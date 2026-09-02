@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0add-standby-scene_ver.0.1.ps1"
set "exitCode=%ERRORLEVEL%"
popd
echo.
pause
exit /b %exitCode%
