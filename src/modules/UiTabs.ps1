function Build-SettingsTab {
    $tab = New-MainTabPage "Settings / Paths" "Settings"

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $tab.Controls.Add($panel)

    $fields = @(
        @{ Key = "InstallRoot"; Label = "Install root"; Browse = "none"; InfoOnly = $true },
        @{ Key = "VdbenchRoot"; Label = "Vdbench root"; Browse = "folder" },
        @{ Key = "ManagerRoot"; Label = "Manager root"; Browse = "none"; InfoOnly = $true },
        @{ Key = "ReportsRoot"; Label = "Reports root"; Browse = "folder" },
        @{ Key = "ReadinessChecker"; Label = "Readiness checker"; Browse = "file"; Hint = "Script run when clicking Readiness on a row. It opens in its own PowerShell window. The shipped default script needs 'Readiness args template' below set to {HostFlag} to actually check the clicked row's host; clear it to blank instead only if you point this at a different script that takes no arguments." },
        @{ Key = "MasterVdbenchBat"; Label = "Master vdbench.bat"; Browse = "file"; Hint = "Absolute path to vdbench.bat on THIS (master) machine. If the Readiness checker reports this file missing, it is checking its own separate, hardcoded path, not this setting - verify the real path here (the official Vdbench zip often extracts into a version-named subfolder, e.g. C:\vdbench\vdbench50407\vdbench.bat, one level deeper than expected) and use Settings -> Validate below to confirm Exists=True locally." },
        @{ Key = "WindowsVdbench"; Label = "Windows Vdbench path"; Browse = "folder"; Hint = "Default Vdbench path for Windows slaves." },
        @{ Key = "LinuxVdbench"; Label = "Linux Vdbench path"; Browse = "none"; Hint = "Default Vdbench path for Linux slaves." },
        @{ Key = "SshConfig"; Label = "SSH config"; Browse = "file" },
        @{ Key = "PrivateKey"; Label = "Private key"; Browse = "file" },
        @{ Key = "ReadinessCheckerArguments"; Label = "Readiness args template"; Browse = "none"; Hint = "Default {HostFlag} expands to -WindowsHosts '<Host>' or -LinuxHosts '<Host>' (chosen by this row's OS) - the shipped checker's real parameter for which host to check remotely. {Host}/{VdbenchPath}/{Target} are also available for a different checker script with its own -HostName-style parameters. Leave blank only if your checker script takes no arguments at all; passing an unrecognized named parameter to a script using [CmdletBinding()] throws a 'parameter cannot be found' error." },
        @{ Key = "SlaveShell"; Label = "Slave shell"; Browse = "none" }
    )

    $y = 18
    foreach ($field in $fields) {
        $labelText = [string](Get-PropertyValue $field "Label" "")
        if ([bool](Get-PropertyValue $field "InfoOnly" $false)) {
            $labelText = $labelText + " (reference)"
        }
        $panel.Controls.Add((New-Label $labelText 18 $y 180))
        $fieldKey = [string](Get-PropertyValue $field "Key" "")
        $box = New-TextBox ([string](Get-PropertyValue $script:Settings $fieldKey "")) 210 $y 520
        if ([bool](Get-PropertyValue $field "InfoOnly" $false)) {
            $box.ReadOnly = $true
            $box.BackColor = [System.Drawing.Color]::Gainsboro
            Set-ControlToolTip $box "Reference only. This value is not used by config generation or runs."
        }
        $hint = [string](Get-PropertyValue $field "Hint" "")
        if (-not [string]::IsNullOrWhiteSpace($hint)) {
            Set-ControlToolTip $box $hint
        }
        $panel.Controls.Add($box)
        $script:SettingsControls[$fieldKey] = $box
        $browse = [string](Get-PropertyValue $field "Browse" "none")
        if ($browse -ne "none") {
            $button = New-Button "Browse" 740 ($y - 2) 80 26
            if ($browse -eq "folder") {
                $button.Add_Click({
                    param($sender, $eventArgs)
                    Browse-FolderForControl $sender.Tag
                })
            } else {
                $button.Add_Click({
                    param($sender, $eventArgs)
                    Browse-FileForControl $sender.Tag
                })
            }
            $button.Tag = $box
            $panel.Controls.Add($button)
        }
        $y += 34
    }

    $commentDisabled = New-Object System.Windows.Forms.CheckBox
    $commentDisabled.Text = "Render disabled parameters as comments"
    $commentDisabled.Checked = [bool](Get-PropertyValue $script:Settings "CommentDisabledParameters" $true)
    $commentDisabled.Location = New-Object System.Drawing.Point -ArgumentList 210, $y
    $commentDisabled.Size = New-Object System.Drawing.Size -ArgumentList 300, 24
    $panel.Controls.Add($commentDisabled)
    $script:SettingsControls["CommentDisabledParameters"] = $commentDisabled
    $y += 30

    $requirePreview = New-Object System.Windows.Forms.CheckBox
    $requirePreview.Text = "Require preview confirmation before run"
    $requirePreview.Checked = [bool](Get-PropertyValue $script:Settings "RequirePreviewBeforeRun" $true)
    $requirePreview.Location = New-Object System.Drawing.Point -ArgumentList 210, $y
    $requirePreview.Size = New-Object System.Drawing.Size -ArgumentList 300, 24
    $panel.Controls.Add($requirePreview)
    $script:SettingsControls["RequirePreviewBeforeRun"] = $requirePreview
    $y += 42

    $saveButton = New-Button "Save settings" 18 $y 120 30
    $saveButton.Add_Click({ Save-Settings })
    $panel.Controls.Add($saveButton)

    $validateButton = New-Button "Validate paths" 150 $y 120 30
    $validateButton.Add_Click({ Validate-SettingsPaths })
    $panel.Controls.Add($validateButton)

    $fakeButton = New-Button "Use fake runner" 282 $y 125 30
    $fakeButton.Add_Click({ Use-FakeRunnerSettings })
    $panel.Controls.Add($fakeButton)

    $importSettingsButton = New-Button "Import settings" 418 $y 125 30
    $importSettingsButton.Add_Click({ Import-Settings })
    $panel.Controls.Add($importSettingsButton)

    $exportSettingsButton = New-Button "Export settings" 554 $y 125 30
    $exportSettingsButton.Add_Click({ Export-Settings })
    $panel.Controls.Add($exportSettingsButton)

    $y += 46
    $script:SettingsStatusBox = New-Object System.Windows.Forms.TextBox
    $script:SettingsStatusBox.Multiline = $true
    $script:SettingsStatusBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:SettingsStatusBox.ReadOnly = $true
    $script:SettingsStatusBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:SettingsStatusBox.Location = New-Object System.Drawing.Point -ArgumentList 18, $y
    $script:SettingsStatusBox.Size = New-Object System.Drawing.Size -ArgumentList 1120, 250
    $panel.Controls.Add($script:SettingsStatusBox)
    Validate-SettingsPaths
    return $tab
}
function Get-TargetIdentity {
    param([object]$Target)
    return (([string](Get-PropertyValue $Target "Kind" "")).ToLowerInvariant() + "|" + ([string](Get-PropertyValue $Target "Target" "")).ToLowerInvariant())
}

function Merge-TargetSelections {
    param(
        [object[]]$Discovered,
        [object[]]$Existing
    )
    $existingByKey = @{}
    foreach ($item in @(Normalize-TargetEntries $Existing)) {
        $existingByKey[(Get-TargetIdentity $item)] = $item
    }
    $result = @()
    $seen = @{}
    foreach ($item in @($Discovered)) {
        $normalized = Normalize-TargetEntry $item
        if ($null -eq $normalized) {
            continue
        }
        $key = Get-TargetIdentity $normalized
        if ($existingByKey.ContainsKey($key)) {
            $old = $existingByKey[$key]
            $normalized.Selected = [bool](Get-PropertyValue $old "Selected" $false)
            $normalized.CreateFile = [bool](Get-PropertyValue $old "CreateFile" $false)
        }
        $result += $normalized
        $seen[$key] = $true
    }
    foreach ($item in @(Normalize-TargetEntries $Existing)) {
        $key = Get-TargetIdentity $item
        if (-not $seen.ContainsKey($key) -and [bool](Get-PropertyValue $item "Selected" $false)) {
            $result += $item
        }
    }
    return @($result)
}

function Add-TargetSelectionColumns {
    param([System.Windows.Forms.DataGridView]$Grid)
    $selectedCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $selectedCol.Name = "Selected"
    $selectedCol.HeaderText = "Use"
    $selectedCol.FillWeight = 55
    $selectedCol.MinimumWidth = 48
    $selectedCol.Width = 52
    $selectedCol.ThreeState = $false
    $selectedCol.TrueValue = $true
    $selectedCol.FalseValue = $false
    $selectedCol.ValueType = [bool]
    $Grid.Columns.Add($selectedCol) | Out-Null
    foreach ($name in @("Kind", "Target")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        $col.ReadOnly = $true
        if ($name -eq "Target") {
            $col.FillWeight = 150
        }
        $Grid.Columns.Add($col) | Out-Null
    }
    $createCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $createCol.Name = "CreateFile"
    $createCol.HeaderText = "Create/overwrite file"
    $createCol.FillWeight = 80
    $createCol.MinimumWidth = 48
    $createCol.ThreeState = $false
    $createCol.TrueValue = $true
    $createCol.FalseValue = $false
    $createCol.ValueType = [bool]
    $Grid.Columns.Add($createCol) | Out-Null
    $descCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $descCol.Name = "Description"
    $descCol.HeaderText = "Description"
    $descCol.ReadOnly = $true
    $Grid.Columns.Add($descCol) | Out-Null
}

