# ==== Ensure 64-bit PowerShell host ====
# Relaunch in 64-bit PowerShell if the script is running under a 32-bit host on a 64-bit OS.
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and [Environment]::Is64BitOperatingSystem) {
    & "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

# ==== One-time execution marker ====
# If the marker file exists, the script has already run on this machine; exit silently.
$markerPath = "C:\ProgramData\Win11Check\done.marker"
if (Test-Path $markerPath) {
    exit 0
}

# ==== Skip if already Windows 11 (by build number) ====
# Windows 11 builds start at 22000. If OS build >= 22000, do nothing.
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $build  = [int]$osInfo.BuildNumber
    if ($build -ge 22000) { exit 0 }
} catch { }

# ==== Optional startup delay ====
# Allow services (network/SMB/TPM/UEFI) to settle after boot.
Start-Sleep -Seconds 300

# ==== Defaults and thresholds ====
$exitCode = 0

[int]$MinOSDiskSizeGB    = 64
[int]$MinMemoryGB        = 4
[Uint32]$MinClockSpeedMHz = 1000
[Uint32]$MinLogicalCores  = 2
[Uint16]$RequiredAddressWidth = 64

# Output target (UNC) and local fallback queue when the share is not reachable.
$OutDir     = 'YOUR_OUT_DIR' #set output dir - e.g. network share
$LocalQueue = 'C:\ProgramData\Win11Check\Queue'

# ==== String constants (logging/result formatting) ====
$PASS_STRING               = "PASS"
$FAIL_STRING               = "FAIL"
$FAILED_TO_RUN_STRING      = "FAILED TO RUN"
$UNDETERMINED_CAPS_STRING  = "UNDETERMINED"
$UNDETERMINED_STRING       = "Undetermined"
$CAPABLE_STRING            = "Capable"
$NOT_CAPABLE_STRING        = "Not capable"
$CAPABLE_CAPS_STRING       = "CAPABLE"
$NOT_CAPABLE_CAPS_STRING   = "NOT CAPABLE"
$STORAGE_STRING            = "Storage"
$OS_DISK_SIZE_STRING       = "OSDiskSize"
$MEMORY_STRING             = "Memory"
$SYSTEM_MEMORY_STRING      = "System_Memory"
$GB_UNIT_STRING            = "GB"
$TPM_STRING                = "TPM"
$TPM_VERSION_STRING        = "TPMVersion"
$PROCESSOR_STRING          = "Processor"
$SECUREBOOT_STRING         = "SecureBoot"
$I7_7820HQ_CPU_STRING      = "i7-7820hq CPU"

# ==== Log formatting templates ====
$logFormat              = '{0}: {1}={2}. {3}; '
$logFormatWithUnit      = '{0}: {1}={2}{3}. {4}; '
$logFormatReturnReason  = '{0}, '
$logFormatException     = '{0}; '
$logFormatWithBlob      = '{0}: {1}. {2}; '

# Result object (default: -2 = script did not run)
$outObject = @{ returnCode = -2; returnResult = $FAILED_TO_RUN_STRING; returnReason = ""; logging = "" }

# ==== Helper: update return code with proper precedence ====
function Private:UpdateReturnCode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(-2, 1)]
        [int] $ReturnCode
    )
    switch ($ReturnCode) {
        0  { if ($outObject.returnCode -eq -2) { $outObject.returnCode = 0 } }
        1  { $outObject.returnCode = 1 }
        -1 { if ($outObject.returnCode -ne 1) { $outObject.returnCode = -1 } }
    }
}

# ==== Embedded C# helper for CPU family validation (matches Win11 CPU rules) ====
$Source = @"
using Microsoft.Win32;
using System;
using System.Runtime.InteropServices;

public class CpuFamilyResult {
    public bool IsValid { get; set; }
    public string Message { get; set; }
}

public class CpuFamily {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_INFO {
        public ushort ProcessorArchitecture;
        ushort Reserved;
        public uint PageSize;
        public IntPtr MinimumApplicationAddress;
        public IntPtr MaximumApplicationAddress;
        public IntPtr ActiveProcessorMask;
        public uint NumberOfProcessors;
        public uint ProcessorType;
        public uint AllocationGranularity;
        public ushort ProcessorLevel;
        public ushort ProcessorRevision;
    }

    [DllImport("kernel32.dll")] internal static extern void GetNativeSystemInfo(ref SYSTEM_INFO lpSystemInfo);

