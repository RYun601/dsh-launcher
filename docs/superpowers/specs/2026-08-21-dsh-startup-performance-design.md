# DSH Startup Performance Design

## Goal

Reduce repeated background startup time for an already prepared DeepSeek
Harness runtime without weakening startup locking, readiness reporting,
failure diagnostics, or upgrade behavior.

The user-facing targets on the current Windows development machine are:

- `deepseek -b` returns after accepting the startup job in about 2 seconds.
- A prepared runtime serves HTTP on `http://127.0.0.1:3080` within 8 seconds.
- A first install or an explicit update may still use the network and is not
  subject to the prepared-runtime target.

## Scope

The change covers launcher-owned CMD and Windows PowerShell 5.1-compatible
scripts, their packaging metadata, documentation, and behavior tests. It does
not modify the installed DSH package, `%USERPROFILE%\.dsh` profiles, MCP
configuration, user credentials, or global npm packages.

## Measured Baseline

Three prepared-runtime background launches reached HTTP readiness in 11.43,
11.56, and 11.32 seconds. `deepseek -b` returned in 2.43 to 3.50 seconds,
`run-dsh.ps1` started at 6.94 to 7.94 seconds, and Node started at 7.46 to
8.45 seconds.

Independent timings identified two launcher costs on the critical path:

- `resolve-dsh-version.ps1` averaged 1.84 seconds because it always executed
  `npm view @deepseek-ai/dsh dist-tags --json`.
- Each separate Windows PowerShell state-script invocation averaged about
  0.58 seconds. `background-run.cmd` launched several of them serially before
  it launched Node.

After Node started, DSH profile initialization took another 3 to 7 seconds.
That package-owned phase remains in scope only where the launcher controls
browser ownership; this design does not rewrite or disable DSH plugins.

## Selected Architecture

### Local-First Version Selection

`resolve-dsh-version.ps1` will accept a local-first mode used by normal
foreground and background startup. In that mode it selects a version in this
order:

1. A prepared runtime marker whose schema and validation fields are valid,
   when the matching DSH package metadata and entrypoint also exist.
2. An installed local DSH package with a valid package name, version, and
   entrypoint, even if its ready marker is absent. This allows
   `run-dsh.ps1` to validate or repair an interrupted preparation without a
   registry lookup.
3. Published npm dist-tags, using the existing highest-version ordering.

Normal startup therefore does not contact npm when a usable local runtime is
present. `deepseek --update` and `deepseek --upgrade` continue to query npm so
that explicit update operations discover new releases. A malformed or
inconsistent local marker is ignored rather than trusted.

This changes the normal-start contract from "implicitly discover the newest
release on every launch" to "start the prepared version; discover releases
through update or upgrade commands." The documented commands will make that
behavior explicit.

### Single PowerShell Background Runner

Add `background-run.ps1` as the authoritative long-lived background runner.
`start-background.ps1` will:

1. Perform the lightweight existing-instance and startup-lock checks.
2. Resolve the target version once in local-first mode.
3. Reserve the startup lock with a generated startup token.
4. Start `background-run.ps1` directly with a hidden Windows PowerShell
   process and a coordinator gate.
5. Transfer the reservation to the real runner PID, write `STARTING`, release
   the gate, and return to the caller.

The new runner will wait for the gate before doing work. After the gate opens,
it will validate that the lock token still identifies its startup, append a
timestamp and selected version to the UTF-8 log, write `STARTING` through the
state helper in the same PowerShell process, start the readiness monitor, and
launch `run-dsh.ps1`.

The runner may retain one child Windows PowerShell process for
`run-dsh.ps1`, because that script exits with Node's exit code and the runner
must remain alive to record an early exit and release the startup lock. It
will no longer launch separate PowerShell processes to discover its parent
PID, resolve the version, acquire its own lock, or write each lifecycle state.

`background-run.cmd` remains as a compatibility wrapper for existing direct
references. It forwards the existing startup token and coordinator gate
environment variables, plus an optional preselected version, to the new
PowerShell runner. When no version is supplied, the wrapper resolves one in
local-first mode before forwarding. Normal launcher flow no longer uses the
wrapper. Packaging will include the new PowerShell runner.

### Startup Ownership And Race Handling

The coordinator-created process ID is the authoritative owner throughout the
startup. The startup token links the reservation, gate, runner, state record,
and release operation.

The runner writes its first log record before performing expensive work. If
the gate contains `CANCEL`, the runner exits without starting DSH. If the gate
times out, the DSH child exits before readiness, or the monitor cannot be
started, the runner records a concise failure when it still owns the token and
releases the lock in a `finally` path. Version-resolution failures occur in
the coordinator before runner creation and release the reservation there.

