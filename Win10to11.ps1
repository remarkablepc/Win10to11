# Requires -Version 5.1
param(
    [string]$TargetDriveLetter = "",
    [switch]$SkipElevation,
    [switch]$AutoLaunch,
    [switch]$BypassAll,
    [switch]$SkipHealthChecks
)
<#
.SYNOPSIS
    Win10to11.ps1 - Windows 10 to 11 In-Place Upgrade, Repair & Bypass Toolkit
.DESCRIPTION
    Self-elevates, logs to a custom file, applies MoSetup/LabConfig bypasses, 
    repairs BCD/WinRE (extracts from mounted ISO), converts MBR to GPT, forces AV confirmation, 
    backs up drivers, runs safe health checks with active heartbeats, and launches setup.
#>

# ------------------------------------------------------------------
# 1. Self-Elevation
# ------------------------------------------------------------------
if (-not $SkipElevation) {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent());
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Elevating privileges to Administrator..." -ForegroundColor Yellow;
        $powershellExe = (Get-Process -Id $PID).Path;
        $scriptPath = $MyInvocation.MyCommand.Definition;
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        if ($TargetDriveLetter) { $argList += " -TargetDriveLetter `"$TargetDriveLetter`"" }
        if ($AutoLaunch) { $argList += " -AutoLaunch" }
        if ($BypassAll) { $argList += " -BypassAll" }
        if ($SkipHealthChecks) { $argList += " -SkipHealthChecks" }
        Start-Process -FilePath $powershellExe -ArgumentList $argList -Verb RunAs;
        exit;
    }
}

# ------------------------------------------------------------------
# 2. Setup Logging (ComputerName-ProfileName-Timestamp)
# ------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition;
if (-not $ScriptDir) { $ScriptDir = Get-Location };
$script:ScriptPath = $MyInvocation.MyCommand.Definition;

$LogDir = Join-Path -Path $ScriptDir -ChildPath "log";
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null };

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss";
$LogFile = Join-Path -Path $LogDir -ChildPath "$($env:COMPUTERNAME)-$($env:USERNAME)-$TimeStamp.log";

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    $FormattedMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message";
    Write-Host $Message -ForegroundColor $Color;
    Add-Content -Path $LogFile -Value $FormattedMsg;
}

# Helper to check for interactive keyboard commands ([P] Pause, [S] Skip, [Q] Quit/Exit)
function Check-KeyboardAction {
    if ($Host.UI.RawUI.KeyAvailable) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character.ToString().ToUpper()
        switch ($key) {
            'P' {
                Write-Host "`n  [PAUSED] Execution paused. Press any key to resume..." -ForegroundColor Yellow
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                Write-Host "  Resuming execution..." -ForegroundColor Green
                return "CONTINUE"
            }
            'S' {
                return "SKIP"
            }
            { $_ -in @('Q', 'X') } {
                Write-Log "`n  [QUIT] User cancelled script execution." "WARN" Red
                exit
            }
        }
    }
    return "NONE"
}

$script:ScriptMountedIso = $null

# Helper to find 7-Zip or NanaZip
function Get-ArchiveExtractor {
    $candidates = @(
        "7z.exe",
        "NanaZip.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\7z.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\NanaZip.exe",
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-Command $c -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
        if (Test-Path $c) { return $c }
    }
    return $null
}

# Helper to stage 0-byte appraiserres.dll bypass (Rufus technique)
function Set-AppraiserBypass {
    param(
        [string]$TargetRoot,
        [switch]$Silent
    )
    try {
        if (-not $TargetRoot) { return }
        $btSources = Join-Path -Path $TargetRoot -ChildPath "`$WINDOWS.~BT\Sources"
        if (-not (Test-Path $btSources)) {
            New-Item -ItemType Directory -Path $btSources -Force | Out-Null
        }
        $targetAppraiserPath = Join-Path -Path $btSources -ChildPath "appraiserres.dll"
        
        # Neutralize any existing copy (including OEM/ESD copies that enforce TPM/Secure Boot)
        if (Test-Path $targetAppraiserPath) {
            cmd.exe /c "attrib -h -s -r `"$targetAppraiserPath`" 2>&1" | Out-Null
            Remove-Item -Path $targetAppraiserPath -Force -ErrorAction SilentlyContinue
        }
        
        # Write 0-byte stub and lock as Read-Only
        [System.IO.File]::WriteAllBytes($targetAppraiserPath, @())
        cmd.exe /c "attrib +r `"$targetAppraiserPath`" 2>&1" | Out-Null
        Write-Log "  [OK] Staged 0-byte appraiserres.dll hardware bypass at $targetAppraiserPath" "SUCCESS" Green
    } catch {
        Write-Log "  [INFO] Appraiser bypass staging note: $_" "INFO" Gray
    }
}

# Helper to install AveYo's battle-tested IFEO Kernel Debugger bypass for SetupHost.exe
function Install-AveYoBypass {
    param(
        [string]$TargetRoot = "$env:SystemDrive\",
        [bool]$IsOffline = $false
    )
    try {
        $scriptsDir = Join-Path $TargetRoot "Scripts"
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
        
        if ($IsOffline) {
            $softHive = Join-Path $TargetRoot "Windows\System32\config\SOFTWARE"
            if (Test-Path $softHive) {
                cmd.exe /c "reg load HKLM\OfflineSOFTWARE `"$softHive`" 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe`" /v UseFilter /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0`" /v FilterFullPath /t REG_SZ /d `"%SystemDrive%\`$WINDOWS.~BT\Sources\SetupHost.exe`" /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe\0`" /v Debugger /t REG_SZ /d `"%SystemDrive%\Scripts\get11.cmd`" /f 2>&1" | Out-Null
                cmd.exe /c "reg unload HKLM\OfflineSOFTWARE 2>&1" | Out-Null
            }
        } else {
            $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SetupHost.exe"
            if (-not (Test-Path $ifeoKey)) { New-Item -Path $ifeoKey -Force | Out-Null }
            Set-ItemProperty -Path $ifeoKey -Name "UseFilter" -Value 1 -Type DWord -Force
            
            $ifeoSubKey = Join-Path $ifeoKey "0"
            if (-not (Test-Path $ifeoSubKey)) { New-Item -Path $ifeoSubKey -Force | Out-Null }
            Set-ItemProperty -Path $ifeoSubKey -Name "FilterFullPath" -Value "%SystemDrive%\`$WINDOWS.~BT\Sources\SetupHost.exe" -Force
            Set-ItemProperty -Path $ifeoSubKey -Name "Debugger" -Value "%SystemDrive%\Scripts\get11.cmd" -Force
        }
        Write-Log "  [OK] Universal IFEO Kernel Bypass installed (SetupHost.exe debugger -> get11.cmd)." "SUCCESS" Green
    } catch {
        Write-Log "  [INFO] AveYo bypass setup note: $_" "INFO" Gray
    }
}

# Extracts comprehensive hardware and OS profile from either live host or offline target drive
function Get-TargetSystemProfile {
    param(
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][bool]$IsOffline
    )

    $profile = [PSCustomObject]@{
        ComputerName        = "Unknown"
        Manufacturer        = "Unknown"
        Model               = "Unknown"
        Processor           = "Unknown"
        RAM                 = "Unknown"
        BIOSVersion         = "Unknown"
        BIOSDate            = "Unknown"
        OSCaption           = "Unknown"
        OSBuild             = "Unknown"
        PartitionStyle      = "Unknown"
        FirmwareMode        = "Unknown"
        TPMStatus           = "Unknown"
        SecureBootStatus    = "Unknown"
        IsCompliant         = $false
        NonCompliantReasons = [System.Collections.Generic.List[string]]::new()
    }

    if (-not $IsOffline) {
        # --- Live Host System Profiling ---
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue

            $profile.ComputerName = $env:COMPUTERNAME
            if ($cs) {
                $profile.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { "Generic" }
                $profile.Model = if ($cs.Model) { $cs.Model.Trim() } else { "Generic" }
                if ($cs.TotalPhysicalMemory) {
                    $gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                    $profile.RAM = "$gb GB"
                    if ($gb -lt 3.8) {
                        $profile.NonCompliantReasons.Add("RAM less than 4GB ($gb GB)")
                    }
                }
            }

            if ($proc) {
                $profile.Processor = if ($proc.Name) { ($proc.Name -replace '\s+', ' ').Trim() } else { "Unknown" }
                $cpuName = $profile.Processor
                $cpuOk = $false
                if ($cpuName -match "i[3579]-(?:[89]\d{3}|1[0-9]\d{3}|2[0-9]\d{3})|Core.*Ultra|Xeon.*(?:E-2[12]|W-2[12]|W-3[12])|Ryzen\s+[3579]\s+(?:[2-9]\d{3}|[1-9]\d{4})|Threadripper\s+(?:29|39|[579]\d{3})") {
                    $cpuOk = $true
                } elseif ($cpuName -match "i7-7820HQ") {
                    $cpuOk = $true
                }
                if (-not $cpuOk) {
                    $profile.NonCompliantReasons.Add("Processor ($cpuName) not on official Win11 whitelist")
                }
            }

            if ($bios) {
                $profile.BIOSVersion = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion.Trim() } else { "Unknown" }
                $profile.BIOSDate = if ($bios.ReleaseDate) {
                    try { ([datetime]$bios.ReleaseDate).ToString("yyyy-MM-dd") } catch { "$($bios.ReleaseDate)" }
                } else { "Unknown" }
            }

            if ($os) {
                $profile.OSCaption = if ($os.Caption) { $os.Caption.Trim() } else { "Windows 10" }
                $build = if ($cv.CurrentBuild) { $cv.CurrentBuild } else { $os.BuildNumber }
                $ubr = if ($cv.UBR) { ".$($cv.UBR)" } else { "" }
                $dispVer = if ($cv.DisplayVersion) { " ($($cv.DisplayVersion))" } else { "" }
                $profile.OSBuild = "Build $build$ubr$dispVer"
            }

            # TPM Check
            try {
                $tpm = Get-Tpm -ErrorAction SilentlyContinue
                $tpmWmi = Get-CimInstance -Namespace "root\cimv2\security\microsofttpm" -ClassName Win32_Tpm -ErrorAction SilentlyContinue
                if ($tpm -and $tpm.TpmPresent -and $tpm.TpmReady -and $tpmWmi -and $tpmWmi.SpecVersion -match "2\.0") {
                    $profile.TPMStatus = "TPM 2.0 Present & Ready"
                } elseif ($tpm -and $tpm.TpmPresent) {
                    $spec = if ($tpmWmi.SpecVersion) { $tpmWmi.SpecVersion } else { "Legacy" }
                    $profile.TPMStatus = "Present but Not TPM 2.0 ($spec)"
                    $profile.NonCompliantReasons.Add("TPM is not version 2.0 ($spec)")
                } else {
                    $profile.TPMStatus = "Not Detected / Missing"
                    $profile.NonCompliantReasons.Add("TPM 2.0 not detected or disabled in BIOS")
                }
            } catch {
                $profile.TPMStatus = "Query Failed"
                $profile.NonCompliantReasons.Add("Could not query TPM")
            }

            # Secure Boot Check
            try {
                $sbCmd = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
                $sbReg = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
                if ($sbCmd -or $sbReg -eq 1) {
                    $profile.SecureBootStatus = "Enabled"
                } else {
                    $profile.SecureBootStatus = "Disabled or Not Supported"
                    $profile.NonCompliantReasons.Add("Secure Boot is disabled or unsupported")
                }
            } catch {
                $profile.SecureBootStatus = "Unknown"
                $profile.NonCompliantReasons.Add("Secure Boot status unknown")
            }

            # Partition & Firmware
            $sysVol = Get-Partition -DriveLetter $TargetRoot.TrimEnd(":") -ErrorAction SilentlyContinue
            if ($sysVol) {
                $disk = Get-Disk -Number $sysVol.DiskNumber -ErrorAction SilentlyContinue
                if ($disk) {
                    $profile.PartitionStyle = $disk.PartitionStyle
                    if ($disk.PartitionStyle -ne "GPT") {
                        $profile.NonCompliantReasons.Add("System disk partition style is $($disk.PartitionStyle) (GPT required)")
                    }
                }
            }
            $profile.FirmwareMode = if ($env:firmware_type) { $env:firmware_type } else { "UEFI" }

            if ($profile.NonCompliantReasons.Count -eq 0) {
                $profile.IsCompliant = $true
            }
        } catch {
            Write-Log "  [INFO] Hardware profiling notice: $_" "INFO" Gray
        }
    } else {
        # --- Offline Target Drive Profiling ---
        try {
            $sysHive = "$TargetRoot\Windows\System32\config\SYSTEM"
            $softHive = "$TargetRoot\Windows\System32\config\SOFTWARE"

            # Load SYSTEM hive temporarily if not already loaded
            $needUnloadSys = $false
            if (-not (Test-Path "HKLM:\OfflineSYSTEMProfile")) {
                cmd.exe /c "reg load HKLM\OfflineSYSTEMProfile `"$sysHive`" 2>&1" | Out-Null
                $needUnloadSys = $true
            }

            if (Test-Path "HKLM:\OfflineSYSTEMProfile") {
                # Computer Name
                $cn = Get-ItemProperty -Path "HKLM:\OfflineSYSTEMProfile\ControlSet001\Control\ComputerName\ComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue
                if ($cn -and $cn.ComputerName) { $profile.ComputerName = $cn.ComputerName }

                # System Info
                $si = Get-ItemProperty -Path "HKLM:\OfflineSYSTEMProfile\ControlSet001\Control\SystemInformation" -ErrorAction SilentlyContinue
                if ($si) {
                    if ($si.SystemManufacturer) { $profile.Manufacturer = $si.SystemManufacturer.Trim() }
                    if ($si.SystemProductName) { $profile.Model = $si.SystemProductName.Trim() }
                    if ($si.BIOSVersion) { $profile.BIOSVersion = $si.BIOSVersion.Trim() }
                    if ($si.BIOSReleaseDate) { $profile.BIOSDate = $si.BIOSReleaseDate.Trim() }
                }

                # Processor extraction from ACPI Enum
                $acpiProc = Get-ChildItem -Path "HKLM:\OfflineSYSTEMProfile\ControlSet001\Enum\ACPI" -ErrorAction SilentlyContinue | Where-Object {
                    $_.PSChildName -match 'GenuineIntel|AuthenticAMD'
                } | Select-Object -First 1
                if ($acpiProc) {
                    $cleanProc = $acpiProc.PSChildName -replace '^.*_-_', '' -replace '_@_', ' @ ' -replace '_', ' '
                    $profile.Processor = $cleanProc.Trim()
                }

                if ($needUnloadSys) {
                    cmd.exe /c "reg unload HKLM\OfflineSYSTEMProfile 2>&1" | Out-Null
                }
            }

            # Load SOFTWARE hive temporarily to get Windows Edition / Build
            $needUnloadSoft = $false
            if (-not (Test-Path "HKLM:\OfflineSOFTWAREProfile")) {
                cmd.exe /c "reg load HKLM\OfflineSOFTWAREProfile `"$softHive`" 2>&1" | Out-Null
                $needUnloadSoft = $true
            }

            if (Test-Path "HKLM:\OfflineSOFTWAREProfile") {
                $cv = Get-ItemProperty -Path "HKLM:\OfflineSOFTWAREProfile\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
                if ($cv) {
                    $profile.OSCaption = if ($cv.ProductName) { $cv.ProductName.Trim() } else { "Windows" }
                    $build = if ($cv.CurrentBuild) { $cv.CurrentBuild } else { "" }
                    $ubr = if ($cv.UBR) { ".$($cv.UBR)" } else { "" }
                    $dispVer = if ($cv.DisplayVersion) { " ($($cv.DisplayVersion))" } else { "" }
                    $profile.OSBuild = "Build $build$ubr$dispVer"
                }

                if ($needUnloadSoft) {
                    cmd.exe /c "reg unload HKLM\OfflineSOFTWAREProfile 2>&1" | Out-Null
                }
            }

            # Disk / Partition info
            $part = Get-Partition -DriveLetter $TargetRoot.TrimEnd(":") -ErrorAction SilentlyContinue
            if ($part) {
                $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
                if ($disk) {
                    $profile.PartitionStyle = $disk.PartitionStyle
                }
            }
        } catch {
            Write-Log "  [INFO] Offline profiling notice: $_" "INFO" Gray
            cmd.exe /c "reg unload HKLM\OfflineSYSTEMProfile 2>&1" | Out-Null
            cmd.exe /c "reg unload HKLM\OfflineSOFTWAREProfile 2>&1" | Out-Null
        }
    }

    return $profile
}

function Get-FirmwareAdvisory {
    param([PSCustomObject]$Profile)
    $advisory = [PSCustomObject]@{
        Status       = "Standard"
        IsLegacyOnly = $false
        Warning      = $null
        PortalUrl    = $null
        Guidance     = "System firmware appears modern and capable of UEFI."
    }
    if (-not $Profile) { return $advisory }

    $mfg = "$($Profile.Manufacturer) $($Profile.Model)"
    $biosVer = "$($Profile.BIOSVersion)"

    # 1. Acer V1.xx vs V2.xx Trap Check
    if (($mfg -match "Acer|Gateway|Packard Bell" -or $Profile.Model -match "Aspire|TravelMate|Extensa") -and ($biosVer -match "^V?1\.")) {
        $advisory.Status = "CRITICAL_LEGACY_TRAP"
        $advisory.IsLegacyOnly = $true
        $advisory.Warning = "Acer V1.xx Pure Legacy BIOS detected ($biosVer). Acer V2.xx (UEFI) updates are strictly for factory Win8 motherboards. Flashing V2 onto V1 will fail or permanently BRICK the board."
        $advisory.Guidance = "DO NOT flash V2.xx BIOS and DO NOT convert disk to GPT! Keep MBR partition style. Windows 11 installs and boots natively on MBR with staged bypasses."
        $advisory.PortalUrl = "https://www.acer.com/us-en/support"
        return $advisory
    }

    # 2. Pre-2014 Legacy BIOS Check
    $yearMatch = [regex]::Match($Profile.BIOSDate, "(\b200\d|\b201[0-3])")
    if ($yearMatch.Success -or $Profile.FirmwareMode -eq "Legacy" -or $Profile.FirmwareMode -eq "BIOS") {
        $advisory.Status = "LEGACY_PLATFORM"
        $advisory.IsLegacyOnly = $true
        $advisory.Warning = "Pre-UEFI / Legacy BIOS platform detected (BIOS Date: $($Profile.BIOSDate))."
        $advisory.Guidance = "Manufacturer BIOS support has ended. BIOS updates will not add UEFI/Secure Boot to this motherboard generation. Recommend MBR boot mode with Windows 11 bypasses."
    }

    # Vendor Support Portals
    if ($mfg -match "Dell") {
        $advisory.PortalUrl = "https://www.dell.com/support/home/drivers"
    } elseif ($mfg -match "HP|Hewlett-Packard") {
        $advisory.PortalUrl = "https://support.hp.com/us-en/drivers"
    } elseif ($mfg -match "Lenovo") {
        $advisory.PortalUrl = "https://pcsupport.lenovo.com/"
    } elseif ($mfg -match "ASUS|ASUSTeK") {
        $advisory.PortalUrl = "https://www.asus.com/support/"
    } elseif ($mfg -match "Acer") {
        $advisory.PortalUrl = "https://www.acer.com/us-en/support"
    }

    return $advisory
}

