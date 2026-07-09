function Test-MetricHeaderLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }
    $lower = $Line.ToLowerInvariant()
    return ($lower -match '\binterval\b' -and ($lower -match '\bi/o\b' -or $lower -match '\breqstdops\b' -or $lower -match '\brate\b'))
}

function Get-MetricDataLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    if (Test-MetricHeaderLine $Line) {
        return $null
    }
    if ($Line -match '^\s*\*') {
        return $null
    }

    $working = $Line.Trim()
    if ($working -match '^\d{1,2}:\d{2}:\d{2}(\.\d+)?\s+(.*)$') {
        $working = $Matches[2].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($working)) {
        return $null
    }
    if ($working -notmatch '^\d') {
        return $null
    }
    return $working
}

function Get-MetricNumberList {
    param([string]$Text)
    $regexMatches = [System.Text.RegularExpressions.Regex]::Matches([string]$Text, '[-+]?\d+(?:\.\d+)?')
    $values = New-Object System.Collections.Generic.List[double]
    foreach ($match in $regexMatches) {
        try {
            [void]$values.Add([double]$match.Value)
        } catch {
        }
    }
    return ,$values
}

function Convert-MetricNumbersToPoint {
    param(
        [System.Collections.Generic.List[double]]$Numbers,
        [switch]$AverageLine
    )
    if ($null -eq $Numbers -or $Numbers.Count -lt 3) {
        return $null
    }
    try {
        # Average/max lines omit Interval: first value is already ReqstdOps rate.
        # Filesystem avg example:
        #   avg_4-33 2232.7 0.862 1.6 1.04 69.9 ... 48.80 20.97 69.77 32767
        # Interval data lines include Interval first:
        #   1 1168.0 0.959 1.9 0.58 70.7 ... 25.81 10.69 36.50 32768
        # Raw/block tables stay short: Interval, IOPS, MB/s, ..., latency.
        if ($AverageLine) {
            if ($Numbers.Count -ge 12) {
                return [pscustomobject]@{
                    Interval = 0.0
                    Iops = [double]$Numbers[0]
                    Latency = [double]$Numbers[1]
                    Mbps = [double]$Numbers[11]
                    ReadPct = [double]$Numbers[4]
                    Kind = "filesystem"
                }
            }
            return [pscustomobject]@{
                Interval = 0.0
                Iops = [double]$Numbers[0]
                Mbps = [double]$Numbers[1]
                Latency = $(if ($Numbers.Count -ge 3) { [double]$Numbers[2] } else { 0.0 })
                ReadPct = $null
                Kind = "raw"
            }
        }
        if ($Numbers.Count -ge 13) {
            return [pscustomobject]@{
                Interval = [double]$Numbers[0]
                Iops = [double]$Numbers[1]
                Latency = [double]$Numbers[2]
                Mbps = [double]$Numbers[12]
                ReadPct = [double]$Numbers[5]
                Kind = "filesystem"
            }
        }
        $latency = 0.0
        if ($Numbers.Count -ge 6) {
            $latency = [double]$Numbers[5]
        } elseif ($Numbers.Count -ge 5) {
            $latency = [double]$Numbers[4]
        }
        return [pscustomobject]@{
            Interval = [double]$Numbers[0]
            Iops = [double]$Numbers[1]
            Mbps = [double]$Numbers[2]
            Latency = $latency
            ReadPct = $null
            Kind = "raw"
        }
    } catch {
        Write-AppLog ("Metric parse failed for numbers: {0}" -f ($Numbers -join ",")) "WARN"
        return $null
    }
}

function Get-MetricValuesFromLine {
    param([string]$Line)
    $dataLine = Get-MetricDataLine $Line
    if ($null -eq $dataLine) {
        return $null
    }
    $numbers = Get-MetricNumberList $dataLine
    return Convert-MetricNumbersToPoint $numbers
}

function Get-AverageMetricFromLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    $working = $Line.Trim()
    if ($working -match '^\d{1,2}:\d{2}:\d{2}(\.\d+)?\s+(.*)$') {
        $working = $Matches[2].Trim()
    }
    if ($working -notmatch '^(avg|max|std)_') {
        return $null
    }
    $kind = "avg"
    if ($working -match '^(avg|max|std)_([0-9]+-[0-9]+)\s+(.*)$') {
        $kind = $Matches[1].ToLowerInvariant()
        $range = $Matches[2]
        $rest = $Matches[3]
    } elseif ($working -match '^(avg|max|std)_\S+\s+(.*)$') {
        $kind = $Matches[1].ToLowerInvariant()
        $range = ""
        $rest = $Matches[2]
    } else {
        return $null
    }
    $numbers = Get-MetricNumberList $rest
    $point = Convert-MetricNumbersToPoint $numbers -AverageLine
    if ($null -eq $point) {
        return $null
    }
    return [pscustomobject]@{
        Kind = $kind
        Range = $range
        Interval = [double]$point.Interval
        Iops = [double]$point.Iops
        Mbps = [double]$point.Mbps
        Latency = [double]$point.Latency
        ReadPct = $point.ReadPct
        MetricKind = [string]$point.Kind
    }
}

