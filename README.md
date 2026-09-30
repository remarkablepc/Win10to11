<p align="center">
  <a href="https://github.com/remarkablepc/Win10to11/releases/latest">
    <img src="https://img.shields.io/badge/Release-v0.9.0--beta-orange?logo=github&logoColor=white" alt="Latest Release">
  </a>
  <a href="https://github.com/remarkablepc/Win10to11/releases">
    <img src="https://img.shields.io/badge/Downloads-Releases-2ea44f?logo=github&logoColor=white" alt="Downloads">
  </a>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20(x64)-0078D4?logo=windows&logoColor=white" alt="Platform: Windows">
  <a href="https://www.paypal.com/ncp/payment/EKH76RTYHH24S?uhm=Win10to11">
    <img src="https://img.shields.io/badge/Say%20Thanks-PayPal-00457C?logo=paypal&logoColor=white" alt="Say Thanks on PayPal">
  </a>
  <a href="https://github.com/sponsors/remarkablepc?uhm=Win10to11">
    <img src="https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA?logo=githubsponsors&logoColor=white" alt="GitHub Sponsors">
  </a>
</p>

# Win10to11
### *A practical PowerShell toolkit to diagnose, repair, and prepare stubborn Windows 10 PCs for Windows 11 upgrades.*
**Engineered by [RemarkablePC](https://github.com/remarkablepc) to dramatically increase first-pass upgrade success rates on live host machines and offline USB-docked drives.**

<p align="center">
  <a href="https://github.com/remarkablepc/Win10to11/archive/refs/heads/main.zip">
    <img src="https://img.shields.io/badge/⬇️%20Download-Source%20Code%20(.ZIP)-2ea44f?style=for-the-badge&logo=windows11&logoColor=white" height="38" alt="Download ZIP">
  </a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/remarkablepc/Win10to11/releases/latest">
    <img src="https://img.shields.io/badge/📦%20Releases-Latest%20Version-0969da?style=for-the-badge&logo=github&logoColor=white" height="38" alt="GitHub Releases">
  </a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/sponsors/remarkablepc?uhm=Win10to11">
    <img src="https://img.shields.io/badge/💖%20Sponsor-GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white" height="38" alt="Sponsor on GitHub">
  </a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://www.paypal.com/ncp/payment/EKH76RTYHH24S?uhm=Win10to11">
    <img src="https://img.shields.io/badge/☕%20Say%20Thanks-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white" height="38" alt="Say Thanks via PayPal">
  </a>
</p>

---

## ⚡ What is Win10to11?

**Win10to11** is an open-source PowerShell script designed for bench technicians, sysadmins, and advanced users. It automates the tedious, repetitive troubleshooting required when Windows 10 repeatedly fails or rolls back during an in-place upgrade to Windows 11.

Instead of waiting an hour for Windows Setup to crash and sifting through cryptic setup logs, Win10to11 performs pre-flight checks and neutralizes predictable blockers—such as leftover antivirus filter drivers, broken recovery partitions, MBR disk layouts, and conflicting OEM drivers—*before* setup runs.

---

## 🛠️ Verified Field Scenarios

| Environment / Hardware | Failure Symptom | Underlying Root Cause | Win10to11 Action & Outcome |
| :--- | :--- | :--- | :--- |
| **Dell Latitude (Workstation SSD)** | Rollback at SafeOS (`0x801F0005` / `0x80070714`) | Uninstalled Avast left active kernel minifilters (`aswSnx.sys`, Altitude 137600) and disk `UpperFilter` (`aswArDisk`) blocking SafeOS WIM reparse queries. | Automatically unhooked filter services, sanitized class `UpperFilters` to `partmgr`. **In-place upgrade succeeded.** |
| **HP EliteDesk (Enterprise PC)** | Pre-Finalize Crash (`0x80070714`) | Missing or damaged `Winre.wim` and broken partition GUID in `ReAgent.xml`. | Auto-detected mounted ISO, unpacked clean `Winre.wim` in ~15s, re-indexed recovery environment. **Upgrade completed.** |
| **Lenovo ThinkCentre (Docked Drive)** | Blocked by Legacy MBR partition style | Drive connected via USB bench dock; Windows native `mbr2gpt` cannot convert secondary or external disks. | Verified BitLocker status, executed safe dry-run test, created binary MBR backup, converted to GPT via `gptgen`, staged ESP + BCD. **Booted UEFI and upgraded.** |

---

## 🛡️ Common Upgrade Blockers Addressed

| Error Code / Blocker | Root Cause | What Win10to11 Does |
| :--- | :--- | :--- |
| **`0x801F0005` / `0x80070714`**<br>*(SafeOS Driver Migration Crash)* | Antivirus minifilters (`aswMonFlt`, `aswSnx`, `SRTSPX64`) or legacy disk `UpperFilters` (`aswArDisk`, `Snapman`) intercepting mounted SafeOS WIM reparse points. | **Minifilter Audit & Cleanup**: Scans services with an `Instances` key against a Microsoft core whitelist, unhooks third-party filters, and restores device class `UpperFilters` (`partmgr`, `volsnap`, `kbdclass`) to safe defaults via direct registry writes. |
| **`0x80070714`**<br>*(WinRE Staging Failure)* | Missing `Winre.wim`, corrupted recovery partition, or stale partition GUIDs in `ReAgent.xml`. | **Recovery Audit & Rapid Extraction**: Checks recovery health. If missing or damaged, prompts the user to mount Windows 11 media, extracts `Winre.wim` directly from `sources\install.esd` or `install.wim` via 7-Zip/NanaZip (or native DISM fallback), and re-binds recovery pointers. |
| **`0xC1900101 - 0x40021`**<br>*(Second-Boot Sysprep Rollback)* | Generic drivers from Dynamic Update colliding with OEM hardware, corrupted user profile `.bak` keys, or corrupt performance counters. | **Pre-Emptive Cleanup**: Backs up all OEM drivers via `Export-WindowsDriver`, cleans orphaned duplicate profile keys, rebuilds performance counters (`lodctr /R`), and launches setup with `/DynamicUpdate Disable`. |
| **Hardware Rejections**<br>*(CPU, TPM 2.0, SecureBoot, RAM)* | Windows 11 hardware checks blocking otherwise capable machines. | **Automated Compatibility Bypasses**: Injects standard `MoSetup` and `LabConfig` registry bypasses; dynamically generates a local 0-byte `appraiserres.dll` hardware check neutralizer (clean-room compliant). |
| **Legacy MBR Partition Style** | Windows 11 requires UEFI boot and GPT partition layout. | **Non-Destructive In-Place Conversion**: Runs native `mbr2gpt` on live host systems. For offline docked drives, verifies BitLocker status, runs a read-only dry run via on-demand `gptgen`, saves a binary `.bin` MBR backup, converts partition tables, and guides EFI System Partition (ESP) & BCD creation. |
| **Storage Accelerator Conflicts** | Samsung RAPID Mode RAM caching or outdated Intel RST drivers. | **Compatibility & Driver Checks**: Warns against volatile RAM write-caching and checks Intel RST driver revisions against Microsoft block thresholds (`< 15.9.8.1050` or `17.0.x - 17.5.x`). |

---

## 📦 Quick Start Guide

### Option 1: Double-Click Launcher (Interactive Menu)
1. Download the latest source package: [**Download ZIP**](https://github.com/remarkablepc/Win10to11/archive/refs/heads/main.zip).
2. Extract the archive to a folder (e.g. `C:\Win10to11`).
3. Right-click **`run.bat`** and select **Run as Administrator**.
4. Follow the interactive numbered menu prompts.

### Option 2: PowerShell Command Line (Technician / Headless)
Open an elevated Administrator PowerShell prompt:

```powershell
# Interactive run on the current live machine
.\Win10to11.ps1

# Unattended run: apply bypasses, backup drivers, and launch setup automatically
.\Win10to11.ps1 -AutoLaunch -BypassAll

# Fast run (skips SFC/DISM if drive health has already been verified)
.\Win10to11.ps1 -AutoLaunch -BypassAll -SkipHealthChecks

# Bench technician mode: Target an offline customer drive docked as P:
.\Win10to11.ps1 -TargetDriveLetter P: -BypassAll
```

### CLI Parameter Reference

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-TargetDriveLetter` | String | Current System (`C:`) | Target Windows partition drive letter (e.g. `O:`, `P:`). Also accepts disk numbers (e.g. `0`). |
| `-SkipElevation` | Switch | `$false` | Skips self-elevation prompt (for automated deployment or RMM scripts). |
| `-AutoLaunch` | Switch | `$false` | Automatically launches Windows 11 Setup once all readiness checks pass. |
| `-BypassAll` | Switch | `$false` | Headless mode: auto-approves hardware bypasses, driver backups, and defaults without pauses. |
| `-SkipHealthChecks` | Switch | `$false` | Skips CHKDSK, SFC, and DISM scans (saves 20-30 minutes if health was already verified). |

---

## 💻 Console Output Preview

Here is an example of what running `Win10to11` on a bench target looks like in the terminal:

```text
====================================================================
  Win10to11 - Windows 10 to 11 In-Place Upgrade & Repair Toolkit
  Target: Offline Windows Partition (Drive P:)
====================================================================
[1/10] Pre-Flight Health Check... [OK: Verified within 24h]
[2/10] Auditing Storage Drivers & Minifilters...
  [WARN] Third-party minifilter detected: aswSnx (Altitude: 137600)
  [ACTION] Neutralizing rogue filter driver service (Start=4)...
  [OK] UpperFilters on DiskDrive class sanitized to 'partmgr'.
[3/10] Auditing Windows Recovery Environment (WinRE)...
  [ACTION] Extracting clean Winre.wim from install.esd (~15s)...
  [SUCCESS] Offline WinRE rebuilt and registered successfully.
[4/10] Partition Table & Bootloader Verification...
  [OK] BitLocker check passed. Disk verified as GPT.
[5/10] Staging Compatibility Bypasses...
  [OK] Injected MoSetup & LabConfig bypass keys.
  [OK] Staged 0-byte appraiserres.dll hardware check neutralizer.
>>> System is prepped and ready for Windows 11 Setup! <<<
```

---

## 🚀 Key Features

* **Dual-Mode Operation (Live Host or External Dock)**:
  * Run directly on the live Windows 10 workstation being upgraded.
  * Or dock a customer's drive via an external USB/SATA bench dock (`-TargetDriveLetter P:`), load offline hives, repair components, and generate a 1-click self-contained launcher on the customer's desktop.
* **Minifilter Audit & Cleanup**:
  * Scans across 12+ security vendors: **Avast/AVG, Symantec/Norton, McAfee, Kaspersky, Bitdefender, Trend Micro, Sophos, Malwarebytes, Webroot, ESET, and Acronis True Image**.
  * Unhooks unknown third-party kernel filter drivers possessing an `Instances` key not on Microsoft's core whitelist.
  * Sanitizes DiskDrive (`partmgr`), Volume (`volsnap`), and Keyboard (`kbdclass`) `UpperFilters`.
* **Automated OEM Driver Backup**:
  * Exports all installed third-party drivers to `$ScriptDir\drivers_backup_<PC>_<Timestamp>` using `Export-WindowsDriver` before setup runs.
* **Rapid WinRE Recovery Repair**:
  * Audits `ReAgent.xml` and validates `Winre.wim` integrity.
  * If WinRE is missing or damaged, prompts the user to mount Windows 11 media and extracts `Winre.wim` directly from `sources\install.esd` or `install.wim` using 7-Zip/NanaZip in ~15 seconds (with automatic fallback to native Windows DISM if archive tools are not installed).
* **Non-Destructive MBR-to-GPT Conversion with Safety Rails**:
  * *Live Host:* Runs validated `mbr2gpt.exe /convert /disk:N /allowFullOS`.
  * *Offline Dock:* Performs an active **BitLocker pre-check** to prevent partition corruption on encrypted drives. Prompts to download open-source `gptgen` on-demand from GitHub, executes a read-only dry run, auto-shrinks partition space if needed, saves a binary `.bin` MBR backup, and guides EFI System Partition (ESP) & BCD creation.
* **Health Check Caching**:
  * Includes `-SkipHealthChecks` and 24-hour verification markers to eliminate redundant 30-minute SFC/DISM re-scans during iterative bench testing.

---

<details>
<summary><b>💡 Click to Expand: Why Win10to11 Exists (The Technician's Story)</b></summary>

<br>

If you have ever spent hours on a customer PC or your own workstation fighting a Windows 10 to 11 upgrade that stubbornly refuses to complete, you know this exact loop:

```text
┌──────────────────────────────────────────────┐
│  1. Launch Windows Setup                     │
│  2. Wait 45 minutes (creeps to 73%)          │
│  3. Crash & Rollback: 0x80070714 / 0x801F0005│
│  4. Dig through 150MB of setupact.log        │
│  5. 4+ hours wasted... back to square one!   │
└───────────────────────┬──────────────────────┘
                        ▼
            [Enter Win10to11 Toolkit]
```

You are greeted by an opaque hex code like **`0x80070714`**, **`0x801F0005`**, or **`0xC1900101 - 0x40021`**. Then starts the manual archaeology:
- Sifting through hundreds of thousands of lines in `C:\$WINDOWS.~BT\Sources\Panther\setupact.log`.
- Discovering that an uninstalled third-party antivirus secretly left behind an active kernel minifilter (`aswSnx.sys`, `SRTSPX64.SYS`) or a disk `UpperFilter` (`aswArDisk`) that intercepted the SafeOS WIM mount and returned `ERROR_FLT_INVALID_NAME_REQUEST`.
- Finding that the Windows Recovery Environment (`Winre.wim`) is missing or has a desynchronized partition GUID in `ReAgent.xml`.
- Struggling to convert an MBR disk to GPT on a drive pulled from a non-booting PC into an external bench dock where Microsoft's native `mbr2gpt` refuses to operate.
- Dealing with arbitrary CPU, TPM 2.0, RAM, or SecureBoot blocks on otherwise fast, capable hardware.

**I built Win10to11 because I was tired of Windows 10 failing to upgrade to Windows 11 over and over again, wasting countless hours of manual troubleshooting on the bench.**

Win10to11 addresses these predictable friction points before Windows Setup executes, significantly improving upgrade reliability and saving valuable bench time.

</details>

---

<details>
<summary><b>🔄 Click to Expand: Upgrade Pipeline Workflow</b></summary>

<br>

```text
┌────────────────────────────────────────────────────────┐
│                   START Win10to11                      │
└───────────────────────────┬────────────────────────────┘
                            │
              [Select Execution Environment]
             ┌──────────────┴──────────────┐
             ▼                             ▼
       Live Host PC              External USB/SATA Dock
             │                             │
             └──────────────┬──────────────┘
                            ▼
    [1. Pre-Flight Health: SFC / DISM / CHKDSK Verification]
                            │
                            ▼
    [2. Minifilter Audit: Neutralize Rogue AV Filters & UpperFilters]
                            │
                            ▼
    [3. Recovery Check: Extract Fresh Winre.wim if Damaged/Missing]
                            │
                            ▼
    [4. Partition Check: BitLocker Test -> Convert MBR to GPT -> ESP]
                            │
                            ▼
    [5. Driver Safety: Export Installed OEM Drivers to Backup Folder]
                            │
                            ▼
    [6. Compatibility: Inject MoSetup, LabConfig & Neutralizer]
                            │
                            ▼
    [7. Launch Setup: Run with /DynamicUpdate Disable]
                            │
                            ▼
    [🎉 Successful Windows 11 Desktop Migration!]
```

</details>

---

## ⚠️ Safety Best Practices for Technicians

* **Always Back Up Data**: While Win10to11 incorporates safety rails (dry runs, MBR `.bin` backups, and non-destructive operations), operating system upgrades and partition modifications carry inherent risks. **Always ensure critical user data is backed up before proceeding.**
* **BitLocker Awareness**: If BitLocker is active on an MBR disk, ensure you have the 48-digit recovery key and suspend protection prior to partition conversion.
* **Basic Disks Only**: Partition conversion tools like `gptgen` and `mbr2gpt` support Windows Basic Disks; Dynamic Disks cannot be converted using these tools.

---

## 🔒 Clean Room & On-Demand Architecture

* **Zero Copyright Infringement**: Contains zero proprietary Microsoft binaries or redistributables. The `appraiserres.dll` hardware bypass is generated dynamically in-memory as an empty 0-byte file (the standard Rufus clean-room method).
* **On-Demand Tooling**: Third-party binaries like `gptgen` are **never bundled in the git repository**. When an offline docked disk conversion requires `gptgen`, the script queries GitHub's official release API and downloads the verified open-source release on-demand with technician consent (or uses an existing local copy if already present).

---

## 💼 Explore More Tools by RemarkablePC

Explore more tools, closed-source freeware, web development solutions, and technician utilities on GitHub:
* **[https://github.com/remarkablepc](https://github.com/remarkablepc)**

---

## 💬 Community & Peer Discussions

Peer-to-peer discussions and technician field reports are hosted on GitHub Discussions:
* **[GitHub Discussions](https://github.com/remarkablepc/Win10to11/discussions)**

*(Note: Win10to11 is provided as-is without 1-on-1 technical support).*

---

## ❤️ Community Support & Sponsorship

Win10to11 is **100% free and open source**.

If this script saved you from hours of troubleshooting or helped recover a difficult upgrade, consider buying a coffee or sponsoring development:

* **[☕ Say Thanks via PayPal](https://www.paypal.com/ncp/payment/EKH76RTYHH24S?uhm=Win10to11)**
* **[💖 Sponsor on GitHub Sponsors](https://github.com/sponsors/remarkablepc?uhm=Win10to11)**

---

## ⚖️ License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for more information.  
Third-party utilities downloaded on-demand (such as `gptgen`) remain under their respective open-source licenses (ISC License).
