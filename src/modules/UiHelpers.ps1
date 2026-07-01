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
                if ($null -ne $workErrorMessage) {
                    & $job.OnComplete $null $workErrorMessage $job.Context
                } else {
                    & $job.OnComplete $workResult $null $job.Context
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
        [scriptblock]$OnComplete,
        [hashtable]$Context = @{},
        [scriptblock]$Work = $null,
        [string]$CommandName = ""
    )
    if ([string]::IsNullOrWhiteSpace($CommandName) -and $null -eq $Work) {
        throw "Start-BackgroundUiWork requires -Work or -CommandName."
    }
    if ($null -eq $Owner) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
                $result = & $CommandName $Context
            } else {
                $result = & $Work $Context
            }
            & $OnComplete $result $null $Context
        } catch {
            & $OnComplete $null (Get-BackgroundUiErrorMessage $_) $Context
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
        Context = $Context
    }
}