    public enum ProcessorFeature : uint { ARM_SUPPORTED_INSTRUCTIONS = 34 }

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool IsProcessorFeaturePresent(ProcessorFeature processorFeature);

    private const ushort PROCESSOR_ARCHITECTURE_X86 = 0;
    private const ushort PROCESSOR_ARCHITECTURE_ARM64 = 12;
    private const ushort PROCESSOR_ARCHITECTURE_X64 = 9;

    private const string INTEL_MANUFACTURER = "GenuineIntel";
    private const string AMD_MANUFACTURER = "AuthenticAMD";
    private const string QUALCOMM_MANUFACTURER = "Qualcomm Technologies Inc";

    public static CpuFamilyResult Validate(string manufacturer, ushort processorArchitecture) {
        CpuFamilyResult cpuFamilyResult = new CpuFamilyResult();
        if (string.IsNullOrWhiteSpace(manufacturer)) {
            cpuFamilyResult.IsValid = false;
            cpuFamilyResult.Message = "Manufacturer is null or empty";
            return cpuFamilyResult;
        }

        string registryPath = "HKEY_LOCAL_MACHINE\\Hardware\\Description\\System\\CentralProcessor\\0";
        SYSTEM_INFO sysInfo = new SYSTEM_INFO();
        GetNativeSystemInfo(ref sysInfo);

        switch (processorArchitecture) {
            case PROCESSOR_ARCHITECTURE_ARM64:
                if (manufacturer.Equals(QUALCOMM_MANUFACTURER, StringComparison.OrdinalIgnoreCase)) {
                    bool isArmv81Supported = IsProcessorFeaturePresent(ProcessorFeature.ARM_SUPPORTED_INSTRUCTIONS);
                    if (!isArmv81Supported) {
                        string registryName = "CP 4030";
                        long registryValue = (long)Registry.GetValue(registryPath, registryName, -1);
                        long atomicResult = (registryValue >> 20) & 0xF;
                        if (atomicResult >= 2) { isArmv81Supported = true; }
                    }
                    cpuFamilyResult.IsValid = isArmv81Supported;
                    cpuFamilyResult.Message = isArmv81Supported ? "" : "Processor does not implement ARM v8.1 atomic instruction";
                } else {
                    cpuFamilyResult.IsValid = false;
                    cpuFamilyResult.Message = "The processor isn't currently supported for Windows 11";
                }
                break;

            case PROCESSOR_ARCHITECTURE_X64:
            case PROCESSOR_ARCHITECTURE_X86:
                int cpuFamily = sysInfo.ProcessorLevel;
                int cpuModel = (sysInfo.ProcessorRevision >> 8) & 0xFF;
                int cpuStepping = sysInfo.ProcessorRevision & 0xFF;

                if (manufacturer.Equals(INTEL_MANUFACTURER, StringComparison.OrdinalIgnoreCase)) {
                    try {
                        cpuFamilyResult.IsValid = true;
                        cpuFamilyResult.Message = "";

                        if (cpuFamily >= 6 && cpuModel <= 95 && !(cpuFamily == 6 && cpuModel == 85)) {
                            cpuFamilyResult.IsValid = false;
                            cpuFamilyResult.Message = "";
                        } else if (cpuFamily == 6 && (cpuModel == 142 || cpuModel == 158) && cpuStepping == 9) {
                            string registryName = "Platform Specific Field 1";
                            int registryValue = (int)Registry.GetValue(registryPath, registryName, -1);
                            if ((cpuModel == 142 && registryValue != 16) || (cpuModel == 158 && registryValue != 8)) {
                                cpuFamilyResult.IsValid = false;
                            }
                            cpuFamilyResult.Message = "PlatformId " + registryValue;
                        }
                    } catch (Exception ex) {
                        cpuFamilyResult.IsValid = false;
                        cpuFamilyResult.Message = "Exception:" + ex.GetType().Name;
                    }
                } else if (manufacturer.Equals(AMD_MANUFACTURER, StringComparison.OrdinalIgnoreCase)) {
                    cpuFamilyResult.IsValid = true;
                    cpuFamilyResult.Message = "";
                    if (cpuFamily < 23 || (cpuFamily == 23 && (cpuModel == 1 || cpuModel == 17))) {
                        cpuFamilyResult.IsValid = false;
                    }
                } else {
                    cpuFamilyResult.IsValid = false;
                    cpuFamilyResult.Message = "Unsupported Manufacturer: " + manufacturer + ", Architecture: " + processorArchitecture + ", CPUFamily: " + sysInfo.ProcessorLevel + ", ProcessorRevision: " + sysInfo.ProcessorRevision;
                }
                break;

            default:
                cpuFamilyResult.IsValid = false;
                cpuFamilyResult.Message = "Unsupported CPU category. Manufacturer: " + manufacturer + ", Architecture: " + processorArchitecture + ", CPUFamily: " + sysInfo.ProcessorLevel + ", ProcessorRevision: " + sysInfo.ProcessorRevision;
                break;
        }
        return cpuFamilyResult;
    }
}
"@

