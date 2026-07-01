# AGENTS.md

## Cursor Cloud specific instructions

### What this project is
Portable Windows UI (PowerShell + Windows Forms) for managing an existing Oracle Vdbench
installation. The single GUI app is `src/VdbenchUI.ps1`, launched on Windows via
`Launch-VdbenchUI.bat`. See `README.md` for the full workflow.

### Platform reality in Cursor Cloud (Linux)
- The GUI itself (`Build-MainForm`, button clicks, grids, dialogs) is **Windows-only** and
  cannot be exercised here — `src/VdbenchUI.ps1` calls
  `Add-Type -AssemblyName System.Windows.Forms` at the top of the file, which fails on Linux.
  The helper scripts under `tools/*.ps1` (`Validate-Project.ps1`, `Verify-Portable.ps1`,
  `Invoke-SmokeTest.ps1`, `Package-Portable.ps1`) also depend on Windows PowerShell, WinForms,
  CIM, and `ssh.exe` and cannot run here.
- **PowerShell Core (`pwsh`) CAN and SHOULD be installed on Linux** to actually run/validate
  PowerShell code instead of editing it blindly. Do this at the start of any session that
  touches `src/**/*.ps1`:
  ```
  curl -sSL -o /tmp/powershell.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
  mkdir -p /tmp/pwsh && tar xzf /tmp/powershell.tar.gz -C /tmp/pwsh && chmod +x /tmp/pwsh/pwsh
  export PATH="/tmp/pwsh:$PATH"
  ```
  With `pwsh` on PATH you can, and should:
  - Parse every `.ps1` file for real syntax errors:
    `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)`.
  - Dot-source all of `src/modules/*.ps1` directly (bypassing `VdbenchUI.ps1`'s top-level
    `Add-Type` calls) and call `Invoke-AppSelfTest` (from `SelfTest.ps1`) headlessly — this
    exercises `Initialize-AppState`, profile creation, and `Build-VdbenchConfig` for all
    4 run-mode/target-kind combinations without needing WinForms. See
    `run_powershell_checks()` in `tools/validate_offline.py` for a working example
    (variable/module list to dot-source, etc.).
  - Beware: PowerShell scriptblocks bound to .NET events (`Add_Click`, `Add_Tick`, etc.) do
    **not** capture local variables from their enclosing function by closure — only
    `.GetNewClosure()` or `$script:`-scoped state does. This bit a background-work rewrite
    in this codebase before (see `Start-BackgroundUiWork` / `Initialize-BackgroundUiPollTimer`
    in `UiHelpers.ps1` for the fixed pattern: track pending jobs in a `$script:` dictionary,
    never in Timer/event-handler closures). Also beware that a single `[runspace]` can only
    run one pipeline at a time — concurrent background jobs need a `RunspacePool`, not a
    shared `Runspace` (see `Initialize-BackgroundRunspace`).
  - Beware: **never write `@(Expr).Property`** (array-wrap a single object/function-call
    result, then dot into a custom property) anywhere in `src/`. Under
    `Set-StrictMode -Version 2.0` (enabled app-wide), this triggers PowerShell's per-element
    "member enumeration" on the resulting 1-item array instead of plain property access; if
    `Property`'s value happens to be an empty collection (e.g. a slave row with no targets
    picked yet), enumeration collects zero results and PowerShell throws "The property 'X'
    cannot be found on this object" — even though the property demonstrably exists. Reproduces
    with zero app code: `Set-StrictMode -Version 2.0; @(@{ Targets = @() }).Targets` throws,
    while `(@{ Targets = @() }).Targets` returns `@()` correctly. This is exactly the bug
    behind a real production crash (`Get-SlaveRowTargets` in `UiSlaveGrid.ps1`) that broke
    almost every interaction with a freshly-added slave. Fix: drop the inner `@()` and access
    the property on the bare expression, wrapping the *result* in `@()` if you need an array:
    `@((Expr).Property)`. `validate_offline.py`'s `validate_no_array_wrap_property_access()`
    statically bans this pattern app-wide (except `.Count`/`.Length`, which are always safe) —
    do not bypass or weaken that check.
  - Relatedly: capturing a function's return value via plain `$var = Some-Function` (or
    passing it as an unwrapped argument) can also give `$var` `$null` instead of an empty
    array if the function outputs zero pipeline objects — wrap the *call site* in `@()`
    (`$var = @(Some-Function)`) whenever the function might legitimately return nothing, before
    touching `.Count` or any property directly on the result.
  - Beware: `ProcessStartInfo.CreateNoWindow = $false` does **not** mean "open a new
    window" — its actual meaning depends entirely on `UseShellExecute` (see
    [Microsoft's own writeup](https://learn.microsoft.com/en-us/archive/blogs/jmstall/how-to-start-a-console-app-in-a-new-window-the-parents-window-or-no-window)):
    `UseShellExecute=$false` + `CreateNoWindow=$false` runs the child in an *existing*
    window (the parent's console, if it has one — silently, with no new window at all);
    only `UseShellExecute=$true` (default) reliably opens a genuinely new, separate
    console regardless of `CreateNoWindow` (which is then ignored). This is exactly what
    made `Get-SlaveReadinessResult`'s "open a separate PowerShell window for the checker"
    feature silently share the app's own console instead (real bug, found 2026-07-01) —
    confirmed empirically in this sandbox with a throwaway script under `pwsh` (a real
    child process, launched both ways, with/without a PATH-resolvable `powershell.exe`
    shim) before touching the real code, since Linux's `UseShellExecute=$true` semantics
    differ enough from Windows to be worth checking rather than assuming: it still
    resolves `FileName` via PATH, still honors `WorkingDirectory`, and still propagates
    `ExitCode`/`WaitForExit()` correctly for a plain executable (not a "document"), so the
    fix is safe to validate end-to-end here. If `UseShellExecute=$true`, do not also set
    `RedirectStandardOutput`/`RedirectStandardError` — `Process.Start` throws
    `InvalidOperationException` for that combination.
  - Beware: `System.Windows.Forms.Timer` (and anything else under
    `System.Windows.Forms.*`) cannot be instantiated on Linux `pwsh` at all — even after
    `Add-Type -AssemblyName System.Windows.Forms` succeeds, `New-Object
    System.Windows.Forms.Timer` fails with "Cannot find path
    '.../System.Windows.Forms.dll'". This means any code path that reaches
    `Start-BackgroundUiWork` with a non-`$null` `-Owner` (which lazily creates the shared
    poll timer via `Initialize-BackgroundUiPollTimer`) cannot be exercised end-to-end
    here. To still get real regression coverage for UI functions that call
    `Start-BackgroundUiWork`/`Start-SlaveReadinessCheck`/`Start-SlavePingCheck` (e.g. to
    prove an in-flight-request guard actually short-circuits *before* reaching that
    WinForms-dependent code), redefine `Start-BackgroundUiWork` itself after dot-sourcing
    the real modules — plain function redefinition (not a `Add_Click`/`Add_Tick` closure)
    resolves at call time in PowerShell, so the real caller's later calls to it hit your
    stub — and assert on a call counter instead of driving the real timer/runspace pool.
  - Beware: a process's exit code alone does not tell you whether it printed anything
    worth showing a human. This bit `Get-ReadinessCheckerWrapperCommand` (real bug, found
    2026-07-01): it only paused the checker window for `Read-Host` when the wrapper's own
    `$exitCode` was non-zero, on the assumption exit 0 meant "nothing to review". The
    shipped checker script exits `0` unconditionally regardless of whether its own
    internal `[OK]`/`[FAIL]` report lines passed, so a run with a failing internal check
    still auto-closed the window before it could be read. Fix: pause unconditionally,
    always, regardless of exit code — do not gate a "let the human read this" prompt
    behind any success/failure signal from the thing being wrapped, since "ran to
    completion" and "everything it checked passed" are not the same thing.
  - When a fix makes a subprocess *always* pause on `Read-Host` before exiting (as
    above), verify empirically — do not assume — that a test harness which redirects that
    subprocess's `stdin` to nothing (Python's `subprocess.run(..., stdin=subprocess.DEVNULL)`)
    does not hang. Confirmed empirically in this sandbox before relying on it: with
    `UseShellExecute=$true` and no explicit `RedirectStandardInput`, the child inherits
    the parent's stdin; when that stdin is `/dev/null` (EOF immediately), `Read-Host`
    returns an empty string immediately rather than blocking - safe for CI. This is
    Linux-only sandbox behavior for validation purposes; on real Windows,
    `UseShellExecute=$true` opens a genuinely new console with its own real keyboard
    input, so `Read-Host` there correctly waits for an actual human keypress.
  - **Critical, previously-undetected bug found 2026-07-01**: `[powershell]::EndInvoke()`
    wraps even a SINGLE output object in a `PSDataCollection<PSObject>` - confirmed
    empirically in this sandbox - not the raw object itself. Direct dot-notation property
    access (`$Result.Status`, or even dynamic `$Result.$name`) transparently "reaches
    into" a collection with exactly one element - this is PowerShell's own member-access
    adapter behavior - but `Get-PropertyValue`'s explicit `$Object.PSObject.Properties[$Name]`
    lookup (in `Core.ps1`) does **not** get that same treatment: it queries the wrapper
    collection's own properties (which never has `$Name`), silently returning
    `$DefaultValue` every single time no matter what the real value inside actually was.
    This meant `Get-PropertyValue $Result "AnyFlag" $false` against ANY
    `Start-BackgroundUiWork`/`EndInvoke()` `OnComplete` `$Result` always evaluated to the
    default, regardless of what was really set - and this had been silently broken for as
    long as that OnComplete/EndInvoke pattern existed, since NONE of this project's tests
    exercised the REAL `RunspacePool`+`BeginInvoke()`+`EndInvoke()` path with
    `Get-PropertyValue` (they either called the inner function directly, bypassing
    `EndInvoke()` entirely, or stubbed out `Start-BackgroundUiWork` itself for WinForms
    reasons - see the `System.Windows.Forms.Timer` note above - which ALSO bypasses
    `EndInvoke()`). `Get-PropertyValue` now unwraps a same single-item, non-string,
    non-dictionary `[System.Collections.ICollection]` before its property lookup,
    matching what direct dot-notation already does, fixing this for every current and
    future caller uniformly. `[string]$Result` casting (used elsewhere in this codebase
    for background-job results, e.g. Ping status) was separately confirmed NOT affected -
    PowerShell's `[string]` conversion has its own, different single-item-collection
    handling that already worked correctly. When writing a REAL (non-stubbed) regression
    test for this class of bug, `[runspacefactory]::CreateRunspacePool()` +
    `[powershell]::Create()` + `BeginInvoke()`/`EndInvoke()` run perfectly fine on Linux
    `pwsh` with no WinForms dependency at all - only the `System.Windows.Forms.Timer`
    *polling* wrapper around it needs stubbing/skipping, not the runspace mechanism
    itself; a plain `while (-not $async.IsCompleted) { Start-Sleep -Milliseconds N }`
    synchronous wait is a perfectly adequate stand-in for the timer in a test.
  - `python3 tools/validate_offline.py` automatically detects `pwsh` on PATH and runs the
    real syntax-parse + `Invoke-AppSelfTest` checks as part of the normal offline validation
    (prints "real PowerShell syntax + self-test checks: ran"). If `pwsh` is missing it skips
    those checks with a warning instead of failing, so CI without PowerShell still works —
    but you should still install `pwsh` yourself in this sandbox to get real coverage.
  - What this still cannot catch: anything requiring actual WinForms rendering/interaction
    (dialogs, grids, button wiring, layout). Review that code path-by-path since it cannot
    be executed here; do not claim it was "tested" without a caveat.

### Run / test / lint / build (Linux dev scope)
- Run + test (core config generation + contracts, plus real PowerShell syntax/self-test if
  `pwsh` is installed per above): `python3 tools/validate_offline.py`
- Lint: there is no separate Linux linter. PowerShell syntax checking lives inside
  `tools/Validate-Project.ps1` (Windows-only) and is now also covered by
  `run_powershell_checks()` in `tools/validate_offline.py` when `pwsh` is available.
- Build/package: `tools/Package-Portable.ps1` produces the portable ZIP and is Windows-only.

### Dependencies
- No required installable dependencies for the Python-only validator (stdlib only, Python 3
  is preinstalled). Installing `pwsh` (PowerShell Core) as described above is optional but
  strongly recommended for any change touching `src/**/*.ps1` — see above. There is
  intentionally **no Docker** for this project (it is a portable Windows app) — do not
  containerize it.
