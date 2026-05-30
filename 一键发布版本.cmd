@echo off
setlocal
set "ROOT=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\70-release-version.ps1"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" echo [ERROR] release script failed with exit code %ERR%.
pause
exit /b %ERR%
