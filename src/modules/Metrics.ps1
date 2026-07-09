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
    param(
        [string]$Line,
        [string]$PhaseHint = ""
    )
    $dataLine = Get-MetricDataLine $Line
    if ($null -eq $dataLine) {
        return $null
    }
    $numbers = Get-MetricNumberList $dataLine
    $point = Convert-MetricNumbersToPoint $numbers
    if ($null -eq $point) {
        return $null
    }
    return [pscustomobject]@{
        Interval = [double]$point.Interval
        Iops = [double]$point.Iops
        Mbps = [double]$point.Mbps
        Latency = [double]$point.Latency
        ReadPct = $point.ReadPct
        Kind = [string]$point.Kind
        Phase = $PhaseHint
    }
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

function Get-LogTimestampFromLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    if ($Line -match '^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?') {
        $ms = 0
        if (-not [string]::IsNullOrWhiteSpace($Matches[4])) {
            $frac = $Matches[4]
            if ($frac.Length -gt 3) {
                $frac = $frac.Substring(0, 3)
            }
            while ($frac.Length -lt 3) {
                $frac = $frac + "0"
            }
            $ms = [int]$frac
        }
        return [TimeSpan]::FromHours([int]$Matches[1]).Add([TimeSpan]::FromMinutes([int]$Matches[2])).Add([TimeSpan]::FromSeconds([int]$Matches[3])).Add([TimeSpan]::FromMilliseconds($ms))
    }
    return $null
}

function Format-DurationSpan {
    param($Span)
    if ($null -eq $Span) {
        return "-"
    }
    try {
        $totalSeconds = [Math]::Max(0, [int][Math]::Round([double]$Span.TotalSeconds))
        $minutes = [int][Math]::Floor($totalSeconds / 60)
        $seconds = $totalSeconds % 60
        return ("{0}m {1:d2}s" -f $minutes, $seconds)
    } catch {
        return "-"
    }
}

function Get-DurationBetweenTimestamps {
    param(
        $Start,
        $End
    )
    if ($null -eq $Start -or $null -eq $End) {
        return $null
    }
    $delta = $End - $Start
    if ($delta.TotalSeconds -lt 0) {
        $delta = $delta.Add([TimeSpan]::FromDays(1))
    }
    return $delta
}

function Test-IsFormatRunDefinition {
    param([string]$RdName)
    return ([string]$RdName -like "format*")
}

function New-EmptyRunResultSummary {
    return [ordered]@{
        Status = ""
        Success = $false
        CurrentRd = ""
        CurrentPhase = ""
        FormatRd = ""
        WorkloadRd = ""
        FormatStart = $null
        FormatEnd = $null
        WorkloadStart = $null
        WorkloadEnd = $null
        FormatDuration = ""
        WorkloadDuration = ""
        FormatAvgIops = ""
        FormatMaxIops = ""
        FormatAvgMbps = ""
        FormatAvgLatency = ""
        FormatObservedMaxIops = 0.0
        WorkloadAvgIops = ""
        WorkloadMaxIops = ""
        WorkloadAvgMbps = ""
        WorkloadAvgLatency = ""
        WorkloadReadPct = ""
        WorkloadObservedMaxIops = 0.0
        LastIops = ""
        LastMbps = ""
        LastLatency = ""
        LastInterval = ""
        CompletedMessage = ""
        AnchorCount = 0
        RunDir = ""
        Slaves = @{}
        HasData = $false
    }
}

function Ensure-RunResultSlaveEntry {
    param(
        $Summary,
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }
    if ($null -eq $Summary.Slaves) {
        $Summary.Slaves = @{}
    }
    if (-not $Summary.Slaves.ContainsKey($Name)) {
        $Summary.Slaves[$Name] = [ordered]@{
            Name = $Name
            Host = ""
            Anchor = ""
            AvgIops = ""
            MaxIops = ""
            AvgMbps = ""
            AvgLatency = ""
            ReadPct = ""
            ObservedMaxIops = 0.0
            Notes = New-Object System.Collections.Generic.List[string]
        }
    }
}

