@echo off
setlocal
title Windows 11 In-Place Upgrade Launcher (Administrator)

:: 1. Check for Administrator Privileges and Auto-Elevate (Keeps window open with /k)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ACTION] Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/k \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

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

if defined BYPASS_SCRIPT (
    echo [1/3] Installing AveYo Universal Hardware Bypass (V13)...
    call "%BYPASS_SCRIPT%" install
) else (
    echo [WARN] AveYo script not found, applying native registry bypass...
    reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f >nul
    reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f >nul
    reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul
    reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f >nul
)

:: 3. Neutralize any stale unpatched appraiserres.dll from previous runs
echo [2/3] Neutralizing setup cache in $WINDOWS.~BT...
if exist "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" (
    attrib -h -s -r "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1
    del /f /q "%SystemDrive%\$WINDOWS.~BT\Sources\appraiserres.dll" >nul 2>&1
)

:: 4. Locate and Auto-Mount Windows 11 ISO
echo [3/3] Locating and mounting Windows 11 ISO...
set "SETUP_DRIVE="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.wim" set "SETUP_DRIVE=%%d"
    if exist "%%d:\setup.exe" if exist "%%d:\sources\install.esd" set "SETUP_DRIVE=%%d"
)

if not defined SETUP_DRIVE (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$candidates = @('%~dp0ISOs\Windows\Win11_23H2_English_x64.iso', '%~dp0Win11.iso'); foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[A-Z]$' })) { $candidates += (Get-ChildItem -Path \"$($d.Name):\ISOs\Windows\*Win11*.iso\", \"$($d.Name):\*Win11*.iso\" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) }; $best = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique | ForEach-Object { Get-Item $_ } | Sort-Object Length -Descending | Select-Object -First 1; if ($best) { Write-Host '  Mounting:' $best.FullName; Mount-DiskImage -ImagePath $best.FullName -PassThru | Out-Null }"
    for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\setup.exe" if exist "%%d:\sources\install.wim" set "SETUP_DRIVE=%%d"
        if exist "%%d:\setup.exe" if exist "%%d:\sources\install.esd" set "SETUP_DRIVE=%%d"
    )
)

if defined SETUP_DRIVE (
    echo.
    echo ==============================================================================
    echo   Found Windows 11 Setup at: %SETUP_DRIVE%:\setup.exe
    echo   Hardware bypass is active. Launching Setup...
    echo ==============================================================================
    echo.
    "%SETUP_DRIVE%:\setup.exe" /DynamicUpdate Disable /Compat IgnoreWarning
) else (
    echo.
    echo [ERROR] Could not find or mount Windows 11 setup media.
    echo Please make sure the USB drive is connected or mount the ISO manually.
    echo.
    pause
)
