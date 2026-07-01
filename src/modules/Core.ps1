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
    # [powershell]::EndInvoke() wraps even a single output object in a
    # PSDataCollection<PSObject> (confirmed empirically 2026-07-01: a
    # background job returning exactly one pscustomobject comes back from
    # EndInvoke() as a 1-item collection, not the raw object). Direct
    # dot-notation property access ($Object.Foo) transparently "reaches
    # into" a collection with exactly one element - PowerShell's own
    # member-access adapter does this - but this function's own explicit
    # $Object.PSObject.Properties[$Name] lookup below does NOT get that same
    # treatment: it queries the wrapper collection's own properties, which
    # never has $Name, silently returning $DefaultValue every time no matter
    # what the real value inside actually was. This was a real,
    # previously-undetected bug: any caller passing a
    # Start-BackgroundUiWork/EndInvoke() OnComplete "$Result" straight into
    # this function always got $DefaultValue back for every property,
    # regardless of what Was really set. Unwrap a same single-item,
    # non-string, non-dictionary collection first so this function behaves
    # identically whether $Object came from EndInvoke() or was constructed
    # directly - matching what direct dot-notation access already does.
    if ($Object -isnot [string] -and $Object -isnot [System.Collections.IDictionary] -and
        $Object -is [System.Collections.ICollection] -and $Object.Count -eq 1) {
        foreach ($item in $Object) {
            $Object = $item
        }
    }
    if ($null -eq $Object) {
        return $DefaultValue
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
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

function Get-AppLogLevelRank {
    param([string]$Level)
    $normalized = ([string]$Level).ToUpperInvariant()
    switch ($normalized) {
        "DEBUG" { return 0 }
        "INFO" { return 1 }
        "WARN" { return 2 }
        "ERROR" { return 3 }
        default { return 1 }
    }
}

function Get-AppLogMinLevel {
    $configured = "DEBUG"
    if ($null -ne $script:Settings) {
        $configured = [string](Get-PropertyValue $script:Settings "LogLevel" "DEBUG")
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = "DEBUG"
    }
    return $configured.ToUpperInvariant()
}

function Format-AppLogException {
    param([System.Exception]$Exception)
    if ($null -eq $Exception) {
        return ""
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $current = $Exception
    $depth = 0
    while ($null -ne $current -and $depth -lt 6) {
        $prefix = if ($depth -eq 0) { "Exception" } else { ("Inner[{0}]" -f $depth) }
        [void]$parts.Add(("{0}: {1}" -f $prefix, $current.GetType().FullName))
        [void]$parts.Add(("{0}: {1}" -f $prefix, $current.Message))
        if (-not [string]::IsNullOrWhiteSpace($current.StackTrace)) {
            [void]$parts.Add(("{0} stack:" -f $prefix))
            [void]$parts.Add($current.StackTrace)
        }
        $current = $current.InnerException
        $depth++
    }
    return ($parts -join [Environment]::NewLine)
}

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [System.Exception]$Exception = $null
    )
    try {
        Ensure-Directory $script:LogRoot
        $normalizedLevel = ([string]$Level).ToUpperInvariant()
        $minLevel = Get-AppLogMinLevel
        if ((Get-AppLogLevelRank $normalizedLevel) -lt (Get-AppLogLevelRank $minLevel)) {
            return
        }

        $line = ("{0} [{1}] {2}" -f (Get-Date).ToString("o"), $normalizedLevel, $Message)
        if ($null -ne $Exception) {
            $formatted = Format-AppLogException $Exception
            if (-not [string]::IsNullOrWhiteSpace($formatted)) {
                $line += [Environment]::NewLine + $formatted
            }
        }

        $logName = if ($normalizedLevel -eq "DEBUG") { "debug.log" } else { "app.log" }
        $logPath = Join-Path $script:LogRoot $logName
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Write-DebugLog {
    param(
        [string]$Message,
        [System.Exception]$Exception = $null
    )
    Write-AppLog $Message "DEBUG" $Exception
}

function Register-AppExceptionLogging {
    if ($script:AppExceptionLoggingRegistered) {
        return
    }
    $script:AppExceptionLoggingRegistered = $true
    [System.Windows.Forms.Application]::Add_ThreadException({
        param($sender, $eventArgs)
        try {
            Write-AppLog ("UI thread exception: {0}" -f $eventArgs.Exception.Message) "ERROR" $eventArgs.Exception
        } catch {
        }
    })
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        try {
            if ($eventArgs.ExceptionObject -is [System.Exception]) {
                $ex = [System.Exception]$eventArgs.ExceptionObject
                Write-AppLog ("Unhandled domain exception: {0}" -f $ex.Message) "ERROR" $ex
            } else {
                Write-AppLog ("Unhandled domain exception: {0}" -f $eventArgs.ExceptionObject) "ERROR"
            }
        } catch {
        }
    })
}

function Expand-ReadinessCheckerArguments {
    param(
        [string]$Template,
        [string]$HostName,
        [string]$VdbenchPath,
        [string]$Target,
        [string]$OsType = ""
    )
    $expanded = $Template
    # {HostFlag} matches the real shipped checker script's actual contract:
    # -WindowsHosts / -LinuxHosts, chosen by THIS row's configured OS, each
    # taking the host to check remotely over SSH (see
    # docs/MASTER_SLAVE_MODEL.md - "Readiness checker script contract"). This
    # is different from a generic single -HostName-style flag: without the
    # right flag *name*, the checker has no way to know which parameter list
    # a bare host string even belongs to. Anything other than "Linux"
    # (including blank/unset, the state of a freshly-added row before OS is
    # even picked) is treated as Windows.
    $hostFlagName = if ([string]$OsType -eq "Linux") { "-LinuxHosts" } else { "-WindowsHosts" }
    $hostFlag = if ([string]::IsNullOrWhiteSpace($HostName)) { "" } else { "$hostFlagName $(Quote-ProcessArgument $HostName)" }
    $replacements = @{
        "{Host}" = (Quote-ProcessArgument $HostName)
        "{VdbenchPath}" = (Quote-ProcessArgument $VdbenchPath)
        "{Target}" = (Quote-ProcessArgument $Target)
        "{HostFlag}" = $hostFlag
    }
    foreach ($token in $replacements.Keys) {
        $expanded = $expanded.Replace($token, $replacements[$token])
    }
    return $expanded
}

function Initialize-DpiAwareness {
    if ($script:DpiAwarenessInitialized) {
        return
    }
    $script:DpiAwarenessInitialized = $true
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class VdbenchDpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int value);
}
"@ -ErrorAction Stop | Out-Null
        try {
            [void][VdbenchDpiHelper]::SetProcessDpiAwareness(2)
        } catch {
            [void][VdbenchDpiHelper]::SetProcessDPIAware()
        }
    } catch {
    }
}
