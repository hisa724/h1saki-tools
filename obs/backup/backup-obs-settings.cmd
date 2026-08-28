@echo off
chcp 65001 >nul
setlocal

echo OBS設定バックアップ
echo ==================
echo.

pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-obs-settings.ps1"
set "exitCode=%ERRORLEVEL%"
popd

echo.
if not "%exitCode%"=="0" (
    echo バックアップに失敗しました。上に表示されたエラーを確認してください。
) else (
    echo バックアップ処理が終了しました。
)

echo.
pause
exit /b %exitCode%
