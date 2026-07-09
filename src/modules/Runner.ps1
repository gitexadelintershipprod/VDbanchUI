function Queue-RunLog {
    param([string]$Message)
    $script:LogQueue.Enqueue($Message)
}

function Flush-RunLog {
    Invoke-PendingProcessExitNotifications
    if ($script:RunFileWriteQueue.Count -gt 0) {
        $fileItem = $null
        $fileWrites = 0
        while ($fileWrites -lt 250 -and $script:RunFileWriteQueue.TryDequeue([ref]$fileItem)) {
            try {
                $path = ""
                $line = ""
                if ($null -ne $fileItem.Path) {
                    $path = [string]$fileItem.Path
                    $line = [string]$fileItem.Line
                }
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine)
                }
            } catch {
                Write-AppLog ("Run log file append failed: {0}" -f $_.Exception.Message) "ERROR"
            }
            $fileWrites++
        }
    }
    if (-not $script:RunLogBox) {
        return
    }
    $msg = $null
    $count = 0
    while ($script:LogQueue.TryDequeue([ref]$msg)) {
        $script:RunLogBox.AppendText($msg + [Environment]::NewLine)
        Add-MetricPointFromLine $msg
        $count++
        if ($count -gt 250) {
            break
        }
    }
}

function Reset-RunChart {
    $script:RunMetricIndex = 0
    if ($script:RunChart) {
        foreach ($series in $script:RunChart.Series) {
            $series.Points.Clear()
        }
    }
}

function Add-MetricPointFromLine {
    param([string]$Line)
    if (-not $script:RunChart) {
        return
    }
    $metrics = Get-MetricValuesFromLine $Line
    if ($null -eq $metrics) {
        return
    }
    try {
        $x = [double]$metrics.Interval
        if ($x -le 0) {
            $script:RunMetricIndex++
            $x = $script:RunMetricIndex
        }
        [void]$script:RunChart.Series["IOPS"].Points.AddXY($x, [double]$metrics.Iops)
        [void]$script:RunChart.Series["MB/s"].Points.AddXY($x, [double]$metrics.Mbps)
        [void]$script:RunChart.Series["Latency"].Points.AddXY($x, [double]$metrics.Latency)
        foreach ($series in $script:RunChart.Series) {
            while ($series.Points.Count -gt 300) {
                $series.Points.RemoveAt(0)
            }
        }
    } catch {
        Write-AppLog ("Chart point update failed: {0}" -f $_.Exception.Message) "WARN"
        return
    }
}

function New-RunChart {
    if (-not $script:ChartAvailable) {
        return $null
    }
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock = [System.Windows.Forms.DockStyle]::Fill
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.Name = "RunMetrics"
    $area.AxisX.Title = "Interval"
    $area.AxisY.Title = "IOPS / MB per sec"
    $area.AxisY2.Title = "Latency"
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    [void]$chart.ChartAreas.Add($area)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    [void]$chart.Legends.Add($legend)

    foreach ($item in @(
        @{ Name = "IOPS"; Axis = "Y"; Color = [System.Drawing.Color]::SteelBlue },
        @{ Name = "MB/s"; Axis = "Y"; Color = [System.Drawing.Color]::SeaGreen },
        @{ Name = "Latency"; Axis = "Y2"; Color = [System.Drawing.Color]::Firebrick }
    )) {
        $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $series.Name = $item.Name
        $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $series.BorderWidth = 2
        $series.Color = $item.Color
        if ($item.Axis -eq "Y2") {
            $series.YAxisType = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
        }
        [void]$chart.Series.Add($series)
    }
    return $chart
}

function Set-RunMetadata {
    param(
        [string]$RunId,
        [hashtable]$Updates
    )
    $path = Join-Path $script:RunStateRoot ($RunId + ".json")
    $state = Read-JsonFile $path ([pscustomobject]@{ Id = $RunId })
    foreach ($key in $Updates.Keys) {
        Set-PropertyValue $state $key $Updates[$key]
    }
    Write-JsonFile $path $state
}

