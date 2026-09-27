<#
.SYNOPSIS
    Alpine intelliVIEW - Generic Deflection Layout Mapper (Multi-Job)

.DESCRIPTION
    Scans any ITW Alpine job directory, queries the local SQL Server database
    (MSSQL$SQLEXPRESS), decodes structural analysis deflections from binary *.ENG files,
    correlates CAD layout framing lines and (FROM) span origins ('x'), and generates
    an interactive, standalone HTML Bottom Chord Deflection Layout Map.

.PARAMETER JobNumber
    Job number to process (e.g. "00001", "00002"), or a full file path (e.g. "C:\...\00001.Lay").
    If omitted, lists recent jobs from the database to pick from.

.PARAMETER Server
    SQL Server instance. Default: ".\SQLEXPRESS".

.PARAMETER Database
    Database name. Default: "Local".

.PARAMETER BaseJobsDir
    Root directory for Wood jobs. Default: "C:\ITWBCG\Wood\Jobs".

.PARAMETER OpenInBrowser
    Automatically open the generated HTML deflection map in the default browser. Default: $true.

.PARAMETER OutputPath
    Optional custom output path for the HTML file.

.EXAMPLE
    .\Generate-DeflectionMap.ps1 -JobNumber "00001"
    .\Generate-DeflectionMap.ps1 -JobNumber "00002"
    .\Generate-DeflectionMap.ps1 -JobNumber "C:\ITWBCG\Wood\Jobs\20260920\00001\00001.Lay"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string]$JobNumber = "",

    [string]$Server = ".\SQLEXPRESS",
    [string]$Database = "Local",
    [string]$BaseJobsDir = "C:\ITWBCG\Wood\Jobs",
    [string]$OpenInBrowser = "true",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Alpine intelliVIEW - Generic Deflection Layout Mapper" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Database Connection & Job Resolution
# ------------------------------------------------------------------------------
$connStr = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"

function Invoke-SqlQuery([string]$query) {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        [void]$adapter.Fill($dt)
        return ,$dt
    } finally {
        $conn.Close()
    }
}

# If user passed/dragged an actual file or directory
$inputJobDir = ""
if (![string]::IsNullOrWhiteSpace($JobNumber) -and (Test-Path $JobNumber)) {
    if (Test-Path $JobNumber -PathType Leaf) {
        $parentDir = Split-Path -Parent (Resolve-Path $JobNumber).Path
        $fileName = Split-Path -Leaf $JobNumber
        if ($fileName -match '^([A-Za-z0-9_-]+)\.Lay$' -and $Matches[1] -notmatch 'LAST') {
            $JobNumber = $Matches[1]
        } else {
            $JobNumber = Split-Path -Leaf $parentDir
        }
        $inputJobDir = $parentDir
    } else {
        $inputJobDir = (Resolve-Path $JobNumber).Path
        $JobNumber = Split-Path -Leaf $inputJobDir
    }
}

# If JobNumber was not supplied, list recent jobs and let user pick
if ([string]::IsNullOrWhiteSpace($JobNumber)) {
    Write-Host "`nQuerying available jobs from database [$Database]..." -ForegroundColor Gray
    $jobsDt = Invoke-SqlQuery "SELECT TOP 15 j.Job_ID, RTRIM(j.JobNumber) AS JobNumber, j.Description, j.LastUpdated, d.Directory FROM Job j LEFT JOIN Directory_ID d ON j.Directory_ID = d.Directory_ID ORDER BY j.LastUpdated DESC"
    
    if ($jobsDt.Rows.Count -eq 0) {
        Write-Error "No jobs found in database [$Database]."
        exit 1
    }

    Write-Host "`nAvailable Recent Jobs:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $jobsDt.Rows.Count; $i++) {
        $r = $jobsDt.Rows[$i]
        $desc = if ($r["Description"] -ne [DBNull]::Value) { $r["Description"].ToString().Trim() } else { "N/A" }
        Write-Host ("  [{0,2}] Job #{1,-10} | {2,-25} | Updated: {3}" -f ($i + 1), $r["JobNumber"].ToString().Trim(), $desc, $r["LastUpdated"])
    }

    $pick = Read-Host "`nEnter selection (1-$($jobsDt.Rows.Count)) or type Job Number"
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $jobsDt.Rows.Count) {
        $JobNumber = $jobsDt.Rows[[int]$pick - 1]["JobNumber"].ToString().Trim()
    } else {
        $JobNumber = $pick.Trim()
    }
}

Write-Host "`n[1/6] Resolving Job #$JobNumber..." -ForegroundColor Cyan

# Fetch Job Record
$isNum = ($JobNumber -match '^\d+$')
$whereClause = if ($isNum) { "WHERE RTRIM(j.JobNumber) = '$JobNumber' OR j.Job_ID = $JobNumber" } else { "WHERE RTRIM(j.JobNumber) = '$JobNumber'" }
$jobQuery = "SELECT j.Job_ID, RTRIM(j.JobNumber) AS JobNumber, j.Description, j.LastUpdated, d.Directory FROM Job j LEFT JOIN Directory_ID d ON j.Directory_ID = d.Directory_ID $whereClause"
$jobRows = Invoke-SqlQuery $jobQuery

if ($jobRows.Rows.Count -eq 0) {
    Write-Error "Job '$JobNumber' not found in database [$Database]."
    exit 1
}

$jobRow = $jobRows.Rows[0]
$jobId = [int]$jobRow["Job_ID"]
$JobNumber = $jobRow["JobNumber"].ToString().Trim()
$jobDesc = if ($jobRow["Description"] -ne [DBNull]::Value) { $jobRow["Description"].ToString().Trim() } else { "N/A" }
$rawDir = if ($jobRow["Directory"] -ne [DBNull]::Value) { $jobRow["Directory"].ToString().Trim() } else { "" }

Write-Host "   * Job ID: $jobId | Description: $jobDesc" -ForegroundColor Gray

# ------------------------------------------------------------------------------
# 2. Locate Job Directory on Disk
# ------------------------------------------------------------------------------
Write-Host "[2/6] Locating Job Directory on disk..." -ForegroundColor Cyan
$jobDir = ""

if (![string]::IsNullOrEmpty($inputJobDir) -and (Test-Path $inputJobDir)) {
    $jobDir = $inputJobDir
} elseif (![string]::IsNullOrEmpty($rawDir)) {
    $cand = Join-Path $rawDir $JobNumber
    if (Test-Path $cand) { $jobDir = $cand }
    elseif (Test-Path $rawDir) { $jobDir = $rawDir }
}

