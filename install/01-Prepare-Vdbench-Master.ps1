#requires -RunAsAdministrator
<#
FINAL v4.7 - Prepare Windows Server 2022 as Vdbench MASTER.

Fixes included:
- Java installation is automatic and non-interactive.
- Microsoft JDK installer is run with feature selection:
    FeatureMain, FeatureEnvironment, FeatureJarFileRunWith, FeatureJavaHome
- Java preference order:
    1) Microsoft JDK 11
    2) Microsoft JDK 17
    3) Microsoft JDK 25
    4) any microsoft-jdk-*-windows-x64 installer
- If Java 25 already exists but Java 11 installer is present, Java 11 is installed and made active.
- JAVA_HOME and Machine PATH are forced to the selected JDK.
- OpenSSH Client+Server installation.
- Master SSH key creation with empty passphrase, non-interactive.
- Master private key ACL hardening for OpenSSH:
    C:\install\ssh\id_rsa -> only Administrator + SYSTEM
- Vdbench install to:
    C:\vdbench
- Vdbench Windows launcher fix:
    removes the bad classpath trailing space in vdbench.bat:
      -cp "%cp% "  ->  -cp "%cp%"
- Creates distributed Windows config template.

Expected files in C:\install:
  microsoft-jdk-11.0.31-windows-x64.exe
  OpenSSH-Win64-v10.0.0.0.msi
  vdbench50407.zip

Run:
  Set-ExecutionPolicy Bypass -Scope Process -Force
  C:\install\01-Prepare-Vdbench-Master-FINAL-v4.ps1

Force recreate SSH key:
  C:\install\01-Prepare-Vdbench-Master-FINAL-v4.ps1 -RecreateSshKey

Force Java installer rerun:
  C:\install\01-Prepare-Vdbench-Master-FINAL-v4.ps1 -ForceJavaInstall
#>

param(
    [string]$InstallDir = "C:\install",
    [string]$VdbenchRoot = "C:\vdbench",
    [int]$VdbenchMasterPort = 5570,

    [switch]$KeepFirewallEnabled,
    [switch]$KeepUACEnabled,
    [switch]$RecreateSshKey,
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
        Write-Step "Keeping Windows Firewall enabled and adding rules"

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

        if (-not (Get-NetFirewallRule -Name "Vdbench-Master-TCP-$VdbenchMasterPort" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -Name "Vdbench-Master-TCP-$VdbenchMasterPort" `
                -DisplayName "Vdbench Master TCP $VdbenchMasterPort" `
                -Enabled True `
                -Direction Inbound `
                -Protocol TCP `
                -Action Allow `
                -LocalPort $VdbenchMasterPort | Out-Null
        }

        Write-Host "Firewall kept enabled; SSH and Vdbench rules added." -ForegroundColor Green
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
        # Case 1: installer used /DIR and installed directly into the root itself:
        #   C:\Program Files\Microsoft\bin\java.exe
        if (Test-Path (Join-Path $root "bin\java.exe")) {
            [void]$homes.Add($root)
        }

        # Case 2: normal Microsoft JDK folder:
        #   C:\Program Files\Microsoft\jdk-11.0.31.11-hotspot\bin\java.exe
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") } |
            ForEach-Object { [void]$homes.Add($_.FullName) }

        # Case 3: user install or nested install folder.
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

    throw "Java installer not found in $InstallDir. Expected microsoft-jdk-11/17/25-*-windows-x64.exe or .msi"
}
function Install-OpenSSH {
    Write-Step "Installing OpenSSH on Master"

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
            Write-Warning "Could not find install-sshd.ps1 fallback script. Continuing because Master mainly needs SSH client."
        }
    }

    New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
    New-ItemProperty `
        -Path "HKLM:\SOFTWARE\OpenSSH" `
        -Name "DefaultShell" `
        -Value "C:\Windows\System32\cmd.exe" `
        -PropertyType String `
        -Force | Out-Null

    $sshdService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($sshdService) {
        Start-Service sshd -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        Restart-Service sshd -ErrorAction SilentlyContinue
    }

    Refresh-PathFromMachine

    Write-Host "OpenSSH check:" -ForegroundColor Cyan
    cmd /c "ssh -V 2>&1"
    where.exe ssh-keygen
}

function Get-SshKeygenPath {
    $candidates = @(
        "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe",
        "C:\Windows\System32\OpenSSH\ssh-keygen.exe",
        "C:\Program Files\OpenSSH\ssh-keygen.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    $cmd = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw "ssh-keygen.exe not found."
}

function New-SshKeyNonInteractive {
    param(
        [string]$SshKeygenPath,
        [string]$PrivateKeyPath,
        [int]$TimeoutSeconds = 60
    )

    $system32Keygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
    if (Test-Path $system32Keygen) {
        $SshKeygenPath = $system32Keygen
    }

    Write-Host "Creating RSA key with empty passphrase." -ForegroundColor Yellow
    Write-Host "ssh-keygen: $SshKeygenPath" -ForegroundColor DarkGray
    Write-Host "key path:   $PrivateKeyPath" -ForegroundColor DarkGray

    $parent = Split-Path -Parent $PrivateKeyPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $cmdLine = "$SshKeygenPath -t rsa -b 4096 -f `"$PrivateKeyPath`" -N `"`" -q"
    Write-Host "cmd.exe /d /c $cmdLine" -ForegroundColor DarkGray

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/d /c $cmdLine"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch {}
        throw "ssh-keygen timed out after $TimeoutSeconds seconds. Process was killed."
    }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }

    if ($p.ExitCode -ne 0) {
        throw "ssh-keygen failed with exit code $($p.ExitCode)"
    }

    if (-not (Test-Path $PrivateKeyPath)) {
        throw "Private key was not created: $PrivateKeyPath"
    }

    if (-not (Test-Path "$PrivateKeyPath.pub")) {
        throw "Public key was not created: $PrivateKeyPath.pub"
    }
}

