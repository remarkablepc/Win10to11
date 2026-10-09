# ==============================================================================
# Windows 11 In-Place Upgrade Launcher (Auto-Mount + Universal IFEO Kernel Bypass)
# RemarkablePC Tooling - Engineered for Legacy BIOS, MBR & Unsupported Hardware
# ==============================================================================

# 0. Ensure Administrator Elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ACTION] Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Host.UI.RawUI.WindowTitle = "Windows 11 Upgrade Launcher - RemarkablePC"
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "   RemarkablePC Windows 11 In-Place Upgrade Engine (Administrator)            " -ForegroundColor Cyan
Write-Host "   Auto-Mounts ISO & Intercepts Hardware Checks at Kernel Level (IFEO)       " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# 1. Apply Full Hardware Bypass Registry Keys (MoSetup + LabConfig + WindowsUpdate)
Write-Host "`n[1/4] Applying compatibility bypass registry suite..." -ForegroundColor Yellow
try {
    # MoSetup
    $moSetup = "HKLM:\SYSTEM\Setup\MoSetup"
    if (-not (Test-Path $moSetup)) { New-Item -Path $moSetup -Force | Out-Null }
    Set-ItemProperty -Path $moSetup -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord -Force

    # LabConfig
    $labConfig = "HKLM:\SYSTEM\Setup\LabConfig"
    if (-not (Test-Path $labConfig)) { New-Item -Path $labConfig -Force | Out-Null }
    Set-ItemProperty -Path $labConfig -Name "BypassTPMCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassSecureBootCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassCPUCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassRAMCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassStorageCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassDiskCheck" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $labConfig -Name "BypassNRO" -Value 1 -Type DWord -Force

    # Disable Safeguards
    $wuPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (-not (Test-Path $wuPolicy)) { New-Item -Path $wuPolicy -Force | Out-Null }
    Set-ItemProperty -Path $wuPolicy -Name "DisableWUfBSafeguards" -Value 1 -Type DWord -Force

    Write-Host "  [OK] Registry bypass suite applied successfully." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Registry bypass notice: $_" -ForegroundColor Yellow
}

