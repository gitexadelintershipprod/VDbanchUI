$script:SlaveReadinessTimers = @{}
$script:SlaveReadinessTimerRows = @{}
$script:SlaveGridRefreshing = $false

function Get-SlaveRowState {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row) {
        return @{ Targets = @(); ReadinessOutput = "" }
    }
    if ($null -eq $Row.Tag -or $Row.Tag -isnot [hashtable]) {
        $targets = @()
        if ($null -ne $Row.Tag) {
            $targets = @(Normalize-TargetEntries @($Row.Tag))
        }
        $Row.Tag = @{
            Targets = $targets
            ReadinessOutput = ""
            ReadinessCheckedAt = ""
            PingCheckedAt = ""
        }
    }
    return $Row.Tag
}

function Get-SlaveRowTargets {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row) {
        return @()
    }
    return @(Normalize-TargetEntries @(Get-SlaveRowState $Row).Targets)
}

function Set-SlaveRowTargets {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [object[]]$Targets
    )
    $state = Get-SlaveRowState $Row
    $normalized = @(Normalize-TargetEntries $Targets)
    $state.Targets = $normalized
    $Row.Cells["Targets"].Value = Get-TargetSummary $normalized
}

function Format-SlaveCheckedAt {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    try {
        return ([datetime]::Parse($Value)).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return $Value
    }
}

function Test-SlaveRowReady {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return $false
    }
    return ([string]$Row.Cells["Readiness"].Value) -eq "Ready"
}

function Sync-SlaveRowEnabledState {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    if (-not (Test-SlaveRowReady $Row)) {
        $Row.Cells["Enabled"].Value = $false
    }
}

function Update-SlaveRowReadiness {
    param(
        [int]$RowIndex,
        [string]$Status,
        [string]$CheckedAt = "",
        [string]$Output = ""
    )
    if ($null -eq $script:SlaveGrid -or $RowIndex -lt 0 -or $RowIndex -ge $script:SlaveGrid.Rows.Count) {
        return
    }
    $row = $script:SlaveGrid.Rows[$RowIndex]
    if ($row.IsNewRow) {
        return
    }
    $row.Cells["Readiness"].Value = $Status
    if (-not [string]::IsNullOrWhiteSpace($CheckedAt)) {
        $row.Cells["CheckedAt"].Value = (Format-SlaveCheckedAt $CheckedAt)
        $state = Get-SlaveRowState $row
        $state.ReadinessCheckedAt = $CheckedAt
    } elseif ($Status -eq "Checking...") {
        $row.Cells["CheckedAt"].Value = ""
    }
    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $state = Get-SlaveRowState $row
        $state.ReadinessOutput = $Output
    }
    Sync-SlaveRowEnabledState $row
    $script:SlaveGrid.InvalidateRow($RowIndex)
}

function Update-SlaveRowPing {
    param(
        [int]$RowIndex,
        [string]$Status,
        [string]$CheckedAt = ""
    )
    if ($null -eq $script:SlaveGrid -or $RowIndex -lt 0 -or $RowIndex -ge $script:SlaveGrid.Rows.Count) {
        return
    }
    $row = $script:SlaveGrid.Rows[$RowIndex]
    if ($row.IsNewRow) {
        return
    }
    $row.Cells["PingStatus"].Value = $Status
    if (-not [string]::IsNullOrWhiteSpace($CheckedAt)) {
        $row.Cells["PingAt"].Value = (Format-SlaveCheckedAt $CheckedAt)
        $state = Get-SlaveRowState $row
        $state.PingCheckedAt = $CheckedAt
    } elseif ($Status -eq "Pinging...") {
        $row.Cells["PingAt"].Value = ""
    }
}

function Get-SlavePingStatus {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return "Missing host"
    }
    try {
        $result = Test-Connection -ComputerName $HostName -Count 1 -Quiet -ErrorAction Stop
        if ($result) {
            return "Ping OK"
        }
        return "Ping failed"
    } catch {
        return "Ping error: " + $_.Exception.Message
    }
}

