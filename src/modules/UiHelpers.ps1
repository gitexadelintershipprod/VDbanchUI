function Invoke-UiSafe {
    param(
        [scriptblock]$Action,
        [string]$Context = "UI action"
    )
    try {
        & $Action
    } catch {
        Write-AppLog ("{0} failed: {1}" -f $Context, $_.Exception.Message) "ERROR" $_.Exception
        Show-Warning ("{0}: {1}" -f $Context, $_.Exception.Message)
    }
}

function Initialize-UiThreadWorkTimer {
    if ($null -ne $script:UiThreadWorkTimer) {
        return
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1
    $script:UiThreadWorkTimer = $timer
    $timer.Add_Tick({
        Invoke-PendingUiThreadWork
    })
    $timer.Start()
}

function Invoke-PendingUiThreadWork {
    if ($script:UiThreadWorkQueue.Count -eq 0) {
        return
    }
    $processed = 0
    while ($processed -lt 32) {
        $item = $null
        if (-not $script:UiThreadWorkQueue.TryDequeue([ref]$item)) {
            break
        }
        $processed++
        try {
            if ($null -ne $item.HandlerName) {
                $handler = Get-Command $item.HandlerName -ErrorAction Stop
                $handlerArgs = $item.Arguments
                if ($null -ne $handlerArgs -and $handlerArgs.Count -gt 0) {
                    & $handler @handlerArgs
                } else {
                    & $handler
                }
            }
        } catch {
            Write-AppLog ("UI thread work failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
    }
}

function Invoke-OnUiThread {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandlerName,
        [hashtable]$HandlerArguments = @{}
    )
    $needsMarshal = ($null -ne $script:Form -and -not $script:Form.IsDisposed -and $script:Form.InvokeRequired)
    if (-not $needsMarshal) {
        try {
            $handler = Get-Command $HandlerName -ErrorAction Stop
            if ($HandlerArguments.Count -gt 0) {
                & $handler @HandlerArguments
            } else {
                & $handler
            }
        } catch {
            Write-AppLog ("UI thread work failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
        }
        return
    }
    $script:UiThreadWorkQueue.Enqueue([pscustomobject]@{
        HandlerName = $HandlerName
        Arguments = $HandlerArguments
    })
    Initialize-UiThreadWorkTimer
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 160,
        [int]$H = 22
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $label.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-TextBox {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 320,
        [int]$H = 24
    )
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $box.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    return $box
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 110,
        [int]$H = 28
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $button.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    return $button
}

function Get-ProfileEditorControlValue {
    param([System.Windows.Forms.Control]$Control)
    if ($null -eq $Control) {
        return ""
    }
    if ($Control -is [System.Windows.Forms.ComboBox]) {
        $combo = [System.Windows.Forms.ComboBox]$Control
        if ($combo.DropDownStyle -eq [System.Windows.Forms.ComboBoxStyle]::DropDownList) {
            if ($null -ne $combo.SelectedItem) {
                return [string]$combo.SelectedItem
            }
            return ""
        }
    }
    return [string]$Control.Text
}

function New-ProfileDropdown {
    param(
        [string[]]$Items,
        [string]$Selected,
        [int]$X,
        [int]$Y,
        [int]$W = 220,
        [int]$H = 24
    )
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.IntegralHeight = $false
    $combo.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $combo.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    $normalizedItems = @()
    foreach ($item in @($Items)) {
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $normalizedItems += $text
        }
    }
    foreach ($item in $normalizedItems) {
        [void]$combo.Items.Add($item)
    }
    $selectedText = [string]$Selected
    if ($normalizedItems -contains $selectedText) {
        $combo.SelectedItem = $selectedText
    } elseif ($normalizedItems.Count -gt 0) {
        $combo.SelectedIndex = 0
    }
    return $combo
}

function New-ComboBox {
    param(
        [string[]]$Items,
        [string]$Selected,
        [int]$X,
        [int]$Y,
        [int]$W = 180,
        [int]$H = 24
    )
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $combo.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    foreach ($item in $Items) {
        [void]$combo.Items.Add($item)
    }
    $combo.Text = $Selected
    return $combo
}

function Show-Info {
    param(
        [string]$Message,
        [string]$Title = "Vdbench UI"
    )
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Show-Warning {
    param(
        [string]$Message,
        [string]$Title = "Vdbench UI"
    )
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Ask-YesNo {
    param(
        [string]$Message,
        [string]$Title = "Confirm"
    )
    $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Set-ControlToolTip {
    param(
        [System.Windows.Forms.Control]$Control,
        [string]$Text
    )
    if ($null -eq $script:AppToolTip -or $null -eq $Control) {
        return
    }
    $script:AppToolTip.SetToolTip($Control, $Text)
}

function Get-UiScaleFactor {
    param([System.Windows.Forms.Control]$Control = $null)
    try {
        if ($Control) {
            return [single]([Math]::Max(1.0, $Control.DeviceDpi / 96.0))
        }
        $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try {
            return [single]([Math]::Max(1.0, $graphics.DpiX / 96.0))
        } finally {
            $graphics.Dispose()
        }
    } catch {
        return 1.0
    }
}

function Get-DataGridRowHeight {
    param(
        [System.Windows.Forms.Control]$Control = $null,
        [int]$BaseHeight = 32,
        [switch]$WithButtons
    )
    $scale = 1.0
    if ($Control) {
        $scale = Get-UiScaleFactor $Control
    }
    $base = if ($WithButtons) { [Math]::Max($BaseHeight, 44) } else { $BaseHeight }
    return [int][Math]::Max($base, [Math]::Round($base * $scale))
}

function Apply-DataGridResponsiveLayout {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [switch]$WithButtons,
        [int]$HeaderBase = 0
    )
    if ($null -eq $Grid) {
        return
    }
    $scale = Get-UiScaleFactor $Grid
    $rowHeight = Get-DataGridRowHeight -Control $Grid -WithButtons:([bool]$WithButtons)
    if ($HeaderBase -gt 0) {
        $headerBase = $HeaderBase
    } elseif ($WithButtons) {
        $headerBase = 42
    } else {
        $headerBase = 36
    }
    $headerHeight = [int][Math]::Max($headerBase, [Math]::Round($headerBase * $scale))
    $pad = [int][Math]::Max(4, [Math]::Round(6 * $scale))
    $padding = New-Object System.Windows.Forms.Padding -ArgumentList $pad, $pad, $pad, $pad
    $gridFont = if ($script:UiFont) { $script:UiFont } else { $Grid.Font }

    $Grid.Font = $gridFont
    $Grid.RowTemplate.Height = $rowHeight
    $Grid.ColumnHeadersHeight = $headerHeight
    $Grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $Grid.DefaultCellStyle.Padding = $padding
    $Grid.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleLeft
    $Grid.ColumnHeadersDefaultCellStyle.Font = $gridFont
    $Grid.ColumnHeadersDefaultCellStyle.Padding = $padding
    $Grid.ColumnHeadersDefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter

    foreach ($row in @($Grid.Rows)) {
        if (-not $row.IsNewRow) {
            $row.Height = $rowHeight
        }
    }
    $Grid.Invalidate()
}

function Apply-MainFormResponsiveLayout {
    param([System.Windows.Forms.Form]$Form)
    if ($null -eq $Form) {
        return
    }
    $scale = Get-UiScaleFactor $Form
    if ($scale -gt 2.25) {
        $scale = 2.25
    }

    $uiFontSize = [Math]::Round(9.0 * $scale, 1)
    $monoFontSize = [Math]::Round(10.0 * $scale, 1)
    $script:UiFont = New-Object System.Drawing.Font -ArgumentList "Segoe UI", $uiFontSize
    $script:UiTabFont = New-Object System.Drawing.Font -ArgumentList "Segoe UI", ([Math]::Round(9.5 * $scale, 1)), ([System.Drawing.FontStyle]::Regular)
    $script:UiMonoFont = New-Object System.Drawing.Font -ArgumentList "Consolas", $monoFontSize
    $Form.Font = $script:UiFont

    if ($script:MainTabControl) {
        $tabWidth = [int][Math]::Max(108, [Math]::Round(118 * $scale))
        $tabHeight = [int][Math]::Max(30, [Math]::Round(30 * $scale))
        $script:MainTabControl.ItemSize = New-Object System.Drawing.Size -ArgumentList $tabWidth, $tabHeight
        $script:MainTabControl.Font = $script:UiTabFont
        $script:MainTabControl.Padding = New-Object System.Drawing.Point -ArgumentList ([int][Math]::Round(8 * $scale)), ([int][Math]::Round(4 * $scale))
    }

    if ($script:RunModeIndicator) {
        $script:RunModeIndicator.Font = New-Object System.Drawing.Font -ArgumentList $script:UiFont, ([System.Drawing.FontStyle]::Bold)
    }

    foreach ($monoBox in @($script:ConfigPreviewBox, $script:RunLogBox, $script:ReportDetailBox, $script:SettingsStatusBox)) {
        if ($monoBox) {
            $monoBox.Font = $script:UiMonoFont
        }
    }

    if ($script:LocalHostPathsLabel) {
        $script:LocalHostPathsLabel.Font = $script:UiMonoFont
    }

    if ($script:RunSummaryBox) {
        $summarySize = [Math]::Round(9.0 * $scale, 1)
        $script:RunSummaryBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", $summarySize
    }

    if ($script:MainFormLayout) {
        $headerHeight = [int][Math]::Max(60, [Math]::Round(60 * $scale))
        $script:MainFormLayout.RowStyles[0].Height = [single]$headerHeight
    }

    if ($script:RunModeCombo) {
        $comboHeight = [int][Math]::Max(30, [Math]::Round(30 * $scale))
        $script:RunModeCombo.Height = $comboHeight
        $script:RunModeCombo.Font = $script:UiFont
        $script:RunModeCombo.IntegralHeight = $false
        $script:RunModeCombo.ItemHeight = [int][Math]::Max(26, [Math]::Round(26 * $scale))
        $longestText = 0
        foreach ($item in @($script:RunModeCombo.Items)) {
            $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText([string]$item, $script:UiFont).Width
            if ($textWidth -gt $longestText) {
                $longestText = $textWidth
            }
        }
        $script:RunModeCombo.DropDownWidth = [int][Math]::Max(300, $longestText + 32)
    }

    if ($script:RunModeLabel) {
        $script:RunModeLabel.Font = New-Object System.Drawing.Font -ArgumentList $script:UiFont.FontFamily, $script:UiFont.Size, ([System.Drawing.FontStyle]::Bold)
        $script:RunModeLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 70, 140)
        $script:RunModeLabel.Text = "Run mode"
    }

    if ($script:MainHeaderLayout) {
        $script:MainHeaderLayout.ColumnStyles[0].Width = [single][Math]::Max(112, [Math]::Round(112 * $scale))
        $script:MainHeaderLayout.ColumnStyles[1].Width = [single][Math]::Max(430, [Math]::Round(430 * $scale))
        $script:MainHeaderLayout.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 10, 8, 8, 6
    }

    if ($script:MasterSlaveToolbarLayout) {
        $toolbarHeight = [int][Math]::Max(108, [Math]::Round(108 * $scale))
        $script:MasterSlaveToolbarLayout.RowStyles[0].Height = [single]$toolbarHeight
    }

    if ($script:ProfileToolbarLayout) {
        $profileToolbarHeight = [int][Math]::Max(82, [Math]::Round(82 * $scale))
        $script:ProfileToolbarLayout.RowStyles[0].Height = [single]$profileToolbarHeight
        $profileBannerHeight = [int][Math]::Max(30, [Math]::Round(30 * $scale))
        $script:ProfileToolbarLayout.RowStyles[1].Height = [single]$profileBannerHeight
    }

    if ($script:RunTabLayout) {
        $runToolbarHeight = [int][Math]::Max(96, [Math]::Round(96 * $scale))
        $script:RunTabLayout.RowStyles[0].Height = [single]$runToolbarHeight
        if ($script:RunProfileSelector) {
            Set-FlowToolbarControlHeight $script:RunProfileSelector
        }
        if ($script:ProfileNameBox) {
            Set-FlowToolbarControlHeight $script:ProfileNameBox
        }
    }

    foreach ($layoutInfo in @(
            @{ Layout = $script:PreviewToolbarLayout; Height = 52 },
            @{ Layout = $script:ReportsToolbarLayout; Height = 52 },
            @{ Layout = $script:LocalHostToolbarLayout; Height = 100 }
        )) {
        if ($layoutInfo.Layout) {
            $layoutInfo.Layout.RowStyles[0].Height = [single][Math]::Max($layoutInfo.Height, [Math]::Round($layoutInfo.Height * $scale))
        }
    }

    if ($script:LocalHostContentLayout) {
        $hostPanelHeight = [int][Math]::Max(210, [Math]::Round(210 * $scale))
        $script:LocalHostContentLayout.RowStyles[0].Height = [single]$hostPanelHeight
    }

    foreach ($hostLabel in @($script:LocalHostComputerLabel, $script:LocalHostOsLabel, $script:LocalHostRunModeLabel)) {
        if ($hostLabel) {
            $hostLabel.Font = $script:UiFont
        }
    }

    Apply-DataGridResponsiveLayout $script:SlaveGrid -WithButtons
    Apply-DataGridResponsiveLayout $script:ReportsGrid -HeaderBase 46
    Apply-DataGridResponsiveLayout $script:LocalHostTargetPreview

    Update-FlowToolbarButtonSizes $Form
}

function Initialize-MainFormWindowBounds {
    param([System.Windows.Forms.Form]$Form)
    if ($null -eq $Form) {
        return
    }
    $area = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    if ($null -eq $area -or $area.Width -lt 200) {
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    $scale = Get-UiScaleFactor $Form
    $initialWidth = [int][Math]::Min(1320, [Math]::Max(960, [Math]::Round($area.Width * 0.9)))
    $initialHeight = [int][Math]::Min(900, [Math]::Max(680, [Math]::Round($area.Height * 0.9)))
    $minWidth = [int][Math]::Min(1100, [Math]::Max(820, [Math]::Round($area.Width * 0.72)))
    $minHeight = [int][Math]::Min(700, [Math]::Max(620, [Math]::Round($area.Height * 0.65)))
    $Form.MinimumSize = New-Object System.Drawing.Size -ArgumentList $minWidth, $minHeight
    $Form.Size = New-Object System.Drawing.Size -ArgumentList $initialWidth, $initialHeight
    if ($Form.Left -lt $area.Left -or $Form.Top -lt $area.Top) {
        $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
}

function Set-ToolbarButtonSize {
    param(
        [System.Windows.Forms.Button]$Button,
        [int]$MinWidth = 68,
        [int]$BaseHeight = 28
    )
    if ($null -eq $Button) {
        return
    }
    $scale = 1.0
    if ($Button.TopLevelControl) {
        $scale = Get-UiScaleFactor $Button.TopLevelControl
    } elseif ($script:Form) {
        $scale = Get-UiScaleFactor $script:Form
    }
    $font = if ($script:UiFont) { $script:UiFont } elseif ($Button.Font) { $Button.Font } else { [System.Drawing.SystemFonts]::DefaultFont }
    $Button.Font = $font
    $textSize = [System.Windows.Forms.TextRenderer]::MeasureText(
        $Button.Text,
        $font,
        [System.Drawing.Size]::new([Math]::Max($MinWidth, 320), 0),
        [System.Windows.Forms.TextFormatFlags]::SingleLine
    )
    $padH = [int][Math]::Max(24, [Math]::Round(18 * $scale))
    $padV = [int][Math]::Max(12, [Math]::Round(10 * $scale))
    $width = [int][Math]::Max($MinWidth, $textSize.Width + $padH)
    $height = [int][Math]::Max([Math]::Max($BaseHeight, [Math]::Round($BaseHeight * $scale)), $textSize.Height + $padV)
    $Button.Size = New-Object System.Drawing.Size -ArgumentList $width, $height
    if ($Button.Margin -eq [System.Windows.Forms.Padding]::Empty) {
        $Button.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 3, 8, 3
    }
}

function Update-FlowToolbarResponsiveWidths {
    param([System.Windows.Forms.FlowLayoutPanel]$Toolbar)
    if ($null -eq $Toolbar) {
        return
    }
    $available = [Math]::Max(280, $Toolbar.ClientSize.Width - 12)
    foreach ($ctrl in @($Toolbar.Controls)) {
        $role = [string]$ctrl.Tag
        if ($role -eq "flow-toolbar-wrap") {
            $ctrl.Width = $available
            $font = if ($ctrl.Font) { $ctrl.Font } else { [System.Drawing.SystemFonts]::DefaultFont }
            $proposedSize = [System.Drawing.Size]::new($available, 10000)
            $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
            $textSize = [System.Windows.Forms.TextRenderer]::MeasureText($ctrl.Text, $font, $proposedSize, $flags)
            $minHeight = 40
            if ([string]$ctrl.AccessibleDescription -match '^\d+$') {
                $minHeight = [int]$ctrl.AccessibleDescription
            }
            $ctrl.Height = [int][Math]::Max($minHeight, $textSize.Height + 8)
        } elseif ($role -eq "flow-toolbar-combo") {
            $ctrl.Width = [Math]::Min([Math]::Max(260, $available - 140), 520)
        } elseif ($role -eq "flow-toolbar-label") {
            $font = if ($ctrl.Font) { $ctrl.Font } else { [System.Drawing.SystemFonts]::DefaultFont }
            $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($ctrl.Text, $font).Width
            $minWidth = 52
            if ($ctrl.AccessibleName -match '^\d+$') {
                $minWidth = [int]$ctrl.AccessibleName
            }
            $ctrl.Width = [Math]::Max($minWidth, $textWidth + 10)
        } elseif ($role -eq "flow-toolbar-status") {
            $ctrl.Width = $available
        }
    }
}

function Set-FlowToolbarControlHeight {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$BaseHeight = 24
    )
    if ($null -eq $Control) {
        return
    }
    $scale = 1.0
    if ($Control.TopLevelControl) {
        $scale = Get-UiScaleFactor $Control.TopLevelControl
    }
    $Control.Height = [int][Math]::Max($BaseHeight, [Math]::Round($BaseHeight * $scale))
}

function Register-FlowToolbarResponsive {
    param([System.Windows.Forms.FlowLayoutPanel]$Toolbar)
    if ($null -eq $Toolbar) {
        return
    }
    if ([string]$Toolbar.Tag -eq "flow-toolbar-responsive") {
        return
    }
    $Toolbar.Tag = "flow-toolbar-responsive"
    $Toolbar.Add_Resize({
        param($sender, $eventArgs)
        Update-FlowToolbarResponsiveWidths $sender
    })
}

function Update-FlowToolbarButtonSizes {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root) {
        return
    }
    foreach ($child in @($Root.Controls)) {
        if ($child -is [System.Windows.Forms.FlowLayoutPanel]) {
            foreach ($item in @($child.Controls)) {
                if ($item -is [System.Windows.Forms.Button]) {
                    Set-ToolbarButtonSize $item
                }
            }
            if ([string]$child.Tag -eq "flow-toolbar-responsive") {
                Update-FlowToolbarResponsiveWidths $child
            }
        }
        if ($child.Controls.Count -gt 0) {
            Update-FlowToolbarButtonSizes $child
        }
    }
}

function Add-FlowToolbarLabel {
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Toolbar,
        [string]$Text,
        [int]$MinWidth = 52
    )
    $label = New-Label $Text 0 0 $MinWidth 24
    $label.Tag = "flow-toolbar-label"
    $label.AccessibleName = [string]$MinWidth
    $label.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 4, 6, 0, 0
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $Toolbar.Controls.Add($label) | Out-Null
    Update-FlowToolbarResponsiveWidths $Toolbar
    return $label
}

function Get-ProfileEditorRowStep {
    param([System.Windows.Forms.Control]$Control = $null)
    $scale = Get-UiScaleFactor $Control
    return [int][Math]::Max(36, [Math]::Round(36 * $scale))
}

function Get-ScaledUiFont {
    param(
        [System.Windows.Forms.Control]$Control = $null,
        [single]$SizeBump = 0,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    $baseFont = if ($script:UiFont) {
        $script:UiFont
    } else {
        $scale = Get-UiScaleFactor $Control
        New-Object System.Drawing.Font -ArgumentList "Segoe UI", ([Math]::Round(9.0 * $scale, 1))
    }
    $size = [Math]::Round($baseFont.Size + $SizeBump, 1)
    if ($size -lt 8.0) {
        $size = 8.0
    }
    return New-Object System.Drawing.Font -ArgumentList $baseFont.FontFamily, $size, $Style
}

function Get-ProfileEditorHeaderFont {
    param([System.Windows.Forms.Control]$Control = $null)
    return Get-ScaledUiFont -Control $Control -SizeBump 1.0 -Style ([System.Drawing.FontStyle]::Bold)
}

function Get-ProfileEditorGroupFont {
    param([System.Windows.Forms.Control]$Control = $null)
    return Get-ScaledUiFont -Control $Control -SizeBump 2.5 -Style ([System.Drawing.FontStyle]::Bold)
}

function Initialize-ResponsiveChildForm {
    param(
        [System.Windows.Forms.Form]$Form,
        [int]$BaseWidth = 0,
        [int]$BaseHeight = 0
    )
    if ($null -eq $Form) {
        return 1.0
    }
    $scale = Get-UiScaleFactor $script:Form
    if ($scale -lt 1.0) {
        $scale = 1.0
    }
    if ($scale -gt 2.25) {
        $scale = 2.25
    }
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $Form.Font = Get-ScaledUiFont
    if ($BaseWidth -gt 0 -and $BaseHeight -gt 0) {
        $Form.Size = New-Object System.Drawing.Size -ArgumentList ([int][Math]::Round($BaseWidth * $scale)), ([int][Math]::Round($BaseHeight * $scale))
    }
    return $scale
}

function Apply-ResponsiveDialogControlFonts {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root) {
        return
    }
    $font = Get-ScaledUiFont -Control $Root
    if ($Root -is [System.Windows.Forms.Form]) {
        $Root.Font = $font
    }
    foreach ($child in @($Root.Controls)) {
        if ($child -is [System.Windows.Forms.Button] -or $child -is [System.Windows.Forms.Label] -or $child -is [System.Windows.Forms.TextBox]) {
            $child.Font = $font
        }
        if ($child.Controls.Count -gt 0) {
            Apply-ResponsiveDialogControlFonts $child
        }
    }
}

function New-ResponsiveDialogButtonPanel {
    param([int]$BaseHeight = 46)
    $scale = 1.0
    if ($script:Form) {
        $scale = Get-UiScaleFactor $script:Form
    }
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $panel.Height = [int][Math]::Max($BaseHeight, [Math]::Round($BaseHeight * $scale))
    $panel.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 8, 6, 8, 6
    return $panel
}

function Add-ResponsiveDialogButtons {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [System.Windows.Forms.Button[]]$Buttons,
        [System.Windows.Forms.Label]$LeadingLabel = $null
    )
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $flow.WrapContents = $false
    if ($LeadingLabel) {
        $leadingHost = New-Object System.Windows.Forms.Panel
        $leadingHost.Dock = [System.Windows.Forms.DockStyle]::Left
        $leadingHost.Width = [Math]::Max(180, $LeadingLabel.PreferredWidth + 12)
        $LeadingLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
        $LeadingLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $leadingHost.Controls.Add($LeadingLabel) | Out-Null
        $Panel.Controls.Add($leadingHost) | Out-Null
    }
    foreach ($button in $Buttons) {
        Set-ToolbarButtonSize $button
        $flow.Controls.Add($button) | Out-Null
    }
    $Panel.Controls.Add($flow) | Out-Null
}

function Add-FlowToolbarItem {
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Toolbar,
        [System.Windows.Forms.Control]$Control,
        [switch]$FlowBreak
    )
    if ($Control -is [System.Windows.Forms.Button]) {
        Set-ToolbarButtonSize $Control
    }
    $Toolbar.Controls.Add($Control) | Out-Null
    if ($FlowBreak) {
        $Toolbar.SetFlowBreak($Control, $true)
    }
}