# ==== Storage check ====
try {
    $osDrive    = Get-WmiObject -Class Win32_OperatingSystem | Select-Object -Property SystemDrive
    $osDriveSize = Get-WmiObject -Class Win32_LogicalDisk -filter "DeviceID='$($osDrive.SystemDrive)'" |
        Select-Object @{Name = "SizeGB"; Expression = { $_.Size / 1GB -as [int] }}

    if ($null -eq $osDriveSize) {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $STORAGE_STRING
        $outObject.logging += $logFormatWithBlob -f $STORAGE_STRING, "Storage is null", $FAIL_STRING
        $exitCode = 1
    } elseif ($osDriveSize.SizeGB -lt $MinOSDiskSizeGB) {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $STORAGE_STRING
        $outObject.logging += $logFormatWithUnit -f $STORAGE_STRING, $OS_DISK_SIZE_STRING, ($osDriveSize.SizeGB), $GB_UNIT_STRING, $FAIL_STRING
        $exitCode = 1
    } else {
        $outObject.logging += $logFormatWithUnit -f $STORAGE_STRING, $OS_DISK_SIZE_STRING, ($osDriveSize.SizeGB), $GB_UNIT_STRING, $PASS_STRING
        UpdateReturnCode -ReturnCode 0
    }
} catch {
    UpdateReturnCode -ReturnCode -1
    $outObject.logging += $logFormat -f $STORAGE_STRING, $OS_DISK_SIZE_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
    $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
    $exitCode = 1
}

# ==== Memory check ====
try {
    $memory = Get-WmiObject Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum |
        Select-Object @{Name = "SizeGB"; Expression = { $_.Sum / 1GB -as [int] }}

    if ($null -eq $memory) {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $MEMORY_STRING
        $outObject.logging += $logFormatWithBlob -f $MEMORY_STRING, "Memory is null", $FAIL_STRING
        $exitCode = 1
    } elseif ($memory.SizeGB -lt $MinMemoryGB) {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $MEMORY_STRING
        $outObject.logging += $logFormatWithUnit -f $MEMORY_STRING, $SYSTEM_MEMORY_STRING, ($memory.SizeGB), $GB_UNIT_STRING, $FAIL_STRING
        $exitCode = 1
    } else {
        $outObject.logging += $logFormatWithUnit -f $MEMORY_STRING, $SYSTEM_MEMORY_STRING, ($memory.SizeGB), $GB_UNIT_STRING, $PASS_STRING
        UpdateReturnCode -ReturnCode 0
    }
} catch {
    UpdateReturnCode -ReturnCode -1
    $outObject.logging += $logFormat -f $MEMORY_STRING, $SYSTEM_MEMORY_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
    $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
    $exitCode = 1
}

# ==== TPM check ====
try {
    $tpm = Get-Tpm
    if ($null -eq $tpm) {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $TPM_STRING
        $outObject.logging += $logFormatWithBlob -f $TPM_STRING, "TPM is null", $FAIL_STRING
        $exitCode = 1
    } elseif ($tpm.TpmPresent) {
        $tpmVersion = Get-WmiObject -Class Win32_Tpm -Namespace root\CIMV2\Security\MicrosoftTpm | Select-Object -Property SpecVersion
        if ($null -eq $tpmVersion.SpecVersion) {
            UpdateReturnCode -ReturnCode 1
            $outObject.returnReason += $logFormatReturnReason -f $TPM_STRING
            $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, "null", $FAIL_STRING
            $exitCode = 1
        }
        $majorVersion = $tpmVersion.SpecVersion.Split(",")[0] -as [int]
        if ($majorVersion -lt 2) {
            UpdateReturnCode -ReturnCode 1
            $outObject.returnReason += $logFormatReturnReason -f $TPM_STRING
            $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, ($tpmVersion.SpecVersion), $FAIL_STRING
            $exitCode = 1
        } else {
            $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, ($tpmVersion.SpecVersion), $PASS_STRING
            UpdateReturnCode -ReturnCode 0
        }
    } else {
        if ($tpm.GetType().Name -eq "String") {
            UpdateReturnCode -ReturnCode -1
            $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
            $outObject.logging += $logFormatException -f $tpm
        } else {
            UpdateReturnCode -ReturnCode 1
            $outObject.returnReason += $logFormatReturnReason -f $TPM_STRING
            $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, ($tpm.TpmPresent), $FAIL_STRING
        }
        $exitCode = 1
    }
} catch {
    UpdateReturnCode -ReturnCode -1
    $outObject.logging += $logFormat -f $TPM_STRING, $TPM_VERSION_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
    $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
    $exitCode = 1
}

