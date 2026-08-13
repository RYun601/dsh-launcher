# dsh-launcher

Windows 下 [DeepSeek Harness](https://github.com/deepseek-ai/dsh) Web 的一键启动器：
前台 / 后台启动、服务就绪自动打开浏览器、停止服务、一键安装带官方鲸鱼图标的桌面快捷方式。

## 功能特性

- **前台启动**：黑色窗口显示运行日志；服务就绪后浏览器**自动打开** http://127.0.0.1:3080（无需手动输入地址）
- **后台启动**：无窗口运行，关闭所有窗口也不影响服务
- **停止服务**：按端口 3080 定位进程并安全结束
- **一键安装**：`安装快捷方式.cmd` 自动检查 Node.js 并在桌面生成带 DeepSeek 鲸鱼图标的快捷方式
- **跨系统通用**：Win10 / Win11 均可使用

## 快速开始

1. 安装 [Node.js](https://nodejs.org) LTS（运行 DeepSeek Harness 的前置条件）
2. 双击 `start-deepseek-harness.bat`（或先运行 `安装快捷方式.cmd` 生成桌面快捷方式）
3. 首次运行会自动通过 `npx` 下载 DeepSeek Harness（需联网，约 1-2 分钟）
4. 服务就绪后浏览器自动打开 http://127.0.0.1:3080

> 注意：首次使用需要在 DeepSeek Harness 界面登录 / 填入 API Key。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `start-deepseek-harness.bat` | 前台启动（主入口）：启动服务 + 自动打开浏览器 |
| `open-when-ready.ps1` | 轮询探测端口，服务就绪后自动打开浏览器 |
| `start-background.cmd` / `.ps1` | 后台启动：无窗口运行，日志写入 `%USERPROFILE%\dsh-launch\dsh-background.log` |
| `stop-dsh.cmd` / `.ps1` | 停止服务（按端口 3080 定位进程） |
| `安装快捷方式.cmd` | 一键安装桌面快捷方式（带图标） |
| `deepseek.ico` | DeepSeek 官方鲸鱼图标（16~256px 多尺寸） |
| deepseek.cmd | 命令行入口：deepseek 前台 / deepseek --background 后台 |
| 安装命令.cmd | 把脚本目录加入用户 PATH，注册 deepseek 命令 |

## 常见问题

- **启动时卡在下载 / 网络错误**：换国内镜像后重试 `npm config set registry https://registry.npmmirror.com`
- **想迁移已配置好的 DSH 设置（含 API Key）**：复制 `%USERPROFILE%\.dsh` 整个文件夹到新电脑的 `C:\Users\<用户名>\.dsh`（含敏感凭据，请勿公开）
- **关闭前台窗口后服务停止**：这是设计行为（进程寄宿在控制台窗口）；需要常驻请使用后台启动模式

## 许可证

[MIT](LICENSE)