function New-FlowToolbar {
    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $toolbar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $toolbar.WrapContents = $true
    $toolbar.AutoScroll = $true
    $toolbar.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 6, 5, 6, 5
    return $toolbar
}

function New-MainTabPage {
    param(
        [string]$FullTitle,
        [string]$ShortTitle
    )
    if ([string]::IsNullOrWhiteSpace($ShortTitle)) {
        $ShortTitle = $FullTitle
    }
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $ShortTitle
    $tab.Tag = $FullTitle
    return $tab
}

function Get-MainTabFullTitle {
    param([System.Windows.Forms.TabPage]$Page)
    if ($null -eq $Page) {
        return ""
    }
    $fullTitle = [string]$Page.Tag
    if ([string]::IsNullOrWhiteSpace($fullTitle)) {
        $fullTitle = [string]$Page.Text
    }
    return $fullTitle
}

function Enable-MainTabToolTips {
    param([System.Windows.Forms.TabControl]$Tabs)
    if ($null -eq $Tabs -or $null -eq $script:AppToolTip) {
        return
    }
    $Tabs.Add_MouseMove({
        param($sender, $eventArgs)
        for ($i = 0; $i -lt $sender.TabCount; $i++) {
            if ($sender.GetTabRect($i).Contains($eventArgs.Location)) {
                $fullTitle = Get-MainTabFullTitle $sender.TabPages[$i]
                if ($fullTitle -ne $script:MainTabToolTipText) {
                    $script:MainTabToolTipText = $fullTitle
                    $script:AppToolTip.SetToolTip($sender, $fullTitle)
                }
                return
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($script:MainTabToolTipText)) {
            $script:MainTabToolTipText = ""
            $script:AppToolTip.SetToolTip($sender, "")
        }
    })
}

function Invoke-GridBatchUpdate {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [scriptblock]$Action
    )
    if ($null -eq $Grid) {
        & $Action
        return
    }
    $Grid.SuspendLayout()
    try {
        & $Action
    } finally {
        $Grid.ResumeLayout($true)
    }
}

