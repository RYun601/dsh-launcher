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
- **Foreground / background modes**: foreground shows logs in a window (closing the window stops it); background runs without a window (closing any window won't affect it)
- **Auto-open browser**: opens http://127.0.0.1:3080 automatically when the service is ready
- **Status & stop**: `deepseek --status` shows the run state; `deepseek --stop` stops the service and reminds you how to restart it
- **Works on both Windows 10 and Windows 11**

## Installation

### Option 1: One-line install via PowerShell (recommended)

```powershell
irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 | iex
```

Downloads the latest Release, extracts it to `%USERPROFILE%\dsh-launcher`, and registers the `deepseek` command automatically.

### Option 2: Manual install

1. Download `dsh-launcher.zip` from [Releases](https://github.com/RYun601/dsh-launcher/releases) and extract it
2. Run `install-command.cmd` (registers the `deepseek` command)
3. Open a new terminal and type `deepseek`

### Option 3: Run from source

```sh
git clone https://github.com/RYun601/dsh-launcher.git
cd dsh-launcher
```

### Prerequisite: Install DeepSeek Harness

dsh-launcher is a launcher for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness);
DeepSeek Harness itself must be installed first (install commands from the official repo):

1. Install [Node.js](https://nodejs.org) LTS
2. Run:

```sh
npx @deepseek-ai/dsh web
```

3. The UI at http://127.0.0.1:3080 means the installation succeeded (press Ctrl+C to exit)

> Note: dsh-launcher also downloads/reuses DeepSeek Harness via `npx --yes @deepseek-ai/dsh web`
> on every start; running the command above beforehand verifies the environment and warms the cache.

## Quick Start

After completing the installation above (any option) and opening a **new** terminal window
(so the new PATH takes effect):

1. Type `deepseek -b` for background mode (or `deepseek` for foreground mode)
2. On first run, DeepSeek Harness is downloaded automatically via `npx` (needs internet, ~1-2 minutes)
3. The browser opens http://127.0.0.1:3080 automatically when the service is ready
4. On first use, sign in / enter an API Key in the DeepSeek Harness UI

## CLI Usage

| Command | Description |
| --- | --- |
| `deepseek` | Foreground mode (default): shows logs in a window; close the window or press Ctrl+C to stop |
| `deepseek -b` / `--background` / `--bg` | Background mode: keeps running without a window; browser opens automatically when ready |
| `deepseek --status` | Show service state (`RUNNING - PID xxxx` / `NOT RUNNING`) |
| `deepseek --stop` | Stop the service (finds the process by port 3080) and reminds you how to restart |
| `deepseek --update` | Compare the local version with the latest on npm and show how to update |
| `deepseek --uninstall` | Remove the `deepseek` command from the user PATH (unregister) |
| `deepseek --check` | Environment self-check (script path / npx / port) |
| `deepseek --help` | Show help |

## Other Ways to Start

- **Run scripts directly**: double-click `start-deepseek-harness.bat` (foreground) or `start-background.cmd` (background)

## Files

| File | Description |
| --- | --- |
| `deepseek.cmd` | CLI entry: foreground / background / stop / status / check / help |
| `start-deepseek-harness.bat` | Foreground launcher (starts the service + auto-opens browser) |
| `start-background.cmd` / `.ps1` | Background launch: runs without a window; logs go to `%USERPROFILE%\dsh-launch\dsh-background.log` |
| `stop-dsh.cmd` / `.ps1` | Stop the service (finds the process by port 3080) |
| `open-when-ready.ps1` | Polls the port and opens the browser when the service is ready (900-second timeout) |
| `background-run.cmd` | Actual executor for background mode: merges output into the log with a timestamp header |
| `update-check.ps1` | Version comparison: local npx cache vs latest on npm |
| `uninstall.ps1` | Removes this folder from the user PATH |
| `install-command.cmd` | Adds this folder to the user PATH and registers the `deepseek` command |
| `deepseek.ico` | Official DeepSeek whale icon (16-256px, multiple sizes) |

## FAQ

- **`deepseek` is not recognized as a command**: run `install-command.cmd` first, then open a new terminal window
- **Stuck on download / network errors**: switch to a mirror and retry: `npm config set registry https://registry.npmmirror.com`
- **Port 3080 is already in use (EADDRINUSE)**: an instance is already running — check with `deepseek --status`, or run `deepseek --stop` first
- **Service stops when the foreground window closes**: by design (the process lives in the console window); use `deepseek -b` for a persistent service
- **Migrate existing DSH settings (including API Key)**: copy the whole `%USERPROFILE%\.dsh` folder to `C:\Users\<username>\.dsh` on the new machine (contains sensitive credentials — do not share publicly)

## License

[MIT](LICENSE)
