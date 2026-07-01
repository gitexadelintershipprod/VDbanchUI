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
