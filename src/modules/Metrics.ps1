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
            Notes = New-Object System.Collections.Generic.List[string]
        }
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
            if ([double]$Summary.FormatObservedMaxIops -gt 0) {
                $Summary.FormatMaxIops = ("{0:n1}" -f [double]$Summary.FormatObservedMaxIops)
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
            if ([double]$Summary.WorkloadObservedMaxIops -gt 0) {
                $Summary.WorkloadMaxIops = ("{0:n1}" -f [double]$Summary.WorkloadObservedMaxIops)
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
        # Filesystem max_* rows are often sparse/misaligned. Prefer observed max
        # from interval samples within the SAME phase only.
        $Summary.HasData = $true
        $isFormat = ($Summary.CurrentPhase -eq "format") -or (Test-IsFormatRunDefinition ([string]$Summary.CurrentRd))
        if (-not $isFormat -and [string]$avg.MetricKind -eq "raw" -and [double]$avg.Iops -gt 0) {
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

function Format-SummaryTableRow {
    param(
        [string]$Col1,
        [string]$Col2,
        [string]$Col3,
        [string]$Col4,
        [string]$Col5,
        [string]$Col6,
        [string]$Col7
    )
    return ("{0,-10} {1,8} {2,10} {3,10} {4,10} {5,8} {6,8}" -f $Col1, $Col2, $Col3, $Col4, $Col5, $Col6, $Col7)
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

    [void]$lines.Add("")
    [void]$lines.Add("FORMAT")
    [void]$lines.Add((Format-SummaryTableRow "Phase" "Time" "Avg IOPS" "Max IOPS" "Avg MB/s" "Lat ms" "Read%"))
    [void]$lines.Add((Format-SummaryTableRow "-----" "----" "--------" "--------" "--------" "------" "-----"))
    $formatTime = [string](Get-PropertyValue $Summary "FormatDuration" "")
    $formatMbps = [string](Get-PropertyValue $Summary "FormatAvgMbps" "")
    if (-not [string]::IsNullOrWhiteSpace($formatMbps) -or -not [string]::IsNullOrWhiteSpace($formatTime)) {
        [void]$lines.Add((Format-SummaryTableRow `
            "format" `
            $(if ([string]::IsNullOrWhiteSpace($formatTime)) { "-" } else { $formatTime }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.FormatAvgIops)) { "-" } else { [string]$Summary.FormatAvgIops }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.FormatMaxIops)) { "-" } else { [string]$Summary.FormatMaxIops }) `
            $(if ([string]::IsNullOrWhiteSpace($formatMbps)) { "-" } else { $formatMbps }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.FormatAvgLatency)) { "-" } else { [string]$Summary.FormatAvgLatency }) `
            "-"))
    } else {
        [void]$lines.Add((Format-SummaryTableRow "format" "-" "-" "-" "-" "-" "-"))
    }

    [void]$lines.Add("")
    [void]$lines.Add("WORKLOAD")
    [void]$lines.Add((Format-SummaryTableRow "Phase" "Time" "Avg IOPS" "Max IOPS" "Avg MB/s" "Lat ms" "Read%"))
    [void]$lines.Add((Format-SummaryTableRow "-----" "----" "--------" "--------" "--------" "------" "-----"))
    $workloadTime = [string](Get-PropertyValue $Summary "WorkloadDuration" "")
    $workloadIops = [string](Get-PropertyValue $Summary "WorkloadAvgIops" "")
    if (-not [string]::IsNullOrWhiteSpace($workloadIops) -or -not [string]::IsNullOrWhiteSpace($workloadTime)) {
        $readPct = [string](Get-PropertyValue $Summary "WorkloadReadPct" "")
        [void]$lines.Add((Format-SummaryTableRow `
            "workload" `
            $(if ([string]::IsNullOrWhiteSpace($workloadTime)) { "-" } else { $workloadTime }) `
            $(if ([string]::IsNullOrWhiteSpace($workloadIops)) { "-" } else { $workloadIops }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadMaxIops)) { "-" } else { [string]$Summary.WorkloadMaxIops }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadAvgMbps)) { "-" } else { [string]$Summary.WorkloadAvgMbps }) `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadAvgLatency)) { "-" } else { [string]$Summary.WorkloadAvgLatency }) `
            $(if ([string]::IsNullOrWhiteSpace($readPct)) { "-" } else { $readPct })))
    } else {
        [void]$lines.Add((Format-SummaryTableRow "workload" "-" "-" "-" "-" "-" "-"))
    }

    [void]$lines.Add("")
    [void]$lines.Add("SLAVES")
    $slaveMap = Get-PropertyValue $Summary "Slaves" @{}
    if ($null -eq $slaveMap -or @($slaveMap.Keys).Count -eq 0) {
        [void]$lines.Add("  (none detected yet)")
    } else {
        [void]$lines.Add(("{0,-14} {1,-16} {2}" -f "Name", "Host", "Anchor"))
        [void]$lines.Add(("{0,-14} {1,-16} {2}" -f "----", "----", "------"))
        foreach ($name in @($slaveMap.Keys | Sort-Object)) {
            $slave = $slaveMap[$name]
            [void]$lines.Add(("{0,-14} {1,-16} {2}" -f `
                [string](Get-PropertyValue $slave "Name" $name), `
                $(if ([string]::IsNullOrWhiteSpace([string]$slave.Host)) { "-" } else { [string]$slave.Host }), `
                $(if ([string]::IsNullOrWhiteSpace([string]$slave.Anchor)) { "-" } else { [string]$slave.Anchor })))
        }
    }

    [void]$lines.Add("")
    [void]$lines.Add("SUMMARY")
    $anchors = [int](Get-PropertyValue $Summary "AnchorCount" 0)
    [void]$lines.Add(("  Anchors: {0}" -f $anchors))
    if (-not [string]::IsNullOrWhiteSpace($formatTime) -or -not [string]::IsNullOrWhiteSpace($formatMbps)) {
        [void]$lines.Add(("  Format:   time={0}  avg={1} MB/s  maxIOPS={2}" -f `
            $(if ([string]::IsNullOrWhiteSpace($formatTime)) { "-" } else { $formatTime }), `
            $(if ([string]::IsNullOrWhiteSpace($formatMbps)) { "-" } else { $formatMbps }), `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.FormatMaxIops)) { "-" } else { [string]$Summary.FormatMaxIops })))
    }
    if (-not [string]::IsNullOrWhiteSpace($workloadIops) -or -not [string]::IsNullOrWhiteSpace($workloadTime)) {
        [void]$lines.Add(("  Workload: time={0}  avg={1} IOPS  max={2} IOPS  {3} MB/s" -f `
            $(if ([string]::IsNullOrWhiteSpace($workloadTime)) { "-" } else { $workloadTime }), `
            $(if ([string]::IsNullOrWhiteSpace($workloadIops)) { "-" } else { $workloadIops }), `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadMaxIops)) { "-" } else { [string]$Summary.WorkloadMaxIops }), `
            $(if ([string]::IsNullOrWhiteSpace([string]$Summary.WorkloadAvgMbps)) { "-" } else { [string]$Summary.WorkloadAvgMbps })))
    }
    if (-not [bool](Get-PropertyValue $Summary "HasData" $false)) {
        [void]$lines.Add("  Start a run to fill format / workload / slave tables.")
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
