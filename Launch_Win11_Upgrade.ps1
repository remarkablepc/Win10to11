# ==============================================================================
# Windows 11 In-Place Upgrade Launcher (Auto-Mount + AveYo IFEO Kernel Bypass)
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
Write-Host "   Auto-Mounts ISO, Installs AveYo IFEO Kernel Bypass & Neutralizes Checks   " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# 1. Apply Full Hardware Bypass Registry Keys (MoSetup + LabConfig + Policies)
Write-Host "`n[1/5] Applying compatibility bypass registry suite..." -ForegroundColor Yellow
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

# 2. Install AveYo Universal IFEO Kernel Bypass for SetupHost.exe
Write-Host "[2/5] Installing AveYo Universal IFEO Kernel Bypass (SetupHost Debugger)..." -ForegroundColor Yellow
try {
    $scriptsDir = "$env:SystemDrive\Scripts"
    if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
    $get11Path = Join-Path $scriptsDir "get11.cmd"

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
    [System.IO.File]::WriteAllText($get11Path, $get11Content, [System.Text.Encoding]::ASCII)

    $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe"
    if (-not (Test-Path $ifeoKey)) { New-Item -Path $ifeoKey -Force | Out-Null }
    Set-ItemProperty -Path $ifeoKey -Name "UseFilter" -Value 1 -Type DWord -Force

    $ifeoSubKey = Join-Path $ifeoKey "0"
    if (-not (Test-Path $ifeoSubKey)) { New-Item -Path $ifeoSubKey -Force | Out-Null }
    Set-ItemProperty -Path $ifeoSubKey -Name "FilterFullPath" -Value "%SystemDrive%\`$WINDOWS.~BT\Sources\SetupHost.exe" -Force
    Set-ItemProperty -Path $ifeoSubKey -Name "Debugger" -Value "%SystemDrive%\Scripts\get11.cmd" -Force

    Write-Host "  [OK] AveYo IFEO Kernel Debugger Hook registered." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] IFEO setup notice: $_" -ForegroundColor Yellow
}

# 3. Pre-Stage 0-Byte appraiserres.dll Stub and Activate Real-Time Watcher
Write-Host "[3/5] Pre-staging 0-byte appraiser stub & starting active watcher..." -ForegroundColor Yellow
try {
    $btSources = "$env:SystemDrive\`$WINDOWS.~BT\Sources"
    if (-not (Test-Path $btSources)) { New-Item -ItemType Directory -Path $btSources -Force | Out-Null }
    $appPath = Join-Path $btSources "appraiserres.dll"
    if (Test-Path $appPath) {
        cmd.exe /c "attrib -h -s -r `"$appPath`" 2>&1" | Out-Null
        Remove-Item -Path $appPath -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllBytes($appPath, @())
    cmd.exe /c "attrib +r `"$appPath`" 2>&1" | Out-Null
    Write-Host "  [OK] 0-byte appraiser stub staged & locked read-only." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Pre-stage notice: $_" -ForegroundColor Yellow
}

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

# 4. Locate and Auto-Mount Windows 11 ISO
Write-Host "[4/5] Locating and auto-mounting Windows 11 ISO..." -ForegroundColor Yellow
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
    # Check already mounted drives
    foreach ($d in $drives) {
        if ((Test-Path "$($d.Name):\setup.exe") -and ((Test-Path "$($d.Name):\sources\install.wim") -or (Test-Path "$($d.Name):\sources\install.esd"))) {
            $setupDriveLetter = $d.Name
            break
        }
    }
}

# 5. Launch Setup
Write-Host "[5/5] Launching Windows 11 Setup..." -ForegroundColor Yellow
if ($setupDriveLetter) {
    $setupExe = "${setupDriveLetter}:\setup.exe"
    Write-Host "`n==============================================================================" -ForegroundColor Green
    Write-Host "  Windows 11 Setup Ready: $setupExe" -ForegroundColor Green
    Write-Host "  Active Safeguards:" -ForegroundColor Green
    Write-Host "    - AveYo IFEO Kernel Debugger Hook (SetupHost -> get11.cmd)" -ForegroundColor Green
    Write-Host "    - MoSetup: AllowUpgradesWithUnsupportedTPMOrCPU = 1" -ForegroundColor Green
    Write-Host "    - LabConfig: BypassTPM, BypassSecureBoot, BypassCPU, BypassRAM" -ForegroundColor Green
    Write-Host "    - Real-Time Zero-Byte appraiserres.dll Neutralizer" -ForegroundColor Green
    Write-Host "    - DynamicUpdate Disabled (prevents 0xC1900101 driver rollback crashes)" -ForegroundColor Green
    Write-Host "==============================================================================`n" -ForegroundColor Green

    Write-Host "Launching: `"$setupExe`" /DynamicUpdate Disable /Compat IgnoreWarning" -ForegroundColor Cyan
    Start-Process -FilePath $setupExe -ArgumentList "/DynamicUpdate Disable /Compat IgnoreWarning"
    Write-Host "`nSetup has started. Follow the prompts on screen to complete your upgrade!" -ForegroundColor Green
    Write-Host "Choose: 'Keep personal files and apps'." -ForegroundColor Green
    Start-Sleep -Seconds 3
} else {
    Write-Host "`n[ERROR] Could not find or mount Windows 11 ISO." -ForegroundColor Red
    Write-Host "Please ensure the USB drive is connected or mount the ISO manually." -ForegroundColor Yellow
    Read-Host "Press Enter to exit..."
}
