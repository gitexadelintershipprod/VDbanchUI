Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$distRoot = Join-Path $root "dist"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$packageDir = Join-Path $distRoot ("VdbenchUI-" + $stamp)
$zipPath = $packageDir + ".zip"

if (-not [System.IO.Directory]::Exists($distRoot)) {
    [System.IO.Directory]::CreateDirectory($distRoot) | Out-Null
}
if ([System.IO.Directory]::Exists($packageDir)) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($packageDir) | Out-Null

$include = @(
    "Launch-VdbenchUI.bat",
    "README.md",
    ".gitignore",
    "config",
    "docs",
    "profiles",
    "src",
    "tests",
    "tools"
)

foreach ($item in $include) {
    $source = Join-Path $root $item
    $target = Join-Path $packageDir $item
    if ([System.IO.Directory]::Exists($source)) {
        Copy-Item -LiteralPath $source -Destination $target -Recurse
    } elseif ([System.IO.File]::Exists($source)) {
        Copy-Item -LiteralPath $source -Destination $target
    }
}

foreach ($runtimeDir in @("data", "runs", "reports", "logs", "dist")) {
    $path = Join-Path $packageDir $runtimeDir
    if ([System.IO.Directory]::Exists($path)) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zipPath -Force
Write-Host ("Created package: {0}" -f $zipPath)
