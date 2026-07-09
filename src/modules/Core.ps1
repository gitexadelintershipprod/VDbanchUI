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

function Convert-ToShellSingleQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Convert-ToPowerShellSingleQuoted {
    # PowerShell's own single-quoted string literal escaping convention: a
    # literal embedded single quote is represented by DOUBLING it (''), not
    # by the POSIX shell '\'' trick that Convert-ToShellSingleQuoted uses -
    # the two are not interchangeable. Use this specifically when embedding
    # an arbitrary value (e.g. a user-supplied path) into PowerShell script
    # text that will be sent to a remote powershell.exe.
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-VdbenchOpenflagsForOsType {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return "o_direct"
    }
    return "directio"
}

function Get-LocalHostOsType {
    # $IsLinux exists only in PowerShell 6+; Windows PowerShell 5.x (used by
    # Validate-Project.ps1 / -SelfTest) throws under Set-StrictMode if it is
    # referenced when unset. RuntimeInformation works on both hosts.
    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [System.Runtime.InteropServices.OSPlatform]::Linux)) {
            return "Linux"
        }
    } catch {
    }
    return "Windows"
}

function Get-RemoteExecCommandParts {
    <#
    Builds the "remote command" portion of an ssh.exe argument list for
    running $RemoteScript on a slave, structured so it survives OpenSSH's
    client-side argument rejoining without being mangled.

    Root cause of the bug this avoids (found 2026-07-01, from a user
    screenshot showing "'ForEach-Object' is not recognized as an internal or
    external command" after clicking Browse on a Windows slave): OpenSSH's
    client concatenates ALL "remote command" arguments together with a
    single space before sending them to the server (confirmed via
    Win32-OpenSSH GitHub issue #1082 and multiple independent sources) - any
    LOCAL quoting used to keep e.g. "powershell.exe", "-Command", and the
    actual script text together as SEPARATE argv elements on this side is
    silently stripped by ssh.exe's own argv parsing and never reapplied once
    ssh.exe rejoins the remaining pieces for the wire. On Windows, the
    remote sshd additionally always routes the joined string through an
    intermediate cmd.exe layer - even when the configured DefaultShell is
    something else - before it reaches the real target shell (also
    confirmed via that GitHub issue). Once the joined, now-unquoted script
    text (containing PowerShell's own pipe operator `|`) reaches cmd.exe,
    cmd.exe interprets that pipe as ITS OWN operator and tries to launch a
    separate program literally named after whatever cmdlet follows the pipe
    (e.g. ForEach-Object) - which fails with exactly "not recognized as an
    internal or external command, operable program or batch file."

    For Windows, the fix is `-EncodedCommand` (Base64 of the UTF-16LE script
    text): the resulting command line (powershell.exe -NoProfile
    -EncodedCommand <base64>) contains zero shell-special characters in any
    shell dialect, so it is immune to being reinterpreted no matter how many
    naive space-join/re-parse layers it passes through - this is the
    standard, widely-recommended technique for this exact class of problem.

    For Linux there is no intermediate cmd.exe-style layer, so the simpler
    fix is to pass "sh -lc '<script>'" as ONE single, already-fully-formed
    string (POSIX single-quoted internally via Convert-ToShellSingleQuoted,
    then Windows-style quoted as a whole via Quote-ProcessArgument for
    ssh.exe's own local argv parsing) instead of as three separate tokens -
    this makes ssh.exe's rejoin step a no-op (nothing left to join), so the
    remote login shell's single, intentional re-parse of the whole "-c"
    argument sees the unmangled "sh -lc '<script>'" invocation exactly as
    written.
    #>
    param(
        [string]$OsType,
        [string]$RemoteScript
    )
    if ($OsType -eq "Linux") {
        $wrapped = "sh -lc " + (Convert-ToShellSingleQuoted $RemoteScript)
        return @((Quote-ProcessArgument $wrapped))
    }
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($RemoteScript)
    $encoded = [Convert]::ToBase64String($bytes)
    return @("powershell.exe", "-NoProfile", "-EncodedCommand", $encoded)
}

function Add-CommonSshOptions {
    <#
    Appends the shared -F/-i/-l/-o options this app always uses for its own
    direct ssh.exe calls (target discovery, folder creation, test file prep)
    to $SshParts, in a single place so all callers stay consistent.

    Root cause of the bug this fixes (found 2026-07-01, from a user
    screenshot showing "Administrator@linux-001: Permission denied" for a
    Linux slave): every one of these ssh.exe invocations built its
    destination argument from ONLY the slave's SshAlias/Host, with no
    explicit username anywhere - so ssh.exe fell back to its own default of
    "whatever OS user is running this process" (the Windows account running
    the UI app, e.g. "Administrator"), completely ignoring the User value
    the app already tracks (and DOES correctly pass through as vdbench's own
    hd=...,user=... parameter for the actual distributed run - see
    ConfigGeneration.ps1 - just never for this app's OWN direct ssh.exe
    calls). Windows slaves usually still worked by coincidence when the
    configured "administrator" User value happened to match the account
    actually running the UI, or when a matching User entry already existed
    in SshConfig for that alias; Linux slaves practically never do, since
    "root" (this app's own Get-DefaultSlaveUserForOs default for Linux) is
    never the Windows account name. Passing -l explicitly here fixes this
    for every case, while still doing nothing (falling through to whatever
    ssh.exe/SshConfig would otherwise resolve) when $User is blank.
    #>
    param(
        [System.Collections.Generic.List[string]]$SshParts,
        [string]$User = "",
        [string]$PrivateKey = ""
    )
    $sshConfig = [string](Get-PropertyValue $script:Settings "SshConfig" "")
    if (-not [string]::IsNullOrWhiteSpace($sshConfig) -and (Test-Path -LiteralPath $sshConfig)) {
        [void]$SshParts.Add("-F")
        [void]$SshParts.Add((Quote-ProcessArgument $sshConfig))
    }
    $resolvedKey = $PrivateKey
    if ([string]::IsNullOrWhiteSpace($resolvedKey)) {
        $resolvedKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedKey) -and (Test-Path -LiteralPath $resolvedKey)) {
        [void]$SshParts.Add("-i")
        [void]$SshParts.Add((Quote-ProcessArgument $resolvedKey))
    }
    if (-not [string]::IsNullOrWhiteSpace($User)) {
        [void]$SshParts.Add("-l")
        [void]$SshParts.Add((Quote-ProcessArgument $User))
    }
    [void]$SshParts.Add("-o")
    [void]$SshParts.Add("BatchMode=yes")
    [void]$SshParts.Add("-o")
    [void]$SshParts.Add("ConnectTimeout=8")
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
    $configured = "INFO"
    if ($null -ne $script:Settings) {
        $configured = [string](Get-PropertyValue $script:Settings "LogLevel" "INFO")
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = "INFO"
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

function Initialize-ProcessEventBridge {
    if ($script:ProcessEventBridgeReady) {
        return
    }
    $typeLoaded = $false
    try {
        $null = [VdbenchUi.ProcessEventBridge]
        $typeLoaded = $true
    } catch {
        $typeLoaded = $false
    }
    if (-not $typeLoaded) {
        $bridgeSource = @'
namespace VdbenchUi {
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public class FileWriteItem {
    public string Path;
    public string Line;
}

public class ProcessExitItem {
    public int ExitCode;
    public string RunId;
    public string StdoutPath;
}

public static class ProcessEventBridge {
    private static ConcurrentQueue<string> _logQueue;
    private static ConcurrentQueue<object> _fileWriteQueue;
    private static ConcurrentQueue<object> _exitQueue;
    private static string _stdoutPath;
    private static string _stderrPath;
    private static string _runId;

    public static readonly DataReceivedEventHandler StdoutHandler =
        new DataReceivedEventHandler(OnStdout);
    public static readonly DataReceivedEventHandler StderrHandler =
        new DataReceivedEventHandler(OnStderr);
    public static readonly EventHandler ExitedHandler =
        new EventHandler(OnExited);

    public static void Initialize(
        ConcurrentQueue<string> logQueue,
        ConcurrentQueue<object> fileWriteQueue,
        ConcurrentQueue<object> exitQueue) {
        _logQueue = logQueue;
        _fileWriteQueue = fileWriteQueue;
        _exitQueue = exitQueue;
    }

    public static void SetRunContext(string runId, string stdoutPath, string stderrPath) {
        _runId = runId ?? "";
        _stdoutPath = stdoutPath ?? "";
        _stderrPath = stderrPath ?? "";
    }

    public static void OnStdout(object sender, DataReceivedEventArgs e) {
        if (e == null || e.Data == null) {
            return;
        }
        if (_logQueue != null) {
            _logQueue.Enqueue(e.Data);
        }
        if (_fileWriteQueue != null && !string.IsNullOrEmpty(_stdoutPath)) {
            _fileWriteQueue.Enqueue(new FileWriteItem { Path = _stdoutPath, Line = e.Data });
        }
    }

    public static void OnStderr(object sender, DataReceivedEventArgs e) {
        if (e == null || e.Data == null) {
            return;
        }
        string line = "[stderr] " + e.Data;
        if (_logQueue != null) {
            _logQueue.Enqueue(line);
        }
        if (_fileWriteQueue != null && !string.IsNullOrEmpty(_stderrPath)) {
            _fileWriteQueue.Enqueue(new FileWriteItem { Path = _stderrPath, Line = line });
        }
    }

    public static void OnExited(object sender, EventArgs e) {
        int code = 0;
        Process proc = sender as Process;
        if (proc != null) {
            try {
                code = proc.ExitCode;
            } catch {
                code = 0;
            }
        }
        if (_exitQueue != null) {
            _exitQueue.Enqueue(new ProcessExitItem {
                ExitCode = code,
                RunId = _runId ?? "",
                StdoutPath = _stdoutPath ?? ""
            });
        }
    }
}
}
'@
        Add-Type -TypeDefinition $bridgeSource -Language CSharp
    }
    if ($null -eq $script:ProcessExitQueue) {
        $script:ProcessExitQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    }
    [VdbenchUi.ProcessEventBridge]::Initialize(
        $script:LogQueue,
        $script:RunFileWriteQueue,
        $script:ProcessExitQueue
    )
    $script:ProcessEventBridgeReady = $true
    Write-DebugLog "Process event bridge initialized"
}

function New-ProcessBridgeDataReceivedHandler {
    param([string]$MethodName)
    $bridgeType = [VdbenchUi.ProcessEventBridge]
    $methodInfo = $bridgeType.GetMethod(
        $MethodName,
        [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public
    )
    if ($null -eq $methodInfo) {
        throw ("ProcessEventBridge method not found: {0}" -f $MethodName)
    }
    return [System.Delegate]::CreateDelegate(
        [System.Diagnostics.DataReceivedEventHandler],
        $methodInfo
    )
}

function New-ProcessBridgeExitedHandler {
    $bridgeType = [VdbenchUi.ProcessEventBridge]
    $methodInfo = $bridgeType.GetMethod(
        "OnExited",
        [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public
    )
    if ($null -eq $methodInfo) {
        throw "ProcessEventBridge method not found: OnExited"
    }
    return [System.Delegate]::CreateDelegate(
        [System.EventHandler],
        $methodInfo
    )
}

function Register-ProcessEventBridgeHandlers {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) {
        throw "Register-ProcessEventBridgeHandlers requires a Process instance."
    }
    Initialize-ProcessEventBridge
    $stdoutHandler = New-ProcessBridgeDataReceivedHandler -MethodName "OnStdout"
    $stderrHandler = New-ProcessBridgeDataReceivedHandler -MethodName "OnStderr"
    $exitedHandler = New-ProcessBridgeExitedHandler
    $Process.add_OutputDataReceived.Invoke($stdoutHandler)
    $Process.add_ErrorDataReceived.Invoke($stderrHandler)
    $Process.add_Exited.Invoke($exitedHandler)
    Write-DebugLog "Process event bridge handlers registered via CreateDelegate"
}

function Register-AppExceptionLogging {
    if ($script:AppExceptionLoggingRegistered) {
        return
    }
    $script:AppExceptionLoggingRegistered = $true
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
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
