# WindowsThemeToggle

Toggles Windows between Light and Dark mode with one click. It switches both the
app theme and the system theme, notifies running apps (such as Visual Studio)
of the change, and also updates the Microsoft Teams caption colors so live
captions stay readable.

## Requirements

- Windows 10/11 with PowerShell 5.1 (built in)
- [Node.js](https://nodejs.org) 18+ with npm (only needed for the Teams caption
  update; use `-SkipTeamsCaptions` to run without it)

## Install

Run `install.cmd` (double-click it or run it from a command prompt). It:

1. Copies `ToggleTheme.ps1` to `%LOCALAPPDATA%\WindowsThemeToggle`.
2. Installs the `classic-level` dependency into `%LOCALAPPDATA%\TeamsCaptionTheme`.
3. Creates a **Light Dark** shortcut on your Desktop that runs the script
   hidden with `-RestartTeams`. The shortcut is generated at install time, so
   it always points at your own profile folder.

Running `install.cmd` again updates the installed script and recreates the shortcut.

## Usage

Click the **Light Dark** shortcut, or run the script directly:

```powershell
.\ToggleTheme.ps1                    # Quit Teams completely first
.\ToggleTheme.ps1 -RestartTeams      # Stops and reopens Teams if it is running
.\ToggleTheme.ps1 -SkipTeamsCaptions # Windows theme only
```

> `-RestartTeams` terminates Teams and will interrupt an active call or meeting.

## Teams captions

The script edits Teams' saved caption settings so the font and background
colors match the theme (Light: black on white, Dark: white on black). Other
caption properties are left unchanged. This relies on an internal Teams storage
format, so a Teams update may break it; unsupported records cause an error
instead of a partial change, and the Windows theme is not toggled in that case.

Before each change, a backup of the Teams database is saved under
`%LOCALAPPDATA%\TeamsCaptionTheme\Backups`. To restore, quit Teams, move the
current `leveldb` directory aside, and copy one backup's entire `leveldb`
directory back to its original location. Do not merge individual `.ldb` files
from different backups.

Use `-TeamsDatabasePath` if your Teams profile is stored somewhere else.

## Uninstall

Delete the **Light Dark** shortcut, `%LOCALAPPDATA%\WindowsThemeToggle`, and
(optionally) `%LOCALAPPDATA%\TeamsCaptionTheme`.
