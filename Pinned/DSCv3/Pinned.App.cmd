@echo off
setlocal

set "SCRIPT=%~dp0Pinned.App.ps1"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
set "WINDOWSPOWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

where pwsh.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%PWSH%" (
    "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

where powershell.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%WINDOWSPOWERSHELL%" (
    "%WINDOWSPOWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

echo Unable to find pwsh.exe or powershell.exe. Install PowerShell 7 or restore Windows PowerShell. 1>&2
exit /b 1
