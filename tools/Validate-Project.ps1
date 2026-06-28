Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $root "src\VdbenchUI.ps1"
$catalogPath = Join-Path $root "config\parameter-catalog.json"
$settingsPath = Join-Path $root "config\default-settings.json"
$launcherPath = Join-Path $root "Launch-VdbenchUI.bat"
$fakeRunnerPath = Join-Path $root "tools\FakeVdbench.ps1"
$smokeScriptPath = Join-Path $root "tools\Invoke-SmokeTest.ps1"
$packageScriptPath = Join-Path $root "tools\Package-Portable.ps1"

Write-Host "Validating PowerShell syntax..."
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    foreach ($err in $errors) {
        Write-Host ("{0}:{1}:{2} {3}" -f $err.Extent.File, $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber, $err.Message) -ForegroundColor Red
    }
    throw "PowerShell syntax validation failed."
}
Write-Host "PowerShell syntax OK."

Write-Host "Running Vdbench UI headless self-test..."
& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw ("Vdbench UI self-test failed with exit code {0}" -f $LASTEXITCODE)
}
Write-Host "Vdbench UI self-test OK."

Write-Host "Validating JSON files..."
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json

$keys = @{}
foreach ($item in @($catalog)) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Key)) {
        throw "Catalog item with empty Key."
    }
    if ($keys.ContainsKey([string]$item.Key)) {
        throw ("Duplicate catalog key: {0}" -f $item.Key)
    }
    $keys[[string]$item.Key] = $true
}

foreach ($required in @("VdbenchRoot", "MasterVdbenchBat", "ReportsRoot", "RunMode", "ReadinessCheckerArguments", "SlaveShell")) {
    if ($null -eq $settings.PSObject.Properties[$required]) {
        throw ("Missing default setting: {0}" -f $required)
    }
}

Write-Host ("JSON OK. Catalog parameters: {0}" -f @($catalog).Count)

Write-Host "Validating launcher..."
$launcher = Get-Content -LiteralPath $launcherPath -Raw
if ($launcher -notmatch "-STA") {
    throw "Launcher must start powershell.exe with -STA for Windows Forms."
}
Write-Host "Launcher OK."

Write-Host "Validating helper scripts..."
foreach ($path in @($fakeRunnerPath, $smokeScriptPath, $packageScriptPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Required helper script is missing: {0}" -f $path)
    }
}
$fakeRunner = Get-Content -LiteralPath $fakeRunnerPath -Raw
if ($fakeRunner -notmatch "Fake Vdbench completed successfully") {
    throw "Fake runner completion marker is missing."
}
Write-Host "Helper scripts OK."

Write-Host "Validating catalog coverage..."
$sections = @($catalog | Select-Object -ExpandProperty Section -Unique)
foreach ($section in @("Run Definition", "Storage Definition", "Workload Definition", "Filesystem Definition", "Filesystem Workload")) {
    if ($sections -notcontains $section) {
        throw ("Missing catalog section: {0}" -f $section)
    }
}
foreach ($item in @($catalog)) {
    if ([string]$item.Type -eq "dropdown" -and @($item.Options).Count -eq 0) {
        throw ("Dropdown parameter has no options: {0}" -f $item.Key)
    }
    if (@("both", "raw", "fs") -notcontains [string]$item.AppliesTo) {
        throw ("Invalid AppliesTo value for {0}: {1}" -f $item.Key, $item.AppliesTo)
    }
}
Write-Host "Catalog coverage OK."
Write-Host "Validation complete."