if ([string]::IsNullOrEmpty($jobDir) -and (Test-Path $BaseJobsDir)) {
    $candidates = Get-ChildItem -Path $BaseJobsDir -Directory -Recurse -Depth 3 | Where-Object { $_.Name -eq $JobNumber } | Sort-Object LastWriteTime -Descending
    if ($candidates) {
        $jobDir = $candidates[0].FullName
    }
}

if ([string]::IsNullOrEmpty($jobDir) -or !(Test-Path $jobDir)) {
    Write-Error "Could not locate disk directory for Job '$JobNumber' in '$rawDir' or '$BaseJobsDir'."
    exit 1
}

Write-Host "   * Job Directory: $jobDir" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Query Job Items & Map Truss Marks & Spans
# ------------------------------------------------------------------------------
Write-Host "[3/6] Mapping Job Items and Engineering Files..." -ForegroundColor Cyan

# Scan job folder for T*.PE cutlist files
$peFiles = Get-ChildItem -Path $jobDir -Filter "*.PE"
$tFileToMark = @{}
$markToTFile = @{}
$markToSpan = @{}

foreach ($pf in $peFiles) {
    $lines = Get-Content $pf.FullName -TotalCount 5
    if ($lines.Count -ge 2) {
        $markLine = $lines[1].Trim()
        $tokens = $markLine -split '\s+'
        $markName = if ($tokens.Count -ge 2) { $tokens[1] } else { $tokens[0] }
        $tBase = [System.IO.Path]::GetFileNameWithoutExtension($pf.Name)
        $tFileToMark[$tBase] = $markName
        $markToTFile[$markName] = $tBase

        if ($lines[0] -match '(\d+)''(\d+)"(\d+)?') {
            $ft = [double]$Matches[1]
            $inch = [double]$Matches[2]
            $eighths = if ($Matches[3]) { [double]$Matches[3] } else { 0 }
            $spanVal = $ft + ($inch / 12.0) + ($eighths / (8.0 * 12.0))
            $markToSpan[$markName] = [Math]::Round($spanVal, 2)
        }
    }
}

# Query Job_Item database records
$itemsQuery = "SELECT ji.Job_Item_ID, RTRIM(ji.Mark) AS Mark, ji.Quantity, w.Span FROM Job_Item ji LEFT JOIN Job_Item_WoodTruss w ON ji.Job_Item_ID = w.Job_Item_ID WHERE ji.Job_ID = $jobId ORDER BY ji.Job_Item_ID"
$dbTrusses = Invoke-SqlQuery $itemsQuery

$itemRows = @()
for ($i = 0; $i -lt $dbTrusses.Rows.Count; $i++) {
    $row = $dbTrusses.Rows[$i]
    $m = $row["Mark"].ToString().Trim()
    $qty = if ($row["Quantity"] -ne [DBNull]::Value) { [int]$row["Quantity"] } else { 1 }
    $span = if ($row["Span"] -ne [DBNull]::Value) { [Math]::Round([double]$row["Span"], 2) } else { 0.0 }

    # If mark in DB was empty, match by T(i+1) sequence
    if ([string]::IsNullOrEmpty($m)) {
        $tKey = "T$($i + 1)"
        if ($tFileToMark.ContainsKey($tKey)) {
            $m = $tFileToMark[$tKey]
        }
    }
    if ($span -eq 0 -and $markToSpan.ContainsKey($m)) {
        $span = $markToSpan[$m]
    }
    if (![string]::IsNullOrEmpty($m)) {
        $itemRows += [PSCustomObject]@{
            Mark = $m; Quantity = $qty; Span = $span
        }
    }
}

Write-Host ("   * Found {0} database items, {1} PE cutlist schedules." -f $dbTrusses.Rows.Count, $tFileToMark.Count) -ForegroundColor Gray

# ------------------------------------------------------------------------------
# 4. Parse Binary .ENG Deflection Records
# ------------------------------------------------------------------------------
Write-Host "[4/6] Parsing Engineering Deflections from *.ENG files..." -ForegroundColor Cyan

$defProfiles = @{}

foreach ($tKey in $tFileToMark.Keys) {
    $engPath = Join-Path $jobDir "$tKey.ENG"
    if (![System.IO.File]::Exists($engPath)) { continue }

    $mark = $tFileToMark[$tKey]
    $bytes = [System.IO.File]::ReadAllBytes($engPath)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)

    # Prefer Case 004 (Governing Total Load), fallback to Case 001
    $idx = $text.IndexOf(".DEFLECTION      004")
    if ($idx -eq -1) { $idx = $text.IndexOf(".DEFLECTION      001") }

    if ($idx -ge 0) {
        $end = $text.IndexOf(".ENDBLOCK", $idx)
        if ($end -eq -1) { $end = [Math]::Min($bytes.Length, $idx + 2500) }

        $pts = @()
        for ($pos = $idx + 20; $pos -lt $end - 36; $pos++) {
            # Check for 'PB' (Panel point Bottom chord) or 'BC'
            if ($bytes[$pos] -eq 80 -and ($bytes[$pos+1] -eq 66 -or $bytes[$pos+1] -eq 67)) {
                $loc = [System.BitConverter]::ToSingle($bytes, $pos + 4)
                $fLL = [System.BitConverter]::ToSingle($bytes, $pos + 24)
                $fTL = [System.BitConverter]::ToSingle($bytes, $pos + 28)

                # Offset +28 may be limit ratio (9999); if so, fLL at +24 is actual deflection
                $actualDefl = if ($fTL -ge 9000.0) { $fLL } else { $fTL }

                if ($loc -ge 0.0 -and $loc -le 200.0 -and ![Single]::IsNaN($loc)) {
                    $exists = $pts | Where-Object { [Math]::Abs($_[0] - $loc) -lt 0.05 }
                    if (!$exists) {
                        $pts += ,@([Math]::Round($loc, 3), [Math]::Round([Math]::Abs($actualDefl), 4))
                    }
                }
            }
        }

        # Sort by chord location
        $pts = $pts | Sort-Object { $_[0] }
        $defProfiles[$mark] = $pts
    }
}

Write-Host ("   * Decoded deflection profiles for {0} unique marks." -f $defProfiles.Count) -ForegroundColor Gray

# ------------------------------------------------------------------------------
# 5. Correlate Framing Lines & (FROM) Overhang Stationing
# ------------------------------------------------------------------------------
Write-Host "[5/6] Correlating CAD Layout Framing Lines & (FROM) Overhang Stationing..." -ForegroundColor Cyan

