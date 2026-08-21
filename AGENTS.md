# AGENTS.md

## 适用范围

本文件适用于仓库根目录及其全部子目录。仓库中若以后出现更深层的 `AGENTS.md`，以更深层文件对其目录树的说明为准。

## 项目定位

`dsh-launcher` 是 DeepSeek Harness Web 的 Windows 启动与管理工具，不是 DeepSeek Harness 本体。仓库主要由 Windows PowerShell 5.1 脚本、CMD/BAT 兼容入口、GitHub Actions 工作流和自包含的 PowerShell 行为测试组成。

仓库没有需要安装的开发期 Node.js 依赖，也没有 `package.json`。Node.js 和 npm 是启动器在用户机器上准备 DSH 运行时所需的外部环境，不要把 `npm install` 写成仓库开发或测试的初始化步骤。

默认以最小改动解决问题。修改前先找到对应的公开入口、PowerShell 实现和行为测试，不要顺手重构无关脚本。

## 仓库导航

### 命令与启动链路

- `deepseek.cmd`：公开 CLI 入口，负责参数白名单、命令分派和退出码传播。
- `start-deepseek-harness.bat`：直接双击使用的前台兼容入口。
- `start-background.cmd`：桌面快捷方式使用的可见后台启动包装器。
- `start-background.ps1`：后台启动协调器，负责已有实例探测、启动锁、提交 runner 和等待就绪模式。
- `background-run.ps1`：后台 runner，拥有 DSH 子进程、日志、生命周期状态和浏览器就绪监视器。
- `background-run.cmd`：后台 runner 的兼容入口；复杂逻辑应继续保留在 PowerShell 中。
- `open-when-ready.ps1`：轮询 HTTP 就绪状态并打开浏览器。

### 状态、运行时与版本

- `dsh-launch-state.ps1`：启动锁、状态文件、令牌转移、存活检查和状态输出的共享实现。
- `resolve-dsh-version.ps1`：选择本地已安装版本或 npm 发布版本。
- `run-dsh.ps1`：串行准备版本化运行时、修复必要 peer 依赖、执行 npm 审计并启动 Node 入口。
- `dsh-version.ps1`：版本解析和比较的共享函数。
- `update-check.ps1`：比较本地运行时、旧缓存、全局安装和 npm 最新版本。
- `upgrade-dsh.ps1`：停止服务、清理 DSH npx 工作区、准备新运行时并重新后台启动。

### 安装与维护

- `install.ps1`：Release 下载和安装入口，也可迁移或创建快捷方式。
- `install-command.cmd`：把安装目录注册到用户 `PATH`。
- `set-shortcut.ps1`：创建或迁移桌面快捷方式。
- `stop-dsh.ps1` / `stop-dsh.cmd`：按端口识别并停止 DSH 相关进程。
- `uninstall.ps1`：移除 `PATH` 注册；完整卸载时还会处理快捷方式、日志、运行时和安装目录。

### 测试与发布

- `tests/*.Tests.ps1`：按职责划分的行为回归测试；测试自带断言和测试替身，不依赖 Pester。
- `tests/start-background-harness.ps1`：后台启动场景的测试辅助脚本，不是独立测试入口。
- `.github/workflows/check.yml`：拉取请求和 `main` 分支的解析、静态守卫及 Windows 行为测试。
- `.github/workflows/release.yml`：标签发布、测试、打包和解压归档烟雾测试。
- `release-files.txt`：发行包的唯一文件清单。
- `VERSION`：启动器版本；发布标签必须与其组成 `v<VERSION>`。
- `README.md` / `README.en.md`：面向最终用户的中英文文档，用户可见行为变化时必须同步。

## 运行环境与兼容性

### Windows PowerShell 5.1 是生产基线

发布脚本必须能由 `powershell.exe` 即 Windows PowerShell 5.1 执行。GitHub Actions 中使用 `pwsh` 协调部分检查，不代表可以在发布脚本中使用 PowerShell 7 独有语法或 API。

