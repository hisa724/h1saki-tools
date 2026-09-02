@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure-audio_ver.0.1.ps1"
set "exitCode=%ERRORLEVEL%"
popd
echo.
pause
exit /b %exitCode%
