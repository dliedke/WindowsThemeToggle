@echo off
setlocal

rem Installs WindowsThemeToggle for the current user:
rem   1. Copies ToggleTheme.ps1 to %LOCALAPPDATA%\WindowsThemeToggle
rem   2. Installs the classic-level dependency used for Teams captions
rem   3. Creates a "Light Dark" shortcut on the Desktop

set "INSTALL_DIR=%LOCALAPPDATA%\WindowsThemeToggle"
set "DEPS_DIR=%LOCALAPPDATA%\TeamsCaptionTheme"
set "SOURCE_DIR=%~dp0"

if not exist "%SOURCE_DIR%ToggleTheme.ps1" (
    echo ERROR: ToggleTheme.ps1 was not found next to install.cmd.
    exit /b 1
)

where node.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Node.js 18+ is required. Install it from https://nodejs.org and run this again.
    exit /b 1
)

echo Copying files to "%INSTALL_DIR%"...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
copy /y "%SOURCE_DIR%ToggleTheme.ps1" "%INSTALL_DIR%\ToggleTheme.ps1" >nul
if errorlevel 1 (
    echo ERROR: Could not copy ToggleTheme.ps1.
    exit /b 1
)

echo Installing Teams caption dependency...
call npm.cmd install --prefix "%DEPS_DIR%" --save-exact --no-audit --no-fund classic-level@3.0.0
if errorlevel 1 (
    echo ERROR: npm install failed.
    exit /b 1
)

echo Creating Desktop shortcut...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Light Dark.lnk'; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $q + $env:INSTALL_DIR + '\ToggleTheme.ps1' + $q + ' -RestartTeams'; $s.WorkingDirectory = $env:INSTALL_DIR; $s.Description = 'Toggle Windows and application Light/Dark mode'; $s.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',25'; $s.Save(); Write-Host ('Shortcut created: ' + $lnk)"
if errorlevel 1 (
    echo ERROR: Could not create the shortcut.
    exit /b 1
)

echo.
echo Done. Use the "Light Dark" shortcut on your Desktop to toggle the theme.
endlocal
