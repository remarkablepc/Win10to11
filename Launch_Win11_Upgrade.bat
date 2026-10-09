@echo off
setlocal
title Windows 11 In-Place Upgrade Launcher (Auto-Elevation)

:: Check for Administrator privileges and auto-elevate if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ACTION] Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo Launching Windows 11 Upgrade Engine as Administrator...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch_Win11_Upgrade.ps1"
if %errorlevel% neq 0 (
    echo.
    pause
)