- 执行脚本和测试时优先使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`。
- 不依赖用户的 PowerShell profile、执行策略、当前工作目录或交互式会话状态。
- CMD/BAT 是公开兼容面；修改 PowerShell 实现时同时检查参数引用、路径空格、退出码和不同 Windows 代码页。
- `.cmd` / `.bat` 中避免加入依赖活动代码页的非 ASCII 输出。需要复杂文本处理时放入 PowerShell 实现。

### 编码要求

`install.ps1` 必须保持 UTF-8 **无 BOM**。BOM 会破坏 Windows PowerShell 5.1 下 `irm ... | iex` 的 `param()` 绑定，CI 对此有专门防护。

写入 JSON、日志、测试夹具或生成脚本时显式选择编码。沿用现有的 `[Text.UTF8Encoding]::new($false)`、`[Text.Encoding]::ASCII` 或等价的 Windows PowerShell 5.1 兼容写法，不依赖不同 PowerShell 版本的默认编码。

## 核心行为不变量

修改启动、状态、停止、版本或升级代码时必须保持以下约束：

1. DSH Web 使用 `http://127.0.0.1:3080`；更改端口需要完整更新探测、状态、停止、浏览器和文档链路，不能只改一处。
2. 后台启动只能有一个有效启动所有者。启动锁、状态文件、启动令牌和 launcher 到 runner 的 PID 转移必须保持一致。
3. 活锁必须保留，陈旧锁才可清理。重复后台命令不得提交第二个 runner；等待模式应附着到已有启动并传播其成功或失败。
4. 每次启动只有一个组件负责打开浏览器。正常后台路径由 runner 的就绪监视器拥有浏览器打开权，协调器不得重复打开。
5. 普通启动优先复用有效的本地版本化运行时，不应在可用运行时存在时访问 npm。显式更新检查或升级才发现远端发布版本。
6. 运行时准备必须串行化。只有安装、入口文件和依赖审计均满足条件后才能写入 ready 标记；未知的 npm 审计错误保持致命。
7. 运行时根目录必须位于启动器拥有的用户目录边界内。不要放宽 `run-dsh.ps1` 的路径验证，也不要让清理逻辑接受未经验证的宽泛路径。
8. `--stop` 只能停止与 DSH 启动链路相符的进程，不能因为端口被占用就终止任意进程。
9. CLI、前台/后台包装器、升级和卸载流程必须传播真实退出码。未知参数必须报错，不能静默回落到前台启动。
10. 正常的子进程标准错误输出本身不等于启动失败；最终状态应根据进程退出、HTTP 就绪和生命周期状态共同判断。

运行数据通常位于 `%USERPROFILE%\dsh-launch`，用户的 DSH 配置和凭据位于 `%USERPROFILE%\.dsh`。不要在测试、日志、提交或诊断输出中读取或复制真实 API Key。

## 编码约定

### PowerShell

- 脚本入口通常设置 `$ErrorActionPreference = 'Stop'`，对允许失败的调用使用局部、明确的 `-ErrorAction` 或 `try/catch`。
- 使用 `Join-Path` 组合路径，文件系统操作优先使用 `-LiteralPath`，避免把用户路径当作通配符。
- 参数块放在脚本允许的位置；需要支持管道执行的安装脚本必须保持 `param()` 绑定行为。
- 函数采用现有的 `Verb-Noun` / PascalCase 命名；变量使用可读名称，避免无意义缩写。
- 操作外部进程后显式检查 `$LASTEXITCODE` 或 `Process.ExitCode`，不要只依据输出文本猜测成功。
- 获取锁、启动进程、修改环境变量或创建临时目录时使用 `try/finally` 恢复状态并清理资源。
- 删除或迁移目录前先解析并验证目标边界。不要对未验证的环境变量、通配符或仓库根目录执行递归删除。
- 保持日志和状态写入可预测；更新共享状态时复用 `dsh-launch-state.ps1`，不要在调用方复制一套状态机。

### CMD/BAT

- CMD/BAT 只负责轻量参数分派和 PowerShell 兼容入口，不在其中扩展复杂状态逻辑。
- 所有可能包含空格的路径都要正确引用。
- 调用 PowerShell 后立即保存并通过 `exit /b` 传播退出码，避免后续命令覆盖 `%ERRORLEVEL%`。
- 修改 `deepseek.cmd` 参数时同步维护帮助文本、未知参数校验、README 和 `tests/startup-behavior.Tests.ps1`。

## 修改工作流