# ==== CPU check ====
$cpuDetails = $null
try {
    $cpuDetails = @(Get-WmiObject -Class Win32_Processor)[0]
    if ($null -eq $cpuDetails) {
        UpdateReturnCode -ReturnCode 1
        $exitCode = 1
        $outObject.returnReason += $logFormatReturnReason -f $PROCESSOR_STRING
        $outObject.logging += $logFormatWithBlob -f $PROCESSOR_STRING, "CpuDetails is null", $FAIL_STRING
    } else {
        $processorCheckFailed = $false

        # Address width (must be 64-bit)
        if ($null -eq $cpuDetails.AddressWidth -or $cpuDetails.AddressWidth -ne $RequiredAddressWidth) {
            UpdateReturnCode -ReturnCode 1; $processorCheckFailed = $true; $exitCode = 1
        }

        # Max clock speed in MHz (minimum threshold)
        if ($null -eq $cpuDetails.MaxClockSpeed -or $cpuDetails.MaxClockSpeed -le $MinClockSpeedMHz) {
            UpdateReturnCode -ReturnCode 1; $processorCheckFailed = $true; $exitCode = 1
        }

        # Logical cores (minimum threshold)
        if ($null -eq $cpuDetails.NumberOfLogicalProcessors -or $cpuDetails.NumberOfLogicalProcessors -lt $MinLogicalCores) {
            UpdateReturnCode -ReturnCode 1; $processorCheckFailed = $true; $exitCode = 1
        }

        # CPU family (C# helper)
        Add-Type -TypeDefinition $Source
        $cpuFamilyResult = [CpuFamily]::Validate([String]$cpuDetails.Manufacturer, [uint16]$cpuDetails.Architecture)

        $cpuDetailsLog = "{AddressWidth=$($cpuDetails.AddressWidth); MaxClockSpeed=$($cpuDetails.MaxClockSpeed); NumberOfLogicalCores=$($cpuDetails.NumberOfLogicalProcessors); Manufacturer=$($cpuDetails.Manufacturer); Caption=$($cpuDetails.Caption); $($cpuFamilyResult.Message)}"

        if (-not $cpuFamilyResult.IsValid) {
            UpdateReturnCode -ReturnCode 1; $processorCheckFailed = $true; $exitCode = 1
        }

        if ($processorCheckFailed) {
            $outObject.returnReason += $logFormatReturnReason -f $PROCESSOR_STRING
            $outObject.logging += $logFormatWithBlob -f $PROCESSOR_STRING, ($cpuDetailsLog), $FAIL_STRING
        } else {
            $outObject.logging += $logFormatWithBlob -f $PROCESSOR_STRING, ($cpuDetailsLog), $PASS_STRING
            UpdateReturnCode -ReturnCode 0
        }
    }
} catch {
    UpdateReturnCode -ReturnCode -1
    $outObject.logging += $logFormat -f $PROCESSOR_STRING, $PROCESSOR_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
    $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
    $exitCode = 1
}

# ==== Secure Boot check (with registry fallback) ====
try {
    $isSecureBootEnabled = Confirm-SecureBootUEFI
    if ($isSecureBootEnabled) {
        $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $CAPABLE_STRING, $PASS_STRING
        UpdateReturnCode -ReturnCode 0
    } else {
        UpdateReturnCode -ReturnCode 1
        $outObject.returnReason += $logFormatReturnReason -f $SECUREBOOT_STRING
        $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $NOT_CAPABLE_STRING, $FAIL_STRING
    }
} catch [System.PlatformNotSupportedException] {
    UpdateReturnCode -ReturnCode 1
    $outObject.returnReason += $logFormatReturnReason -f $SECUREBOOT_STRING
    $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $NOT_CAPABLE_STRING, $FAIL_STRING
    $exitCode = 1
} catch [System.UnauthorizedAccessException] {
    try {
        $sbState = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop
        if ($sbState.UEFISecureBootEnabled -eq 1) {
            $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $CAPABLE_STRING, $PASS_STRING
            UpdateReturnCode -ReturnCode 0
        } else {
            UpdateReturnCode -ReturnCode 1
            $outObject.returnReason += $logFormatReturnReason -f $SECUREBOOT_STRING
            $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $NOT_CAPABLE_STRING, $FAIL_STRING
            $exitCode = 1
        }
    } catch {
        UpdateReturnCode -ReturnCode -1
        $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
        $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
        $exitCode = 1
    }
} catch {
    UpdateReturnCode -ReturnCode -1
    $outObject.logging += $logFormatWithBlob -f $SECUREBOOT_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
    $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
    $exitCode = 1
}

