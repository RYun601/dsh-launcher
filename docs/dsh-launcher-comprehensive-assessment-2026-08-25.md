# dsh-launcher 综合评估与后续路线图

> 评估日期：2026-08-25<br>
> 评估对象：当前 `dsh-launcher` 代码、行为测试与发行流程<br>
> 对照项目：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)

## 结论摘要

当前项目已经不是简单的“启动一个 Node 命令”脚本，而是一套面向 Windows 的 DSH Web 生命周期管理器：它处理后台 runner、启动锁、令牌转移、状态文件、浏览器就绪、停止保护、版本化运行时、peer 依赖修复和行为回归测试。整体基础较好，最值得继续投入的方向是可靠性边界和可诊断性，而不是立即增加大量 UI 功能。

建议按以下顺序推进：

1. 先修复 Node 版本前置检查、CLI 退出码、进程身份/健康判定、卸载路径安全和升级回滚。
2. 再统一 workspace、端口、状态和版本通道配置，减少脚本之间的隐式常量。
3. 然后建设版本锁定/回滚、启动器自更新、`doctor` 诊断和受管 DSH CLI 透传。
4. 最后再考虑 watchdog、任务计划程序自启动和多实例等扩展能力。

## 1. 当前项目的能力与优点

### 1.1 启动生命周期设计已经比较完整

`start-background.ps1`、`background-run.ps1` 和 `dsh-launch-state.ps1` 已形成较清晰的职责边界：

- 启动协调器负责检查已有实例、获取锁并提交 runner。
- runner 接管启动令牌，拥有 DSH 子进程、日志、状态和浏览器就绪监视器。
- 令牌转移后，协调器退出不会误删仍由 runner 持有的活锁。
- 重复后台启动会附着到已有启动，而不是无条件创建第二个 runner。
- 失败生命周期、状态文件和日志可以帮助区分启动失败与正常退出。

这是 Windows 脚本项目中较容易遗漏的一层，当前实现已经覆盖了大部分常见竞态。

### 1.2 停止逻辑有进程所有权意识

`stop-dsh.ps1` 不只按端口杀进程，还会结合启动链路、命令行和父子进程关系进行判断。这比“发现 3080 被占用就执行 `taskkill`”安全得多，能够降低误杀其他本地服务的风险。

### 1.3 运行时准备遵循了可验证的串行流程

`run-dsh.ps1` 会准备版本化运行时、检查入口文件、补齐已知 peer 依赖、执行 npm 审计，并在准备完成后写入 ready 标记。普通启动优先复用有效本地运行时，避免每次启动都访问 npm；显式更新和升级仍可以发现远端版本。

对当前上游包做的临时审计显示，仍存在一批缺失的必需 peer 依赖，因此现有 peer 补齐机制并非多余逻辑。需要做的是让它更具版本感知能力，而不是直接移除。

### 1.4 行为测试覆盖面较好

本次评估执行了完整 Windows 行为套件：11 个测试脚本、61 个 `Invoke-Test` 场景，以及 1 个发行包独立场景，共 62 个场景全部通过；发行脚本解析检查通过，`install.ps1` 保持 UTF-8 无 BOM，`git diff --check` 通过。

测试按启动、状态、运行时、版本、浏览器、停止、快捷方式、升级缓存和发行包拆分，后续新增功能可以沿用现有的隔离测试替身，不需要引入重量级测试框架。

## 2. 与 deepseek-harness 的对照基线

上游项目仍处于开发预览阶段，CLI、配置和包依赖可能发生破坏性变化。评估时观察到的上游特征包括：

- 根项目要求 Node.js `^22.19.0 || >=24.0.0`。
- 当前源代码/发布包版本处于 `0.1.1-rc.2` 这一开发预览线；实现时应重新查询 npm，而不要把这个版本写死在启动器中。
- CLI 已提供 profiles、plugin 管理、配置导出（config dump）以及 Web 的 `--host`、`--port`、可重复 `--trusted-host`、`--no-open` 等参数。
- 默认 Web 地址是 `127.0.0.1:3080`，CLI 对 `--host 0.0.0.0` 有意拒绝；因此“直接暴露到公网”不应作为默认功能方向。
- CLI 文档将调用时的当前工作目录作为默认 workspace，并会加载 workspace 下的 `.env`、`AGENTS.md` 等文件。