This removes the CMD parent-PID lookup and narrows the stop/start race in which
a submitted CMD process could disappear before reaching its first log line.
The coordinator still cancels a child whose ownership transfer fails.

### Lightweight Existing-Instance Probe

`start-background.ps1` will avoid loading `Get-NetTCPConnection` when port
3080 is closed:

1. Probe the DSH HTTP URL using the existing readiness semantics.
2. If HTTP is unavailable, perform a short .NET `TcpClient` connection probe.
3. Only when TCP connects will it call `Get-NetTCPConnection` to identify the
   owning process for the existing-instance message.

A ready HTTP service still opens the browser and returns successfully. An
occupied but not-yet-ready port is treated as an existing startup rather than
causing a duplicate DSH process.

### Single Browser Owner

Foreground and background launcher paths will invoke DSH Web with
`--no-open`. `run-dsh.ps1` will expose this through an explicit switch so the
argument can cross the external PowerShell process boundary reliably.

`open-when-ready.ps1` becomes the only component that opens the browser and
writes the HTTP-based `RUNNING` transition. Its polling interval changes from
one second to 200 milliseconds, while each request retains a bounded timeout.
This prevents duplicate browser opens and reduces the post-readiness delay to
at most about 200 milliseconds under normal local failure behavior.

## Component Changes

- `resolve-dsh-version.ps1`: add validated local-first resolution with an
  explicit runtime root override for isolated tests.
- `start-background.ps1`: use local-first resolution, lightweight port
  probing, direct PowerShell runner creation, token transfer, and gate
  release.
- `background-run.ps1`: own the long-lived startup lifecycle, logging,
  readiness monitor, child DSH process, failure recording, and lock cleanup.
- `background-run.cmd`: become a compatibility wrapper around the PowerShell
  runner interface.
- `run-dsh.ps1`: add an explicit no-browser switch and append `--no-open` to
  the DSH arguments exactly once.
- `open-when-ready.ps1`: use a configurable 200 millisecond polling interval.
- `deepseek.cmd` and `start-deepseek-harness.bat`: use local-first version
  selection and single-browser-owner semantics for foreground startup.
- `release-files.txt` and release tests: include the new runner.
- `README.md` and `README.en.md`: document that normal launch uses the prepared
  version and update commands perform release discovery.

## Error Handling

- Invalid local JSON, mismatched package versions, or a missing entrypoint
  never count as a prepared runtime.
- If no usable local version exists and npm cannot be queried, callers retain
  the existing `latest` fallback behavior.
- Failure before runner creation releases the coordinator reservation.
- Failure after runner creation is recorded only by the process that still
  owns the matching startup token.
- A readiness monitor follows the authoritative runner PID and exits when that
  process exits.
- DSH child output remains appended to `%USERPROFILE%\dsh-launch\dsh-background.log`
  as UTF-8 text.
- Stop behavior continues to target only positively identified launcher-owned
  process trees.

## Testing

Behavior tests will use isolated temporary profiles, runtimes, fake npm/node
commands, and fake readiness probes. They will verify:

- A valid prepared runtime returns its version without invoking npm.
- A valid installed package without a marker is reused for validation without
  invoking npm.
- Invalid or missing local metadata falls back to npm version resolution.
- Explicit update and upgrade paths still query published versions.
- Immediate background startup transfers one token to the direct PowerShell
  runner and returns without waiting for HTTP.
- The runner does not query its parent PID or resolve the version again.
- DSH receives `web --no-open` exactly once.
- Only the readiness monitor issues the browser launch.
- The monitor polls at the configured sub-second interval and records
  `RUNNING` only after a successful HTTP response.
- A cancelled gate, gate timeout, transfer failure, monitor-start failure, and
  early DSH exit each leave no live startup lock and expose the appropriate
  failure state.
- Repeated synthetic stop/start cycles do not submit a runner that disappears
  before its first log record.
- Release packaging contains `background-run.ps1` and the compatibility CMD
  wrapper.

After the complete behavior suite passes, a real prepared-runtime benchmark
will perform at least three stop/start cycles, measure command submission,
runner creation, Node creation, and HTTP readiness, and leave one ready service
running. The acceptance target is a median HTTP readiness time no greater than
8 seconds on the current development machine. Timing results will be reported
even if the environment misses the target; functional tests will not use
wall-clock thresholds that would make CI flaky.

## Out Of Scope

- Editing `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml`.
- Deferring or disabling Chrome DevTools MCP or Vision Toolkit plugins.
- Replacing `chrome-devtools-mcp@latest` with a pinned or global executable.
- Changing DSH package internals or its Web server initialization order.
- Removing startup state, lock, status, logs, update, upgrade, or browser-open
  behavior.
