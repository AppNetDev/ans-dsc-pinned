@echo off
setlocal

set "SCRIPT=%~dp0Pinned.App.ps1"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
set "PWSH_X86=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
set "WINDOWSPOWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "WINDOWSPOWERSHELL_X86=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"

if exist "%PWSH%" (
    "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%PWSH_X86%" (
    "%PWSH_X86%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%WINDOWSPOWERSHELL%" (
    "%WINDOWSPOWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%WINDOWSPOWERSHELL_X86%" (
    "%WINDOWSPOWERSHELL_X86%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

echo Unable to find pwsh.exe or powershell.exe. Install PowerShell 7 or restore Windows PowerShell. 1>&2
exit /b 1
