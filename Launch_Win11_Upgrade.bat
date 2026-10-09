@echo off
setlocal
title Windows 11 In-Place Upgrade Launcher (Administrator)

:: 1. Check for Administrator Privileges and Auto-Elevate
net session >nul 2>&1
if %errorlevel% equ 0 goto :is_admin

echo [ACTION] Requesting Administrator privileges...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/k \"\"%~f0\"\"' -Verb RunAs"
exit /b

:is_admin
cd /d "%~dp0"

echo ==============================================================================
echo   Windows 11 In-Place Upgrade Launcher - RemarkablePC
echo   AveYo Universal IFEO Interceptor + Direct ISO Mount
echo ==============================================================================
echo.

:: 2. Locate AveYo bypass script
set "BYPASS_SCRIPT="
if exist "%~dp0Skip_TPM_Check_on_Dynamic_Update.cmd" set "BYPASS_SCRIPT=%~dp0Skip_TPM_Check_on_Dynamic_Update.cmd"
if not defined BYPASS_SCRIPT if exist "%~dp0WINTools\bin\win10to11\Skip_TPM_Check_on_Dynamic_Update.cmd" set "BYPASS_SCRIPT=%~dp0WINTools\bin\win10to11\Skip_TPM_Check_on_Dynamic_Update.cmd"

if not defined BYPASS_SCRIPT goto :fallback_bypass

echo [1/3] Installing AveYo Universal Hardware Bypass (V13)...
call "%BYPASS_SCRIPT%" install
goto :after_bypass

:fallback_bypass
echo [WARN] AveYo script not found, applying native registry bypass...
reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul
reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f >nul

:after_bypass
:: 3. Neutralize any stale unpatched appraiserres.dll from previous runs
echo [2/3] Neutralizing setup cache in $WINDOWS.~BT...
if exist "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" attrib -h -s -r "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1
if exist "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" del /f /q "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1

:: 4. Locate and Auto-Mount Windows 11 ISO
echo [3/3] Locating and mounting Windows 11 ISO...
set "SETUP_DRIVE="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.wim" set "SETUP_DRIVE=%%d"
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.esd" set "SETUP_DRIVE=%%d"
)

if defined SETUP_DRIVE goto :do_launch

echo   Scanning and mounting ISO...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$iso = Get-ChildItem -Path '%~dp0ISOs\Windows\*Win11*.iso', '%~dp0*Win11*.iso', '%~dp0..\..\ISOs\Windows\*Win11*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($iso) { Write-Host '  Mounting:' $iso.FullName; Mount-DiskImage -ImagePath $iso.FullName -PassThru | Out-Null }"

ping 127.0.0.1 -n 3 >nul

for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.wim" set "SETUP_DRIVE=%%d"
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.esd" set "SETUP_DRIVE=%%d"
)

:do_launch
if defined SETUP_DRIVE goto :ready_to_launch

echo.
echo [ERROR] Could not find or mount Windows 11 setup media.
echo Please make sure the USB drive is connected or mount the ISO manually.
echo.
pause
exit /b 1

:ready_to_launch
echo.
echo ==============================================================================
echo   Found Windows 11 Setup at: %SETUP_DRIVE%:\setup.exe
echo   Hardware bypass is active. Launching Setup...
echo ==============================================================================
echo.
echo Windows 11 Setup has started. Follow the on-screen prompts to keep files and apps.
echo.
"%SETUP_DRIVE%:\setup.exe" /DynamicUpdate Disable /Compat IgnoreWarning
pause
