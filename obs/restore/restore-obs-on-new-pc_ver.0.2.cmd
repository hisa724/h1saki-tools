@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-obs-on-new-pc_ver.0.2.ps1"
set "exitCode=%ERRORLEVEL%"
popd
echo.
pause
exit /b %exitCode%
