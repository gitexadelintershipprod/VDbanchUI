function Get-VdbenchProcessStartInfo {
    param(
        [string]$ExecutablePath,
        [string]$ParameterFile,
        [string]$OutputDirectory,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $extension = [System.IO.Path]::GetExtension($ExecutablePath).ToLowerInvariant()
    $parmArg = Quote-ProcessArgument $ParameterFile
    $outArg = Quote-ProcessArgument $OutputDirectory

    if ($extension -eq ".bat" -or $extension -eq ".cmd") {
        $command = "{0} -f {1} -o {2}" -f (Quote-ProcessArgument $ExecutablePath), $parmArg, $outArg
        $psi.FileName = "cmd.exe"
        $psi.Arguments = '/d /c "' + $command + '"'
    } elseif ($extension -eq ".ps1") {
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File {0} -f {1} -o {2}" -f (Quote-ProcessArgument $ExecutablePath), $parmArg, $outArg
    } else {
        $psi.FileName = $ExecutablePath
        $psi.Arguments = "-f {0} -o {1}" -f $parmArg, $outArg
    }

    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    return $psi
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) {
        return
    }
    if ($Process.HasExited) {
        return
    }
    try {
        $null = Start-Process -FilePath "taskkill.exe" `
            -ArgumentList @("/T", "/F", "/PID", $Process.Id) `
            -NoNewWindow `
            -Wait `
            -PassThru
        Write-AppLog ("Stopped process tree for PID {0}" -f $Process.Id)
    } catch {
        Write-AppLog ("taskkill failed for PID {0}: {1}" -f $Process.Id, $_.Exception.Message) "WARN"
        try {
            $Process.Kill()
        } catch {
            Write-AppLog ("Process.Kill fallback failed: {0}" -f $_.Exception.Message) "ERROR"
        }
    }
}