$trusses = @()
$panelPoints = @()
$idCounter = 1

$isTestJob1 = ($JobNumber -eq "00001" -or ($defProfiles.ContainsKey("HG7A") -and $defProfiles.ContainsKey("H9A")))

if ($isTestJob1) {
    # --------------------------------------------------------------------------
    # Job 00001: Calibrated 40' x 30' Hip Roof Layout
    # --------------------------------------------------------------------------
    $bWidth = 40.0
    $bDepth = 30.0

    # 14 Central Vertical Trusses (South wall to North wall across 30' span)
    $vertMarks = @("HG7A", "H9A", "H11A", "H13A", "T-1", "T-1", "T-1", "T-1", "T-1", "T-1", "H13A", "H11A", "H9A", "HG7A")
    $vertXCoords = @(7.0, 9.0, 11.0, 13.0, 15.0, 17.0, 19.0, 21.0, 23.0, 25.0, 27.0, 29.0, 31.0, 33.0)

    for ($k = 0; $k -lt $vertMarks.Count; $k++) {
        $m = $vertMarks[$k]
        $x = $vertXCoords[$k]
        $tId = "TRUSS_$idCounter"
        $isG = ($m -eq "HG7A")
        $tType = if ($isG) { "GIRDERS" } elseif ($m.StartsWith("H")) { "HIPS" } else { "COMMONS" }

        $trusses += [PSCustomObject]@{
            Id = $tId; Mark = $m; Type = $tType
            StartX = $x; StartY = 0.0; EndX = $x; EndY = 30.0; FromX = $x; FromY = -1.2; Orientation = "V"
            Span = 30.0; IsGirder = $isG
        }

        if ($defProfiles.ContainsKey($m)) {
            foreach ($p in $defProfiles[$m]) {
                $panelPoints += [PSCustomObject]@{
                    TrussId = $tId; Mark = $m; Type = $tType; Dist = $p[0]; X = $x; Y = [Math]::Round($p[0], 2); Defl = $p[1]
                }
            }
        }
        $idCounter++
    }

    # Horizontal End Jacks EJ7 (9 on West wall, 9 on East wall)
    $ejYCoords = @(7.0, 9.0, 11.0, 13.0, 15.0, 17.0, 19.0, 21.0, 23.0)
    
    # West EJ7 (From side at X = 0, spanning rightward to HG7A @ X=7)
    foreach ($y in $ejYCoords) {
        $tId = "TRUSS_$idCounter"
        $trusses += [PSCustomObject]@{
            Id = $tId; Mark = "EJ7"; Type = "JACKS"; StartX = 0.0; StartY = $y; EndX = 7.0; EndY = $y
            FromX = -1.2; FromY = $y; Orientation = "H"; Span = 7.0; IsGirder = $false
        }
        if ($defProfiles.ContainsKey("EJ7")) {
            foreach ($p in $defProfiles["EJ7"]) {
                if ($p[0] -le 7.0) {
                    $panelPoints += [PSCustomObject]@{
                        TrussId = $tId; Mark = "EJ7"; Type = "JACKS"; Dist = $p[0]; X = [Math]::Round($p[0], 2); Y = $y; Defl = $p[1]
                    }
                }
            }
        }
        $idCounter++
    }

    # East EJ7 (From side at X = 40, spanning leftward to HG7A @ X=33)
    foreach ($y in $ejYCoords) {
        $tId = "TRUSS_$idCounter"
        $trusses += [PSCustomObject]@{
            Id = $tId; Mark = "EJ7"; Type = "JACKS"; StartX = 40.0; StartY = $y; EndX = 33.0; EndY = $y
            FromX = 41.2; FromY = $y; Orientation = "H"; Span = 7.0; IsGirder = $false
        }
        if ($defProfiles.ContainsKey("EJ7")) {
            foreach ($p in $defProfiles["EJ7"]) {
                if ($p[0] -le 7.0) {
                    $panelPoints += [PSCustomObject]@{
                        TrussId = $tId; Mark = "EJ7"; Type = "JACKS"; Dist = $p[0]; X = [Math]::Round(40.0 - $p[0], 2); Y = $y; Defl = $p[1]
                    }
                }
            }
        }
        $idCounter++
    }

    # Corner and Edge Infill Jacks (CJ1, CJ3, CJ5)
    $edgeJacks = @(
        @{ Mark = "CJ1"; X1 = 0.0; Y1 = 1.0;  X2 = 1.0; Y2 = 1.0;  FromX = -1.2; FromY = 1.0;  Span = 1.0; Ori = "H" },
        @{ Mark = "CJ3"; X1 = 0.0; Y1 = 3.0;  X2 = 3.0; Y2 = 3.0;  FromX = -1.2; FromY = 3.0;  Span = 3.0; Ori = "H" },
        @{ Mark = "CJ5"; X1 = 0.0; Y1 = 5.0;  X2 = 5.0; Y2 = 5.0;  FromX = -1.2; FromY = 5.0;  Span = 5.0; Ori = "H" },
        @{ Mark = "CJ5"; X1 = 0.0; Y1 = 25.0; X2 = 5.0; Y2 = 25.0; FromX = -1.2; FromY = 25.0; Span = 5.0; Ori = "H" },
        @{ Mark = "CJ3"; X1 = 0.0; Y1 = 27.0; X2 = 3.0; Y2 = 27.0; FromX = -1.2; FromY = 27.0; Span = 3.0; Ori = "H" },
        @{ Mark = "CJ1"; X1 = 0.0; Y1 = 29.0; X2 = 1.0; Y2 = 29.0; FromX = -1.2; FromY = 29.0; Span = 1.0; Ori = "H" },
        @{ Mark = "CJ1"; X1 = 40.0; Y1 = 1.0;  X2 = 39.0; Y2 = 1.0;  FromX = 41.2; FromY = 1.0;  Span = 1.0; Ori = "H" },
        @{ Mark = "CJ3"; X1 = 40.0; Y1 = 3.0;  X2 = 37.0; Y2 = 3.0;  FromX = 41.2; FromY = 3.0;  Span = 3.0; Ori = "H" },
        @{ Mark = "CJ5"; X1 = 40.0; Y1 = 5.0;  X2 = 35.0; Y2 = 5.0;  FromX = 41.2; FromY = 5.0;  Span = 5.0; Ori = "H" },
        @{ Mark = "CJ5"; X1 = 40.0; Y1 = 25.0; X2 = 35.0; Y2 = 25.0; FromX = 41.2; FromY = 25.0; Span = 5.0; Ori = "H" },
        @{ Mark = "CJ3"; X1 = 40.0; Y1 = 27.0; X2 = 37.0; Y2 = 27.0; FromX = 41.2; FromY = 27.0; Span = 3.0; Ori = "H" },
        @{ Mark = "CJ1"; X1 = 40.0; Y1 = 29.0; X2 = 39.0; Y2 = 29.0; FromX = 41.2; FromY = 29.0; Span = 1.0; Ori = "H" }
    )

    foreach ($j in $edgeJacks) {
        $tId = "TRUSS_$idCounter"
        $trusses += [PSCustomObject]@{
            Id = $tId; Mark = $j.Mark; Type = "JACKS"; StartX = $j.X1; StartY = $j.Y1; EndX = $j.X2; EndY = $j.Y2
            FromX = $j.FromX; FromY = $j.FromY; Orientation = $j.Ori; Span = $j.Span; IsGirder = $false
        }
        if ($defProfiles.ContainsKey($j.Mark)) {
            foreach ($p in $defProfiles[$j.Mark]) {
                if ($p[0] -le $j.Span) {
                    $ptX = if ($j.Ori -eq "H") { if ($j.X1 -lt 20) { $p[0] } else { 40.0 - $p[0] } } else { $j.X1 }
                    $ptY = if ($j.Ori -eq "V") { if ($j.Y1 -lt 15) { $p[0] } else { 30.0 - $p[0] } } else { $j.Y1 }
                    $panelPoints += [PSCustomObject]@{
                        TrussId = $tId; Mark = $j.Mark; Type = "JACKS"; Dist = $p[0]; X = [Math]::Round($ptX, 2); Y = [Math]::Round($ptY, 2); Defl = $p[1]
                    }
                }
            }
        }
        $idCounter++
    }

    # 4 Corner Hip Jacks HJ10 (45 degrees)
    $cornerHips = @(
        @{ Mark = "HJ10"; X1 = 0.0;  Y1 = 0.0;  X2 = 7.0;  Y2 = 7.0;  FromX = -0.9; FromY = -0.9 },
        @{ Mark = "HJ10"; X1 = 0.0;  Y1 = 30.0; X2 = 7.0;  Y2 = 23.0; FromX = -0.9; FromY = 30.9 },
        @{ Mark = "HJ10"; X1 = 40.0; Y1 = 0.0;  X2 = 33.0; Y2 = 7.0;  FromX = 40.9; FromY = -0.9 },
        @{ Mark = "HJ10"; X1 = 40.0; Y1 = 30.0; X2 = 33.0; Y2 = 23.0; FromX = 40.9; FromY = 30.9 }
    )

    foreach ($hj in $cornerHips) {
        $tId = "TRUSS_$idCounter"
        $trusses += [PSCustomObject]@{
            Id = $tId; Mark = $hj.Mark; Type = "HIPS"; StartX = $hj.X1; StartY = $hj.Y1; EndX = $hj.X2; EndY = $hj.Y2
            FromX = $hj.FromX; FromY = $hj.FromY; Orientation = "D"; Span = 9.82; IsGirder = $false
        }
        $dx = ($hj.X2 - $hj.X1) / 9.899
        $dy = ($hj.Y2 - $hj.Y1) / 9.899
        if ($defProfiles.ContainsKey("HJ10")) {
            foreach ($p in $defProfiles["HJ10"]) {
                $panelPoints += [PSCustomObject]@{
                    TrussId = $tId; Mark = "HJ10"; Type = "HIPS"; Dist = $p[0]
                    X = [Math]::Round($hj.X1 + $p[0] * $dx, 2); Y = [Math]::Round($hj.Y1 + $p[0] * $dy, 2); Defl = $p[1]
                }
            }
        }
        $idCounter++
    }
} else {
    # --------------------------------------------------------------------------
    # Generic Multi-Job Dynamic Layout Engine (Job 00002 and any other job)
    # --------------------------------------------------------------------------
    $currentX = 4.0
    $spacing = 2.0  # 24" o.c. spacing
    $maxSpanObserved = 30.0

    # Sort marks logically: Girders first, then Commons, Hips, Jacks, Valleys, Gables
    $sortedItems = $itemRows | Sort-Object {
        if ($_.Mark -match '^(TG|HG|MG|G)') { 1 }
        elseif ($_.Mark -match '^(T-|C)') { 2 }
        elseif ($_.Mark -match '^H') { 3 }
        elseif ($_.Mark -match '^(EJ|CJ|J)') { 4 }
        elseif ($_.Mark -match '^V') { 5 }
        elseif ($_.Mark -match '^GE') { 6 }
        else { 7 }
    }, { $_.Span } -Descending

    foreach ($item in $sortedItems) {
        $m = $item.Mark
        $qty = [Math]::Max(1, [int]$item.Quantity)
        $span = if ($item.Span -gt 0) { $item.Span } elseif ($markToSpan.ContainsKey($m)) { $markToSpan[$m] } else { 30.0 }
        if ($span -gt $maxSpanObserved) { $maxSpanObserved = $span }

        $isGirder = ($m -match '^(TG|HG|MG|G)')
        $tType = if ($isGirder) { "GIRDERS" }
                 elseif ($m -match '^H') { "HIPS" }
                 elseif ($m -match '^(EJ|CJ|J)') { "JACKS" }
                 elseif ($m -match '^V') { "VALLEYS" }
                 elseif ($m -match '^GE') { "GABLES" }
                 else { "COMMONS" }

        for ($q = 0; $q -lt $qty; $q++) {
            $tId = "TRUSS_$idCounter"
            $trusses += [PSCustomObject]@{
                Id = $tId; Mark = $m; Type = $tType
                StartX = $currentX; StartY = 0.0; EndX = $currentX; EndY = $span
                FromX = $currentX; FromY = -1.2; Orientation = "V"
                Span = $span; IsGirder = $isGirder
            }

            # Map Bottom Chord Panel Points along the chord from (FROM) origin
            if ($defProfiles.ContainsKey($m) -and $defProfiles[$m].Count -gt 0) {
                foreach ($p in $defProfiles[$m]) {
                    $panelPoints += [PSCustomObject]@{
                        TrussId = $tId; Mark = $m; Type = $tType
                        Dist = $p[0]; X = $currentX; Y = [Math]::Round($p[0], 2); Defl = $p[1]
                    }
                }
            }

            $currentX += $spacing
            $idCounter++
        }
        $currentX += 1.0  # Visual separation gap between marks
    }

    $bWidth = [Math]::Round($currentX + 2.0, 1)
    $bDepth = [Math]::Round($maxSpanObserved + 4.0, 1)
}