function Repair-OrphanedRunStates {
    $currentRunId = ""
    if (Get-Variable -Name CurrentRunId -Scope Script -ErrorAction SilentlyContinue) {
        $currentRunId = [string]$script:CurrentRunId
    }
    $currentProcess = $null
    if (Get-Variable -Name CurrentProcess -Scope Script -ErrorAction SilentlyContinue) {
        $currentProcess = $script:CurrentProcess
    }
    $hasActive = ($null -ne $currentProcess -and -not $currentProcess.HasExited)
    foreach ($file in @(Get-ChildItem -Path $script:RunStateRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $state = Read-JsonFile $file.FullName $null
        if ($null -eq $state) {
            continue
        }
        $status = [string](Get-PropertyValue $state "Status" "")
        if ($status -ne "Running") {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $state "CompletedAt" ""))) {
            continue
        }
        $runId = [string](Get-PropertyValue $state "Id" "")
        if ($hasActive -and $runId -eq $currentRunId) {
            continue
        }
        $runDir = [string](Get-PropertyValue $state "RunDir" "")
        $stdoutPath = [string](Get-PropertyValue $state "StdoutPath" "")
        if ([string]::IsNullOrWhiteSpace($stdoutPath) -and -not [string]::IsNullOrWhiteSpace($runDir)) {
            $stdoutPath = Join-Path $runDir "stdout.log"
        }
        $summaryPath = ""
        if (-not [string]::IsNullOrWhiteSpace($runDir)) {
            $summaryPath = Join-Path $runDir "summary.html"
        }
        $stdoutText = ""
        if (-not [string]::IsNullOrWhiteSpace($stdoutPath) -and (Test-Path -LiteralPath $stdoutPath)) {
            try {
                $stdoutText = [System.IO.File]::ReadAllText($stdoutPath)
            } catch {
                $stdoutText = ""
            }
        }
        $newStatus = "Abandoned"
        $exitCode = ""
        if ((Test-Path -LiteralPath $summaryPath) -or -not [string]::IsNullOrWhiteSpace($stdoutText)) {
            if ($stdoutText -match 'RuntimeException|java\.lang\.|fatal error|FATAL') {
                $newStatus = "Failed"
                $exitCode = "1"
            } else {
                $newStatus = "Completed"
                $exitCode = "0"
            }
        }
        $updates = @{
            CompletedAt = (Get-Date).ToString("o")
            Status = $newStatus
            ExitCode = $exitCode
        }
        $summary = Get-RunSummaryFromFile $stdoutPath
        foreach ($key in $summary.Keys) {
            $updates[$key] = $summary[$key]
        }
        Set-RunMetadata $runId $updates
        Write-DebugLog ("Repaired orphaned run {0} -> {1}" -f $runId, $newStatus)
    }
}

function Invoke-RunFinishedUiRefresh {
    param(
        [string]$RunId,
        [string]$Status
    )
    Invoke-OnUiThread -HandlerName "Notify-RunFinished" -HandlerArguments @{
        RunId = $RunId
        Status = $Status
    }
}

