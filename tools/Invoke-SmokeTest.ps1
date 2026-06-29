Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$validator = Join-Path $root "tools\Validate-Project.ps1"
$fakeRunner = Join-Path $root "tools\FakeVdbench.ps1"
$smokeRoot = Join-Path $root "data\smoke"
$runRoot = Join-Path $smokeRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$parmPath = Join-Path $runRoot "profile.parm"
$stdoutPath = Join-Path $runRoot "stdout.log"
$stderrPath = Join-Path $runRoot "stderr.log"

Write-Host "Running project validator..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator
if ($LASTEXITCODE -ne 0) {
    throw ("Project validator failed with exit code {0}" -f $LASTEXITCODE)
}

if (-not [System.IO.Directory]::Exists($runRoot)) {
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
}

@"
* Smoke-test parameter file for fake runner
sd=sd1,lun=C:\vdbench\smoke.dat,threads=1
wd=wd1,sd=sd1,xfersize=4k,rdpct=70,seekpct=100
rd=rd1,wd=wd1,iorate=max,elapsed=5,interval=1
"@ | Set-Content -LiteralPath $parmPath -Encoding ASCII

Write-Host "Running fake Vdbench..."
$process = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $fakeRunner, "-f", $parmPath, "-o", $runRoot) `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -NoNewWindow `
    -PassThru `
    -Wait

$stdout = Get-Content -LiteralPath $stdoutPath -Raw
$stderr = Get-Content -LiteralPath $stderrPath -Raw

if ($process.ExitCode -ne 0) {
    Write-Host $stdout
    Write-Host $stderr -ForegroundColor Red
    throw ("Fake runner failed with exit code {0}" -f $process.ExitCode)
}

if ($stdout -notmatch "Fake Vdbench completed successfully") {
    throw "Fake runner completion marker was not found."
}

if ($stdout -notmatch "(?m)^\d{2}:\d{2}:\d{2}\.\d{3}\s+\d+\s+\d+(\.\d+)?\s+4096\s+70\s+\d+(\.\d+)?") {
    throw "Expected final metrics row with Vdbench-style timestamp was not found."
}

Write-Host ("Smoke test OK. Output: {0}" -f $runRoot)
