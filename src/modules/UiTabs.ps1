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
        @{ Key = "ReadinessChecker"; Label = "Readiness checker"; Browse = "file" },
        @{ Key = "MasterVdbenchBat"; Label = "Master vdbench.bat"; Browse = "file" },
        @{ Key = "WindowsVdbench"; Label = "Windows Vdbench path"; Browse = "folder"; Hint = "Default Vdbench path for Windows slaves." },
        @{ Key = "LinuxVdbench"; Label = "Linux Vdbench path"; Browse = "none"; Hint = "Default Vdbench path for Linux slaves." },
        @{ Key = "SshConfig"; Label = "SSH config"; Browse = "file" },
        @{ Key = "PrivateKey"; Label = "Private key"; Browse = "file" },
        @{ Key = "ReadinessCheckerArguments"; Label = "Readiness args template"; Browse = "none" },
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

    $panel.Controls.Add((New-Label "Run mode" 18 $y 180))
    $mode = New-ComboBox @("Single local run", "Master/Slave distributed run") ([string](Get-PropertyValue $script:Settings "RunMode" "Single local run")) 210 $y 250
    $mode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $mode.Add_SelectedIndexChanged({
        Capture-Settings
        Update-RunModeIndicator
        Refresh-ConfigPreview
    })
    $panel.Controls.Add($mode)
    $script:SettingsControls["RunMode"] = $mode
    $y += 34

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
    $selectedCol.FillWeight = 35
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
    $Grid.Columns.Add($createCol) | Out-Null
    $descCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $descCol.Name = "Description"
    $descCol.HeaderText = "Description"
    $descCol.ReadOnly = $true
    $Grid.Columns.Add($descCol) | Out-Null
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
            -Selected ([bool]$row.Cells["Selected"].Value) `
            -CreateFile ([bool]$row.Cells["CreateFile"].Value)
    }
    return @($targets)
}

function Update-TargetCreateFileEditability {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $isTestFile = ([string]$Row.Cells["Kind"].Value) -eq "Test file"
    $Row.Cells["CreateFile"].ReadOnly = -not $isTestFile
    if (-not $isTestFile) {
        $Row.Cells["CreateFile"].Value = $false
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
    [void]$lines.Add("Selections are stored in the active profile and survive refresh.")
    $script:LocalHostInfoBox.Text = ($lines -join [Environment]::NewLine)

    if ($null -eq $script:LocalHostTargetGrid) {
        return
    }
    try {
        $existing = @()
        if ($null -ne $script:CurrentProfile) {
            $existing = @(Get-PropertyValue $script:CurrentProfile "LocalTargets" @())
        }
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
    if ($null -eq $script:LocalHostTargetGrid -or $null -eq $script:CurrentProfile) {
        return
    }
    if ($script:RefreshingLocalTargets) {
        return
    }
    $script:CurrentProfile.LocalTargets = @(Get-TargetGridRows $script:LocalHostTargetGrid)
}

function Save-LocalHostTargets {
    if ($null -eq $script:CurrentProfile) {
        Show-Warning "Create or load a profile first."
        return
    }
    Capture-LocalHostTargets
    Save-CurrentProfile
    Refresh-ConfigPreview
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
    $applyButton.Add_Click({ Save-LocalHostTargets })
    Set-ControlToolTip $applyButton "Persist selected local targets in the active profile."
    $toolbar.Controls.Add($applyButton)

    $validateButton = New-Button "Validate paths" 266 8 110 28
    $validateButton.Add_Click({
        Validate-SettingsPaths
        Refresh-LocalHostTab
    })
    $toolbar.Controls.Add($validateButton)

    $note = New-Label "Active when Run mode = Single local run. Check Use for each target; Create/overwrite applies only to Test file rows." 0 0 900 40
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
    $script:LocalHostTargetGrid.ReadOnly = $false
    $script:LocalHostTargetGrid.AllowUserToAddRows = $false
    $script:LocalHostTargetGrid.AllowUserToDeleteRows = $false
    $script:LocalHostTargetGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:LocalHostTargetGrid.MultiSelect = $false
    $script:LocalHostTargetGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    Add-TargetSelectionColumns $script:LocalHostTargetGrid
    $script:LocalHostTargetGrid.Add_CurrentCellDirtyStateChanged({
        param($sender, $eventArgs)
        if ($sender.IsCurrentCellDirty) {
            $sender.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $script:LocalHostTargetGrid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($script:RefreshingLocalTargets) {
            return
        }
        if ($eventArgs.RowIndex -ge 0) {
            Update-TargetCreateFileEditability $sender.Rows[$eventArgs.RowIndex]
            Capture-LocalHostTargets
            Refresh-ConfigPreview
        }
    })
    $script:LocalHostTargetGrid.Add_CellDoubleClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -ge 0) {
            $row = $sender.Rows[$eventArgs.RowIndex]
            $row.Cells["Selected"].Value = -not [bool]$row.Cells["Selected"].Value
            Capture-LocalHostTargets
            Refresh-ConfigPreview
        }
    })
    $container.Controls.Add($script:LocalHostTargetGrid, 0, 2)
    Refresh-LocalHostTab
    return $tab
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

function Add-ParameterRow {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [object]$Definition,
        [int]$Y
    )
    $key = [string]$Definition.Key
    $param = Get-ProfileParam $script:CurrentProfile $key

    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = "Enabled"
    $enabled.Checked = [bool]$param.Enabled
    $enabled.Location = New-Object System.Drawing.Point -ArgumentList 12, $Y
    $enabled.Size = New-Object System.Drawing.Size -ArgumentList 78, 24
    $Panel.Controls.Add($enabled)

    $label = New-Label ([string]$Definition.Label) 96 $Y 210
    $Panel.Controls.Add($label)

    $helpButton = New-Button "?" 310 ($Y - 1) 28 24
    $helpButton.Tag = $Definition
    $helpButton.Add_Click({
        param($sender, $eventArgs)
        Show-ParameterHelp $sender.Tag
    })
    $Panel.Controls.Add($helpButton)

    $type = [string](Get-PropertyValue $Definition "Type" "text")
    $valueControl = $null
    if ($type -eq "dropdown") {
        $items = @()
        foreach ($option in @($Definition.Options)) {
            $items += [string]$option
        }
        $valueControl = New-ComboBox $items ([string]$param.Value) 350 $Y 220
    } else {
        $valueControl = New-TextBox ([string]$param.Value) 350 $Y 220
    }
    $Panel.Controls.Add($valueControl)

    $vdName = New-Label ([string]$Definition.VdbenchName) 590 $Y 120
    $vdName.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($vdName)

    $line = New-Label ([string]$Definition.Line) 720 $Y 120
    $line.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($line)

    $script:ParameterControls[$key] = [pscustomobject]@{
        Enabled = $enabled
        Value = $valueControl
        Definition = $Definition
    }
}
function Capture-ProfileEditor {
    if ($null -eq $script:CurrentProfile) {
        return
    }
    if ($script:ProfileNameBox) {
        $script:CurrentProfile.Name = [string]$script:ProfileNameBox.Text
    }
    if ($script:ProfileKindCombo) {
        $script:CurrentProfile.TestKind = [string]$script:ProfileKindCombo.Text
    }
    foreach ($key in $script:ParameterControls.Keys) {
        $entry = $script:ParameterControls[$key]
        Set-ProfileParamEnabled $script:CurrentProfile $key ([bool]$entry.Enabled.Checked)
        Set-ProfileParamValue $script:CurrentProfile $key ([string]$entry.Value.Text)
    }
    if ($script:AdvancedActiveBox) {
        $script:CurrentProfile.AdvancedActive = $script:AdvancedActiveBox.Text
    }
    if ($script:AdvancedDisabledBox) {
        $script:CurrentProfile.AdvancedDisabled = $script:AdvancedDisabledBox.Text
    }
    Capture-LocalHostTargets
}

function Refresh-ProfileEditor {
    if ($null -eq $script:CurrentProfile) {
        $script:CurrentProfile = New-DefaultProfile "New-Profile" "Raw/block"
    }
    $script:RefreshingProfileEditor = $true
    $script:ParameterControls = @{}
    $script:ProfileNameBox.Text = [string]$script:CurrentProfile.Name
    $script:ProfileKindCombo.Text = [string]$script:CurrentProfile.TestKind
    $script:ProfileParamTabs.TabPages.Clear()

    $testKind = [string]$script:CurrentProfile.TestKind
    $sections = @($script:Catalog | Where-Object { Definition-AppliesToKind $_ $testKind } | Select-Object -ExpandProperty Section -Unique)
    foreach ($section in $sections) {
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $section
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
            $panel.Controls.Add($h)
        }
        $y += 30
        foreach ($def in @($script:Catalog | Where-Object { $_.Section -eq $section -and (Definition-AppliesToKind $_ $testKind) })) {
            if (@("storage.lun", "fsd.anchor") -contains [string]$def.Key) {
                continue
            }
            Add-ParameterRow $panel $def $y
            $y += 32
        }
        $script:ProfileParamTabs.TabPages.Add($tab) | Out-Null
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
    $script:RefreshingProfileEditor = $false
    Refresh-ConfigPreview
    Update-RunModeIndicator
}

function Refresh-ProfileList {
    if (-not $script:ProfileSelector) {
        return
    }
    $current = [string]$script:ProfileSelector.Text
    $script:ProfileSelector.Items.Clear()
    foreach ($name in Get-ProfileNames) {
        [void]$script:ProfileSelector.Items.Add($name)
    }
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $script:ProfileSelector.Text = $current
    }
}

function Build-ProfileTab {
    $tab = New-MainTabPage "Profile Builder" "Profile"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 124)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-FlowToolbar
    $container.Controls.Add($toolbar, 0, 0)

    $toolbar.Controls.Add((New-Label "Profile" 10 12 60))
    $script:ProfileSelector = New-ComboBox @() "" 72 10 230
    $toolbar.Controls.Add($script:ProfileSelector)

    $loadButton = New-Button "Load" 310 9 70 27
    $loadButton.Add_Click({
        $profile = Load-ProfileByName ([string]$script:ProfileSelector.Text)
        if ($profile) {
            $script:CurrentProfile = $profile
            Refresh-ProfileEditor
            Update-RunModeIndicator
        }
    })
    $toolbar.Controls.Add($loadButton)

    $newRawButton = New-Button "New raw" 388 9 80 27
    $newRawButton.Add_Click({
        $script:CurrentProfile = New-DefaultProfile "New-Raw-Profile" "Raw/block"
        Refresh-ProfileEditor
    })
    $toolbar.Controls.Add($newRawButton)

    $newFsButton = New-Button "New fs" 476 9 75 27
    $newFsButton.Add_Click({
        $script:CurrentProfile = New-DefaultProfile "New-Filesystem-Profile" "Filesystem"
        Refresh-ProfileEditor
    })
    $toolbar.Controls.Add($newFsButton)

    $saveButton = New-Button "Save profile" 560 9 105 27
    $saveButton.Add_Click({ Save-CurrentProfile })
    $toolbar.Controls.Add($saveButton)

    $previewButton = New-Button "Refresh preview" 674 9 120 27
    $previewButton.Add_Click({
        Capture-ProfileEditor
        Refresh-ConfigPreview
    })
    $toolbar.Controls.Add($previewButton)

    $duplicateButton = New-Button "Duplicate" 804 9 90 27
    $duplicateButton.Add_Click({ Duplicate-CurrentProfile })
    $toolbar.Controls.Add($duplicateButton)

    $deleteButton = New-Button "Delete" 902 9 80 27
    $deleteButton.Add_Click({ Delete-SelectedProfile })
    $toolbar.Controls.Add($deleteButton)

    $folderButton = New-Button "Folder" 10 44 75 27
    $folderButton.Add_Click({ Open-ProfileFolder })
    $toolbar.Controls.Add($folderButton)

    $importButton = New-Button "Import" 92 44 75 27
    $importButton.Add_Click({ Import-Profile })
    $toolbar.Controls.Add($importButton)

    $exportButton = New-Button "Export" 174 44 75 27
    $exportButton.Add_Click({ Export-CurrentProfile })
    $toolbar.Controls.Add($exportButton)

    $toolbar.Controls.Add((New-Label "Name" 260 46 50))
    $script:ProfileNameBox = New-TextBox "" 312 44 230
    $toolbar.Controls.Add($script:ProfileNameBox)

    $toolbar.Controls.Add((New-Label "Type" 558 46 40))
    $script:ProfileKindCombo = New-ComboBox @("Raw/block", "Filesystem") "Raw/block" 600 44 150
    $script:ProfileKindCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:ProfileKindCombo.Add_SelectedIndexChanged({
        if ($script:RefreshingProfileEditor) {
            return
        }
        if ($script:CurrentProfile) {
            Capture-ProfileEditor
            $script:CurrentProfile.TestKind = [string]$script:ProfileKindCombo.Text
            Refresh-ProfileEditor
            Update-RunModeIndicator
        }
    })
    $toolbar.Controls.Add($script:ProfileKindCombo)

    $note = New-Label "Targets are selected in Local Host or Master / Slave. Every parameter has help; disabled values are preserved as comments." 10 78 1040 34
    $toolbar.Controls.Add($note)

    $script:ProfileParamTabs = New-Object System.Windows.Forms.TabControl
    $script:ProfileParamTabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($script:ProfileParamTabs, 0, 1)

    Refresh-ProfileList
    $names = Get-ProfileNames
    if ($names.Count -gt 0) {
        $script:CurrentProfile = Load-ProfileByName $names[0]
        $script:ProfileSelector.Text = $names[0]
    } else {
        $script:CurrentProfile = New-DefaultProfile "New-Profile" "Raw/block"
    }
    Refresh-ProfileEditor
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

    $saveButton = New-Button "Save .parm" 214 8 100 28
    $saveButton.Add_Click({
        try {
            $clean = Get-CleanConfigText
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            $dialog.Filter = "Vdbench parameter file (*.parm)|*.parm|Text file (*.txt)|*.txt|All files (*.*)|*.*"
            $dialog.FileName = ((Sanitize-FileName $script:CurrentProfile.Name) + ".parm")
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                [System.IO.File]::WriteAllText($dialog.FileName, $clean, [System.Text.Encoding]::ASCII)
            }
        } catch {
            Show-Warning ("Save failed: " + $_.Exception.Message)
        }
    })
    $toolbar.Controls.Add($saveButton)

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
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 48)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 210)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $startButton = New-Button "Start" 10 10 80 28
    $startButton.Add_Click({ Start-VdbenchRun })
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

    $script:RunChart = New-RunChart
    if ($script:RunChart) {
        $container.Controls.Add($script:RunChart, 0, 1)
    } else {
        $chartFallback = New-Object System.Windows.Forms.TextBox
        $chartFallback.Dock = [System.Windows.Forms.DockStyle]::Fill
        $chartFallback.Multiline = $true
        $chartFallback.ReadOnly = $true
        $chartFallback.Text = "Chart assembly is not available. Live Vdbench stdout is still shown below."
        $container.Controls.Add($chartFallback, 0, 1)
    }

    $script:RunLogBox = New-Object System.Windows.Forms.TextBox
    $script:RunLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:RunLogBox.Multiline = $true
    $script:RunLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:RunLogBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:RunLogBox.WordWrap = $false
    $container.Controls.Add($script:RunLogBox, 0, 2)

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
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 30)) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $form.Controls.Add($layout)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Height = 30
    $script:RunModeIndicator = New-Label "Run mode: Single local run  |  Profile: (none)" 12 5 1100 20
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
        if (-not (Is-DistributedMode) -and $selected -eq $script:LocalHostTab) {
            $deferRefresh = [System.Action]{ Refresh-LocalHostTab }
            $sender.BeginInvoke($deferRefresh) | Out-Null
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $script:UiRefreshTimer = $timer
    $timer.Add_Tick({
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
                $script:RunFinishedNotified = $true
                $script:RunStatusLabel.Text = "Finished: " + $script:CurrentRunId
                Refresh-Reports
            }
        }
    })
    $timer.Start()

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
            if (-not (Ask-YesNo "A Vdbench run is active. Close UI and leave/kill process manually?" "Active run")) {
                $eventArgs.Cancel = $true
            }
        }
    })

    Update-RunModeIndicator
    Update-RunModeTabs
    return $form
}
