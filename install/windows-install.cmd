@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Codex-Immediate.ps1"
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo Installation failed. See the message above.
pause
exit /b %result%