function Get-SlaveReadinessResult {
    param(
        [string]$HostName,
        [string]$VdbenchPath,
        [string]$Target,
        [string]$Checker,
        [string]$CheckerTemplate
    )
    if ([string]::IsNullOrWhiteSpace($Checker) -or -not (Test-Path -LiteralPath $Checker)) {
        return [pscustomobject]@{
            Status = "Checker missing"
            Output = ""
        }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $checkerArgs = Expand-ReadinessCheckerArguments $CheckerTemplate $HostName $VdbenchPath $Target
    $quotedChecker = Quote-ProcessArgument $Checker
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedChecker $checkerArgs"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $status = if ($p.ExitCode -eq 0) { "Ready" } else { "Failed" }
        return [pscustomobject]@{
            Status = $status
            Output = ($out + [Environment]::NewLine + $err).Trim()
        }
    } catch {
        return [pscustomobject]@{
            Status = "Error"
            Output = $_.Exception.Message
        }
    }
}

function Get-SlaveReadinessTargetForRow {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    $targets = @(Get-SelectedTargetEntries (Get-SlaveRowTargets $Row))
    if ($targets.Count -gt 0) {
        return [string]$targets[0].Target
    }
    return Get-DefaultTestTargetForOs ([string]$Row.Cells["OsType"].Value)
}

function Start-SlavePingCheck {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $pingContext = @{
        RowIndex = $Row.Index
        HostName = [string]$Row.Cells["Host"].Value
    }
    Update-SlaveRowPing $pingContext.RowIndex "Pinging..."
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $pingContext -Work {
        param($Context)
        Get-SlavePingStatus $Context.HostName
    } -OnComplete {
        param($Result, $ErrorMessage, $Context)
        $status = if ($null -ne $ErrorMessage) { "Ping error: " + $ErrorMessage } else { [string]$Result }
        $checkedAt = (Get-Date).ToString("o")
        Update-SlaveRowPing $Context.RowIndex $status $checkedAt
    }
}

function Start-SlaveReadinessCheck {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [bool]$ShowOutput = $false
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    Capture-Settings
    $readyContext = @{
        RowIndex = $Row.Index
        ShowOutput = $ShowOutput
        HostName = [string]$Row.Cells["Host"].Value
        VdbenchPath = [string]$Row.Cells["VdbenchPath"].Value
        Target = Get-SlaveReadinessTargetForRow $Row
        Checker = [string](Get-PropertyValue $script:Settings "ReadinessChecker" "")
        CheckerTemplate = [string](Get-PropertyValue $script:Settings "ReadinessCheckerArguments" "-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}")
    }
    Update-SlaveRowReadiness $readyContext.RowIndex "Checking..."
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $readyContext -Work {
        param($Context)
        Get-SlaveReadinessResult $Context.HostName $Context.VdbenchPath $Context.Target $Context.Checker $Context.CheckerTemplate
    } -OnComplete {
        param($Result, $ErrorMessage, $Context)
        $checkedAt = (Get-Date).ToString("o")
        if ($null -ne $ErrorMessage) {
            Update-SlaveRowReadiness $Context.RowIndex "Error" $checkedAt $ErrorMessage
            if ($Context.ShowOutput) {
                Show-Warning $ErrorMessage
            }
            return
        }
        Update-SlaveRowReadiness $Context.RowIndex ([string]$Result.Status) $checkedAt ([string]$Result.Output)
        if ($Context.ShowOutput) {
            if ([string]$Result.Status -eq "Checker missing") {
                Show-Warning "Readiness checker path is missing or does not exist."
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$Result.Output)) {
                Show-Info ([string]$Result.Output) "Readiness output"
            }
        }
        Refresh-ConfigPreview
    }
}

function Schedule-SlaveReadinessCheck {
    param([int]$RowIndex)
    if ($null -eq $script:SlaveGrid) {
        return
    }
    $key = [string]$RowIndex
    if ($script:SlaveReadinessTimers.ContainsKey($key)) {
        $oldTimer = $script:SlaveReadinessTimers[$key]
        [void]$script:SlaveReadinessTimerRows.Remove([string]$oldTimer.GetHashCode())
        $oldTimer.Stop()
        $oldTimer.Dispose()
        [void]$script:SlaveReadinessTimers.Remove($key)
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $script:SlaveReadinessTimerRows[[string]$timer.GetHashCode()] = $RowIndex
    $timer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        $timerKey = [string]$sender.GetHashCode()
        if (-not $script:SlaveReadinessTimerRows.ContainsKey($timerKey)) {
            $sender.Dispose()
            return
        }
        $rowIndex = [int]$script:SlaveReadinessTimerRows[$timerKey]
        [void]$script:SlaveReadinessTimerRows.Remove($timerKey)
        [void]$script:SlaveReadinessTimers.Remove([string]$rowIndex)
        $sender.Dispose()
        if ($null -eq $script:SlaveGrid -or $rowIndex -lt 0 -or $rowIndex -ge $script:SlaveGrid.Rows.Count) {
            return
        }
        $row = $script:SlaveGrid.Rows[$rowIndex]
        if (-not $row.IsNewRow) {
            Start-SlaveReadinessCheck -Row $row
        }
    })
    $script:SlaveReadinessTimers[$key] = $timer
    $timer.Start()
}