function Invoke-PendingProcessExitNotifications {
    if ($null -eq $script:ProcessExitQueue) {
        return
    }
    $item = $null
    while ($script:ProcessExitQueue.TryDequeue([ref]$item)) {
        if ($null -eq $item) {
            continue
        }
        try {
            Complete-VdbenchProcessExited `
                -ExitCode ([int]$item.ExitCode) `
                -RunId ([string]$item.RunId) `
                -StdoutPath ([string]$item.StdoutPath)
        } catch {
            Write-AppLog ("Process exit notification failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    }
}

function Complete-VdbenchProcessExited {
    param(
        [int]$ExitCode,
        [string]$RunId,
        [string]$StdoutPath
    )
    $status = "Failed"
    if ($script:KillRequested) {
        $status = "Killed"
    } elseif ($ExitCode -eq 0) {
        $status = "Completed"
    }
    $script:LogQueue.Enqueue(("Run exited with code {0}" -f $ExitCode))
    $updates = @{
        CompletedAt = (Get-Date).ToString("o")
        Status = $status
        ExitCode = [string]$ExitCode
    }
    $summary = Get-RunSummaryFromFile $StdoutPath
    foreach ($key in $summary.Keys) {
        $updates[$key] = $summary[$key]
    }
    Set-RunMetadata $RunId $updates
    Write-AppLog ("Run {0} finished with status {1} (exit {2})" -f $RunId, $status, $ExitCode)
    Notify-RunFinished -RunId $RunId -Status $status
}

function Get-RunOutputRoot {
    $reportsRoot = [string](Get-PropertyValue $script:Settings "ReportsRoot" "")
    if (-not [string]::IsNullOrWhiteSpace($reportsRoot)) {
        return $reportsRoot
    }
    return (Join-Path $script:AppRoot "runs")
}

function Get-NewRunContext {
    param([object]$BuiltConfig)
    $runId = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $runRoot = Get-RunOutputRoot
    $runDir = Join-Path $runRoot $runId
    try {
        Ensure-Directory $runDir
    } catch {
        $runRoot = Join-Path $script:AppRoot "runs"
        Ensure-Directory $runRoot
        $runDir = Join-Path $runRoot $runId
        Ensure-Directory $runDir
    }

    $parmPath = Join-Path $runDir "profile.parm"
    $stdoutPath = Join-Path $runDir "stdout.log"
    $stderrPath = Join-Path $runDir "stderr.log"
    [System.IO.File]::WriteAllText($parmPath, $BuiltConfig.Text, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($stdoutPath, "")
    [System.IO.File]::WriteAllText($stderrPath, "")

    return [pscustomobject]@{
        RunId = $runId
        RunRoot = $runRoot
        RunDir = $runDir
        ParmPath = $parmPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function New-RunMetadataMap {
    param(
        [object]$Context,
        [object]$BuiltConfig,
        [string]$Status,
        [string]$Command
    )
    return @{
        Id = [string]$Context.RunId
        StartedAt = (Get-Date).ToString("o")
        CompletedAt = ""
        Status = $Status
        ExitCode = ""
        Profile = Get-RunProfileName
        Mode = (Get-Mode)
        TestKind = [string](Resolve-RunTestKind).TestKind
        RunDir = [string]$Context.RunDir
        ParmPath = [string]$Context.ParmPath
        StdoutPath = [string]$Context.StdoutPath
        StderrPath = [string]$Context.StderrPath
        Command = $Command
        Warnings = @($BuiltConfig.Warnings)
    }
}

function New-ConfigOnlyRun {
    Capture-Settings
    Capture-SlaveGrid
    Capture-ProfileEditor
    $built = Build-VdbenchConfig
    $context = Get-NewRunContext $built
    Set-RunMetadata $context.RunId (New-RunMetadataMap $context $built "Config generated" "No process started")
    $script:CurrentRunId = [string]$context.RunId
    if ($script:RunLogBox) {
        $script:RunLogBox.Clear()
        Queue-RunLog ("Generated config-only run {0}" -f $context.RunId)
        Queue-RunLog ("Config: {0}" -f $context.ParmPath)
        Queue-RunLog ("Output folder: {0}" -f $context.RunDir)
    }
    if ($script:RunStatusLabel) {
        $script:RunStatusLabel.Text = "Config generated: " + $context.RunId
    }
    Refresh-Reports
}

function New-RemoteSshArguments {
    param([object]$Slave)
    $parts = New-Object System.Collections.Generic.List[string]
    $privateKey = [string](Get-PropertyValue $Slave "PrivateKey" "")
    Add-CommonSshOptions -SshParts $parts -User ([string](Get-PropertyValue $Slave "User" "")) -PrivateKey $privateKey
    $systemName = [string](Get-PropertyValue $Slave "SshAlias" "")
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        $systemName = [string](Get-PropertyValue $Slave "Host" "")
    }
    [void]$parts.Add((Quote-ProcessArgument $systemName))
    return ,$parts
}

function New-TestFileTarget {
    param(
        [object]$Owner,
        [object]$Target
    )
    return [pscustomobject]@{
        Owner = $Owner
        Target = [string](Get-PropertyValue $Target "Target" "")
        OsType = [string](Get-PropertyValue $Owner "OsType" "Windows")
        Host = [string](Get-PropertyValue $Owner "Host" "localhost")
    }
}

function Get-TestFilesToCreate {
    $items = @()
    if (Is-DistributedMode) {
        foreach ($slave in @(Get-EnabledSlaves)) {
            foreach ($target in @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "raw")) {
                if ([string](Get-PropertyValue $target "Kind" "") -eq "Test file" -and [bool](Get-PropertyValue $target "CreateFile" $false)) {
                    $items += New-TestFileTarget $slave $target
                }
            }
        }
    } else {
        $owner = [pscustomobject]@{ Host = "localhost"; OsType = "Windows" }
        foreach ($target in @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "raw")) {
            if ([string](Get-PropertyValue $target "Kind" "") -eq "Test file" -and [bool](Get-PropertyValue $target "CreateFile" $false)) {
                $items += New-TestFileTarget $owner $target
            }
        }
    }
    return @($items)
}

function Initialize-TestFilesForRun {
    foreach ($item in @(Get-TestFilesToCreate)) {
        $path = [string]$item.Target
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if (Test-HostLooksLocal ([string]$item.Host)) {
            $parent = Split-Path -Parent $path
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                Ensure-Directory $parent
            }
            [System.IO.File]::WriteAllText($path, "", [System.Text.Encoding]::ASCII)
            continue
        }
        $sshParts = New-RemoteSshArguments $item.Owner
        $osType = [string]$item.OsType
        if ($osType -eq "Linux") {
            $quotedPath = Convert-ToShellSingleQuoted $path
            $remote = "mkdir -p -- `"`$(dirname -- $quotedPath)`" && : > $quotedPath"
        } else {
            $escapedPath = $path.Replace("'", "''")
            $remote = "`$p='$escapedPath'; `$d=Split-Path -Parent `$p; if (`$d) { New-Item -ItemType Directory -Force -Path `$d | Out-Null }; Set-Content -LiteralPath `$p -Value '' -NoNewline"
        }
        foreach ($token in @(Get-RemoteExecCommandParts -OsType $osType -RemoteScript $remote)) {
            [void]$sshParts.Add($token)
        }
        $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 20000
        if ($result.ExitCode -ne 0) {
            throw ("Failed to create test file on {0}: {1}" -f $item.Host, (($result.StdErr + " " + $result.StdOut).Trim()))
        }
    }
}

