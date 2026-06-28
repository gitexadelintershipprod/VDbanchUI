Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$validator = Join-Path $root "tools\Validate-Project.ps1"
$smoke = Join-Path $root "tools\Invoke-SmokeTest.ps1"
$packager = Join-Path $root "tools\Package-Portable.ps1"
$distRoot = Join-Path $root "dist"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Script
    )
    Write-Host ""
    Write-Host ("== {0} ==" -f $Name) -ForegroundColor Cyan
    & $Script
    Write-Host ("OK: {0}" -f $Name) -ForegroundColor Green
}

Invoke-Step "Project validation" {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator
    if ($LASTEXITCODE -ne 0) {
        throw ("Project validation failed with exit code {0}" -f $LASTEXITCODE)
    }
}

Invoke-Step "Fake-runner smoke test" {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $smoke
    if ($LASTEXITCODE -ne 0) {
        throw ("Smoke test failed with exit code {0}" -f $LASTEXITCODE)
    }
}

Invoke-Step "Portable package build" {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packager
    if ($LASTEXITCODE -ne 0) {
        throw ("Packaging failed with exit code {0}" -f $LASTEXITCODE)
    }
}

Invoke-Step "Portable package inspection" {
    if (-not [System.IO.Directory]::Exists($distRoot)) {
        throw "dist folder was not created."
    }
    $zip = Get-ChildItem -LiteralPath $distRoot -Filter "*.zip" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $zip) {
        throw "No portable ZIP package was found."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '/', '\' })
        foreach ($required in @(
            "Launch-VdbenchUI.bat",
            "README.md",
            "src\VdbenchUI.ps1",
            "config\parameter-catalog.json",
            "tools\Validate-Project.ps1",
            "tools\Invoke-SmokeTest.ps1",
            "tools\Verify-Portable.ps1"
        )) {
            if ($entries -notcontains $required) {
                throw ("Portable package missing required file: {0}" -f $required)
            }
        }
        foreach ($forbiddenPrefix in @("data\", "runs\", "reports\", "logs\", "dist\")) {
            if (@($entries | Where-Object { $_.StartsWith($forbiddenPrefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                throw ("Portable package contains runtime state under: {0}" -f $forbiddenPrefix)
            }
        }
    } finally {
        $archive.Dispose()
    }
    Write-Host ("Package OK: {0}" -f $zip.FullName)
}

Write-Host ""
Write-Host "Portable verification complete." -ForegroundColor Green
