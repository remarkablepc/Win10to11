@echo off
setlocal EnableDelayedExpansion

:: 1. Self-Elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrative Privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

:: 2. Change Directory to Script Location
cd /d "%~dp0"

:: 3. Verify PowerShell File Exists & Execute
set "SCRIPT_FILE=Win10to11.ps1"
if not exist "%SCRIPT_FILE%" if exist "win11readiness.ps1" set "SCRIPT_FILE=win11readiness.ps1"

if exist "%SCRIPT_FILE%" (
    echo Launching %SCRIPT_FILE%...
    echo.
    
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_FILE%" %*
    
    echo.
    echo Script execution finished. Press any key to close this window.
    pause
) else (
    echo [ERROR] Neither Win10to11.ps1 nor win11readiness.ps1 was found in the current directory!
    echo Current Directory: %cd%
    echo.
    pause
)

exit /b