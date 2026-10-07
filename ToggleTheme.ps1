<#
Toggles Windows and Teams caption colors without UI automation.

One-time dependency setup (normal PowerShell, Node.js 18+ and npm installed):
  npm.cmd install --prefix "$env:LOCALAPPDATA\TeamsCaptionTheme" --save-exact --no-audit --no-fund classic-level@3.0.0

Usage:
  .\ToggleTheme.ps1                  # Quit Teams completely first.
  .\ToggleTheme.ps1 -RestartTeams    # Stops and reopens Teams if running.
  .\ToggleTheme.ps1 -SkipTeamsCaptions # Original Windows-only behavior.

-RestartTeams terminates Teams and will interrupt an active call/meeting.
All saved caption records for teams.microsoft.com in the selected profile
are updated. Other caption properties remain unchanged.

Backups are saved under %LOCALAPPDATA%\TeamsCaptionTheme\Backups.
To restore: quit Teams, move the current leveldb directory aside, then copy
one backup's entire leveldb directory back to the original location.
Do not merge individual .ldb files from different database versions.

This uses an internal Teams storage format verified against the supplied
snapshot. Teams updates may change it. Unsupported records cause an error.
#>
[CmdletBinding()]
param(
    [switch]$RestartTeams,
    [switch]$SkipTeamsCaptions,
    [string]$TeamsDatabasePath = (
        Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\Local Storage\leveldb'
    )
)

$ErrorActionPreference = 'Stop'

function Set-TeamsCaptionTheme {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Light', 'Dark')]
        [string]$Theme,
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,
        [switch]$Restart
    )

    $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        throw 'Node.js 18+ is required for Teams captions. Install Node.js, or use -SkipTeamsCaptions.'
    }

    $dependencyRoot = Join-Path $env:LOCALAPPDATA 'TeamsCaptionTheme'
    $packagePath = Join-Path $dependencyRoot 'node_modules\classic-level'
    if (-not (Test-Path -LiteralPath (Join-Path $packagePath 'package.json'))) {
        throw 'Run this once in normal PowerShell: npm.cmd install --prefix "$env:LOCALAPPDATA\TeamsCaptionTheme" --save-exact --no-audit --no-fund classic-level@3.0.0'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DatabasePath 'CURRENT'))) {
        throw "Teams database not found: $DatabasePath. Use -TeamsDatabasePath for another profile, or -SkipTeamsCaptions."
    }

    # Verify the dependency before stopping Teams or changing any settings.
    & $node.Source -e 'if (parseInt(process.versions.node) < 18) process.exit(1); require(process.argv[1]);' $packagePath
    if ($LASTEXITCODE -ne 0) {
        throw 'The LevelDB dependency could not be loaded. No theme settings were changed.'
    }

    $sessionId = (Get-Process -Id $PID).SessionId
    $teamsProcesses = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId })
    $wasRunning = $teamsProcesses.Count -gt 0
    if ($wasRunning -and -not $Restart) {
        throw 'Quit Teams from its tray menu first, or run with -RestartTeams. Restarting interrupts active calls.'
    }

    $helperPath = Join-Path ([IO.Path]::GetTempPath()) (
        'teams-caption-theme-' + [Guid]::NewGuid().ToString('N') + '.cjs'
    )
    $helperSource = @'
'use strict';
const fs = require('node:fs');
const path = require('node:path');

function decodeString(bytes) {
  if (bytes.length < 1) throw new Error('Empty Chromium string.');
  if (bytes[0] === 1) return bytes.subarray(1).toString('latin1');
  if (bytes[0] === 0 && (bytes.length - 1) % 2 === 0) {
    return bytes.subarray(1).toString('utf16le');
  }
  throw new Error('Unrecognized Chromium string encoding; no changes made.');
}