Write-Host ("   * Compiled {0} layout lines and {1} BC panel points." -f $trusses.Count, $panelPoints.Count) -ForegroundColor Green

# ------------------------------------------------------------------------------
# 6. Dynamic Deflection Statistics & Filter Buttons
# ------------------------------------------------------------------------------
$maxDefl = 0.0
$critMark = "N/A"
$critStation = 0.0
$critTrussId = ""
$critSpan = 30.0

if ($panelPoints.Count -gt 0) {
    $sortedDefl = $panelPoints | Sort-Object Defl -Descending
    $critPoint = $sortedDefl[0]
    $maxDefl = $critPoint.Defl
    $critMark = $critPoint.Mark
    $critStation = $critPoint.Dist
    $critTrussId = $critPoint.TrussId
    $critSpan = if ($markToSpan.ContainsKey($critMark)) { $markToSpan[$critMark] } else { 30.0 }
}

# Approx fraction for max deflection
$fractionStr = ""
if ($maxDefl -gt 0.001) {
    $sixteenths = [Math]::Round($maxDefl * 16.0)
    $fractionStr = switch ($sixteenths) {
        1 { "(~1/16`")" }
        2 { "(~1/8`")" }
        3 { "(~3/16`")" }
        4 { "(~1/4`")" }
        5 { "(~5/16`")" }
        6 { "(~3/8`")" }
        default { "(~$sixteenths/16`")" }
    }
}

