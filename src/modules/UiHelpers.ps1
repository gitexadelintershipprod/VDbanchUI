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

$script:BackgroundUiPackages = @{}
$script:BackgroundUiWorkerJobs = @{}
$script:BackgroundUiCompletionQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:BackgroundRunspace = $null
$script:BackgroundRunspaceLock = New-Object object

function Initialize-BackgroundRunspace {
    if ($null -ne $script:BackgroundRunspace) {
        return
    }
    $script:BackgroundRunspace = [runspacefactory]::CreateRunspace()
    $script:BackgroundRunspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $script:BackgroundRunspace
    try {
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
        [void]$ps.AddScript($initScript)
        foreach ($moduleName in @(
            "Core.ps1", "Metrics.ps1", "ProcessRunner.ps1", "State.ps1", "UiHelpers.ps1",
            "TargetDiscovery.ps1", "UiSlaveGrid.ps1", "UiTabs.ps1", "ConfigGeneration.ps1", "Runner.ps1"
        )) {
            $modulePath = (Join-Path $script:ModuleRoot $moduleName) -replace "'", "''"
            [void]$ps.AddScript(". '$modulePath'")
        }
        $null = $ps.Invoke()
        if ($ps.HadErrors) {
            $errors = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
            throw ("Background runspace initialization failed: {0}" -f ($errors -join "; "))
        }
        Write-DebugLog "Background runspace initialized"
    } finally {
        $ps.Dispose()
    }
}

function Invoke-BackgroundUiWorkItem {
    param(
        [scriptblock]$Work,
        [hashtable]$Context,
        $Runspace = $null
    )
    if ($null -eq $Runspace) {
        if ($null -eq $script:BackgroundRunspace) {
            Initialize-BackgroundRunspace
        }
        $Runspace = $script:BackgroundRunspace
    }
    [System.Threading.Monitor]::Enter($script:BackgroundRunspaceLock)
    try {
        $previous = [runspace]::DefaultRunspace
        try {
            [runspace]::DefaultRunspace = $Runspace
            return & $Work $Context
        } finally {
            [runspace]::DefaultRunspace = $previous
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:BackgroundRunspaceLock)
    }
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
    if ($null -ne $candidate.PSObject.Properties["Message"]) {
        return [string]$candidate.Message
    }
    return [string]$candidate
}

function Invoke-BackgroundUiCompletions {
    while ($script:BackgroundUiCompletionQueue.Count -gt 0) {
        $item = $script:BackgroundUiCompletionQueue.Dequeue()
        if ($null -ne $item.ErrorMessage) {
            & $item.OnComplete $null $item.ErrorMessage $item.Context
        } else {
            & $item.OnComplete $item.Result $null $item.Context
        }
    }
}

function Start-BackgroundUiWork {
    param(
        [System.Windows.Forms.Control]$Owner,
        [scriptblock]$Work,
        [scriptblock]$OnComplete,
        [hashtable]$Context = @{}
    )
    if ($null -eq $Owner) {
        try {
            $result = & $Work $Context
            & $OnComplete $result $null $Context
        } catch {
            & $OnComplete $null (Get-BackgroundUiErrorMessage $_) $Context
        }
        return
    }
    if ($null -eq $script:BackgroundRunspace) {
        Initialize-BackgroundRunspace
    }
    $package = [pscustomobject]@{
        Work = $Work
        OnComplete = $OnComplete
        Owner = $Owner
        Context = $Context
        BackgroundRunspace = $script:BackgroundRunspace
    }
    $jobId = [guid]::NewGuid().ToString()
    $script:BackgroundUiPackages[$jobId] = $package
    $worker = New-Object System.ComponentModel.BackgroundWorker
    $workerKey = [string]$worker.GetHashCode()
    $script:BackgroundUiWorkerJobs[$workerKey] = $jobId
    $worker.Add_DoWork({
        param($sender, $eventArgs)
        $id = [string]$eventArgs.Argument
        $pkg = $script:BackgroundUiPackages[$id]
        $eventArgs.Result = Invoke-BackgroundUiWorkItem -Work $pkg.Work -Context $pkg.Context -Runspace $pkg.BackgroundRunspace
    })
    $worker.Add_RunWorkerCompleted({
        param($sender, $eventArgs)
        # RunWorkerCompletedEventArgs has no Argument property (unlike DoWorkEventArgs).
        $workerKey = [string]$sender.GetHashCode()
        $id = [string]$script:BackgroundUiWorkerJobs[$workerKey]
        [void]$script:BackgroundUiWorkerJobs.Remove($workerKey)
        $pkg = $script:BackgroundUiPackages[$id]
        [void]$script:BackgroundUiPackages.Remove($id)
        $workError = $eventArgs.Error
        $workErrorMessage = $null
        $workResult = $null
        if ($null -eq $workError) {
            $workResult = $eventArgs.Result
        } else {
            $workErrorMessage = Get-BackgroundUiErrorMessage $workError
        }
        [void]$script:BackgroundUiCompletionQueue.Enqueue([pscustomobject]@{
            OnComplete = $pkg.OnComplete
            ErrorMessage = $workErrorMessage
            Result = $workResult
            Context = $pkg.Context
        })
        $owner = $pkg.Owner
        $owner.BeginInvoke([System.Action]{ Invoke-BackgroundUiCompletions }) | Out-Null
        $sender.Dispose()
    })
    $worker.RunWorkerAsync($jobId) | Out-Null
}
