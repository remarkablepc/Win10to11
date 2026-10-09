@echo off
setlocal EnableDelayedExpansion
title Windows 11 In-Place Upgrade Launcher (Administrator)

:: 1. Check for Administrator Privileges and Auto-Elevate
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ACTION] Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo ==============================================================================
echo   Windows 11 In-Place Upgrade Launcher - RemarkablePC
echo   Kernel IFEO Interceptor + Direct ISO Mount (Zero Typing Required)
echo ==============================================================================
echo.

:: 2. Execute PowerShell Engine
if exist "%~dp0Launch_Win11_Upgrade.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch_Win11_Upgrade.ps1"
    if %errorlevel% equ 0 exit /b
)

:: 3. Pure CMD Fallback (In case PowerShell execution is blocked)
echo [FALLBACK] Running native setup sequence...
reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f >nul

if not exist "%SystemDrive%\Scripts" mkdir "%SystemDrive%\Scripts" >nul
(
echo @echo off
echo set "CLI=%%*"
echo set "SOURCES=%%SystemDrive%%\$WINDOWS.~BT\Sources"
echo if not exist "%%SOURCES%%\SetupHost.exe" exit /b
echo if not exist "%%SOURCES%%\WindowsUpdateBox.exe" ^(
echo     mklink /h "%%SOURCES%%\WindowsUpdateBox.exe" "%%SOURCES%%\SetupHost.exe" ^>nul 2^>^&1
echo     if not exist "%%SOURCES%%\WindowsUpdateBox.exe" copy /y "%%SOURCES%%\SetupHost.exe" "%%SOURCES%%\WindowsUpdateBox.exe" ^>nul 2^>^&1
echo ^)
echo if exist "%%SOURCES%%\appraiserres.dll" ^(
echo     attrib -h -s -r "%%SOURCES%%\appraiserres.dll" ^>nul 2^>^&1
echo     del /f /q "%%SOURCES%%\appraiserres.dll" ^>nul 2^>^&1
echo ^)
echo cd.^>"%%SOURCES%%\appraiserres.dll"
echo attrib +r "%%SOURCES%%\appraiserres.dll" ^>nul 2^>^&1
echo reg add "HKLM\SYSTEM\Setup\MoSetup" /f /v AllowUpgradesWithUnsupportedTPMorCPU /d 1 /t reg_dword ^>nul 2^>^&1
echo "%%SOURCES%%\WindowsUpdateBox.exe" %%CLI%%
echo exit /b
) > "%SystemDrive%\Scripts\get11.cmd"

reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe" /v UseFilter /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0" /v FilterFullPath /t REG_SZ /d "%SystemDrive%\$WINDOWS.~BT\Sources\SetupHost.exe" /f >nul
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0" /v Debugger /t REG_SZ /d "%SystemDrive%\Scripts\get11.cmd" /f >nul

if not exist "%SystemDrive%\$WINDOWS.~BT\Sources" mkdir "%SystemDrive%\$WINDOWS.~BT\Sources" >nul
if exist "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" (
    attrib -h -s -r "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1
    del /f /q "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1
)
cd.>"%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll"
attrib +r "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$iso = (Get-ChildItem -Path '%~dp0ISOs\Windows\Win11*.iso', '%~dp0Win11*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName; if ($iso) { Mount-DiskImage -ImagePath $iso -PassThru | Out-Null }"

set "SETUP_EXE="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.wim" set "SETUP_EXE=%%d:\setup.exe"
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.esd" set "SETUP_EXE=%%d:\setup.exe"
)

if defined SETUP_EXE (
    echo Launching: "%SETUP_EXE%" /DynamicUpdate Disable /Compat IgnoreWarning
    "%SETUP_EXE%" /DynamicUpdate Disable /Compat IgnoreWarning
) else (
    echo [ERROR] Could not find or mount Windows 11 setup media.
    pause
)