function Initialize-TargetSelectionGrid {
    param([System.Windows.Forms.DataGridView]$Grid)
    $Grid.ReadOnly = $false
    $Grid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
    $Grid.StandardTab = $true
}

function Invoke-TargetGridRowChanged {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [System.Windows.Forms.DataGridViewRow]$Row,
        [scriptblock]$Extra
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    Sync-TargetGridRowSelectionStyle $Row
    Update-TargetCreateFileEditability $Row
    if ($null -ne $Extra) {
        & $Extra $Grid $Row
    }
}

function Register-TargetSelectionGridHandlers {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [scriptblock]$OnRowChanged
    )
    Initialize-TargetSelectionGrid $Grid
    # Event-handler scriptblocks do not capture local variables (see AGENTS.md) -
    # store the callback on the grid Tag so handlers can read it at fire time.
    $tag = @{}
    if ($null -ne $Grid.Tag -and $Grid.Tag -is [hashtable]) {
        $tag = @{} + $Grid.Tag
    }
    $tag.TargetSelectionOnRowChanged = $OnRowChanged
    $Grid.Tag = $tag

    $Grid.Add_CurrentCellDirtyStateChanged({
        param($sender, $eventArgs)
        if ($sender.IsCurrentCellDirty) {
            $sender.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $Grid.Add_CellValueChanged({
        param($sender, $eventArgs)
        try {
            if ($eventArgs.RowIndex -ge 0) {
                $extra = $null
                if ($null -ne $sender.Tag) {
                    $extra = $sender.Tag.TargetSelectionOnRowChanged
                }
                Invoke-TargetGridRowChanged -Grid $sender -Row $sender.Rows[$eventArgs.RowIndex] -Extra $extra
            }
        } catch {
            Write-AppLog ("Target grid CellValueChanged failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    })
    $Grid.Add_CellContentClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $row = $sender.Rows[$eventArgs.RowIndex]
        $column = $sender.Columns[$eventArgs.ColumnIndex]
        if ($column.Name -eq "CreateFile") {
            if ($row.Cells["CreateFile"].ReadOnly) {
                return
            }
            return
        }
        $extra = $null
        if ($null -ne $sender.Tag) {
            $extra = $sender.Tag.TargetSelectionOnRowChanged
        }
        if ($column.Name -eq "Selected") {
            $current = [bool](Get-PropertyValue $row.Cells["Selected"].Value $false)
            $row.Cells["Selected"].Value = -not $current
            $sender.InvalidateCell($row.Cells["Selected"])
            Invoke-TargetGridRowChanged -Grid $sender -Row $row -Extra $extra
            return
        }
        if ($column.Name -in @("Kind", "Target", "Description")) {
            $current = [bool](Get-PropertyValue $row.Cells["Selected"].Value $false)
            $row.Cells["Selected"].Value = -not $current
            $sender.InvalidateCell($row.Cells["Selected"])
            Invoke-TargetGridRowChanged -Grid $sender -Row $row -Extra $extra
        }
    })
    $Grid.Add_CellDoubleClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $row = $sender.Rows[$eventArgs.RowIndex]
        $row.Cells["Selected"].Value = -not [bool](Get-PropertyValue $row.Cells["Selected"].Value $false)
        $sender.InvalidateCell($row.Cells["Selected"])
        $extra = $null
        if ($null -ne $sender.Tag) {
            $extra = $sender.Tag.TargetSelectionOnRowChanged
        }
        Invoke-TargetGridRowChanged -Grid $sender -Row $row -Extra $extra
    })
}

function Set-TargetGridRows {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Targets
    )
    Invoke-GridBatchUpdate $Grid {
        $Grid.Rows.Clear()
        foreach ($target in @(Normalize-TargetEntries $Targets)) {
            $idx = $Grid.Rows.Add()
            $row = $Grid.Rows[$idx]
            $row.Cells["Selected"].Value = [bool](Get-PropertyValue $target "Selected" $false)
            $row.Cells["Kind"].Value = [string](Get-PropertyValue $target "Kind" "")
            $row.Cells["Target"].Value = [string](Get-PropertyValue $target "Target" "")
            $row.Cells["CreateFile"].Value = [bool](Get-PropertyValue $target "CreateFile" $false)
            $row.Cells["Description"].Value = [string](Get-PropertyValue $target "Description" "")
        }
    }
}

function Get-TargetGridRows {
    param([System.Windows.Forms.DataGridView]$Grid)
    if ($null -eq $Grid) {
        return @()
    }
    $Grid.EndEdit()
    $targets = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $targets += New-TargetSelection `
            -Kind ([string]$row.Cells["Kind"].Value) `
            -Target ([string]$row.Cells["Target"].Value) `
            -Description ([string]$row.Cells["Description"].Value) `
            -Selected ([bool](Get-PropertyValue $row.Cells["Selected"].Value $false)) `
            -CreateFile ([bool](Get-PropertyValue $row.Cells["CreateFile"].Value $false))
    }
    return @($targets)
}

function New-TargetListView {
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.HideSelection = $false
    $listView.MultiSelect = $false
    [void]$listView.Columns.Add("Kind", 100)
    [void]$listView.Columns.Add("Target", 260)
    [void]$listView.Columns.Add("Description", 420)
    return $listView
}

function Get-ListViewItemChecked {
    param([System.Windows.Forms.ListViewItem]$Item)
    if ($null -eq $Item) {
        return $false
    }
    try {
        return [bool]$Item.Checked
    } catch {
        return $false
    }
}

function Sync-TargetListViewItemStyle {
    param([System.Windows.Forms.ListViewItem]$Item)
    if ($null -eq $Item) {
        return
    }
    if (Get-ListViewItemChecked $Item) {
        $Item.BackColor = [System.Drawing.Color]::Honeydew
    } else {
        $Item.BackColor = [System.Drawing.Color]::White
    }
}

function Clear-TargetListViewBulkSyncDeferred {
    param([System.Windows.Forms.ListView]$ListView)
    if ($null -eq $ListView) {
        return
    }
    if ($ListView.IsHandleCreated) {
        $target = $ListView
        $action = [System.Action]{
            Set-TargetListViewBulkSync -ListView $target -Enabled $false
        }
        $ListView.BeginInvoke($action) | Out-Null
    } else {
        Set-TargetListViewBulkSync -ListView $ListView -Enabled $false
    }
}

function Set-TargetListViewBulkSync {
    param(
        [System.Windows.Forms.ListView]$ListView,
        [bool]$Enabled
    )
    if ($null -eq $ListView) {
        return
    }
    $tag = $ListView.Tag
    if ($null -eq $tag) {
        $tag = @{}
    } elseif ($tag -isnot [hashtable]) {
        $tag = @{ Data = $tag }
    } else {
        $tag = @{} + $tag
    }
    $tag['Syncing'] = $Enabled
    $ListView.Tag = $tag
}

function Get-TargetListViewItemFields {
    param(
        [System.Windows.Forms.ListViewItem]$Item,
        [object]$Stored = $null
    )
    if ($null -eq $Item) {
        return @{
            Kind = ""
            Target = ""
            Description = ""
            CreateFile = $false
        }
    }
    if ($null -eq $Stored) {
        $Stored = Get-PropertyValue $Item "Tag" $null
    }
    $kind = [string](Get-PropertyValue $Stored "Kind" ([string]$Item.Text))
    $path = ""
    if ($Item.SubItems.Count -ge 2) {
        $path = [string]$Item.SubItems[1].Text
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [string](Get-PropertyValue $Stored "Target" "")
    }
    $description = ""
    if ($Item.SubItems.Count -ge 3) {
        $description = [string]$Item.SubItems[2].Text
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = [string](Get-PropertyValue $Stored "Description" "")
    }
    $createFile = [bool](Get-PropertyValue $Stored "CreateFile" $false)
    return @{
        Kind = $kind
        Target = $path
        Description = $description
        CreateFile = $createFile
    }
}

function Update-TargetListViewItemSelection {
    param(
        [System.Windows.Forms.ListViewItem]$Item,
        [bool]$Selected,
        [switch]$FromItemChecked
    )
    if ($null -eq $Item) {
        return
    }
    $fields = Get-TargetListViewItemFields -Item $Item
    $createFile = [bool]$fields.CreateFile
    if ($Selected -and [string]$fields.Kind -eq "Test file") {
        $createFile = $true
    }
    # Tag must exist before Checked changes; ItemChecked fires synchronously under StrictMode.
    $Item.Tag = New-TargetSelection `
        -Kind ([string]$fields.Kind) `
        -Target ([string]$fields.Target) `
        -Description ([string]$fields.Description) `
        -Selected $Selected `
        -CreateFile $createFile
    # Never reassign Checked from inside ItemChecked; WinForms can throw or recurse badly.
    if (-not $FromItemChecked) {
        if ((Get-ListViewItemChecked $Item) -ne $Selected) {
            $Item.Checked = $Selected
        }
    }
    Sync-TargetListViewItemStyle $Item
}

function Set-TargetListViewTargets {
    param(
        [System.Windows.Forms.ListView]$ListView,
        [object[]]$Targets
    )
    Set-TargetListViewBulkSync -ListView $ListView -Enabled $true
    $ListView.BeginUpdate()
    try {
        $ListView.Items.Clear()
        foreach ($target in @(Normalize-TargetEntries $Targets)) {
            $kind = [string](Get-PropertyValue $target "Kind" "")
            $path = [string](Get-PropertyValue $target "Target" "")
            $description = [string](Get-PropertyValue $target "Description" "")
            $selected = [bool](Get-PropertyValue $target "Selected" $false)
            $createFile = [bool](Get-PropertyValue $target "CreateFile" $false)
            if ($selected -and $kind -eq "Test file") {
                $createFile = $true
            }
            $item = New-Object System.Windows.Forms.ListViewItem $kind
            [void]$item.SubItems.Add($path)
            [void]$item.SubItems.Add($description)
            Update-TargetListViewItemSelection -Item $item -Selected $selected
            [void]$ListView.Items.Add($item)
        }
    } finally {
        $ListView.EndUpdate()
        Clear-TargetListViewBulkSyncDeferred $ListView
    }
}

function Get-TargetListViewTargets {
    param([System.Windows.Forms.ListView]$ListView)
    if ($null -eq $ListView) {
        return @()
    }
    $targets = @()
    foreach ($item in $ListView.Items) {
        $stored = Get-PropertyValue $item "Tag" $null
        $fields = Get-TargetListViewItemFields -Item $item -Stored $stored
        $createFile = [bool]$fields.CreateFile
        $checked = Get-ListViewItemChecked $item
        if ($checked -and [string]$fields.Kind -eq "Test file") {
            $createFile = $true
        }
        $targets += New-TargetSelection `
            -Kind ([string]$fields.Kind) `
            -Target ([string]$fields.Target) `
            -Description ([string]$fields.Description) `
            -Selected $checked `
            -CreateFile $createFile
    }
    return @($targets)
}

function Update-TargetListViewSelectionCounter {
    param(
        [System.Windows.Forms.Label]$Label,
        [System.Windows.Forms.ListView]$ListView
    )
    if ($null -eq $Label -or $null -eq $ListView) {
        return
    }
    $count = @(Get-SelectedTargetEntries @(Get-TargetListViewTargets $ListView)).Count
    $Label.Text = ("{0} target(s) selected" -f $count)
}

function Register-TargetListViewHandlers {
    param(
        [System.Windows.Forms.ListView]$ListView,
        [System.Windows.Forms.Label]$CounterLabel
    )
    $ListView.Tag = @{
        CounterLabel = $CounterLabel
        Syncing = $false
    }
    $ListView.Add_ItemChecked({
        param($sender, $eventArgs)
        try {
            if ([bool](Get-PropertyValue $sender.Tag "Syncing" $false)) {
                return
            }
            $item = $eventArgs.Item
            if ($null -eq $item) {
                return
            }
            Update-TargetListViewItemSelection -Item $item -Selected (Get-ListViewItemChecked $item) -FromItemChecked
            $label = Get-PropertyValue $sender.Tag "CounterLabel" $null
            Update-TargetListViewSelectionCounter $label $sender
        } catch {
            Write-AppLog ("Target list ItemChecked handler failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    })
}

function Sync-TargetGridRowSelectionStyle {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $selected = [bool](Get-PropertyValue $Row.Cells["Selected"].Value $false)
    if ($selected) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Honeydew
        $Row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::LightGreen
        $Row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    } else {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
        $Row.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Highlight
        $Row.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::HighlightText
    }
}

function Update-TargetGridSelectionCounter {
    param(
        [System.Windows.Forms.Label]$Label,
        [System.Windows.Forms.DataGridView]$Grid
    )
    if ($null -eq $Label -or $null -eq $Grid) {
        return
    }
    $count = @(Get-SelectedTargetEntries @(Get-TargetGridRows $Grid)).Count
    $Label.Text = ("{0} target(s) selected" -f $count)
}

function Update-TargetCreateFileEditability {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $kind = [string]$Row.Cells["Kind"].Value
    $isTestFile = $kind -eq "Test file"
    $isFilesystem = $kind -eq "Filesystem"
    $Row.Cells["CreateFile"].ReadOnly = -not $isTestFile
    if ($isFilesystem) {
        $Row.Cells["CreateFile"].Value = $false
        $Row.Cells["CreateFile"].ToolTipText = "vdbench creates test files at run time from profile fsd.* parameters - no extra action needed here"
        $Row.Cells["Kind"].ToolTipText = $Row.Cells["CreateFile"].ToolTipText
        return
    }
    $Row.Cells["Kind"].ToolTipText = ""
    $Row.Cells["CreateFile"].ToolTipText = ""
    if (-not $isTestFile) {
        $Row.Cells["CreateFile"].Value = $false
        return
    }
    if ([bool](Get-PropertyValue $Row.Cells["Selected"].Value $false)) {
        $Row.Cells["CreateFile"].Value = $true
    }
}

function Refresh-LocalHostTab {
    param([switch]$ForceInventory)
    if ($null -eq $script:LocalHostInfoBox) {
        return
    }
    Capture-Settings
    if (-not $script:RefreshingLocalTargets) {
        Capture-LocalHostTargets
    }
    $computer = [string]$env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) {
        $computer = "localhost"
    }
    $osCaption = "Windows"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = [string]$os.Caption
    } catch {
    }
    $paths = @(
        @{ Name = "Vdbench root"; Path = [string](Get-PropertyValue $script:Settings "VdbenchRoot" "") },
        @{ Name = "Master runner"; Path = [string](Get-PropertyValue $script:Settings "MasterVdbenchBat" "") },
        @{ Name = "Reports root"; Path = [string](Get-PropertyValue $script:Settings "ReportsRoot" "") }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Local single-host run")
    [void]$lines.Add("====================")
    [void]$lines.Add(("Computer: {0}" -f $computer))
    [void]$lines.Add(("OS: {0}" -f $osCaption))
    [void]$lines.Add(("Run mode: {0}" -f (Get-Mode)))
    [void]$lines.Add("")
    [void]$lines.Add("Master paths on this host:")
    foreach ($item in $paths) {
        $exists = $false
        if (-not [string]::IsNullOrWhiteSpace($item.Path)) {
            $exists = Test-Path -LiteralPath $item.Path
        }
        [void]$lines.Add(("{0,-16} {1,-55} Exists={2}" -f $item.Name, $item.Path, $exists))
    }
    [void]$lines.Add("")
    [void]$lines.Add("Select one or more local raw/file or filesystem targets below.")
    [void]$lines.Add("Selections are stored in localhost.json and used by the Run tab.")
    $script:LocalHostInfoBox.Text = ($lines -join [Environment]::NewLine)

    if ($null -eq $script:LocalHostTargetGrid) {
        return
    }
    try {
        $existing = @(Get-LocalHostTargetStore)
        $targets = @(Merge-TargetSelections (Get-LocalTargetInventory -Force:$ForceInventory) $existing)
        $script:RefreshingLocalTargets = $true
        try {
            Set-TargetGridRows $script:LocalHostTargetGrid $targets
            foreach ($row in $script:LocalHostTargetGrid.Rows) {
                Update-TargetCreateFileEditability $row
            }
        } finally {
            $script:RefreshingLocalTargets = $false
        }
    } catch {
        Invoke-GridBatchUpdate $script:LocalHostTargetGrid {
            $script:LocalHostTargetGrid.Rows.Clear()
            $idx = $script:LocalHostTargetGrid.Rows.Add()
            $row = $script:LocalHostTargetGrid.Rows[$idx]
            $row.Cells["Selected"].Value = $false
            $row.Cells["Kind"].Value = "Error"
            $row.Cells["Target"].Value = ""
            $row.Cells["CreateFile"].Value = $false
            $row.Cells["Description"].Value = $_.Exception.Message
        }
    }
}

function Capture-LocalHostTargets {
    if ($null -eq $script:LocalHostTargetGrid) {
        return
    }
    if ($script:RefreshingLocalTargets) {
        return
    }
    $script:LocalHostTargets = @(Get-TargetGridRows $script:LocalHostTargetGrid)
    Save-LocalHostTargets
}

function Apply-LocalHostTargetSelections {
    Capture-LocalHostTargets
    Request-ProfileTargetContextSync "local-host-save"
    Show-Info "Local target selections saved."
}

function Test-RunModeTabDisabled {
    param([System.Windows.Forms.TabPage]$Page)
    if ($null -eq $Page) {
        return $false
    }
    $distributed = Is-DistributedMode
    if ($Page -eq $script:LocalHostTab) {
        return $distributed
    }
    if ($Page -eq $script:MasterSlaveTab) {
        return -not $distributed
    }
    return $false
}

function Update-RunModeTabs {
    if ($null -eq $script:MainTabControl) {
        return
    }
    $distributed = Is-DistributedMode
    if ($null -ne $script:LocalHostTab) {
        $script:LocalHostTab.Enabled = -not $distributed
    }
    if ($null -ne $script:MasterSlaveTab) {
        $script:MasterSlaveTab.Enabled = $distributed
    }
    if ($distributed) {
        if ($null -ne $script:LocalHostTab -and $script:MainTabControl.SelectedTab -eq $script:LocalHostTab) {
            $script:MainTabControl.SelectedTab = $script:MasterSlaveTab
        }
    } else {
        if ($null -ne $script:MasterSlaveTab -and $script:MainTabControl.SelectedTab -eq $script:MasterSlaveTab) {
            $script:MainTabControl.SelectedTab = $script:LocalHostTab
        }
        Refresh-LocalHostTab
    }
    $script:MainTabControl.Invalidate()
}

function Build-LocalHostTab {
    $tab = New-MainTabPage "Local Host" "Local"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 70)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 185)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-FlowToolbar
    $refreshButton = New-Button "Refresh targets" 10 8 120 28
    $refreshButton.Add_Click({ Refresh-LocalHostTab -ForceInventory })
    $toolbar.Controls.Add($refreshButton)

    $applyButton = New-Button "Save selections" 138 8 120 28
    $applyButton.Add_Click({ Apply-LocalHostTargetSelections })
    Set-ControlToolTip $applyButton "Persist selected local targets in localhost.json."
    $toolbar.Controls.Add($applyButton)

    $validateButton = New-Button "Validate paths" 266 8 110 28
    $validateButton.Add_Click({
        Validate-SettingsPaths
        Refresh-LocalHostTab
    })
    $toolbar.Controls.Add($validateButton)

    $exploreButton = New-Button "Explore" 384 8 90 28
    $exploreButton.Add_Click({
        try {
            $existing = @(Get-LocalHostTargetStore)
            $initial = ""
            foreach ($item in $existing) {
                if ([string](Get-PropertyValue $item "Kind" "") -eq "Filesystem") {
                    $candidate = [string](Get-PropertyValue $item "Target" "")
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $initial = $candidate
                        break
                    }
                }
            }
            $picked = Show-HostPathBrowser -InitialPath $initial
            if ($null -eq $picked) {
                return
            }
            $entry = New-TargetSelection -Kind ([string]$picked.Kind) -Target ([string]$picked.Target) -Description ([string]$picked.Description) -Selected $true
            $merged = @(Merge-TargetSelections (Get-LocalTargetInventory) @(Merge-TargetSelections @($entry) $existing))
            $script:RefreshingLocalTargets = $true
            try {
                Set-TargetGridRows $script:LocalHostTargetGrid $merged
                foreach ($row in $script:LocalHostTargetGrid.Rows) {
                    Update-TargetCreateFileEditability $row
                }
            } finally {
                $script:RefreshingLocalTargets = $false
            }
            Capture-LocalHostTargets
            Request-ProfileTargetContextSync "local-host-explore"
        } catch {
            Show-Warning ("Explore failed: " + $_.Exception.Message)
        }
    })
    $toolbar.Controls.Add($exploreButton)

    $note = New-Label "Active when Run mode = Single local run. Refresh lists drive roots; Explore opens folders and files. Check Use for each target." 0 0 900 40
    $toolbar.Controls.Add($note)
    $container.Controls.Add($toolbar, 0, 0)

    $script:LocalHostInfoBox = New-Object System.Windows.Forms.TextBox
    $script:LocalHostInfoBox.Multiline = $true
    $script:LocalHostInfoBox.ReadOnly = $true
    $script:LocalHostInfoBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:LocalHostInfoBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:LocalHostInfoBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $container.Controls.Add($script:LocalHostInfoBox, 0, 1)

    $script:LocalHostTargetGrid = New-Object System.Windows.Forms.DataGridView
    $script:LocalHostTargetGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:LocalHostTargetGrid.AllowUserToAddRows = $false
    $script:LocalHostTargetGrid.AllowUserToDeleteRows = $false
    $script:LocalHostTargetGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:LocalHostTargetGrid.MultiSelect = $false
    $script:LocalHostTargetGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    Add-TargetSelectionColumns $script:LocalHostTargetGrid
    Register-TargetSelectionGridHandlers -Grid $script:LocalHostTargetGrid -OnRowChanged {
        param($Grid, $Row)
        if ($script:RefreshingLocalTargets) {
            return
        }
        try {
            Capture-LocalHostTargets
            Request-ProfileTargetContextSync "local-host-grid"
        } catch {
            Write-AppLog ("Local host target selection failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    }
    $container.Controls.Add($script:LocalHostTargetGrid, 0, 2)
    Refresh-LocalHostTab
    return $tab
}

function Show-ParameterHelp {
    param([object]$Definition)
    $message = @(
        ("Parameter: {0}" -f $Definition.Label),
        ("Vdbench name: {0}" -f $Definition.VdbenchName),
        ("Section: {0}" -f $Definition.Section),
        "",
        [string]$Definition.Help,
        "",
        ("Example: {0}" -f $Definition.Example),
        "",
        "Disable behavior: clearing Enabled keeps the value in the profile but comments it out in generated config."
    ) -join [Environment]::NewLine
    Show-Info $message "Parameter help"
}

function Test-ProfileTabSelected {
    if ($null -eq $script:MainTabControl) {
        return $false
    }
    $selected = $script:MainTabControl.SelectedTab
    if ($null -eq $selected) {
        return $false
    }
    return (Get-MainTabFullTitle $selected) -eq "Profile Builder"
}

function Set-ProfileToolbarLockState {
    param([bool]$Locked)
    $script:ProfileEditorLocked = $Locked
    foreach ($button in @($script:ProfileNewButton, $script:ProfileSaveButton, $script:ProfilePreviewButton)) {
        if ($null -ne $button) {
            $button.Enabled = -not $Locked
        }
    }
    if ($null -ne $script:ProfileNameBox) {
        $script:ProfileNameBox.Enabled = -not $Locked
        if ($Locked) {
            $script:ProfileNameBox.BackColor = [System.Drawing.SystemColors]::Control
        } else {
            $script:ProfileNameBox.BackColor = [System.Drawing.SystemColors]::Window
        }
    }
}

function Set-ProfileEditorBanner {
    param(
        [bool]$Locked,
        [string]$Message
    )
    if ($null -eq $script:ProfileEditorBanner) {
        return
    }
    if ($Locked) {
        $script:ProfileEditorBanner.Text = [string]$Message
        $script:ProfileEditorBanner.ForeColor = [System.Drawing.Color]::Firebrick
        $script:ProfileEditorBanner.Visible = $true
    } else {
        $script:ProfileEditorBanner.Text = ("Editing profile parameters for derived test kind: {0}" -f $script:ProfileEditorTestKind)
        $script:ProfileEditorBanner.ForeColor = [System.Drawing.Color]::DarkGreen
        $script:ProfileEditorBanner.Visible = $true
    }
}

function Add-ProfileEditorSectionTab {
    param(
        [string]$Section,
        [bool]$ReadOnly
    )
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Section
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $tab.Controls.Add($panel)

    $y = 16
    $headers = @(
        @{ Text = "State"; X = 12; W = 75 },
        @{ Text = "Parameter"; X = 96; W = 210 },
        @{ Text = "Help"; X = 310; W = 40 },
        @{ Text = "Value"; X = 350; W = 220 },
        @{ Text = "Vdbench"; X = 590; W = 120 },
        @{ Text = "Line"; X = 720; W = 120 }
    )
    foreach ($header in $headers) {
        $h = New-Label $header.Text $header.X $y $header.W
        $h.Font = New-Object System.Drawing.Font -ArgumentList $h.Font, ([System.Drawing.FontStyle]::Bold)
        $h.Enabled = -not $ReadOnly
        $panel.Controls.Add($h)
    }
    $y += 30
    $lastGroup = ""
    $defs = @($script:Catalog | Where-Object { [string]$_.Section -eq $Section } | Sort-Object {
        [int](Get-PropertyValue $_ "SortOrder" 9999)
    })
    foreach ($def in $defs) {
        if ([bool](Get-PropertyValue $def "EditorHidden" $false)) {
            continue
        }
        if (-not (Definition-AppliesToKind $def $script:ProfileEditorTestKind)) {
            continue
        }
        $group = [string](Get-PropertyValue $def "Group" "")
        if (-not [string]::IsNullOrWhiteSpace($group) -and $group -ne $lastGroup) {
            $groupLabel = New-Label $group 12 $y 900
            $groupLabel.Font = New-Object System.Drawing.Font -ArgumentList $groupLabel.Font, ([System.Drawing.FontStyle]::Bold)
            $groupLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
            $groupLabel.Enabled = -not $ReadOnly
            $panel.Controls.Add($groupLabel)
            $y += 24
            $lastGroup = $group
        }
        $targetDerived = [bool](Get-PropertyValue $def "TargetDerived" $false)
        Add-ParameterRow $panel $def $y -ReadOnly:$ReadOnly -TargetDerived:$targetDerived
        $y += 32
    }
    $script:ProfileParamTabs.TabPages.Add($tab) | Out-Null
}

function Add-ParameterRow {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [object]$Definition,
        [int]$Y,
        [bool]$ReadOnly = $false,
        [bool]$TargetDerived = $false
    )
    $key = [string]$Definition.Key
    $param = Get-ProfileParam $script:CurrentProfile $key
    $rowReadOnly = $ReadOnly -or $TargetDerived

    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = "Enabled"
    if ($TargetDerived) {
        $enabled.Checked = $true
        $enabled.Enabled = $false
    } else {
        $enabled.Checked = [bool]$param.Enabled
        $enabled.Enabled = -not $ReadOnly
    }
    $enabled.Location = New-Object System.Drawing.Point -ArgumentList 12, $Y
    $enabled.Size = New-Object System.Drawing.Size -ArgumentList 78, 24
    $Panel.Controls.Add($enabled)

    $label = New-Label ([string]$Definition.Label) 96 $Y 210
    $label.Enabled = -not $rowReadOnly
    $Panel.Controls.Add($label)

    $helpButton = New-Button "?" 310 ($Y - 1) 28 24
    $helpButton.Enabled = -not $rowReadOnly
    $helpButton.Tag = $Definition
    $helpButton.Add_Click({
        param($sender, $eventArgs)
        Show-ParameterHelp $sender.Tag
    })
    $Panel.Controls.Add($helpButton)

    $type = [string](Get-PropertyValue $Definition "Type" "text")
    $displayValue = if ($TargetDerived) {
        Get-ProfileTargetDisplayValue $key
    } else {
        [string]$param.Value
    }
    $valueControl = $null
    if ($type -eq "dropdown" -and -not $TargetDerived) {
        $items = @()
        foreach ($option in @($Definition.Options)) {
            $items += [string]$option
        }
        $valueControl = New-ComboBox $items $displayValue 350 $Y 220
    } else {
        $valueControl = New-TextBox $displayValue 350 $Y 220
    }
    $valueControl.Enabled = -not $rowReadOnly
    if ($TargetDerived) {
        $valueControl.ReadOnly = $true
        $valueControl.BackColor = [System.Drawing.Color]::WhiteSmoke
    }
    $Panel.Controls.Add($valueControl)

    $vdName = New-Label ([string]$Definition.VdbenchName) 590 $Y 120
    $vdName.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($vdName)

    $line = New-Label ([string]$Definition.Line) 720 $Y 120
    $line.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($line)

    if (-not $TargetDerived) {
        $script:ParameterControls[$key] = [pscustomobject]@{
            Enabled = $enabled
            Value = $valueControl
            Definition = $Definition
        }
    }
}
function Capture-ProfileEditor {
    if ($script:ProfileEditorLocked) {
        return
    }
    if ($null -eq $script:CurrentProfile) {
        return
    }
    if ($script:ProfileNameBox) {
        $script:CurrentProfile.Name = [string]$script:ProfileNameBox.Text
    }
    foreach ($key in $script:ParameterControls.Keys) {
        $entry = $script:ParameterControls[$key]
        if ($null -eq $entry -or $null -eq $entry.Enabled) {
            continue
        }
        if ($entry.Enabled.IsDisposed) {
            continue
        }
        Set-ProfileParamEnabled $script:CurrentProfile $key ([bool]$entry.Enabled.Checked)
        Set-ProfileParamValue $script:CurrentProfile $key ([string]$entry.Value.Text)
    }
    if ($script:AdvancedActiveBox) {
        $script:CurrentProfile.AdvancedActive = $script:AdvancedActiveBox.Text
    }
    if ($script:AdvancedDisabledBox) {
        $script:CurrentProfile.AdvancedDisabled = $script:AdvancedDisabledBox.Text
    }
    $resolved = Resolve-RunTestKind
    $testKind = [string]$resolved.TestKind
    if (-not [string]::IsNullOrWhiteSpace($testKind)) {
        Sync-EditorProfileParametersToCommon $script:CurrentProfile $testKind
    } else {
        Sync-CommonProfileParameters $script:CurrentProfile
    }
}

function Test-RunMonitorTabSelected {
    if ($null -eq $script:MainTabControl) {
        return $false
    }
    $selected = $script:MainTabControl.SelectedTab
    if ($null -eq $selected) {
        return $false
    }
    return (Get-MainTabFullTitle $selected) -eq "Run Monitor"
}

function Initialize-ProfileTargetContextDebounceTimer {
    if ($null -ne $script:ProfileTargetContextDebounceTimer) {
        return
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $script:ProfileTargetContextDebounceTimer = $timer
    $timer.Add_Tick({
        try {
            $script:ProfileTargetContextDebounceTimer.Stop()
            $source = [string]$script:ProfileTargetContextDebounceSource
            $script:ProfileTargetContextDebounceSource = ""
            Sync-ProfileEditorTargetContext -ChangeSource $source
        } catch {
            Write-AppLog ("Profile target context debounce failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    })
}

function Request-ProfileTargetContextSync {
    param([string]$Source = "unknown")
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $script:ProfileTargetContextDebounceSource = $Source
    }
    Initialize-ProfileTargetContextDebounceTimer
    $script:ProfileTargetContextDebounceTimer.Stop()
    $script:ProfileTargetContextDebounceTimer.Start()
}

function Sync-ProfileEditorTargetContext {
    param([string]$ChangeSource = "target-context")
    if ($script:RefreshingProfileEditor) {
        $script:ProfileEditorRefreshPending = $true
        if (-not [string]::IsNullOrWhiteSpace($ChangeSource)) {
            $script:ProfileEditorRefreshPendingSource = $ChangeSource
        }
        return
    }

    $context = Get-ProfileEditorContext
    $newLocked = [bool]$context.Locked
    $newTestKind = [string]$context.TestKind
    $oldLocked = [bool]$script:ProfileEditorLocked
    $oldTestKind = [string]$script:ProfileEditorLastTestKind
    $needsFullRefresh = ($newLocked -ne $oldLocked) -or ($newTestKind -ne $oldTestKind)

    Write-DebugLog ("Sync-ProfileEditorTargetContext: source={0}; fullRefresh={1}; locked={2}->{3}; testKind={4}->{5}" -f $ChangeSource, $needsFullRefresh, $oldLocked, $newLocked, $oldTestKind, $newTestKind)

    $script:ProfileEditorLocked = $newLocked
    $script:ProfileEditorTestKind = $newTestKind
    if (-not [string]::IsNullOrWhiteSpace($newTestKind)) {
        $script:ProfileEditorLastTestKind = $newTestKind
    }

    if ($needsFullRefresh -and (Test-ProfileTabSelected)) {
        Refresh-ProfileEditor -ChangeSource $ChangeSource
        return
    }

    if (Test-ProfileTabSelected) {
        Set-ProfileToolbarLockState $newLocked
        Set-ProfileEditorBanner $newLocked ([string]$context.Message)
    }

    Refresh-ConfigPreview
    Update-RunModeIndicator
}

function Refresh-ProfileEditor {
    param([string]$ChangeSource = "manual")

    if ($script:RefreshingProfileEditor) {
        $script:ProfileEditorRefreshPending = $true
        if (-not [string]::IsNullOrWhiteSpace($ChangeSource)) {
            $script:ProfileEditorRefreshPendingSource = $ChangeSource
        }
        return
    }

    Write-DebugLog ("Refresh-ProfileEditor start: source={0}" -f $ChangeSource)
    $script:RefreshingProfileEditor = $true
    try {
        if ($null -eq $script:CurrentProfile) {
            $script:CurrentProfile = New-DefaultProfile "New-Profile"
        }
        if (-not $script:ProfileEditorLocked) {
            Capture-ProfileEditor
        }

        $context = Get-ProfileEditorContext
        $script:ProfileEditorLocked = [bool]$context.Locked
        $script:ProfileEditorTestKind = [string]$context.TestKind
        Write-DebugLog ("Profile editor context: locked={0}; testKind={1}; sections={2}; resolvedError={3}" -f $context.Locked, $context.TestKind, ($context.VisibleSections -join ","), [string]$context.Resolved.Error)

        if (-not [string]::IsNullOrWhiteSpace($context.TestKind)) {
            $script:ProfileEditorLastTestKind = [string]$context.TestKind
        }

        $script:ParameterControls = @{}
        if ($script:ProfileNameBox) {
            $script:ProfileNameBox.Text = [string]$script:CurrentProfile.Name
        }
        Set-ProfileToolbarLockState $context.Locked
        Set-ProfileEditorBanner $context.Locked ([string]$context.Message)
        if ($script:ProfileParamTabs) {
            $script:ProfileParamTabs.TabPages.Clear()
        }

        if ($context.Locked) {
            $lockedTab = New-Object System.Windows.Forms.TabPage
            $lockedTab.Text = "Parameters"
            $lockedPanel = New-Object System.Windows.Forms.Panel
            $lockedPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $lockedPanel.AutoScroll = $true
            $lockedTab.Controls.Add($lockedPanel)
            $lockedLabel = New-Label ([string]$context.Message) 16 24 1040 80
            $lockedLabel.ForeColor = [System.Drawing.Color]::Firebrick
            $lockedLabel.Font = New-Object System.Drawing.Font -ArgumentList $lockedLabel.Font, ([System.Drawing.FontStyle]::Bold)
            $lockedPanel.Controls.Add($lockedLabel)
            $script:ProfileParamTabs.TabPages.Add($lockedTab) | Out-Null
            $script:ProfileParamTabs.Enabled = $false
        } else {
            $script:ProfileParamTabs.Enabled = $true
            foreach ($section in @($context.VisibleSections)) {
                Add-ProfileEditorSectionTab $section $false
            }

            $advTab = New-Object System.Windows.Forms.TabPage
            $advTab.Text = "Advanced manual lines"
            $advPanel = New-Object System.Windows.Forms.Panel
            $advPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $advPanel.AutoScroll = $true
            $advTab.Controls.Add($advPanel)

            $advPanel.Controls.Add((New-Label "Active manual Vdbench lines" 12 12 260))
            $script:AdvancedActiveBox = New-Object System.Windows.Forms.TextBox
            $script:AdvancedActiveBox.Multiline = $true
            $script:AdvancedActiveBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
            $script:AdvancedActiveBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
            $script:AdvancedActiveBox.Text = [string](Get-PropertyValue $script:CurrentProfile "AdvancedActive" "")
            $script:AdvancedActiveBox.Location = New-Object System.Drawing.Point -ArgumentList 12, 40
            $script:AdvancedActiveBox.Size = New-Object System.Drawing.Size -ArgumentList 950, 190
            $advPanel.Controls.Add($script:AdvancedActiveBox)

            $advPanel.Controls.Add((New-Label "Disabled/commented manual lines" 12 250 260))
            $script:AdvancedDisabledBox = New-Object System.Windows.Forms.TextBox
            $script:AdvancedDisabledBox.Multiline = $true
            $script:AdvancedDisabledBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
            $script:AdvancedDisabledBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
            $script:AdvancedDisabledBox.Text = [string](Get-PropertyValue $script:CurrentProfile "AdvancedDisabled" "")
            $script:AdvancedDisabledBox.Location = New-Object System.Drawing.Point -ArgumentList 12, 278
            $script:AdvancedDisabledBox.Size = New-Object System.Drawing.Size -ArgumentList 950, 190
            $advPanel.Controls.Add($script:AdvancedDisabledBox)

            $script:ProfileParamTabs.TabPages.Add($advTab) | Out-Null
        }

        Refresh-ConfigPreview
        Update-RunModeIndicator
        Write-DebugLog "Refresh-ProfileEditor completed"
    } catch {
        Write-AppLog ("Refresh-ProfileEditor failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        Show-Warning ("Profile editor refresh failed: " + $_.Exception.Message)
    } finally {
        $script:RefreshingProfileEditor = $false
        if ($script:ProfileEditorRefreshPending) {
            $script:ProfileEditorRefreshPending = $false
            $pendingSource = [string]$script:ProfileEditorRefreshPendingSource
            $script:ProfileEditorRefreshPendingSource = ""
            if ([string]::IsNullOrWhiteSpace($pendingSource)) {
                $pendingSource = "pending"
            }
            Refresh-ProfileEditor -ChangeSource $pendingSource
        }
    }
}

function Refresh-RunProfileList {
    if (-not $script:RunProfileSelector) {
        return
    }
    $current = [string]$script:RunProfileSelector.Text
    $script:SuppressRunProfileSelectorEvents = $true
    try {
        $script:RunProfileSelector.Items.Clear()
        foreach ($name in Get-ProfileNames) {
            [void]$script:RunProfileSelector.Items.Add($name)
        }
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $script:RunProfileSelector.Text = $current
        } elseif ($script:RunProfileSelector.Items.Count -gt 0) {
            $preferred = @("Default-Filesystem-Random-Read", "Default-Distributed-WP", "Default-Filesystem-Format")
            $picked = $null
            foreach ($name in $preferred) {
                if ($script:RunProfileSelector.Items.Contains($name)) {
                    $picked = $name
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($picked)) {
                $picked = [string]$script:RunProfileSelector.Items[0]
            }
            $script:RunProfileSelector.Text = $picked
        }
    } finally {
        $script:SuppressRunProfileSelectorEvents = $false
    }
    Sync-RunProfileFromSelector
}

function Preview-DraftProfile {
    if ($script:ProfileEditorLocked) {
        Show-Warning "Select a target before previewing a draft profile."
        return
    }
    if ($null -eq $script:CurrentProfile) {
        return
    }
    Capture-ProfileEditor
    Sync-CommonProfileParameters $script:CurrentProfile
    try {
        $built = Build-VdbenchConfig -UseDraftProfile
        $script:LastBuiltConfig = $built
        $prefix = ""
        if ($built.Warnings.Count -gt 0) {
            $prefix = ("* DRAFT PREVIEW WARNINGS" + [Environment]::NewLine)
            foreach ($warning in $built.Warnings) {
                $prefix += ("* - " + $warning + [Environment]::NewLine)
            }
            $prefix += [Environment]::NewLine
        }
        if ($script:ConfigPreviewBox) {
            $script:ConfigPreviewBox.Text = $prefix + $built.Text
        }
        Select-MainTab "Config Preview"
    } catch {
        if ($script:ConfigPreviewBox) {
            $script:ConfigPreviewBox.Text = "Draft preview error: " + $_.Exception.Message
        }
        Write-AppLog ("Draft preview error: {0}" -f $_.Exception.Message) "ERROR"
    }
}

function Build-ProfileTab {
    $tab = New-MainTabPage "Profile Builder" "Profile"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 60)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 28)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-FlowToolbar
    $container.Controls.Add($toolbar, 0, 0)

    $script:ProfileNewButton = New-Button "New" 10 9 70 27
    $script:ProfileNewButton.Add_Click({ Initialize-NewDraftProfile })
    $toolbar.Controls.Add($script:ProfileNewButton)

    $script:ProfileSaveButton = New-Button "Save profile" 88 9 105 27
    $script:ProfileSaveButton.Add_Click({ Save-CurrentProfile })
    $toolbar.Controls.Add($script:ProfileSaveButton)

    $script:ProfilePreviewButton = New-Button "Preview draft" 201 9 110 27
    $script:ProfilePreviewButton.Add_Click({ Preview-DraftProfile })
    $toolbar.Controls.Add($script:ProfilePreviewButton)

    $toolbar.Controls.Add((New-Label "Name" 330 12 50))
    $script:ProfileNameBox = New-TextBox "" 382 9 360
    $toolbar.Controls.Add($script:ProfileNameBox)

    $note = New-Label "Create new workload profiles here. Parameter groups follow the selected target type from Local Host or Master/Slave tabs." 10 38 1040 18
    $toolbar.Controls.Add($note)

    $script:ProfileEditorBanner = New-Label "Select a target to edit profile parameters." 10 4 1040 20
    $script:ProfileEditorBanner.ForeColor = [System.Drawing.Color]::Firebrick
    $container.Controls.Add($script:ProfileEditorBanner, 0, 1)

    $script:ProfileParamTabs = New-Object System.Windows.Forms.TabControl
    $script:ProfileParamTabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($script:ProfileParamTabs, 0, 2)

    Refresh-ProfileEditor -ChangeSource "profile-tab-init"
    return $tab
}
function Build-PreviewTab {
    $tab = New-MainTabPage "Config Preview" "Preview"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $refreshButton = New-Button "Refresh" 10 8 85 28
    $refreshButton.Add_Click({ Refresh-ConfigPreview })
    $toolbar.Controls.Add($refreshButton)

    $copyButton = New-Button "Copy config" 104 8 100 28
    $copyButton.Add_Click({
        try {
            $clean = Get-CleanConfigText
            [System.Windows.Forms.Clipboard]::SetText($clean)
        } catch {
            Show-Warning ("Copy failed: " + $_.Exception.Message)
        }
    })
    $toolbar.Controls.Add($copyButton)

    $script:ConfigPreviewBox = New-Object System.Windows.Forms.TextBox
    $script:ConfigPreviewBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ConfigPreviewBox.Multiline = $true
    $script:ConfigPreviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:ConfigPreviewBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:ConfigPreviewBox.WordWrap = $false
    $container.Controls.Add($script:ConfigPreviewBox, 0, 1)
    return $tab
}
function Open-CurrentRunFolder {
    if ([string]::IsNullOrWhiteSpace($script:CurrentRunId)) {
        Show-Warning "No current run."
        return
    }
    $path = Join-Path $script:RunStateRoot ($script:CurrentRunId + ".json")
    $state = Read-JsonFile $path $null
    $runDir = [string](Get-PropertyValue $state "RunDir" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($runDir) -and (Test-Path -LiteralPath $runDir)) {
        Start-Process $runDir
    }
}

function Build-RunTab {
    $tab = New-MainTabPage "Run Monitor" "Run"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 4
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 48)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 185)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 210)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $startButton = New-Button "Start" 10 10 80 28
    $startButton.Add_Click({ Invoke-UiSafe { Start-VdbenchRun } "Start run" })
    $toolbar.Controls.Add($startButton)

    $configOnlyButton = New-Button "Config only" 100 10 95 28
    $configOnlyButton.Add_Click({ New-ConfigOnlyRun })
    $toolbar.Controls.Add($configOnlyButton)

    $stopButton = New-Button "Stop/Kill" 205 10 90 28
    $stopButton.Add_Click({ Stop-VdbenchRun })
    $toolbar.Controls.Add($stopButton)

    $openButton = New-Button "Open folder" 305 10 100 28
    $openButton.Add_Click({ Open-CurrentRunFolder })
    $toolbar.Controls.Add($openButton)

    $script:RunStatusLabel = New-Label "Idle" 425 13 600
    $toolbar.Controls.Add($script:RunStatusLabel)

    $orchestrator = New-Object System.Windows.Forms.Panel
    $orchestrator.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($orchestrator, 0, 1)

    $orchestrator.Controls.Add((New-Label "Run profile" 10 10 80))
    $script:RunProfileSelector = New-ComboBox @() "" 95 8 280
    $script:RunProfileSelector.Add_SelectedIndexChanged({
        if ($script:SuppressRunProfileSelectorEvents) {
            return
        }
        Invoke-UiSafe {
            Sync-RunProfileFromSelector
            Update-RunModeIndicator
            Refresh-ConfigPreview
        } "Run profile selection"
    })
    $orchestrator.Controls.Add($script:RunProfileSelector)

    $reloadButton = New-Button "Reload" 385 7 75 27
    $reloadButton.Add_Click({ Reload-RunProfile })
    $orchestrator.Controls.Add($reloadButton)

    $deleteButton = New-Button "Delete" 10 40 75 27
    $deleteButton.Add_Click({ Delete-SelectedProfile })
    $orchestrator.Controls.Add($deleteButton)

    $duplicateButton = New-Button "Duplicate" 92 40 85 27
    $duplicateButton.Add_Click({ Duplicate-RunProfile })
    $orchestrator.Controls.Add($duplicateButton)

    $importButton = New-Button "Import" 184 40 75 27
    $importButton.Add_Click({ Import-Profile })
    $orchestrator.Controls.Add($importButton)

    $exportButton = New-Button "Export" 266 40 75 27
    $exportButton.Add_Click({ Export-RunProfile })
    $orchestrator.Controls.Add($exportButton)

    $folderButton = New-Button "Folder" 348 40 75 27
    $folderButton.Add_Click({ Open-ProfileFolder })
    $orchestrator.Controls.Add($folderButton)

    $orchestrator.Controls.Add((New-Label "Run summary" 10 74 90))
    $script:RunSummaryBox = New-Object System.Windows.Forms.TextBox
    $script:RunSummaryBox.Multiline = $true
    $script:RunSummaryBox.ReadOnly = $true
    $script:RunSummaryBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:RunSummaryBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 9
    $script:RunSummaryBox.Location = New-Object System.Drawing.Point -ArgumentList 10, 96
    $script:RunSummaryBox.Size = New-Object System.Drawing.Size -ArgumentList 1120, 78
    $orchestrator.Controls.Add($script:RunSummaryBox)

    Refresh-RunProfileList
    Refresh-RunTabSummary

    $script:RunChart = New-RunChart
    if ($script:RunChart) {
        $container.Controls.Add($script:RunChart, 0, 2)
    } else {
        $chartFallback = New-Object System.Windows.Forms.TextBox
        $chartFallback.Dock = [System.Windows.Forms.DockStyle]::Fill
        $chartFallback.Multiline = $true
        $chartFallback.ReadOnly = $true
        $chartFallback.Text = "Chart assembly is not available. Live Vdbench stdout is still shown below."
        $container.Controls.Add($chartFallback, 0, 2)
    }

    $script:RunLogBox = New-Object System.Windows.Forms.TextBox
    $script:RunLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:RunLogBox.Multiline = $true
    $script:RunLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:RunLogBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:RunLogBox.WordWrap = $false
    $container.Controls.Add($script:RunLogBox, 0, 3)

    return $tab
}

function Get-RunStates {
    $items = @()
    foreach ($file in @(Get-ChildItem -Path $script:RunStateRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $state = Read-JsonFile $file.FullName $null
        if ($state) {
            $items += $state
        }
    }
    return @($items | Sort-Object StartedAt -Descending)
}

function Refresh-Reports {
    if (-not $script:ReportsGrid) {
        return
    }
    Invoke-GridBatchUpdate $script:ReportsGrid {
        $script:ReportsGrid.Rows.Clear()
        foreach ($state in Get-RunStates) {
            $idx = $script:ReportsGrid.Rows.Add()
            $row = $script:ReportsGrid.Rows[$idx]
            foreach ($name in @("Id", "StartedAt", "Status", "ExitCode", "Profile", "Mode", "TestKind", "LastIops", "LastMbps", "LastLatency", "RunDir")) {
                $row.Cells[$name].Value = [string](Get-PropertyValue $state $name "")
            }
        }
    }
}

function Notify-RunFinished {
    param(
        [string]$RunId,
        [string]$Status
    )
    if ($script:RunFinishedNotified) {
        Refresh-Reports
        return
    }
    $script:RunFinishedNotified = $true
    if ($script:RunStatusLabel) {
        $label = switch ($Status) {
            "Killed" { "Killed" }
            "Failed" { "Failed" }
            "Completed" { "Finished" }
            default { "Finished" }
        }
        $script:RunStatusLabel.Text = ("{0}: {1}" -f $label, $RunId)
    }
    Refresh-Reports
}

function Open-SelectedReportFolder {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $row = $script:ReportsGrid.SelectedRows[0]
    $dir = [string]$row.Cells["RunDir"].Value
    if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath $dir)) {
        Start-Process $dir
    }
}

function Export-SelectedRunBundle {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        Show-Warning "Select a run first."
        return
    }
    $row = $script:ReportsGrid.SelectedRows[0]
    $runId = [string]$row.Cells["Id"].Value
    $dir = [string]$row.Cells["RunDir"].Value
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) {
        Show-Warning "Selected run folder does not exist."
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "ZIP archive (*.zip)|*.zip|All files (*.*)|*.*"
    $dialog.FileName = ("vdbench-run-{0}.zip" -f (Sanitize-FileName $runId))
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        if (Test-Path -LiteralPath $dialog.FileName) {
            Remove-Item -LiteralPath $dialog.FileName -Force
        }
        $source = Join-Path $dir "*"
        Compress-Archive -Path $source -DestinationPath $dialog.FileName -Force
        Show-Info ("Exported run bundle: {0}" -f $dialog.FileName)
    } catch {
        Show-Warning ("Run bundle export failed: " + $_.Exception.Message)
    }
}

function Show-SelectedRunConfig {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $script:ReportDetailBox.Text = ""
    $id = [string]$script:ReportsGrid.SelectedRows[0].Cells["Id"].Value
    $state = Read-JsonFile (Join-Path $script:RunStateRoot ($id + ".json")) $null
    $parmPath = [string](Get-PropertyValue $state "ParmPath" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($parmPath) -and (Test-Path -LiteralPath $parmPath)) {
        $script:ReportDetailBox.Text = [System.IO.File]::ReadAllText($parmPath)
    } else {
        $script:ReportDetailBox.Text = "No config available for selected run."
    }
}

function Show-SelectedRunLog {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $script:ReportDetailBox.Text = ""
    $id = [string]$script:ReportsGrid.SelectedRows[0].Cells["Id"].Value
    $state = Read-JsonFile (Join-Path $script:RunStateRoot ($id + ".json")) $null
    $stdoutPath = [string](Get-PropertyValue $state "StdoutPath" "")
    $stderrPath = [string](Get-PropertyValue $state "StderrPath" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($stdoutPath) -and (Test-Path -LiteralPath $stdoutPath)) {
        $text = [System.IO.File]::ReadAllText($stdoutPath)
        if (-not [string]::IsNullOrWhiteSpace($stderrPath) -and (Test-Path -LiteralPath $stderrPath)) {
            $text += [Environment]::NewLine + "===== stderr =====" + [Environment]::NewLine
            $text += [System.IO.File]::ReadAllText($stderrPath)
        }
        $script:ReportDetailBox.Text = $text
    } else {
        $script:ReportDetailBox.Text = "No log available for selected run."
    }
}

function Build-ReportsTab {
    $tab = New-MainTabPage "Status / Reports" "Reports"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 45)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 55)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $refreshButton = New-Button "Refresh" 10 8 80 28
    $refreshButton.Add_Click({ Refresh-Reports })
    $toolbar.Controls.Add($refreshButton)

    $openButton = New-Button "Open folder" 100 8 100 28
    $openButton.Add_Click({ Open-SelectedReportFolder })
    $toolbar.Controls.Add($openButton)

    $configButton = New-Button "Show config" 210 8 100 28
    $configButton.Add_Click({ Show-SelectedRunConfig })
    $toolbar.Controls.Add($configButton)

    $logButton = New-Button "Show logs" 320 8 90 28
    $logButton.Add_Click({ Show-SelectedRunLog })
    $toolbar.Controls.Add($logButton)

    $bundleButton = New-Button "Export ZIP" 420 8 95 28
    $bundleButton.Add_Click({ Export-SelectedRunBundle })
    $toolbar.Controls.Add($bundleButton)

    $script:ReportsGrid = New-Object System.Windows.Forms.DataGridView
    $script:ReportsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ReportsGrid.AllowUserToAddRows = $false
    $script:ReportsGrid.AllowUserToDeleteRows = $false
    $script:ReportsGrid.ReadOnly = $true
    $script:ReportsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:ReportsGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    foreach ($name in @("Id", "StartedAt", "Status", "ExitCode", "Profile", "Mode", "TestKind", "LastIops", "LastMbps", "LastLatency", "RunDir")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        $script:ReportsGrid.Columns.Add($col) | Out-Null
    }
    $script:ReportsGrid.Add_SelectionChanged({
        Show-SelectedRunLog
    })
    $container.Controls.Add($script:ReportsGrid, 0, 1)

    $script:ReportDetailBox = New-Object System.Windows.Forms.TextBox
    $script:ReportDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ReportDetailBox.Multiline = $true
    $script:ReportDetailBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:ReportDetailBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:ReportDetailBox.WordWrap = $false
    $container.Controls.Add($script:ReportDetailBox, 0, 2)

    Refresh-Reports
    return $tab
}

function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Vdbench UI - Portable Manager"
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF -ArgumentList 96, 96
    $form.Size = New-Object System.Drawing.Size -ArgumentList 1280, 820
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 1100, 700

    $script:AppToolTip = New-Object System.Windows.Forms.ToolTip
    $script:AppToolTip.AutoPopDelay = 12000
    $script:AppToolTip.InitialDelay = 400
    $script:AppToolTip.ReshowDelay = 200
    $script:AppToolTip.ShowAlways = $true

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.RowCount = 2
    $layout.ColumnCount = 1
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 36)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $form.Controls.Add($layout)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Height = 36
    $header.Controls.Add((New-Label "Run mode" 12 8 70))
    $script:RunModeCombo = New-ComboBox @("Single local run", "Master/Slave distributed run") ([string](Get-PropertyValue $script:Settings "RunMode" "Single local run")) 82 5 230 24
    $script:RunModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:RunModeCombo.Add_SelectedIndexChanged({
        Invoke-UiSafe {
            Sync-RunModeToSettings
            Request-ProfileTargetContextSync "run-mode"
        } "Run mode change"
    })
    $header.Controls.Add($script:RunModeCombo)
    $script:RunModeIndicator = New-Label "Profile: (none)  |  Test kind: (pending targets)" 322 8 900 20
    $script:RunModeIndicator.Font = New-Object System.Drawing.Font -ArgumentList $script:RunModeIndicator.Font, ([System.Drawing.FontStyle]::Bold)
    $header.Controls.Add($script:RunModeIndicator)
    $layout.Controls.Add($header, 0, 0)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabs.Multiline = $true
    $tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
    $tabs.ItemSize = New-Object System.Drawing.Size -ArgumentList 118, 28
    $tabs.Padding = New-Object System.Drawing.Point -ArgumentList 8, 4
    $layout.Controls.Add($tabs, 0, 1)
    $script:MainTabControl = $tabs

    $tabs.TabPages.Add((Build-SettingsTab)) | Out-Null
    $script:LocalHostTab = Build-LocalHostTab
    $tabs.TabPages.Add($script:LocalHostTab) | Out-Null
    $script:MasterSlaveTab = Build-MasterSlaveTab
    $tabs.TabPages.Add($script:MasterSlaveTab) | Out-Null
    $tabs.TabPages.Add((Build-ProfileTab)) | Out-Null
    $tabs.TabPages.Add((Build-PreviewTab)) | Out-Null
    $tabs.TabPages.Add((Build-RunTab)) | Out-Null
    $tabs.TabPages.Add((Build-ReportsTab)) | Out-Null
    Enable-MainTabToolTips $tabs

    $tabs.Add_DrawItem({
        param($sender, $eventArgs)
        $index = $eventArgs.Index
        $page = $sender.TabPages[$index]
        $disabled = Test-RunModeTabDisabled $page
        $selected = ($sender.SelectedIndex -eq $index)
        $tabRect = $sender.GetTabRect($index)
        $graphics = $eventArgs.Graphics
        $backColor = if ($disabled) {
            [System.Drawing.Color]::FromArgb(220, 220, 220)
        } elseif ($selected) {
            [System.Drawing.SystemColors]::Window
        } else {
            [System.Drawing.SystemColors]::Control
        }
        $foreColor = if ($disabled) {
            [System.Drawing.Color]::DimGray
        } else {
            [System.Drawing.SystemColors]::ControlText
        }
        $backBrush = New-Object System.Drawing.SolidBrush $backColor
        $graphics.FillRectangle($backBrush, $tabRect)
        $backBrush.Dispose()
        if ($selected) {
            $borderPen = New-Object System.Drawing.Pen ([System.Drawing.SystemColors]::ControlDark)
            $graphics.DrawLine($borderPen, $tabRect.Left, $tabRect.Bottom - 1, $tabRect.Right, $tabRect.Bottom - 1)
            $borderPen.Dispose()
        }
        $textRect = $tabRect
        $textRect.Inflate(-4, -2)
        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter `
            -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter `
            -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis `
            -bor [System.Windows.Forms.TextFormatFlags]::SingleLine `
            -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
        [System.Windows.Forms.TextRenderer]::DrawText($graphics, $page.Text, $sender.Font, $textRect, $foreColor, $textFlags)
    })

    $tabs.Add_Selecting({
        param($sender, $eventArgs)
        if (Test-RunModeTabDisabled $eventArgs.TabPage) {
            $eventArgs.Cancel = $true
        }
    })

    $tabs.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        Update-RunModeIndicator
        $selected = $sender.SelectedTab
        if ($null -eq $selected) {
            return
        }
        $title = Get-MainTabFullTitle $selected
        if ($title -eq "Config Preview") {
            Refresh-ConfigPreview
        }
        if ($title -eq "Status / Reports") {
            Refresh-Reports
        }
        if ($title -eq "Run Monitor") {
            Refresh-RunTabSummary
        }
        if ($title -eq "Profile Builder") {
            Refresh-ProfileEditor -ChangeSource "profile-tab-select"
        }
        if (-not (Is-DistributedMode) -and $selected -eq $script:LocalHostTab) {
            $deferRefresh = [System.Action]{ Refresh-LocalHostTab }
            $sender.BeginInvoke($deferRefresh) | Out-Null
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $script:UiRefreshTimer = $timer
    $timer.Add_Tick({
        try {
            $activeRun = ($null -ne $script:CurrentProcess -and -not $script:CurrentProcess.HasExited)
            if ($activeRun) {
                if ($script:UiRefreshTimer.Interval -ne 250) {
                    $script:UiRefreshTimer.Interval = 250
                }
                Flush-RunLog
                return
            }
            if ($script:UiRefreshTimer.Interval -ne 500) {
                $script:UiRefreshTimer.Interval = 500
            }
            if ($script:CurrentProcess -and $script:CurrentProcess.HasExited) {
                if (-not $script:RunFinishedNotified) {
                    $runId = [string]$script:CurrentRunId
                    $statePath = Join-Path $script:RunStateRoot ($runId + ".json")
                    $state = Read-JsonFile $statePath $null
                    $status = [string](Get-PropertyValue $state "Status" "")
                    if ($status -ne "Running") {
                        Notify-RunFinished -RunId $runId -Status $status
                    }
                }
            }
        } catch {
            Write-AppLog ("UI refresh timer failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    })
    $timer.Start()

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
            if (-not (Ask-YesNo "A Vdbench run is active. Close UI and leave/kill process manually?" "Active run")) {
                $eventArgs.Cancel = $true
                return
            }
        }
        Write-DebugLog "Main form closing"
    })
    $form.Add_FormClosed({
        Write-DebugLog "Main form closed"
    })

    Update-RunModeIndicator
    Update-RunModeTabs
    Apply-RunModeFromSettings
    return $form
}