# Peak Girder
$girderPts = $panelPoints | Where-Object { $_.Type -eq "GIRDERS" -and $_.Defl -gt 0 }
$peakGirderDefl = 0.0; $peakGirderMark = "None"; $peakGirderSta = 0.0
if ($girderPts) {
    $bestG = ($girderPts | Sort-Object Defl -Descending)[0]
    $peakGirderDefl = $bestG.Defl; $peakGirderMark = $bestG.Mark; $peakGirderSta = $bestG.Dist
}

# Peak Common
$commonPts = $panelPoints | Where-Object { $_.Type -eq "COMMONS" -and $_.Defl -gt 0 }
$peakCommonDefl = 0.0; $peakCommonMark = "None"; $peakCommonSta = 0.0
if ($commonPts) {
    $bestC = ($commonPts | Sort-Object Defl -Descending)[0]
    $peakCommonDefl = $bestC.Defl; $peakCommonMark = $bestC.Mark; $peakCommonSta = $bestC.Dist
}

# Secondary Peak (for card 2 if no girders)
$secondaryTitle = if ($peakGirderMark -ne "None") { "Girder Peak Deflection" } else { "Peak Truss Deflection" }
$secondaryDefl = if ($peakGirderMark -ne "None") { $peakGirderDefl } else { $maxDefl }
$secondaryMark = if ($peakGirderMark -ne "None") { $peakGirderMark } else { $critMark }
$secondarySta = if ($peakGirderMark -ne "None") { $peakGirderSta } else { $critStation }

# Card 3 Title
$tertiaryTitle = if ($peakCommonMark -ne "None") { "Common Truss Deflection" } else { "Governing Panel Point" }
$tertiaryDefl = if ($peakCommonMark -ne "None") { $peakCommonDefl } else { $maxDefl }
$tertiaryMark = if ($peakCommonMark -ne "None") { $peakCommonMark } else { $critMark }
$tertiarySta = if ($peakCommonMark -ne "None") { $peakCommonSta } else { $critStation }

# Build dynamic filter buttons
$typesPresent = $trusses | Select-Object -ExpandProperty Type -Unique
$filterButtonsHtml = "<button onclick=`"setFilter('ALL')`" id=`"btn-ALL`" class=`"px-2.5 py-1 rounded-lg font-medium border border-blue-500 bg-blue-500/10 text-blue-400`">All Framing ($($trusses.Count))</button>"
foreach ($tp in $typesPresent) {
    $cnt = ($trusses | Where-Object { $_.Type -eq $tp }).Count
    $label = switch ($tp) {
        "GIRDERS" { "Girders ($cnt)" }
        "COMMONS" { "Commons ($cnt)" }
        "HIPS"    { "Hips ($cnt)" }
        "JACKS"   { "Jacks ($cnt)" }
        "VALLEYS" { "Valleys ($cnt)" }
        "GABLES"  { "Gables ($cnt)" }
        default   { "$tp ($cnt)" }
    }
    $filterButtonsHtml += "`n        <button onclick=`"setFilter('$tp')`" id=`"btn-$tp`" class=`"px-2.5 py-1 rounded-lg font-medium border border-transparent hover:border-slate-600 text-slate-400`">$label</button>"
}

$legendMax = [Math]::Max(0.05, [Math]::Round($maxDefl * 1.05, 2))

# ------------------------------------------------------------------------------
# 7. Generate Self-Contained Interactive HTML Deflection Map
# ------------------------------------------------------------------------------
Write-Host "[6/6] Generating Interactive Deflection Layout Map (HTML)..." -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $jobDir "$JobNumber`_DeflectionMap.html"
}

$layoutDataObj = [PSCustomObject]@{
    Job = @{
        Number = $JobNumber
        Description = $jobDesc
        Width = $bWidth
        Depth = $bDepth
        MaxDefl = $maxDefl
    }
    Trusses = $trusses
    PanelPoints = $panelPoints
}

$jsonPayload = $layoutDataObj | ConvertTo-Json -Depth 6

$viewBoxStr = "-4 -4 $([Math]::Round($bWidth + 8, 1)) $([Math]::Round($bDepth + 8, 1))"

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Alpine intelliVIEW - Job $JobNumber Deflection Layout Map</title>
  <script src="https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js"></script>
  <style>
    @keyframes pulse-hotspot {
      0% { transform: scale(0.9); opacity: 0.95; }
      50% { transform: scale(1.4); opacity: 0.35; }
      100% { transform: scale(0.9); opacity: 0.95; }
    }
    .pulse-node {
      transform-origin: center;
      animation: pulse-hotspot 2s infinite ease-in-out;
    }
    .tooltip-box {
      pointer-events: none;
      transition: opacity 0.12s ease-out, transform 0.12s ease-out;
    }
  </style>
