# dsh-launcher

[中文](README.md) | [English](README.en.md)

![License](https://img.shields.io/github/license/RYun601/dsh-launcher)
![Release](https://img.shields.io/github/v/release/RYun601/dsh-launcher)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)

Windows 下 [DeepSeek Harness](https://github.com/deepseek-ai/dsh) Web 的启动与管理工具：
在 cmd / PowerShell 中输入 `deepseek` 即可一键启动（前台 / 后台双模式）、自动打开浏览器、
查询状态、停止服务，支持一键注册 `deepseek` 命令。

## 功能特性

- **命令行启动**：在 cmd / PowerShell 中输入 `deepseek` 即可启动
- **前台 / 后台双模式**：前台显示运行日志（关窗即停）；`deepseek -b` 提交后台启动后立即返回
- **自动打开浏览器**：服务就绪后自动打开 http://127.0.0.1:3080，无需手动输入地址
- **快捷方式启动反馈**：显示启动进度，成功打开浏览器后自动关窗；失败时保留窗口与日志提示
- **状态查询与停止**：`deepseek --status` 查看运行状态，`deepseek --stop` 一键停止并提示重启命令
- **跨系统通用**：Win10 / Win11 均可使用

## 安装

### 前置条件：安装 Node.js

dsh-launcher 是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的启动器，
只需先安装 Node.js；首次运行 `deepseek` 时，启动器会通过 npm 在 `%USERPROFILE%\dsh-launch\runtime` 准备并启动 DSH 本体。

1. 安装 [Node.js](https://nodejs.org) LTS

> 首次启动需要联网。Node.js 通常自带 npm；若环境自检提示未检测到 npm，请重新安装 Node.js LTS。

### 可选：安装官方 DSH CLI

只有需要在任意终端直接使用官方 `dsh` 命令时，才需要全局安装 DSH CLI：

```sh
npm install -g @deepseek-ai/dsh
```

新开一个终端后，可运行：

```sh
dsh web
```

浏览器打开 http://127.0.0.1:3080 看到界面即启动成功（Ctrl+C 退出）。

> `npm install -g @deepseek-ai/dsh` 会在 npm 的全局可执行目录注册 `dsh`（Windows 中为 `dsh.cmd`）。正常安装的 Node.js 会把该目录加入 PATH；若新开终端后仍提示找不到 `dsh`，请检查 npm 全局目录是否在 PATH 中。
>
> `npx @deepseek-ai/dsh web` 能直接启动 DSH，但不会注册可在任意终端使用的 `dsh` 命令。dsh-launcher 使用自己的版本化运行时，因此无需全局安装 DSH CLI。

### 方式一：PowerShell 一行命令（推荐）

```powershell
irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 | iex
```

自动完成：下载最新 Release → 解压到 `%USERPROFILE%\dsh-launcher` → 注册 `deepseek` 命令。

> 默认不创建桌面快捷方式。需要快捷方式时，请在同一个 PowerShell 窗口依次执行以下两步：
>
> 1. 下载安装脚本到当前目录：
>
>    ```powershell
>    irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 -OutFile .\install.ps1
>    ```
>
> 2. 执行该脚本，并传入 `-Shortcut` 参数：
>
>    ```powershell
>    .\install.ps1 -Shortcut
>    ```
>
> `-Shortcut`：在桌面创建「DeepSeek Harness」快捷方式，点击后以后台模式启动并显示启动进度；启动成功后窗口自动关闭。再次使用该参数会更新同名快捷方式；不带该参数时，安装器不会新建快捷方式。

### 方式二：手动安装

1. 从 [Releases](https://github.com/RYun601/dsh-launcher/releases) 下载 `dsh-launcher.zip` 并解压
2. 双击运行 `install-command.cmd`（注册 `deepseek` 命令）
3. 新开终端，输入 `deepseek`

### 方式三：从源码运行

```sh
git clone https://github.com/RYun601/dsh-launcher.git
cd dsh-launcher
```

## 快速开始

完成上方「安装」（任选一种方式）并**新开**一个终端窗口（使新 PATH 生效）后：

1. 输入 `deepseek -b` 提交后台启动并立即返回（或输入 `deepseek` 前台启动）
2. 首次运行会自动通过 npm 准备 DeepSeek Harness 运行时和必需依赖（需联网，约 1-2 分钟）
3. 服务就绪后浏览器自动打开 http://127.0.0.1:3080
4. 首次使用需要在 DeepSeek Harness 界面登录 / 填入 API Key

## 命令行用法

| 命令 | 说明 |
| --- | --- |
| `deepseek` | 前台启动（默认）：窗口显示日志，关闭窗口或 Ctrl+C 即停止 |
| `deepseek -b` / `-d` / `--background` / `--bg` / `--daemon` | 后台启动：提交后立即返回，服务继续运行并在就绪后自动打开浏览器 |
| `deepseek --status` | 查看服务状态（`RUNNING (ready)` / `RUNNING (starting)` / `STARTING` / `FAILED` / `NOT RUNNING`）；启动下载期间会显示 `STARTING`，失败时提示日志路径 |
| `deepseek --stop` | 停止服务（按端口 3080 定位进程，仅停止 DeepSeek Harness 相关进程），并提示重新启动命令 |
| `deepseek --logs [N]` | 显示后台日志末尾 N 行（默认 20），如 `deepseek --logs 50` |
| `deepseek --version` | 显示启动器版本与本地 DeepSeek Harness 版本 |
| `deepseek --update` | 对比本地与 npm 上的最新版本，提示更新方法 |
| `deepseek --upgrade` | 一键升级：停止服务 → 清理旧 DSH npx 工作区 → 准备最新版运行时 → 重新后台启动 |
| `deepseek --uninstall` | 从用户 PATH 移除 `deepseek` 命令（卸载注册） |
| `deepseek --uninstall --full` | 完整卸载：移除 PATH + 桌面快捷方式 + 日志与运行时目录 + 安装目录（带确认） |
| `deepseek --check` | 环境自检（脚本路径 / npm / 端口） |
| `deepseek --help` | 查看帮助 |

- 普通启动优先复用已经准备并校验过的本地 DSH 版本；存在可用本地运行时时不访问 npm。仅在没有可用运行时的首次启动或修复场景中准备依赖。使用 `deepseek --update` 从 npm 检查新版本，使用 `deepseek --upgrade` 安装并切换到新版本。

## 其他启动方式

- **直接运行脚本**：双击 `start-deepseek-harness.bat`（前台）或 `start-background.cmd`（后台进度窗；成功自动关闭、失败保留）

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `deepseek.cmd` | 命令行入口：前台 / 后台 / 停止 / 状态 / 自检 / 帮助 |
| `start-deepseek-harness.bat` | 前台启动脚本（启动服务 + 自动打开浏览器） |
| `start-background.cmd` / `.ps1` | 后台启动协调器：支持立即返回或等待就绪，日志写入 `%USERPROFILE%\dsh-launch\dsh-background.log` |
| `stop-dsh.cmd` / `.ps1` | 停止服务（按端口 3080 定位进程） |
| `open-when-ready.ps1` | 轮询 HTTP 服务，确认就绪后自动打开浏览器（900 秒超时保护） |
| `background-run.ps1` | 持有后台启动锁，记录生命周期状态与日志，并启动就绪监视器和 DSH 子进程 |
| `background-run.cmd` | 后台 runner 的兼容入口；正常启动关键路径直接使用 `background-run.ps1` |
| `run-dsh.ps1` | 串行准备版本化 DSH 运行时、补齐必需 peer 依赖、通过 `npm ls --all` 审计后启动 Node 入口 |
| `update-check.ps1` | 版本对比：本地运行时 / 旧 npx 缓存 / 全局安装 vs npm 最新版 |
| `upgrade-dsh.ps1` | 一键升级：停止服务、清理旧 DSH npx 工作区、准备并启动最新版运行时 |
| `set-shortcut.ps1` | 创建或迁移桌面快捷方式，配置可见启动进度窗口 |
| `uninstall.ps1` | 卸载：移除 PATH 注册（`-Full` 时同时删除快捷方式 / 日志和运行时 / 安装目录） |
| `install-command.cmd` | 把脚本目录加入用户 PATH，注册 `deepseek` 命令 |
| `VERSION` | 启动器版本号（`deepseek --version` 读取） |
| `deepseek.ico` | DeepSeek Harness 黑色鲸鱼图标（16~256px 多尺寸，桌面快捷方式使用） |
| `deepseek.svg` | 图标矢量源文件（取自 DSH web 前端 favicon，可用它重新生成 .ico） |

## 常见问题

- **输入 `deepseek` 提示"不是内部或外部命令"**：先运行 `install-command.cmd`，然后新开终端窗口
- **启动时卡在下载 / 报网络错误**：换国内镜像后重试 `npm config set registry https://registry.npmmirror.com`
- **`deepseek --status` 显示 `STARTING`**：表示 DSH 正在下载或启动，使用 `deepseek --logs 50` 查看实时错误；再次运行 `deepseek -b` 不会重复提交启动任务
- **`deepseek --status` 显示 `FAILED`**：DSH 在监听端口前退出，运行 `deepseek --logs 50` 查看具体错误后重试 `deepseek -b`
- **提示端口 3080 被占用（EADDRINUSE）**：说明已有一个实例在运行，用 `deepseek --status` 确认，或先 `deepseek --stop` 再启动
- **关闭前台窗口后服务就停了**：设计行为（进程寄宿在控制台窗口）；需要常驻请用 `deepseek -b`
- **想迁移已配置好的 DSH 设置（含 API Key）**：复制 `%USERPROFILE%\.dsh` 整个文件夹到新电脑的 `C:\Users\<用户名>\.dsh`（含敏感凭据，请勿公开）

## 许可证

[MIT](LICENSE)
