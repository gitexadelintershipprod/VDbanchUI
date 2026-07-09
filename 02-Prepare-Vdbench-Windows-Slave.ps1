#requires -RunAsAdministrator
<#
FINAL v4 - Prepare Windows Server 2022 as Vdbench WINDOWS SLAVE.

Lab mode:
- Uses built-in .\Administrator
- Disables Windows Firewall by default
- Disables UAC by default
- Installs Java from C:\install
- Installs OpenSSH Client+Server from C:\install
- Adds Master public key to C:\ProgramData\ssh\administrators_authorized_keys
- Extracts Vdbench to C:\vdbench
- Creates local smoke config, but does NOT run disk workload automatically
- Validates java, sshd, and vdbench -t

Expected files on this Windows slave:
  C:\install\microsoft-jdk-*-windows-x64.exe  OR .msi
  C:\install\OpenSSH-Win64-*.msi
  C:\install\vdbench*.zip
  C:\install\master_id_ed25519.pub

Run:
  Set-ExecutionPolicy Bypass -Scope Process -Force
  C:\install\03-Prepare-Vdbench-Windows-Slave-FINAL.ps1

After reboot, test from Master:
  ssh Administrator@<SLAVE_IP_OR_NAME> hostname
  ssh Administrator@<SLAVE_IP_OR_NAME> java --version
  ssh Administrator@<SLAVE_IP_OR_NAME> C:\vdbench\vdbench.bat -t
#>

param(
    [string]$InstallDir = "C:\install",
    [string]$VdbenchRoot = "C:\vdbench",
    [string]$MasterPublicKeyFile = "C:\install\master_id_ed25519.pub",
    [switch]$KeepFirewallEnabled,
    [switch]$KeepUACEnabled,
    [switch]$ForceJavaInstall
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Run-ProcessChecked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0, 3010)
    )

    Write-Host "Running: $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray

    $p = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru

    Write-Host "ExitCode: $($p.ExitCode)" -ForegroundColor DarkGray

    if ($AllowedExitCodes -notcontains $p.ExitCode) {
        throw "Command failed. File=$FilePath ExitCode=$($p.ExitCode)"
    }

    if ($p.ExitCode -eq 3010) {
        Write-Warning "Installer returned 3010: reboot required."
    }
}