function Apply-SlaveGridRowDefaults {
    param(
        $Row,
        [switch]$RefreshSshAlias
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $osType = [string]$Row.Cells["OsType"].Value
    if ([string]::IsNullOrWhiteSpace($osType)) {
        $osType = "Windows"
        $Row.Cells["OsType"].Value = $osType
    }
    $Row.Cells["User"].Value = Get-DefaultSlaveUserForOs $osType
    $Row.Cells["VdbenchPath"].Value = Get-DefaultVdbenchPathForOs $osType
    $name = [string]$Row.Cells["Name"].Value
    $hostName = [string]$Row.Cells["Host"].Value
    if ($RefreshSshAlias -or [string]::IsNullOrWhiteSpace([string]$Row.Cells["SshAlias"].Value)) {
        $Row.Cells["SshAlias"].Value = Get-DefaultSshAliasForSlave $name $hostName
    }
}

function Set-SlaveGridRowFromSlave {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [object]$Slave
    )
    $normalized = Apply-SlaveDefaults $Slave
    foreach ($col in @("Enabled", "Name", "Host", "OsType", "User", "VdbenchPath", "SshAlias", "Notes")) {
        $Row.Cells[$col].Value = Get-PropertyValue $normalized $col ""
    }
    $Row.Cells["Readiness"].Value = [string](Get-PropertyValue $normalized "ReadinessStatus" "")
    $Row.Cells["CheckedAt"].Value = Format-SlaveCheckedAt ([string](Get-PropertyValue $normalized "ReadinessCheckedAt" ""))
    $Row.Cells["PingStatus"].Value = [string](Get-PropertyValue $normalized "PingStatus" "")
    $Row.Cells["PingAt"].Value = Format-SlaveCheckedAt ([string](Get-PropertyValue $normalized "PingCheckedAt" ""))
    $state = Get-SlaveRowState $Row
    $state.ReadinessOutput = [string](Get-PropertyValue $normalized "ReadinessOutput" "")
    $state.ReadinessCheckedAt = [string](Get-PropertyValue $normalized "ReadinessCheckedAt" "")
    $state.PingCheckedAt = [string](Get-PropertyValue $normalized "PingCheckedAt" "")
    Set-SlaveRowTargets $Row @(Get-PropertyValue $normalized "Targets" @())
    Sync-SlaveRowEnabledState $Row
}

