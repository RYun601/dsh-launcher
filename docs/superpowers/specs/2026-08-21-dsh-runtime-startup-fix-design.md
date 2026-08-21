# DSH Runtime Startup Fix Design

**Date:** 2026-08-21

**Status:** Approved for implementation planning

## Goal

Make `deepseek -b` reach a genuinely ready DeepSeek Harness service when npm
reports the known React peer conflict under Windows PowerShell 5.1, and remove
one redundant full dependency-tree scan from both cold preparation and
unmarked-runtime validation.

## Confirmed Problem

The launcher prepares a managed runtime before invoking the DSH Node entrypoint.
For `@deepseek-ai/dsh@0.1.0-rc.8`, the prepared graph contains React 19.2.8 next
to `use-sync-external-store@1.2.0`, whose required React peer range ends at
React 18. `npm ls --all --json` therefore exits with `ELSPROBLEMS`.

`run-dsh.ps1` uses `$ErrorActionPreference = 'Stop'` and merges native stderr
into the audit output. Windows PowerShell 5.1 converts npm's stderr into a
`NativeCommandError`, so execution stops inside `Invoke-NpmDependencyAudit`
before the existing React 18.3.1 repair branch can inspect the output.

Because the dependency audit never completes, the runtime ready marker is not
written. Every retry repeats the expensive dependency scans and fails before
the DSH Node entrypoint runs.

## Scope

This change will:

- make npm dependency-audit failures capturable under Windows PowerShell 5.1;
- preserve npm stdout, stderr, and exit code for the existing audit logic;
- keep the existing React 18.3.1 compatibility repair;
- avoid repeating a dependency-tree scan after the previous scan already
  established that no required peers remain;
- add regression coverage for real npm stderr behavior and scan counts;
- verify both first successful preparation and ready-runtime reuse.

This change will not:

- move runtime installation into launcher installation or upgrade;
- prebundle the DSH npm dependency tree;
- change the selected DSH version, runtime location, port, browser behavior,
  lock ownership, or launch-state contract;
- address npm `allow-scripts` policy beyond reporting any real-startup failure
  revealed during verification;
- change the upstream DSH package dependency declarations.

## Design

### Native npm audit handling

`Invoke-NpmDependencyAudit` will first resolve `npm.cmd` with
`Get-Command -CommandType Application -ErrorAction Stop`. It will then save the
caller's current `$ErrorActionPreference`, set it to `Continue` only around the
resolved npm `ls` invocation, capture the merged output and `$LASTEXITCODE`, and
restore the previous preference in `finally`.

The function will continue returning the existing object shape:

```text
ExitCode: integer npm process exit code
Output: combined npm stdout and stderr text
```

This is intentionally narrower than replacing all npm invocation code. The
install path already treats nonzero exit codes as fatal; only the audit path
expects a nonzero exit so it can classify and repair a known dependency graph.

If `npm.cmd` is missing, command resolution fails before the local error
preference is relaxed. A normal `ELSPROBLEMS` process exit remains data for
`Repair-KnownPeerConflict`.

### Peer scan reuse

The preparation loop will retain the latest `Get-MissingRequiredPeers` result.
Each loop iteration will:

1. scan once;
2. stop when the result is empty;
3. otherwise install the reported peers and scan again on the next iteration.

After the loop, the retained result will be used for the remaining-peer check.
There will be no unconditional extra scan.

For the current runtime this changes the expected scan counts as follows:

| Scenario | Before | After |
| --- | ---: | ---: |
| Cold preparation with one peer-install round | 3 | 2 |
| Existing unmarked runtime with no missing peers | 2 | 1 |
| Ready runtime reuse | 0 | 0 |

The maximum of five peer-install rounds and the final missing-peer failure
remain unchanged.

## Error Flow

For the known published conflict, the startup flow becomes:

```text
npm ls exits 1 and emits ELSPROBLEMS
  -> audit returns ExitCode 1 plus combined output
  -> React conflict matcher selects the known repair
  -> npm installs react@18.3.1 and react-dom@18.3.1
  -> second npm audit runs
  -> successful audit writes the ready marker
  -> Node invokes the DSH web entrypoint
  -> HTTP readiness changes launch state to RUNNING
```

An unknown dependency problem still writes `dsh-dependency-audit.log` and fails
startup. The change does not turn arbitrary npm dependency errors into success.

## Test Design

The existing fake npm used by `runtime-preparation-behavior.Tests.ps1` will
model npm 11 more faithfully for the incompatible-React case:

- write `npm error code ELSPROBLEMS` to stderr;
- write the conflict JSON to stdout;
- exit with code 1.

Before the production change, the existing React repair test must fail with
`NativeCommandError`. After the change it must pass, perform two audits, install
the React 18.3.1 pair, and write a schema-2 ready marker.

A test-only PowerShell wrapper will intercept calls to `Get-ChildItem` while the
real runtime script executes with the fake filesystem and fake npm. It will
record dependency scan invocations without adding test hooks to production
code. Assertions will require two scans for cold preparation and zero scans
when the resulting ready runtime is reused.

Verification will include:

- the focused runtime preparation test file;
- all repository PowerShell behavior tests;
- `git diff --check` on changed files;
- a real background startup using Windows PowerShell 5.1 and npm 11;
- HTTP readiness and `deepseek --status` reporting `RUNNING`;
- stopping the service, starting it again from the ready runtime, and recording
  warm-start time;
- final cleanup confirming port 3080 and launcher test processes are not left
  running.

## Success Criteria

- The new stderr regression test fails before the production fix and passes
  after it.
- The known React conflict is repaired instead of surfacing as an unhandled
  `NativeCommandError`.
- A successful real startup creates `dsh-runtime-ready.json` and reaches HTTP
  readiness on port 3080.
- A subsequent start reuses the ready runtime without npm installation, npm
  audit, or peer scanning.
- Cold preparation performs two peer scans for one install round, not three.
- Unknown dependency-audit failures remain fatal and retain diagnostic output.
- All existing behavior tests continue to pass.
