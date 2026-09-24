<p align="center">
  <a href="https://github.com/remarkablepc/Win10to11/releases/latest">
    <img src="https://img.shields.io/badge/Release-v0.9.0--beta-orange?logo=github&logoColor=white" alt="Latest Release">
    <img src="https://img.shields.io/badge/Status-Public%20Beta-orange" alt="Status">
    <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT">
    <img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg" alt="PowerShell 5.1+">
    <img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20(x64)-0078D4?logo=windows&logoColor=white" alt="Platform: Windows">
  </a>
  <a href="https://www.paypal.com/ncp/payment/EKH76RTYHH24S">
    <img src="https://img.shields.io/badge/Say%20Thanks-PayPal-00457C?logo=paypal&logoColor=white" alt="Say Thanks">
  </a>
  <a href="https://github.com/sponsors/remarkablepc?uhm=Win10to11">
    <img src="https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA?logo=githubsponsors&logoColor=white" alt="GitHub Sponsors">
  </a>
</p>

# Win10to11 – The Autonomous Windows 10 to 11 In-Place Upgrade, Repair & Bypass Toolkit
### *Engineered by RemarkablePC to diagnose, repair, convert, and orchestrate seamless Windows 11 upgrades on supported and unsupported hardware — both on live host PCs and offline docked drives.*

<p align="center">
  <sub>⚠️ <b>Public Beta (v0.9.0-beta)</b>: Feature-complete and engineered for technician bench testing.<br>Community deployment feedback across diverse motherboard and BIOS configurations is welcomed.</sub>
</p>

<br>

**Win10to11** is an all-in-one PowerShell administration and deployment script designed for technicians, sysadmins, and power users. It eliminates the headaches of failed Windows 11 in-place upgrades by diagnosing system readiness, curing stubborn upgrade rollback errors, repairing corrupted boot and recovery partitions, non-destructively converting MBR disks to GPT, backing up third-party drivers, and injecting zero-touch hardware bypasses.

---

## ⚡ The Problems Win10to11 Solves

Standard Windows 11 upgrades frequently fail, rollback, or abort midway due to five primary failure modes:

| Upgrade Blocker / Error | Root Cause | How Win10to11 Solves It |
| :--- | :--- | :--- |
| **`0x801F0005` / `0x80070714`** *(Pre-Finalize Driver Migration Crash)* | Antivirus minifilters (`aswMonFlt`, `aswSnx`, `aswSP`) or legacy storage/SQL filters intercepting mounted SafeOS WIM reparse points | Actively scans and neutralizes third-party filter drivers, cleans storage/keyboard `UpperFilters`, removes rogue `Instances` from the registry, and unhooks legacy filters. |
| **`0x80070714`** *(Pre-Finalize SafeOS Crash)* | Missing `Winre.wim`, corrupted recovery partition, or stale MBR partition GUIDs in `ReAgent.xml` | Auto-extracts pristine `Winre.wim` directly from ISO `install.esd`/`install.wim` in ~15 seconds and re-binds recovery pointers. |
| **`0xC1900101 - 0x40021`** *(Second Boot Sysprep Rollback)* | Conflicting third-party drivers from Dynamic Update, orphaned `.bak` user profiles, or corrupted performance counter tables | Audits and backs up all OEM drivers (`Export-WindowsDriver`), purges duplicate `.bak` profile keys, rebuilds counters (`lodctr /R`), and launches with `/DynamicUpdate Disable`. |
| **Hardware Rejections** *(CPU, TPM 2.0, SecureBoot, RAM)* | Microsoft hardware gatekeeping on older or non-standard machines | Injects comprehensive MoSetup & LabConfig registry bypasses and stages a 0-byte `appraiserres.dll` hardware check neutralizer. |
| **Legacy BIOS / MBR Disks** | Windows 11 mandates UEFI firmware and GPT partition style | Non-destructively converts disks in-place: native `mbr2gpt` for live systems, and bundled `gptgen` with automatic ESP creation for offline USB docks. |
| **Offline Drive Servicing** | Customer drive pulled from a non-booting PC into a workbench USB dock | Full offline targeting: loads offline hives, audits offline components, converts docked disks, generates a 1-click launcher, and pre-stages the target drive. |

---

## 🚀 Key Features

- **Dual-Mode Operation (Live Host or Offline Dock)**:
  Analyze and repair the currently running Windows 10 PC, or plug a customer's drive into a USB/SATA dock and target it directly (`-TargetDriveLetter O:`).
- **Zero-Touch Hardware Bypasses**:
  - Injects `AllowUpgradesWithUnsupportedTPMOrCPU` into `MoSetup`.
  - Injects the complete `LabConfig` suite (`BypassTPMCheck`, `BypassCPUCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`, `BypassStorageCheck`, `BypassDiskCheck`, `BypassNRO`).
  - Automatically stages a zero-byte `appraiserres.dll` dummy bypass file locally on the PC with zero external download dependencies (Rufus technique).
- **Automated OEM Driver Backup**:
  Exports all installed third-party drivers to `$ScriptDir\drivers_backup_<PC>_<Timestamp>` using `Export-WindowsDriver` before the upgrade initiates, safeguarding against driver loss during migration.