1. 先阅读相关入口、PowerShell 实现、最接近的 `tests/*-behavior.Tests.ps1` 和对应 README 段落。
2. 对行为变化先增加或调整能复现目标行为的回归测试；文档或纯注释修改无需制造无意义测试。
3. 实现最小修复，保留现有公开参数、输出含义、路径和退出码，除非任务明确要求改变它们。
4. 先运行最接近改动的单个测试，再执行解析检查和完整 Windows 行为套件。
5. 按“测试与发布同步”检查是否需要更新双语 README、`release-files.txt`、CI 静态守卫或 `VERSION`。

不要修改 `dist/` 中的副本来实现功能；发行物由工作流根据 `release-files.txt` 重新组装。不要提交日志、本地运行时、npm 缓存、用户配置或测试临时目录。

## 测试

### 运行单个行为测试

从仓库根目录调用最接近改动的测试，例如：

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior test failed' }
```

常见对应关系：

- 启动分派、参数、后台协调和 runner：`tests/startup-behavior.Tests.ps1`
- 锁、状态和失败生命周期：`tests/launch-state-behavior.Tests.ps1`
- 运行时安装、peer 修复、审计和串行化：`tests/runtime-preparation-behavior.Tests.ps1`
- 本地/远端版本选择与比较：`tests/version-resolution-behavior.Tests.ps1`、`tests/version-ordering-behavior.Tests.ps1`
- 浏览器就绪检测：`tests/open-when-ready-behavior.Tests.ps1`
- 停止逻辑：`tests/stop-behavior.Tests.ps1`
- 快捷方式：`tests/shortcut-behavior.Tests.ps1`
- 更新与升级缓存：`tests/update-check-behavior.Tests.ps1`、`tests/upgrade-cache-behavior.Tests.ps1`
- 发行文件和打包后分派：`tests/release-package-behavior.Tests.ps1`

这些测试通过 `$env:TEMP` 下的临时 profile、fake executable 和日志替身隔离外部状态。新增测试必须在 `finally` 中清理临时资源，不能触碰开发者真实的 `%USERPROFILE%\dsh-launch`、npm 缓存、桌面快捷方式或浏览器。

### 检查发行脚本能否解析

```powershell
$ErrorActionPreference = 'Stop'
$files = @(Get-Content .\release-files.txt | Where-Object { $_ -like '*.ps1' })
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PWD $file),
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        throw "parse failed: $file -> $($errors[0].Message)"
    }
}
```

### 运行完整 Windows 行为套件

```powershell
$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem .\tests -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($test in $tests) {
    Write-Host "Running $($test.Name)..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "$($test.Name) failed with exit code $LASTEXITCODE"
    }
}
```

某些进程识别测试需要访问 `Win32_Process`。受限沙箱若拒绝 `Get-CimInstance`，应明确报告环境限制；不要删除或放宽相应断言来制造通过结果。

### 发行包验证

修改 `release-files.txt`、入口分派、安装或打包流程时至少运行：

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior test failed' }
```

实际生成 `dist/dsh-launcher.zip` 后，再使用 `-ArchivePath .\dist\dsh-launcher.zip` 验证解压后的归档。

## 文档与发布同步

- git 提交信息（commit message）一律使用中文书写。
- Release 说明（release notes）使用中英双语书写，方便中英文用户阅读。
- 用户可见命令、参数、安装步骤、状态文本、默认路径或文件职责变化时，同时更新 `README.md` 和 `README.en.md`。
- 新增或重命名发行时需要携带的文件时更新 `release-files.txt`，并运行发行包行为测试。
- 只有准备新版本发布时才修改 `VERSION`。标签名必须严格等于 `v` 加 `VERSION` 内容。
- 静态回归守卫若表达了仍然有效的事故约束，应更新实现以满足守卫，而不是随意删除守卫。
- `AGENTS.md` 是仓库协作说明，不加入 `release-files.txt`，不随启动器压缩包发布。

## 完成前检查

- 改动范围是否只覆盖任务需要的文件，且未覆盖用户已有修改。
- 相关单个行为测试是否通过。
- `release-files.txt` 中的 PowerShell 脚本是否全部解析成功。
- 完整 Windows 行为套件是否通过；若受环境限制未完成，是否准确记录失败位置和原因。
- 用户可见变化是否同步到中英文 README。
- 新增运行时文件是否同步到 `release-files.txt`。
- `install.ps1` 是否仍为 UTF-8 无 BOM。
- 是否运行 `git diff --check`，并检查没有日志、发行物、缓存、凭据或临时文件进入改动。
