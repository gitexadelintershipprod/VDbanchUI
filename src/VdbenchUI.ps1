param(
    [switch]$NoGui,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $script:ChartAvailable = $true
} catch {
    $script:ChartAvailable = $false
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = Join-Path $script:AppRoot "data"
$script:ProfileRoot = Join-Path $script:AppRoot "profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = Join-Path $script:AppRoot "logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"

$script:Settings = $null
$script:Slaves = @()
$script:Catalog = @()
$script:CurrentProfile = $null
$script:ParameterControls = @{}
$script:SettingsControls = @{}
$script:RefreshingProfileEditor = $false
$script:CurrentProcess = $null
$script:CurrentRunId = $null
$script:KillRequested = $false
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Form = $null
$script:SettingsStatusBox = $null
$script:SlaveGrid = $null
$script:ProfileSelector = $null
$script:ProfileNameBox = $null
$script:ProfileKindCombo = $null
$script:ProfileParamTabs = $null
$script:AdvancedActiveBox = $null
$script:AdvancedDisabledBox = $null
$script:ConfigPreviewBox = $null
$script:RunLogBox = $null
$script:RunStatusLabel = $null
$script:RunChart = $null
$script:RunMetricIndex = 0
$script:ReportsGrid = $null
$script:ReportDetailBox = $null
$script:ActiveStdoutPath = $null
$script:ActiveStderrPath = $null
$script:MainTabControl = $null
$script:LocalHostTab = $null
$script:MasterSlaveTab = $null
$script:LocalHostInfoBox = $null
$script:LocalHostTargetGrid = $null
$script:RefreshingLocalTargets = $false
$script:RunModeIndicator = $null
$script:AppToolTip = $null
$script:RunFinishedNotified = $false

$script:ModuleRoot = Join-Path (Split-Path -Parent $PSCommandPath) "modules"
. (Join-Path $script:ModuleRoot "Import-AppModules.ps1") -ModuleRoot $script:ModuleRoot

try {
    if ($SelfTest) {
        Invoke-AppSelfTest
        return
    }
    if (-not $NoGui) {
        Write-AppLog "Starting Vdbench UI"
        Initialize-AppState
        $script:Form = Build-MainForm
        Refresh-ConfigPreview
        [System.Windows.Forms.Application]::Run($script:Form)
    }
} catch {
    Write-AppLog ("Fatal error: {0}" -f $_.Exception.Message) "ERROR"
    if (-not $NoGui -and -not $SelfTest) {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Vdbench UI fatal error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    throw
}
