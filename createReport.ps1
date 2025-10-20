<#
.SYNOPSIS
Generates a Windows 11 readiness report (CSV + HTML) from JSON logs.

.DESCRIPTION
Parses JSON logs produced by a Windows 11 readiness checker, aggregates key
signals (Storage, Memory, TPM, Secure Boot, Processor), and produces:
- A CSV file with detailed rows per machine.
- An HTML dashboard with summary cards, SVG bar charts, and top failure reasons.

.PARAMETER LogPath
Output directory for the generated CSV and HTML. Defaults to a subfolder "out" in the current directory.

.EXAMPLE
PS> .\Generate-Win11ReadinessReport.ps1 -LogPath \\files\win11 -OutDir C:\Reports\Win11
#>

param(
    [Parameter(Mandatory)]
    [string]$LogPath,                        # e.g. \\plus-test\windows11check
    [string]$OutDir = (Join-Path $PWD "out") # e.g. C:\Reports\Win11Check
)

# ---------- Helpers ----------
function Ensure-Dir($p) { if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null } }

function Get-StatusFromLogging {
    param(
        [string]$Logging,
        [string]$CheckName  # "Storage","Memory","TPM","Processor","SecureBoot"
    )
    # Returns: PASS / FAIL / UNDETERMINED (or empty)
    if ([string]::IsNullOrWhiteSpace($Logging)) { return "" }
    $pattern = [Regex]::Escape($CheckName) + '.*?(PASS|FAIL|UNDETERMINED)'
    $m = [Regex]::Match($Logging, $pattern, 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ""
}

function Get-Value {
    param(
        [string]$Logging,
        [string]$Name,     # e.g. "OSDiskSize","System_Memory","TPMVersion"
        [string]$Unit = "" # e.g. "GB"
    )
    if ([string]::IsNullOrWhiteSpace($Logging)) { return $null }
    # Examples in the log:
    # "Storage: OSDiskSize=455GB. PASS; "
    # "Memory: System_Memory=16GB. PASS; "
    # "TPM: TPMVersion=2.0, 0, 1.59. PASS; "
    $pattern =
        if ($Unit) {
            [Regex]::Escape($Name) + "=(?<val>[\d\.]+)" + [Regex]::Escape($Unit)
        } else {
            [Regex]::Escape($Name) + "=(?<val>[^\.]+)\."
        }
    $m = [Regex]::Match($Logging, $pattern)
    if ($m.Success) { return $m.Groups['val'].Value.Trim() }
    return $null
}

function Get-CPUBlob {
    param([string]$Logging)
    # Example:
    # "Processor: {AddressWidth=64; MaxClockSpeed=1300; NumberOfLogicalCores=12; Manufacturer=GenuineIntel; Caption=...}. PASS; "
    $m = [Regex]::Match($Logging, 'Processor:\s*\{(?<blob>[^}]+)\}', 'IgnoreCase')
    if ($m.Success) { return $m.Groups['blob'].Value }
    return $null
}

function Parse-CPUField {
    param([string]$Blob, [string]$FieldName)
    if (-not $Blob) { return $null }
    $m = [Regex]::Match($Blob, [Regex]::Escape($FieldName) + '=(?<v>[^;]+);?')
    if ($m.Success) { return ($m.Groups['v'].Value).Trim() }
    return $null
}

function New-BarSvg {
    param(
        [string[]]$Labels,
        [int[]]$Values,
        [int]$Width = 720,
        [int]$Height = 320,
        [string]$Title = ""
    )
    $leftPad = 60; $bottomPad = 40; $topPad = 40; $rightPad = 20
    $plotW = $Width - $leftPad - $rightPad
    $plotH = $Height - $topPad - $bottomPad
    $max = [Math]::Max(1, ($Values | Measure-Object -Maximum).Maximum)
    $barW = [Math]::Max(10, [Math]::Floor($plotW / [Math]::Max(1,$Labels.Count) * 0.7))
    $gap = [Math]::Max(5, [Math]::Floor(($plotW - $barW*$Labels.Count) / [Math]::Max(1,($Labels.Count+1))))

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<svg width='$Width' height='$Height' viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg' role='img' aria-label='Chart'>")
    if ($Title) {
        [void]$sb.AppendLine("<text x='50%' y='20' text-anchor='middle' font-size='16' font-weight='bold'>$Title</text>")
    }
    # axes
    [void]$sb.AppendLine("<line x1='$leftPad' y1='$topPad' x2='$leftPad' y2='$($topPad+$plotH)' stroke='black' />")
    [void]$sb.AppendLine("<line x1='$leftPad' y1='$($topPad+$plotH)' x2='$($leftPad+$plotW)' y2='$($topPad+$plotH)' stroke='black' />")

    # y ticks (5)
    for ($i=0; $i -le 5; $i++) {
        $val = [Math]::Round($max * $i / 5)
        $y = $topPad + $plotH - [Math]::Floor($plotH * $i / 5)
        [void]$sb.AppendLine("<line x1='$leftPad' y1='$y' x2='$($leftPad+$plotW)' y2='$y' stroke='lightgray' stroke-dasharray='2,4'/>")
        [void]$sb.AppendLine("<text x='$($leftPad-8)' y='$($y+4)' text-anchor='end' font-size='11'>$val</text>")
    }

    # bars
    $x = $leftPad + $gap
    for ($i=0; $i -lt $Labels.Count; $i++) {
        $v = [int]$Values[$i]
        $h = if ($max -eq 0) { 0 } else { [Math]::Floor($plotH * $v / $max) }
        $y = $topPad + $plotH - $h
        # default fill (uses browser theme via currentColor)
        [void]$sb.AppendLine("<rect x='$x' y='$y' width='$barW' height='$h' fill='currentColor' opacity='0.8'>")
        [void]$sb.AppendLine("<title>$($Labels[$i]): $v</title></rect>")
        # value label
        [void]$sb.AppendLine("<text x='$($x+$barW/2)' y='$($y-4)' text-anchor='middle' font-size='11'>$v</text>")
        # x labels (basic wrap)
        $lbl = [System.Web.HttpUtility]::HtmlEncode($Labels[$i])
        [void]$sb.AppendLine("<text x='$($x+$barW/2)' y='$($topPad+$plotH+14)' text-anchor='middle' font-size='11'>$lbl</text>")
        $x += $barW + $gap
    }

    [void]$sb.AppendLine("</svg>")
    return $sb.ToString()
}

# ---------- Start ----------
Ensure-Dir $OutDir
$files = Get-ChildItem -Path $LogPath -Filter '*.json' -ErrorAction Stop
if ($files.Count -eq 0) {
    Write-Host "No JSON logs found in $LogPath."
    exit 1
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
    try {
        $raw = Get-Content -Path $f.FullName -Raw -ErrorAction Stop
        $j = $raw | ConvertFrom-Json -ErrorAction Stop

        # Computer & Timestamp from filename (pattern: HOST-YYYYMMDDTHHmmss.json)
        $comp = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $idx = $comp.LastIndexOf('-')
        if ($idx -gt 0) {
            $hostname = $comp.Substring(0,$idx)
            $stamp = $comp.Substring($idx+1)
        } else {
            $hostname = $comp
            $stamp = ''
        }
        $dt = $null
        if ($stamp -and $stamp -match '^\d{8}T\d{6}$') {
            $dt = [datetime]::ParseExact($stamp,'yyyyMMddTHHmmss',$null)
        } else {
            $dt = $f.CreationTime
        }

        $logging = [string]$j.logging
        $retCode = [int]$j.returnCode
        $retResult = [string]$j.returnResult
        $retReason = [string]$j.returnReason

        # Individual checks
        $stStatus = Get-StatusFromLogging -Logging $logging -CheckName 'Storage'
        $memStatus = Get-StatusFromLogging -Logging $logging -CheckName 'Memory'
        $tpmStatus = Get-StatusFromLogging -Logging $logging -CheckName 'TPM'
        $cpuStatus = Get-StatusFromLogging -Logging $logging -CheckName 'Processor'
        $sbStatus  = Get-StatusFromLogging -Logging $logging -CheckName 'SecureBoot'

        $osDiskGB = Get-Value -Logging $logging -Name 'OSDiskSize' -Unit 'GB'
        $memGB    = Get-Value -Logging $logging -Name 'System_Memory' -Unit 'GB'
        $tpmVer   = Get-Value -Logging $logging -Name 'TPMVersion'

        $cpuBlob  = Get-CPUBlob -Logging $logging
        $cpuAddrW = Parse-CPUField -Blob $cpuBlob -FieldName 'AddressWidth'
        $cpuMHz   = Parse-CPUField -Blob $cpuBlob -FieldName 'MaxClockSpeed'
        $cpuLC    = Parse-CPUField -Blob $cpuBlob -FieldName 'NumberOfLogicalCores'
        $cpuMan   = Parse-CPUField -Blob $cpuBlob -FieldName 'Manufacturer'
        $cpuCap   = Parse-CPUField -Blob $cpuBlob -FieldName 'Caption'

        $rows.Add([PSCustomObject]@{
            ComputerName = $hostname
            Timestamp    = $dt
            Result       = $retResult
            ReturnCode   = $retCode
            ReturnReason = $retReason
            Storage      = $stStatus
            OSDisk_GB    = [int]($osDiskGB -as [int])
            Memory       = $memStatus
            Memory_GB    = [int]($memGB -as [int])
            TPM          = $tpmStatus
            TPM_Version  = $tpmVer
            SecureBoot   = $sbStatus
            Processor    = $cpuStatus
            CPU_AddressW = $cpuAddrW
            CPU_MHz      = $cpuMHz
            CPU_LogicalCores = $cpuLC
            CPU_Manufacturer = $cpuMan
            CPU_Caption  = $cpuCap
            RawLogging   = $logging
            FileName     = $f.Name
        })
    }
    catch {
        Write-Warning "Could not parse '$($f.Name)': $($_.Exception.Message)"
    }
}

# ---------- CSV ----------
$csvPath = Join-Path $OutDir "Win11Check_Report.csv"
$rows | Sort-Object ComputerName, Timestamp | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# ---------- Summary ----------
$tot = $rows.Count
$byResult = $rows | Group-Object Result | Sort-Object Name
$labelsRes = $byResult.Name
$valuesRes = $byResult.Count
$htmlResChart = New-BarSvg -Labels $labelsRes -Values $valuesRes -Title "Overall result (CAPABLE / NOT CAPABLE / UNDETERMINED)"

$checkNames = @('Storage','Memory','TPM','SecureBoot','Processor')
$passCounts = foreach ($c in $checkNames) {
    ($rows | Where-Object { ($_.$c) -eq 'PASS' }).Count
}
$failCounts = foreach ($c in $checkNames) {
    ($rows | Where-Object { ($_.$c) -eq 'FAIL' }).Count
}
$undCounts = foreach ($c in $checkNames) {
    ($rows | Where-Object { ($_.$c) -eq 'UNDETERMINED' }).Count
}
$htmlPassChart = New-BarSvg -Labels $checkNames -Values $passCounts -Title "Checks: PASS per criterion"
$htmlFailChart = New-BarSvg -Labels $checkNames -Values $failCounts -Title "Checks: FAIL per criterion"
$htmlUndChart  = New-BarSvg -Labels $checkNames -Values $undCounts  -Title "Checks: UNDETERMINED per criterion"

# Top reasons (ReturnReason is a comma-separated list of failed checks)
$reasons = @()
foreach ($r in $rows) {
    if ($r.ReturnReason) {
        $parts = $r.ReturnReason -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $reasons += $parts
    }
}
$byReason = $reasons | Group-Object | Sort-Object Count -Descending

# Small HTML table for overview
function To-HtmlTable {
    param([object[]]$Items, [string[]]$Columns)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<table>")
    [void]$sb.Append("<thead><tr>")
    foreach ($c in $Columns) { [void]$sb.Append("<th>$c</th>") }
    [void]$sb.AppendLine("</tr></thead>")
    [void]$sb.AppendLine("<tbody>")
    foreach ($it in $Items) {
        [void]$sb.Append("<tr>")
        foreach ($c in $Columns) {
            $v = $it.$c
            $v = [System.Web.HttpUtility]::HtmlEncode("$v")
            [void]$sb.Append("<td>$v</td>")
        }
        [void]$sb.AppendLine("</tr>")
    }
    [void]$sb.AppendLine("</tbody></table>")
    return $sb.ToString()
}

$topReasonRows = @()
foreach ($g in $byReason | Select-Object -First 10) {
    $topReasonRows += [PSCustomObject]@{ Reason = $g.Name; Count = $g.Count }
}
$topReasonsTable = To-HtmlTable -Items $topReasonRows -Columns @('Reason','Count')

# Detail table (first 100 rows as preview)
$preview = $rows | Sort-Object ComputerName, Timestamp | Select-Object ComputerName, Timestamp, Result, Storage, Memory, TPM, SecureBoot, Processor, OSDisk_GB, Memory_GB, TPM_Version, CPU_LogicalCores, CPU_MHz, CPU_Manufacturer, CPU_Caption | Select-Object -First 100
$detailTable = To-HtmlTable -Items $preview -Columns @('ComputerName','Timestamp','Result','Storage','Memory','TPM','SecureBoot','Processor','OSDisk_GB','Memory_GB','TPM_Version','CPU_LogicalCores','CPU_MHz','CPU_Manufacturer','CPU_Caption')

# ---------- HTML ----------
$htmlPath = Join-Path $OutDir "Win11Check_Report.html"
$style = @"
<style>
body { font-family: Segoe UI, Roboto, Arial, sans-serif; margin: 24px; }
h1 { margin: 0 0 8px 0; }
.cards { display: grid; grid-template-columns: repeat(auto-fit,minmax(220px,1fr)); gap: 12px; margin: 12px 0 24px 0; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 12px 14px; box-shadow: 0 2px 8px rgba(0,0,0,.05); }
.card h3 { margin: 0 0 6px 0; font-size: 15px; }
.card .val { font-size: 22px; font-weight: 700; }
section { margin-bottom: 28px; }
table { border-collapse: collapse; width: 100%; margin-top: 10px; }
th, td { border: 1px solid #e5e5e5; padding: 6px 8px; font-size: 13px; }
th { background: #fafafa; text-align: left; }
small { color: #666; }
svg { max-width: 100%; height: auto; }
.footer { margin-top: 24px; color: #666; font-size: 12px; }
</style>
"@

$capable = ($rows | Where-Object { $_.Result -match 'CAPABLE' }).Count
$notcap  = ($rows | Where-Object { $_.Result -match 'NOT CAPABLE' }).Count
$undet   = ($rows | Where-Object { $_.Result -match 'UNDETERMINED' }).Count

$now = Get-Date

$html = @"
<!DOCTYPE html>
<html lang="en">
<meta charset="utf-8" />
<title>Windows 11 Readiness – Report</title>
$style
<body>
  <h1>Windows 11 Readiness – Report</h1>
  <small>Created on $now — Source: $LogPath</small>

  <div class="cards">
    <div class="card"><h3>Total devices</h3><div class="val">$tot</div></div>
    <div class="card"><h3>CAPABLE</h3><div class="val">$capable</div></div>
    <div class="card"><h3>NOT CAPABLE</h3><div class="val">$notcap</div></div>
    <div class="card"><h3>UNDETERMINED</h3><div class="val">$undet</div></div>
  </div>

  <section>
    $htmlResChart
  </section>

  <section>
    $htmlPassChart
  </section>

  <section>
    $htmlFailChart
  </section>

  <section>
    $htmlUndChart
  </section>

  <section>
    <h2>Top reasons (top 10)</h2>
    $topReasonsTable
  </section>

  <section>
    <h2>Details (preview, first 100)</h2>
    $detailTable
    <p class="footer">See full data in CSV: <b>Win11Check_Report.csv</b></p>
  </section>
</body>
</html>
"@

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host "Done!"
Write-Host "CSV : $csvPath"
Write-Host "HTML: $htmlPath"
exit 0