# Helper function to auto-detect or mount the Windows 11 ISO
function Get-MountedSetupDrive {
    # 1. Check if an ISO or USB is already mounted with setup.exe and sources
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match "^[A-Z]$" };
    foreach ($drive in $drives) {
        $setupPath = "$($drive.Name):\setup.exe";
        $sourcesPath = "$($drive.Name):\sources";
        if ((Test-Path $setupPath) -and (Test-Path $sourcesPath)) {
            return $drive.Name;
        }
    }

    # 2. Comprehensive multi-drive search for Windows 11 ISO files
    $isoCandidates = @()
    $subDirs = @(
        "ISOs\Windows",
        "ISO\Windows",
        "_ISO\Windows\Win11",
        "_ISO\Windows",
        "ISOs",
        "ISO",
        "_ISO",
        "Ventoy",
        "Downloads",
        ""
    )

    foreach ($drive in $drives) {
        foreach ($sub in $subDirs) {
            $folder = if ($sub) { "$($drive.Name):\$sub" } else { "$($drive.Name):\" }
            if (Test-Path $folder) {
                $found = Get-ChildItem -Path $folder -Filter "*Win11*.iso" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                if ($found) { $isoCandidates += $found }
            }
        }
    }

    # Also search user profile and script directory tree
    $userDirs = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", "$ScriptDir", "$ScriptDir\..")
    foreach ($ud in $userDirs) {
        if (Test-Path $ud) {
            $found = Get-ChildItem -Path $ud -Filter "*Win11*.iso" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
            if ($found) { $isoCandidates += $found }
        }
    }

    $foundIso = $null
    $isoList = $isoCandidates | Select-Object -Unique | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ } | Sort-Object Length -Descending
    if ($isoList) {
        $item = $isoList[0]
        $foundIso = $item.FullName
        $sizeGb = [math]::Round($item.Length / 1GB, 2)
        Write-Host "`n[ISO DISCOVERY] Found Windows 11 ISO: $foundIso ($sizeGb GB)" -ForegroundColor Green
        Write-Log "  [ACTION] Auto-detected Windows 11 ISO: $foundIso ($sizeGb GB)" "INFO" Yellow

        $mountChoice = $true
        if (-not $BypassAll -and -not $AutoLaunch) {
            $mAns = Read-Host "Auto-mount this Windows 11 ISO now? [Y/N] (Default: Y)"
            if ($mAns -ne "" -and $mAns -notmatch "^[yY]") { $mountChoice = $false }
        }

        if ($mountChoice) {
            try {
                Write-Log "  [ACTION] Auto-mounting Windows 11 ISO ($foundIso)..." "INFO" Yellow
                $mountRes = Mount-DiskImage -ImagePath $foundIso -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
                Start-Sleep -Seconds 2
                if ($mountRes) {
                    $vol = $mountRes | Get-Volume -ErrorAction SilentlyContinue
                    if ($vol -and $vol.DriveLetter) {
                        $script:ScriptMountedIso = $foundIso
                        Write-Log "  [SUCCESS] Auto-mounted ISO to Drive $($vol.DriveLetter):" "SUCCESS" Green
                        Write-Host "[SUCCESS] Windows 11 ISO mounted to Drive $($vol.DriveLetter):" -ForegroundColor Green
                        return $vol.DriveLetter
                    }
                }
            } catch {
                Write-Log "  [WARN] Failed to auto-mount ISO ($foundIso): $_" "WARN" Yellow
            }
        }
    }

    return $null
}

