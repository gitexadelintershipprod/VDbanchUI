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

$script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = Join-Path $script:AppRoot "data"
$script:ProfileRoot = Join-Path $script:AppRoot "profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = Join-Path $script:AppRoot "logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:LocalHostTargetsPath = Join-Path $script:DataRoot "localhost.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"

$script:Settings = $null
$script:Slaves = @()
$script:LocalHostTargets = @()
$script:Catalog = @()
$script:CurrentProfile = $null
$script:RunProfile = $null
$script:ParameterControls = @{}
$script:SettingsControls = @{}
$script:RefreshingProfileEditor = $false
$script:CurrentProcess = $null
$script:CurrentRunId = $null
$script:KillRequested = $false
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:RunFileWriteQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:ProcessExitQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:UiThreadWorkQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:UiThreadWorkTimer = $null
$script:Form = $null
$script:SettingsStatusBox = $null
$script:SlaveGrid = $null
$script:ProfileNameBox = $null
$script:ProfileParamTabs = $null
$script:RunModeCombo = $null
$script:RunProfileSelector = $null
$script:RunSummaryBox = $null
$script:RunTabLayout = $null
$script:MasterSlaveToolbarLayout = $null
$script:ProfileToolbarLayout = $null
$script:PreviewToolbarLayout = $null
$script:ReportsToolbarLayout = $null
$script:LocalHostToolbarLayout = $null
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
$script:LocalHostComputerLabel = $null
$script:LocalHostOsLabel = $null
$script:LocalHostRunModeLabel = $null
$script:LocalHostPathsLabel = $null
$script:LocalHostTargetPreview = $null
$script:LocalHostContentLayout = $null
$script:RefreshingLocalTargets = $false
$script:LocalHostCleanInFlight = $false
$script:LocalHostCleanButton = $null
$script:CleanupUiEnabledCache = $false
$script:CleanupUiStateInitialized = $false
$script:RunModeLabel = $null
$script:RunModeIndicator = $null
$script:MainFormLayout = $null
$script:MainHeaderLayout = $null
$script:UiFont = $null
$script:UiTabFont = $null
$script:UiMonoFont = $null
$script:AppToolTip = $null
$script:RunFinishedNotified = $false
$script:ProfileEditorRefreshPending = $false
$script:ProfileEditorRefreshPendingSource = ""
$script:RefreshingConfigPreview = $false
$script:SuppressRunProfileSelectorEvents = $false
$script:ProfileTargetContextDebounceSource = ""
$script:ProfileTargetContextDebounceTimer = $null
$script:MainTabToolTipText = ""
$script:UiRefreshTimer = $null
$script:DpiAwarenessInitialized = $false
$script:AppExceptionLoggingRegistered = $false
$script:ProfileEditorLocked = $true
$script:ProfileEditorTestKind = ""
$script:ProfileEditorLastTestKind = ""
$script:ProfileNewButton = $null
$script:ProfileSaveButton = $null
$script:ProfilePreviewButton = $null
$script:ProcessEventBridgeReady = $false
$script:ProfileEditorBanner = $null
$script:PendingListViewBulkSync = $null

$script:ModuleRoot = Join-Path (Split-Path -Parent $PSCommandPath) "modules"
. (Join-Path $script:ModuleRoot "Import-AppModules.ps1") -ModuleRoot $script:ModuleRoot

Initialize-DpiAwareness
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    if ($SelfTest) {
        Invoke-AppSelfTest
        return
    }
    if (-not $NoGui) {
        Register-AppExceptionLogging
        Write-AppLog "Starting Vdbench UI"
        Write-DebugLog ("AppRoot={0}; LogRoot={1}" -f $script:AppRoot, $script:LogRoot)
        Initialize-AppState
        Initialize-ProcessEventBridge
        Initialize-BackgroundRunspace
        $script:Form = Build-MainForm
        Write-DebugLog "Main form built"
        Refresh-ConfigPreview
        Write-DebugLog "Entering UI message loop"
        try {
            [System.Windows.Forms.Application]::Run($script:Form)
            Write-DebugLog "UI message loop exited normally"
        } finally {
            Write-DebugLog "Application.Run returned"
        }
    }
} catch {
    Write-AppLog ("Fatal error: {0}" -f $_.Exception.Message) "ERROR" $_.Exception
    if (-not $NoGui -and -not $SelfTest) {
        try {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Vdbench UI fatal error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } catch {
        }
    }
    exit 1
}