function Find-RunResultSlaveKey {
    param(
        $Summary,
        [string]$Name
    )
    if ($null -eq $Summary -or $null -eq $Summary.Slaves -or [string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }
    if ($Summary.Slaves.ContainsKey($Name)) {
        return $Name
    }
    foreach ($key in @($Summary.Slaves.Keys)) {
        if ([string]$key -eq $Name) {
            return [string]$key
        }
        if ([string]$key.StartsWith($Name + "-", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$key
        }
        if ($Name.StartsWith([string]$key + "-", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$key
        }
    }
    return ""
}

function Set-RunResultSlaveMetrics {
    param(
        $Summary,
        [string]$Name,
        [double]$Iops,
        [double]$Mbps,
        [double]$Latency,
        $ReadPct = $null
    )
    if ($null -eq $Summary -or [string]::IsNullOrWhiteSpace($Name)) {
        return
    }
    $key = Find-RunResultSlaveKey $Summary $Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        Ensure-RunResultSlaveEntry $Summary $Name
        $key = $Name
    }
    $slave = $Summary.Slaves[$key]
    if ($Iops -gt 0) {
        $slave.AvgIops = ("{0:n1}" -f $Iops)
        if ($Iops -gt [double]$slave.ObservedMaxIops) {
            $slave.ObservedMaxIops = $Iops
            $slave.MaxIops = ("{0:n1}" -f $Iops)
        } elseif ([string]::IsNullOrWhiteSpace([string]$slave.MaxIops)) {
            $slave.MaxIops = ("{0:n1}" -f $Iops)
        } else {
            $existingMax = 0.0
            [void][double]::TryParse(([string]$slave.MaxIops).Replace(",", ""), [ref]$existingMax)
            $maxVal = [Math]::Max($existingMax, $Iops)
            $slave.ObservedMaxIops = $maxVal
            $slave.MaxIops = ("{0:n1}" -f $maxVal)
        }
    }
    if ($Mbps -gt 0) {
        $slave.AvgMbps = ("{0:n2}" -f $Mbps)
    }
    if ($Latency -gt 0) {
        $slave.AvgLatency = ("{0:n3}" -f $Latency)
    }
    if ($null -ne $ReadPct) {
        $slave.ReadPct = ("{0:n1}" -f [double]$ReadPct)
    }
    $Summary.HasData = $true
}

function Update-RunResultSummaryFromSkewText {
    param(
        $Summary,
        [string]$Text
    )
    if ($null -eq $Summary -or [string]::IsNullOrWhiteSpace($Text)) {
        return $Summary
    }
    # skew.html is HTML; strip tags so we can parse the Slave: rate table.
    $plain = [System.Text.RegularExpressions.Regex]::Replace($Text, '(?is)<script.*?</script>', ' ')
    $plain = [System.Text.RegularExpressions.Regex]::Replace($plain, '(?is)<style.*?</style>', ' ')
    $plain = [System.Text.RegularExpressions.Regex]::Replace($plain, '(?i)<br\s*/?>', [Environment]::NewLine)
    $plain = [System.Text.RegularExpressions.Regex]::Replace($plain, '(?i)</(p|div|tr|h\d)>', [Environment]::NewLine)
    $plain = [System.Text.RegularExpressions.Regex]::Replace($plain, '<[^>]+>', ' ')
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)

    $inSlaveSection = $false
    foreach ($rawLine in ($plain -split "`r?`n")) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -match '(?i)^Slave:\s*rate') {
            $inSlaveSection = $true
            continue
        }
        if ($inSlaveSection -and ($line -match '(?i)^(WD:|Host:|FSD:|FWD:|Calculated versus|Counts reported)')) {
            break
        }
        if (-not $inSlaveSection) {
            continue
        }
        if ($line -match '(?i)^Total\b') {
            continue
        }
        # Example: localhost-0 87601.40 85.55 1024 100.00 0.020 ...
        if ($line -match '^([A-Za-z0-9_.-]+)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)') {
            $slaveName = $Matches[1]
            if ($slaveName -match '^(avg|max|std)_' -or $slaveName -eq "Total") {
                continue
            }
            $iops = [double]$Matches[2]
            $mbps = [double]$Matches[3]
            $readPct = [double]$Matches[5]
            $latency = [double]$Matches[6]
            Set-RunResultSlaveMetrics $Summary $slaveName $iops $mbps $latency $readPct
        }
    }
    return $Summary
}

function Update-RunResultSummaryFromRunDir {
    param(
        $Summary,
        [string]$RunDir
    )
    if ($null -eq $Summary -or [string]::IsNullOrWhiteSpace($RunDir) -or -not (Test-Path -LiteralPath $RunDir)) {
        return $Summary
    }
    $Summary.RunDir = $RunDir
    $skewPath = Join-Path $RunDir "skew.html"
    if (Test-Path -LiteralPath $skewPath) {
        try {
            $skewText = [System.IO.File]::ReadAllText($skewPath)
            [void](Update-RunResultSummaryFromSkewText $Summary $skewText)
        } catch {
        }
    }
    return $Summary
}