function Refresh-PathFromMachine {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Enable-AdministratorAccount {
    Write-Step "Enabling built-in Administrator"

    try {
        Enable-LocalUser -Name "Administrator"
        Set-LocalUser -Name "Administrator" -PasswordNeverExpires $true
        Write-Host "Administrator enabled and password set to never expire." -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not modify Administrator account. Continuing. Error: $($_.Exception.Message)"
    }
}

function Disable-PowerSaving {
    Write-Step "Disabling sleep and hibernate"

    powercfg /hibernate off
    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change disk-timeout-ac 0

    Write-Host "Power saving disabled." -ForegroundColor Green
}

function Configure-FirewallAndUAC {
    if (-not $KeepFirewallEnabled) {
        Write-Step "Disabling Windows Firewall profiles"
        Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
        Write-Host "Windows Firewall disabled for Domain, Private, Public." -ForegroundColor Yellow
    }
    else {
        Write-Step "Keeping Windows Firewall enabled and adding SSH rule"

        if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-TCP-22" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -Name "OpenSSH-Server-TCP-22" `
                -DisplayName "OpenSSH Server TCP 22" `
                -Enabled True `
                -Direction Inbound `
                -Protocol TCP `
                -Action Allow `
                -LocalPort 22 | Out-Null
        }

        Write-Host "Firewall kept enabled; SSH rule added." -ForegroundColor Green
    }

    if (-not $KeepUACEnabled) {
        Write-Step "Disabling UAC"

        Set-ItemProperty `
            -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
            -Name "EnableLUA" `
            -Value 0

        Write-Warning "UAC disabled. Reboot is required for this to fully apply."
    }
    else {
        Write-Step "Keeping UAC enabled"
    }
}

function Get-JdkMajorFromHome {
    param([string]$JavaHome)

    if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome "bin\java.exe"))) {
        return $null
    }

    if ($JavaHome -match "jdk-(\d+)") {
        return [int]$Matches[1]
    }

    try {
        $ver = & (Join-Path $JavaHome "bin\java.exe") --version 2>&1 | Select-Object -First 1
        if ($ver -match 'openjdk\s+\"?(\d+)\.') {
            return [int]$Matches[1]
        }
        if ($ver -match 'java\s+version\s+\"?(\d+)\.') {
            return [int]$Matches[1]
        }
        if ($ver -match '(\d+)\.\d+\.\d+') {
            return [int]$Matches[1]
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-InstalledJdkDirs {
    $roots = @(
        "C:\Program Files\Microsoft",
        "C:\Program Files\Java",
        "C:\Program Files\Eclipse Adoptium",
        "$env:LOCALAPPDATA\Programs\Microsoft",
        "$env:LOCALAPPDATA\Programs\Java",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $homes = New-Object System.Collections.Generic.List[string]

    foreach ($root in $roots) {
        # Case 1: older/bad /DIR install may place bin\java.exe directly under the root.
        if (Test-Path (Join-Path $root "bin\java.exe")) {
            [void]$homes.Add($root)
        }

        # Case 2: normal JDK folder, e.g. C:\Program Files\Microsoft\jdk-11.0.31.11-hotspot.
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") } |
            ForEach-Object { [void]$homes.Add($_.FullName) }

        # Case 3: nested/user install folder.
        Get-ChildItem $root -Recurse -Filter "java.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\bin\\java\.exe$" } |
            ForEach-Object {
                $javaHome = Split-Path -Parent (Split-Path -Parent $_.FullName)
                if ($javaHome) { [void]$homes.Add($javaHome) }
            }
    }

    # Registry hints, if available.
    $regPaths = @(
        "HKLM:\SOFTWARE\JavaSoft\JDK",
        "HKLM:\SOFTWARE\Microsoft\JDK",
        "HKCU:\SOFTWARE\JavaSoft\JDK",
        "HKCU:\SOFTWARE\Microsoft\JDK"
    )

    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) {
            continue
        }

        Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                foreach ($name in @("JavaHome", "Path")) {
                    $value = $props.$name
                    if ($value -and (Test-Path (Join-Path $value "bin\java.exe"))) {
                        [void]$homes.Add($value)
                    }
                }
            }
            catch {}
        }
    }

    $uniqueHomes = $homes |
        Where-Object { $_ -and (Test-Path (Join-Path $_ "bin\java.exe")) } |
        Select-Object -Unique

    $result = @()
    foreach ($homePath in $uniqueHomes) {
        $item = Get-Item $homePath -ErrorAction SilentlyContinue
        if ($item) {
            $major = Get-JdkMajorFromHome -JavaHome $item.FullName
            $result += [PSCustomObject]@{
                FullName = $item.FullName
                Name     = $item.Name
                Major    = $major
            }
        }
    }

    return $result
}

function Get-InstalledJdkHomeByMajor {
    param([int]$Major)

    $hit = Get-InstalledJdkDirs |
        Where-Object { $_.Major -eq $Major -or $_.Name -match "jdk-$Major(\.|-|$)" -or $_.FullName -match "jdk-$Major(\.|-|$)" } |
        Sort-Object FullName |
        Select-Object -First 1

    if ($hit) { return $hit.FullName }
    return $null
}

function Get-BestInstalledJdkHome {
    foreach ($major in @(11,17,25)) {
        $jdkHomeCandidate = Get-InstalledJdkHomeByMajor -Major $major
        if ($jdkHomeCandidate) { return $jdkHomeCandidate }
    }

    $any = Get-InstalledJdkDirs | Sort-Object FullName | Select-Object -First 1
    if ($any) { return $any.FullName }
    return $null
}

function Get-PreferredJavaInstaller {
    Write-Step "Searching preferred Java installer in $InstallDir"

    $items = @(
        @{ Major = 11; Pattern = "microsoft-jdk-11*-windows-x64.msi" },
        @{ Major = 11; Pattern = "microsoft-jdk-11*-windows-x64.exe" },
        @{ Major = 17; Pattern = "microsoft-jdk-17*-windows-x64.msi" },
        @{ Major = 17; Pattern = "microsoft-jdk-17*-windows-x64.exe" },
        @{ Major = 25; Pattern = "microsoft-jdk-25*-windows-x64.msi" },
        @{ Major = 25; Pattern = "microsoft-jdk-25*-windows-x64.exe" },
        @{ Major = 0;  Pattern = "microsoft-jdk-*-windows-x64.msi" },
        @{ Major = 0;  Pattern = "microsoft-jdk-*-windows-x64.exe" }
    )

    foreach ($item in $items) {
        $file = Get-ChildItem -Path $InstallDir -Filter $item.Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Select-Object -First 1

        if ($file) {
            $major = [int]$item.Major
            if ($major -eq 0 -and $file.Name -match "microsoft-jdk-(\d+)") {
                $major = [int]$Matches[1]
            }

            Write-Host "Selected Java installer: $($file.FullName)" -ForegroundColor Green
            Write-Host "Selected Java major:     $major" -ForegroundColor Green

            return [PSCustomObject]@{
                File  = $file
                Major = $major
            }
        }
    }

    return $null
}

function Set-ActiveJava {
    param([string]$JavaHome)

    if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome "bin\java.exe"))) {
        throw "Invalid JavaHome: $JavaHome"
    }

    Write-Step "Setting active Java"

    $javaBin = Join-Path $JavaHome "bin"

    [Environment]::SetEnvironmentVariable("JAVA_HOME", $JavaHome, "Machine")
    $env:JAVA_HOME = $JavaHome

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $msPattern       = [regex]::Escape("C:\Program Files\Microsoft\") + "jdk-.*\\bin"
    $javaPattern     = [regex]::Escape("C:\Program Files\Java\") + "jdk-.*\\bin"
    $adoptiumPattern = [regex]::Escape("C:\Program Files\Eclipse Adoptium\") + "jdk-.*\\bin"

    $parts = $machinePath -split ";" | Where-Object {
        $_ -and
        ($_ -notmatch $msPattern) -and
        ($_ -notmatch $javaPattern) -and
        ($_ -notmatch $adoptiumPattern)
    }

    $newPath = @($javaBin) + $parts
    [Environment]::SetEnvironmentVariable("Path", ($newPath -join ";"), "Machine")

    Refresh-PathFromMachine

    Write-Host "JAVA_HOME=$JavaHome" -ForegroundColor Green
    Write-Host "Java bin added first in Machine PATH: $javaBin" -ForegroundColor Green

    & "$javaBin\java.exe" --version
}

function Install-JavaAutomatic {
    Write-Step "Installing Java automatically"

    Refresh-PathFromMachine

    $installerInfo = Get-PreferredJavaInstaller

    if ($installerInfo) {
        $installer = $installerInfo.File
        $selectedMajor = $installerInfo.Major

        if (-not $installer -or -not (Test-Path $installer.FullName)) {
            throw "Java installer object is invalid."
        }

        if ($selectedMajor -and $selectedMajor -gt 0 -and -not $ForceJavaInstall) {
            $sameMajorHome = Get-InstalledJdkHomeByMajor -Major $selectedMajor
            if ($sameMajorHome) {
                Write-Host "Selected Java major is already installed. Will use it:" -ForegroundColor Yellow
                Write-Host "  $sameMajorHome" -ForegroundColor Yellow
                Set-ActiveJava -JavaHome $sameMajorHome
                return
            }
        }

        $installDirForJava = "C:\Program Files\Microsoft\"
        $msiFeatures = "FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome"
        $exeTasks = "FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome"

        Write-Host "Java installer file: $($installer.FullName)" -ForegroundColor Green
        Write-Host "Java installer extension: $($installer.Extension)" -ForegroundColor Green
        Write-Host "Java selected major: $selectedMajor" -ForegroundColor Green

        if ($installer.Extension -ieq ".msi") {
            Run-ProcessChecked `
                -FilePath "msiexec.exe" `
                -Arguments @(
                    "/i",
                    "`"$($installer.FullName)`"",
                    "ADDLOCAL=$msiFeatures",
                    "INSTALLDIR=`"$installDirForJava`"",
                    "/quiet",
                    "/norestart"
                )
        }
        elseif ($installer.Extension -ieq ".exe") {
            # Microsoft Build of OpenJDK EXE silent install.
            # Do NOT use /quiet here; this EXE can open the GUI with /quiet.
            Run-ProcessChecked `
                -FilePath $installer.FullName `
                -Arguments @(
                    "/VERYSILENT",
                    "/SUPPRESSMSGBOXES",
                    "/SP-",
                    "/ALLUSERS",
                    "/NORESTART",
                    "/TASKS=`"$exeTasks`""
                )
        }
        else {
            throw "Unsupported Java installer type: $($installer.FullName)"
        }

        Start-Sleep -Seconds 3
        Refresh-PathFromMachine

        $jdkHome = $null
        if ($selectedMajor -and $selectedMajor -gt 0) {
            $jdkHome = Get-InstalledJdkHomeByMajor -Major $selectedMajor
        }

        if (-not $jdkHome) {
            $jdkHome = Get-BestInstalledJdkHome
        }

        if (-not $jdkHome) {
            throw "Java installer completed but no installed JDK folder was detected."
        }

        Set-ActiveJava -JavaHome $jdkHome
        return
    }

    $preferredExisting = Get-BestInstalledJdkHome

    if ($preferredExisting) {
        Write-Warning "No Java installer found, but existing JDK is available. Will use it."
        Set-ActiveJava -JavaHome $preferredExisting
        return
    }

    throw "Java installer not found in $InstallDir and no installed JDK detected."
}
function Install-OpenSSH {
    Write-Step "Installing OpenSSH Client+Server on Windows slave"

    $openSshMsi = Get-ChildItem -Path $InstallDir -Filter "OpenSSH-Win64-*.msi" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $openSshMsi) {
        throw "OpenSSH Win64 MSI not found in $InstallDir"
    }

    $existingSsh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    $existingKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    $existingSshd = Get-Service -Name "sshd" -ErrorAction SilentlyContinue

    if ($existingSsh -and $existingKeygen -and $existingSshd) {
        Write-Host "OpenSSH already appears to be installed." -ForegroundColor Yellow
    }
    else {
        Write-Host "Found OpenSSH MSI: $($openSshMsi.FullName)" -ForegroundColor Green

        Run-ProcessChecked `
            -FilePath "msiexec.exe" `
            -Arguments @(
                "/i",
                "`"$($openSshMsi.FullName)`"",
                "ADDLOCAL=Client,Server",
                "/qn",
                "/norestart"
            )
    }

    Refresh-PathFromMachine

    $sshdService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if (-not $sshdService) {
        Write-Warning "sshd service not found after MSI install. Trying install-sshd.ps1 fallback."

        $installSshd = @(
            Get-ChildItem "C:\Program Files\OpenSSH" -Filter "install-sshd.ps1" -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem "C:\Program Files\OpenSSH-Win64" -Filter "install-sshd.ps1" -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem "C:\Windows\System32\OpenSSH" -Filter "install-sshd.ps1" -Recurse -ErrorAction SilentlyContinue
        ) | Select-Object -First 1

        if ($installSshd) {
            Run-ProcessChecked `
                -FilePath "powershell.exe" `
                -Arguments @(
                    "-ExecutionPolicy", "Bypass",
                    "-File", "`"$($installSshd.FullName)`""
                )
        }
        else {
            throw "Could not find install-sshd.ps1 fallback script."
        }
    }

    New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null

    New-ItemProperty `
        -Path "HKLM:\SOFTWARE\OpenSSH" `
        -Name "DefaultShell" `
        -Value "C:\Windows\System32\cmd.exe" `
        -PropertyType String `
        -Force | Out-Null

    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-TCP-22" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -Name "OpenSSH-Server-TCP-22" `
            -DisplayName "OpenSSH Server TCP 22" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22 | Out-Null
    }

    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Restart-Service sshd -ErrorAction SilentlyContinue

    Write-Host "OpenSSH sshd service is ready." -ForegroundColor Green
}

