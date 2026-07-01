$script:SlaveGridRefreshing = $false

function Get-SlaveRowState {
    # Untyped $Row (not [System.Windows.Forms.DataGridViewRow]) so this can be
    # unit-tested with a plain mock object without WinForms loaded; PowerShell
    # calls members duck-typed regardless of the declared parameter type.
    param($Row)
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
    param($Row)
    if ($null -eq $Row) {
        return @()
    }
    # NOTE: do not write "@(Get-SlaveRowState $Row).Targets" here. Under
    # Set-StrictMode -Version 2.0 (enabled app-wide), wrapping a function
    # call that returns a single hashtable/object in @() before accessing a
    # property triggers PowerShell's per-element "member enumeration" on the
    # resulting 1-item array instead of plain property access. When that
    # property's value is an empty collection - true for every slave row
    # until targets are picked via Browse - member enumeration collects zero
    # results, and PowerShell raises "The property 'Targets' cannot be found
    # on this object" even though the property exists. Accessing the
    # property directly on the un-wrapped return value avoids this; @() is
    # still applied to the final result to guarantee an array.
    $state = Get-SlaveRowState $Row
    return @(Normalize-TargetEntries $state.Targets)
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
    # Untyped $Row (see Get-SlaveRowState above) so this is unit-testable with a
    # plain mock object without WinForms loaded.
    param($Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return $false
    }
    return ([string]$Row.Cells["Readiness"].Value) -eq "Ready"
}

function Sync-SlaveRowEnabledState {
    # Untyped $Row (see Get-SlaveRowState above) so this is unit-testable with a
    # plain mock object without WinForms loaded.
    param($Row)
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

function Get-ReadinessCheckerWrapperCommand {
    param(
        [string]$QuotedChecker,
        [string]$CheckerArgs
    )
    $innerCommand = "& $QuotedChecker $CheckerArgs"
    return @"
`$ErrorActionPreference = 'Stop'
try {
    $innerCommand
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
} catch {
    Write-Host ''
    Write-Host 'Readiness checker failed:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    `$exitCode = 1
}
if (`$exitCode -ne 0) {
    Write-Host ''
    Write-Host ('Readiness checker finished with a non-zero exit code (' + `$exitCode + ').') -ForegroundColor Yellow
    Write-Host 'Press Enter to close this window...'
    `$null = Read-Host
}
exit `$exitCode
"@
}

