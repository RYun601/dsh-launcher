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

1. 安装 [Node.js](https://nodejs.org) LTS（要求 `^22.19.0 || >=24.0.0`；22 LTS 或 24+ 均可；启动器在安装、启动和升级前会统一检查并提示当前版本与升级方式）

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
| `deepseek --status` | 查看服务状态（`READY` / `STARTING` / `UNHEALTHY` / `FOREIGN_PORT` / `FAILED` / `STOPPED`）；启动下载期间显示 `STARTING`，失败时提示日志路径 |
| `deepseek --status --json` | 以版本化 JSON 输出同一状态（含时间戳与字段），问题状态（`FAILED` / `UNHEALTHY` / `FOREIGN_PORT`）以非零码退出，便于脚本消费 |
| `deepseek --stop` | 停止服务（按端口 3080 定位进程，仅停止 DeepSeek Harness 相关进程），并提示重新启动命令；进程无法结束或等待超时会显式报错并以非零码退出 |
| `deepseek --logs [N]` | 显示后台日志末尾 N 行（默认 20），如 `deepseek --logs 50` |
| `deepseek --logs --follow [N]` | 跟随日志输出（Ctrl+C 停止）；日志被轮转后会自动重连新文件，长期运行的后台日志超过 5MB 会轮转保留一代 `.old` |
| `deepseek --version` | 显示启动器版本与**当前活动**的 DeepSeek Harness 版本（优先读取 `runtime-current.json` 活动指针，指针缺失时回退旧版运行时目录，并标注其他非活动来源） |
| `deepseek --update` | 对比**活动运行时**版本与 npm 上的最新版本，提示更新方法；本地版本无法确认或远端解析失败时以非零码退出，不会把“未知”当作“已是最新” |
| `deepseek --upgrade` | 一键升级：解析并校验目标版本；当前运行时健康且版本不低于目标版本时直接提示已是最新并退出，不停止服务也不执行 npm 操作；否则停止服务 → 清理旧 DSH npx 工作区 → 同步全局 `dsh` 命令 → 重新后台启动；候选版本因插件依赖 DSH 已移除的导出而启动失败时，会列出不兼容插件并询问是否移除，确认后自动移除并重试；拒绝或处理失败时依次尝试恢复当前、上一版或旧版可用运行时（只有通过就绪校验的运行时才会被用于回退） |
| `deepseek --update-launcher` | 查询 GitHub 上启动器的最新稳定发行版并与本地版本比较（只查询，不改文件） |
| `deepseek --upgrade-launcher` | 自更新启动器：下载发行包并校验 SHA-256 与包清单 → 获取维护互斥锁 → 旧安装整目录备份 → 新版就位 → 离线烟雾验证 → 提交；服务运行中、DSH 升级进行中、源码工作树或非受管安装时拒绝执行；失败自动恢复旧版本（恢复未完成时保留备份与恢复脚本并以退出码 2 结束） |
| `deepseek --uninstall` | 从用户 PATH 移除 `deepseek` 命令（卸载注册） |
| `deepseek --uninstall --full` | 完整卸载：移除 PATH + 桌面快捷方式 + 日志与运行时目录 + 安装目录（带确认，取消不做任何更改；先停止服务，目录先备份后删除；PATH 在目录全部备份成功后才移除；安装目录会校验所有权标记，删除失败时保留备份并提示位置） |
| `deepseek --check` / `deepseek --doctor` | 环境诊断：启动器安装与版本、Node/npm、活动运行时与指针、服务状态与端口 3080 占用、最近一次失败原因；发现问题时以非零码退出 |
| `deepseek --help` | 查看帮助 |

- 普通启动优先复用已经准备并校验过的本地 DSH 版本；存在可用本地运行时时不访问 npm。仅在没有可用运行时的首次启动或修复场景中准备依赖。使用 `deepseek --update` 从 npm 检查新版本，使用 `deepseek --upgrade` 安装并切换到新版本。
- `deepseek --update` / `deepseek --upgrade` 默认直接查询 npm 公共 registry 的 dist-tags（比 `npm view` 更快）。如需使用镜像或私有 registry，可设置环境变量 `DSH_REGISTRY`（例如 `https://registry.npmmirror.com`）；该设置仅在查询远端发布版本时生效，不影响本地运行时启动。
- `deepseek --upgrade` 会同步 npm 全局的 `dsh` 命令：已安装则升级到最新版，缺失则自动安装，保证直接使用 `dsh` 命令的版本与启动器一致；该步骤失败仅提示警告，不影响启动器运行时的升级。目标版本无法解析或格式非法时，升级会在停止服务之前直接中止，不会影响当前安装。
- 如果候选版本启动日志确认某个插件依赖已经从 DSH 移除的导出，`deepseek --upgrade` 会显示插件名并询问是否从 `web` profile 移除；确认后使用目标版本的 `dsh plugin --profile web remove` 清理插件并重试候选运行时，拒绝则保留插件并回退旧运行时。
- 每次调用只允许一个动作（`--help`、`--status`、`--stop`、`-b` 等互斥）；出现多个动作时报错退出。`--full` 只能与 `--uninstall` 组合使用，并会传给事务式完整卸载流程；数字只允许紧跟在 `--logs` 后作为唯一的行数，`--json` 只允许跟随 `--status`、`--follow` 只允许跟随 `--logs`。PowerShell 层的失败退出码会原样传播到 `deepseek` 命令的返回值。
- Node.js 版本要求为 `^22.19.0 || >=24.0.0`（与上游一致）：安装、启动和升级三处共用同一版本检查，版本过低或未安装时会给出当前版本、要求版本和升级方式后直接失败，不会进入运行时准备流程。

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
| `update-check.ps1` | 版本对比：活动运行时指针 vs npm 最新版（其余来源仅作参考信息） |
| `update-launcher.ps1` | 启动器自更新：查询 / 下载 / 校验 GitHub 发行包并事务式替换当前安装（`--update-launcher` / `--upgrade-launcher`） |
| `dsh-doctor.ps1` | `deepseek --doctor` / `--check` 的环境诊断实现 |
| `dsh-logs.ps1` | `deepseek --logs` 的日志查看与跟随（支持轮转重连）实现 |
| `dsh-maintenance-lock.ps1` | 启动器维护互斥：覆盖安装、DSH 升级、自更新、完整卸载共用同一把用户级维护锁 |
| `version-info.ps1` | `deepseek --version` 的版本来源实现（活动指针优先） |
| `register-path.ps1` | `install-command.cmd` 的用户 PATH 注册实现 |
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
- **`deepseek --status` 显示 `UNHEALTHY`**：端口 3080 有 DSH 进程在监听但 HTTP 无响应（可能已卡死）；运行 `deepseek --stop` 后重新启动
- **`deepseek --status` 显示 `FOREIGN_PORT`**：端口 3080 被其他非 DeepSeek Harness 进程占用；启动前请先排查并释放该端口（启动器和停止逻辑都不会误杀陌生进程）
- **提示端口 3080 被占用（EADDRINUSE）**：说明已有一个实例在运行，用 `deepseek --status` 确认，或先 `deepseek --stop` 再启动
- **关闭前台窗口后服务就停了**：设计行为（进程寄宿在控制台窗口）；需要常驻请用 `deepseek -b`
- **想迁移已配置好的 DSH 设置（含 API Key）**：复制 `%USERPROFILE%\.dsh` 整个文件夹到新电脑的 `C:\Users\<用户名>\.dsh`（含敏感凭据，请勿公开）

## 许可证

[MIT](LICENSE)