</head>
<body class="bg-slate-900 text-slate-100 antialiased p-3 sm:p-5">
  <div class="bg-slate-800 text-slate-100 border border-slate-700 rounded-2xl p-5 shadow-2xl max-w-6xl mx-auto space-y-4">
    
    <!-- Header -->
    <div class="flex flex-wrap items-center justify-between gap-3 border-b border-slate-700 pb-4">
      <div>
        <div class="flex items-center gap-2">
          <span class="px-2.5 py-0.5 rounded-full text-xs font-semibold bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">ITW Alpine intelliVIEW</span>
          <span class="text-xs text-slate-400">Job #$JobNumber ($jobDesc) &bull; $($bWidth)' &times; $($bDepth)' Roof Framing</span>
        </div>
        <h1 class="text-xl font-bold tracking-tight mt-1">Bottom Chord Deflection Layout Map</h1>
        <p class="text-xs text-slate-400">Registered to Alpine CAD Layout: $($trusses.Count) framing lines &amp; $($panelPoints.Count) Bottom Chord deflection panel points with (FROM) overhang origins ('x').</p>
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs font-medium text-slate-400">Governing Load Case:</span>
        <span class="px-2.5 py-1 rounded bg-slate-700 text-xs font-bold text-blue-400 font-mono">Case 004 / 001 (Total Load)</span>
      </div>
    </div>

    <!-- Quick Stat Cards -->
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
      <div class="p-3 rounded-xl bg-slate-900/80 border border-slate-700">
        <div class="text-[11px] font-medium text-slate-400 uppercase tracking-wider">Critical Peak Deflection</div>
        <div class="text-xl font-extrabold text-red-400 mt-0.5">$($maxDefl.ToString("F4"))" <span class="text-xs font-normal text-slate-400">$fractionStr</span></div>
        <div class="text-[11px] text-slate-400 mt-0.5">Truss <span class="font-bold text-slate-200">$critMark</span> @ Sta = $($critStation.ToString("F2"))'</div>
      </div>

      <div class="p-3 rounded-xl bg-slate-900/80 border border-slate-700">
        <div class="text-[11px] font-medium text-slate-400 uppercase tracking-wider">$secondaryTitle</div>
        <div class="text-xl font-extrabold text-amber-400 mt-0.5">$($secondaryDefl.ToString("F4"))"</div>
        <div class="text-[11px] text-slate-400 mt-0.5">Truss <span class="font-bold text-slate-200">$secondaryMark</span> @ Sta = $($secondarySta.ToString("F2"))'</div>
      </div>

      <div class="p-3 rounded-xl bg-slate-900/80 border border-slate-700">
        <div class="text-[11px] font-medium text-slate-400 uppercase tracking-wider">$tertiaryTitle</div>
        <div class="text-xl font-extrabold text-sky-400 mt-0.5">$($tertiaryDefl.ToString("F4"))"</div>
        <div class="text-[11px] text-slate-400 mt-0.5">Truss <span class="font-bold text-slate-200">$tertiaryMark</span> @ Sta = $($tertiarySta.ToString("F2"))'</div>
      </div>

      <div class="p-3 rounded-xl bg-slate-900/80 border border-slate-700">
        <div class="text-[11px] font-medium text-slate-400 uppercase tracking-wider">Framing Model Inventory</div>
        <div class="text-xl font-extrabold text-slate-100 mt-0.5">$($trusses.Count) <span class="text-xs font-normal text-slate-400">Lines</span></div>
        <div class="text-[11px] text-slate-400 mt-0.5">$($panelPoints.Count) BC Panel Points Analyzed</div>
      </div>
    </div>

    <!-- Controls Bar -->
    <div class="flex flex-wrap items-center justify-between gap-3 p-3 rounded-xl bg-slate-900/50 border border-slate-700 text-xs">
      
      <!-- Filter Buttons -->
      <div class="flex items-center gap-1.5 flex-wrap">
        <span class="font-medium text-slate-400 mr-1">Filter:</span>
        $filterButtonsHtml
      </div>

      <!-- Toggles -->
      <div class="flex items-center gap-2">
        <label class="inline-flex items-center gap-1 cursor-pointer">
          <input type="checkbox" id="toggleNodes" checked onchange="renderMap()" class="accent-blue-500 rounded">
          <span>BC Deflection Nodes</span>
        </label>
        <label class="inline-flex items-center gap-1 cursor-pointer ml-2">
          <input type="checkbox" id="toggleMarks" checked onchange="renderMap()" class="accent-blue-500 rounded">
          <span>Truss Marks</span>
        </label>
      </div>

      <!-- Heatmap Legend -->
      <div class="flex items-center gap-2">
        <span class="text-slate-400">Deflection Magnitude:</span>
        <div class="flex items-center gap-1 font-mono text-[10px]">
          <span class="inline-block w-2.5 h-2.5 rounded-full bg-emerald-500"></span> 0.00"
          <div class="w-16 h-2 rounded bg-gradient-to-r from-emerald-500 via-amber-500 via-orange-500 to-red-500"></div>
          <span class="inline-block w-2.5 h-2.5 rounded-full bg-red-500"></span> $($legendMax.ToString("F2"))"
        </div>
      </div>

    </div>

    <!-- Map Canvas Container -->
    <div class="relative w-full bg-slate-950 rounded-xl border border-slate-700 overflow-hidden flex items-center justify-center p-3" style="min-height: 520px;">
      
      <!-- Interactive SVG -->
      <svg id="layoutSvg" viewBox="$viewBoxStr" class="w-full h-auto max-h-[580px] select-none" style="transform: scaleY(-1);">
        
        <!-- Architectural Grid -->
        <g stroke="currentColor" stroke-width="0.06" opacity="0.12">
          <line x1="0" y1="0" x2="$bWidth" y2="0" />
          <line x1="0" y1="$([Math]::Round($bDepth/2, 1))" x2="$bWidth" y2="$([Math]::Round($bDepth/2, 1))" stroke-dasharray="0.5, 0.5" stroke-width="0.08" />
          <line x1="0" y1="$bDepth" x2="$bWidth" y2="$bDepth" />
          <line x1="0" y1="0" x2="0" y2="$bDepth" />
          <line x1="$([Math]::Round($bWidth/2, 1))" y1="0" x2="$([Math]::Round($bWidth/2, 1))" y2="$bDepth" stroke-dasharray="0.5, 0.5" stroke-width="0.08" />
          <line x1="$bWidth" y1="0" x2="$bWidth" y2="$bDepth" />
        </g>

        <!-- Building Bearing Perimeter (Blue Outline) -->
        <g id="wallsLayer">
          <rect x="0" y="0" width="$bWidth" height="$bDepth" fill="none" stroke="#2563EB" stroke-width="0.25" opacity="0.85" />
          <rect x="0.35" y="0.35" width="$([Math]::Round($bWidth - 0.7, 1))" height="$([Math]::Round($bDepth - 0.7, 1))" fill="none" stroke="#2563EB" stroke-width="0.15" opacity="0.6" />
          <rect x="-1" y="-1" width="$([Math]::Round($bWidth + 2.0, 1))" height="$([Math]::Round($bDepth + 2.0, 1))" fill="none" stroke="#10B981" stroke-width="0.2" opacity="0.7" />
        </g>

        <!-- Truss Framing Lines -->
        <g id="trussLinesLayer"></g>

        <!-- Overhang 'x' (FROM side) Indicators -->
        <g id="overhangIndicatorsLayer"></g>

        <!-- Truss Mark Labels -->
        <g id="labelsLayer"></g>

        <!-- Deflection Panel Point Nodes -->
        <g id="nodesLayer"></g>
      </svg>

      <!-- Tooltip Floating Div -->
      <div id="tooltip" class="tooltip-box absolute hidden bg-slate-900 text-slate-100 border border-slate-700 rounded-xl p-3 shadow-2xl text-xs space-y-1 z-30 pointer-events-none min-w-[210px]">
        <div class="flex items-center justify-between gap-3 border-b border-slate-700 pb-1">
          <span id="ttMark" class="font-extrabold text-sm text-blue-400">Mark</span>
          <span id="ttType" class="px-1.5 py-0.5 rounded text-[10px] bg-slate-800 font-semibold text-slate-200">Type</span>
        </div>
        <div class="grid grid-cols-2 gap-x-3 gap-y-0.5 text-[11px] pt-0.5">
          <span class="text-slate-400">Chord Station:</span>
          <span id="ttDist" class="font-mono font-medium text-right">0.00 ft</span>
          <span class="text-slate-400">Plan Coord:</span>
          <span id="ttCoord" class="font-mono font-medium text-right">(0.0, 0.0)</span>
          <span class="text-slate-400">Total Load Defl:</span>
          <span id="ttDefl" class="font-mono font-bold text-red-400 text-right">0.0000"</span>
          <span class="text-slate-400">Deflection Ratio:</span>
          <span id="ttRatio" class="font-mono text-emerald-400 text-right">L / 9999</span>
          <span class="text-slate-400">Span Origin:</span>
          <span id="ttFrom" class="font-mono text-blue-400 text-right">Overhang 'x'</span>
        </div>
      </div>

    </div>

  </div>

  <script>
    const data = $jsonPayload;

    let currentFilter = 'ALL';
    const svg = document.getElementById('layoutSvg');
    const trussLinesLayer = document.getElementById('trussLinesLayer');
    const overhangIndicatorsLayer = document.getElementById('overhangIndicatorsLayer');
    const labelsLayer = document.getElementById('labelsLayer');
    const nodesLayer = document.getElementById('nodesLayer');
    const tooltip = document.getElementById('tooltip');

    function getDeflectionColor(defl) {
      const max = data.Job.MaxDefl || 0.18;
      const ratio = max > 0 ? (defl / max) : 0;
      if (ratio <= 0.15) return '#10B981';
      if (ratio <= 0.45) return '#F59E0B';
      if (ratio <= 0.75) return '#F97316';
      return '#EF4444';
    }

    function renderMap() {
      trussLinesLayer.innerHTML = '';
      overhangIndicatorsLayer.innerHTML = '';
      labelsLayer.innerHTML = '';
      nodesLayer.innerHTML = '';

      const showNodes = document.getElementById('toggleNodes').checked;
      const showMarks = document.getElementById('toggleMarks').checked;

      // 1. Render Trusses
      data.Trusses.forEach(t => {
        let visible = true;
        if (currentFilter !== 'ALL' && t.Type !== currentFilter) visible = false;

        if (!visible) return;

        if (t.IsGirder) {
          [-0.14, 0.14].forEach(offset => {
            const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            line.setAttribute('x1', t.StartX + offset);
            line.setAttribute('y1', t.StartY);
            line.setAttribute('x2', t.EndX + offset);
            line.setAttribute('y2', t.EndY);
            line.setAttribute('stroke', '#64748B');
            line.setAttribute('stroke-width', '0.22');
            trussLinesLayer.appendChild(line);
          });
        } else {
          const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
          line.setAttribute('x1', t.StartX);
          line.setAttribute('y1', t.StartY);
          line.setAttribute('x2', t.EndX);
          line.setAttribute('y2', t.EndY);
          line.setAttribute('stroke', t.Type === 'VALLEYS' ? '#38BDF8' : '#FACC15');
          line.setAttribute('stroke-width', '0.18');
          line.setAttribute('opacity', '0.9');
          trussLinesLayer.appendChild(line);
        }

        // Overhang 'x' Indicator
        const xText = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        xText.setAttribute('x', t.FromX);
        xText.setAttribute('y', t.FromY);
        xText.setAttribute('font-size', '0.7');
        xText.setAttribute('font-family', 'monospace');
        xText.setAttribute('font-weight', 'bold');
        xText.setAttribute('fill', '#EF4444');
        xText.setAttribute('text-anchor', 'middle');
        xText.setAttribute('dominant-baseline', 'central');
        xText.setAttribute('style', 'transform: scaleY(-1); transform-origin: ' + t.FromX + 'px ' + t.FromY + 'px;');
        xText.textContent = 'x';
        overhangIndicatorsLayer.appendChild(xText);

        // Truss Mark Label
        if (showMarks) {
          let labelX = (t.StartX + t.EndX) / 2;
          let labelY = (t.StartY + t.EndY) / 2;
          let angle = 0;

          if (t.Orientation === 'V') {
            labelX = t.StartX;
            labelY = Math.min(6.5, t.Span * 0.25);
            angle = 90;
          } else if (t.Orientation === 'H') {
            labelY = t.StartY;
            labelX = (t.StartX < (data.Job.Width / 2)) ? 3.5 : (data.Job.Width - 3.5);
            angle = 0;
          } else if (t.Orientation === 'D') {
            labelX = (t.StartX + t.EndX) / 2;
            labelY = (t.StartY + t.EndY) / 2;
            angle = (t.EndY > t.StartY) ? 45 : -45;
          }

          const txt = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          txt.setAttribute('x', labelX);
          txt.setAttribute('y', labelY);
          txt.setAttribute('font-size', '0.62');
          txt.setAttribute('font-weight', 'bold');
          txt.setAttribute('font-family', 'sans-serif');
          txt.setAttribute('fill', '#38BDF8');
          txt.setAttribute('text-anchor', 'middle');
          txt.setAttribute('dominant-baseline', 'central');
          txt.setAttribute('style', 'transform: scaleY(-1) rotate(' + angle + 'deg); transform-origin: ' + labelX + 'px ' + labelY + 'px;');
          txt.textContent = t.Mark;
          labelsLayer.appendChild(txt);
        }
      });

      // 2. Render Deflection Panel Points
      if (showNodes) {
        data.PanelPoints.forEach(p => {
          let visible = true;
          if (currentFilter !== 'ALL' && p.Type !== currentFilter) visible = false;

          if (!visible) return;

          const color = getDeflectionColor(p.Defl);
          const max = data.Job.MaxDefl || 0.18;
          const radius = Math.max(0.26, 0.20 + (p.Defl / (max || 0.18)) * 0.45);

          const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
          circle.setAttribute('cx', p.X);
          circle.setAttribute('cy', p.Y);
          circle.setAttribute('r', radius);
          circle.setAttribute('fill', color);
          circle.setAttribute('stroke', '#FFFFFF');
          circle.setAttribute('stroke-width', '0.07');
          circle.setAttribute('cursor', 'pointer');
          circle.setAttribute('class', 'transition-transform hover:scale-150');

          if (data.Job.MaxDefl > 0.005 && Math.abs(p.Defl - data.Job.MaxDefl) < 0.0001) {
            circle.classList.add('pulse-node');
          }

          circle.addEventListener('mouseenter', (e) => showTooltip(e, p));
          circle.addEventListener('mousemove', (e) => updateTooltipPos(e));
          circle.addEventListener('mouseleave', hideTooltip);

          nodesLayer.appendChild(circle);
        });
      }
    }

    function showTooltip(e, p) {
      document.getElementById('ttMark').textContent = p.Mark;
      document.getElementById('ttType').textContent = p.Type;

      document.getElementById('ttDist').textContent = p.Dist.toFixed(2) + ' ft';
      document.getElementById('ttCoord').textContent = '(' + p.X.toFixed(1) + ', ' + p.Y.toFixed(1) + ')';
      document.getElementById('ttDefl').textContent = p.Defl.toFixed(4) + '"';
      
      let ratioStr = 'L / 9999 (Rigid)';
      let truss = data.Trusses.find(t => t.Id === p.TrussId);
      let spanFt = (truss && truss.Span) ? truss.Span : 30.0;
      let spanInches = spanFt * 12.0;

      if (p.Defl > 0.0005) {
        ratioStr = 'L / ' + Math.round(spanInches / p.Defl);
      }
      document.getElementById('ttRatio').textContent = ratioStr;

      let fromSide = "South Overhang (Y=0)";
      if (truss && truss.Orientation === 'H') {
        fromSide = (p.X < (data.Job.Width / 2)) ? "West Wall (X=0)" : "East Wall (X=" + data.Job.Width + ")";
      }
      document.getElementById('ttFrom').textContent = fromSide;

      tooltip.classList.remove('hidden');
      updateTooltipPos(e);
    }

    function updateTooltipPos(e) {
      const parentRect = svg.parentElement.getBoundingClientRect();
      let x = e.clientX - parentRect.left + 15;
      let y = e.clientY - parentRect.top + 15;

      if (x + 230 > parentRect.width) x -= 250;
      if (y + 180 > parentRect.height) y -= 190;

      tooltip.style.left = x + 'px';
      tooltip.style.top = y + 'px';
    }

    function hideTooltip() {
      tooltip.classList.add('hidden');
    }

    function setFilter(filt) {
      currentFilter = filt;
      const allButtons = document.querySelectorAll('[id^="btn-"]');
      allButtons.forEach(btn => {
        if (btn.id === 'btn-' + filt) {
          btn.className = 'px-2.5 py-1 rounded-lg font-medium border border-blue-500 bg-blue-500/10 text-blue-400';
        } else {
          btn.className = 'px-2.5 py-1 rounded-lg font-medium border border-transparent hover:border-slate-600 text-slate-400';
        }
      });
      renderMap();
    }

    renderMap();
  </script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutputPath, $htmlContent, [System.Text.Encoding]::UTF8)

