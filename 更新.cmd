@echo off
setlocal
cd /d "%~dp0"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"

set "PS_SCRIPT="
for %%F in ("%~dp0scripts\10-*.ps1") do set "PS_SCRIPT=%%~fF"
if not defined PS_SCRIPT exit /b 1
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" update
if errorlevel 1 pause & exit /b 1

set "DL_SCRIPT="
for %%F in ("%~dp0scripts\50-*.ps1") do set "DL_SCRIPT=%%~fF"
if defined DL_SCRIPT "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DL_SCRIPT%" skills
pause
exit /b 0