$script:BackgroundRunspacePool = $null
$script:BackgroundUiJobs = @{}
$script:BackgroundUiPollTimer = $null

function Initialize-BackgroundRunspace {
    # Uses a RunspacePool (not a single shared Runspace) because a single
    # Runspace can only run one pipeline at a time: two background jobs
    # started close together (e.g. Readiness + Ping, or two slave rows)
    # would otherwise fail with "Pipelines cannot be run concurrently."
    if ($null -ne $script:BackgroundRunspacePool) {
        return
    }
    $initScript = @"
Set-StrictMode -Version 2.0
`$ErrorActionPreference = 'Stop'
`$script:AppRoot = '$([string]$script:AppRoot -replace "'", "''")'
`$script:ConfigRoot = '$([string]$script:ConfigRoot -replace "'", "''")'
`$script:DataRoot = '$([string]$script:DataRoot -replace "'", "''")'
`$script:ProfileRoot = '$([string]$script:ProfileRoot -replace "'", "''")'
`$script:RunStateRoot = '$([string]$script:RunStateRoot -replace "'", "''")'
`$script:LogRoot = '$([string]$script:LogRoot -replace "'", "''")'
`$script:SettingsPath = '$([string]$script:SettingsPath -replace "'", "''")'
`$script:SlavesPath = '$([string]$script:SlavesPath -replace "'", "''")'
`$script:LocalHostTargetsPath = '$([string]$script:LocalHostTargetsPath -replace "'", "''")'
`$script:CatalogPath = '$([string]$script:CatalogPath -replace "'", "''")'
`$script:ModuleRoot = '$([string]$script:ModuleRoot -replace "'", "''")'
`$script:Settings = `$null
`$script:Slaves = @()
`$script:LocalHostTargets = @()
`$script:Catalog = @()
"@
    Ensure-Directory $script:LogRoot
    $initScriptPath = Join-Path $script:LogRoot "background-init.generated.ps1"
    Set-Content -LiteralPath $initScriptPath -Value $initScript -Encoding UTF8

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    [void]$iss.StartupScripts.Add($initScriptPath)
    foreach ($moduleName in @(
        "Core.ps1", "Metrics.ps1", "ProcessRunner.ps1", "State.ps1", "UiHelpers.ps1",
        "TargetDiscovery.ps1", "UiSlaveGrid.ps1", "UiTabs.ps1", "ConfigGeneration.ps1", "Runner.ps1"
    )) {
        [void]$iss.StartupScripts.Add((Join-Path $script:ModuleRoot $moduleName))
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
    $pool.Open()

    # Validate the pool actually initializes cleanly (catches bad module paths
    # or startup script errors immediately instead of failing silently later).
    $probe = [powershell]::Create()
    $probe.RunspacePool = $pool
    [void]$probe.AddScript("Get-Command Get-SlaveReadinessResult -ErrorAction Stop | Out-Null")
    try {
        $null = $probe.Invoke()
        if ($probe.HadErrors) {
            $errors = @($probe.Streams.Error | ForEach-Object { $_.ToString() })
            throw ("Background runspace pool initialization failed: {0}" -f ($errors -join "; "))
        }
    } finally {
        $probe.Dispose()
    }

    $script:BackgroundRunspacePool = $pool
    Write-DebugLog "Background runspace pool initialized"
}

function Get-BackgroundUiErrorMessage {
    param($ErrorObject)
    if ($null -eq $ErrorObject) {
        return $null
    }
    $candidate = $ErrorObject
    if ($null -ne $ErrorObject.PSObject.Properties["Exception"] -and $null -ne $ErrorObject.Exception) {
        $candidate = $ErrorObject.Exception
    }
    # Unwrap nested exceptions (e.g. MethodInvocationException from EndInvoke)
    # down to the innermost message, which is the actual root cause.
    while ($null -ne $candidate.PSObject.Properties["InnerException"] -and $null -ne $candidate.InnerException) {
        $candidate = $candidate.InnerException
    }
    if ($null -ne $candidate.PSObject.Properties["Message"]) {
        return [string]$candidate.Message
    }
    return [string]$candidate
}

function Initialize-BackgroundUiPollTimer {
    if ($null -ne $script:BackgroundUiPollTimer) {
        return
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 120
    # IMPORTANT: PowerShell scriptblocks bound to .NET events (Add_Tick) do NOT
    # capture local variables from the function that created the timer unless
    # .GetNewClosure() is used. Pending jobs are therefore tracked in the
    # $script:BackgroundUiJobs dictionary instead of relying on closures here.
    $timer.Add_Tick({
        param($sender, $eventArgs)
        if ($script:BackgroundUiJobs.Count -eq 0) {
            return
        }
        $doneIds = @()
        foreach ($jobId in @($script:BackgroundUiJobs.Keys)) {
            $job = $script:BackgroundUiJobs[$jobId]
            if (-not $job.Async.IsCompleted) {
                continue
            }
            $doneIds += $jobId
            $workResult = $null
            $workErrorMessage = $null
            try {
                $workResult = $job.PowerShellInstance.EndInvoke($job.Async)
                if ($job.PowerShellInstance.HadErrors) {
                    $workErrorMessage = @($job.PowerShellInstance.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
                }
            } catch {
                $workErrorMessage = Get-BackgroundUiErrorMessage $_
            } finally {
                $job.PowerShellInstance.Dispose()
            }
            Write-DebugLog ("Background UI work finished: id={0} error={1}" -f $jobId, [bool]$workErrorMessage)
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$job.OnCompleteCommandName)) {
                    $handler = Get-Command $job.OnCompleteCommandName -ErrorAction Stop
                    if ($null -ne $workErrorMessage) {
                        & $handler $null $workErrorMessage $job.Context
                    } else {
                        & $handler $workResult $null $job.Context
                    }
                } elseif ($null -ne $job.OnComplete) {
                    if ($null -ne $workErrorMessage) {
                        & $job.OnComplete $null $workErrorMessage $job.Context
                    } else {
                        & $job.OnComplete $workResult $null $job.Context
                    }
                }
            } catch {
                Write-AppLog ("Background UI OnComplete handler failed: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
            }
        }
        foreach ($jobId in $doneIds) {
            [void]$script:BackgroundUiJobs.Remove($jobId)
        }
    })
    $timer.Start()
    $script:BackgroundUiPollTimer = $timer
}

function Start-BackgroundUiWork {
    param(
        $Owner,
        [scriptblock]$OnComplete = $null,
        [string]$OnCompleteCommandName = "",
        [hashtable]$Context = @{},
        [scriptblock]$Work = $null,
        [string]$CommandName = ""
    )
    if ([string]::IsNullOrWhiteSpace($CommandName) -and $null -eq $Work) {
        throw "Start-BackgroundUiWork requires -Work or -CommandName."
    }
    if ([string]::IsNullOrWhiteSpace($OnCompleteCommandName) -and $null -eq $OnComplete) {
        throw "Start-BackgroundUiWork requires -OnComplete or -OnCompleteCommandName."
    }
    if ($null -eq $Owner) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
                $result = & $CommandName $Context
            } else {
                $result = & $Work $Context
            }
            if (-not [string]::IsNullOrWhiteSpace($OnCompleteCommandName)) {
                $handler = Get-Command $OnCompleteCommandName -ErrorAction Stop
                & $handler $result $null $Context
            } else {
                & $OnComplete $result $null $Context
            }
        } catch {
            $errorMessage = Get-BackgroundUiErrorMessage $_
            if (-not [string]::IsNullOrWhiteSpace($OnCompleteCommandName)) {
                $handler = Get-Command $OnCompleteCommandName -ErrorAction Stop
                & $handler $null $errorMessage $Context
            } else {
                & $OnComplete $null $errorMessage $Context
            }
        }
        return
    }
    if ($null -eq $script:BackgroundRunspacePool) {
        Initialize-BackgroundRunspace
    }
    Initialize-BackgroundUiPollTimer
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:BackgroundRunspacePool
    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        [void]$ps.AddCommand($CommandName).AddParameter("Context", $Context)
    } else {
        [void]$ps.AddScript({
            param($Work, $Context)
            & $Work $Context
        }).AddArgument($Work).AddArgument($Context)
    }
    $jobId = [guid]::NewGuid().ToString()
    Write-DebugLog ("Background UI work started: id={0} command={1}" -f $jobId, ($(if ($CommandName) { $CommandName } else { "scriptblock" })))
    $async = $ps.BeginInvoke()
    $script:BackgroundUiJobs[$jobId] = [pscustomobject]@{
        PowerShellInstance = $ps
        Async = $async
        OnComplete = $OnComplete
        OnCompleteCommandName = $OnCompleteCommandName
        Context = $Context
    }
}