function encodeString(text, marker) {
  if (marker === 1 && /[^\u0000-\u00ff]/.test(text)) {
    throw new Error('Cannot preserve the original Latin-1 encoding.');
  }
  return Buffer.concat([
    Buffer.from([marker]), Buffer.from(text, marker === 1 ? 'latin1' : 'utf16le')
  ]);
}

function captionKey(key) {
  const prefix = Buffer.from('_https://teams.microsoft.com\0', 'utf8');
  if (!key.subarray(0, prefix.length).equals(prefix)) return false;
  const name = decodeString(key.subarray(prefix.length));
  return /^tmp\.[0-9a-f-]{36}\.[0-9a-f-]{36}\.react-web-client\.closed-captions-settings$/i.test(name);
}

function updatedValue(value, theme) {
  const originalText = decodeString(value);
  const original = JSON.parse(originalText);
  const colors = {
    fontColor: theme === 'Light' ? 'Black' : 'White',
    fontColorV2: theme === 'Light' ? 'Black' : 'White',
    backgroundColor: theme === 'Light' ? 'White' : 'Black'
  };
  // Replace only the three JSON tokens, preserving whitespace, encoding,
  // other fields and byte length (Chromium also tracks storage sizes).
  let text = originalText;
  for (const [field, color] of Object.entries(colors)) {
    if (!['White', 'Black'].includes(original[field])) {
      throw new Error(`Unsupported ${field} value; expected White or Black. No changes made.`);
    }
    const pattern = new RegExp(`("${field}"\\s*:\\s*")(White|Black)(")`, 'g');
    let matches = 0;
    text = text.replace(pattern, (_, before, previous, after) => {
      matches += 1;
      return before + color + after;
    });
    if (matches !== 1) throw new Error(`Ambiguous ${field}; no changes made.`);
  }
  const parsed = JSON.parse(text);
  for (const field of Object.keys(original)) {
    const expected = Object.hasOwn(colors, field) ? colors[field] : original[field];
    if (JSON.stringify(parsed[field]) !== JSON.stringify(expected)) {
      throw new Error('Unexpected change outside caption colors.');
    }
  }
  const encoded = encodeString(text, value[0]);
  if (encoded.length !== value.length) throw new Error('Storage size changed; refusing update.');
  return encoded;
}

async function main(args) {
  const [dependencyRoot, dbPath, theme, backupRoot] = args;
  if (args.length !== 4 || !['Light', 'Dark'].includes(theme)) {
    throw new Error('Expected dependency directory, database directory, Light/Dark, backup directory.');
  }
  const { ClassicLevel } = require(path.join(dependencyRoot, 'node_modules', 'classic-level'));
  if (!fs.existsSync(path.join(dbPath, 'CURRENT'))) {
    throw new Error('Existing Teams Local Storage database was not found.');
  }
  // Caller must quit Teams first. LevelDB's own LOCK additionally prevents
  // concurrent database access; never delete or bypass that lock.
  fs.mkdirSync(backupRoot, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backup = fs.mkdtempSync(path.join(backupRoot, `${stamp}-${theme}-`));
  fs.cpSync(dbPath, path.join(backup, 'leveldb'), { recursive: true, errorOnExist: true, force: false });
  console.log(`Database backup: ${backup}`);
  const db = new ClassicLevel(dbPath, {
    keyEncoding: 'buffer', valueEncoding: 'buffer',
    createIfMissing: false, paranoidChecks: true
  });
  try {
    await db.open();
    const changes = [];
    let found = 0;
    for await (const [key, value] of db.iterator()) {
      if (!captionKey(key)) continue;
      found += 1;
      const updated = updatedValue(value, theme);
      if (!value.equals(updated)) changes.push({ type: 'put', key, value: updated });
    }
    if (found === 0) throw new Error('No saved Teams caption-style record found; no caption values changed.');
    if (changes.length > 0) {
      await db.batch(changes, { sync: true });
      for (const change of changes) {
        const stored = await db.get(change.key);
        if (!stored || !stored.equals(change.value)) throw new Error('Caption read-back verification failed.');
      }
    }
    console.log(`Teams captions: ${theme}; ${changes.length} record(s) updated, ${found} found.`);
  } finally {
    await db.close();
  }
}

module.exports = { decodeString, encodeString, captionKey, updatedValue, main };
if (require.main === module) {
  main(process.argv.slice(2)).catch(error => {
    console.error(`Caption update failed: ${error.message}`);
    if (error.cause) console.error(`Details: ${error.cause.message}`);
    process.exitCode = 1;
  });
}

'@
    $restartNeeded = $false
    try {
        [IO.File]::WriteAllText($helperPath, $helperSource, [Text.UTF8Encoding]::new($false))
        if ($wasRunning) {
            $restartNeeded = $true
            foreach ($process in $teamsProcesses) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            }
            foreach ($process in $teamsProcesses) {
                if (-not $process.WaitForExit(10000)) {
                    throw 'Teams did not exit. Caption settings were not changed.'
                }
            }
            Start-Sleep -Milliseconds 750
        }

        $backupRoot = Join-Path $dependencyRoot 'Backups'
        & $node.Source $helperPath $dependencyRoot $DatabasePath $Theme $backupRoot
        if ($LASTEXITCODE -ne 0) {
            throw 'Teams caption update failed; the Windows theme was not changed. See the error and backup path above. If the database is locked, fully quit Teams and try again.'
        }
    }
    finally {
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
        if ($restartNeeded) {
            try {
                Start-Process -FilePath 'ms-teams:' -ErrorAction Stop
            }
            catch {
                Write-Warning 'Could not reopen Teams automatically. Open it from the Start menu.'
            }
        }
    }
}

$themePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Read the current application theme.
$currentTheme = Get-ItemPropertyValue `
    -Path $themePath `
    -Name AppsUseLightTheme `
    -ErrorAction SilentlyContinue

# If the value doesn't exist, treat the current mode as Light.
if ($null -eq $currentTheme) {
    $currentTheme = 1
}

# Toggle both the application theme and Windows system theme.
if ($currentTheme -eq 1) {
    $newTheme = 0
}
else {
    $newTheme = 1
}

# Update captions before applying the Windows theme. A caption error aborts the toggle.
if (-not $SkipTeamsCaptions) {
    $captionTheme = if ($newTheme -eq 1) { 'Light' } else { 'Dark' }
    Set-TeamsCaptionTheme -Theme $captionTheme -DatabasePath $TeamsDatabasePath -Restart:$RestartTeams
}

Set-ItemProperty `
    -Path $themePath `
    -Name AppsUseLightTheme `
    -Type DWord `
    -Value $newTheme

Set-ItemProperty `
    -Path $themePath `
    -Name SystemUsesLightTheme `
    -Type DWord `
    -Value $newTheme

# Windows Settings broadcasts WM_SETTINGCHANGE after a theme change.
# Applications such as Visual Studio that follow the system theme listen
# for this notification. "ImmersiveColorSet" identifies the color-theme change.
if (-not ("ThemeBroadcast" -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ThemeBroadcast
{
    public const int HWND_BROADCAST = 0xffff;
    public const int WM_SETTINGCHANGE = 0x001A;
    public const int SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult
    );
}
"@
}

$settingName = "ImmersiveColorSet"
$lParam = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($settingName)

try {
    $result = [UIntPtr]::Zero

    [void][ThemeBroadcast]::SendMessageTimeout(
        [IntPtr][ThemeBroadcast]::HWND_BROADCAST,
        [uint32][ThemeBroadcast]::WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        $lParam,
        [uint32][ThemeBroadcast]::SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    )
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($lParam)
}

# Give applications a moment to process the broadcast.
Start-Sleep -Milliseconds 150

Write-Host ("Windows theme: " + $(if ($newTheme -eq 1) { "Light" } else { "Dark" }))
