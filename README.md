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
- Windows 10/11  
- PowerShell 5+  
- Domain environment (for GPO + machine-account writes)  
- Network share reachable from clients  

---

## ❓ Why this project?
- 🕵️ **No agents, no SCCM/Intune required**  
- 🛡️ Robust in real-world AD: handles early-boot timing, 64-bit host, and Secure Boot quirks  
- 🔂 Safe to run repeatedly but designed to execute **exactly once per device** via a marker  