function Build-SlaveGrid {
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $true
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false

    $enabledCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $enabledCol.Name = "Enabled"
    $enabledCol.HeaderText = "Use"
    $enabledCol.FillWeight = 40
    $grid.Columns.Add($enabledCol) | Out-Null

    foreach ($name in @("Name", "Host")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        $grid.Columns.Add($col) | Out-Null
    }

    $osCol = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $osCol.Name = "OsType"
    $osCol.HeaderText = "OS"
    [void]$osCol.Items.Add("Windows")
    [void]$osCol.Items.Add("Linux")
    $grid.Columns.Add($osCol) | Out-Null

    foreach ($name in @("User", "VdbenchPath", "SshAlias", "Targets", "Readiness", "CheckedAt", "PingStatus", "PingAt", "Notes")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = switch ($name) {
            "CheckedAt" { "Checked at" }
            "PingAt" { "Ping at" }
            "PingStatus" { "Ping" }
            default { $name }
        }
        $col.ReadOnly = @("Targets", "Readiness", "CheckedAt", "PingStatus", "PingAt") -contains $name
        if ($name -eq "Targets") { $col.FillWeight = 70 }
        if ($name -eq "Readiness") { $col.FillWeight = 55 }
        if ($name -eq "CheckedAt") { $col.FillWeight = 75 }
        if ($name -eq "Notes") { $col.FillWeight = 60 }
        $grid.Columns.Add($col) | Out-Null
    }

    foreach ($button in @(
            @{ Name = "Browse"; Text = "Browse" },
            @{ Name = "Recheck"; Text = "Re-check" },
            @{ Name = "Ping"; Text = "Ping" }
        )) {
        $col = New-Object System.Windows.Forms.DataGridViewButtonColumn
        $col.Name = $button.Name
        $col.HeaderText = $button.Text
        $col.Text = $button.Text
        $col.UseColumnTextForButtonValue = $true
        $col.FillWeight = 52
        $grid.Columns.Add($col) | Out-Null
    }

    $grid.Add_CellFormatting({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $row = $sender.Rows[$eventArgs.RowIndex]
        if ($row.IsNewRow) {
            return
        }
        if (-not (Test-SlaveRowReady $row)) {
            $eventArgs.CellStyle.ForeColor = [System.Drawing.Color]::DimGray
        }
        $columnName = $sender.Columns[$eventArgs.ColumnIndex].Name
        if ($columnName -eq "Readiness") {
            $status = [string]$eventArgs.Value
            if ($status -eq "Ready") {
                $eventArgs.CellStyle.ForeColor = [System.Drawing.Color]::DarkGreen
            } elseif ($status -eq "Failed" -or $status -eq "Error") {
                $eventArgs.CellStyle.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
    })

    $grid.Add_CellBeginEdit({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $columnName = $sender.Columns[$eventArgs.ColumnIndex].Name
        if ($columnName -eq "Enabled") {
            $row = $sender.Rows[$eventArgs.RowIndex]
            if (-not (Test-SlaveRowReady $row)) {
                $eventArgs.Cancel = $true
                Show-Warning "Host must pass readiness before it can be enabled."
            }
        }
    })

    $grid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($script:SlaveGridRefreshing -or $eventArgs.RowIndex -lt 0) {
            return
        }
        $columnName = $sender.Columns[$eventArgs.ColumnIndex].Name
        $row = $sender.Rows[$eventArgs.RowIndex]
        if ($row.IsNewRow) {
            return
        }
        if ($columnName -eq "Enabled") {
            if (-not (Test-SlaveRowReady $row)) {
                $row.Cells["Enabled"].Value = $false
            } else {
                Capture-SlaveGrid
                Refresh-ConfigPreview
            }
            return
        }
        if (@("OsType", "Name", "Host", "VdbenchPath", "User", "SshAlias") -contains $columnName) {
            Capture-Settings
            $refreshSshAlias = @("Name", "Host") -contains $columnName
            Apply-SlaveGridRowDefaults -Row $row -RefreshSshAlias:$refreshSshAlias
            $row.Cells["Enabled"].Value = $false
            if (@("Host", "OsType", "VdbenchPath", "Name") -contains $columnName) {
                Schedule-SlaveReadinessCheck $row.Index
            }
        }
    })

    $grid.Add_CellContentClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $columnName = $sender.Columns[$eventArgs.ColumnIndex].Name
        $row = $sender.Rows[$eventArgs.RowIndex]
        switch ($columnName) {
            "Browse" {
                Browse-SlaveTargetsForRow $row
            }
            "Recheck" {
                Start-SlaveReadinessCheck -Row $row -ShowOutput:$true
            }
            "Ping" {
                Start-SlavePingCheck $row
            }
        }
    })
    return $grid
}

function Populate-SlaveGrid {
    $script:SlaveGridRefreshing = $true
    try {
        Invoke-GridBatchUpdate $script:SlaveGrid {
            $script:SlaveGrid.Rows.Clear()
            foreach ($slave in @($script:Slaves)) {
                if (-not (Test-SlaveHasHost $slave)) {
                    continue
                }
                $idx = $script:SlaveGrid.Rows.Add()
                $row = $script:SlaveGrid.Rows[$idx]
                Set-SlaveGridRowFromSlave $row $slave
            }
        }
    } finally {
        $script:SlaveGridRefreshing = $false
    }
    foreach ($row in $script:SlaveGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        if (-not (Test-SlaveRowReady $row)) {
            Schedule-SlaveReadinessCheck $row.Index
        }
    }
}