# 2. Install AveYo Universal IFEO Kernel Bypass (SetupHost Debugger Interceptor)
Write-Host "[2/4] Installing Universal IFEO Kernel Bypass (SetupHost.exe Interceptor)..." -ForegroundColor Yellow
try {
    $bypassCandidates = @(
        (Join-Path $PSScriptRoot "Skip_TPM_Check_on_Dynamic_Update.cmd"),
        (Join-Path $PSScriptRoot "WINTools\bin\win10to11\Skip_TPM_Check_on_Dynamic_Update.cmd"),
        "$env:SystemDrive\Skip_TPM_Check_on_Dynamic_Update.cmd"
    )
    $officialBypass = $null
    foreach ($cand in $bypassCandidates) {
        if ($cand -and (Test-Path $cand)) {
            $officialBypass = $cand
            break
        }
    }

    if ($officialBypass) {
        cmd.exe /c "`"$officialBypass`" install" | Out-Null
        Write-Host "  [OK] AveYo Universal Hardware Bypass suite (V13) installed." -ForegroundColor Green
    } else {
        $scriptsDir = "$env:SystemDrive\Scripts"
        if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
        $get11 = Join-Path $scriptsDir "get11.cmd"
        $get11Content = @"
@echo off & title get 11 on 'unsupported' PC || AveYo
set CLI=%*& set SOURCES=%SystemDrive%\`$WINDOWS.~BT\Sources& set MEDIA=.& set MOD=CLI& set PRE=WUA& set /a VER=11
if not defined CLI (exit /b) else if not exist %SOURCES%\SetupHost.exe (exit /b)
if not exist %SOURCES%\WindowsUpdateBox.exe mklink /h %SOURCES%\WindowsUpdateBox.exe %SOURCES%\SetupHost.exe
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate /f /v DisableWUfBSafeguards /d 1 /t reg_dword >nul 2>nul
reg add HKLM\SYSTEM\Setup\MoSetup /f /v AllowUpgradesWithUnsupportedTPMorCPU /d 1 /t reg_dword >nul 2>nul
set OPT=/Compat IgnoreWarning /MigrateDrivers All /Telemetry Disable
set /a restart_application=0x800705BB & (call set CLI=%%CLI:%1 =%%)
set /a incorrect_parameter=0x80070057 & (set SRV=%CLI:/Product Client =%)
set /a launch_option_error=0xc190010a & (set SRV=%SRV:/Product Server =%)
for %%W in (%CLI%) do if /i %%W == /PreDownload (set MOD=SRV)
for %%W in (%CLI%) do if /i %%W == /InstallFile (set PRE=ISO& set "MEDIA=") else if not defined MEDIA set "MEDIA=%%~dpW"
if %VER% == 11 for %%W in ("%MEDIA%appraiserres.dll") do if exist %%W if %%~zW == 0 set AlreadyPatched=1 & set /a VER=10
if %VER% == 11 findstr /r "P.r.o.d.u.c.t.V.e.r.s.i.o.n...1.0.\..0.\..2.[2-9]" %SOURCES%\SetupHost.exe >nul 2>nul || set /a VER=10
if %VER% == 11 if not exist "%MEDIA%EI.cfg" (echo;[Channel]>%SOURCES%\EI.cfg & echo;_Default>>%SOURCES%\EI.cfg)
if %VER%_%PRE% == 11_ISO (%SOURCES%\WindowsUpdateBox.exe /Product Server /PreDownload /Quiet %OPT%)
if %VER%_%PRE% == 11_ISO (del /f /q %SOURCES%\appraiserres.dll 2>nul & cd.>%SOURCES%\appraiserres.dll & call :canary)
if %VER%_%MOD% == 11_SRV (set ARG=%OPT% %SRV% /Product Server)
if %VER%_%MOD% == 11_CLI (set ARG=%OPT% %CLI%)
%SOURCES%\WindowsUpdateBox.exe %ARG%
if %errorlevel% == %restart_application% (call :canary & %SOURCES%\WindowsUpdateBox.exe %ARG%)
exit /b

:canary
set C=  `$X='%SOURCES%\hwreqchk.dll'; `$Y='SQ_TpmVersion GTE 1'; `$Z='SQ_TpmVersion GTE 0'; if (test-path `$X) { try { takeown.exe /f `$X /a; icacls.exe `$X /grant *S-1-5-32-544:f; attrib -R -S `$X; [io.file]::OpenWrite(`$X).close() } catch { return }; `$R=[Text.Encoding]::UTF8.GetBytes(`$Z); `$l=`$R.Length; `$i=2; `$w=!1; `$B=[io.file]::ReadAllBytes(`$X); `$H=[BitConverter]::ToString(`$B) -replace '-'; `$S=[BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes(`$Y)) -replace '-'; do { `$i=`$H.IndexOf(`$S, `$i + 2); if (`$i -gt 0) { `$w=!0; for (`$k=0; `$k -lt `$l; `$k++) { `$B[`$k + `$i / 2]=`$R[`$k] } } } until (`$i -lt 1); if (`$w) { [io.file]::WriteAllBytes(`$X, `$B); [GC]::Collect() } }
if %VER%_%PRE% == 11_ISO powershell -nop -c iex(`$env:C) >nul 2>nul
exit /b
"@
        [System.IO.File]::WriteAllText($get11, $get11Content, [System.Text.Encoding]::ASCII)

        cmd.exe /c "reg.exe add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe`" /v UseFilter /t REG_DWORD /d 1 /f 2>&1" | Out-Null
        cmd.exe /c "reg.exe add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0`" /v FilterFullPath /t REG_SZ /d `"$env:SystemDrive\`$WINDOWS.~BT\Sources\SetupHost.exe`" /f 2>&1" | Out-Null
        cmd.exe /c "reg.exe add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0`" /v Debugger /t REG_SZ /d `"$env:SystemDrive\Scripts\get11.cmd`" /f 2>&1" | Out-Null

        Write-Host "  [OK] IFEO Kernel Interceptor registered (SetupHost.exe -> get11.cmd)." -ForegroundColor Green
    }
} catch {
    Write-Host "  [WARN] IFEO setup notice: $_" -ForegroundColor Yellow
}

# 3. Purge Stale Appraiser & Pre-Stage 0-Byte Stub
Write-Host "[3/4] Neutralizing setup cache & staging 0-byte appraiser stub..." -ForegroundColor Yellow
try {
    $btSources = "$env:SystemDrive\`$WINDOWS.~BT\Sources"
    if (-not (Test-Path $btSources)) { New-Item -ItemType Directory -Path $btSources -Force | Out-Null }
    $btAppraiser = Join-Path $btSources "appraiserres.dll"
    if (Test-Path $btAppraiser) {
        cmd.exe /c "attrib -h -s -r `"$btAppraiser`" 2>&1" | Out-Null
        Remove-Item -Path $btAppraiser -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllBytes($btAppraiser, @())
    cmd.exe /c "attrib +r `"$btAppraiser`" 2>&1" | Out-Null
    Write-Host "  [OK] Staged 0-byte appraiser stub and locked read-only." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Pre-stage notice: $_" -ForegroundColor Yellow
}

# Start background zero-byte watcher
Start-Job -ScriptBlock {
    $p = "$env:SystemDrive\`$WINDOWS.~BT\Sources\appraiserres.dll"
    for ($i = 0; $i -lt 400; $i++) {
        if (Test-Path $p) {
            $item = Get-Item $p -ErrorAction SilentlyContinue
            if ($item -and $item.Length -gt 0) {
                cmd.exe /c "attrib -h -s -r `"$p`" 2>&1" | Out-Null
                [System.IO.File]::WriteAllBytes($p, @())
                cmd.exe /c "attrib +r `"$p`" 2>&1" | Out-Null
            }
        }
        Start-Sleep -Milliseconds 300
    }
} | Out-Null

# 4. Locate, Auto-Mount ISO & Launch Setup
Write-Host "[4/4] Locating and mounting Windows 11 ISO..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$candidates = @()
if ($scriptDir) {
    $candidates += (Join-Path $scriptDir "ISOs\Windows\Win11_23H2_English_x64.iso")
    $candidates += (Join-Path $scriptDir "Win11.iso")
}

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match "^[A-Z]$" }
foreach ($d in $drives) {
    $candidates += "$($d.Name):\ISOs\Windows\Win11_23H2_English_x64.iso"
    $candidates += (Get-ChildItem -Path "$($d.Name):\" -Filter "*Win11*.iso" -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
}

$bestIso = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique | ForEach-Object { Get-Item $_ } | Sort-Object Length -Descending | Select-Object -First 1

$setupDriveLetter = $null
if ($bestIso) {
    Write-Host "  Found ISO: $($bestIso.FullName) ($([math]::Round($bestIso.Length/1GB, 2)) GB)" -ForegroundColor Green
    $m = Get-DiskImage -ImagePath $bestIso.FullName -ErrorAction SilentlyContinue
    if (-not $m -or -not ($m | Get-Volume -ErrorAction SilentlyContinue).DriveLetter) {
        Write-Host "  Mounting ISO image..." -ForegroundColor Cyan
        $m = Mount-DiskImage -ImagePath $bestIso.FullName -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
    }
    $vol = $m | Get-Volume -ErrorAction SilentlyContinue
    if ($vol -and $vol.DriveLetter) {
        $setupDriveLetter = $vol.DriveLetter
    }
} else {
    foreach ($d in $drives) {
        if ((Test-Path "$($d.Name):\setup.exe") -and ((Test-Path "$($d.Name):\sources\install.wim") -or (Test-Path "$($d.Name):\sources\install.esd"))) {
            $setupDriveLetter = $d.Name
            break
        }
    }
}

if ($setupDriveLetter) {
    $setupExe = "${setupDriveLetter}:\setup.exe"
    Write-Host "`n==============================================================================" -ForegroundColor Green
    Write-Host "  Windows 11 Setup Ready: $setupExe" -ForegroundColor Green
    Write-Host "  Active Safeguards:" -ForegroundColor Green
    Write-Host "    - AveYo IFEO Kernel Interceptor (SetupHost.exe -> get11.cmd)" -ForegroundColor Green
    Write-Host "    - MoSetup: AllowUpgradesWithUnsupportedTPMOrCPU = 1" -ForegroundColor Green
    Write-Host "    - LabConfig: BypassTPMCheck, BypassSecureBootCheck, BypassCPUCheck" -ForegroundColor Green
    Write-Host "    - Real-Time 0-Byte appraiserres.dll Neutralizer" -ForegroundColor Green
    Write-Host "    - /DynamicUpdate Disable (prevents driver rollback crashes)" -ForegroundColor Green
    Write-Host "==============================================================================`n" -ForegroundColor Green

    Write-Host "Launching Setup..." -ForegroundColor Cyan
    Start-Process -FilePath $setupExe -ArgumentList "/DynamicUpdate Disable /Compat IgnoreWarning"
    Write-Host "Setup has been initiated. Follow the prompts on screen." -ForegroundColor Green
    Write-Host "Choose: 'Keep personal files and apps'." -ForegroundColor Green
    Start-Sleep -Seconds 3
} else {
    Write-Host "`n[ERROR] Could not find or mount Windows 11 ISO." -ForegroundColor Red
    Write-Host "Please ensure the USB drive containing the Windows 11 ISO is connected." -ForegroundColor Yellow
    Read-Host "Press Enter to exit..."
}