# ==== Special case: i7-7820HQ allowed only on specific OEM models ====
try {
    $supportedDevices = @('surface studio 2', 'precision 5520')
    $systemInfo = @(Get-WmiObject -Class Win32_ComputerSystem)[0]
    if ($null -ne $cpuDetails) {
        if ($cpuDetails.Name -match 'i7-7820hq cpu @ 2.90ghz'){
            $modelOrSKUCheckLog = $systemInfo.Model.Trim()
            if ($supportedDevices -contains $modelOrSKUCheckLog){
                $outObject.logging += $logFormatWithBlob -f $I7_7820HQ_CPU_STRING, $modelOrSKUCheckLog, $PASS_STRING
                $outObject.returnCode = 0
                $exitCode = 0
            }
        }
    }
} catch {
    if ($outObject.returnCode -ne 0){
        UpdateReturnCode -ReturnCode -1
        $outObject.logging += $logFormatWithBlob -f $I7_7820HQ_CPU_STRING, $UNDETERMINED_STRING, $UNDETERMINED_CAPS_STRING
        $outObject.logging += $logFormatException -f "$($_.Exception.GetType().Name) $($_.Exception.Message)"
        $exitCode = 1
    }
}

# ==== Finalize overall result string ====
switch ($outObject.returnCode) {
    0  { $outObject.returnResult = $CAPABLE_CAPS_STRING }
    1  { $outObject.returnResult = $NOT_CAPABLE_CAPS_STRING }
    -1 { $outObject.returnResult = $UNDETERMINED_CAPS_STRING }
    -2 { $outObject.returnResult = $FAILED_TO_RUN_STRING }
}

# ==== Output and sync with local-queue-first strategy ====
# 1) Serialize JSON and write to local queue
# 2) Immediately set the one-time marker (because we now have a durable local result)
# 3) Try to flush entire queue to the network share (best-effort)
# 4) Exit with the check exit code
try {
    # Serialize to JSON
    $json = $outObject | ConvertTo-Json -Compress

    # Ensure local queue folder exists
    if (-not (Test-Path $LocalQueue)) {
        New-Item -Path $LocalQueue -ItemType Directory -Force | Out-Null
    }

    # Filename: HOSTNAME-YYYYMMDDTHHMMSS.json
    $stamp     = (Get-Date).ToString('yyyyMMddTHHmmss')
    $fileName  = "$($env:COMPUTERNAME)-$stamp.json"
    $localFile = Join-Path $LocalQueue $fileName

    # Write JSON locally (this is the durable point of no return)
    Set-Content -Path $localFile -Value $json -Encoding UTF8 -NoNewline

    # Set the one-time marker AFTER local write succeeded
    if (-not (Test-Path (Split-Path $markerPath))) {
        New-Item -Path (Split-Path $markerPath) -ItemType Directory -Force | Out-Null
    }
    New-Item -Path $markerPath -ItemType File -Force | Out-Null

    # Best-effort: flush ALL queued files to the share
    try {
        if (Test-Path $OutDir) {
            Get-ChildItem -Path $LocalQueue -File -Filter '*.json' | ForEach-Object {
                try {
                    $dest = Join-Path $OutDir $_.Name
                    Copy-Item -Path $_.FullName -Destination $dest -Force
                    Remove-Item -Path $_.FullName -Force
                } catch {
                    # Leave the file in queue on error; will retry next boot/run
                }
            }
        }
    } catch {
        # Ignore sync-level exceptions; marker is set and local data exists
    }

    # Exit reflecting the check result
    exit $exitCode
}
catch {
    # If we fail BEFORE writing the local JSON, do NOT set the marker.
    # This allows a future run to retry and produce a result.
    exit 1
}