function New-EmptyRunResultSummary {
    return [ordered]@{
        Status = ""
        Success = $false
        CurrentRd = ""
        FormatAvgIops = ""
        FormatAvgMbps = ""
        FormatAvgLatency = ""
        WorkloadAvgIops = ""
        WorkloadMaxIops = ""
        WorkloadAvgMbps = ""
        WorkloadAvgLatency = ""
        WorkloadReadPct = ""
        ObservedMaxIops = 0.0
        LastIops = ""
        LastMbps = ""
        LastLatency = ""
        LastInterval = ""
        CompletedMessage = ""
        AnchorCount = 0
        HasData = $false
    }
}

function Update-RunResultSummaryFromLine {
    param(
        $Summary,
        [string]$Line
    )
    if ($null -eq $Summary -or [string]::IsNullOrWhiteSpace($Line)) {
        return $Summary
    }
    if ($Line -match 'Starting RD=(\S+)') {
        $Summary.CurrentRd = $Matches[1].TrimEnd(';')
    }
    if ($Line -match 'Anchor size:') {
        $Summary.AnchorCount = [int]$Summary.AnchorCount + 1
    }
    if ($Line -match 'Vdbench execution completed successfully') {
        $Summary.Success = $true
        $Summary.Status = "Completed"
        $Summary.CompletedMessage = "Vdbench completed successfully"
        $Summary.HasData = $true
    } elseif ($Line -match 'RuntimeException|java\.lang\.|fatal error|FATAL') {
        $Summary.Success = $false
        $Summary.Status = "Failed"
        $Summary.CompletedMessage = $Line.Trim()
        $Summary.HasData = $true
    }

    $avg = Get-AverageMetricFromLine $Line
    if ($null -ne $avg -and $avg.Kind -eq "avg") {
        $Summary.HasData = $true
        $isFormat = ([string]$Summary.CurrentRd -like "format*")
        if ($isFormat) {
            $Summary.FormatAvgIops = ("{0:n1}" -f [double]$avg.Iops)
            $Summary.FormatAvgMbps = ("{0:n2}" -f [double]$avg.Mbps)
            $Summary.FormatAvgLatency = ("{0:n3}" -f [double]$avg.Latency)
        } else {
            $Summary.WorkloadAvgIops = ("{0:n1}" -f [double]$avg.Iops)
            $Summary.WorkloadAvgMbps = ("{0:n2}" -f [double]$avg.Mbps)
            $Summary.WorkloadAvgLatency = ("{0:n3}" -f [double]$avg.Latency)
            if ($null -ne $avg.ReadPct) {
                $Summary.WorkloadReadPct = ("{0:n1}" -f [double]$avg.ReadPct)
            }
            if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadMaxIops) -and [double]$Summary.ObservedMaxIops -gt 0) {
                $Summary.WorkloadMaxIops = ("{0:n1}" -f [double]$Summary.ObservedMaxIops)
            }
        }
        $Summary.LastIops = ("{0:n2}" -f [double]$avg.Iops)
        $Summary.LastMbps = ("{0:n2}" -f [double]$avg.Mbps)
        $Summary.LastLatency = ("{0:n3}" -f [double]$avg.Latency)
        $Summary.LastInterval = [string]$avg.Range
    } elseif ($null -ne $avg -and $avg.Kind -eq "max") {
        # Filesystem max_* rows are often sparse/misaligned across blank columns.
        # Prefer ObservedMaxIops collected from interval samples instead.
        $Summary.HasData = $true
        if ([string]$Summary.CurrentRd -notlike "format*" -and [string]$avg.MetricKind -eq "raw" -and [double]$avg.Iops -gt 0) {
            $Summary.WorkloadMaxIops = ("{0:n1}" -f [double]$avg.Iops)
        }
    }

    $point = Get-MetricValuesFromLine $Line
    if ($null -ne $point) {
        $Summary.HasData = $true
        $Summary.LastIops = ("{0:n2}" -f [double]$point.Iops)
        $Summary.LastMbps = ("{0:n2}" -f [double]$point.Mbps)
        $Summary.LastLatency = ("{0:n3}" -f [double]$point.Latency)
        $Summary.LastInterval = [string]([int][double]$point.Interval)
        if ([string]$Summary.CurrentRd -notlike "format*" -and [double]$point.Iops -gt [double]$Summary.ObservedMaxIops) {
            $Summary.ObservedMaxIops = [double]$point.Iops
            $Summary.WorkloadMaxIops = ("{0:n1}" -f [double]$point.Iops)
        }
    }
    return $Summary
}

