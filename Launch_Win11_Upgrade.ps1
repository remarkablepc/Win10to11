# ==============================================================================
# Windows 11 In-Place Upgrade Launcher (Writable SSD Staging + 0-Byte Appraiser)
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
Write-Host "   Writable SSD Staging + 0-Byte Appraiser Bypass (TPM & Secure Boot Free)    " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# 1. Apply Full Hardware Bypass Registry Keys (MoSetup + LabConfig + Policies)
Write-Host "`n[1/5] Applying compatibility bypass registry suite..." -ForegroundColor Yellow
try {
    # MoSetup Key
    $moSetup = "HKLM:\SYSTEM\Setup\MoSetup"
    if (-not (Test-Path $moSetup)) { New-Item -Path $moSetup -Force | Out-Null }
    Set-ItemProperty -Path $moSetup -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord -Force

    # LabConfig Keys
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

# 2. Check or Extract Setup to Local SSD (C:\Win11Setup)
$targetStage = "$env:SystemDrive\Win11Setup"
$setupExe = Join-Path $targetStage "setup.exe"
$appraiserDll = Join-Path $targetStage "sources\appraiserres.dll"
$hasWim = (Test-Path (Join-Path $targetStage "sources\install.wim")) -or (Test-Path (Join-Path $targetStage "sources\install.esd"))

if ((Test-Path $setupExe) -and $hasWim) {
    Write-Host "`n[2/5] Verified existing Windows 11 installation media at: $targetStage" -ForegroundColor Green
} else {
    Write-Host "`n[2/5] Locating Windows 11 ISO image..." -ForegroundColor Yellow
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

    if (-not $bestIso) {
        Write-Host "`n[ERROR] Could not find Windows 11 ISO image on any attached drive." -ForegroundColor Red
        Write-Host "Please ensure the USB drive containing the Windows 11 ISO is connected." -ForegroundColor Yellow
        Read-Host "Press Enter to exit..."
        exit
    }

    Write-Host "  Found ISO: $($bestIso.FullName) ($([math]::Round($bestIso.Length/1GB, 2)) GB)" -ForegroundColor Green
    Write-Host "  Mounting ISO to extract files to local SSD..." -ForegroundColor Cyan
    $m = Mount-DiskImage -ImagePath $bestIso.FullName -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 2
    $isoVol = $m | Get-Volume -ErrorAction SilentlyContinue
    $isoLetter = $isoVol.DriveLetter

    if (-not $isoLetter) {
        Write-Host "`n[ERROR] Failed to obtain drive letter for mounted ISO." -ForegroundColor Red
        exit
    }

    Write-Host "  Fast-copying setup media to $targetStage (this takes ~60-90 seconds)..." -ForegroundColor Cyan
    if (-not (Test-Path $targetStage)) { New-Item -ItemType Directory -Path $targetStage -Force | Out-Null }
    
    # Use Robocopy with multi-threading for maximum SSD write speed
    $rc = cmd.exe /c "robocopy `"${isoLetter}:\`" `"$targetStage`" /E /MT:8 /R:1 /W:1 /XD `"`$RECYCLE.BIN`" `"System Volume Information`" 2>&1"
    
    Write-Host "  Dismounting temporary ISO image..." -ForegroundColor Gray
    Dismount-DiskImage -ImagePath $bestIso.FullName -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  [OK] Extraction complete." -ForegroundColor Green
}

# 3. Neutralize appraiserres.dll on the Local Writable SSD
Write-Host "`n[3/5] Neutralizing appraiserres.dll on local SSD (Rufus 0-Byte Technique)..." -ForegroundColor Yellow
try {
    if (Test-Path $appraiserDll) {
        cmd.exe /c "attrib -h -s -r `"$appraiserDll`" 2>&1" | Out-Null
        Remove-Item -Path $appraiserDll -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllBytes($appraiserDll, @())
    cmd.exe /c "attrib +r `"$appraiserDll`" 2>&1" | Out-Null
    Write-Host "  [OK] Writable appraiserres.dll replaced with 0-byte stub and locked read-only." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Appraiser notice: $_" -ForegroundColor Yellow
}

# 4. Pre-Stage $WINDOWS.~BT and Install AveYo IFEO Fallback Hook
Write-Host "[4/5] Staging setup cache stubs and AveYo IFEO kernel hook..." -ForegroundColor Yellow
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
    
    # Scripts\get11.cmd
    $scriptsDir = "$env:SystemDrive\Scripts"
    if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
    $get11 = Join-Path $scriptsDir "get11.cmd"
    $get11Content = @"
@echo off
set CLI=%*& set SOURCES=%SystemDrive%\`$WINDOWS.~BT\Sources
if exist %SOURCES%\appraiserres.dll del /f /q %SOURCES%\appraiserres.dll 2>nul
cd.>%SOURCES%\appraiserres.dll
attrib +r %SOURCES%\appraiserres.dll 2>nul
if not exist %SOURCES%\WindowsUpdateBox.exe mklink /h %SOURCES%\WindowsUpdateBox.exe %SOURCES%\SetupHost.exe
%SOURCES%\WindowsUpdateBox.exe %CLI%
exit /b
"@
    [System.IO.File]::WriteAllText($get11, $get11Content, [System.Text.Encoding]::ASCII)
    
    $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe"
    if (-not (Test-Path $ifeoKey)) { New-Item -Path $ifeoKey -Force | Out-Null }
    Set-ItemProperty -Path $ifeoKey -Name "UseFilter" -Value 1 -Type DWord -Force
    $ifeoSubKey = Join-Path $ifeoKey "0"
    if (-not (Test-Path $ifeoSubKey)) { New-Item -Path $ifeoSubKey -Force | Out-Null }
    Set-ItemProperty -Path $ifeoSubKey -Name "FilterFullPath" -Value "$env:SystemDrive\`$WINDOWS.~BT\Sources\SetupHost.exe" -Force
    Set-ItemProperty -Path $ifeoSubKey -Name "Debugger" -Value "$env:SystemDrive\Scripts\get11.cmd" -Force
    
    Write-Host "  [OK] Kernel IFEO hook and cache stub armed." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Pre-stage notice: $_" -ForegroundColor Yellow
}

# 5. Launch Setup from Local SSD
Write-Host "`n[5/5] Launching Windows 11 Setup from Local SSD..." -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
Write-Host "  Executable: $setupExe" -ForegroundColor Green
Write-Host "  Active Safeguards:" -ForegroundColor Green
Write-Host "    - 0-Byte appraiserres.dll (Hard-blocks TPM 2.0 & Secure Boot checks)" -ForegroundColor Green
Write-Host "    - MoSetup: AllowUpgradesWithUnsupportedTPMOrCPU = 1" -ForegroundColor Green
Write-Host "    - LabConfig: BypassTPMCheck, BypassSecureBootCheck, BypassCPUCheck" -ForegroundColor Green
Write-Host "    - /DynamicUpdate Disable (prevents driver rollback crashes)" -ForegroundColor Green
Write-Host "==============================================================================`n" -ForegroundColor Green

Write-Host "Launching Setup..." -ForegroundColor Cyan
Start-Process -FilePath $setupExe -ArgumentList "/DynamicUpdate Disable /Compat IgnoreWarning"
Write-Host "Setup has been initiated. Follow the prompts on screen." -ForegroundColor Green
Write-Host "Choose: 'Keep personal files and apps'." -ForegroundColor Green
Start-Sleep -Seconds 3