function Fix-MasterPrivateKeyPermissions {
    param([string]$PrivateKeyPath = "C:\install\ssh\id_rsa")

    Write-Step "Fixing Master private key permissions"

    if (-not (Test-Path $PrivateKeyPath)) {
        throw "Private key not found: $PrivateKeyPath"
    }

    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    takeown /F $PrivateKeyPath | Out-Null
    icacls $PrivateKeyPath /inheritance:r | Out-Null

    icacls $PrivateKeyPath /remove:g `
        "BUILTIN\Users" `
        "Users" `
        "Authenticated Users" `
        "Everyone" `
        "*S-1-5-32-545" `
        "*S-1-5-11" `
        "*S-1-1-0" 2>$null | Out-Null

    icacls $PrivateKeyPath /grant:r "*$($userSid):F" "*S-1-5-18:F" | Out-Null

    Write-Host ("Final ACL for {0}:" -f $PrivateKeyPath) -ForegroundColor Cyan
    icacls $PrivateKeyPath
}

function Prepare-MasterSshKeyAndConfig {
    Write-Step "Preparing Master SSH key and SSH client config"

    $sshDir = "C:\install\ssh"
    $MasterPrivateKey = Join-Path $sshDir "id_rsa"
    $MasterPublicKey  = Join-Path $sshDir "id_rsa.pub"
    $ExportedPublicKey = "C:\install\master_id_ed25519.pub"

    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null

    if ($RecreateSshKey) {
        Write-Warning "RecreateSshKey specified. Removing existing SSH key."
        Remove-Item -Force $MasterPrivateKey -ErrorAction SilentlyContinue
        Remove-Item -Force $MasterPublicKey -ErrorAction SilentlyContinue
        Remove-Item -Force $ExportedPublicKey -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $MasterPrivateKey) -or -not (Test-Path $MasterPublicKey)) {
        Remove-Item -Force $MasterPrivateKey -ErrorAction SilentlyContinue
        Remove-Item -Force $MasterPublicKey -ErrorAction SilentlyContinue
        $sshKeygen = Get-SshKeygenPath
        New-SshKeyNonInteractive -SshKeygenPath $sshKeygen -PrivateKeyPath $MasterPrivateKey -TimeoutSeconds 60
    }
    else {
        Write-Host "Master SSH key already exists: $MasterPrivateKey" -ForegroundColor Yellow
    }

    Fix-MasterPrivateKeyPermissions -PrivateKeyPath $MasterPrivateKey

    if (-not (Test-Path $MasterPublicKey)) {
        throw "SSH public key was not created: $MasterPublicKey"
    }

    Copy-Item $MasterPublicKey $ExportedPublicKey -Force

    $sshConfigPath = Join-Path "$env:USERPROFILE\.ssh" "config"

@"
Host *
    User Administrator
    IdentityFile C:\install\ssh\id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile NUL
    ServerAliveInterval 30
    ServerAliveCountMax 4
"@ | Set-Content $sshConfigPath -Encoding ascii

    Write-Host ""
    Write-Host "Master SSH key folder:" -ForegroundColor Cyan
    Get-ChildItem $sshDir

    Write-Host ""
    Write-Host "Exported public key for slaves:" -ForegroundColor Cyan
    Get-Content $ExportedPublicKey

    Write-Host ""
    Write-Host "SSH client config:" -ForegroundColor Cyan
    Get-Content $sshConfigPath
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
    $fixed = $content -replace '-cp "%cp% "', '-cp "%cp%"'

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

function Create-DistributedConfigTemplate {
    Write-Step "Creating sample Vdbench distributed config"

    $cfgDir = Join-Path $VdbenchRoot "cfg"
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfgFile = Join-Path $cfgDir "distributed_windows_8hosts_template.cfg"

    $cfg = @"
* ==========================================================
* Vdbench native distributed config template - Windows hosts
* Master path: $VdbenchRoot
* Slave path:  C:\vdbench
* User:        Administrator
* Port:        $VdbenchMasterPort
* ==========================================================

port=$VdbenchMasterPort
report=host_detail
report=slave_detail

hd=default,user=Administrator,shell=ssh,jvms=1

* Change system= to IP or hostname after cloning
hd=win01,system=win01,vdbench=c:\vdbench
hd=win02,system=win02,vdbench=c:\vdbench
hd=win03,system=win03,vdbench=c:\vdbench
hd=win04,system=win04,vdbench=c:\vdbench
hd=win05,system=win05,vdbench=c:\vdbench
hd=win06,system=win06,vdbench=c:\vdbench
hd=win07,system=win07,vdbench=c:\vdbench
hd=win08,system=win08,vdbench=c:\vdbench

* WARNING:
* Replace PhysicalDrive1 with the real TEST disk on each host.
* Do NOT use PhysicalDrive0 if it is the OS disk.

sd=sd_win01,host=win01,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win02,host=win02,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win03,host=win03,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win04,host=win04,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win05,host=win05,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win06,host=win06,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win07,host=win07,lun=\\.\PhysicalDrive1,threads=8,size=10g
sd=sd_win08,host=win08,lun=\\.\PhysicalDrive1,threads=8,size=10g

* Read-only smoke test
wd=wd_smoke,sd=*,xfersize=4k,rdpct=100,seekpct=100
rd=smoke_readonly,wd=wd_smoke,iorate=100,elapsed=60,interval=1

* Real stress example - enable later after smoke test is OK
* wd=wd_4k_70r,sd=*,xfersize=4k,rdpct=70,seekpct=100
* rd=run_4k_70r,wd=wd_4k_70r,iorate=max,elapsed=30m,warmup=5m,interval=1
"@

    Set-Content -Path $cfgFile -Value $cfg -Encoding ascii
    Write-Host "Created config template: $cfgFile" -ForegroundColor Green
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
    cmd /c "ssh -V 2>&1"

    Write-Host ""
    Write-Host "OpenSSH service:" -ForegroundColor Cyan
    $sshdService = Get-Service sshd -ErrorAction SilentlyContinue
    if ($sshdService) {
        $sshdService | Format-Table Name,Status,StartType -AutoSize
    }
    else {
        Write-Warning "sshd service not found."
    }

    Write-Host ""
    Write-Host "Master private key ACL:" -ForegroundColor Cyan
    icacls "C:\install\ssh\id_rsa"

    Write-Host ""
    Write-Host "Vdbench local test:" -ForegroundColor Cyan
    cmd /c "cd /d $VdbenchRoot && vdbench.bat -t"

    Write-Step "Local disk list"
    Get-Disk | Sort-Object Number |
        Format-Table Number,FriendlyName,Size,BusType,PartitionStyle,IsBoot,IsSystem,IsOffline,IsReadOnly -AutoSize
}

Get-Process ssh-keygen -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$logPath = Join-Path $InstallDir "Prepare-Vdbench-Master-FINAL-v4.7.log"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Step "Starting Vdbench MASTER preparation FINAL v4.7"

    Write-Host "InstallDir          = $InstallDir"
    Write-Host "VdbenchRoot         = $VdbenchRoot"
    Write-Host "VdbenchMasterPort   = $VdbenchMasterPort"
    Write-Host "Current user        = $env:USERDOMAIN\$env:USERNAME"
    Write-Host "ComputerName        = $env:COMPUTERNAME"

    Enable-AdministratorAccount
    Disable-PowerSaving
    Configure-FirewallAndUAC
    Install-JavaAutomatic
    Install-OpenSSH
    Install-Vdbench
    Fix-VdbenchWindowsLauncher
    Create-DistributedConfigTemplate
    Prepare-MasterSshKeyAndConfig
    Show-Validation

    Write-Step "DONE"

    Write-Host "Vdbench MASTER is prepared." -ForegroundColor Green
    Write-Host ""
    Write-Host "Important paths:" -ForegroundColor Yellow
    Write-Host "  Vdbench root:                $VdbenchRoot"
    Write-Host "  Sample distributed config:   $VdbenchRoot\cfg\distributed_windows_8hosts_template.cfg"
    Write-Host "  Output folder:               $VdbenchRoot\output"
    Write-Host "  Private SSH key:             C:\install\ssh\id_rsa"
    Write-Host "  Public SSH key for slaves:   C:\install\master_id_ed25519.pub"
    Write-Host "  SSH client config:           $env:USERPROFILE\.ssh\config"
    Write-Host "  Log file:                    $logPath"
    Write-Host ""
    Write-Host "Copy this file to every Windows slave:"
    Write-Host "  C:\install\master_id_ed25519.pub"
    Write-Host ""
    Write-Host "After slaves are ready, test from Master:"
    Write-Host "  ssh Administrator@win01 hostname"
    Write-Host "  ssh Administrator@win01 java --version"
    Write-Host "  ssh Administrator@win01 C:\vdbench\vdbench.bat -t"
    Write-Host ""
    Write-Host "Then run smoke distributed test:"
    Write-Host "  $VdbenchRoot\vdbench.bat -f $VdbenchRoot\cfg\distributed_windows_8hosts_template.cfg -o $VdbenchRoot\output\smoke001"

    if (-not $KeepUACEnabled) {
        Write-Warning "Reboot this Master before real distributed testing because UAC change requires reboot."
    }
}
finally {
    Stop-Transcript | Out-Null
}
