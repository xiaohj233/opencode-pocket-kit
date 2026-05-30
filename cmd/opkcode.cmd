@echo off
setlocal
set "ROOT=%~dp0.."
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"
set "PS_SCRIPT="
for %%F in ("%ROOT%\scripts\20-*.ps1") do set "PS_SCRIPT=%%~fF"
if not defined PS_SCRIPT exit /b 1
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Workspace "%CD%"
exit /b %ERRORLEVEL%
