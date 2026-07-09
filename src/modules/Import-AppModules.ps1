param([string]$ModuleRoot)

$order = @(
    "Core.ps1",
    "Metrics.ps1",
    "ProcessRunner.ps1",
    "State.ps1",
    "UiHelpers.ps1",
    "TargetDiscovery.ps1",
    "UiSlaveGrid.ps1",
    "UiTabs.ps1",
    "ConfigGeneration.ps1",
    "Runner.ps1",
    "TargetCleanup.ps1",
    "SelfTest.ps1"
)

foreach ($name in $order) {
    $path = Join-Path $ModuleRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Missing module: {0}" -f $path)
    }
    . $path
}