function Get-SlaveReadinessResult {
    param(
        [string]$HostName,
        [string]$VdbenchPath,
        [string]$Target,
        [string]$Checker,
        [string]$CheckerTemplate,
        [bool]$ShowCheckerWindow = $false,
        [string]$OsType = ""
    )
    if ([string]::IsNullOrWhiteSpace($Checker) -or -not (Test-Path -LiteralPath $Checker)) {
        return [pscustomobject]@{
            Status = "Checker missing"
            Output = ""
            AlreadyShown = $false
        }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $checkerArgs = Expand-ReadinessCheckerArguments $CheckerTemplate $HostName $VdbenchPath $Target $OsType
    $quotedChecker = Quote-ProcessArgument $Checker
    # Run the checker from its own containing folder, matching exactly what
    # happens when a user double-clicks / "Run with PowerShell"s it from
    # Explorer. Without this, the checker inherits whatever directory the
    # main UI app happened to be launched from, so any relative path the
    # checker (or a script it shells out to) uses can silently create files
    # or folders in an unexpected location instead of alongside the checker.
    $checkerDir = Split-Path -Parent $Checker
    if (-not [string]::IsNullOrWhiteSpace($checkerDir) -and (Test-Path -LiteralPath $checkerDir)) {
        $psi.WorkingDirectory = $checkerDir
    }
    if ($ShowCheckerWindow) {
        # Wrap the checker invocation so the window behaves well in BOTH
        # outcomes: on success it closes itself immediately (no leftover
        # window to dismiss); on failure it prints the real error and waits
        # for Enter, so the user actually gets to read it instead of the
        # window flashing open and closing before they can see what happened
        # (this is what made a checker script param mismatch look like a
        # silent/"strange" failure previously).
        $wrapperCommand = Get-ReadinessCheckerWrapperCommand $quotedChecker $checkerArgs
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + (Quote-ProcessArgument $wrapperCommand)
        # UseShellExecute MUST be $true here to actually get a brand-new,
        # independent console. UseShellExecute=$false + CreateNoWindow=$false
        # (the previous code) does NOT create a new window: per Win32
        # CreateProcess semantics (see Microsoft's own ProcessStartInfo docs/
        # blog on this exact gotcha), that combination only avoids
        # *suppressing* a console - it does not request a new one - so the
        # child silently shares/inherits whatever console (if any) the UI's
        # own host process is already attached to. When the UI is launched
        # from a .bat/console shortcut, that meant the checker's output never
        # opened a visibly separate window (it echoed into the pre-existing,
        # possibly hidden console the whole app was started from) and,
        # worse, closing that shared console sends a close signal to every
        # process attached to it - including the UI itself.
        # UseShellExecute=$true always creates a new window regardless of
        # CreateNoWindow (which is then ignored), fully decoupling the
        # checker's console from the app's own.
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    } else {
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedChecker $checkerArgs"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($ShowCheckerWindow) {
            $p.WaitForExit()
            return [pscustomobject]@{
                Status = if ($p.ExitCode -eq 0) { "Ready" } else { "Failed" }
                Output = "Readiness checker ran in a separate PowerShell window (exit code $($p.ExitCode))."
                # The user already watched the real output live in that
                # separate window, so the caller must not pop a duplicate
                # confirmation dialog on top of it.
                AlreadyShown = $true
            }
        }
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $status = if ($p.ExitCode -eq 0) { "Ready" } else { "Failed" }
        return [pscustomobject]@{
            Status = $status
            Output = ($out + [Environment]::NewLine + $err).Trim()
            AlreadyShown = $false
        }
    } catch {
        return [pscustomobject]@{
            Status = "Error"
            Output = $_.Exception.Message
            AlreadyShown = $false
        }
    }
}

function Get-SlaveReadinessTargetForRow {
    # Untyped $Row (see Get-SlaveRowState above) so this is unit-testable with a
    # plain mock object without WinForms loaded.
    param($Row)
    $targets = @(Get-SelectedTargetEntries (Get-SlaveRowTargets $Row))
    if ($targets.Count -gt 0) {
        return [string]$targets[0].Target
    }
    return Get-DefaultTestTargetForOs ([string]$Row.Cells["OsType"].Value)
}

function Invoke-SlavePingBackgroundWork {
    param([hashtable]$Context)
    Get-SlavePingStatus $Context.HostName
}

