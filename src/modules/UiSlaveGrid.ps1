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
            CleanInFlight = $false
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
    # ALWAYS pause for Enter before this window closes, regardless of the
    # checker's own exit code - never auto-close. This used to only pause on
    # a non-zero exit code, on the assumption that exit code 0 meant nothing
    # worth reviewing. That assumption is wrong for checker scripts (like the
    # shipped one) that print their own per-check [OK]/[FAIL] report lines
    # but still exit 0 regardless of whether individual checks passed - exit
    # code 0 here means "the script itself ran to completion", not "every
    # check inside it passed". With the old code, a run with one or more
    # internal [FAIL] lines but exit code 0 closed the window before the
    # user had any chance to read which check(s) failed.
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
Write-Host ''
if (`$exitCode -eq 0) {
    Write-Host 'Readiness checker finished (exit code 0).' -ForegroundColor Green
} else {
    Write-Host ('Readiness checker finished with a non-zero exit code (' + `$exitCode + ').') -ForegroundColor Yellow
}
Write-Host 'Review the output above, then press Enter to close this window...'
`$null = Read-Host
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
        # Wrap the checker invocation so the window ALWAYS pauses for Enter
        # before closing, regardless of the checker's own exit code - see
        # Get-ReadinessCheckerWrapperCommand for why exit code 0 alone is not
        # a safe signal that there is nothing worth reading.
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
            }
        }
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

function Complete-SlavePingBackgroundWork {
    param(
        $Result,
        $ErrorMessage,
        $Context
    )
    $status = if ($null -ne $ErrorMessage) { "Ping error: " + $ErrorMessage } else { [string]$Result }
    $checkedAt = (Get-Date).ToString("o")
    Update-SlaveRowPing $Context.RowIndex $status $checkedAt
}

function Complete-SlaveReadinessBackgroundWork {
    param(
        $Result,
        $ErrorMessage,
        $Context
    )
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
        }
    }
    Refresh-ConfigPreview
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
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $pingContext -CommandName "Invoke-SlavePingBackgroundWork" -OnCompleteCommandName "Complete-SlavePingBackgroundWork"
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
    Start-BackgroundUiWork -Owner $script:SlaveGrid -Context $readyContext -CommandName "Invoke-SlaveReadinessBackgroundWork" -OnCompleteCommandName "Complete-SlaveReadinessBackgroundWork"
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
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    Initialize-ResponsiveChildForm -Form $dialog -BaseWidth 560 -BaseHeight 250

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 2
    $layout.RowCount = 4
    $layout.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 16, 14, 16, 8
    $layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 110)) | Out-Null
    $layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 34)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 34)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 34)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 48)) | Out-Null
    $dialog.Controls.Add($layout)

    $hostLabel = New-Label "Host / IP:" 0 0 100 24
    $hostLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hostLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($hostLabel, 0, 0)
    $hostBox = New-TextBox "" 0 0 380 24
    $hostBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Controls.Add($hostBox, 1, 0)

    $nameLabel = New-Label "Name:" 0 0 100 24
    $nameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($nameLabel, 0, 1)
    $nameBox = New-TextBox $defaultName 0 0 380 24
    $nameBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Controls.Add($nameBox, 1, 1)

    $osLabel = New-Label "OS:" 0 0 100 24
    $osLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $osLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($osLabel, 0, 2)
    $osBox = New-Object System.Windows.Forms.ComboBox
    $osBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $osBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$osBox.Items.Add("Windows")
    [void]$osBox.Items.Add("Linux")
    $osBox.SelectedIndex = 0
    $layout.Controls.Add($osBox, 1, 2)

    $buttonPanel = New-ResponsiveDialogButtonPanel
    $ok = New-Button "Add" 0 0 85 28
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 0 0 85 28
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Add-ResponsiveDialogButtons -Panel $buttonPanel -Buttons @($cancel, $ok)
    $layout.Controls.Add($buttonPanel, 0, 3)
    $layout.SetColumnSpan($buttonPanel, 2)
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
    foreach ($col in @("Enabled", "Name", "Host", "OsType", "User", "VdbenchPath", "SshAlias")) {
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
    $osCol.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    [void]$osCol.Items.Add("Windows")
    [void]$osCol.Items.Add("Linux")
    $grid.Columns.Add($osCol) | Out-Null

    foreach ($name in @("User", "VdbenchPath", "SshAlias", "Targets", "Readiness", "CheckedAt", "PingStatus", "PingAt")) {
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
        if ($name -eq "CheckedAt") { $col.FillWeight = 95; $col.MinimumWidth = 145 }
        if ($name -eq "PingAt") { $col.FillWeight = 95; $col.MinimumWidth = 145 }
        $grid.Columns.Add($col) | Out-Null
    }

    foreach ($button in @(
            @{ Name = "CleanRun"; Text = "Clean" },
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
            "CleanRun" {
                Start-SlaveTargetClean -Row $row
            }
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
    Apply-DataGridResponsiveLayout $grid -WithButtons
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
    Apply-DataGridResponsiveLayout $script:SlaveGrid -WithButtons
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
        $legacyNotes = ""
        foreach ($existing in @($script:Slaves)) {
            if ([string](Get-PropertyValue $existing "Host" "") -eq $hostName -and [string](Get-PropertyValue $existing "Name" "") -eq $name) {
                $legacyNotes = [string](Get-PropertyValue $existing "Notes" "")
                break
            }
        }
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
            Notes = $legacyNotes
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

function Show-TargetPicker {
    param(
        $Row,
        [object[]]$Inventory,
        [object[]]$Existing,
        [string]$Title = ""
    )
    $merged = @(Merge-TargetSelections $Inventory $Existing)
    if ($merged.Count -eq 0) {
        Show-Warning "No selectable targets were found."
        return $null
    }
    $hostLabel = [string]$Title
    if ([string]::IsNullOrWhiteSpace($hostLabel)) {
        if ($null -ne $Row -and -not $Row.IsNewRow) {
            $hostLabel = [string]$Row.Cells["Host"].Value
        } else {
            $hostLabel = [string]$env:COMPUTERNAME
            if ([string]::IsNullOrWhiteSpace($hostLabel)) {
                $hostLabel = "localhost"
            }
        }
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = ("Targets for {0}" -f $hostLabel)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $true
    $scale = Initialize-ResponsiveChildForm -Form $dialog -BaseWidth 1040 -BaseHeight 640

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.RowCount = 3
    $layout.ColumnCount = 1
    $toolbarHeight = [int][Math]::Max(96, [Math]::Round(96 * $scale))
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), $toolbarHeight)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), ([int][Math]::Max(52, [Math]::Round(52 * $scale))))) | Out-Null
    $dialog.Controls.Add($layout)

    $toolbar = New-FlowToolbar
    Register-FlowToolbarResponsive $toolbar
    $refreshButton = New-Button "Refresh" 10 8 90 28
    $newFolderButton = New-Button "New folder" 108 8 95 28
    $addPathButton = New-Button "Add path" 210 8 85 28
    $exploreButton = New-Button "Explore" 303 8 85 28
    $selectAllButton = New-Button "Select all" 396 8 80 28
    $clearAllButton = New-Button "Clear all" 482 8 80 28
    Add-FlowToolbarItem $toolbar $refreshButton
    Add-FlowToolbarItem $toolbar $newFolderButton
    Add-FlowToolbarItem $toolbar $addPathButton
    Add-FlowToolbarItem $toolbar $exploreButton
    Add-FlowToolbarItem $toolbar $selectAllButton
    Add-FlowToolbarItem $toolbar $clearAllButton
    $hint = New-Label "Refresh lists drive roots; Explore opens folders and files. Tick Use on each target, then Save selection." 0 0 400 32
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.AutoSize = $false
    $hint.Tag = "flow-toolbar-wrap"
    $hint.AccessibleDescription = "40"
    $hint.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 4, 0, 0
    $toolbar.Controls.Add($hint)
    $layout.Controls.Add($toolbar, 0, 0)

    $listView = New-TargetListView
    $listFont = Get-ScaledUiFont
    $listView.Font = $listFont
    foreach ($column in @($listView.Columns)) {
        if ($column.Text -eq "Kind") {
            $column.Width = [int][Math]::Max(160, [Math]::Round(160 * $scale))
        } elseif ($column.Text -eq "Target") {
            $column.Width = [int][Math]::Max(280, [Math]::Round(280 * $scale))
        } else {
            $column.Width = [int][Math]::Max(420, [Math]::Round(420 * $scale))
        }
    }
    $layout.Controls.Add($listView, 0, 1)

    $counterLabel = New-Label "0 target(s) selected" 0 0 220 24
    $counterLabel.ForeColor = [System.Drawing.Color]::DimGray

    $reloadList = {
        param([object[]]$Items)
        Set-TargetListViewTargets -ListView $listView -Targets $Items
        Update-TargetListViewSelectionCounter $counterLabel $listView
    }
    Register-TargetListViewHandlers -ListView $listView -CounterLabel $counterLabel
    & $reloadList $merged

    $selectAllButton.Add_Click({
        Set-TargetListViewBulkSync -ListView $listView -Enabled $true
        try {
            foreach ($item in $listView.Items) {
                Update-TargetListViewItemSelection -Item $item -Selected $true
            }
        } finally {
            Set-TargetListViewBulkSync -ListView $listView -Enabled $false
        }
        Update-TargetListViewSelectionCounter $counterLabel $listView
    })
    $clearAllButton.Add_Click({
        Set-TargetListViewBulkSync -ListView $listView -Enabled $true
        try {
            foreach ($item in $listView.Items) {
                Update-TargetListViewItemSelection -Item $item -Selected $false
            }
        } finally {
            Set-TargetListViewBulkSync -ListView $listView -Enabled $false
        }
        Update-TargetListViewSelectionCounter $counterLabel $listView
    })

    $refreshButton.Add_Click({
        try {
            if ($null -ne $Row -and -not $Row.IsNewRow) {
                $discovered = @(Get-SlaveTargetInventory $Row -Force)
            } else {
                $discovered = @(Get-LocalTargetInventory -Force)
            }
            $current = @(Get-TargetListViewTargets $listView)
            & $reloadList @(Merge-TargetSelections $discovered $current)
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
            $current = @(Get-TargetListViewTargets $listView)
            $entry = New-TargetSelection -Kind "Filesystem" -Target $path -Description "Created from UI" -Selected $true
            & $reloadList @(Merge-TargetSelections @($entry) $current)
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
        $current = @(Get-TargetListViewTargets $listView)
        $entry = New-TargetSelection -Kind $kind -Target $path -Description "Manual entry" -Selected $true
        & $reloadList @(Merge-TargetSelections @($entry) $current)
    })

    $exploreButton.Add_Click({
        try {
            $initial = ""
            foreach ($item in @(Get-TargetListViewTargets $listView)) {
                if ([string](Get-PropertyValue $item "Kind" "") -eq "Filesystem") {
                    $candidate = [string](Get-PropertyValue $item "Target" "")
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $initial = $candidate
                        break
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($initial)) {
                if ($null -ne $Row -and -not $Row.IsNewRow) {
                    $selected = @(Get-SelectedTargetEntries (Get-SlaveRowTargets $Row))
                } else {
                    $selected = @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore))
                }
                if ($selected.Count -gt 0) {
                    $initial = [string](Get-PropertyValue $selected[0] "Target" "")
                }
            }
            $picked = Show-HostPathBrowser -Row $Row -InitialPath $initial
            if ($null -eq $picked) {
                return
            }
            $current = @(Get-TargetListViewTargets $listView)
            $entry = New-TargetSelection -Kind ([string]$picked.Kind) -Target ([string]$picked.Target) -Description ([string]$picked.Description) -Selected $true
            & $reloadList @(Merge-TargetSelections @($entry) $current)
        } catch {
            Show-Warning ("Explore failed: " + $_.Exception.Message)
        }
    }.GetNewClosure())

    $buttonPanel = New-ResponsiveDialogButtonPanel -BaseHeight 52
    $layout.Controls.Add($buttonPanel, 0, 2)

    $okButton = New-Button "Save selection" 0 0 125 28
    $okButton.Add_Click({
        $rows = @(Get-TargetListViewTargets $listView)
        if (@(Get-SelectedTargetEntries $rows).Count -eq 0) {
            Show-Warning "Tick at least one checkbox on the left, then Save selection."
            return
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $cancelButton = New-Button "Cancel" 0 0 80 28
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Add-ResponsiveDialogButtons -Panel $buttonPanel -Buttons @($cancelButton, $okButton) -LeadingLabel $counterLabel
    Update-TargetListViewSelectionCounter $counterLabel $listView
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    Apply-ResponsiveDialogControlFonts $dialog
    Update-FlowToolbarButtonSizes $dialog

    if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return @(Get-TargetListViewTargets $listView)
}

function Show-SlaveTargetPicker {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [object[]]$Inventory,
        [object[]]$Existing
    )
    return Show-TargetPicker -Row $Row -Inventory $Inventory -Existing $Existing
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
            if (@(Get-SelectedTargetEntries $selected).Count -gt 0) {
                $Row.Cells["Enabled"].Value = $true
            }
            Capture-SlaveGrid
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
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 108)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)
    $script:MasterSlaveToolbarLayout = $container

    $toolbar = New-FlowToolbar
    Register-FlowToolbarResponsive $toolbar
    $container.Controls.Add($toolbar, 0, 0)

    $addButton = New-Button "Add slave" 10 8 95 28
    $addButton.Add_Click({ Add-NewSlaveRow })
    Add-FlowToolbarItem $toolbar $addButton

    $removeButton = New-Button "Remove" 112 8 80 28
    $removeButton.Add_Click({
        $row = Get-SelectedSlaveRow
        if ($row -and -not $row.IsNewRow) {
            $script:SlaveGrid.Rows.Remove($row)
        }
    })
    Add-FlowToolbarItem $toolbar $removeButton

    $saveButton = New-Button "Save" 200 8 80 28
    $saveButton.Add_Click({ Save-Slaves })
    Add-FlowToolbarItem $toolbar $saveButton -FlowBreak

    $note = New-Label "Enter Host / IP when adding a slave. Click Readiness to verify the host. Browse targets, use Explore to open folders/files, tick Use beside each target, Save selection." 0 0 400 48
    $note.AutoSize = $false
    $note.Tag = "flow-toolbar-wrap"
    $note.AccessibleDescription = "48"
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $note.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 4, 0, 0
    $toolbar.Controls.Add($note)

    $script:SlaveGrid = Build-SlaveGrid
    $container.Controls.Add($script:SlaveGrid, 0, 1)
    Populate-SlaveGrid
    return $tab
}
