param(
    [Alias("f")]
    [string]$ParameterFile,

    [Alias("o")]
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) "fake-vdbench-output"
}

if (-not [System.IO.Directory]::Exists($OutputDirectory)) {
    [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
}

Write-Host "Fake Vdbench runner"
Write-Host ("Parameter file: {0}" -f $ParameterFile)
Write-Host ("Output directory: {0}" -f $OutputDirectory)
Write-Host ""
Write-Host "interval        i/o   MB/sec   bytes   read     resp"

for ($i = 1; $i -le 12; $i++) {
    $iops = 1000 + ($i * 125)
    $mbps = [math]::Round(($iops * 4096) / 1048576, 2)
    $lat = [math]::Round(0.80 + ($i / 25), 3)
    Write-Host ("{0,8} {1,10} {2,8} {3,7} {4,6} {5,8}" -f $i, $iops, $mbps, 4096, 70, $lat)
    Start-Sleep -Milliseconds 250
}

$summaryPath = Join-Path $OutputDirectory "fake-summary.txt"
[System.IO.File]::WriteAllText($summaryPath, "Fake Vdbench run completed successfully.`r`n", [System.Text.Encoding]::UTF8)
Write-Host ""
Write-Host "Fake Vdbench completed successfully."
exit 0
