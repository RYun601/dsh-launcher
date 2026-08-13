# dsh-launcher

Windows 下 [DeepSeek Harness](https://github.com/deepseek-ai/dsh) Web 的启动与管理工具：
在 cmd / PowerShell 中输入 `deepseek` 即可一键启动（前台 / 后台双模式）、自动打开浏览器、
查询状态、停止服务；也支持一键注册命令、一键生成带官方鲸鱼图标的桌面快捷方式。

## 功能特性

- **命令行启动**：在 cmd / PowerShell 中输入 `deepseek` 即可启动
- **前台 / 后台双模式**：前台显示运行日志（关窗即停）；后台无窗口持续运行（关任何窗口都不影响）
- **自动打开浏览器**：服务就绪后自动打开 http://127.0.0.1:3080，无需手动输入地址
- **状态查询与停止**：`deepseek --status` 查看运行状态，`deepseek --stop` 一键停止并提示重启命令
- **跨系统通用**：Win10 / Win11 均可使用

## 快速开始

1. 安装 [Node.js](https://nodejs.org) LTS（运行 DeepSeek Harness 的前置条件）
2. 运行 `安装命令.cmd`，把脚本目录加入 PATH，注册 `deepseek` 命令
3. **新开**一个终端窗口（已打开的窗口不会加载新 PATH）
4. 输入 `deepseek -b` 后台启动（或输入 `deepseek` 前台启动）
5. 首次运行会自动通过 `npx` 下载 DeepSeek Harness（需联网，约 1-2 分钟）
6. 服务就绪后浏览器自动打开 http://127.0.0.1:3080

> 注意：首次使用需要在 DeepSeek Harness 界面登录 / 填入 API Key。

## 命令行用法

| 命令 | 说明 |
| --- | --- |
| `deepseek` | 前台启动（默认）：窗口显示日志，关闭窗口或 Ctrl+C 即停止 |
| `deepseek -b` / `--background` / `--bg` | 后台启动：无窗口持续运行，服务就绪后浏览器自动打开 |
| `deepseek --status` | 查看服务状态（`RUNNING - PID xxxx` / `NOT RUNNING`） |
| `deepseek --stop` | 停止服务（按端口 3080 定位进程），并提示重新启动命令 |
| `deepseek --check` | 环境自检（脚本路径 / npx / 端口） |
| `deepseek --help` | 查看帮助 |

## 其他启动方式

- **桌面快捷方式**：运行 `安装快捷方式.cmd`，自动生成「DeepSeek Harness」（前台）和
  「DeepSeek Harness（后台）」两个快捷方式（带鲸鱼图标）
- **直接运行脚本**：双击 `start-deepseek-harness.bat`（前台）或 `start-background.cmd`（后台）

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `deepseek.cmd` | 命令行入口：前台 / 后台 / 停止 / 状态 / 自检 / 帮助 |
| `start-deepseek-harness.bat` | 前台启动脚本（启动服务 + 自动打开浏览器） |
| `start-background.cmd` / `.ps1` | 后台启动：无窗口运行，日志写入 `%USERPROFILE%\dsh-launch\dsh-background.log` |
| `stop-dsh.cmd` / `.ps1` | 停止服务（按端口 3080 定位进程） |
| `open-when-ready.ps1` | 轮询探测端口，服务就绪后自动打开浏览器（900 秒超时保护） |
| `安装命令.cmd` | 把脚本目录加入用户 PATH，注册 `deepseek` 命令 |
| `安装快捷方式.cmd` | 一键生成桌面快捷方式（前台 + 后台，带图标） |
| `deepseek.ico` | DeepSeek 官方鲸鱼图标（16~256px 多尺寸） |

## 常见问题

- **输入 `deepseek` 提示"不是内部或外部命令"**：先运行 `安装命令.cmd`，然后新开终端窗口
- **启动时卡在下载 / 报网络错误**：换国内镜像后重试 `npm config set registry https://registry.npmmirror.com`
- **提示端口 3080 被占用（EADDRINUSE）**：说明已有一个实例在运行，用 `deepseek --status` 确认，或先 `deepseek --stop` 再启动
- **关闭前台窗口后服务就停了**：设计行为（进程寄宿在控制台窗口）；需要常驻请用 `deepseek -b`
- **想迁移已配置好的 DSH 设置（含 API Key）**：复制 `%USERPROFILE%\.dsh` 整个文件夹到新电脑的 `C:\Users\<用户名>\.dsh`（含敏感凭据，请勿公开）

## 许可证

[MIT](LICENSE)