function Add-MasterPublicKey {
    Write-Step "Adding Master public key for Administrator SSH login"

    if (-not (Test-Path $MasterPublicKeyFile)) {
        throw "Master public key not found: $MasterPublicKeyFile. Copy C:\install\master_id_ed25519.pub from Master to this slave/template first."
    }

    $sshDataDir = "C:\ProgramData\ssh"
    $adminKeys  = Join-Path $sshDataDir "administrators_authorized_keys"

    New-Item -ItemType Directory -Force -Path $sshDataDir | Out-Null

    $key = (Get-Content $MasterPublicKeyFile -Raw).Trim()

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Master public key file is empty: $MasterPublicKeyFile"
    }

    if ($key -notmatch "^ssh-(rsa|ed25519|ecdsa)\s+") {
        throw "Invalid public key content in $MasterPublicKeyFile. Expected line starting with ssh-rsa, ssh-ed25519, or ssh-ecdsa."
    }

    # IMPORTANT:
    # Overwrite the final OpenSSH admin authorized-keys file.
    # The previous append-based logic could leave an empty or invalid file in template/cloned systems.
    [System.IO.File]::WriteAllText($adminKeys, $key + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

    Write-Host "Master public key written to $adminKeys" -ForegroundColor Green

    Write-Step "Fixing administrators_authorized_keys permissions"

    icacls $adminKeys /inheritance:r | Out-Null

    # S-1-5-18      = NT AUTHORITY\SYSTEM
    # S-1-5-32-544  = BUILTIN\Administrators
    icacls $adminKeys /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null

    icacls $adminKeys /remove:g `
        "BUILTIN\Users" `
        "Users" `
        "Authenticated Users" `
        "Everyone" `
        "*S-1-5-32-545" `
        "*S-1-5-11" `
        "*S-1-1-0" 2>$null | Out-Null

    Write-Host ("Final ACL for {0}:" -f $adminKeys) -ForegroundColor Cyan
    icacls $adminKeys

    Write-Host "`nAuthorized key fingerprint:" -ForegroundColor Cyan
    $fpOutput = & ssh-keygen -lf $adminKeys 2>&1
    $fpExit = $LASTEXITCODE
    $fpOutput | ForEach-Object { Write-Host $_ }

    if ($fpExit -ne 0) {
        Write-Host "`nFile content for debugging:" -ForegroundColor Yellow
        Get-Content $adminKeys -ErrorAction SilentlyContinue
        throw "administrators_authorized_keys is not a valid public key file after writing."
    }

    Write-Host "`nAuthorized key content:" -ForegroundColor Cyan
    Get-Content $adminKeys

    Restart-Service sshd -ErrorAction SilentlyContinue
}
function Install-Vdbench {
    Write-Step "Installing Vdbench to $VdbenchRoot"

    $zip = Get-ChildItem -Path $InstallDir -Filter "vdbench*.zip" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $zip) {
        throw "Vdbench zip not found in $InstallDir. Expected vdbench50407.zip"
    }

    New-Item -ItemType Directory -Force -Path $VdbenchRoot | Out-Null

    $tempExtract = Join-Path $env:TEMP ("vdbench_extract_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null

    Expand-Archive -Path $zip.FullName -DestinationPath $tempExtract -Force

    $vdbenchBat = Get-ChildItem -Path $tempExtract -Filter "vdbench.bat" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $vdbenchBat) {
        throw "vdbench.bat not found inside $($zip.FullName)"
    }

    $sourceRoot = $vdbenchBat.Directory.FullName

    Copy-Item -Path (Join-Path $sourceRoot "*") -Destination $VdbenchRoot -Recurse -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $VdbenchRoot "cfg") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $VdbenchRoot "output") | Out-Null

    Remove-Item -Recurse -Force $tempExtract -ErrorAction SilentlyContinue

    if (-not (Test-Path (Join-Path $VdbenchRoot "vdbench.bat"))) {
        throw "Vdbench install failed. Missing $VdbenchRoot\vdbench.bat"
    }

    Write-Host "Vdbench installed in $VdbenchRoot" -ForegroundColor Green
}


