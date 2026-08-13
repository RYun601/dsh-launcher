# dsh-launcher

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

## Quick Start

1. Install [Node.js](https://nodejs.org) LTS (prerequisite for DeepSeek Harness)
2. Run `install-command.cmd` to add this folder to the user PATH and register the `deepseek` command
3. Open a **new** terminal window (already-open windows won't pick up the new PATH)
4. Type `deepseek -b` for background mode (or `deepseek` for foreground mode)
5. On first run, DeepSeek Harness is downloaded automatically via `npx` (needs internet, ~1-2 minutes)
6. The browser opens http://127.0.0.1:3080 automatically when the service is ready

> Note: on first use, sign in / enter an API Key in the DeepSeek Harness UI.

## CLI Usage

| Command | Description |
| --- | --- |
| `deepseek` | Foreground mode (default): shows logs in a window; close the window or press Ctrl+C to stop |
| `deepseek -b` / `--background` / `--bg` | Background mode: keeps running without a window; browser opens automatically when ready |
| `deepseek --status` | Show service state (`RUNNING - PID xxxx` / `NOT RUNNING`) |
| `deepseek --stop` | Stop the service (finds the process by port 3080) and reminds you how to restart |
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