上游参考：

- [deepseek-harness 主仓库](https://github.com/deepseek-ai/deepseek-harness)
- [上游 package.json](https://github.com/deepseek-ai/deepseek-harness/blob/master/package.json)
- [上游 CLI 中文参考](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/reference/README.zh.md)
- [上游用户指南](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.zh.md)

上游公开讨论中也出现过 Windows Web 卡死、端口仍监听但 HTTP 不再响应、`taskkill` 无法结束进程等问题。这些反馈不能单独证明本项目存在同样的缺陷，但说明健康检查、超时、日志和恢复操作值得优先建设：

- [Windows 下 Web 卡住的讨论](https://github.com/deepseek-ai/deepseek-harness/discussions/3155)
- [Windows 进程/端口异常的讨论](https://github.com/deepseek-ai/deepseek-harness/discussions/972)

## 3. 值得优化的点

下面按优先级分组。优先级表示对数据安全、用户可恢复性和启动成功率的影响，不表示实现工作量。

### P0：应优先处理的可靠性问题

| 方向 | 当前证据 | 风险 | 建议 |
| --- | --- | --- | --- |
| Node.js 版本前置检查 | `install.ps1` 目前主要检查 `node`/`npm` 是否存在；没有验证 Node 主版本和最低版本 | 安装成功但运行时因 Node 版本不兼容失败，错误信息滞后且不易定位 | 安装、启动和升级共用一个 Node 版本检查函数；明确提示当前版本、要求版本和升级方式 |
| CLI 参数分派与退出码 | `deepseek.cmd` 允许多个动作同时出现，分派逻辑带有字符串匹配/优先级；多条路径固定 `exit /b 0` | 用户看到命令成功但实际 PowerShell 失败；组合参数可能触发与预期不同的动作 | 使用显式动作枚举和互斥校验；PowerShell 调用后立即保存 `%ERRORLEVEL%` 并原样返回 |
| 服务身份与健康判定 | `start-background.ps1`、`dsh-launch-state.ps1` 和就绪脚本存在“端口可连/HTTP 状态小于 500”这类宽判定；锁所有者主要看进程名 | 其他程序占用 3080 时被误认为 DSH；端口监听但 Web 已死时仍报告成功；停止时可能误杀 | 状态至少拆成 `STARTING`、`READY`、`UNHEALTHY`、`FOREIGN_PORT`、`STOPPED`；结合启动令牌、进程命令行、入口路径、响应特征和状态文件判定 |
| 卸载安全边界 | `uninstall.ps1` 对日志目录和安装目录执行递归删除；完整卸载前没有可靠地先停止服务并确认路径归属 | 环境变量、安装目录配置异常时可能删除过宽；运行中的文件删除不完整，留下半卸载状态 | 删除前解析绝对路径并验证位于启动器拥有的用户目录边界；先停止并等待 runner；采用“移到回收目录/备份后删除”或可回滚步骤 |
| 升级原子性与回滚 | `upgrade-dsh.ps1` 在目标版本解析失败时仍可能继续使用默认最新版本；`run-dsh.ps1` 安装前会清理现有运行时 | 网络中断、npm 失败或新版本启动失败会直接破坏当前可用版本 | 先解析并验证目标版本，再创建 side-by-side 新运行时；新运行时通过健康检查后切换指针，失败自动保留旧版本 |

验收口径：P0 各项的验收不能只验证“改动后能正常启动/运行”，必须同时核对建议中的功能点是否完整落地；任何一项功能点缺失或仅部分实现，都视为验收未通过。每个方向至少补充一条对应的行为回归测试后再进入验收。

各方向的测试与验收：

1. **Node.js 版本前置检查**：行为测试覆盖未安装 Node、主版本过低、恰好满足最低版本三类输入，断言输出同时包含当前版本、要求版本和升级方式；验收时核对同一检查函数确实被安装、启动、升级三处共用，而不是只在其中一个入口生效。
2. **CLI 参数分派与退出码**：行为测试覆盖互斥动作组合、未知参数和 PowerShell 内部失败三类场景，断言 CMD 层拿到的是真实 `%ERRORLEVEL%` 而非固定值；验收时逐个动作核对分派结果与帮助文本一致，并确认代码中不再存在无条件 `exit /b 0` 的失败路径。
3. **服务身份与健康判定**：行为测试用替身 HTTP 服务模拟端口被其他程序占用、HTTP 可连但 Web 已死、真实 DSH 就绪三种状态，断言状态分别报告为 `FOREIGN_PORT`、`UNHEALTHY`、`READY`，且停止逻辑不终止陌生进程；验收时核对状态枚举完整覆盖 `STARTING`、`READY`、`UNHEALTHY`、`FOREIGN_PORT`、`STOPPED`，判定依据包含启动令牌、命令行和入口路径而不只是进程名。
4. **卸载安全边界**：行为测试构造边界外目录和运行中实例两类场景，断言递归删除只作用于已解析验证的边界内路径，完整卸载前先停止 runner 并等待其退出；验收时核对存在备份或可回滚步骤，并在环境变量指向宽泛路径等异常配置下脚本拒绝删除而不是继续执行。
5. **升级原子性与回滚**：行为测试模拟目标版本解析失败、npm 安装中断和新运行时健康检查失败三类场景，断言旧运行时始终保持可启动、不留半清理状态；验收时核对 side-by-side 目录与指针切换机制真实存在，任一失败路径都会自动保留旧版本且旧版本能再次启动成功。

### P1：应在下一阶段统一的工程问题

| 方向 | 当前证据 | 建议 |
| --- | --- | --- |
| workspace 传递 | `deepseek.cmd` 一开始切换到 `%USERPROFILE%`；后台 runner 的工作目录也固定为用户目录 | 保留调用方当前目录作为默认 workspace，增加显式 `--workspace <path>`；启动状态中记录最终 workspace，避免 `.env`、`AGENTS.md` 和项目文件被加载错位置 |
| 端口配置集中化 | `start-background.ps1` 暴露 `Port` 参数，但 runner、状态和部分探测仍固定 3080 | 建立单一配置源，并让启动、就绪、状态、停止、浏览器和文档全部从同一配置读取；未完成全链路前不要只开放局部端口参数 |
| 版本通道与版本来源 | `resolve-dsh-version.ps1` 按 dist-tags 选择最高版本；缓存、全局安装和受管运行时的关系不够显式 | 区分 `managed`、`global`、`cache` 三类版本；提供 `latest`、`next`、固定版本和回滚版本；展示选择原因 |
| peer 修复策略 | `run-dsh.ps1` 包含针对旧版 rc.8 的 React 18.3.1 修复启发式 | 根据实际 package metadata、peer range 和 DSH 版本决定修复；记录修复清单和来源，避免旧规则误伤未来版本 |
| 安装器事务性 | `install.ps1` 解压、迁移、PATH 注册和快捷方式创建缺少统一回滚；自定义安装目录的归档目录名也有边界问题 | 使用唯一临时目录、校验下载文件、先完整解压和验证，再切换安装目录；PATH/快捷方式失败时回滚文件变更 |
| 全局 `dsh` 安装策略 | `upgrade-dsh.ps1` 会在缺失时自动安装全局 `dsh`，而上游文档把全局 CLI 视为可选 | 默认使用启动器管理的运行时；全局命令同步改成明确的 opt-in，避免污染用户 npm 全局环境 |
| 锁的进程身份 | 当前锁主要依赖 PID/进程名，PID 复用或同名进程会增加误判概率 | 锁中保存 token、PID、命令行摘要、入口路径和创建时间；验证时至少匹配 token 与命令行，不要仅凭进程名 |
| 测试与 CI 矩阵 | 现有行为测试强，但工作流对 PowerShell 解析、Windows PowerShell 5.1 与 PowerShell 7 的边界仍可进一步显式化；静态守卫在多个 workflow 中有重复 | 增加 PS 5.1 解析/最小执行矩阵，统一可复用的静态检查；对端口冲突、HTTP 假就绪、升级中断、卸载边界补充回归场景 |
| 文档准确性 | `README.md` 中仍有指向 `deepseek-ai/dsh` 的失效链接；上游实际仓库是 `deepseek-harness` | 修复中英文 README 链接，并增加“受管运行时、workspace、版本通道和诊断命令”的说明 |

### P2：体验和运维增强

- 日志轮转、日志大小上限和 `--logs --follow`，避免长时间运行后日志无限增长。
- `--status --json` 和稳定的状态码，方便桌面快捷方式、脚本和 CI 消费。
- 启动/停止/升级超时配置，以及失败时自动输出最近一段 runner 日志。
- 对 npm registry、下载、解压、审计等阶段显示耗时，帮助区分网络慢、依赖安装慢和 DSH 本身启动慢。
- 将重复的 PowerShell 静态检查抽成 CI 共享步骤，减少工作流漂移。

## 4. 值得新增的功能

### 4.1 `deepseek --doctor` 诊断报告

这是投入产出比最高的新功能。建议一次性检查并输出：

- Windows PowerShell 版本、Node/npm 版本和 PATH 命中位置。
- 当前安装目录、运行时版本、ready 标记和状态文件摘要。
- 3080 端口占用者的脱敏进程信息。
- DSH 入口文件、关键 peer 依赖、npm audit 结果摘要。
- 最近一次启动/停止/升级失败阶段和日志尾部。

报告默认只输出脱敏信息；可选 `--doctor --bundle <path>` 生成诊断压缩包，明确排除 API Key、`.dsh` 凭据和完整环境变量。

### 4.2 启动器自更新

将“更新 dsh-launcher”和“更新 DSH 运行时”分开。启动器自更新可以检查 GitHub Release，下载并校验新的归档，使用 side-by-side 目录替换文件，并在失败时恢复旧版本。这样可以避免旧版启动器无法处理新版上游 CLI 的问题。

### 4.3 运行时版本通道、固定和回滚

提供以下命令族或等价参数：

```text
deepseek --version-list
deepseek --version-channel latest|next
deepseek --version-pin <version>
deepseek --rollback
```

版本目录应保留多个已验证运行时，并用一个小型元数据文件记录当前活动版本、来源、安装时间、Node 版本和健康检查结果。切换版本只更新指针，不重复删除和重装所有内容。

### 4.4 受管 DSH CLI 透传

上游已经提供 profiles、plugins、config dump 等能力。启动器可以提供：

```text
deepseek dsh <upstream arguments...>
```

该命令应明确使用启动器选择的受管运行时和 workspace，不要求用户再安装全局 `dsh`，也不能把凭据打印到日志。这样既保留启动器的一致性，又不会把上游 CLI 的每个新参数复制一遍。

### 4.5 workspace、端口和实例配置

支持配置文件或参数覆盖：

- 默认 workspace：当前目录。
- 显式 workspace：`--workspace <path>`。
- 端口：配置文件、环境变量和命令行的优先级应固定并记录。
- 实例名称：为未来的开发/测试多实例预留命名空间，但默认仍保持单实例。

多实例不应作为第一阶段功能，因为它会同时影响锁、状态、停止、浏览器、日志和端口的全链路语义。

### 4.6 运维命令补齐

建议提供以下轻量命令，而不强迫用户手工操作 PowerShell：

- `--health`：只做健康检查并返回机器可读退出码。
- `--restart`：按安全停止、等待端口释放、重新启动的顺序执行。
- `--logs --follow`：实时跟随 runner 日志。
- `--repair`：在确认后重建损坏的受管运行时，并优先保留旧版本。
- `--open`：只打开已就绪的地址，不重复启动服务。

### 4.7 可选 watchdog 与自动启动

在健康状态模型稳定后，可以增加可选 watchdog：发现进程存活但 HTTP 不健康时，先记录诊断，再按退避策略重启。任务计划程序自动启动也应是显式 opt-in，并提供关闭、查看任务和清理任务的命令。

不建议现在直接加入“监听 `0.0.0.0` 并对外提供 Web”的一键功能。上游 CLI 已主动拒绝该 host，且这会带来认证、TLS、CSRF 和防火墙配置问题；若未来确有需求，应先设计反向代理和访问控制，而不是简单放宽参数。

## 5. 建议路线图与验收标准

### 阶段一：可靠性收口

实现 Node 版本检查、严格参数分派、真实退出码传播、服务身份/健康状态、卸载路径边界和升级 side-by-side 回滚。

验收重点：

- Node 版本不满足时在安装/启动前得到可操作错误。
- 任意 PowerShell 失败都能传到 CMD、快捷方式和 CI。
- 3080 被其他 HTTP 服务占用时显示 `FOREIGN_PORT`，不会打开错误页面或停止陌生进程。
- 新运行时启动失败时旧运行时仍可启动。
- 卸载不会删除安装边界外的目录，且运行中卸载能先安全停止。

### 阶段二：统一配置和 workspace

引入共享配置读取、`--workspace`、端口全链路传递和结构化状态输出，并同步中英文 README。

验收重点：同一组配置能够被前台、后台、停止、状态、浏览器和升级流程一致读取；从任意工作目录启动时，上游能看到用户指定的 workspace。

### 阶段三：版本与诊断产品化

加入版本通道、固定版本、回滚、启动器自更新、`--doctor` 和受管 DSH CLI 透传。

验收重点：用户可以解释“当前运行了哪个版本、从哪里来、为什么被选择”，并能在不复制凭据的情况下提交诊断报告。

### 阶段四：可选自动化

在前述状态模型和回滚能力稳定后，再加入 watchdog、任务计划程序自启动和受控多实例。

验收重点：自动恢复有次数上限、退避和日志；关闭功能后不会残留后台任务或锁文件。

## 6. 实施时需要持续关注的风险

1. 上游目前是开发预览版本，包结构、peer 依赖和 CLI 参数可能变化。每次实现前应重新读取上游 package metadata、CLI 参考和 release notes。
2. Node 版本要求是启动器必须显式处理的外部契约，不能只依赖 npm 安装阶段碰巧报错。
3. 3080、`%USERPROFILE%\dsh-launch` 和 `%USERPROFILE%\.dsh` 是当前用户可见契约。端口、路径或凭据边界的变更需要同步测试与双语 README。
4. 诊断、日志和状态输出必须默认脱敏，尤其不能读取或复制真实 API Key。
5. 新增行为应先在现有 PowerShell 5.1 测试替身中建立回归场景，再修改生产脚本；不要用放宽断言的方式掩盖环境限制。

## 7. 评估依据

- 当前仓库代码：`deepseek.cmd`、`start-background.ps1`、`background-run.ps1`、`dsh-launch-state.ps1`、`run-dsh.ps1`、`install.ps1`、`upgrade-dsh.ps1`、`uninstall.ps1` 及对应测试。
- 当前测试结果：完整 Windows 行为套件 62 个场景通过；发行脚本解析、无 BOM 和 diff 检查通过。
- 上游资料：[deepseek-harness 主仓库](https://github.com/deepseek-ai/deepseek-harness)、[package.json](https://github.com/deepseek-ai/deepseek-harness/blob/master/package.json)、[CLI 参考](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/reference/README.zh.md)、[用户指南](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.zh.md)。
- 上游 Windows 运行问题讨论：[讨论 3155](https://github.com/deepseek-ai/deepseek-harness/discussions/3155)、[讨论 972](https://github.com/deepseek-ai/deepseek-harness/discussions/972)。

本文件是架构和产品规划评估，不代表其中所有建议已经实现。落地每一项建议时，应单独补充设计、行为测试、双语用户文档和发行包验证。