function Capture-SlaveGrid {
    if ($null -eq $script:SlaveGrid) {
        return
    }
    $items = @()
    foreach ($row in $script:SlaveGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $name = [string]$row.Cells["Name"].Value
        $hostName = [string]$row.Cells["Host"].Value
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $hostName
        }
        $state = Get-SlaveRowState $row
        $items += Apply-SlaveDefaults ([pscustomobject]@{
            Enabled = [bool]$row.Cells["Enabled"].Value
            Name = $name
            Host = $hostName
            OsType = [string]$row.Cells["OsType"].Value
            User = [string]$row.Cells["User"].Value
            VdbenchPath = [string]$row.Cells["VdbenchPath"].Value
            TestTarget = ""
            Targets = @(Get-SlaveRowTargets $row)
            SshAlias = [string]$row.Cells["SshAlias"].Value
            ReadinessStatus = [string]$row.Cells["Readiness"].Value
            ReadinessCheckedAt = [string]$state.ReadinessCheckedAt
            ReadinessOutput = [string]$state.ReadinessOutput
            PingStatus = [string]$row.Cells["PingStatus"].Value
            PingCheckedAt = [string]$state.PingCheckedAt
            Notes = [string]$row.Cells["Notes"].Value
        })
    }
    $script:Slaves = @($items)
}

function Save-Slaves {
    Capture-SlaveGrid
    Write-JsonFile $script:SlavesPath $script:Slaves -AsArray
    Show-Info "Slave inventory saved."
    Refresh-ConfigPreview
}

function Get-SelectedSlaveRow {
    if ($null -eq $script:SlaveGrid) {
        return $null
    }
    if ($script:SlaveGrid.SelectedRows.Count -gt 0) {
        return $script:SlaveGrid.SelectedRows[0]
    }
    if ($script:SlaveGrid.CurrentRow -and -not $script:SlaveGrid.CurrentRow.IsNewRow) {
        return $script:SlaveGrid.CurrentRow
    }
    return $null
}

function Show-SlaveTargetPicker {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [object[]]$Inventory,
        [object[]]$Existing
    )
    $merged = @(Merge-TargetSelections $Inventory $Existing)
    if ($merged.Count -eq 0) {
        Show-Warning "No selectable targets were found."
        return $null
    }
    $hostLabel = [string]$Row.Cells["Host"].Value
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = ("Targets for {0}" -f $hostLabel)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 1000, 600
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $true

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.RowCount = 2
    $layout.ColumnCount = 1
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $dialog.Controls.Add($layout)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Controls.Add($toolbar, 0, 0)

    $refreshButton = New-Button "Refresh" 10 8 90 28
    $newFolderButton = New-Button "New folder" 108 8 95 28
    $addPathButton = New-Button "Add path" 210 8 85 28
    $toolbar.Controls.Add($refreshButton)
    $toolbar.Controls.Add($newFolderButton)
    $toolbar.Controls.Add($addPathButton)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    Add-TargetSelectionColumns $grid
    $layout.Controls.Add($grid, 0, 1)

  $reloadGrid = {
        param([object[]]$Items)
        Set-TargetGridRows $grid $Items
        foreach ($gridRow in $grid.Rows) {
            Update-TargetCreateFileEditability $gridRow
        }
    }
    & $reloadGrid $merged

    $refreshButton.Add_Click({
        try {
            $discovered = @(Get-SlaveTargetInventory $Row -Force)
            $current = @(Get-TargetGridRows $grid)
            & $reloadGrid @(Merge-TargetSelections $discovered $current)
        } catch {
            Show-Warning ("Refresh failed: " + $_.Exception.Message)
        }
    })

    $newFolderButton.Add_Click({
        try {
            $path = Prompt-HostFolderPath -Row $Row
            if ([string]::IsNullOrWhiteSpace($path)) {
                return
            }
            New-HostFolderPath -Row $Row -Path $path
            $current = @(Get-TargetGridRows $grid)
            $entry = New-TargetSelection -Kind "Filesystem" -Target $path -Description "Created from UI" -Selected $true
            & $reloadGrid @(Merge-TargetSelections @($entry) $current)
        } catch {
            Show-Warning ("Create folder failed: " + $_.Exception.Message)
        }
    })

    $addPathButton.Add_Click({
        $path = Prompt-HostPathEntry -Row $Row
        if ([string]::IsNullOrWhiteSpace($path)) {
            return
        }
        $kind = if ($path -match '^\\\\\.\\|^/dev/') { "Raw disk" } elseif ($path -match '\.(dat|bin|img)$') { "Test file" } else { "Filesystem" }
        $current = @(Get-TargetGridRows $grid)
        $entry = New-TargetSelection -Kind $kind -Target $path -Description "Manual entry" -Selected $true
        & $reloadGrid @(Merge-TargetSelections @($entry) $current)
    })

    $grid.Add_CurrentCellDirtyStateChanged({
        param($sender, $eventArgs)
        if ($sender.IsCurrentCellDirty) {
            $sender.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $grid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -ge 0) {
            Update-TargetCreateFileEditability $sender.Rows[$eventArgs.RowIndex]
        }
    })

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.Height = 46
    $dialog.Controls.Add($buttonPanel)

    $okButton = New-Button "Save selection" 720 9 125 28
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($okButton)
    $cancelButton = New-Button "Cancel" 855 9 80 28
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return @(Get-TargetGridRows $grid)
}