- **Universal Minifilter & Driver Heuristics Engine**:
  - Automatically identifies and neutralizes third-party antivirus and backup kernel filter drivers (Avast/AVG, Symantec/Norton, McAfee, Kaspersky, Bitdefender, Trend Micro, Sophos, Malwarebytes, Acronis True Image, and more).
  - Performs generic minifilter altitude discovery: unhooks any non-whitelisted third-party filter driver from `ControlSet001\Services` preventing `0x801F0005` SafeOS WIM mount crashes.
  - Cleans legacy disk, volume, and keyboard `UpperFilters` (such as `aswArDisk`, `Snapman`, `fltsrv`, `klbackupdisk`).
  - Detects Samsung Magician RAPID Mode (RAM caching) and flags known Intel Rapid Storage Technology (RST) driver versions subject to Microsoft upgrade compatibility blocks.
- **Fast WinRE Recovery Repair (~15 Seconds)**:
  Auto-discovers and mounts Windows 11 ISOs, locates 7-Zip or NanaZip, and extracts a pristine `Winre.wim` directly from compressed `install.esd` without needing slow DISM mount passes.
- **Non-Destructive In-Place MBR-to-GPT Conversion**:
  - *Live Host:* Runs validated `mbr2gpt.exe /convert /disk:N /allowFullOS`.
  - *Offline Dock:* Automatically handles 33-sector end-of-disk shrinking, backs up the original MBR to a `.bin` file, converts the partition table using `gptgen`, automatically creates the FAT32 EFI System Partition (ESP), and writes fresh UEFI bootloader files via `bcdboot`.
- **Conflict-Free Setup Launcher**:
  Launches Windows Setup with `/DynamicUpdate Disable /Compat IgnoreWarning`, preventing setup from fetching generic crash-inducing drivers during the final boot phases.
- **Headless & Unattended CLI Support**:
  Automate across your bench or remote management tools using CLI switches (`-AutoLaunch`, `-BypassAll`).

---

## 📦 Quick Start

### Option 1: Double-Click Launcher (GUI / Interactive)
1. Right-click **`run.bat`** and select **Run as Administrator** (it will self-elevate if needed).
2. Follow the guided interactive menu steps.

### Option 2: PowerShell Command Line (Automated / Headless)
Open an elevated PowerShell prompt in the script directory:

```powershell
# Interactive run on current system
.\Win10to11.ps1

# Fully unattended: auto-apply all bypasses, backup drivers, and launch setup
.\Win10to11.ps1 -AutoLaunch -BypassAll

# Service an offline customer drive connected in a USB dock (Drive O:)
.\Win10to11.ps1 -TargetDriveLetter O: -BypassAll
```

### CLI Parameter Reference

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-TargetDriveLetter` | String | Target Windows partition drive letter (e.g. `O:`, `C:`). Also accepts disk numbers (e.g. `0` automatically translates to `O:`). |
| `-SkipElevation` | Switch | Skips the self-elevation check (useful when running inside automated deployment pipelines). |
| `-AutoLaunch` | Switch | Automatically launches setup with recommended flags once all readiness checks pass. |
| `-BypassAll` | Switch | Non-interactive mode: automatically approves hardware bypasses, driver backups, and defaults without pausing for user confirmation. |
| `-SkipHealthChecks` | Switch | Skips CHKDSK, SFC, and DISM scans (recommended when drive health checks have already passed or are running on tight timelines). |

---

## 🛠️ Repository Structure

```text
Win10to11/
├── Win10to11.ps1             # Main PowerShell script
├── run.bat                   # Elevated batch launcher (forwards all CLI arguments)
├── LICENSE                   # MIT License
├── README.md                 # Full repository documentation
└── .gitignore                # Filters logs, driver backups, on-demand tools, and scratch files
```

---

## 🔒 Clean Room & On-Demand Architecture

- **Zero Copyright Infringement:** Contains zero copyrighted or proprietary Microsoft binaries. The `appraiserres.dll` hardware check bypass is generated dynamically on the host machine as an empty dummy file, carrying zero legal or DMCA risk.
- **On-Demand Third-Party Tooling:** Third-party binary tools like `gptgen` are **never stored in the repository**. If MBR-to-GPT conversion is required on an offline docked disk and `gptgen.exe` is not already present, the script automatically resolves and downloads the official release package on-demand from its open-source GitHub repository with user permission.

---

## 💼 More Tools by RemarkablePC

If you find **Win10to11** useful, check out our other software projects:

* **[CCSync](https://github.com/remarkablepc/CCSync)** — *The Privacy-First Contact & Calendar Manager & Sync Suite.* Connects Google, Outlook Classic (MAPI), Apple iCloud, and CardDAV/CalDAV without routing personal data through third-party cloud servers.
* **[AppTransporter](https://github.com/remarkablepc)** — Windows application, user profile, and data migration toolkit designed for rapid PC transfers.
* **[Page2Divi](https://github.com/remarkablepc)** — Automated web layout and content conversion toolkit for WordPress and Divi environments.
* **[WINBARS](https://github.com/remarkablepc)** — Customized Windows taskbar, workspace enhancement, and desktop automation system.

---

## ❤️ Community Support & Sponsorship

Win10to11 is **100% free and open source** for technicians, sysadmins, and everyday users.

If this script saved you hours of troubleshooting, rescued a customer machine from rollback loops, or simplified your bench workflow, consider buying me a coffee or sponsoring continued development:

* **[☕ Say Thanks via PayPal](https://www.paypal.com/ncp/payment/EKH76RTYHH24S)**
* **[💖 Sponsor on GitHub Sponsors](https://github.com/sponsors/remarkablepc?uhm=Win10to11)**

---

## ⚖️ License & Credits

- **Win10to11 Toolkit**: Licensed under the [MIT License](LICENSE).
- **gptgen**: Copyright © 2009–2012 Gábor A. Stefanik, © 2015–2026 Karl Lenz. Licensed under the permissive **ISC License** (see `LICENSE-gptgen.txt`).
