function Test-MetricHeaderLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }
    $lower = $Line.ToLowerInvariant()
    return ($lower -match '\binterval\b' -and $lower -match '\bi/o\b')
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

function Get-MetricValuesFromLine {
    param([string]$Line)
    $dataLine = Get-MetricDataLine $Line
    if ($null -eq $dataLine) {
        return $null
    }

    $regexMatches = [System.Text.RegularExpressions.Regex]::Matches($dataLine, '[-+]?\d+(?:\.\d+)?')
    if ($regexMatches.Count -lt 3) {
        return $null
    }

    try {
        $interval = [double]$regexMatches[0].Value
        $iops = [double]$regexMatches[1].Value
        $mbps = [double]$regexMatches[2].Value
        $latency = 0.0
        if ($regexMatches.Count -ge 6) {
            $latency = [double]$regexMatches[5].Value
        } elseif ($regexMatches.Count -ge 5) {
            $latency = [double]$regexMatches[4].Value
        }
        return [pscustomobject]@{
            Interval = $interval
            Iops = $iops
            Mbps = $mbps
            Latency = $latency
        }
    } catch {
        Write-AppLog ("Metric parse failed for line: {0}" -f $Line) "WARN"
        return $null
    }
}

function Get-RunSummaryFromFile {
    param([string]$StdoutPath)
    if ([string]::IsNullOrWhiteSpace($StdoutPath) -or -not (Test-Path -LiteralPath $StdoutPath)) {
        return @{}
    }
    $last = $null
    foreach ($line in [System.IO.File]::ReadLines($StdoutPath)) {
        $metrics = Get-MetricValuesFromLine $line
        if ($null -ne $metrics) {
            $last = $metrics
        }
    }
    if ($null -eq $last) {
        return @{}
    }
    return @{
        LastInterval = [string]$last.Interval
        LastIops = ("{0:n2}" -f [double]$last.Iops)
        LastMbps = ("{0:n2}" -f [double]$last.Mbps)
        LastLatency = ("{0:n3}" -f [double]$last.Latency)
    }
}
