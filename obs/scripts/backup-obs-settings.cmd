@echo off
setlocal

echo OBS Settings Backup
echo ===================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-obs-settings.ps1"
set "exitCode=%ERRORLEVEL%"

echo.
if not "%exitCode%"=="0" (
    echo Backup failed. Read the error message above.
) else (
    echo Backup command finished.
)

echo.
pause
exit /b %exitCode%