function Get-RunResultSummaryFromText {
    param([string]$Text)
    $summary = New-EmptyRunResultSummary
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $summary
    }
    foreach ($line in ($Text -split "`r?`n")) {
        [void](Update-RunResultSummaryFromLine $summary $line)
    }
    return $summary
}

function Get-RunResultSummaryFromFile {
    param([string]$StdoutPath)
    $summary = New-EmptyRunResultSummary
    if ([string]::IsNullOrWhiteSpace($StdoutPath) -or -not (Test-Path -LiteralPath $StdoutPath)) {
        return $summary
    }
    foreach ($line in [System.IO.File]::ReadLines($StdoutPath)) {
        [void](Update-RunResultSummaryFromLine $summary $line)
    }
    return $summary
}

function Format-RunResultSummaryText {
    param($Summary)
    if ($null -eq $Summary) {
        return "Results: waiting for run output..."
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $status = [string](Get-PropertyValue $Summary "Status" "")
    if ([string]::IsNullOrWhiteSpace($status)) {
        if ([bool](Get-PropertyValue $Summary "HasData" $false)) {
            $status = "Running"
        } else {
            $status = "Idle"
        }
    }
    [void]$lines.Add(("Status: {0}" -f $status))
    $completed = [string](Get-PropertyValue $Summary "CompletedMessage" "")
    if (-not [string]::IsNullOrWhiteSpace($completed)) {
        [void]$lines.Add($completed)
    }
    $anchors = [int](Get-PropertyValue $Summary "AnchorCount" 0)
    if ($anchors -gt 0) {
        [void]$lines.Add(("Anchors seen: {0}" -f $anchors))
    }

    $formatMbps = [string](Get-PropertyValue $Summary "FormatAvgMbps" "")
    if (-not [string]::IsNullOrWhiteSpace($formatMbps)) {
        [void]$lines.Add(("Format avg: {0} MB/s  |  {1} IOPS  |  {2} ms" -f `
            $formatMbps, `
            [string](Get-PropertyValue $Summary "FormatAvgIops" ""), `
            [string](Get-PropertyValue $Summary "FormatAvgLatency" "")))
    }

    $workloadIops = [string](Get-PropertyValue $Summary "WorkloadAvgIops" "")
    if (-not [string]::IsNullOrWhiteSpace($workloadIops)) {
        $readPct = [string](Get-PropertyValue $Summary "WorkloadReadPct" "")
        $readText = if ([string]::IsNullOrWhiteSpace($readPct)) { "" } else { ("  |  read {0}%" -f $readPct) }
        [void]$lines.Add(("Workload avg: {0} IOPS  |  {1} MB/s  |  {2} ms{3}" -f `
            $workloadIops, `
            [string](Get-PropertyValue $Summary "WorkloadAvgMbps" ""), `
            [string](Get-PropertyValue $Summary "WorkloadAvgLatency" ""), `
            $readText))
        $maxIops = [string](Get-PropertyValue $Summary "WorkloadMaxIops" "")
        if (-not [string]::IsNullOrWhiteSpace($maxIops)) {
            [void]$lines.Add(("Workload max IOPS: {0}" -f $maxIops))
        }
    } elseif ([bool](Get-PropertyValue $Summary "HasData" $false)) {
        [void]$lines.Add(("Latest: {0} IOPS  |  {1} MB/s  |  {2} ms" -f `
            [string](Get-PropertyValue $Summary "LastIops" ""), `
            [string](Get-PropertyValue $Summary "LastMbps" ""), `
            [string](Get-PropertyValue $Summary "LastLatency" "")))
    } else {
        [void]$lines.Add("Start a run to see avg IOPS / MB/s / latency here.")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-RunSummaryFromFile {
    param([string]$StdoutPath)
    $result = Get-RunResultSummaryFromFile $StdoutPath
    if (-not [bool](Get-PropertyValue $result "HasData" $false)) {
        return @{}
    }
    return @{
        LastInterval = [string](Get-PropertyValue $result "LastInterval" "")
        LastIops = [string](Get-PropertyValue $result "LastIops" "")
        LastMbps = [string](Get-PropertyValue $result "LastMbps" "")
        LastLatency = [string](Get-PropertyValue $result "LastLatency" "")
        WorkloadAvgIops = [string](Get-PropertyValue $result "WorkloadAvgIops" "")
        WorkloadAvgMbps = [string](Get-PropertyValue $result "WorkloadAvgMbps" "")
        WorkloadAvgLatency = [string](Get-PropertyValue $result "WorkloadAvgLatency" "")
        WorkloadReadPct = [string](Get-PropertyValue $result "WorkloadReadPct" "")
        FormatAvgMbps = [string](Get-PropertyValue $result "FormatAvgMbps" "")
    }
}
