# dsh-launcher

[中文](README.md) | [English](README.en.md)

![License](https://img.shields.io/github/license/RYun601/dsh-launcher)
![Release](https://img.shields.io/github/v/release/RYun601/dsh-launcher)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)

A launch & management tool for [DeepSeek Harness](https://github.com/deepseek-ai/dsh) Web on Windows:
type `deepseek` in cmd / PowerShell to start it (foreground / background modes), auto-open the
browser, check status, and stop the service. One-click registration of the `deepseek` command
is also supported.

## Features

- **Command-line launch**: type `deepseek` in cmd / PowerShell to start — no need to hunt for icons or remember paths
- **Foreground / background modes**: foreground shows logs in a window (closing the window stops it); `deepseek -b` submits background startup and returns immediately
- **Auto-open browser**: opens http://127.0.0.1:3080 automatically when the service is ready
- **Visible shortcut feedback**: shows startup progress, closes after opening the browser, and stays open with log details on failure
- **Status & stop**: `deepseek --status` shows the run state; `deepseek --stop` stops the service and reminds you how to restart it
- **Works on both Windows 10 and Windows 11**

## Installation

### Prerequisite: Install Node.js

dsh-launcher is a launcher for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness);
dsh-launcher only requires Node.js. On the first `deepseek` run, it prepares and starts DeepSeek Harness through npm in `%USERPROFILE%\dsh-launch\runtime`.

1. Install [Node.js](https://nodejs.org) LTS

> The first launch requires an internet connection. Node.js normally includes npm; if the environment check cannot find npm, reinstall Node.js LTS.

### Optional: Install the official DSH CLI

Install the DSH CLI globally only if you want to use the official `dsh` command directly from any terminal:

```sh
npm install -g @deepseek-ai/dsh
```

Open a new terminal, then run:

```sh
dsh web
```

The UI at http://127.0.0.1:3080 means it started successfully (press Ctrl+C to exit).

> `npm install -g @deepseek-ai/dsh` registers `dsh` in npm's global executable directory (as `dsh.cmd` on Windows). A standard Node.js installation adds that directory to PATH; if `dsh` is still not found in a new terminal, check that the npm global directory is on PATH.
>
> `npx @deepseek-ai/dsh web` can start DSH directly, but does not register the `dsh` command for use in any terminal. dsh-launcher uses its own versioned runtime, so the global DSH CLI is not required.

### Option 1: One-line install via PowerShell (recommended)

```powershell
irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 | iex
```

Downloads the latest Release, extracts it to `%USERPROFILE%\dsh-launcher`, and registers the `deepseek` command automatically.

> A desktop shortcut is not created by default. To create one, run these two steps in the same PowerShell window:
>
> 1. Download the installer script to the current directory:
>
>    ```powershell
>    irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 -OutFile .\install.ps1
>    ```
>
> 2. Run the script with the `-Shortcut` parameter:
>
>    ```powershell
>    .\install.ps1 -Shortcut
>    ```
>
> `-Shortcut`: creates a "DeepSeek Harness" desktop shortcut. It starts in background mode, shows startup progress, and closes automatically after a successful start. Running the installer with this parameter again updates the shortcut; without it, the installer does not create a shortcut.

### Option 2: Manual install

1. Download `dsh-launcher.zip` from [Releases](https://github.com/RYun601/dsh-launcher/releases) and extract it
2. Run `install-command.cmd` (registers the `deepseek` command)
3. Open a new terminal and type `deepseek`

### Option 3: Run from source

```sh
git clone https://github.com/RYun601/dsh-launcher.git
cd dsh-launcher
```

## Quick Start

After completing the installation above (any option) and opening a **new** terminal window
(so the new PATH takes effect):

1. Type `deepseek -b` to submit background startup and return immediately (or `deepseek` for foreground mode)
2. On first run, npm prepares the DeepSeek Harness runtime and required dependencies automatically (needs internet, ~1-2 minutes)
3. The browser opens http://127.0.0.1:3080 automatically when the service is ready
4. On first use, sign in / enter an API Key in the DeepSeek Harness UI

## CLI Usage

| Command | Description |
| --- | --- |
| `deepseek` | Foreground mode (default): shows logs in a window; close the window or press Ctrl+C to stop |
| `deepseek -b` / `-d` / `--background` / `--bg` / `--daemon` | Background mode: returns immediately while the service keeps starting; browser opens automatically when ready |
| `deepseek --status` | Show service state (`RUNNING (ready)` / `RUNNING (starting)` / `STARTING` / `FAILED` / `NOT RUNNING`); `STARTING` covers download/install and `FAILED` includes the log path |
| `deepseek --stop` | Stop the service (port 3080; only kills DeepSeek Harness processes) and remind how to restart |
| `deepseek --logs [N]` | Show the last N lines of the background log (default 20), e.g. `deepseek --logs 50` |
| `deepseek --version` | Show launcher version and local DeepSeek Harness version |
| `deepseek --update` | Compare the local version with the latest on npm and show how to update |
| `deepseek --upgrade` | One-click upgrade: stop service, clear old DSH npx workspaces, prepare the latest runtime, restart in background |
| `deepseek --uninstall` | Remove the `deepseek` command from the user PATH (unregister) |
| `deepseek --uninstall --full` | Full uninstall: PATH + desktop shortcut + logs/runtime dir + install dir (with confirmation) |
| `deepseek --check` | Environment self-check (script path / npm / port) |
| `deepseek --help` | Show help |

- Normal startup prefers the prepared and validated local DSH version and does not contact npm when a usable runtime exists. Dependencies are prepared only for a first launch or repair without a usable runtime. Use `deepseek --update` to discover releases from npm and `deepseek --upgrade` to install and switch versions.

## Other Ways to Start

- **Run scripts directly**: double-click `start-deepseek-harness.bat` (foreground) or `start-background.cmd` (background progress window; closes on success, stays open on failure)

## Files

| File | Description |
| --- | --- |
| `deepseek.cmd` | CLI entry: foreground / background / stop / status / check / help |
| `start-deepseek-harness.bat` | Foreground launcher (starts the service + auto-opens browser) |
| `start-background.cmd` / `.ps1` | Background coordinator: supports immediate return or waiting for readiness; logs go to `%USERPROFILE%\dsh-launch\dsh-background.log` |
| `stop-dsh.cmd` / `.ps1` | Stop the service (finds the process by port 3080) |
| `open-when-ready.ps1` | Polls the HTTP service and opens the browser when it is ready (900-second timeout) |
| `background-run.ps1` | Owns the background startup lock, lifecycle state, log, readiness monitor, and DSH child process |
| `background-run.cmd` | Compatibility entrypoint for the background runner; normal startup invokes `background-run.ps1` directly |
| `run-dsh.ps1` | Serializes runtime preparation, completes required peers, audits the tree with `npm ls --all`, and starts the Node entrypoint |
| `update-check.ps1` | Version comparison: managed runtime / legacy npx cache / global install vs latest on npm |
| `upgrade-dsh.ps1` | One-click upgrade: stop service, clear legacy DSH npx workspaces, prepare and start the latest runtime |
| `set-shortcut.ps1` | Create or migrate the desktop shortcut to the visible startup progress window |
| `uninstall.ps1` | Uninstall: remove PATH registration (`-Full` also removes shortcut / logs and runtime / install dir) |
| `install-command.cmd` | Adds this folder to the user PATH and registers the `deepseek` command |
| `VERSION` | Launcher version (read by `deepseek --version`) |
| `deepseek.ico` | DeepSeek Harness black whale icon (16-256px, multiple sizes; used by the desktop shortcut) |
| `deepseek.svg` | Vector source of the icon (from the DSH web frontend favicon; regenerate the .ico from it) |

## FAQ

- **`deepseek` is not recognized as a command**: run `install-command.cmd` first, then open a new terminal window
- **Stuck on download / network errors**: switch to a mirror and retry: `npm config set registry https://registry.npmmirror.com`
- **`deepseek --status` shows `STARTING`**: DSH is downloading or starting. Use `deepseek --logs 50` to inspect progress; another `deepseek -b` will not submit a duplicate startup job.
- **`deepseek --status` shows `FAILED`**: DSH exited before it listened on the port. Run `deepseek --logs 50` for the error, then retry with `deepseek -b`.
- **Port 3080 is already in use (EADDRINUSE)**: an instance is already running — check with `deepseek --status`, or run `deepseek --stop` first
- **Service stops when the foreground window closes**: by design (the process lives in the console window); use `deepseek -b` for a persistent service
- **Migrate existing DSH settings (including API Key)**: copy the whole `%USERPROFILE%\.dsh` folder to `C:\Users\<username>\.dsh` on the new machine (contains sensitive credentials — do not share publicly)

## License

[MIT](LICENSE)