function Browse-SlaveTargetsForRow {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    if (-not (Test-SlaveRowReady $Row)) {
        Show-Warning "Host must pass readiness before browsing targets."
        return
    }
    Capture-Settings
    try {
        $targets = @(Get-SlaveTargetInventory $Row -Force)
        $selected = Show-SlaveTargetPicker -Row $Row -Inventory $targets -Existing (Get-SlaveRowTargets $Row)
        if ($null -ne $selected) {
            Set-SlaveRowTargets $Row $selected
            Capture-SlaveGrid
            Refresh-ConfigPreview
        }
    } catch {
        Show-Warning ("Target discovery failed: " + $_.Exception.Message)
    }
}

function Add-NewSlaveRow {
    Capture-Settings
    $idx = $script:SlaveGrid.Rows.Add()
    $row = $script:SlaveGrid.Rows[$idx]
    $row.Cells["Enabled"].Value = $false
    $row.Cells["Name"].Value = "slave-" + ($idx + 1)
    $row.Cells["Host"].Value = "host-or-ip"
    $row.Cells["OsType"].Value = "Windows"
    $row.Cells["Readiness"].Value = "Pending"
    $row.Cells["CheckedAt"].Value = ""
    $row.Cells["PingStatus"].Value = ""
    $row.Cells["PingAt"].Value = ""
    Apply-SlaveGridRowDefaults -Row $row -RefreshSshAlias:$true
    Set-SlaveRowTargets $row @()
    Schedule-SlaveReadinessCheck $row.Index
}

function Build-MasterSlaveTab {
    $tab = New-MainTabPage "Master / Slave" "Slaves"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 52)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-FlowToolbar
    $container.Controls.Add($toolbar, 0, 0)

    $addButton = New-Button "Add slave" 10 8 95 28
    $addButton.Add_Click({ Add-NewSlaveRow })
    $toolbar.Controls.Add($addButton)

    $removeButton = New-Button "Remove" 112 8 80 28
    $removeButton.Add_Click({
        $row = Get-SelectedSlaveRow
        if ($row -and -not $row.IsNewRow) {
            $script:SlaveGrid.Rows.Remove($row)
        }
    })
    $toolbar.Controls.Add($removeButton)

    $saveButton = New-Button "Save" 200 8 80 28
    $saveButton.Add_Click({ Save-Slaves })
    $toolbar.Controls.Add($saveButton)

    $exportButton = New-Button "Export" 288 8 75 28
    $exportButton.Add_Click({ Export-SlaveInventory })
    $toolbar.Controls.Add($exportButton)

    $importButton = New-Button "Import" 370 8 75 28
    $importButton.Add_Click({ Import-SlaveInventory })
    $toolbar.Controls.Add($importButton)

    $note = New-Label "Readiness runs automatically per host. Use is allowed only after Ready; browse targets on each row. Test file rows support create/overwrite." 0 0 900 36
    $toolbar.Controls.Add($note)

    $script:SlaveGrid = Build-SlaveGrid
    $container.Controls.Add($script:SlaveGrid, 0, 1)
    Populate-SlaveGrid
    return $tab
}