function Fix-VdbenchWindowsLauncher {
    Write-Step "Fixing Windows Vdbench launcher"

    $bat = Join-Path $VdbenchRoot "vdbench.bat"

    if (-not (Test-Path $bat)) {
        throw "Missing Vdbench batch file: $bat"
    }

    $backup = Join-Path $VdbenchRoot ("vdbench.bat.original_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item $bat $backup -Force
    Write-Host "Backup created: $backup" -ForegroundColor Green

    $content = Get-Content $bat -Raw

    $fixed = $content `
        -replace '-cp "%cp% "', '-cp "%cp%"' `
        -replace "-cp '%cp% '", "-cp '%cp%'" `
        -replace "-cp %cp% ", "-cp %cp%"

    if ($fixed -ne $content) {
        Set-Content -Path $bat -Value $fixed -Encoding ASCII
        Write-Host "vdbench.bat classpath trailing-space bug fixed." -ForegroundColor Green
    }
    else {
        Write-Host "No classpath trailing-space pattern found, or already fixed." -ForegroundColor Yellow
    }

    Write-Host "Current -cp lines:" -ForegroundColor Cyan
    cmd /c "findstr /n /c:""-cp"" ""$bat"""
}

function Create-LocalSmokeConfig {
    Write-Step "Creating local Vdbench smoke config"

    $cfgDir = Join-Path $VdbenchRoot "cfg"
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

    $cfgFile = Join-Path $cfgDir "local_smoke_readonly.cfg"

    $cfg = @"
* Local read-only smoke test
* Change PhysicalDrive1 if your test disk number is different.
* Do NOT use PhysicalDrive0 if it is the OS disk.

sd=sd1,lun=\\.\PhysicalDrive1,threads=4,size=1g
wd=wd1,sd=sd1,xfersize=4k,rdpct=100,seekpct=100
rd=rd1,wd=wd1,iorate=100,elapsed=60,interval=1
"@

    Set-Content -Path $cfgFile -Value $cfg -Encoding ascii
    Write-Host "Created: $cfgFile" -ForegroundColor Green
}

function Show-Validation {
    Write-Step "Running local validation"

    Refresh-PathFromMachine

    Write-Host ""
    Write-Host "java --version:" -ForegroundColor Cyan
    & java --version

    Write-Host ""
    Write-Host "JAVA_HOME:" -ForegroundColor Cyan
    Write-Host $env:JAVA_HOME

    Write-Host ""
    Write-Host "ssh -V:" -ForegroundColor Cyan
    $sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($sshCmd) {
        cmd /c "ssh -V 2>&1"
    }
    else {
        Write-Warning "ssh.exe not found in PATH."
    }

    Write-Host ""
    Write-Host "OpenSSH service:" -ForegroundColor Cyan
    Get-Service sshd | Format-Table Name,Status,StartType -AutoSize

    Write-Host ""
    Write-Host "Vdbench local test:" -ForegroundColor Cyan
    Push-Location $VdbenchRoot
    & .\vdbench.bat -t
    Pop-Location

    Write-Step "Disk list"
    Get-Disk | Sort-Object Number |
        Format-Table Number,FriendlyName,Size,BusType,PartitionStyle,IsBoot,IsSystem,IsOffline,IsReadOnly -AutoSize
}

$logPath = Join-Path $InstallDir "Prepare-Vdbench-Windows-Slave-FINAL-v4.log"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Step "Starting Vdbench WINDOWS SLAVE preparation"

    Write-Host "InstallDir          = $InstallDir"
    Write-Host "VdbenchRoot         = $VdbenchRoot"
    Write-Host "MasterPublicKeyFile = $MasterPublicKeyFile"
    Write-Host "Current user        = $env:USERDOMAIN\$env:USERNAME"
    Write-Host "ComputerName        = $env:COMPUTERNAME"

    Enable-AdministratorAccount
    Disable-PowerSaving
    Configure-FirewallAndUAC
    Install-JavaAutomatic
    Install-OpenSSH
    Add-MasterPublicKey
    Install-Vdbench
    Fix-VdbenchWindowsLauncher
    Create-LocalSmokeConfig
    Show-Validation

    Write-Step "DONE"

    Write-Host "Vdbench WINDOWS SLAVE is prepared." -ForegroundColor Green
    Write-Host ""
    Write-Host "From MASTER test:" -ForegroundColor Yellow
    Write-Host "  ssh Administrator@$env:COMPUTERNAME hostname"
    Write-Host "  ssh Administrator@$env:COMPUTERNAME java --version"
    Write-Host "  ssh Administrator@$env:COMPUTERNAME C:\vdbench\vdbench.bat -t"
    Write-Host ""
    Write-Host "Vdbench path for distributed config:" -ForegroundColor Yellow
    Write-Host "  vdbench=c:\vdbench"
    Write-Host ""
    Write-Host "Windows raw disk example:" -ForegroundColor Yellow
    Write-Host "  lun=\\.\PhysicalDrive1"
    Write-Host ""
    Write-Host "Log file:" -ForegroundColor Yellow
    Write-Host "  $logPath"

    if (-not $KeepUACEnabled) {
        Write-Warning "Reboot this slave before cloning/testing because UAC change requires reboot."
    }
}
finally {
    Stop-Transcript | Out-Null
}
