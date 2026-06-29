function Ensure-Directory {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Read-TextFile {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$Fallback
    )
    $text = Read-TextFile $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value,
        [switch]$AsArray
    )
    $dir = Split-Path -Parent $Path
    Ensure-Directory $dir
    if ($AsArray) {
        $json = ConvertTo-Json -InputObject @($Value) -Depth 20
    } else {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Copy-ObjectJson {
    param([object]$Value)
    return (($Value | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) {
        return $DefaultValue
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $DefaultValue
    }
    return $prop.Value
}

function Set-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) {
        return '""'
    }
    return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Merge-DefaultProperties {
    param(
        [object]$Target,
        [object]$Defaults
    )
    $changed = $false
    foreach ($prop in $Defaults.PSObject.Properties) {
        if ($null -eq $Target.PSObject.Properties[$prop.Name]) {
            $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            $changed = $true
        }
    }
    return $changed
}

function Sanitize-FileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name
    foreach ($char in $invalid) {
        $result = $result.Replace([string]$char, "-")
    }
    return $result.Trim()
}

function Format-ByteSize {
    param([object]$Bytes)
    $value = 0.0
    if ($null -ne $Bytes) {
        [void][double]::TryParse([string]$Bytes, [ref]$value)
    }
    if ($value -ge 1tb) {
        return ("{0:N2} TB" -f ($value / 1tb))
    }
    if ($value -ge 1gb) {
        return ("{0:N2} GB" -f ($value / 1gb))
    }
    if ($value -ge 1mb) {
        return ("{0:N2} MB" -f ($value / 1mb))
    }
    return ("{0:N0} bytes" -f $value)
}

function Invoke-CapturedProcess {
    param(
        [string]$FileName,
        [string]$Arguments,
        [int]$TimeoutMs = 20000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $finished = $process.WaitForExit($TimeoutMs)
    if (-not $finished) {
        try {
            Stop-ProcessTree -Process $process
        } catch {
        }
        throw ("Command timed out: {0} {1}" -f $FileName, $Arguments)
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $process.StandardOutput.ReadToEnd()
        StdErr = $process.StandardError.ReadToEnd()
    }
}

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    try {
        Ensure-Directory $script:LogRoot
        $line = ("{0} [{1}] {2}" -f (Get-Date).ToString("o"), $Level, $Message)
        $logPath = Join-Path $script:LogRoot "app.log"
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Expand-ReadinessCheckerArguments {
    param(
        [string]$Template,
        [string]$HostName,
        [string]$VdbenchPath,
        [string]$Target
    )
    $expanded = $Template
    $replacements = @{
        "{Host}" = (Quote-ProcessArgument $HostName)
        "{VdbenchPath}" = (Quote-ProcessArgument $VdbenchPath)
        "{Target}" = (Quote-ProcessArgument $Target)
    }
    foreach ($token in $replacements.Keys) {
        $expanded = $expanded.Replace($token, $replacements[$token])
    }
    return $expanded
}