function Invoke-SlaveReadinessBackgroundWork {
    param([hashtable]$Context)
    Get-SlaveReadinessResult `
        $Context.HostName `
        $Context.VdbenchPath `
        $Context.Target `
        $Context.Checker `
        $Context.CheckerTemplate `
        ([bool]$Context.ShowCheckerWindow) `
        ([string]$Context.OsType)
}

function Start-SlavePingCheck {
    # Untyped $Row (see Get-SlaveRowState above) so this is unit-testable with a
    # plain mock object without WinForms loaded.
    param($Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    if ([string]$Row.Cells["PingStatus"].Value -eq "Pinging...") {
        # Ignore repeat clicks while a ping for this row is already running;
        # otherwise clicking Ping several times (a natural reaction when the
        # status does not visibly change right away) queues one background
        # job per click that all update the same cell out of order once they
        # complete.
        return
    }
    $pingContext = @{
        RowIndex = $Row.Index
        HostName = [string]$Row.Cells["Host"].Value
    }
    Write-DebugLog ("Ping check started for host={0} row={1}" -f $pingContext.HostName, $pingContext.RowIndex)
    Update-SlaveRowPing $pingContext.RowIndex "Pinging..."
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $pingContext -CommandName "Invoke-SlavePingBackgroundWork" -OnComplete {
        param($Result, $ErrorMessage, $Context)
        $status = if ($null -ne $ErrorMessage) { "Ping error: " + $ErrorMessage } else { [string]$Result }
        $checkedAt = (Get-Date).ToString("o")
        Update-SlaveRowPing $Context.RowIndex $status $checkedAt
    }
}

function Start-SlaveReadinessCheck {
    # Untyped $Row (see Get-SlaveRowState above) so this is unit-testable with a
    # plain mock object without WinForms loaded.
    param(
        $Row,
        [bool]$ShowOutput = $false
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    if ([string]$Row.Cells["Readiness"].Value -eq "Checking...") {
        # Ignore repeat clicks while a check for this row is already in
        # flight. Without this guard, clicking Readiness several times (a
        # very natural reaction when nothing seems to happen right away)
        # queued one background job - and, with -ShowOutput, one popup - per
        # click; they then all completed around the same time and piled up
        # into a wall of confirmation dialogs to click through one by one,
        # which looked and felt like the whole UI had frozen.
        return
    }
    Capture-Settings
    $readyContext = @{
        RowIndex = $Row.Index
        ShowOutput = $ShowOutput
        ShowCheckerWindow = $ShowOutput
        HostName = [string]$Row.Cells["Host"].Value
        VdbenchPath = [string]$Row.Cells["VdbenchPath"].Value
        Target = Get-SlaveReadinessTargetForRow $Row
        OsType = [string]$Row.Cells["OsType"].Value
        Checker = [string](Get-PropertyValue $script:Settings "ReadinessChecker" "")
        CheckerTemplate = [string](Get-PropertyValue $script:Settings "ReadinessCheckerArguments" "{HostFlag}")
    }
    Write-DebugLog ("Readiness check started for host={0} row={1} checker={2}" -f $readyContext.HostName, $readyContext.RowIndex, $readyContext.Checker)
    Update-SlaveRowReadiness $readyContext.RowIndex "Checking..."
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $readyContext -CommandName "Invoke-SlaveReadinessBackgroundWork" -OnComplete {
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
            $status = [string]$Result.Status
            if ($status -eq "Checker missing") {
                Show-Warning "Readiness checker path is missing or does not exist."
            } elseif ($status -eq "Error") {
                Show-Warning ("Readiness checker failed to start: " + [string]$Result.Output)
            } elseif (-not [bool](Get-PropertyValue $Result "AlreadyShown" $false) -and -not [string]::IsNullOrWhiteSpace([string]$Result.Output)) {
                # AlreadyShown means the checker ran in its own separate
                # window and the user already watched the real output live
                # there; popping a redundant "ran in a separate window"
                # dialog on top of it added nothing except another window to
                # dismiss, and piled up badly when several checks were
                # in flight or re-run.
                Show-Info ([string]$Result.Output) "Readiness output"
            }
        }
        Refresh-ConfigPreview
    }
}

function Reset-SlaveRowReadiness {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $Row.Cells["Readiness"].Value = "Not checked"
    $Row.Cells["CheckedAt"].Value = ""
    $state = Get-SlaveRowState $Row
    $state.ReadinessCheckedAt = ""
    $state.ReadinessOutput = ""
    Sync-SlaveRowEnabledState $Row
}

function Show-AddSlaveDialog {
    $nextIndex = 1
    if ($null -ne $script:SlaveGrid) {
        $nextIndex = $script:SlaveGrid.Rows.Count + 1
    }
    $defaultName = "slave-$nextIndex"

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Add slave host"
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 520, 210
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $hostLabel = New-Label "Host / IP:" 16 18 80 22
    $hostBox = New-TextBox "" 104 16 380 24
    $nameLabel = New-Label "Name:" 16 52 80 22
    $nameBox = New-TextBox $defaultName 104 50 380 24
    $osLabel = New-Label "OS:" 16 86 80 22
    $osBox = New-Object System.Windows.Forms.ComboBox
    $osBox.Location = New-Object System.Drawing.Point -ArgumentList 104, 84
    $osBox.Size = New-Object System.Drawing.Size -ArgumentList 160, 24
    $osBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$osBox.Items.Add("Windows")
    [void]$osBox.Items.Add("Linux")
    $osBox.SelectedIndex = 0

    $dialog.Controls.AddRange(@($hostLabel, $hostBox, $nameLabel, $nameBox, $osLabel, $osBox))

    $ok = New-Button "Add" 320 126 75 28
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 401 126 75 28
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.AddRange(@($ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    if ($null -ne $script:Form) {
        $dialogResult = $dialog.ShowDialog($script:Form)
    } else {
        $dialogResult = $dialog.ShowDialog()
    }
    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $hostName = [string]$hostBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Show-Warning "Host / IP is required."
        return $null
    }
    $name = [string]$nameBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $hostName
    }
    return @{
        Host = $hostName
        Name = $name
        OsType = [string]$osBox.SelectedItem
    }
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
    $Row.Cells["Readiness"].Value = [string](Get-PropertyValue $normalized "ReadinessStatus" "Not checked")
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
        $col.HeaderText = if ($name -eq "Host") { "Host / IP" } else { $name }
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
            @{ Name = "ReadinessRun"; Text = "Readiness" },
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
                Notify-ProfileTargetContextChanged "slave-enabled"
            }
            return
        }
        if (@("OsType", "Name", "Host", "VdbenchPath", "User", "SshAlias") -contains $columnName) {
            Capture-Settings
            $refreshSshAlias = @("Name", "Host") -contains $columnName
            Apply-SlaveGridRowDefaults -Row $row -RefreshSshAlias:$refreshSshAlias
            if (@("Host", "OsType", "VdbenchPath", "Name") -contains $columnName) {
                Reset-SlaveRowReadiness $row
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
        if ($row.IsNewRow) {
            return
        }
        switch ($columnName) {
            "Browse" {
                Browse-SlaveTargetsForRow $row
            }
            "ReadinessRun" {
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
            Notify-ProfileTargetContextChanged "slave-target-picker"
        }
    } catch {
        Show-Warning ("Target discovery failed: " + $_.Exception.Message)
    }
}

function Add-NewSlaveRow {
    Capture-Settings
    $details = Show-AddSlaveDialog
    if ($null -eq $details) {
        return
    }
    $idx = $script:SlaveGrid.Rows.Add()
    $row = $script:SlaveGrid.Rows[$idx]
    $row.Cells["Enabled"].Value = $false
    $row.Cells["Name"].Value = [string]$details.Name
    $row.Cells["Host"].Value = [string]$details.Host
    $row.Cells["OsType"].Value = [string]$details.OsType
    $row.Cells["Readiness"].Value = "Not checked"
    $row.Cells["CheckedAt"].Value = ""
    $row.Cells["PingStatus"].Value = ""
    $row.Cells["PingAt"].Value = ""
    Apply-SlaveGridRowDefaults -Row $row -RefreshSshAlias:$true
    Set-SlaveRowTargets $row @()
    $script:SlaveGrid.CurrentCell = $row.Cells["Host"]
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

    $note = New-Label "Enter Host / IP when adding a slave. Click Readiness on each row to verify the host before enabling Use or browsing targets." 0 0 900 36
    $toolbar.Controls.Add($note)

    $script:SlaveGrid = Build-SlaveGrid
    $container.Controls.Add($script:SlaveGrid, 0, 1)
    Populate-SlaveGrid
    return $tab
}