function Update-RunResultSummaryFromLine {
    param(
        $Summary,
        [string]$Line
    )
    if ($null -eq $Summary -or [string]::IsNullOrWhiteSpace($Line)) {
        return $Summary
    }

    $ts = Get-LogTimestampFromLine $Line

    if ($Line -match 'Starting slave:\s+ssh\s+(\S+)') {
        $hostName = $Matches[1]
        $slaveLabel = $hostName
        # vdbench: ... -n <id> -l <label> -p <port>
        if ($Line -match '\s-l\s+(\S+)\s+-p\s+\d+') {
            $slaveLabel = $Matches[1]
        }
        Ensure-RunResultSlaveEntry $Summary $slaveLabel
        $Summary.Slaves[$slaveLabel].Host = $hostName
        $Summary.HasData = $true
    }

    if ($Line -match '^\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Za-z0-9_.-]+):\s+(.*)$') {
        $slaveName = $Matches[1]
        $msg = $Matches[2].Trim()
        if ($slaveName -notmatch '^(avg|max|std)_' -and $slaveName -ne "Message") {
            Ensure-RunResultSlaveEntry $Summary $slaveName
            if ($msg -match 'anchor=(\S+)') {
                $Summary.Slaves[$slaveName].Anchor = $Matches[1].TrimEnd('.')
            }
            if ($msg -match 'Created anchor directory:\s+(\S+)') {
                $Summary.Slaves[$slaveName].Anchor = $Matches[1]
            }
            if ($msg.Length -gt 0 -and $Summary.Slaves[$slaveName].Notes.Count -lt 4) {
                [void]$Summary.Slaves[$slaveName].Notes.Add($msg)
            }
            $Summary.HasData = $true
        }
    }

    if ($Line -match 'Starting RD=(\S+)') {
        $rdName = $Matches[1].TrimEnd(';')
        $Summary.CurrentRd = $rdName
        if (Test-IsFormatRunDefinition $rdName) {
            $Summary.CurrentPhase = "format"
            $Summary.FormatRd = $rdName
            if ($null -ne $ts) {
                $Summary.FormatStart = $ts
            }
            # Closing previous workload is unusual here; format usually comes first.
        } else {
            $Summary.CurrentPhase = "workload"
            $Summary.WorkloadRd = $rdName
            if ($null -ne $ts) {
                $Summary.WorkloadStart = $ts
                if ($null -ne $Summary.FormatStart -and $null -eq $Summary.FormatEnd) {
                    $Summary.FormatEnd = $ts
                    $Summary.FormatDuration = Format-DurationSpan (Get-DurationBetweenTimestamps $Summary.FormatStart $Summary.FormatEnd)
                }
            }
        }
        $Summary.HasData = $true
    }

    if ($Line -match 'Anchor size:') {
        $Summary.AnchorCount = [int]$Summary.AnchorCount + 1
        $Summary.HasData = $true
    }

    if ($Line -match 'Vdbench execution completed successfully') {
        $Summary.Success = $true
        $Summary.Status = "Completed"
        $Summary.CompletedMessage = "Vdbench completed successfully"
        $Summary.HasData = $true
        if ($null -ne $ts) {
            if ($Summary.CurrentPhase -eq "workload" -and $null -ne $Summary.WorkloadStart -and $null -eq $Summary.WorkloadEnd) {
                $Summary.WorkloadEnd = $ts
                $Summary.WorkloadDuration = Format-DurationSpan (Get-DurationBetweenTimestamps $Summary.WorkloadStart $Summary.WorkloadEnd)
            } elseif ($Summary.CurrentPhase -eq "format" -and $null -ne $Summary.FormatStart -and $null -eq $Summary.FormatEnd) {
                $Summary.FormatEnd = $ts
                $Summary.FormatDuration = Format-DurationSpan (Get-DurationBetweenTimestamps $Summary.FormatStart $Summary.FormatEnd)
            }
        }
    } elseif ($Line -match 'RuntimeException|java\.lang\.|fatal error|FATAL') {
        $Summary.Success = $false
        $Summary.Status = "Failed"
        $Summary.CompletedMessage = $Line.Trim()
        $Summary.HasData = $true
    }

    $avg = Get-AverageMetricFromLine $Line
    if ($null -ne $avg -and $avg.Kind -eq "avg") {
        $Summary.HasData = $true
        $isFormat = ($Summary.CurrentPhase -eq "format") -or (Test-IsFormatRunDefinition ([string]$Summary.CurrentRd))
        if ($isFormat) {
            $Summary.FormatAvgIops = ("{0:n1}" -f [double]$avg.Iops)
            $Summary.FormatAvgMbps = ("{0:n2}" -f [double]$avg.Mbps)
            $Summary.FormatAvgLatency = ("{0:n3}" -f [double]$avg.Latency)
            # Max must never display below avg for the same phase.
            $formatMax = [Math]::Max([double]$Summary.FormatObservedMaxIops, [double]$avg.Iops)
            if ($formatMax -gt 0) {
                $Summary.FormatObservedMaxIops = $formatMax
                $Summary.FormatMaxIops = ("{0:n1}" -f $formatMax)
            }
            if ($null -ne $ts -and $null -ne $Summary.FormatStart -and $null -eq $Summary.FormatEnd) {
                $Summary.FormatEnd = $ts
                $Summary.FormatDuration = Format-DurationSpan (Get-DurationBetweenTimestamps $Summary.FormatStart $Summary.FormatEnd)
            }
        } else {
            $Summary.WorkloadAvgIops = ("{0:n1}" -f [double]$avg.Iops)
            $Summary.WorkloadAvgMbps = ("{0:n2}" -f [double]$avg.Mbps)
            $Summary.WorkloadAvgLatency = ("{0:n3}" -f [double]$avg.Latency)
            if ($null -ne $avg.ReadPct) {
                $Summary.WorkloadReadPct = ("{0:n1}" -f [double]$avg.ReadPct)
            }
            # Max must never display below avg (missed intervals / warmup gaps).
            $workloadMax = [Math]::Max([double]$Summary.WorkloadObservedMaxIops, [double]$avg.Iops)
            if ($workloadMax -gt 0) {
                $Summary.WorkloadObservedMaxIops = $workloadMax
                $Summary.WorkloadMaxIops = ("{0:n1}" -f $workloadMax)
            }
            if ($null -ne $ts -and $null -ne $Summary.WorkloadStart -and $null -eq $Summary.WorkloadEnd) {
                $Summary.WorkloadEnd = $ts
                $Summary.WorkloadDuration = Format-DurationSpan (Get-DurationBetweenTimestamps $Summary.WorkloadStart $Summary.WorkloadEnd)
            }
        }
        $Summary.LastIops = ("{0:n2}" -f [double]$avg.Iops)
        $Summary.LastMbps = ("{0:n2}" -f [double]$avg.Mbps)
        $Summary.LastLatency = ("{0:n3}" -f [double]$avg.Latency)
        $Summary.LastInterval = [string]$avg.Range
    } elseif ($null -ne $avg -and $avg.Kind -eq "max") {
        # Prefer observed interval max; still accept raw max_* when higher.
        $Summary.HasData = $true
        $isFormat = ($Summary.CurrentPhase -eq "format") -or (Test-IsFormatRunDefinition ([string]$Summary.CurrentRd))
        if ([double]$avg.Iops -gt 0) {
            if ($isFormat) {
                $formatMax = [Math]::Max([double]$Summary.FormatObservedMaxIops, [double]$avg.Iops)
                $Summary.FormatObservedMaxIops = $formatMax
                $Summary.FormatMaxIops = ("{0:n1}" -f $formatMax)
            } else {
                $workloadMax = [Math]::Max([double]$Summary.WorkloadObservedMaxIops, [double]$avg.Iops)
                $Summary.WorkloadObservedMaxIops = $workloadMax
                $Summary.WorkloadMaxIops = ("{0:n1}" -f $workloadMax)
            }
        }
    }

    $point = Get-MetricValuesFromLine $Line
    if ($null -ne $point) {
        $Summary.HasData = $true
        $Summary.LastIops = ("{0:n2}" -f [double]$point.Iops)
        $Summary.LastMbps = ("{0:n2}" -f [double]$point.Mbps)
        $Summary.LastLatency = ("{0:n3}" -f [double]$point.Latency)
        $Summary.LastInterval = [string]([int][double]$point.Interval)
        $isFormat = ($Summary.CurrentPhase -eq "format") -or (Test-IsFormatRunDefinition ([string]$Summary.CurrentRd))
        if ($isFormat) {
            if ([double]$point.Iops -gt [double]$Summary.FormatObservedMaxIops) {
                $Summary.FormatObservedMaxIops = [double]$point.Iops
                $Summary.FormatMaxIops = ("{0:n1}" -f [double]$point.Iops)
            }
        } else {
            if ([double]$point.Iops -gt [double]$Summary.WorkloadObservedMaxIops) {
                $Summary.WorkloadObservedMaxIops = [double]$point.Iops
                $Summary.WorkloadMaxIops = ("{0:n1}" -f [double]$point.Iops)
            }
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

function Format-DashIfEmpty {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "-"
    }
    return $Text
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
    $completed = [string](Get-PropertyValue $Summary "CompletedMessage" "")
    if ([string]::IsNullOrWhiteSpace($completed)) {
        [void]$lines.Add(("Status: {0}" -f $status))
    } else {
        [void]$lines.Add(("Status: {0}  |  {1}" -f $status, $completed))
    }

    $formatTime = [string](Get-PropertyValue $Summary "FormatDuration" "")
    $formatMbps = [string](Get-PropertyValue $Summary "FormatAvgMbps" "")
    $formatIops = [string](Get-PropertyValue $Summary "FormatAvgIops" "")
    $formatMax = [string](Get-PropertyValue $Summary "FormatMaxIops" "")
    $formatLat = [string](Get-PropertyValue $Summary "FormatAvgLatency" "")
    $workloadTime = [string](Get-PropertyValue $Summary "WorkloadDuration" "")
    $workloadIops = [string](Get-PropertyValue $Summary "WorkloadAvgIops" "")
    $workloadMax = [string](Get-PropertyValue $Summary "WorkloadMaxIops" "")
    $workloadMbps = [string](Get-PropertyValue $Summary "WorkloadAvgMbps" "")
    $workloadLat = [string](Get-PropertyValue $Summary "WorkloadAvgLatency" "")
    $readPct = [string](Get-PropertyValue $Summary "WorkloadReadPct" "")
    $anchors = [int](Get-PropertyValue $Summary "AnchorCount" 0)

    [void]$lines.Add("")
    [void]$lines.Add(("WORKLOAD  time={0}  avg={1} IOPS  max={2}  {3} MB/s  lat={4}  read={5}%  anchors={6}" -f `
        (Format-DashIfEmpty $workloadTime), `
        (Format-DashIfEmpty $workloadIops), `
        (Format-DashIfEmpty $workloadMax), `
        (Format-DashIfEmpty $workloadMbps), `
        (Format-DashIfEmpty $workloadLat), `
        (Format-DashIfEmpty $readPct), `
        $anchors))
    [void]$lines.Add(("FORMAT    time={0}  avg={1} MB/s  maxIOPS={2}  avgIOPS={3}  lat={4}" -f `
        (Format-DashIfEmpty $formatTime), `
        (Format-DashIfEmpty $formatMbps), `
        (Format-DashIfEmpty $formatMax), `
        (Format-DashIfEmpty $formatIops), `
        (Format-DashIfEmpty $formatLat)))

    $slaveMap = Get-PropertyValue $Summary "Slaves" @{}
    $slaveNames = @()
    if ($null -ne $slaveMap -and @($slaveMap.Keys).Count -gt 0) {
        $slaveNames = @($slaveMap.Keys | Sort-Object)
    }

    [void]$lines.Add("")
    [void]$lines.Add(("{0,-14} {1,-15} {2,-14} {3,9} {4,9} {5,7} {6,7} {7,6}" -f `
        "Host", "IP", "Anchor", "Avg IOPS", "Max IOPS", "MB/s", "Lat ms", "Read%"))
    [void]$lines.Add(("{0,-14} {1,-15} {2,-14} {3,9} {4,9} {5,7} {6,7} {7,6}" -f `
        "----", "--", "------", "--------", "--------", "-----", "------", "-----"))

    if ($slaveNames.Count -eq 0) {
        [void]$lines.Add("(no hosts yet)")
    } else {
        foreach ($name in $slaveNames) {
            $slave = $slaveMap[$name]
            $hostIp = [string](Get-PropertyValue $slave "Host" "")
            $anchor = [string](Get-PropertyValue $slave "Anchor" "")
            [void]$lines.Add(("{0,-14} {1,-15} {2,-14} {3,9} {4,9} {5,7} {6,7} {7,6}" -f `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "Name" $name))), `
                (Format-DashIfEmpty $hostIp), `
                (Format-DashIfEmpty $anchor), `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "AvgIops" ""))), `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "MaxIops" ""))), `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "AvgMbps" ""))), `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "AvgLatency" ""))), `
                (Format-DashIfEmpty ([string](Get-PropertyValue $slave "ReadPct" "")))))
        }
    }

    if (-not [bool](Get-PropertyValue $Summary "HasData" $false)) {
        [void]$lines.Add("Start a run to fill results.")
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
        WorkloadMaxIops = [string](Get-PropertyValue $result "WorkloadMaxIops" "")
        FormatAvgMbps = [string](Get-PropertyValue $result "FormatAvgMbps" "")
        FormatDuration = [string](Get-PropertyValue $result "FormatDuration" "")
        WorkloadDuration = [string](Get-PropertyValue $result "WorkloadDuration" "")
    }
}
