@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-Codex-Original.ps1"
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo Restore failed. See the message above.
pause
exit /b %result%