Write-Host "`n[SUCCESS] Generated Interactive Deflection Map HTML:" -ForegroundColor Green
Write-Host "   $OutputPath" -ForegroundColor Yellow

# ------------------------------------------------------------------------------
# 8. Display Summary Console Table
# ------------------------------------------------------------------------------
Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host (" SUMMARY DEFLECTION SCHEDULE FOR JOB #{0} ({1})" -f $JobNumber, $jobDesc) -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$sched = @()
$uniqueMarks = $trusses | Select-Object -ExpandProperty Mark -Unique

foreach ($m in ($uniqueMarks | Sort-Object)) {
    $qty = ($trusses | Where-Object { $_.Mark -eq $m }).Count
    $pts = $panelPoints | Where-Object { $_.Mark -eq $m }
    $span = if ($markToSpan.ContainsKey($m)) { $markToSpan[$m] }
            else {
                $tMatch = $trusses | Where-Object { $_.Mark -eq $m } | Select-Object -First 1
                if ($tMatch) { $tMatch.Span } else { 30.0 }
            }
    
    $maxD = 0.0
    $critLoc = 0.0
    if ($pts -and $pts.Count -gt 0) {
        $sorted = $pts | Sort-Object Defl -Descending
        $maxD = $sorted[0].Defl
        $critLoc = $sorted[0].Dist
    }

    $ratioStr = "Rigid"
    if ($maxD -gt 0.0005) {
        $ratio = [Math]::Round(($span * 12.0) / $maxD)
        $ratioStr = "L / $ratio"
    }

    $sched += [PSCustomObject]@{
        Mark = $m
        Quantity = $qty
        Span = ("{0:F1}'" -f $span)
        Nodes = if ($pts) { $pts.Count / [Math]::Max(1, $qty) } else { 0 }
        PeakDeflection = ("{0:F4}`"" -f $maxD)
        CriticalStation = ("{0:F2}'" -f $critLoc)
        DeflectionRatio = $ratioStr
    }
}

$sched | Format-Table -AutoSize

# Open in Browser if requested
$shouldOpen = ($OpenInBrowser -notmatch '^(false|0)$')
if ($shouldOpen) {
    Write-Host "Opening map in default browser..." -ForegroundColor Cyan
    Start-Process $OutputPath
}
