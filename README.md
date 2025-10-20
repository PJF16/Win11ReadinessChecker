# 🖥️ Windows 11 Readiness Checker (GPO-friendly)

Lightweight, domain-ready PowerShell solution to assess Windows 11 hardware readiness across your fleet and collect results centrally — without agents or extra dependencies.  

---

## ✨ Features
- 🛑 Runs **once per device** (marker file in `C:\ProgramData\Win11Check\`)  
- 🪟 Skips devices already on **Windows 11** (build ≥ 22000)  
- ⏲️ Waits **5 minutes after boot** to ensure network/TPM/UEFI are ready  
- 💻 Forces **64-bit PowerShell** relaunch if needed  
- 🔍 Performs detailed checks:
  - 💾 **Storage** (OS disk size ≥ 64 GB)  
  - 🧠 **Memory** (≥ 4 GB)  
  - 🔐 **TPM** (present, TPM 2.0)  
  - ⚙️ **CPU** (64-bit, min clock, logical cores, family validation via embedded C#)  
  - 🔒 **Secure Boot** (cmdlet with **Registry fallback**)  
  - ⭐ Special case: **Intel i7-7820HQ** allowed only on certain OEM devices (Surface Studio 2, Precision 5520)  

---

## 📂 Output & Collection
- Writes compact JSON per run: `HOSTNAME-YYYYMMDDTHHMMSS.json`  
- Saves to a **network share** (e.g., `\\server\share\win11check`)  
- If the share is unavailable, logs are queued in  
  `C:\ProgramData\Win11Check\Queue` and **auto-flushed** next run ✅  

---

## 🛠️ Deployment Options
- **GPO Startup Script** (via `.bat` wrapper or ExecutionPolicy GPO)  
- **Recommended: GPO Scheduled Task**  
  - 🔄 Trigger: **At startup**, Delay: **5 minutes**  
  - 👤 Run as: **SYSTEM**  
  - ▶️ Action:  
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File \\domain\SYSVOL\...\Win11Readiness.ps1
    ```
  - 🌐 Option: “Run only if network is available”  

---

## 🔑 Permissions
- Grant **Domain Computers** (or a dedicated group) 🖧 **Modify** rights on the target share **and** NTFS folder so machine accounts can write logs.  

---

## 📊 Result Semantics
- `returnCode`:  
  - ✅ `0 = CAPABLE`  
  - ❌ `1 = NOT CAPABLE`  
  - ❓ `-1 = UNDETERMINED`  
  - ⚠️ `-2 = FAILED TO RUN`  

- `logging`: human-readable per-check trail  
- `returnReason`: comma-separated failed checks  

---

## ⚡ Requirements 
- PowerShell 5+  
- Domain environment (for GPO + machine-account writes)  
- Network share reachable from clients  

---

## ❓ Why this project?
- 🕵️ **No agents, no SCCM/Intune required**  
- 🛡️ Robust in real-world AD: handles early-boot timing, 64-bit host, and Secure Boot quirks  
- 🔂 Safe to run repeatedly but designed to execute **exactly once per device** via a marker  

---

# 📈 Reporting Script (CSV + HTML dashboard)

Once JSON logs are landing in your share, use this script to generate:  
- `Win11Check_Report.csv` (full detail per device)  
- `Win11Check_Report.html` (summary dashboard with SVG charts)

### Usage
```powershell
# Example
.\report.ps1 -LogPath \\server\share\win11check -OutDir C:\Reports\Win11
```

- **`-LogPath`**: Folder containing the collected JSON logs  
- **`-OutDir`**: Output directory for CSV + HTML (created if missing)

### What it does
- Parses each `*.json` file (expects `logging`, `returnCode`, `returnResult`, `returnReason`)  
- Extracts PASS/FAIL/UNDETERMINED for: **Storage**, **Memory**, **TPM**, **SecureBoot**, **Processor**  
- Pulls helpful values from the log stream (disk size, memory, TPM version, CPU details)  
- Builds an **HTML dashboard** with:
  - Summary cards (counts of CAPABLE / NOT CAPABLE / UNDETERMINED)
  - Bar chart for overall result distribution  
  - Bar charts for PASS/FAIL/UNDETERMINED per criterion  
  - Top failure reasons (top 10)  
  - Preview table (first 100 rows) with hardware signals  

---

## 📜 `report.ps1`
The full script is included in the repository as `report.ps1`.  
Run it manually or schedule it to generate regular readiness reports.

---

## 🧪 Verifying the pipeline

1. **Deploy** the collector via GPO and confirm JSON files appear in your share.  
2. **Run** the report locally (or as a scheduled task on an admin box):
   ```powershell
   .\report.ps1 -LogPath \\server\share\win11check -OutDir C:\Reports\Win11
   ```
3. **Open** `Win11Check_Report.html` for the overview; use `Win11Check_Report.csv` for Excel/BI.

---

## 🧰 Troubleshooting

- **“No JSON logs found”**  
  Check share path, permissions for machine accounts, and that the collector actually ran.

- **Charts look empty**  
  If all results are the same (e.g., all CAPABLE), the other charts will legitimately show zeros.

- **Filename parsing**  
  The report expects `HOST-YYYYMMDDTHHMMSS.json`. If missing, it falls back to the file’s creation time.