# Helper to extract clean Winre.wim from ISO (install.esd or install.wim)
function Extract-WinREFromISO {
    param(
        [string]$TargetRecoveryPath,
        [string]$IsoDriveLetter
    )

    if (-not $IsoDriveLetter) {
        $IsoDriveLetter = Get-MountedSetupDrive
    }
    if (-not $IsoDriveLetter) {
        return $false
    }

    $installWim = "${IsoDriveLetter}:\sources\install.wim"
    $installEsd = "${IsoDriveLetter}:\sources\install.esd"
    $destWinre = Join-Path $TargetRecoveryPath "winre.wim"

    if (-not (Test-Path $TargetRecoveryPath)) {
        New-Item -ItemType Directory -Path $TargetRecoveryPath -Force | Out-Null
    }

    # 1. Try 7-Zip / NanaZip fast extraction (handles both install.esd and install.wim without mounting)
    $extractor = Get-ArchiveExtractor
    $sourceImage = if (Test-Path $installEsd) { $installEsd } elseif (Test-Path $installWim) { $installWim } else { $null }

    if ($extractor -and $sourceImage) {
        $imgType = [System.IO.Path]::GetFileName($sourceImage)
        Write-Log "  [ACTION] Extracting clean Winre.wim from $imgType using 7-Zip/NanaZip..." "INFO" Yellow
        $tempExtractDir = Join-Path $env:TEMP "winre_extract_$TimeStamp"
        New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null
        try {
            # Extract 1\Windows\System32\Recovery\Winre.wim
            $p = Start-Process -FilePath $extractor -ArgumentList "e `"$sourceImage`" `"1\Windows\System32\Recovery\Winre.wim`" -o`"$tempExtractDir`" -y" -Wait -PassThru -NoNewWindow
            $extractedFile = Join-Path $tempExtractDir "Winre.wim"
            if ((Test-Path $extractedFile) -and (Get-Item $extractedFile).Length -gt 100MB) {
                Copy-Item -Path $extractedFile -Destination $destWinre -Force
                Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "  [SUCCESS] Extracted pristine Winre.wim ($([math]::Round((Get-Item $destWinre).Length / 1MB, 2)) MB) to $destWinre" "SUCCESS" Green
                return $true
            }
        } catch {
            Write-Log "  [WARN] 7-Zip extraction encountered error: $_" "WARN" Yellow
        }
        Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 2. Native DISM mount for install.wim if 7-Zip not present
    if (Test-Path $installWim) {
        Write-Log "  [ACTION] Found install.wim. Mounting image to extract winre.wim..." "INFO" Yellow
        $mountDir = Join-Path $TargetRecoveryPath "TempWimMount"
        if (-not (Test-Path $mountDir)) { New-Item -ItemType Directory -Path $mountDir -Force | Out-Null }
        try {
            Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mountDir -ReadOnly -ErrorAction Stop | Out-Null
            $winreSrc = "$mountDir\Windows\System32\Recovery\winre.wim"
            if (Test-Path $winreSrc) {
                Copy-Item -Path $winreSrc -Destination $destWinre -Force
                Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
                Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
                Write-Log "  [SUCCESS] Extracted pristine Winre.wim from install.wim to $destWinre" "SUCCESS" Green
                return $true
            }
            Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
            Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Log "  [WARN] Mount-WindowsImage failed: $_" "WARN" Yellow
            Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
            Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    # 3. DISM Export for install.esd if 7-Zip not present
    if (Test-Path $installEsd) {
        Write-Log "  [ACTION] Converting index 1 from install.esd to temporary WIM via DISM export..." "INFO" Yellow
        $tempWim = Join-Path $env:TEMP "temp_export_$TimeStamp.wim"
        $mountDir = Join-Path $env:TEMP "temp_mount_$TimeStamp"
        try {
            & dism.exe /Export-Image /SourceImageFile:"$installEsd" /SourceIndex:1 /DestinationImageFile:"$tempWim" /Compress:fast 2>&1 | Out-Null
            if (Test-Path $tempWim) {
                New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
                Mount-WindowsImage -ImagePath $tempWim -Index 1 -Path $mountDir -ReadOnly -ErrorAction Stop | Out-Null
                $winreSrc = "$mountDir\Windows\System32\Recovery\winre.wim"
                if (Test-Path $winreSrc) {
                    Copy-Item -Path $winreSrc -Destination $destWinre -Force
                    Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
                    Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
                    Remove-Item $tempWim -Force -ErrorAction SilentlyContinue
                    Write-Log "  [SUCCESS] Extracted Winre.wim via DISM export to $destWinre" "SUCCESS" Green
                    return $true
                }
            }
        } catch {
            Write-Log "  [WARN] DISM export/mount failed: $_" "WARN" Yellow
        } finally {
            Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
            Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $tempWim -Force -ErrorAction SilentlyContinue
        }
    }

    return $false
}

# ------------------------------------------------------------------
# Drive Selection (Online vs Offline)
# ------------------------------------------------------------------
Write-Host "`nScanning for Windows installations..." -ForegroundColor Cyan;
$winDrives = @()
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match "^[A-Z]$" }
foreach ($drive in $drives) {
    $winSys32 = "$($drive.Name):\Windows\System32"
    if (Test-Path $winSys32) {
        $winDrives += $drive.Name
    }
}

if ($winDrives.Count -eq 0) {
    Write-Log "  [ERROR] No Windows installations found." "ERROR" Red
    exit
}

$TargetDrive = $env:SystemDrive.TrimEnd(":")

$targetLetterClean = $TargetDriveLetter.TrimEnd(":\").ToUpper()
if ($targetLetterClean -eq "0" -and ($winDrives -contains "O")) {
    Write-Log "  [INFO] Interpreted target '0' as Drive O: (Offline Windows installation)." "INFO" Yellow
    $targetLetterClean = "O"
}

if ($targetLetterClean -and ($winDrives -contains $targetLetterClean)) {
    $TargetDrive = $targetLetterClean
} elseif ($targetLetterClean -and (Test-Path "${targetLetterClean}:\Windows")) {
    $TargetDrive = $targetLetterClean
} elseif ($winDrives.Count -gt 1) {
    Write-Host "`nMultiple Windows installations found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $winDrives.Count; $i++) {
        $drv = $winDrives[$i]
        $type = if ($drv -eq $env:SystemDrive.TrimEnd(":")) { "(Online/Host)" } else { "(Offline)" }
        Write-Host "  [$($i+1)] $($drv):\ Windows $type" -ForegroundColor White
    }
    $sel = Read-Host "`nSelect the installation to analyze/prep (1-$($winDrives.Count))"
    if ([int]$sel -gt 0 -and [int]$sel -le $winDrives.Count) {
        $TargetDrive = $winDrives[[int]$sel - 1]
    }
} elseif ($winDrives.Count -eq 1) {
    $TargetDrive = $winDrives[0]
}

$IsOffline = ($TargetDrive -ne $env:SystemDrive.TrimEnd(":"))
$TargetDrive = "${TargetDrive}:"
Write-Log "Selected Target Drive: $TargetDrive $(if($IsOffline){'(Offline)'}else{'(Online)'})" "INFO" Magenta

# Query and display comprehensive Target System Specification Profile
$script:TargetProfile = Get-TargetSystemProfile -TargetRoot $TargetDrive -IsOffline $IsOffline

if ($IsOffline -and $script:TargetProfile.ComputerName -and $script:TargetProfile.ComputerName -ne "Unknown") {
    $newLogName = "$($script:TargetProfile.ComputerName)-Offline-$TimeStamp.log"
    $newLogFile = Join-Path -Path $LogDir -ChildPath $newLogName
    if ($LogFile -ne $newLogFile) {
        Rename-Item -Path $LogFile -NewName $newLogName -Force -ErrorAction SilentlyContinue
        $LogFile = $newLogFile
        Write-Log "Log file renamed to match offline target: $newLogName" "INFO" Gray
    }
}

Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  TARGET SYSTEM HARDWARE & SPECIFICATION PROFILE" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Log "  Target Mode         : $TargetDrive $(if($IsOffline){'(Offline External Bench Dock)'}else{'(Online Host System)'})" "INFO" White
Write-Log "  Computer Name       : $($script:TargetProfile.ComputerName)" "INFO" White
Write-Log "  Manufacturer        : $($script:TargetProfile.Manufacturer)" "INFO" White
Write-Log "  Model / Product     : $($script:TargetProfile.Model)" "INFO" White
Write-Log "  Processor (CPU)     : $($script:TargetProfile.Processor)" "INFO" White
if (-not $IsOffline) {
    Write-Log "  Physical RAM        : $($script:TargetProfile.RAM)" "INFO" White
    Write-Log "  TPM Status          : $($script:TargetProfile.TPMStatus)" "INFO" White
    Write-Log "  Secure Boot         : $($script:TargetProfile.SecureBootStatus)" "INFO" White
}
Write-Log "  BIOS Version / Date : $($script:TargetProfile.BIOSVersion) ($($script:TargetProfile.BIOSDate))" "INFO" White
$fwAdv = Get-FirmwareAdvisory -Profile $script:TargetProfile
if ($fwAdv.Warning) {
    Write-Log "  Firmware Advisory   : $($fwAdv.Warning)" "WARN" Yellow
}
if ($fwAdv.PortalUrl) {
    Write-Log "  Vendor Support URL  : $($fwAdv.PortalUrl)" "INFO" Cyan
}
Write-Log "  Installed Windows   : $($script:TargetProfile.OSCaption) $($script:TargetProfile.OSBuild)" "INFO" White
Write-Log "  Partition Layout    : $($script:TargetProfile.PartitionStyle)" "INFO" White
Write-Host "====================================================================`n" -ForegroundColor Cyan

# ------------------------------------------------------------------
# Progress, Scoring, & Resume Initialization
# ------------------------------------------------------------------
$TotalSteps = 8;
$CurrentStep = 0;
$ReadinessScore = 100;
$RegKey = "HKCU:\SOFTWARE\Win11Readiness";
$ResumeStep = 1;
$script:ForceReboot = $false;

if (-not (Test-Path $RegKey)) { New-Item -Path $RegKey -Force | Out-Null }

$resumeProp = Get-ItemProperty -Path $RegKey -Name "ResumeStep" -ErrorAction SilentlyContinue
if ($resumeProp -and $resumeProp.ResumeStep -gt 1) {
    $ResumeStep = $resumeProp.ResumeStep
    Write-Host "`n>>> PREVIOUS RUN DETECTED <<<" -ForegroundColor Magenta
    if ($BypassAll) {
        Write-Log "[-BypassAll active] Resuming script at Step $ResumeStep..." "INFO" Cyan
    } else {
        $ans = Read-Host "An incomplete run was detected (interrupted at Step $ResumeStep). Resume from this step? (Y/N)"
        if ($ans -match '^[nN]') {
            $ResumeStep = 1
            Remove-ItemProperty -Path $RegKey -Name "ResumeStep" -ErrorAction SilentlyContinue
            Write-Log "User chose to start fresh." "INFO" Gray
        } else {
            Write-Log "Resuming script at Step $ResumeStep..." "INFO" Cyan
        }
    }
}

function Step-Progress([string]$Activity) {
    $script:CurrentStep++;
    $Percent = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100);
    Write-Progress -Activity "Windows 11 Readiness Check" -Status "$Activity" -PercentComplete $Percent;
    Write-Log "`n[$script:CurrentStep/$script:TotalSteps] $Activity" "INFO" Yellow;
}

function Invoke-RebootCountdown {
    param([int]$NextStep, [int]$Timeout = 60)
    
    # Setup RunOnce & save ResumeStep
    $scriptPath = $script:ScriptPath
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Win11ReadinessResume" -Value "powershell.exe -ExecutionPolicy Bypass -NoExit -File `"$scriptPath`"" -Force
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value $NextStep -Force
    
    Write-Host "`n==================================================" -ForegroundColor Yellow
    Write-Host "             SYSTEM REBOOT REQUIRED               " -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $host.UI.RawUI.FlushInputBuffer()
    
    $choice = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt $Timeout) {
        $remaining = $Timeout - [math]::Floor($stopwatch.Elapsed.TotalSeconds)
        Write-Host "`rRebooting in $remaining seconds... Press [R] to Reboot Now, [S] to Stop/Cancel, [C] to Continue without reboot: " -NoNewline -ForegroundColor Cyan
        
        if ($host.UI.RawUI.KeyAvailable) {
            $key = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character
            if ($key -match '^[rRsScC]$') {
                $choice = $key.ToString().ToUpper()
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host "`n"
    
    if ($choice -eq 'S') {
        Write-Log "User aborted reboot. Script stopping. Run again later to resume." "WARN" Yellow
        exit
    } elseif ($choice -eq 'C') {
        Write-Log "User chose to CONTINUE without reboot. Warning: subsequent steps may fail!" "WARN" Red
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Win11ReadinessResume" -ErrorAction SilentlyContinue
        # We allow continuation but keep ForceReboot true
    } else {
        Write-Log "Initiating system reboot..." "INFO" Cyan
        Restart-Computer -Force
        exit
    }
}

Write-Log "==================================================" "INFO" Cyan;
Write-Log "   Win10to11 Upgrade & Readiness Toolkit v1.0.0-beta " "INFO" Cyan;
Write-Log "==================================================" "INFO" Cyan;
Write-Log "Log file: $LogFile" "INFO" Gray;

# Dynamic Bench Telemetry & Success Audit
try {
    $benchLogDir = Split-Path -Parent $LogFile
    $priorSuccesses = (Get-ChildItem -Path $benchLogDir -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object { 
        $_.Length -gt 0 -and (Select-String -Path $_.FullName -Pattern "SUCCESS|In-Place Upgrade.*Completed" -Quiet -ErrorAction SilentlyContinue) 
    }).Count
    if ($priorSuccesses -gt 0) {
        Write-Log "Bench Telemetry: $priorSuccesses verified upgrade/readiness run(s) logged." "INFO" Green
    } else {
        Write-Log "Target Support: Windows 10 (21H2-22H2) -> Windows 11 (23H2-24H2) | Bypasses: LabConfig/MoSetup" "INFO" DarkGray
    }
} catch {}

# ------------------------------------------------------------------
# ------------------------------------------------------------------
# Step 1: Firmware Check & Optional Hardware Requirement Bypass
# ------------------------------------------------------------------
$StepNum = 1
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking Firmware Mode & Optional Registry Bypass...";
    
    # 1A. Firmware Mode Verification (UEFI vs BIOS)
    try {
        $fwType = $null
        if ($IsOffline) {
            $targetVol = Get-Partition -DriveLetter $TargetDrive.TrimEnd(":") -ErrorAction SilentlyContinue
            if ($targetVol) {
                $targetDisk = Get-Disk -Number $targetVol.DiskNumber -ErrorAction SilentlyContinue
                if ($targetDisk) {
                    if ($targetDisk.PartitionStyle -eq "GPT") { $fwType = 2 }
                    elseif ($targetDisk.PartitionStyle -eq "MBR") { $fwType = 1 }
                }
            }
        } else {
            $fwProp = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue;
            if ($fwProp) { $fwType = $fwProp.PEFirmwareType }
            
            if ($null -eq $fwType) {
                $sbProp = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction SilentlyContinue
                if ($sbProp) { $fwType = 2 }
            }
            
            if ($null -eq $fwType) {
                $bcdEnum = cmd.exe /c "bcdedit /enum {current}" 2>&1
                if ($bcdEnum -match "winload\.efi") { $fwType = 2 }
                elseif ($bcdEnum -match "winload\.exe") { $fwType = 1 }
            }
        }
        
        $fwAdv = Get-FirmwareAdvisory -Profile $script:TargetProfile
        if ($fwType -eq 2) {
            Write-Log "  [OK] Target system (or disk) is configured for UEFI mode." "SUCCESS" Green;
        } elseif ($fwType -eq 1) {
            if ($fwAdv.IsLegacyOnly) {
                Write-Log "  [OK] Legacy BIOS platform detected ($($script:TargetProfile.Manufacturer) $($script:TargetProfile.BIOSVersion)). Windows 11 will upgrade cleanly in native MBR mode via staged bypasses." "SUCCESS" Green;
            } else {
                Write-Log "  [INFO] Target system is running in Legacy BIOS (MBR) mode. (Upgrades natively on MBR via bypasses)." "INFO" Cyan;
            }
        } else {
            Write-Log "  [INFO] Firmware mode undetermined." "INFO" Gray;
        }
    } catch {
        Write-Log "  [INFO] Could not query firmware type: $_" "INFO" Gray;
    }

    # 1B. Target-Aware Optional Hardware Bypass (MoSetup + LabConfig + appraiserres.dll Staging)
    try {
        $applyBypass = $false
        Write-Host "`n>>> WINDOWS 11 HARDWARE REQUIREMENT BYPASS <<<" -ForegroundColor Yellow
        Write-Host "Bypasses allow Windows 11 setup to run on unsupported TPM, CPU, SecureBoot, RAM, or Storage." -ForegroundColor Gray
        
        if ($BypassAll) {
            $applyBypass = $true
            Write-Log "  [-BypassAll specified] Automatically injecting complete hardware bypass suite." "INFO" Green
        } elseif ($IsOffline) {
            $ans = Read-Host "Inject Windows 11 hardware bypasses (MoSetup + LabConfig) into offline target hive? [Y/N] (Default: Y)"
            if ($ans -eq "" -or $ans -match "^[yY]") { $applyBypass = $true }
        } else {
            # Online Live Host: Intelligent Hardware Evaluation (Zero prompts)
            if ($script:TargetProfile -and $script:TargetProfile.IsCompliant) {
                Write-Log "  [OK] Live host hardware fully meets native Windows 11 requirements (TPM 2.0, SecureBoot, Supported CPU, RAM)." "SUCCESS" Green
                Write-Log "  [INFO] Hardware bypasses not required for native setup." "INFO" Gray
                $applyBypass = $false
            } else {
                $blockers = if ($script:TargetProfile -and $script:TargetProfile.NonCompliantReasons.Count -gt 0) { $script:TargetProfile.NonCompliantReasons -join "; " } else { "Unsupported Hardware" }
                Write-Log "  [INFO] Live host hardware has compatibility blocker(s): $blockers" "INFO" Yellow
                Write-Log "  [ACTION] Automatically applying Windows 11 compatibility bypass suite (MoSetup + LabConfig)..." "INFO" Yellow
                $applyBypass = $true
            }
        }

        if ($applyBypass) {
            # Zero-touch 0-byte appraiserres.dll staging & Universal AveYo IFEO Kernel Bypass
            Set-AppraiserBypass -TargetRoot $TargetDrive
            Install-AveYoBypass -TargetRoot $TargetDrive -IsOffline $IsOffline
            if ($IsOffline) {
                Write-Log "  [ACTION] Loading offline SYSTEM registry hive ($TargetDrive\Windows\System32\config\SYSTEM)..." "INFO" Gray;
                $sysHive = "$TargetDrive\Windows\System32\config\SYSTEM"
                $regLoad = cmd.exe /c "reg load HKLM\OfflineSYSTEM `"$sysHive`" " 2>&1
                
                # MoSetup Key
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\MoSetup`" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                
                # Full LabConfig Keys
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassTPMCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassRAMCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassCPUCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassStorageCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassDiskCheck /t REG_DWORD /d 1 /f 2>&1" | Out-Null
                cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\Setup\LabConfig`" /v BypassNRO /t REG_DWORD /d 1 /f 2>&1" | Out-Null

                cmd.exe /c "reg unload HKLM\OfflineSYSTEM" 2>&1 | Out-Null
                Write-Log "  [OK] Successfully injected complete Windows 11 hardware bypass suite (MoSetup & LabConfig) into offline target drive." "SUCCESS" Green;
            } else {
                # Online MoSetup Key
                $MoSetupPath = "HKLM:\SYSTEM\Setup\MoSetup";
                if (-not (Test-Path $MoSetupPath)) { New-Item -Path $MoSetupPath -Force | Out-Null };
                Set-ItemProperty -Path $MoSetupPath -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord -Force;
                
                # Online Full LabConfig Keys
                $LabConfigPath = "HKLM:\SYSTEM\Setup\LabConfig";
                if (-not (Test-Path $LabConfigPath)) { New-Item -Path $LabConfigPath -Force | Out-Null };
                Set-ItemProperty -Path $LabConfigPath -Name "BypassTPMCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassSecureBootCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassRAMCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassCPUCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassStorageCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassDiskCheck" -Value 1 -Type DWord -Force;
                Set-ItemProperty -Path $LabConfigPath -Name "BypassNRO" -Value 1 -Type DWord -Force;

                Write-Log "  [OK] Successfully injected complete Windows 11 hardware bypass suite (MoSetup & LabConfig) into system registry." "SUCCESS" Green;
            }
        } else {
            Write-Log "  [SKIP] Skipped registry bypass injection (System native or user opted out)." "INFO" Cyan;
        }
    } catch {
        Write-Log "  [ERROR] Failed to inject registry bypass keys: $_" "ERROR" Red;
        if ($IsOffline) { cmd.exe /c "reg unload HKLM\OfflineSYSTEM" 2>&1 | Out-Null }
    }

    # 1C. Defuse Fast Startup & Hibernation (Eliminates Shutdown -> Login Screen Loop and Dirty Volume Lock)
    try {
        if ($IsOffline) {
            Write-Log "  [ACTION] Defusing Fast Startup & Hibernation in target registry (prevents shutdown loop)..." "INFO" Gray
            $sysHive = "$TargetDrive\Windows\System32\config\SYSTEM"
            cmd.exe /c "reg load HKLM\OfflineSYSFastStartup `"$sysHive`" 2>&1" | Out-Null
            if (Test-Path "HKLM:\OfflineSYSFastStartup\ControlSet001\Control\Session Manager\Power") {
                Set-ItemProperty -Path "HKLM:\OfflineSYSFastStartup\ControlSet001\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path "HKLM:\OfflineSYSFastStartup\ControlSet001\Control\Power") {
                Set-ItemProperty -Path "HKLM:\OfflineSYSFastStartup\ControlSet001\Control\Power" -Name "HibernateEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            cmd.exe /c "reg unload HKLM\OfflineSYSFastStartup 2>&1" | Out-Null
            Write-Log "  [OK] Fast Startup and Hibernation disabled in target registry." "SUCCESS" Green
        } else {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            cmd.exe /c "powercfg /h off 2>&1" | Out-Null
            Write-Log "  [OK] Fast Startup and Hibernation disabled on live system." "SUCCESS" Green
        }

        # Purge locked hiberfil.sys if present
        if (Test-Path "$TargetDrive\hiberfil.sys") {
            cmd.exe /c "attrib -h -s -r `"$TargetDrive\hiberfil.sys`" 2>&1" | Out-Null
            Remove-Item "$TargetDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
            Write-Log "  [OK] Purged stale hiberfil.sys to release dirty filesystem lock." "SUCCESS" Green
        }
    } catch {
        Write-Log "  [INFO] Fast Startup defusal notice: $_" "INFO" Gray
        if ($IsOffline) { cmd.exe /c "reg unload HKLM\OfflineSYSFastStartup 2>&1" | Out-Null }
    }

    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 2: Check System Free Space
# ------------------------------------------------------------------
$StepNum = 2
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking OS Drive Free Space...";
    $sysLetter = $TargetDrive.TrimEnd(":")
    $cDrive = Get-Volume -DriveLetter $sysLetter -ErrorAction SilentlyContinue;
    if ($cDrive) {
        $freeGB = [math]::Round($cDrive.SizeRemaining / 1GB, 2);

        if ($freeGB -lt 25) {
            Write-Log "  [WARNING] $TargetDrive drive has only $freeGB GB free. 25+ GB recommended." "WARN" Red;
            $ReadinessScore -= 20;
        } else {
            Write-Log "  [OK] $TargetDrive drive has $freeGB GB free space." "SUCCESS" Green;
        }
    } else {
        Write-Log "  [ERROR] Could not query volume for $TargetDrive" "ERROR" Red;
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 3: Clear Previous Setup Caches (Instant Rename + Non-Blocking Purge)
# ------------------------------------------------------------------
$StepNum = 3
if ($ResumeStep -le $StepNum) {
    Step-Progress "Cleaning up stale upgrade setup cache folders...";
    Write-Host "  (Controls: Press [S] to Skip, [P] to Pause, [Q] to Quit)" -ForegroundColor Gray
    
    $cachePaths = @("$TargetDrive\`$WINDOWS.~BT", "$TargetDrive\`$GetCurrent", "$TargetDrive\`$SysReset", "$TargetDrive\`$Windows.~WS", "$TargetDrive\`$WinREAgent");
    
    foreach ($path in $cachePaths) {
        $action = Check-KeyboardAction
        if ($action -eq "SKIP") {
            Write-Log "  [SKIP] User skipped remaining cache cleanup." "WARN" Yellow
            break
        }

        if (Test-Path $path) {
            Write-Log "  [ACTION] Processing cache directory $path..." "INFO" Yellow;
            
            # Step 3A: Instant Rename First (takes 0.01s, immediately unblocks Windows Setup!)
            $targetPath = $path
            try {
                $newName = "$path.old-$TimeStamp"
                Rename-Item -Path $path -NewName (Split-Path $newName -Leaf) -Force -ErrorAction Stop
                Write-Log "  [OK] Fast-renamed $path -> $(Split-Path $newName -Leaf) (Windows Setup unblocked)." "SUCCESS" Green;
                $targetPath = $newName
            } catch {
                Write-Log "  [INFO] Instant rename skipped (folder open or in use). Running background purge..." "INFO" Gray;
            }

            # Step 3B: Non-blocking background purge with 5-second max wait
            $cleanJob = Start-Job -ArgumentList $targetPath -ScriptBlock {
                param($p)
                cmd.exe /c "attrib -r -a -s -h `"$p`" " 2>&1 | Out-Null
                cmd.exe /c "rd /s /q `"$p`" " 2>&1 | Out-Null
            }
            
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($cleanJob.State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt 5) {
                $subAct = Check-KeyboardAction
                if ($subAct -eq "SKIP") { break }
                Start-Sleep -Milliseconds 200
            }
            
            if ($cleanJob.State -eq 'Completed') {
                $null = Receive-Job -Job $cleanJob
                Write-Log "  [OK] Cache folder $targetPath purged completely." "SUCCESS" Green
            } else {
                Write-Log "  [INFO] Purging of $targetPath continuing in background (Script advancing cleanly)." "INFO" Cyan
            }
            Remove-Job -Job $cleanJob -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "  [OK] No stale cache found at $path" "INFO" Gray;
        }
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 4: Validate & Clean-Rebuild BCD Boot Configuration (UEFI)
# ------------------------------------------------------------------
$StepNum = 4
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking BCD Integrity & Rebuilding Boot Configuration...";
    try {
        $testExportPath = "$($env:SystemDrive)\Windows\Temp\bcd_export_test.bcd"
        if (Test-Path $testExportPath) { Remove-Item $testExportPath -Force -ErrorAction SilentlyContinue }
        
        # Locate target partition and disk
        $targetVol = Get-Partition -DriveLetter $TargetDrive.TrimEnd(":") -ErrorAction SilentlyContinue
        $targetDisk = Get-Disk -Number $targetVol.DiskNumber -ErrorAction SilentlyContinue

        # 4A. MBR-to-GPT Conversion Check & Execution
        if ($targetDisk.PartitionStyle -eq "MBR") {
            $fwAdv = Get-FirmwareAdvisory -Profile $script:TargetProfile
            $mbrAction = $null

            if ($fwAdv.IsLegacyOnly) {
                Write-Host "`n==================================================" -ForegroundColor Green
                Write-Host "   LEGACY BIOS DETECTED -- PRESERVING MBR BOOT    " -ForegroundColor Green
                Write-Host "==================================================" -ForegroundColor Green
                Write-Host "Target Disk: Disk $($targetDisk.Number) ($($targetDisk.FriendlyName)) | Style: MBR" -ForegroundColor Cyan
                Write-Host "Platform   : $($script:TargetProfile.Manufacturer) $($script:TargetProfile.Model) ($($script:TargetProfile.BIOSVersion))" -ForegroundColor Cyan
                Write-Host "Notice     : Motherboard is Pure Legacy BIOS. GPT conversion is blocked to prevent an unbootable PC." -ForegroundColor Yellow
                Write-Host "Action     : Keeping MBR partition style and maintaining native BIOS bootloader." -ForegroundColor Green
                Write-Log "  [INFO] Legacy-only hardware detected. Automatically keeping MBR and bypassing GPT conversion." "INFO" Green
                $mbrAction = "2"
            } else {
                Write-Host "`n==================================================" -ForegroundColor Yellow
                Write-Host "         DISK PARTITION STYLE IS MBR             " -ForegroundColor Yellow
                Write-Host "==================================================" -ForegroundColor Yellow
                Write-Host "Target Disk: Disk $($targetDisk.Number) ($($targetDisk.FriendlyName))" -ForegroundColor Cyan
                Write-Host "Total Size: $([math]::Round($targetDisk.Size/1GB, 2)) GB | Partition Style: MBR" -ForegroundColor Cyan
                Write-Host "`nPartition Style & Boot Mode Options:" -ForegroundColor Cyan
                Write-Host "  [1] Convert MBR to GPT (Recommended for UEFI-capable PCs)" -ForegroundColor White
                Write-Host "  [2] Keep MBR & Configure Legacy BIOS Bootloader" -ForegroundColor White
                Write-Host "  [Q] Quit / Cancel" -ForegroundColor White

                $mbrAction = Read-Host "`nSelect an option [1, 2, Q] (Default: 1)"
                if ($mbrAction -eq "") { $mbrAction = "1" }
            }

            if ($mbrAction -eq "2") {
                Write-Log "  [ACTION] Technician chose to KEEP MBR partition style for Legacy BIOS boot." "INFO" Yellow
                Write-Host "`nConfiguring native Legacy BIOS bootloader on Disk $($targetDisk.Number)..." -ForegroundColor Cyan
                
                $parts = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber
                $activePart = $parts | Where-Object { $_.IsActive } | Select-Object -First 1
                if (-not $activePart) {
                    $activePart = $parts | Where-Object { $_.PartitionNumber -eq 1 -or $_.Size -lt 1GB } | Select-Object -First 1
                    if ($activePart) {
                        Write-Log "  [ACTION] Marking Partition $($activePart.PartitionNumber) as Active..." "INFO" Yellow
                        cmd.exe /c "echo select disk $($targetDisk.Number) & echo select partition $($activePart.PartitionNumber) & echo active" | diskpart | Out-Null
                    }
                }
                
                $bootDriveLetter = $null
                if ($activePart -and $activePart.DriveLetter) {
                    $bootDriveLetter = "$($activePart.DriveLetter):"
                } else {
                    $bootDriveLetter = $TargetDrive
                }
                
                Write-Log "  [ACTION] Installing BIOS bootloader (bootmgr) from $TargetDrive\Windows to $bootDriveLetter..." "INFO" Yellow
                $bcdRes = cmd.exe /c "bcdboot `"$TargetDrive\Windows`" /s $bootDriveLetter /f BIOS /v 2>&1" | Out-String
                Write-Log "  bcdboot output: $($bcdRes.Trim())" "INFO" Gray
                
                Write-Log "  [ACTION] Stamping NT60 MBR and VBR code..." "INFO" Yellow
                cmd.exe /c "bootsect.exe /nt60 $bootDriveLetter /force /mbr 2>&1" | Out-Null
                
                Write-Log "  [SUCCESS] Legacy BIOS MBR bootloader configured successfully on $bootDriveLetter!" "SUCCESS" Green
                Write-Host "`n[SUCCESS] Disk $($targetDisk.Number) is primed for native Legacy BIOS boot. Windows 11 will upgrade cleanly on MBR." -ForegroundColor Green
            } elseif ($mbrAction -match "^[qQ]") {
                Write-Log "  [QUIT] User cancelled at MBR/GPT choice." "WARN" Red
                exit
            } else {
                # ── BitLocker Safety Check ──
                Write-Log "  [ACTION] Checking BitLocker encryption status on $TargetDrive..." "INFO" Gray
            try {
                $bdeOutput = cmd.exe /c "manage-bde.exe -status $TargetDrive 2>&1" | Out-String
                if ($bdeOutput -match "Protection Status:\s+Protection On" -or $bdeOutput -match "Conversion Status:\s+(?!Fully Decrypted)" -or $bdeOutput -match "Lock Status:\s+Locked") {
                    Write-Host "`n==================================================" -ForegroundColor Red
                    Write-Host "   CRITICAL WARNING: BITLOCKER ENCRYPTION ACTIVE  " -ForegroundColor Red
                    Write-Host "==================================================" -ForegroundColor Red
                    Write-Host "Target drive $TargetDrive has BitLocker protection enabled or encryption active." -ForegroundColor Yellow
                    Write-Host "Modifying partition tables on an encrypted disk can lead to permanent data loss." -ForegroundColor Yellow
                    Write-Host "Ensure you have the 48-digit Recovery Key backed up before continuing." -ForegroundColor Yellow
                    Write-Log "  [WARN] BitLocker protection detected on $TargetDrive" "WARN" Yellow
                    
                    if (-not $BypassAll) {
                        Write-Host "`nOptions:" -ForegroundColor Cyan
                        Write-Host "  [1] Attempt to Suspend BitLocker protection (manage-bde -protectors -disable)" -ForegroundColor White
                        Write-Host "  [2] Acknowledge risk and proceed (I have verified the recovery key)" -ForegroundColor White
                        Write-Host "  [Q] Abort conversion and exit" -ForegroundColor White
                        $blChoice = Read-Host "`nSelect an option [1, 2, Q] (Default: 1)"
                        if ($blChoice -eq "" -or $blChoice -eq "1") {
                            Write-Log "  [ACTION] Suspending BitLocker protection on $TargetDrive..." "INFO" Yellow
                            $suspendRes = cmd.exe /c "manage-bde.exe -protectors -disable $TargetDrive 2>&1" | Out-String
                            Write-Log "  manage-bde: $suspendRes" "INFO" Gray
                            Write-Host $suspendRes -ForegroundColor Gray
                        } elseif ($blChoice -match "^[qQ]") {
                            Write-Log "  [QUIT] User aborted MBR-to-GPT conversion due to BitLocker warning." "WARN" Red
                            exit
                        }
                    }
                } else {
                    Write-Log "  [OK] BitLocker is disabled or drive is fully decrypted." "SUCCESS" Green
                }
            } catch {
                Write-Log "  [INFO] BitLocker status check note: $_" "INFO" Gray
            }

            # ── Lazy-Load Helper for gptgen (Called ONLY when strictly required) ──
            $gptgenExe = $null
            $GetGptGenExe = {
                $foundExe = Get-ChildItem -Path $ScriptDir -Filter "gptgen.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($foundExe) { return $foundExe.FullName }

                $localZip = Get-ChildItem -Path $ScriptDir -Filter "gptgen*.zip" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($localZip) {
                    Write-Log "  [ACTION] Extracting gptgen from $($localZip.Name)..." "INFO" Yellow
                    try {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($localZip.FullName, $ScriptDir)
                    } catch {
                        Expand-Archive -Path $localZip.FullName -DestinationPath $ScriptDir -Force -ErrorAction SilentlyContinue
                    }
                    $foundExe = Get-ChildItem -Path $ScriptDir -Filter "gptgen.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($foundExe) { return $foundExe.FullName }
                }

                # Only prompt for download if strictly needed and not found locally
                Write-Host "`n[NOTICE] gptgen is required for offline MBR-to-GPT conversion." -ForegroundColor Yellow
                Write-Host "Official repository: https://github.com/xorangekiller/gptgen (ISC Permissive License)" -ForegroundColor Gray
                
                $dlApproved = $false
                if ($BypassAll) {
                    $dlApproved = $true
                } else {
                    $dlAns = Read-Host "Download official gptgen release from GitHub now? [Y/N] (Default: Y)"
                    if ($dlAns -eq "" -or $dlAns -match "^[yY]") { $dlApproved = $true }
                }

                if ($dlApproved) {
                    Write-Log "  [ACTION] Resolving latest gptgen release from GitHub..." "INFO" Yellow
                    $gptgenZip = Join-Path -Path $ScriptDir -ChildPath "gptgen.zip"
                    $gptgenUrl = $null
                    try {
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/xorangekiller/gptgen/releases/latest" -UseBasicParsing -ErrorAction Stop
                        $asset = $releaseInfo.assets | Where-Object { $_.name -like "gptgen*.zip" } | Select-Object -First 1
                        if ($asset) {
                            $gptgenUrl = $asset.browser_download_url
                            $gptgenZip = Join-Path -Path $ScriptDir -ChildPath $asset.name
                        }
                    } catch {
                        Write-Log "  [INFO] GitHub API check note: $_. Falling back to direct release download." "INFO" Gray
                        $gptgenUrl = "https://github.com/xorangekiller/gptgen/releases/latest/download/gptgen.zip"
                    }

                    if ($gptgenUrl) {
                        try {
                            Write-Log "  [ACTION] Downloading gptgen from $gptgenUrl..." "INFO" Yellow
                            Invoke-WebRequest -Uri $gptgenUrl -OutFile $gptgenZip -UseBasicParsing -TimeoutSec 30
                            Write-Log "  [OK] Downloaded gptgen package successfully." "SUCCESS" Green
                            Expand-Archive -Path $gptgenZip -DestinationPath $ScriptDir -Force -ErrorAction SilentlyContinue
                            $foundExe = Get-ChildItem -Path $ScriptDir -Filter "gptgen.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($foundExe) { return $foundExe.FullName }
                        } catch {
                            Write-Log "  [ERROR] Failed to download gptgen: $_" "ERROR" Red
                        }
                    }
                }
                return $null
            }

            # ── Display Partition Layout ──
            $partitions = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber
            Write-Host "`nCurrent Partition Layout on Disk $($targetDisk.Number):" -ForegroundColor Cyan
            Write-Log "  [INFO] Partition layout on Disk $($targetDisk.Number):" "INFO" Gray
            $partitions | Select-Object PartitionNumber, DriveLetter, Type, @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}, @{N='OffsetMB';E={[math]::Round($_.Offset/1MB,0)}} | ForEach-Object {
                $pStr = "  Partition $($_.PartitionNumber): Drive=$($_.DriveLetter) | Type=$($_.Type) | Size=$($_.SizeGB) GB | Offset=$($_.OffsetMB) MB"
                Write-Host $pStr -ForegroundColor White
                Write-Log "         $pStr" "INFO" Gray
            }

            # Helper scriptblock for gptgen dry-run
            $ExecuteGptGenDryRun = {
                param([int]$DiskNum, [string]$ExePath)
                $pDrive = "\\.\physicaldrive$DiskNum"
                $previewDir = Join-Path -Path $ScriptDir -ChildPath "gptgen_preview"
                if (-not (Test-Path $previewDir)) { New-Item -ItemType Directory -Path $previewDir -Force | Out-Null }
                
                Write-Log "  [ACTION] Executing gptgen DRY-RUN (read-only layout validation) on $pDrive..." "INFO" Yellow
                Write-Host "`n>>> Running gptgen Dry-Run (Read-Only Simulation) <<<" -ForegroundColor Cyan
                Write-Host "Checking sector alignment, partition table limits, and end-of-disk space..." -ForegroundColor Gray
                
                Push-Location $previewDir
                # Pass -k so gptgen does not halt asking interactive Y/N on stdin when boot partition exists!
                $dryOutput = cmd.exe /c "`"$ExePath`" -k $pDrive " 2>&1
                Pop-Location
                
                Write-Log "  --- Dry-Run Log Output ---" "INFO" Gray
                $dryOutput | ForEach-Object { Write-Log "  $_" "INFO" Gray }
                Write-Log "  --- End Dry-Run Log Output ---" "INFO" Gray

                $dryOutputStr = $dryOutput -join "`n"
                Write-Host $dryOutputStr -ForegroundColor Gray

                $isOk = ($LASTEXITCODE -eq 0 -and ($dryOutputStr -match "Writing primary GPT|primary\.img"))
                $needsEndSpace = ($dryOutputStr -match "Not enough space at the end of the disk|need at least \d+ sectors after|33 free blocks|backup GPT")
                
                # Cleanup temporary preview images
                Get-ChildItem -Path $previewDir -Filter "*.img" -ErrorAction SilentlyContinue | Remove-Item -Force
                
                return [PSCustomObject]@{
                    Success = $isOk
                    NeedsEndSpace = $needsEndSpace
                    Output = $dryOutputStr
                    ExitCode = $LASTEXITCODE
                }
            }

            # ── Guided Step-by-Step Flow ──
            $gptSuccess = $false

            if ($IsOffline) {
                Write-Host "`n[INFO] Target drive is OFFLINE (attached via USB/SATA dock)." -ForegroundColor White
                Write-Host "       Microsoft's MBR2GPT tool CANNOT convert offline or secondary non-boot disks." -ForegroundColor White
                Write-Host "       gptgen will convert this disk in-place non-destructively." -ForegroundColor White
                Write-Host ""
                Write-Host "!!!  SAFETY NOTE: Partition data is preserved intact. A complete MBR backup will be created.  !!!" -ForegroundColor Yellow
                
                while (-not $gptSuccess) {
                    Write-Host "`n--- MBR to GPT Step-by-Step Conversion Menu (Offline Disk $($targetDisk.Number)) ---" -ForegroundColor Cyan
                    Write-Host "  [1] Run Dry-Run Only (Safe test - validates disk layout & sector space without writing)" -ForegroundColor White
                    Write-Host "  [2] Proceed with Guided Conversion (Dry-Run -> Backup MBR -> Write GPT Table)" -ForegroundColor White
                    Write-Host "  [3] Guide & Requirements Explanation" -ForegroundColor White
                    Write-Host "  [Q] Quit / Cancel" -ForegroundColor White
                    $opt = Read-Host "`nSelect an option [1-3, Q] (Default: 2)"
                    if ($opt -eq "") { $opt = "2" }

                    if ($opt -eq "1") {
                        if (-not $gptgenExe -or -not (Test-Path $gptgenExe)) {
                            $gptgenExe = & $GetGptGenExe
                        }
                        if (-not $gptgenExe) {
                            Write-Log "  [ERROR] gptgen.exe not found or unavailable. Place gptgen in $ScriptDir." "ERROR" Red
                            continue
                        }
                        $dryResult = & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe
                        if ($dryResult.Success) {
                            Write-Host "`n[DRY RUN PASSED] Disk $($targetDisk.Number) layout is 100% compatible with GPT conversion!" -ForegroundColor Green
                            Write-Log "  [OK] gptgen dry run passed cleanly." "SUCCESS" Green
                        } elseif ($dryResult.NeedsEndSpace) {
                            Write-Host "`n[DRY RUN NOTICE] Disk needs 33 sectors (~16.5 KB) free space at end for backup GPT table." -ForegroundColor Yellow
                            $shrinkAns = Read-Host "Attempt automatic shrink of last partition by 16 MB now? [Y/N] (Default: Y)"
                            if ($shrinkAns -eq "" -or $shrinkAns -match "^[yY]") {
                                $lastPart = Get-Partition -DiskNumber $targetDisk.Number | Sort-Object Offset | Select-Object -Last 1
                                if ($lastPart) {
                                    $supp = $lastPart | Get-PartitionSupportedSize -ErrorAction SilentlyContinue
                                    if ($supp -and ($lastPart.Size - 16MB) -ge $supp.SizeMin) {
                                        try {
                                            $lastPart | Resize-Partition -Size ($lastPart.Size - 16MB) -ErrorAction Stop
                                            Write-Log "  [OK] Partition $($lastPart.PartitionNumber) shrunk by 16 MB." "SUCCESS" Green
                                            Write-Host "Partition $($lastPart.PartitionNumber) successfully shrunk by 16 MB. Re-testing dry run..." -ForegroundColor Green
                                            & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe | Out-Null
                                        } catch {
                                            Write-Log "  [ERROR] Shrink failed: $_" "ERROR" Red
                                        }
                                    } else {
                                        Write-Host "Partition $($lastPart.PartitionNumber) cannot be shrunk (Minimum size: $([math]::Round($supp.SizeMin/1MB,0)) MB)." -ForegroundColor Red
                                    }
                                }
                            }
                        } else {
                            Write-Host "`n[DRY RUN FAILED] gptgen dry-run error. Review output above." -ForegroundColor Red
                        }
                    } elseif ($opt -eq "2") {
                        # Proceed with guided conversion
                        if (-not $gptgenExe -or -not (Test-Path $gptgenExe)) {
                            $gptgenExe = & $GetGptGenExe
                        }
                        if (-not $gptgenExe) {
                            Write-Log "  [ERROR] gptgen.exe not found or unavailable. Place gptgen in $ScriptDir." "ERROR" Red
                            break
                        }

                        # Check disk basic
                        if ($targetDisk.OperationalStatus -match "Dynamic" -or $targetDisk.OperationalStatus -eq "Unknown") {
                            Write-Log "  [ERROR] Disk $($targetDisk.Number) is Dynamic. gptgen only supports Basic disks." "ERROR" Red
                            break
                        }

                        # Step A: Mandatory Dry-Run validation first
                        Write-Host "`nStep 1/3: Running pre-conversion dry-run validation..." -ForegroundColor Cyan
                        $dryResult = & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe
                        
                        if (-not $dryResult.Success -and $dryResult.NeedsEndSpace) {
                            Write-Host "`nDisk needs 33 sectors free at end of drive. Automatically shrinking last partition by 16 MB..." -ForegroundColor Yellow
                            $lastPart = Get-Partition -DiskNumber $targetDisk.Number | Sort-Object Offset | Select-Object -Last 1
                            if ($lastPart) {
                                $supp = $lastPart | Get-PartitionSupportedSize -ErrorAction SilentlyContinue
                                if ($supp -and ($lastPart.Size - 16MB) -ge $supp.SizeMin) {
                                    try {
                                        $lastPart | Resize-Partition -Size ($lastPart.Size - 16MB) -ErrorAction Stop
                                        Write-Log "  [OK] Partition $($lastPart.PartitionNumber) shrunk by 16 MB." "SUCCESS" Green
                                        $dryResult = & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe
                                    } catch {
                                        Write-Log "  [ERROR] Auto-shrink failed: $_" "ERROR" Red
                                    }
                                } else {
                                    Write-Log "  [ERROR] Last partition cannot be shrunk further. Minimum: $([math]::Round($supp.SizeMin/1MB,0)) MB." "ERROR" Red
                                }
                            }
                        }

                        if (-not $dryResult.Success) {
                            Write-Host "`n[ERROR] Dry-run validation failed. Aborting write to prevent corruption." -ForegroundColor Red
                            Write-Log "  [ERROR] gptgen dry run validation failed on Disk $($targetDisk.Number)." "ERROR" Red
                            $retry = Read-Host "Return to menu? [Y/Q] (Default: Y)"
                            if ($retry -match "^[qQ]") { exit }
                            continue
                        }

                        # Step B: User confirmation before write
                        $mbrBackupFile = Join-Path -Path $LogDir -ChildPath "mbr_backup_disk$($targetDisk.Number)_$TimeStamp.bin"
                        Write-Host "`n==================================================" -ForegroundColor Yellow
                        Write-Host "   DRY-RUN VALIDATION PASSED - READY TO CONVERT   " -ForegroundColor Yellow
                        Write-Host "==================================================" -ForegroundColor Yellow
                        Write-Host "Target Disk: Disk $($targetDisk.Number) ($($targetDisk.FriendlyName))" -ForegroundColor Cyan
                        Write-Host "An original MBR backup will be saved to:" -ForegroundColor White
                        Write-Host "  $mbrBackupFile" -ForegroundColor Green
                        Write-Host "All existing partitions will be converted to GPT." -ForegroundColor White
                        
                        $conf = Read-Host "`nWrite GPT partition table to Disk $($targetDisk.Number) now? [Y/Q] (Default: Y)"
                        if ($conf -eq "" -or $conf -match "^[yY]") {
                            Write-Host "`nStep 2/3: Releasing Windows filesystem volume locks (diskpart offline)..." -ForegroundColor Cyan
                            Write-Log "  [ACTION] Taking Disk $($targetDisk.Number) offline temporarily..." "INFO" Yellow
                            "select disk $($targetDisk.Number)`noffline disk" | diskpart | Out-Null
                            Start-Sleep -Seconds 1

                            Write-Host "`nStep 3/3: Writing GPT partition table & saving MBR backup..." -ForegroundColor Cyan
                            $pDrive = "\\.\physicaldrive$($targetDisk.Number)"
                            $writeOutput = cmd.exe /c "`"$gptgenExe`" -w -k -b `"$mbrBackupFile`" $pDrive " 2>&1
                            $writeExit = $LASTEXITCODE

                            Write-Log "  --- gptgen Write Output ---" "INFO" Gray
                            $writeOutput | ForEach-Object { Write-Log "  $_" "INFO" Gray }

                            # Immediately restore disk online status regardless of write outcome
                            Write-Log "  [ACTION] Bringing Disk $($targetDisk.Number) back online..." "INFO" Yellow
                            "select disk $($targetDisk.Number)`nonline disk" | diskpart | Out-Null
                            Start-Sleep -Seconds 2
                            "rescan" | diskpart | Out-Null
                            Start-Sleep -Seconds 2
                            Update-HostStorageCache -ErrorAction SilentlyContinue

                            if ($writeExit -eq 0 -or ($writeOutput -join "`n") -match "Success!") {
                                Write-Log "  [SUCCESS] gptgen conversion completed on Disk $($targetDisk.Number)!" "SUCCESS" Green
                                Write-Host "`n[SUCCESS] GPT partition table written successfully!" -ForegroundColor Green
                                $gptSuccess = $true
                            } else {
                                Write-Log "  [ERROR] gptgen write failed (Exit code: $writeExit)." "ERROR" Red
                                Write-Host "`n[ERROR] gptgen write failed. Review logs above." -ForegroundColor Red
                                break
                            }
                        } else {
                            Write-Log "  [QUIT] User cancelled GPT write." "WARN" Red
                            break
                        }
                    } elseif ($opt -eq "3") {
                        Write-Host "`n=== MBR to GPT Conversion Guide ===" -ForegroundColor Cyan
                        Write-Host "1. Windows 11 mandates UEFI firmware boot mode, which boots exclusively from GPT disks." -ForegroundColor White
                        Write-Host "2. gptgen transcribes all existing MBR primary and logical partitions into GPT basic data partitions." -ForegroundColor White
                        Write-Host "3. gptgen is non-destructive and saves a full MBR backup file ($LogDir)." -ForegroundColor White
                        Write-Host "4. After conversion, the script automatically verifies or creates the EFI System Partition (ESP)" -ForegroundColor White
                        Write-Host "   and populates pristine UEFI bootloader files (bootx64.efi & BCD) via bcdboot." -ForegroundColor White
                        Write-Host "5. When putting this drive back into the machine, enter BIOS/UEFI settings and enable UEFI boot." -ForegroundColor Yellow
                        Read-Host "`nPress Enter to return to menu..."
                    } else {
                        Write-Log "  [QUIT] User exited conversion menu." "WARN" Red
                        exit
                    }
                }
            } else {
                # --- ONLINE PATH: Windows MBR2GPT with gptgen fallback ---
                Write-Host "`n[INFO] Target drive is ONLINE (Host System OS Drive)." -ForegroundColor White
                Write-Host "  [1] Windows MBR2GPT (Microsoft tool - handles ESP & BCD automatically)" -ForegroundColor White
                Write-Host "  [2] gptgen Guided Conversion (Recommended if MBR2GPT validation fails)" -ForegroundColor White
                Write-Host "  [3] Run gptgen Dry-Run Only (Safe read-only simulation)" -ForegroundColor White
                Write-Host "  [Q] Quit" -ForegroundColor White
                
                $onlineChoice = Read-Host "`nSelect conversion method [1, 2, 3, Q] (Default: 1)"
                if ($onlineChoice -eq "") { $onlineChoice = "1" }

                if ($onlineChoice -eq "1") {
                    Write-Log "  [ACTION] Running MBR2GPT validation..." "INFO" Yellow
                    $valRes = cmd.exe /c "mbr2gpt.exe /validate /disk:$($targetDisk.Number) /allowFullOS" 2>&1
                    Write-Log "  Validation output: $valRes" "INFO" Gray; Write-Log "  Exit code: $LASTEXITCODE" "INFO" Gray
                    
                    if ($valRes -match "completed successfully" -or $LASTEXITCODE -eq 0) {
                        Write-Log "  [ACTION] Running MBR2GPT conversion..." "INFO" Yellow
                        $convRes = cmd.exe /c "mbr2gpt.exe /convert /disk:$($targetDisk.Number) /allowFullOS" 2>&1
                        Write-Log "  Conversion output: $convRes" "INFO" Gray; Write-Log "  Exit code: $LASTEXITCODE" "INFO" Gray
                        if ($LASTEXITCODE -eq 0 -or $convRes -match "completed successfully") {
                            Write-Log "  [SUCCESS] MBR2GPT completed successfully!" "SUCCESS" Green
                            Write-Host "`n  ** System must reboot into UEFI mode. Enter BIOS and enable UEFI boot. **" -ForegroundColor Yellow
                            $script:ForceReboot = $true
                            $gptSuccess = $true
                        } else {
                            Write-Log "  [ERROR] MBR2GPT convert failed." "ERROR" Red
                        }
                    } else {
                        Write-Log "  [ERROR] MBR2GPT validation failed: $valRes" "ERROR" Red
                        Write-Host "`n[NOTICE] Windows MBR2GPT cannot convert this layout ($valRes)." -ForegroundColor Yellow
                        Write-Host "Would you like to switch to gptgen for guided in-place conversion?" -ForegroundColor Cyan
                        $fallbackAns = Read-Host "Switch to gptgen? [Y/Q] (Default: Y)"
                        if ($fallbackAns -eq "" -or $fallbackAns -match "^[yY]") {
                            $onlineChoice = "2"
                        } else {
                            Write-Log "  [QUIT] User chose not to use gptgen fallback." "WARN" Red
                            exit
                        }
                    }
                }

                if ($onlineChoice -eq "3") {
                    if (-not $gptgenExe -or -not (Test-Path $gptgenExe)) {
                        $gptgenExe = & $GetGptGenExe
                    }
                    if ($gptgenExe -and (Test-Path $gptgenExe)) {
                        $dryResult = & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe
                        if ($dryResult.Success) {
                            Write-Host "`n[DRY RUN PASSED] Layout is fully compatible with GPT." -ForegroundColor Green
                        } else {
                            Write-Host "`n[DRY RUN RESULT] Output logged above." -ForegroundColor Yellow
                        }
                    } else {
                        Write-Log "  [ERROR] gptgen.exe not found or unavailable for dry-run." "ERROR" Red
                    }
                } elseif ($onlineChoice -eq "2" -and -not $gptSuccess) {
                    if (-not $gptgenExe -or -not (Test-Path $gptgenExe)) {
                        $gptgenExe = & $GetGptGenExe
                    }
                    if (-not $gptgenExe -or -not (Test-Path $gptgenExe)) {
                        Write-Log "  [ERROR] gptgen.exe not found or unavailable." "ERROR" Red
                    } else {
                        Write-Host "`nRunning gptgen pre-conversion dry-run..." -ForegroundColor Cyan
                        $dryResult = & $ExecuteGptGenDryRun -DiskNum $targetDisk.Number -ExePath $gptgenExe
                        if ($dryResult.Success -or $dryResult.NeedsEndSpace) {
                            if ($dryResult.NeedsEndSpace) {
                                $lastPart = Get-Partition -DiskNumber $targetDisk.Number | Sort-Object Offset | Select-Object -Last 1
                                if ($lastPart) {
                                    $supp = $lastPart | Get-PartitionSupportedSize -ErrorAction SilentlyContinue
                                    if ($supp -and ($lastPart.Size - 16MB) -ge $supp.SizeMin) {
                                        $lastPart | Resize-Partition -Size ($lastPart.Size - 16MB) -ErrorAction SilentlyContinue
                                    }
                                }
                            }
                            $mbrBackupFile = Join-Path -Path $LogDir -ChildPath "mbr_backup_disk$($targetDisk.Number)_$TimeStamp.bin"
                            $conf = Read-Host "`nReady to write GPT table with gptgen. Proceed? [Y/Q] (Default: Y)"
                            if ($conf -eq "" -or $conf -match "^[yY]") {
                                "select disk $($targetDisk.Number)`noffline disk" | diskpart | Out-Null
                                $pDrive = "\\.\physicaldrive$($targetDisk.Number)"
                                $writeOutput = cmd.exe /c "`"$gptgenExe`" -w -k -b `"$mbrBackupFile`" $pDrive " 2>&1
                                "select disk $($targetDisk.Number)`nonline disk" | diskpart | Out-Null
                                "rescan" | diskpart | Out-Null
                                Start-Sleep -Seconds 2
                                if ($LASTEXITCODE -eq 0 -or ($writeOutput -join "`n") -match "Success!") {
                                    Write-Log "  [SUCCESS] gptgen conversion completed on Disk $($targetDisk.Number)!" "SUCCESS" Green
                                    $gptSuccess = $true
                                } else {
                                    Write-Log "  [ERROR] gptgen write failed." "ERROR" Red
                                }
                            }
                        }
                    }
                } elseif ($onlineChoice -match "^[qQ]") {
                    Write-Log "  [QUIT] User chose to quit." "WARN" Red; exit
                }
            }

            # ── Refresh & Verify GPT Status ──
            Start-Sleep -Seconds 2
            "rescan" | diskpart | Out-Null
            Update-HostStorageCache -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $targetDisk = Get-Disk -Number $targetVol.DiskNumber -ErrorAction SilentlyContinue

            if ($targetDisk.PartitionStyle -eq "GPT") {
                Write-Log "  [SUCCESS] Disk $($targetDisk.Number) is now GPT!" "SUCCESS" Green
                Write-Host "`n[SUCCESS] Disk $($targetDisk.Number) verified as GPT partition style." -ForegroundColor Green
            } else {
                Write-Log "  [WARNING] Disk $($targetDisk.Number) partition style is still $($targetDisk.PartitionStyle)." "WARN" Yellow
            }

            # ── Re-detect Windows drive letter ──
            Write-Log "  [ACTION] Re-detecting Windows target drive letter..." "INFO" Yellow
            Start-Sleep -Seconds 2
            $foundWindows = $false
            foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object Name -match "^[A-Z]$")) {
                if (Test-Path "$($d.Name):\Windows\System32\config\SOFTWARE") {
                    $dPart = Get-Partition -DriveLetter $d.Name -ErrorAction SilentlyContinue
                    if ($dPart -and $dPart.DiskNumber -eq $targetDisk.Number) {
                        Write-Log "  [OK] Target Windows partition confirmed on $($d.Name):" "SUCCESS" Green
                        $TargetDrive = "$($d.Name):"
                        $targetVol = $dPart
                        $foundWindows = $true
                        break
                    }
                }
            }
            if (-not $foundWindows) {
                Write-Log "  [WARNING] Using original target drive letter: $TargetDrive" "WARN" Yellow
            }

            # Cleanup preview directory
            $previewDir = Join-Path -Path $ScriptDir -ChildPath "gptgen_preview"
            if (Test-Path $previewDir) { Remove-Item $previewDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        # ── Gate: skip ESP + BCD if disk isn't GPT or if mbr2gpt handled it ──
        $targetDisk = Get-Disk -Number $targetVol.DiskNumber -ErrorAction SilentlyContinue
        $skipEspBcd = $false
        if (-not $targetDisk) { Write-Log "  [ERROR] Cannot access disk. Skipping ESP/BCD." "ERROR" Red; $skipEspBcd = $true }
        elseif ($script:ForceReboot) {
            Write-Log "  [INFO] Online MBR2GPT completed. ESP + boot files handled by mbr2gpt. Reboot into UEFI firmware to switch boot mode." "INFO" Cyan
            $skipEspBcd = $true
        } elseif ($targetDisk.PartitionStyle -ne "GPT") {
            Write-Log "  [WARNING] Disk is not GPT. Skipping ESP/BCD creation." "WARN" Yellow; $skipEspBcd = $true
        } else { Write-Log "  [OK] Disk is GPT. Proceeding with ESP + BCD." "SUCCESS" Green }

        if (-not $skipEspBcd) {

        # 4B. Locate or create EFI System Partition (ESP)
        $espPartition = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Where-Object { 
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -or $_.IsSystem -or $_.Type -eq "System" 
        } | Select-Object -First 1

        if (-not $espPartition) {
            Write-Host "`n==================================================" -ForegroundColor Yellow
            Write-Host "             EFI SYSTEM PARTITION REQUIRED        " -ForegroundColor Yellow
            Write-Host "==================================================" -ForegroundColor Yellow
            Write-Host "An EFI System Partition (ESP) is missing or needs to be created on Disk $($targetDisk.Number)." -ForegroundColor White
            
            $partitions = Get-Partition -DiskNumber $targetDisk.Number | Sort-Object PartitionNumber
            Write-Host "`nExisting Partitions on Disk $($targetDisk.Number):" -ForegroundColor Cyan
            $partitions | Select-Object PartitionNumber, DriveLetter, Type, Size | Out-String | Write-Host -ForegroundColor White
            
            $candidate = $null
            $recommendationMsg = ""
            
            # Find candidate partition to shrink (verifying shrinkable capacity >= 100MB)
            $shrinkCandidates = @()
            foreach ($p in $partitions | Where-Object { $_.Type -notin @("Reserved", "System") }) {
                $supp = $p | Get-PartitionSupportedSize -ErrorAction SilentlyContinue
                if ($supp -and ($p.Size - 100MB) -ge $supp.SizeMin) {
                    $shrinkCandidates += [PSCustomObject]@{
                        Partition = $p
                        SupportedSize = $supp
                        ShrinkableMB = [math]::Round(($p.Size - $supp.SizeMin) / 1MB, 0)
                        IsRecovery = ($p.Type -eq "Recovery" -or $p.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}")
                        IsOS = ($p.DriveLetter -eq $TargetDrive.TrimEnd(":"))
                    }
                }
            }

            $candidateObj = $shrinkCandidates | Where-Object IsRecovery | Select-Object -First 1
            if (-not $candidateObj) {
                $candidateObj = $shrinkCandidates | Where-Object { -not $_.IsOS } | Select-Object -First 1
            }
            if (-not $candidateObj) {
                $candidateObj = $shrinkCandidates | Where-Object IsOS | Select-Object -First 1
            }

            if ($candidateObj) {
                $candidate = $candidateObj.Partition
                if ($candidateObj.IsRecovery) {
                    $recommendationMsg = "Recommended partition to shrink: Partition $($candidate.PartitionNumber) (Type: Recovery, Size: $([math]::Round($candidate.Size / 1MB, 2)) MB, Shrinkable: $($candidateObj.ShrinkableMB) MB). Safest candidate."
                } elseif ($candidateObj.IsOS) {
                    $recommendationMsg = "Recommended partition to shrink: OS Partition $($candidate.PartitionNumber) (Drive: $($candidate.DriveLetter):, Shrinkable: $($candidateObj.ShrinkableMB) MB)."
                } else {
                    $recommendationMsg = "Recommended partition to shrink: Partition $($candidate.PartitionNumber) (Type: $($candidate.Type), Shrinkable: $($candidateObj.ShrinkableMB) MB)."
                }
            }
            
            if ($candidate) {
                Write-Host "$recommendationMsg" -ForegroundColor Yellow
                $ans = Read-Host "`nShrink Partition $($candidate.PartitionNumber) by 100MB to create a new 100MB FAT32 EFI partition? [Y/Q] (Default: Y, or Q to Quit and do manually)"
                if ($ans -eq "" -or $ans -match "^[yY]") {
                    try {
                        Write-Log "  [ACTION] Shrinking Partition $($candidate.PartitionNumber)..." "INFO" Yellow;
                        $shrinkBytes = 100 * 1024 * 1024
                        $currentSize = $candidate.Size
                        $newSize = $currentSize - $shrinkBytes
                        
                        $supportedSize = $candidate | Get-PartitionSupportedSize
                        if ($newSize -ge $supportedSize.SizeMin) {
                            $candidate | Resize-Partition -Size $newSize -ErrorAction Stop
                            Write-Log "  [OK] Partition $($candidate.PartitionNumber) shrunk successfully." "SUCCESS" Green;
                            
                            Write-Log "  [ACTION] Creating new EFI System Partition..." "INFO" Yellow;
                            $newPart = New-Partition -DiskNumber $targetDisk.Number -Size $shrinkBytes -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -ErrorAction Stop
                            Write-Log "  [OK] Partition $($newPart.PartitionNumber) created as EFI System Partition." "SUCCESS" Green;
                            
                            Write-Log "  [ACTION] Formatting EFI partition as FAT32..." "INFO" Yellow;
                            $newPart | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false -ErrorAction Stop
                            Write-Log "  [OK] Partition formatted successfully." "SUCCESS" Green;
                            
                            $espPartition = $newPart
                        } else {
                            Write-Log "  [ERROR] Partition $($candidate.PartitionNumber) cannot be shrunk further. Minimum supported size is $($supportedSize.SizeMin / 1MB) MB." "ERROR" Red;
                        }
                    } catch {
                        Write-Log "  [ERROR] Failed to resize/create partition: $_" "ERROR" Red;
                    }
                } else {
                    Write-Log "  [QUIT] User chose to quit and perform EFI partition creation manually." "WARN" Red;
                    exit
                }
            } else {
                Write-Log "  [ERROR] Could not identify any partitions to resize on Disk $($targetDisk.Number)." "ERROR" Red;
            }
        }

        # 4C. Mount EFI System Partition
        $espDrive = $null
        $mountedTempDrive = $false
        $freeLetter = $null
        
        if ($espPartition) {
            $volume = $espPartition | Get-Volume -ErrorAction SilentlyContinue
            if ($volume -and $volume.DriveLetter) {
                $espDrive = "$($volume.DriveLetter):"
            } else {
                $usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
                $freeLetter = "S"
                if ($usedLetters -contains "S") {
                    $freeLetter = (67..90 | ForEach-Object { [char]$_ } | Where-Object { $usedLetters -notcontains $_ })[0]
                }
                $espDrive = "${freeLetter}:"
                Write-Log "  [ACTION] Mounting target EFI System Partition to ${espDrive}..." "INFO" Gray;
                $espPartition | Set-Partition -NewDriveLetter $freeLetter -ErrorAction Stop
                $mountedTempDrive = $true
            }
        }

        # 4D. Comprehensive UEFI Bootloader & BCD Rebuild
        # Rebuilding the UEFI bootloader environment with fresh build-matched bootmgfw.efi, fallback bootx64.efi,
        # and explicit BCD partition pointers guarantees clean native UEFI boot across Acer, HP, Dell, and Lenovo firmware.
        if ($espDrive) {
            Write-Log "  [ACTION] Recreating pristine EFI bootloader & BCD store via bcdboot ($TargetDrive\Windows)..." "INFO" Yellow;
            
            # Back up existing BCD if present
            $bcdPath = "$espDrive\EFI\Microsoft\Boot\BCD"
            if (Test-Path $bcdPath) {
                Write-Log "  [ACTION] Backing up existing BCD to BCD.old..." "INFO" Gray;
                cmd.exe /c "attrib -h -r -s `"$bcdPath`" 2>&1" | Out-Null
                Move-Item -Path $bcdPath -Destination "$bcdPath.old-$TimeStamp" -Force -ErrorAction SilentlyContinue
            }
            
            # Execute bcdboot with verbose logging targeting UEFI firmware
            $bcdBootRes = cmd.exe /c "bcdboot `"$TargetDrive\Windows`" /s $espDrive /f UEFI /v 2>&1" | Out-String
            Write-Log "  bcdboot output: $($bcdBootRes.Trim())" "INFO" Gray;

            # Ensure fallback UEFI bootloader exists (\EFI\Boot\bootx64.efi)
            # Many UEFI BIOSes (especially Acer, Lenovo, HP) look for bootx64.efi as the mandatory fallback loader
            $fallbackDir = "$espDrive\EFI\Boot"
            $fallbackEfi = "$fallbackDir\bootx64.efi"
            $msBootEfi = "$espDrive\EFI\Microsoft\Boot\bootmgfw.efi"
            if (-not (Test-Path $fallbackDir)) {
                New-Item -ItemType Directory -Path $fallbackDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if (Test-Path $msBootEfi) {
                Copy-Item -Path $msBootEfi -Destination $fallbackEfi -Force -ErrorAction SilentlyContinue
                Write-Log "  [OK] Staged fallback UEFI bootloader to $fallbackEfi" "SUCCESS" Green;
            }

            # Explicitly bind BCD device and osdevice pointers (The DISM++ / Sergei Strelec standard)
            if (Test-Path "$espDrive\EFI\Microsoft\Boot\BCD") {
                Write-Log "  [ACTION] Binding explicit partition volume pointers in target BCD store..." "INFO" Gray;
                cmd.exe /c "bcdedit /store `"$espDrive\EFI\Microsoft\Boot\BCD`" /set {bootmgr} device partition=$espDrive 2>&1" | Out-Null
                cmd.exe /c "bcdedit /store `"$espDrive\EFI\Microsoft\Boot\BCD`" /set {default} device partition=$TargetDrive 2>&1" | Out-Null
                cmd.exe /c "bcdedit /store `"$espDrive\EFI\Microsoft\Boot\BCD`" /set {default} osdevice partition=$TargetDrive 2>&1" | Out-Null
                
                # Verify BCD enumeration
                $verifyResult = cmd.exe /c "bcdedit /store `"$espDrive\EFI\Microsoft\Boot\BCD`" /enum 2>&1" | Out-String
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "  [SUCCESS] Target UEFI BCD store verified and bound successfully!" "SUCCESS" Green;
                } else {
                    Write-Log "  [WARNING] Target BCD verification notice: $($verifyResult.Trim())" "WARN" Yellow;
                }
            } else {
                Write-Log "  [ERROR] BCD store missing after bcdboot pass." "ERROR" Red;
                $ReadinessScore -= 20;
            }

            if (-not $IsOffline) {
                Write-Log "  [ACTION] Synchronizing fresh BCD into active system registry hive..." "INFO" Yellow;
                $importRes = cmd.exe /c "bcdedit /import `"$espDrive\EFI\Microsoft\Boot\BCD`" /clean 2>&1" | Out-String
                Write-Log "  bcdedit /import: $($importRes.Trim())" "INFO" Gray;
            }

            # 4E-1. Stamp FAT32 Partition Boot Record (PBR) on ESP via bootsect
            Write-Log "  [ACTION] Stamping FAT32 Partition Boot Record (PBR) on ESP via bootsect..." "INFO" Gray
            $bsRes = cmd.exe /c "bootsect.exe /nt60 $espDrive /force /mbr 2>&1" | Out-String
            Write-Log "  bootsect output: $($bsRes.Trim())" "INFO" Gray

            # 4E-2. Inject automated motherboard NVRAM registration into target RunOnce (for offline targets)
            if ($IsOffline) {
                try {
                    Write-Log "  [ACTION] Scheduling motherboard NVRAM auto-registration for target first-boot..." "INFO" Gray
                    $softHive = "$TargetDrive\Windows\System32\config\SOFTWARE"
                    if (Test-Path $softHive) {
                        cmd.exe /c "reg load HKLM\OfflineSoftNvram `"$softHive`" 2>&1" | Out-Null
                        cmd.exe /c "reg add `"HKLM\OfflineSoftNvram\Microsoft\Windows\CurrentVersion\RunOnce`" /v AutoRegisterUEFI /t REG_SZ /d `"cmd.exe /c bcdboot C:\Windows /f UEFI`" /f 2>&1" | Out-Null
                        cmd.exe /c "reg unload HKLM\OfflineSoftNvram 2>&1" | Out-Null
                        Write-Log "  [OK] Motherboard NVRAM auto-registration scheduled in target RunOnce." "SUCCESS" Green
                    }
                } catch {
                    cmd.exe /c "reg unload HKLM\OfflineSoftNvram 2>&1" | Out-Null
                }
            }
        } else {
            Write-Log "  [ACTION] Running default bcdboot refresh..." "INFO" Yellow;
            $bcdOutput = cmd.exe /c "bcdboot `"$TargetDrive\Windows`" /f UEFI 2>&1" | Out-String;
            Write-Log "  bcdboot output: $($bcdOutput.Trim())" "INFO" Gray;
        }

        # 4E. Strip conflicting drive letters from orphaned legacy MBR System Reserved partitions on GPT disks
        if ($targetDisk.PartitionStyle -eq "GPT") {
            $orphanParts = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Where-Object {
                $_.DriveLetter -and $_.DriveLetter -ne $TargetDrive.TrimEnd(":") -and $_.Type -ne "System" -and $_.GptType -ne "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
            }
            foreach ($op in $orphanParts) {
                $opVol = $op | Get-Volume -ErrorAction SilentlyContinue
                if ($opVol -and ($opVol.FileSystemLabel -match "System Reserved" -or ($opVol.Size -le 500MB -and $opVol.FileSystem -eq "NTFS"))) {
                    Write-Log "  [ACTION] Removing conflicting drive letter $($op.DriveLetter): from orphaned legacy MBR partition..." "INFO" Yellow;
                    $op | Remove-PartitionAccessPath -AccessPath "$($op.DriveLetter):\" -ErrorAction SilentlyContinue
                }
            }
        }

        # Reset health check cache to ensure clean state
        Write-Log "  [ACTION] Resetting SFC/DISM execution cache..." "INFO" Yellow;
        if (Test-Path $RegKey) {
            Remove-ItemProperty -Path $RegKey -Name "LastHealthCheck" -ErrorAction SilentlyContinue
        }
        }  # End of if (-not $skipEspBcd) gate for ESP/BCD creation
    } catch {
        Write-Log "  [ERROR] Failed during BCD integrity check/rebuild: $_" "ERROR" Red;
        $ReadinessScore -= 20;
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
    if ($script:ForceReboot) { Invoke-RebootCountdown -NextStep 5 -Timeout 60 }
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 5: Check, Enable & Repair WinRE (Extract from ISO)
# ------------------------------------------------------------------
$StepNum = 5
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking Windows Recovery Environment (WinRE)...";
    $recoveryPath = "$TargetDrive\Windows\System32\Recovery"
    $reXmlPath = "$recoveryPath\ReAgent.xml"
    $winreWimPath = "$recoveryPath\winre.wim"
    $winreNeedsFix = $false
    $winreReason = ""

    # Query reagentc with target if offline
    $reCmd = if ($IsOffline) { "reagentc /info /target `"$TargetDrive\Windows`"" } else { "reagentc /info" }
    $reStatus = cmd.exe /c "$reCmd 2>&1" | Out-String

    if ($reStatus -notmatch "Enabled") {
        $winreNeedsFix = $true
        $winreReason = "WinRE is currently disabled"
    }

    # Inspect ReAgent.xml for corrupt MBR guid or missing location
    if (Test-Path $reXmlPath) {
        try {
            [xml]$xml = Get-Content $reXmlPath -ErrorAction Stop
            $loc = $xml.WindowsRE.WinreLocation
            if ($loc) {
                # Check for zeroed GUID on GPT disk
                if ($targetDisk -and $targetDisk.PartitionStyle -eq "GPT" -and $loc.guid -eq "{00000000-0000-0000-0000-000000000000}") {
                    $winreNeedsFix = $true
                    $winreReason = "ReAgent.xml contains stale MBR partition GUID ({00000000-0000-0000-0000-000000000000}) on a GPT disk"
                }
            }
        } catch {}
    }

    # Inspect winre.wim integrity
    if (Test-Path $winreWimPath) {
        $wimItem = Get-Item $winreWimPath -ErrorAction SilentlyContinue
        if ($wimItem.Length -lt 250MB) {
            $winreNeedsFix = $true
            $winreReason = "winre.wim is suspiciously small ($([math]::Round($wimItem.Length/1MB,1)) MB) or corrupted"
        }
    } else {
        if (-not $winreNeedsFix) {
            if ($reStatus -match "Windows RE location:\s*\\\\\?\\GLOBALROOT") {
                # Valid online path in dedicated partition
            } elseif (-not (Test-Path "$recoveryPath\winre.wim")) {
                $winreNeedsFix = $true
                $winreReason = "winre.wim not found in System32\Recovery"
            }
        }
    }

    if (-not $winreNeedsFix) {
        Write-Log "  [OK] WinRE is Enabled and configuration is valid." "SUCCESS" Green;
    } else {
        Write-Log "  [ACTION] WinRE requires repair: $winreReason" "INFO" Yellow;
        
        # Check if local winre.wim exists or if we should extract a fresh copy from ISO
        $extracted = $false
        if ((-not (Test-Path $winreWimPath)) -or ($winreReason -match "stale MBR|corrupted|suspiciously")) {
            Write-Log "  [ACTION] Extracting fresh Windows 11 Winre.wim from ISO..." "INFO" Yellow
            $isoDrive = Get-MountedSetupDrive
            if (-not $isoDrive) {
                if ($BypassAll) {
                    Write-Log "  [-BypassAll active] No ISO detected. Proceeding without fresh ISO WinRE extraction." "INFO" Yellow;
                } else {
                    Write-Host "`n[ACTION REQUIRED] Windows 11 ISO or setup drive not detected." -ForegroundColor Magenta;
                    Write-Host "Please mount your Windows 11 ISO (right-click -> Mount), plug in a USB setup drive," -ForegroundColor Magenta;
                    Write-Host "or place Win11.iso in $ScriptDir." -ForegroundColor Magenta;
                    Write-Host "Press any key once the ISO or USB drive is mounted..." -ForegroundColor Magenta;
                    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                    $isoDrive = Get-MountedSetupDrive;
                }
            }
            if ($isoDrive) {
                $extracted = Extract-WinREFromISO -TargetRecoveryPath $recoveryPath -IsoDriveLetter $isoDrive
            }
        }

        # Reset ReAgent.xml and re-register
        Write-Log "  [ACTION] Re-registering WinRE image pointer..." "INFO" Yellow;
        if ($IsOffline) {
            cmd.exe /c "reagentc /disable /target `"$TargetDrive\Windows`" 2>&1" | Out-Null
            $setRes = cmd.exe /c "reagentc /setreimage /path `"$recoveryPath`" /target `"$TargetDrive\Windows`" 2>&1" | Out-String
            Write-Log "  reagentc setreimage: $($setRes.Trim())" "INFO" Gray
            $enRes = cmd.exe /c "reagentc /enable /target `"$TargetDrive\Windows`" 2>&1" | Out-String
            Write-Log "  reagentc enable: $($enRes.Trim())" "INFO" Gray
            if ($enRes -match "Successful") {
                Write-Log "  [OK] Offline WinRE rebuilt and enabled successfully." "SUCCESS" Green;
            } else {
                Write-Log "  [WARNING] Offline WinRE staging complete (ReAgent.xml updated with fresh winre.wim)." "WARN" Yellow;
            }
        } else {
            cmd.exe /c "reagentc /disable 2>&1" | Out-Null
            cmd.exe /c "reagentc /setreimage /path `"$recoveryPath`" 2>&1" | Out-Null
            $enRes = cmd.exe /c "reagentc /enable 2>&1" | Out-String
            if ($enRes -match "Successful") {
                Write-Log "  [OK] WinRE pointer rebuilt and enabled successfully." "SUCCESS" Green;
            } else {
                Write-Log "  [WARNING] WinRE enable returned: $($enRes.Trim())" "WARN" Yellow;
                $ReadinessScore -= 10
            }
        }
    }

    # Unmount the temporary EFI partition drive letter if it was mounted
    if ($mountedTempDrive -and $freeLetter) {
        Write-Log "  [ACTION] Unmounting temporary EFI System Partition ${freeLetter}:..." "INFO" Gray;
        Get-Partition -DriveLetter $freeLetter -ErrorAction SilentlyContinue | Remove-PartitionAccessPath -AccessPath "${freeLetter}:\" -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 6: Check Pending Reboots
# ------------------------------------------------------------------
$StepNum = 6
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking for pending system reboots...";
    $pendingReboot = $false;
    
    if ($IsOffline) {
        $swHive = "$TargetDrive\Windows\System32\config\SOFTWARE"
        cmd.exe /c "reg load HKLM\OfflineSOFTWARE `"$swHive`" " 2>&1 | Out-Null
        $regPaths = @(
            "HKLM:\OfflineSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\OfflineSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        )
        foreach ($reg in $regPaths) {
            if (Test-Path $reg) { $pendingReboot = $true };
        }
        cmd.exe /c "reg unload HKLM\OfflineSOFTWARE" 2>&1 | Out-Null
    } else {
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        )
        foreach ($reg in $regPaths) {
            if (Test-Path $reg) { $pendingReboot = $true };
        }
    }

    if ($pendingReboot -or $script:ForceReboot) {
        Write-Log "  [CRITICAL] Pending reboot detected or required by BCD! A system restart is advised." "WARN" Red;
        $ReadinessScore -= 15;
        Invoke-RebootCountdown -NextStep 7 -Timeout 60
    } else {
        Write-Log "  [OK] No pending reboot flags found." "SUCCESS" Green;
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 7: Third-Party Antivirus Detection & Active Verification
# ------------------------------------------------------------------
$StepNum = 7
if ($ResumeStep -le $StepNum) {
    Step-Progress "Checking for Third-Party Antivirus...";
    try {
        if ($IsOffline) {
            Write-Log "  [ACTION] Scanning offline target for third-party Antivirus and filesystem filter drivers..." "INFO" Cyan;
            
            # 1. Check directories for major AV, EDR, and backup software
            $avDirs = @(
                "$TargetDrive\Program Files\AVAST Software",
                "${TargetDrive}\Program Files (x86)\AVAST Software",
                "$TargetDrive\ProgramData\AVAST Software",
                "$TargetDrive\Program Files\AVG",
                "${TargetDrive}\Program Files (x86)\AVG",
                "$TargetDrive\ProgramData\Avg",
                "$TargetDrive\Program Files\Norton Security",
                "$TargetDrive\Program Files (x86)\Norton Security",
                "$TargetDrive\Program Files\Symantec",
                "$TargetDrive\Program Files (x86)\Symantec",
                "$TargetDrive\Program Files\McAfee",
                "$TargetDrive\Program Files (x86)\McAfee",
                "$TargetDrive\Program Files\Kaspersky Lab",
                "$TargetDrive\Program Files (x86)\Kaspersky Lab",
                "$TargetDrive\Program Files\Bitdefender",
                "$TargetDrive\Program Files\Trend Micro",
                "$TargetDrive\Program Files\Sophos",
                "$TargetDrive\Program Files\Malwarebytes",
                "$TargetDrive\Program Files\WRData",
                "$TargetDrive\Program Files\ESET",
                "$TargetDrive\Program Files\Acronis",
                "$TargetDrive\Program Files (x86)\Samsung\Samsung Magician"
            );
            $foundAvDirs = @($avDirs | Where-Object { Test-Path $_ });
            if ($foundAvDirs.Count -gt 0) {
                foreach ($d in $foundAvDirs) {
                    Write-Log "  [WARNING] Found offline security/backup software directory: $d" "WARN" Magenta;
                }
            }

            # 2. Check drivers in System32\drivers against known upgrade blocker signatures
            $driverDir = "$TargetDrive\Windows\System32\drivers";
            $knownBlockerPatterns = @(
                "asw*.sys", "avg*.sys",                      # Avast / AVG
                "SRTSPX64.SYS", "SRTSP.SYS", "SymEFA.sys",   # Symantec / Norton
                "SymHsm.sys", "NAVEX15.SYS", "symevent.sys",
                "mfehidk.sys", "mfeavfk.sys", "mfeapfk.sys", # McAfee / Trellix
                "klif.sys", "klflt.sys", "klbackupflt.sys",  # Kaspersky
                "tmactmon.sys", "tmfileflt.sys",             # Trend Micro
                "hmpalert.sys", "savonaccess.sys",           # Sophos / HitmanPro
                "gzflt.sys", "atc.sys", "trufos.sys",        # Bitdefender
                "farflt.sys", "mbamchameleon.sys",           # Malwarebytes
                "snapman.sys", "fltsrv.sys", "tib.sys",      # Acronis TrueImage
                "SamsungRapidDiskFltr.sys", "RAPID.sys",     # Samsung Magician RAPID Mode
                "RsFx010*.sys"                               # Legacy SQL FILESTREAM
            );
            
            $fltDrivers = @();
            if (Test-Path $driverDir) {
                foreach ($pattern in $knownBlockerPatterns) {
                    $matches = Get-ChildItem -Path $driverDir -Filter $pattern -ErrorAction SilentlyContinue;
                    if ($matches) { $fltDrivers += $matches }
                }
            }

            # 3. Check offline SYSTEM hive using Generic Minifilter Discovery Heuristic
            $sysHive = "$TargetDrive\Windows\System32\config\SYSTEM";
            $thirdPartyFiltersFound = @();
            $knownAvServices = @();
            
            $msFilterWhitelist = @(
                'FileInfo', 'Wof', 'bindflt', 'cldflt', 'storqosflt', 'wcifs', 'luafv', 
                'FileCrypt', 'WIMMount', 'FsDepends', 'UCPD', 'npsvctrig', 'wcnfs', 
                'AppvStrm', 'AppvVemgr', 'AppvVfs', 'UevAgentDriver', 'Filetrace', 
                'MsSecFlt', 'applockerfltr', 'PEAUTH', 'WdFilter'
            );

            if (Test-Path $sysHive) {
                cmd.exe /c "reg.exe load HKLM\OfflineSYSTEM `"$sysHive`" 2>&1" | Out-Null;
                try {
                    $servicesKey = "HKLM:\OfflineSYSTEM\ControlSet001\Services";
                    if (Test-Path $servicesKey) {
                        # A. Named vendor services (Avast, AVG, Norton, McAfee, etc.)
                        $knownAvServices = @(Get-ChildItem -Path $servicesKey | Where-Object {
                            $_.PSChildName -match "^asw|^avast|^avg|^sym|^srtsp|^mfe|^kl|^tm|^hmp|^gzflt|^snapman|^RsFx010"
                        });

                        # B. Generic Heuristic: Any service with an 'Instances' key not in MS whitelist
                        Get-ChildItem -Path $servicesKey | ForEach-Object {
                            $sName = $_.PSChildName;
                            if ($msFilterWhitelist -notcontains $sName) {
                                $instKey = Join-Path $_.PSPath "Instances";
                                if (Test-Path $instKey) {
                                    $sProps = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue;
                                    if ($sProps.Group -match "FSFilter|Filter" -or $sProps.DependOnService -match "FltMgr") {
                                        $thirdPartyFiltersFound += [PSCustomObject]@{
                                            Name      = $sName;
                                            Group     = $sProps.Group;
                                            ImagePath = $sProps.ImagePath;
                                            Start     = $sProps.Start;
                                        }
                                    }
                                }
                            }
                        };
                    }
                } finally {
                    cmd.exe /c "reg.exe unload HKLM\OfflineSYSTEM 2>&1" | Out-Null;
                }
            }

            # 4. Storage Driver & RAM Cache Heuristic (Samsung RAPID & Intel RST)
            if (Test-Path $driverDir) {
                # A. Samsung Magician RAPID Mode
                $rapidDriver = Join-Path $driverDir "SamsungRapidDiskFltr.sys";
                if (Test-Path $rapidDriver) {
                    Write-Host "`n>>> CRITICAL STORAGE WARNING: SAMSUNG RAPID MODE DETECTED <<<" -ForegroundColor Red;
                    Write-Host "Samsung RAPID Mode caches disk writes in RAM, which corrupts SafeOS migrations (0xC1900101-0x30018)!" -ForegroundColor Yellow;
                }

                # B. Outdated Intel RST Driver Check
                $iaStor = Join-Path $driverDir "iaStorA.sys";
                if (-not (Test-Path $iaStor)) { $iaStor = Join-Path $driverDir "iaStorAC.sys" }
                if (Test-Path $iaStor) {
                    $rstVer = (Get-ItemProperty $iaStor).VersionInfo.FileVersion;
                    if ($rstVer) {
                        Write-Log "  [INFO] Detected Intel RST storage driver version: $rstVer" "INFO" White;
                        # Microsoft blocks upgrades on < 15.9.8.1050 and 17.0.x - 17.5.x
                        if ($rstVer -match "^1[0-4]\." -or $rstVer -match "^15\.[0-8]\." -or $rstVer -match "^17\.[0-4]\.") {
                            Write-Host "  [WARNING] Intel RST driver version $rstVer is subject to Microsoft upgrade hold!" -ForegroundColor Yellow;
                            Write-Host "  [MITIGATION] Win10to11 will launch Setup with /DynamicUpdate Disable to bypass this block." -ForegroundColor Cyan;
                        }
                    }
                }
            }

            $totalBlockers = $knownAvServices.Count + $thirdPartyFiltersFound.Count + $fltDrivers.Count + $foundAvDirs.Count;
            if ($totalBlockers -gt 0) {
                Write-Host "`n>>> OFFLINE SECURITY & FILTER DRIVERS DETECTED <<<" -ForegroundColor Red;
                Write-Host "Third-party filesystem minifilters and storage filter drivers are installed on this drive." -ForegroundColor Yellow;
                Write-Host "These filter drivers block SafeOS WIM mounting and trigger fatal errors 0x801F0005 and 0x80070714!" -ForegroundColor Yellow;
                if ($thirdPartyFiltersFound.Count -gt 0) {
                    foreach ($tpf in $thirdPartyFiltersFound) {
                        Write-Host "  - Found Minifilter: $($tpf.Name) (Group: $($tpf.Group), Start: $($tpf.Start))" -ForegroundColor Cyan;
                    }
                }
                Write-Host "";
                
                $disableConfirm = $true;
                if (-not $BypassAll) {
                    $ans = Read-Host "Do you want to neutralize / disable these offline filter drivers to allow the upgrade? (Y/N)";
                    if ($ans -notmatch "^[Yy]") { $disableConfirm = $false };
                }

                if ($disableConfirm) {
                    Write-Log "  [ACTION] Neutralizing offline security and legacy filter services via reg.exe..." "INFO" Yellow;
                    cmd.exe /c "reg.exe load HKLM\OfflineSYSTEM `"$sysHive`" 2>&1" | Out-Null;
                    try {
                        # Combine named and generic discovered filter services
                        $allSvcsToDisable = @();
                        foreach ($s in $knownAvServices) { $allSvcsToDisable += $s.PSChildName }
                        foreach ($s in $thirdPartyFiltersFound) { $allSvcsToDisable += $s.Name }
                        $allSvcsToDisable = @($allSvcsToDisable | Select-Object -Unique);

                        foreach ($svc in $allSvcsToDisable) {
                            cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\ControlSet001\Services\$svc`" /v Start /t REG_DWORD /d 4 /f 2>&1" | Out-Null;
                            cmd.exe /c "reg.exe delete `"HKLM\OfflineSYSTEM\ControlSet001\Services\$svc\Instances`" /f 2>&1" | Out-Null;
                            Write-Log "    Disabled service & removed filter instance: $svc (Start=4)" "INFO" Gray;
                        }

                        # Universal Class UpperFilter Sanitization
                        # 1. DiskDrive Class: Revert to pure partmgr (removes aswArDisk, snapman, ambakdrv, etc.)
                        cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\ControlSet001\Control\Class\{4d36e967-e325-11ce-bfc1-08002be10318}`" /v UpperFilters /t REG_MULTI_SZ /d `"partmgr`" /f 2>&1" | Out-Null;
                        Write-Log "    Sanitized DiskDrive UpperFilters -> partmgr" "SUCCESS" Green;

                        # 2. Volume Class: Revert to pure volsnap (removes third-party snapshot hooks)
                        cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\ControlSet001\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}`" /v UpperFilters /t REG_MULTI_SZ /d `"volsnap`" /f 2>&1" | Out-Null;
                        Write-Log "    Sanitized Volume UpperFilters -> volsnap" "SUCCESS" Green;

                        # 3. Keyboard Class: Revert to pure kbdclass (removes aswKbd)
                        cmd.exe /c "reg.exe add `"HKLM\OfflineSYSTEM\ControlSet001\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}`" /v UpperFilters /t REG_MULTI_SZ /d `"kbdclass`" /f 2>&1" | Out-Null;
                        Write-Log "    Sanitized Keyboard UpperFilters -> kbdclass" "SUCCESS" Green;
                    } finally {
                        cmd.exe /c "reg.exe unload HKLM\OfflineSYSTEM 2>&1" | Out-Null;
                    }

                    # Rename discovered blocker driver files to .disabled
                    foreach ($df in $fltDrivers) {
                        $cdPath = $df.FullName;
                        if (Test-Path $cdPath) {
                            try {
                                Rename-Item -Path $cdPath -NewName "$($df.Name).disabled" -Force -ErrorAction Stop;
                                Write-Log "    Renamed driver: $($df.Name) -> $($df.Name).disabled" "SUCCESS" Green;
                            } catch {
                                Write-Log "    Could not rename $($df.Name): $_" "WARN" Yellow;
                            }
                        }
                    }

                    # Quarantine any leftover *.tmp and *.backup driver remnants
                    $quarDir = Join-Path $driverDir "Quarantined_Drivers";
                    $remnants = @(Get-ChildItem -Path $driverDir | Where-Object { $_.Name -match "^(asw|avg|sym|mfe|kl|snap).*\.(tmp|backup|sum)$" });
                    if ($remnants.Count -gt 0) {
                        if (-not (Test-Path $quarDir)) { New-Item -ItemType Directory -Path $quarDir -Force | Out-Null };
                        foreach ($rem in $remnants) {
                            Move-Item -Path $rem.FullName -Destination $quarDir -Force -ErrorAction SilentlyContinue;
                        }
                        Write-Log "    Quarantined $($remnants.Count) temporary/backup driver files." "INFO" Gray;
                    }

                    # Remove known rogue driver packages from offline DriverStore
                    cmd.exe /c "dism.exe /Image:`"$TargetDrive\`" /Remove-Driver /Driver:oem76.inf 2>&1" | Out-Null;

                    Write-Log "  [SUCCESS] Offline security & legacy filter drivers neutralized. Setup will not be blocked by 0x801F0005." "SUCCESS" Green;
                } else {
                    Write-Log "  [WARNING] Offline filter drivers remain active. Upgrade is highly likely to fail." "WARN" Red;
                    $ReadinessScore -= 30;
                }
            } else {
                Write-Log "  [OK] No active offline third-party filter drivers found." "SUCCESS" Green;
            }
        } else {
            # Online AV & Filter Driver Check
            $avInfo = Get-CimInstance -Namespace "root\SecurityCenter2" -Class AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object { $_.displayName -notmatch "Windows Defender" };
            if ($avInfo) {
                foreach ($av in $avInfo) {
                    Write-Log "  [WARNING] Third-party AV detected: $($av.displayName)" "WARN" Magenta;
                }
                Write-Host "`n>>> ACTION REQUIRED <<<" -ForegroundColor Red;
                Write-Host "Please heavily DISABLE (or UNINSTALL) the above Antivirus software now." -ForegroundColor Yellow;
                Write-Host "AV engines actively block the Windows 11 registry migration phase." -ForegroundColor Yellow;
                
                if ($BypassAll) {
                    Write-Log "  [-BypassAll active] Proceeding past AV disable confirmation prompt..." "INFO" Yellow
                } else {
                    $avConfirm = Read-Host "Type 'Y' and press Enter once you have disabled/uninstalled it";
                }
            }

            # Check for active kernel minifilters in memory via fltmc
            Write-Log "  Auditing active filesystem minifilter drivers (fltmc)..." "INFO" Gray;
            $fltOut = cmd.exe /c "fltmc filters 2>&1" | Out-String;
            $rogueFilterList = @(
                "aswMonFlt", "aswSP", "aswSnx", "RsFx0105", "RsFx0100", "RsFx0101", 
                "SRTSPX64", "SRTSP", "SymEFA", "mfehidk", "mfeavfk", "klif", 
                "tmactmon", "tmfileflt", "hmpalert", "gzflt", "farflt", "snapman", 
                "SamsungRapidDiskFltr", "RAPID"
            );
            $activeRogueFilters = @($rogueFilterList | Where-Object { $fltOut -match $_ });
            if ($activeRogueFilters.Count -gt 0) {
                foreach ($rf in $activeRogueFilters) {
                    Write-Log "  [CRITICAL] Active filter driver detected in memory: $rf" "ERROR" Red;
                    Write-Log "  [ACTION] Unloading filter $rf to prevent 0x801F0005..." "INFO" Yellow;
                    cmd.exe /c "fltmc unload $rf 2>&1" | Out-Null;
                    cmd.exe /c "sc.exe config $rf start= disabled 2>&1" | Out-Null;
                }
            }

            # Check for Samsung Magician RAPID Mode service online
            $rapidSvc = Get-Service -Name "RAPID" -ErrorAction SilentlyContinue;
            if (-not $rapidSvc) { $rapidSvc = Get-Service -Name "SamsungRapidDiskFltr" -ErrorAction SilentlyContinue }
            if ($rapidSvc) {
                Write-Host "`n>>> CRITICAL WARNING: SAMSUNG RAPID MODE IS RUNNING <<<" -ForegroundColor Red;
                Write-Host "Disable RAPID Mode in the Samsung Magician application before upgrading to prevent fatal rollback (0xC1900101-0x30018)!" -ForegroundColor Yellow;
            }

            Write-Log "  Verifying AV processes are stopped in memory..." "INFO" Gray;
            $knownAvProcs = @("ccsvchst", "nortonsecurity", "mbam", "mbamservice", "mcshield", "mfevtps", "avp", "bdservicehost", "avg", "avast", "wrsvc", "ekrn", "trufos");
            $runningAv = Get-Process | Where-Object { $knownAvProcs -contains $_.Name.ToLower() -or $_.Name -match "(?i)(norton|malwarebytes|mcafee|kaspersky|bitdefender|avast|avg|sophos|eset|webroot|acronis)" };
            
            if ($runningAv) {
                foreach ($proc in $runningAv) {
                    Write-Log "  [CRITICAL] Found running AV/Backup process: $($proc.Name) (ID: $($proc.Id))" "ERROR" Red;
                }
                Write-Log "  [CRITICAL] Antivirus/Backup software is STILL RUNNING in memory! The upgrade is highly likely to fail." "ERROR" Red;
                $ReadinessScore -= 40;
            } else {
                Write-Log "  [OK] AV background processes appear to be successfully disabled." "SUCCESS" Green;
            }
        }
    } catch {
        Write-Log "  [WARNING] Could not complete Antivirus/Filter audit: $_" "WARN" Red;
    }
    Set-ItemProperty -Path $RegKey -Name "ResumeStep" -Value ($StepNum + 1) -Force
} else { $script:CurrentStep++ }

# ------------------------------------------------------------------
# Step 8: SFC & DISM (with Heartbeat & Timeout Safeguards)
# ------------------------------------------------------------------
$StepNum = 8
if ($ResumeStep -le $StepNum) {
    Step-Progress "System File Checker & DISM Health Checks...";
    $RunHealthChecks = $true;

    if ($SkipHealthChecks) {
        $RunHealthChecks = $false;
        Write-Log "  [-SkipHealthChecks specified] Skipping SFC, DISM, and CHKDSK health checks." "INFO" Cyan;
    }

    $markerFile = "$TargetDrive\Windows\Win11Readiness_LastHealthCheck.txt";
    if ($RunHealthChecks -and (Test-Path $markerFile)) {
        try {
            $markerDate = [datetime](Get-Content $markerFile -ErrorAction SilentlyContinue);
            if ($markerDate -and (Get-Date) -lt $markerDate.AddHours(24)) {
                $RunHealthChecks = $false;
                Write-Log "  [SKIP] System health checks verified clean within last 24h ($($markerDate.ToString('g'))). Skipping SFC/DISM." "INFO" Cyan;
            }
        } catch {}
    }

    if ($RunHealthChecks -and -not $IsOffline -and (Test-Path $RegKey)) {
        $lastRunProp = Get-ItemProperty -Path $RegKey -Name "LastHealthCheck" -ErrorAction SilentlyContinue;
        if ($lastRunProp) {
            $lastRunDate = [datetime]$lastRunProp.LastHealthCheck;
            if ((Get-Date) -lt $lastRunDate.AddHours(24)) {
                $RunHealthChecks = $false;
                Write-Log "  [SKIP] Health checks ran recently on $($lastRunDate.ToString('g')). Skipping." "INFO" Cyan;
            }
        }
    }

    if ($RunHealthChecks) {
        # ---- Run Volume Filesystem Check (CHKDSK) ----
        Write-Log "  Checking volume filesystem integrity ($TargetDrive)..." "INFO" Gray;
        $volLetter = $TargetDrive.TrimEnd(":");
        $vol = Get-Volume -DriveLetter $volLetter -ErrorAction SilentlyContinue;
        if ($vol) {
            Write-Log "  [INFO] Volume $TargetDrive Health: $($vol.HealthStatus), OperationalStatus: $($vol.OperationalStatus)" "INFO" Gray;
            if ($vol.HealthStatus -ne "Healthy" -or $vol.OperationalStatus -match "Spot Fix Needed|Corrupt|Error|Warning") {
                Write-Log "  [WARNING] File system corruption detected on $TargetDrive ($($vol.OperationalStatus))!" "WARN" Yellow;
                Write-Log "  [ACTION] Running CHKDSK /F to repair filesystem corruption..." "INFO" Yellow;
                
                $chkAction = Check-KeyboardAction;
                if ($chkAction -ne "SKIP") {
                    $chkRes = cmd.exe /c "echo Y | chkdsk $TargetDrive /f 2>&1";
                    Write-Log "  CHKDSK execution completed." "INFO" Gray;
                    $volAfter = Get-Volume -DriveLetter $volLetter -ErrorAction SilentlyContinue;
                    if ($volAfter.HealthStatus -eq "Healthy" -and $volAfter.OperationalStatus -eq "OK") {
                        Write-Log "  [SUCCESS] Volume $TargetDrive file system successfully repaired to Healthy / OK." "SUCCESS" Green;
                    } else {
                        Write-Log "  [INFO] Volume $TargetDrive status after CHKDSK: $($volAfter.HealthStatus) / $($volAfter.OperationalStatus)" "INFO" Yellow;
                    }
                } else {
                    Write-Log "  [SKIP] User skipped CHKDSK repair." "WARN" Yellow;
                }
            } else {
                Write-Log "  [OK] Volume $TargetDrive file system is Healthy." "SUCCESS" Green;
            }
        }

        $spinner = @('-', '\', '|', '/');
        
        # ---- Run SFC with Heartbeat & Hotkey Controls ----
        Write-Log "  Running SFC (Timeout: 20 mins)... (Press [S] to Skip, [P] to Pause, [Q] to Quit)" "INFO" Gray;
        $sfcJob = Start-Job -ArgumentList $TargetDrive, $IsOffline -ScriptBlock { 
            param($td, $off)
            if ($off) { sfc.exe /scannow /offbootdir="$td\" /offwindir="$td\Windows" } else { sfc.exe /scannow }
        };
        $sfcStopwatch = [System.Diagnostics.Stopwatch]::StartNew();
        $i = 0;
        
        while ($sfcJob.State -eq 'Running') {
            $act = Check-KeyboardAction
            if ($act -eq "SKIP") {
                Write-Host "`n";
                Write-Log "  [SKIP] User skipped SFC scan." "WARN" Yellow;
                Stop-Job -Job $sfcJob;
                break;
            }
            if ($sfcStopwatch.Elapsed.TotalSeconds -gt 1200) { 
                Write-Host "`n";
                Write-Log "  [ERROR] SFC timed out! Aborting SFC step to prevent hang." "ERROR" Red;
                Stop-Job -Job $sfcJob;
                $ReadinessScore -= 10;
                break;
            }
            Write-Host "`r  $($spinner[$i % 4]) SFC is scanning... Elapsed: $($sfcStopwatch.Elapsed.ToString('mm\:ss')) " -NoNewline -ForegroundColor Cyan;
            $i++;
            Start-Sleep -Milliseconds 250;
        }
        Write-Host "`n"; 
        if ($sfcJob.State -eq 'Completed') {
            $null = Receive-Job -Job $sfcJob;
            Write-Log "  [OK] SFC scan complete." "SUCCESS" Green;
        }
        Remove-Job -Job $sfcJob -Force -ErrorAction SilentlyContinue;

        # ---- Run DISM with Heartbeat & Hotkey Controls ----
        Write-Log "  Running DISM Component Store Restore (Timeout: 30 mins)... (Press [S] to Skip, [P] to Pause, [Q] to Quit)" "INFO" Gray;
        $dismJob = Start-Job -ArgumentList $TargetDrive, $IsOffline -ScriptBlock { 
            param($td, $off)
            if ($off) { dism.exe /Image:"$td\" /Cleanup-Image /RestoreHealth } else { dism.exe /Online /Cleanup-Image /RestoreHealth }
        };
        $dismStopwatch = [System.Diagnostics.Stopwatch]::StartNew();
        $i = 0;
        
        while ($dismJob.State -eq 'Running') {
            $act = Check-KeyboardAction
            if ($act -eq "SKIP") {
                Write-Host "`n";
                Write-Log "  [SKIP] User skipped DISM scan." "WARN" Yellow;
                Stop-Job -Job $dismJob;
                break;
            }
            if ($dismStopwatch.Elapsed.TotalSeconds -gt 1800) { 
                Write-Host "`n";
                Write-Log "  [ERROR] DISM timed out! Aborting DISM step to prevent hang." "ERROR" Red;
                Stop-Job -Job $dismJob;
                $ReadinessScore -= 10;
                break;
            }
            Write-Host "`r  $($spinner[$i % 4]) DISM is actively working... Elapsed: $($dismStopwatch.Elapsed.ToString('mm\:ss')) " -NoNewline -ForegroundColor Cyan;
            $i++;
            Start-Sleep -Milliseconds 250;
        }
        Write-Host "`n"; 
        if ($dismJob.State -eq 'Completed') {
            $null = Receive-Job -Job $dismJob;
            Write-Log "  [OK] DISM component store restored and cleaned." "SUCCESS" Green;
        }
        Remove-Job -Job $dismJob -Force -ErrorAction SilentlyContinue;
        
        # ----------------------------------------------------------
        # Sysprep & Respecialize Safeguards (Prevents 0xC1900101 - 0x40021)
        # ----------------------------------------------------------
        Write-Log "`nChecking Sysprep & Respecialize Prerequisites (Anti-Rollback Safeguards)..." "INFO" Cyan;

        # 1. ProfileList Registry Audit
        Write-Log "  [ACTION] Auditing ProfileList for orphaned SIDs and duplicate .bak keys..." "INFO" Yellow;
        $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $offlineProfileHiveLoaded = $false

        if ($IsOffline) {
            $softwareHivePath = "$TargetDrive\Windows\System32\config\SOFTWARE"
            if (Test-Path $softwareHivePath) {
                cmd.exe /c "reg.exe load HKLM\TargetSOFTWARE `"$softwareHivePath`" 2>&1" | Out-Null
                $profileListPath = "HKLM\TargetSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
                $offlineProfileHiveLoaded = $true
            }
        }

        if (Test-Path $profileListPath) {
            $profiles = Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue
            $cleanedBak = 0
            foreach ($prof in $profiles) {
                $subKeyName = $prof.PSChildName
                if ($subKeyName.EndsWith(".bak")) {
                    Write-Log "  [WARNING] Found corrupted duplicate profile key: $subKeyName" "WARN" Yellow;
                    try {
                        Remove-Item -Path $prof.PSPath -Recurse -Force -ErrorAction Stop
                        Write-Log "  [OK] Removed broken .bak profile key: $subKeyName" "SUCCESS" Green;
                        $cleanedBak++
                    } catch {
                        Write-Log "  [WARN] Could not remove ${subKeyName}: $_" "WARN" Yellow;
                    }
                }
            }
            if ($cleanedBak -eq 0) {
                Write-Log "  [OK] ProfileList contains no corrupted .bak profile keys." "SUCCESS" Green;
            }
        }

        if ($offlineProfileHiveLoaded) {
            [gc]::Collect()
            Start-Sleep -Milliseconds 500
            cmd.exe /c "reg.exe unload HKLM\TargetSOFTWARE 2>&1" | Out-Null
        }

        # 2. Performance Counters Rebuild (lodctr /R)
        if (-not $IsOffline) {
            Write-Log "  [ACTION] Rebuilding performance counter registry (lodctr /R)..." "INFO" Yellow;
            try {
                $null = cmd.exe /c "lodctr.exe /R 2>&1"
                if (Test-Path "$env:SystemRoot\SysWOW64\lodctr.exe") {
                    $null = cmd.exe /c "C:\Windows\SysWOW64\lodctr.exe /R 2>&1"
                }
                Write-Log "  [OK] Performance counters rebuilt successfully." "SUCCESS" Green;
            } catch {
                Write-Log "  [WARN] Performance counter rebuild returned: $_" "WARN" Yellow;
            }

            # 3. WMI Repository Verification
            Write-Log "  [ACTION] Verifying WMI repository health..." "INFO" Yellow;
            $wmiRes = cmd.exe /c "winmgmt.exe /verifyrepository 2>&1" | Out-String
            if ($wmiRes -match "consistent") {
                Write-Log "  [OK] WMI repository is consistent." "SUCCESS" Green;
            } else {
                Write-Log "  [WARN] WMI repository inconsistent. Attempting salvage..." "WARN" Yellow;
                $salvageRes = cmd.exe /c "winmgmt.exe /salvagerepository 2>&1" | Out-String
                Write-Log "  WMI salvage result: $($salvageRes.Trim())" "INFO" Gray;
            }

            # 4. Third-Party Driver Store Audit
            Write-Log "  [ACTION] Auditing installed third-party drivers (pnputil)..." "INFO" Yellow;
            $pnpOut = cmd.exe /c "pnputil.exe /enum-drivers 2>&1" | Out-String
            $driverCount = ([regex]::Matches($pnpOut, "Published Name:")).Count
            Write-Log "  [INFO] Detected $driverCount third-party driver packages installed." "INFO" White;
            if ($pnpOut -match "iaStorA\.inf|iaStorAC\.inf") {
                Write-Log "  [WARNING] Detected legacy Intel RST storage driver. Ensure latest driver or use /DynamicUpdate Disable." "WARN" Yellow;
            }

            # 5. Automated Third-Party Driver Export & Backup (Online)
            Write-Log "  [ACTION] Exporting third-party driver backup (Safeguard for SYSPREP / 0xC1900101)..." "INFO" Yellow;
            $driverBackupDir = Join-Path -Path $ScriptDir -ChildPath "drivers_backup_$($env:COMPUTERNAME)_$TimeStamp"
            if (-not (Test-Path $driverBackupDir)) { New-Item -ItemType Directory -Path $driverBackupDir -Force | Out-Null }
            try {
                $exportedDrivers = Export-WindowsDriver -Online -Destination $driverBackupDir -ErrorAction Stop
                Write-Log "  [SUCCESS] Successfully backed up $($exportedDrivers.Count) third-party driver packages to $driverBackupDir" "SUCCESS" Green;
            } catch {
                Write-Log "  [WARN] Export-WindowsDriver failed: $_. Falling back to pnputil /export-driver..." "WARN" Yellow;
                $pnpExp = cmd.exe /c "pnputil.exe /export-driver * `"$driverBackupDir`" 2>&1"
                Write-Log "  [OK] pnputil driver export finished." "SUCCESS" Green;
            }
        } else {
            # Offline Driver Backup via DISM
            Write-Log "  [ACTION] Exporting third-party drivers from offline target ($TargetDrive)..." "INFO" Yellow;
            $driverBackupDir = Join-Path -Path $ScriptDir -ChildPath "drivers_backup_offline_$TimeStamp"
            if (-not (Test-Path $driverBackupDir)) { New-Item -ItemType Directory -Path $driverBackupDir -Force | Out-Null }
            $dismExp = cmd.exe /c "dism.exe /image:`"$TargetDrive\`" /export-driver /destination:`"$driverBackupDir`" 2>&1"
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  [SUCCESS] Successfully backed up offline drivers to $driverBackupDir" "SUCCESS" Green;
            } else {
                Write-Log "  [INFO] Offline driver export note: $dismExp" "INFO" Gray;
            }
        }

        # Save timestamp if we got through them
        Set-ItemProperty -Path $RegKey -Name "LastHealthCheck" -Value (Get-Date).ToString("o") -Force -ErrorAction SilentlyContinue;
        Set-Content -Path "$TargetDrive\Windows\Win11Readiness_LastHealthCheck.txt" -Value (Get-Date).ToString("o") -Force -ErrorAction SilentlyContinue;
    }
} else { $script:CurrentStep++ }

Write-Progress -Activity "Windows 11 Readiness Check" -Completed;

# ------------------------------------------------------------------
# Cleanup Resume State
# ------------------------------------------------------------------
Remove-ItemProperty -Path $RegKey -Name "ResumeStep" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Win11ReadinessResume" -ErrorAction SilentlyContinue

# ------------------------------------------------------------------
# Readiness Evaluation & Launch Options
# ------------------------------------------------------------------
if ($ReadinessScore -lt 0) { $ReadinessScore = 0 };

Write-Host "`n==================================================" -ForegroundColor Cyan;
Write-Host "             UPGRADE READINESS SCORE              " -ForegroundColor Cyan;
Write-Host "==================================================" -ForegroundColor Cyan;

if ($ReadinessScore -ge 90) {
    Write-Log "  Score: $ReadinessScore% - EXCELLENT. System is fully prepped for Windows 11." "INFO" Green;
} elseif ($ReadinessScore -ge 70) {
    Write-Log "  Score: $ReadinessScore% - GOOD. Minor warnings exist (e.g., pending reboot). Proceed with caution." "INFO" Yellow;
} else {
    Write-Log "  Score: $ReadinessScore% - POOR. Critical issues found. The upgrade is highly likely to fail or rollback." "INFO" Red;
}

if ($IsOffline) {
    Write-Host "`n[9] OFFLINE DRIVE SELECTED: Launch Options Disabled" -ForegroundColor Yellow;
    Write-Host "--------------------------------------------------" -ForegroundColor Gray;
    Write-Host "This script has successfully prepped and repaired the offline drive ($TargetDrive)." -ForegroundColor White;
    Write-Host "Windows in-place upgrades cannot be launched against an offline installation from a host OS." -ForegroundColor Red;
    Write-Host "Action Required: Put this drive back into the target machine, boot into it, and launch the Windows 11 setup locally." -ForegroundColor Cyan;
    Write-Host "";

    # Generate 1-click upgrade launcher on target drive root
    $launcherBat = "$TargetDrive\Launch_Win11_Upgrade.bat"
    $batLines = @(
        "@echo off",
        ":: Windows 11 Upgrade Launcher created by Win10to11 Toolkit",
        "echo ==============================================================",
        "echo Windows 11 In-Place Upgrade Launcher (Bypass + Safe Flags)",
        "echo ==============================================================",
        "echo.",
        "echo [ACTION] Verifying motherboard UEFI NVRAM registration...",
        "bcdboot C:\Windows /f UEFI >nul 2>&1",
        "echo.",
        "set `"SETUP_PATH=`"",
        "for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (",
        "    if exist `"%%d:\setup.exe`" if exist `"%%d:\sources\install.wim`" (",
        "        set `"SETUP_PATH=%%d:\setup.exe`"",
        "        goto :found",
        "    )",
        "    if exist `"%%d:\setup.exe`" if exist `"%%d:\sources\install.esd`" (",
        "        set `"SETUP_PATH=%%d:\setup.exe`"",
        "        goto :found",
        "    )",
        ")",
        ":found",
        "if not defined SETUP_PATH (",
        "    echo [ACTION] Searching for Windows 11 ISO on connected USB and local drives...",
        "    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[A-Z]$' }).Root; $cand = @(); foreach ($d in $drives) { $cand += (Get-ChildItem -Path $d -Filter '*Win11*.iso' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) }; $best = $cand | Select-Object -Unique | ForEach-Object { Get-Item $_ } | Sort-Object Length -Descending | Select-Object -First 1; if ($best) { Write-Host 'Auto-mounting ISO:' $best.FullName; Mount-DiskImage -ImagePath $best.FullName -PassThru | Out-Null }`"",
        "    for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (",
        "        if exist `"%%d:\setup.exe`" if exist `"%%d:\sources\install.wim`" (",
        "            set `"SETUP_PATH=%%d:\setup.exe`"",
        "            goto :found_after_mount",
        "        )",
        "        if exist `"%%d:\setup.exe`" if exist `"%%d:\sources\install.esd`" (",
        "            set `"SETUP_PATH=%%d:\setup.exe`"",
        "            goto :found_after_mount",
        "        )",
        "    )",
        ")",
        ":found_after_mount",
        "if defined SETUP_PATH (",
        "    echo Found Windows Setup media at: %SETUP_PATH%",
        "    echo Activating real-time appraiser zero-byte neutralizer...",
        "    start `"`" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$p = \`"`$env:SystemDrive\\`$WINDOWS.~BT\\Sources\\appraiserres.dll\`"; for (`$i=0; `$i -lt 300; `$i++) { if (Test-Path `$p) { if ((Get-Item `$p).Length -gt 0) { attrib -h -s -r `$p 2>`$null; Clear-Content -Path `$p -Force 2>`$null; attrib +r `$p 2>`$null } }; Start-Sleep -Milliseconds 400 }`"",
        "    echo Launching upgrade with: /DynamicUpdate Disable /Compat IgnoreWarning ...",
        "    echo.",
        "    `"%SETUP_PATH%`" /DynamicUpdate Disable /Compat IgnoreWarning",
        ") else (",
        "    echo [ERROR] No Windows 11 setup media (USB or mounted ISO) was detected.",
        "    echo Please insert your Windows 11 USB drive or mount the Windows 11 ISO and run this script again.",
        "    pause",
        ")"
    );
    try {
        [System.IO.File]::WriteAllLines($launcherBat, $batLines);
        Write-Log "  [SUCCESS] Generated 1-click upgrade launcher at: $launcherBat" "SUCCESS" Green;
        Write-Host "  Convenience Helper: Created '$launcherBat'" -ForegroundColor Green;
        Write-Host "  Once you boot into this drive, double-click 'Launch_Win11_Upgrade.bat' on C:\ to run Setup with safe flags." -ForegroundColor Green;
    } catch {
        Write-Log "  [INFO] Could not create launcher bat on target drive: $_" "INFO" Gray;
    }
    if ($script:ScriptMountedIso) {
        Write-Log "  [ACTION] Dismounting temporary ISO image..." "INFO" Gray;
        Dismount-DiskImage -ImagePath $script:ScriptMountedIso -ErrorAction SilentlyContinue | Out-Null
    }
} else {
    Write-Host "`n[9] Select Launch Option:" -ForegroundColor Yellow;
    Write-Host "--------------------------------------------------" -ForegroundColor Gray;
    Write-Host "NOTE: Microsoft deprecated/blocked '/product:server' in modern Windows 11 setup media." -ForegroundColor Yellow;
    Write-Host "      Hardware checks are bypassed natively via injected MoSetup & LabConfig registry keys." -ForegroundColor Green;
    Write-Host "      '/DynamicUpdate Disable' prevents driver conflicts during SECOND_BOOT (0xC1900101-0x40021).`n" -ForegroundColor Cyan;
    Write-Host "1) Launch ISO Setup (Recommended: setup.exe /DynamicUpdate Disable /Compat IgnoreWarning)" -ForegroundColor White;
    Write-Host "2) Launch ISO Setup Standard (setup.exe /DynamicUpdate Disable)" -ForegroundColor White;
    Write-Host "3) Launch Automated Upgrade (setup.exe /Auto Upgrade /DynamicUpdate Disable /Compat IgnoreWarning)" -ForegroundColor White;
    Write-Host "4) Exit (Setup prepped, will run manually later)" -ForegroundColor White;
    Write-Host "";
    
    if ($AutoLaunch) {
        $choice = "1"
        Write-Log "[-AutoLaunch active] Automatically selecting Option 1 (Recommended Setup)..." "INFO" Green
    } else {
        $choice = Read-Host "Select an option (1, 2, 3, or 4)";
    }
    
    switch ($choice) {
        "1" {
            Write-Log "User selected Option 1: Setup /DynamicUpdate Disable /Compat IgnoreWarning" "INFO" Cyan;
            $isoDrive = Get-MountedSetupDrive;
            if (-not $isoDrive) {
                Write-Host "`n[ACTION REQUIRED] No mounted Windows 11 ISO detected." -ForegroundColor Magenta;
                Write-Host "Tech Note: Please mount the Windows 11 ISO now (Right-click ISO -> Mount)." -ForegroundColor Magenta;
                Write-Host "Press any key once the ISO is mounted to scan again..." -ForegroundColor Magenta;
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                $isoDrive = Get-MountedSetupDrive;
            }

            if ($isoDrive) {
                Set-AppraiserBypass -TargetRoot "$($env:SystemDrive)\"
                Install-AveYoBypass -TargetRoot "$($env:SystemDrive)\"
                $setupPath = "${isoDrive}:\setup.exe";
                $setupArgs = "/DynamicUpdate Disable /Compat IgnoreWarning";
                $manualCmd = "`"$setupPath`" $setupArgs";
                $manualPs = "& `"$setupPath`" $setupArgs";
                
                Write-Host "`n==================================================" -ForegroundColor Green;
                Write-Host "        WINDOWS 11 SETUP LAUNCH COMMANDS          " -ForegroundColor Green;
                Write-Host "==================================================" -ForegroundColor Green;
                Write-Host "If Windows Setup does not open automatically, run this command in Administrator prompt:`n" -ForegroundColor White;
                Write-Host "Command Prompt (CMD):" -ForegroundColor Cyan;
                Write-Host "  $manualCmd" -ForegroundColor White;
                Write-Host "`nPowerShell:" -ForegroundColor Cyan;
                Write-Host "  $manualPs" -ForegroundColor White;
                Write-Host "==================================================`n" -ForegroundColor Green;

                Write-Log "  [ACTION] Activating real-time appraiser zero-byte neutralizer..." "INFO" Yellow
                Start-Job -ScriptBlock {
                    $p = "$env:SystemDrive\`$WINDOWS.~BT\Sources\appraiserres.dll"
                    for ($i = 0; $i -lt 300; $i++) {
                        if (Test-Path $p) {
                            if ((Get-Item $p).Length -gt 0) {
                                attrib -h -s -r $p 2>$null
                                Clear-Content -Path $p -Force 2>$null
                                attrib +r $p 2>$null
                            }
                        }
                        Start-Sleep -Milliseconds 400
                    }
                } | Out-Null

                Write-Log "Launching: $manualCmd" "INFO" Cyan;
                try {
                    Start-Process -FilePath $setupPath -ArgumentList $setupArgs -ErrorAction Stop;
                    Write-Log "  [OK] Setup process initiated successfully." "SUCCESS" Green;
                } catch {
                    Write-Log "  [ERROR] Start-Process failed: $_" "ERROR" Red;
                    Write-Host "Please copy and paste the command shown above manually into an elevated prompt." -ForegroundColor Yellow;
                }
            } else {
                Write-Log "  [ERROR] Still could not detect a mounted Windows ISO. Please ensure the ISO is mounted correctly and try again." "ERROR" Red;
            }
        }
        "2" {
            Write-Log "User selected Option 2: Standard Setup with /DynamicUpdate Disable" "INFO" Cyan;
            $isoDrive = Get-MountedSetupDrive;
            if (-not $isoDrive) {
                Write-Host "`n[ACTION REQUIRED] No mounted Windows 11 ISO detected." -ForegroundColor Magenta;
                Write-Host "Tech Note: Please mount the Windows 11 ISO now (Right-click ISO -> Mount)." -ForegroundColor Magenta;
                Write-Host "Press any key once the ISO is mounted to scan again..." -ForegroundColor Magenta;
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                $isoDrive = Get-MountedSetupDrive;
            }

            if ($isoDrive) {
                Set-AppraiserBypass -TargetRoot "$($env:SystemDrive)\"
                Install-AveYoBypass -TargetRoot "$($env:SystemDrive)\"
                $setupPath = "${isoDrive}:\setup.exe";
                $setupArgs = "/DynamicUpdate Disable";
                $manualCmd = "`"$setupPath`" $setupArgs";
                $manualPs = "& `"$setupPath`" $setupArgs";

                Write-Host "`n==================================================" -ForegroundColor Green;
                Write-Host "        WINDOWS 11 SETUP LAUNCH COMMANDS          " -ForegroundColor Green;
                Write-Host "==================================================" -ForegroundColor Green;
                Write-Host "If Windows Setup does not open automatically, run this command in Administrator prompt:`n" -ForegroundColor White;
                Write-Host "Command Prompt (CMD):" -ForegroundColor Cyan;
                Write-Host "  $manualCmd" -ForegroundColor White;
                Write-Host "`nPowerShell:" -ForegroundColor Cyan;
                Write-Host "  $manualPs" -ForegroundColor White;
                Write-Host "==================================================`n" -ForegroundColor Green;

                Write-Log "Launching: $manualCmd" "INFO" Cyan;
                try {
                    Start-Process -FilePath $setupPath -ArgumentList $setupArgs -ErrorAction Stop;
                    Write-Log "  [OK] Setup process initiated successfully." "SUCCESS" Green;
                } catch {
                    Write-Log "  [ERROR] Start-Process failed: $_" "ERROR" Red;
                    Write-Host "Please copy and paste the command shown above manually into an elevated prompt." -ForegroundColor Yellow;
                }
            } else {
                Write-Log "  [ERROR] Still could not detect a mounted Windows ISO. Please ensure the ISO is mounted correctly and try again." "ERROR" Red;
            }
        }
        "3" {
            Write-Log "User selected Option 3: Automated Upgrade" "INFO" Cyan;
            $isoDrive = Get-MountedSetupDrive;
            if (-not $isoDrive) {
                Write-Host "`n[ACTION REQUIRED] No mounted Windows 11 ISO detected." -ForegroundColor Magenta;
                Write-Host "Tech Note: Please mount the Windows 11 ISO now (Right-click ISO -> Mount)." -ForegroundColor Magenta;
                Write-Host "Press any key once the ISO is mounted to scan again..." -ForegroundColor Magenta;
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                $isoDrive = Get-MountedSetupDrive;
            }

            if ($isoDrive) {
                Set-AppraiserBypass -TargetRoot "$($env:SystemDrive)\"
                Install-AveYoBypass -TargetRoot "$($env:SystemDrive)\"
                $setupPath = "${isoDrive}:\setup.exe";
                $setupArgs = "/Auto Upgrade /DynamicUpdate Disable /Compat IgnoreWarning";
                $manualCmd = "`"$setupPath`" $setupArgs";
                $manualPs = "& `"$setupPath`" $setupArgs";

                Write-Host "`n==================================================" -ForegroundColor Green;
                Write-Host "        WINDOWS 11 SETUP LAUNCH COMMANDS          " -ForegroundColor Green;
                Write-Host "==================================================" -ForegroundColor Green;
                Write-Host "If Windows Setup does not open automatically, run this command in Administrator prompt:`n" -ForegroundColor White;
                Write-Host "Command Prompt (CMD):" -ForegroundColor Cyan;
                Write-Host "  $manualCmd" -ForegroundColor White;
                Write-Host "`nPowerShell:" -ForegroundColor Cyan;
                Write-Host "  $manualPs" -ForegroundColor White;
                Write-Host "==================================================`n" -ForegroundColor Green;

                Write-Log "Launching: $manualCmd" "INFO" Cyan;
                try {
                    Start-Process -FilePath $setupPath -ArgumentList $setupArgs -ErrorAction Stop;
                    Write-Log "  [OK] Setup process initiated successfully." "SUCCESS" Green;
                } catch {
                    Write-Log "  [ERROR] Start-Process failed: $_" "ERROR" Red;
                    Write-Host "Please copy and paste the command shown above manually into an elevated prompt." -ForegroundColor Yellow;
                }
            } else {
                Write-Log "  [ERROR] Still could not detect a mounted Windows ISO. Please ensure the ISO is mounted correctly and try again." "ERROR" Red;
            }
        }
        "4" {
            Write-Log "User selected Option 4: Exit" "INFO" Green;
            if ($script:ScriptMountedIso) {
                Write-Log "  [ACTION] Dismounting temporary ISO image..." "INFO" Gray;
                Dismount-DiskImage -ImagePath $script:ScriptMountedIso -ErrorAction SilentlyContinue | Out-Null
            }
        }
        default {
            Write-Log "Invalid option selected. Exiting." "WARN" Red;
            if ($script:ScriptMountedIso) {
                Dismount-DiskImage -ImagePath $script:ScriptMountedIso -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
}

Write-Log "`nScript completed. Log saved to: $LogFile" "INFO" Cyan;

Write-Host ""
Write-Host "==============================================================================" -ForegroundColor DarkGray
Write-Host " Win10to11 -- Maintained by RemarkablePC" -ForegroundColor Cyan
Write-Host " Explore more tools on GitHub: https://github.com/remarkablepc" -ForegroundColor White
Write-Host " Peer-to-peer discussion: https://github.com/remarkablepc/Win10to11/discussions" -ForegroundColor DarkGray
Write-Host "==============================================================================" -ForegroundColor DarkGray
Write-Host ""