function Start-VdbenchRun {
    try {
        Start-VdbenchRunCore
    } catch {
        Write-AppLog ("Start-VdbenchRun failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        Show-Warning ("Run start failed: " + $_.Exception.Message)
        if ($script:RunStatusLabel) {
            $script:RunStatusLabel.Text = "Start failed"
        }
    }
}

function Start-VdbenchRunCore {
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        Show-Warning "A run is already active."
        return
    }
    Capture-Settings
    Capture-SlaveGrid
    Capture-ProfileEditor
    $built = Build-VdbenchConfig
    $blockers = @($built.Warnings | Where-Object { [string]$_ -like "BLOCKER:*" })
    if ($blockers.Count -gt 0) {
        Refresh-ConfigPreview
        Select-MainTab "Config Preview"
        Show-Warning ("Run cannot start until these issues are fixed:" + [Environment]::NewLine + [Environment]::NewLine + ($blockers -join [Environment]::NewLine))
        return
    }

    $masterBat = [string](Get-PropertyValue $script:Settings "MasterVdbenchBat" "")
    if ([string]::IsNullOrWhiteSpace($masterBat) -or -not (Test-Path -LiteralPath $masterBat)) {
        Show-Warning "Master Vdbench batch file does not exist: $masterBat"
        return
    }
    try {
        $previousCursor = [System.Windows.Forms.Cursor]::Current
        try {
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            Initialize-TestFilesForRun
        } finally {
            [System.Windows.Forms.Cursor]::Current = $previousCursor
        }
    } catch {
        Show-Warning ("Test file preparation failed: " + $_.Exception.Message)
        return
    }

    $context = Get-NewRunContext $built
    $runId = [string]$context.RunId
    $runDir = [string]$context.RunDir
    $parmPath = [string]$context.ParmPath
    $stdoutPath = [string]$context.StdoutPath
    $stderrPath = [string]$context.StderrPath
    $script:CurrentRunId = $runId
    $script:KillRequested = $false
    $script:RunFinishedNotified = $false
    $commandText = ("`"{0}`" -f `"{1}`" -o `"{2}`"" -f $masterBat, $parmPath, $runDir)

    $script:RunLogBox.Clear()
    Reset-RunChart
    Queue-RunLog ("Preparing run {0}" -f $runId)
    Queue-RunLog ("Command: {0}" -f $commandText)
    Queue-RunLog ("Output: {0}" -f $runDir)
    $script:RunStatusLabel.Text = "Starting: " + $runId
    if (Get-Command Select-MainTab -ErrorAction SilentlyContinue) {
        Select-MainTab "Run Monitor"
    }
    Flush-RunLog

    $psi = Get-VdbenchProcessStartInfo $masterBat $parmPath $runDir ([string](Get-PropertyValue $script:Settings "VdbenchRoot" $script:AppRoot))

    $capturedRunId = $runId
    $capturedStdoutPath = $stdoutPath
    $capturedStderrPath = $stderrPath
    $script:ActiveStdoutPath = $stdoutPath
    $script:ActiveStderrPath = $stderrPath

    Initialize-ProcessEventBridge
    [VdbenchUi.ProcessEventBridge]::SetRunContext($capturedRunId, $capturedStdoutPath, $capturedStderrPath)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    try {
        Register-ProcessEventBridgeHandlers -Process $process
        [void]$process.Start()
        $script:CurrentProcess = $process
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        Set-RunMetadata $runId (New-RunMetadataMap $context $built "Running" $commandText)
        $script:RunStatusLabel.Text = "Running: " + $runId
        Queue-RunLog ("Run process started (pid {0})" -f $process.Id)
        Flush-RunLog
    } catch {
        Set-RunMetadata $runId @{
            CompletedAt = (Get-Date).ToString("o")
            Status = "Start failed"
            ExitCode = ""
        }
        $script:CurrentRunId = ""
        $script:CurrentProcess = $null
        Queue-RunLog ("Start failed: " + $_.Exception.Message)
        $script:RunStatusLabel.Text = "Start failed"
        Flush-RunLog
        Refresh-Reports
        throw
    }
}

function Stop-VdbenchRun {
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        if (Ask-YesNo "Kill the active Vdbench process and its child processes?" "Stop run") {
            try {
                $script:KillRequested = $true
                $runId = [string]$script:CurrentRunId
                Stop-ProcessTree -Process $script:CurrentProcess
                Queue-RunLog "Kill requested (process tree)."
                Set-RunMetadata $runId @{
                    CompletedAt = (Get-Date).ToString("o")
                    Status = "Killed"
                }
                Invoke-RunFinishedUiRefresh -RunId $runId -Status "Killed"
                Write-AppLog ("Run {0} killed by user" -f $runId)
            } catch {
                Show-Warning $_.Exception.Message
                Write-AppLog ("Kill failed: {0}" -f $_.Exception.Message) "ERROR"
            }
        }
    } else {
        Show-Info "No active run."
    }
}
