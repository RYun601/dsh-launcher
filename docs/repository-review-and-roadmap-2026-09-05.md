# dsh-launcher 代码审查与功能路线图

> 审查日期：2026-09-05。
> 基线 commit：`9d1433a2e43b14fb87701527ed6b2bff27e77117`；启动器 `VERSION = 0.1.11`。
> 本次按用户要求只交付文档，不实现新命令、不修复功能代码、不发布版本。
> 配套方案：[启动器自更新命令设计](launcher-self-update-design-2026-09-05.md)。

## 1. 结论与建议顺序

当前仓库已有启动身份与令牌校验、较完整的状态行为测试、统一 Node 前置检查，以及候选运行时和当前/上一版本指针。不能再沿用旧评估中“这些机制完全没有实现”的结论。

仍需优先处理的边界集中在停止进程识别、运行时物理路径、安装/卸载事务，以及测试对真实系统资源的隔离。隔离复现已证实：停止脚本可把无关进程判为 DSH、运行时路径检查接受指向边界外的 junction、卸载回滚会丢快捷方式、安装失败可留下混合版本。其次是版本显示不读取活动指针，以及含单引号路径下的 CLI 错误。

建议实施顺序：

1. 修复测试隔离，再修复停止识别、路径边界和卸载恢复，建立可安全运行的验收基线。
2. 补上安装/升级维护互斥与失败恢复，再实现启动器自更新；不要直接为覆盖安装器加一个命令别名。
3. 统一版本来源，并增加 `--doctor`、结构化状态、日志跟随和显式运行时回滚。
4. 最后再考虑 workspace 配置、多实例、自动重启和开机启动。

下文 P1 表示应优先修复的安全或可靠性问题，P2 表示常规正确性或体验问题。本次没有给出需要假定已发生事故的 P0 结论。

## 2. 审查方法与边界

检查范围包括 CLI 分派、前台/后台入口、runner、锁与状态共享函数、服务健康判定、停止、运行时布局与安装、版本解析、DSH 升级、启动器安装/卸载、快捷方式、发行清单和 GitHub 工作流，并对照相应行为测试。对大型状态模块结合关键函数阅读与现有回归结果判断，不宣称形式化证明或穷尽所有时序。

证据分为：

- **隔离复现**：Windows PowerShell 5.1，临时目录和合成数据；记录实际结果。
- **代码确认**：能从明确执行路径确认实现问题；没有在真实服务上触发故障。
- **待验证风险**：存在需要补测的边界，但证据不足以宣称已经造成具体生产故障。

所有复现均未读取真实 API Key，未对真实 DSH 执行启动、停止、升级或卸载。涉及卸载的临时脚本副本只替换桌面定位和用户 PATH 访问这两个外部接口，保留原路径判断、移动、回滚与删除逻辑；因此结果用于证明事务缺陷，不等于原始完整卸载套件已经通过。

代码定位均相对于上述基线，链接固定到该 commit，避免后续修改导致行号含义漂移。8 月 25 日的[历史评估](dsh-launcher-comprehensive-assessment-2026-08-25.md)保留为历史记录；其测试统计与上游版本信息不作为本次结果。

## 3. 需要处理的问题

### R1 · P1：停止脚本的身份判断仍可能命中无关进程

> **实施状态（2026-09-05）：✅ 已修复。** `stop-dsh.ps1` 复用 `dsh-service-health.ps1` 的 `ConvertFrom-DshWindowsCommandLine` 做结构化命令行判定：Node 进程必须携带独立的 `@deepseek-ai\dsh\lib\bin.js` 路径参数；PowerShell 进程必须是 `-File` 指向 `background-run.ps1` / `run-dsh.ps1` / `start-foreground.ps1`；普通参数或日志文件名提到脚本名不再授予停止权限，身份查询失败一律 UNKNOWN 不终止。启动锁分支已由 `TestStartupLock` 的精确身份校验覆盖（含前台 STARTING 所有者）。`tests/stop-behavior.Tests.ps1` 新增 6 项场景（无关参数、`-Command` 提及脚本名、错误入口、身份查询失败、锁 PID 复用、前台所有者），13/13 通过。

- **位置**：[stop-dsh.ps1 第 25–43 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/stop-dsh.ps1#L25)。
- **触发条件**：3080 的监听进程命令行参数中恰好包含 `run-dsh.ps1`、`background-run.ps1` 或匹配的 DSH 路径片段，但真正执行的是另一个程序。
- **证据**：从源文件 AST 提取并执行原 `Get-DshLauncherProcessState`，仅替换 `Get-CimInstance`。输入 `node.exe C:\unrelated\server.js --log-path C:\notes\run-dsh.ps1`，实际返回 `ALIVE`。调用者遇到 `ALIVE` 会执行 `taskkill /T /F`。复现没有执行 taskkill。
- **影响**：进程识别只检查整条命令行的子串，未验证可执行程序、脚本参数角色及当前启动身份；这比健康模块的精确参数检查宽松。
- **建议**：复用共享命令行解析，按 Node 入口、PowerShell `-File` 入口和受管 runner 分别验证；结合当前锁/状态身份，且在终止前复检。普通参数或日志文件名提到脚本名不能授予停止权限。
- **验收**：添加上述无关参数、脚本名近似、错误入口、PID 复用和身份查询失败用例；断言没有停止调用。另检查前台 STARTING 所有者的识别，避免只补后台分支。

### R2 · P1：运行时边界只验证字符串，接受指向边界外的重解析点

> **实施状态（2026-09-05）：✅ 已修复。** `dsh-runtime-layout.ps1` 新增统一物理边界检查 `Assert-DshRuntimePathWithinOwnedRoot`：先按 `GetLongPathName` 归一 8.3 短名再做前缀比较，然后从目标逐级检查到 launch root（含根本身），任一级为重解析点即拒绝。接入点：`Resolve-DshOwnedRuntimePath`（指针读取）、`Commit-DshRuntimePointer`（候选提交）、`run-dsh.ps1`（运行时根准备入口）；`Remove-DshUnreferencedRuntimes` 绝不递归删除重解析点目录。`tests/runtime-layout-behavior.Tests.ps1` 新增 4 项（边界外 junction、父级 junction、清理防穿透、短路径别名），`tests/runtime-preparation-behavior.Tests.ps1` 新增 junction 运行时根拒绝场景，10/10 与 11/11 通过。

- **位置**：[run-dsh.ps1 第 16–23 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/run-dsh.ps1#L16)、[dsh-runtime-layout.ps1 第 8–23 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/dsh-runtime-layout.ps1#L8)。
- **触发条件**：受管路径中的某一级是 junction，例如合成 profile 下的 `dsh-launch\runtime-alias` 指向受管数据目录之外。
- **证据**：在临时目录外侧建立合法 ready 夹具，通过上述 junction 调用原 `run-dsh.ps1 -Version 0.2.0 -PrepareOnly`，实际退出 `0`。Node 版本查询使用替身，未启动 Node 服务。证明路径检查接受了物理边界外的运行时；没有用真实数据验证删除后果。
- **影响**：`GetFullPath` 与 `StartsWith` 能拦截普通 `..` 越界，不能解析链接目标。安装、读取、未来清理仍可能通过别名落到非受管目录，与 `.dsh` 的绝对保护要求不一致。
- **建议**：统一运行时根、候选路径、指针解析和清理时的物理路径检查；至少拒绝从 profile 到最终目标路径上的重解析点，并处理长路径/8.3 别名。可参考安装器已有防护，但不能仅复制字符串前缀判断。
- **验收**：junction 指向合成边界外目录与合成 `.dsh`，以及父级 junction、非法指针与短路径别名；读取准备、写入和清理入口均应拒绝，哨兵保持不变。

### R3 · P1：完整卸载回滚会丢失已备份的快捷方式

> **实施状态（2026-09-05）：✅ 已修复。** `uninstall.ps1` 事务记录同时保存原始路径与实际备份路径（`Restore-TransactionMoves`），逐项逆序恢复并验证结果；全部恢复成功才清理备份区，任何失败都保留剩余备份并输出恢复位置，不再无条件删除唯一恢复副本。PATH 提交失败分支复用同一恢复逻辑，并新增注入点 `DSH_TEST_UNINSTALL_FAIL_PATH` / `DSH_TEST_UNINSTALL_FAIL_RESTORE`。`tests/uninstall-behavior.Tests.ps1` 新增快捷方式先搬移后失败、PATH 提交失败、恢复失败保留备份三项场景，14/14 通过。

- **位置**：[uninstall.ps1 第 154–174 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/uninstall.ps1#L154)，同样问题存在于第 187–198 行的 PATH 失败恢复分支。
- **触发条件**：快捷方式先成功移入备份，随后日志或安装目录搬移失败，或 PATH 提交失败。
- **证据**：备份 key 为 `shortcut`，实际文件名为 `DeepSeek Harness.lnk`；恢复代码却按 key 查找 `backupRoot\shortcut`。临时桌面放置哨兵快捷方式，使用现有 `DSH_TEST_UNINSTALL_FAIL_MOVE=install` 触发失败，结果为退出 `1`、安装目录和日志恢复、快捷方式不存在、备份目录数为 `0`。
- **影响**：输出声称已回滚，但快捷方式没有恢复，其唯一备份被递归清理。同一恢复逻辑还忽略 `Move-ToBackup` 的失败返回值，其他恢复失败也可能被清理掩盖；后一情形本次未另做文件锁复现。
- **建议**：事务记录同时存原路径与实际备份路径；逐项验证恢复结果，全部恢复成功后才能清理。任何失败都保留剩余备份并输出恢复位置。
- **验收**：覆盖快捷方式先搬移后失败、恢复时文件被锁、PATH 写入失败；不只检查安装目录和日志，应核对每个已移动条目的内容。

### R4 · P1：卸载测试没有隔离真实桌面与历史恢复备份

> **实施状态（2026-09-05）：✅ 已修复。** `uninstall.ps1` 新增两个测试注入点：`DSH_TEST_UNINSTALL_DESKTOP`（仅接受位于已解析用户目录边界内的假桌面）与 `DSH_TEST_UNINSTALL_PATH_STORE`（文件模拟用户 PATH 存储，测试不再触碰真实注册表）。`tests/uninstall-behavior.Tests.ps1` 改为注入假桌面、PATH 存储和测试专用 TEMP，备份目录只枚举/清理测试 TEMP 内本次产生的目录；新增“历史备份哨兵保留”与“真实用户 PATH 不变”断言。14/14 通过。安装器（`install.ps1`）的桌面注入点随阶段 C 自更新一并接入。

- **位置**：[tests/uninstall-behavior.Tests.ps1 第 90–121 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/tests/uninstall-behavior.Tests.ps1#L90)、[第 233–238 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/tests/uninstall-behavior.Tests.ps1#L233)、[uninstall.ps1 第 113 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/uninstall.ps1#L113)。
- **触发条件**：在真实用户会话运行完整套件，桌面存在同名快捷方式，或 TEMP 已有先前真实卸载留下的 `dsh-launcher-backup-*`。
- **证据**：修改进程的 `USERPROFILE` 后，实测 `[Environment]::GetFolderPath('Desktop')` 仍返回原桌面，而非假 profile 桌面。测试未注入桌面路径；其 finally 枚举并删除 TEMP 中所有匹配的备份目录，并不限于本次创建的目录。用户 PATH API 也仍指向真实用户注册表，虽然现有断言期待值不变。
- **影响**：测试可能移动/删除真实快捷方式，或删掉原本用于人工恢复的历史备份。这是测试自身的隔离缺陷，不能用“测试使用了临时 profile”排除。
- **建议**：注入桌面、PATH 存储和独立 TEMP；只清理本次记录且已验证边界的资源。失败恢复测试应预置“其他任务的备份”哨兵并断言其保留。
- **验收**：普通用户桌面存在同名文件、TEMP 有历史备份、PATH 非空时，全部真实资源保持不变。安装测试和发行包安装烟雾同样需要检查桌面隔离。

### R5 · P1：覆盖安装失败会留下新旧混合版本

> **实施状态（2026-09-05）：✅ 已修复。** `install.ps1` 提交阶段改为事务式：解压后先校验包（VERSION、必需入口文件、全部 PS1 可被 Windows PowerShell 5.1 解析、包内 install.ps1 无 BOM），通过 Node 检查后进入用户级维护互斥，在同卷准备完整 payload 目录，旧安装整目录改名到相邻备份，新 payload 原子改名就位，写所有权标记并做离线烟雾验证（deepseek.cmd + VERSION 一致）后才提交并清理备份；任何阶段失败都会把旧安装原样移回，恢复失败则保留备份并输出位置。`tests/install-behavior.Tests.ps1` 新增 3 项：目标被占用中止且旧文件集一致、注入 swap/marker/smoke 三阶段失败均恢复旧版、成功覆盖完整替换文件集（不再混合新旧）。11/11 通过。

- **位置**：[install.ps1 第 193–219 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/install.ps1#L193)。
- **触发条件**：已有安装目录中某个较后复制的文件被占用、权限拒绝或复制失败。
- **证据**：隔离安装包包含 `aa-updated.txt` 与 `zz-blocked.txt`；旧目标均为 `old`，新包均为 `new`。锁住后一个目标文件，安装器退出 `1`，前一个目标已变为 `new`，后一个仍为 `old`。复现只替换真实桌面查询，使用本地 ZIP、Node/npm 替身与 `-SkipPath`。
- **影响**：解压暂存不等于提交有事务性；旧文件已经被逐个覆盖，finally 只清理下载/暂存目录，不恢复安装。新自更新命令若直接复用这一流程，将继承该问题。
- **建议**：提交前完整校验，建立维护互斥和恢复副本，再切换文件集合；更新失败恢复原版本。包清单、版本与摘要验证也应在执行包内脚本前完成。
- **验收**：逐阶段模拟下载、复制、目录移动和烟雾失败，验证旧版本能运行且文件集合一致。

### R6 · P2：完整卸载会删除非本安装拥有的同名快捷方式

> **实施状态（2026-09-05）：✅ 已修复。** `uninstall.ps1` 新增 `Test-DshOwnedDesktopShortcut`：清理前核对快捷方式目标/参数是否指向本安装（含 `start-background.cmd` 包装器）、工作目录或受管描述；同名普通文件与指向其他安装的快捷方式一律保留并明确输出。测试覆盖三种归属（本安装删除、其他安装保留、同名普通文件保留），14/14 通过。

- **位置**：[uninstall.ps1 第 113–118 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/uninstall.ps1#L113)、第 154–156 行；对照 [set-shortcut.ps1 第 25–40 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/set-shortcut.ps1#L25)。
- **证据**：临时桌面存在名为 `DeepSeek Harness.lnk` 的无关哨兵文件，完整卸载返回 `0`，文件被删除。没有打开或修改真实桌面。
- **影响**：安装迁移已会识别同名快捷方式，卸载却仅凭文件名清理；多个安装副本或用户自己创建的快捷方式会受影响。
- **建议与验收**：清理前核对目标命令、工作目录与本安装身份；同名但指向其他安装/程序的快捷方式应保留，测试覆盖三种归属。

### R7 · P2：版本查询与更新提示没有读取活动运行时指针

> **实施状态（2026-09-05）：✅ 已修复。** `dsh-runtime-layout.ps1` 新增统一版本报告 `Get-DshRuntimeVersionReport`（Current 指针优先、legacy 回退、指针损坏单独标注）；新增 `version-info.ps1` 供 `deepseek --version` 显示 launcher 版本、活动运行时版本与来源路径，并单独列出 Previous 指针、legacy、全局、缓存等非活动来源；`update-check.ps1` 重写为同一来源：本地未知时明确“无法确认当前实际使用版本”并以非零退出码结束（绝不解释为“已是最新”），远端解析失败显式返回非零；本地高于远端时输出“本地较新”。顺带修复 `resolve-dsh-version.ps1` 在完全解析失败时把空数组传给 `Get-HighestDshVersion` 的崩溃。测试：`update-check-behavior` 重写为 6 项（指针活动、指针与 legacy 不同、全局高于当前仅提示、未知不判最新、指针损坏、远端失败非零）6/6 通过；`version-resolution-behavior` 8/8。

- **位置**：[deepseek.cmd 第 149–152 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/deepseek.cmd#L149)、[update-check.ps1 第 19–47 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/update-check.ps1#L19)。
- **触发条件**：通过新布局使用 `runtime-versions` 和 `runtime-current.json`，旧 `runtime` 不存在、版本过旧，或全局版本与受管版本不同。
- **证据**：合成活动指针指向已准备的 `0.2.0`，没有旧缓存与全局安装；原 `deepseek --version` 返回 `DeepSeek Harness unknown`。原更新检查搭配只返回 `0.2.0` 的远端解析替身，也把本地显示为 `unknown`。代码还会把本地未知落入“已是最新版本”分支。
- **影响**：用户无法确认实际使用的版本；从全局/缓存取最高值也不等于当前受管版本。现有更新检查测试只建立 legacy 路径，遗漏此布局。
- **建议**：统一查询函数，优先显示有效 Current，同时分别标出 Previous、legacy、global、cache 来源；版本未知不能解释为已是最新。更新检查还应显式处理远端解析失败的非零退出码。
- **验收**：仅 Current、Current 与 legacy 不同、global 高于 Current、指针损坏、无本地安装及远端失败。

### R8 · P2：含单引号的安装路径使 `--version` 解析失败

> **实施状态（2026-09-05）：✅ 已修复。** `deepseek.cmd` 的 `:version` 分派改为 `-File "%~dp0version-info.ps1"`，不再向内联 PowerShell 单引号字符串注入路径；并在该分派块内 `setlocal DisableDelayedExpansion`，使安装路径中的感叹号不被 CMD 延迟扩展吞掉。`install-command.cmd` 的内联 PATH 注册同样移入新文件 `register-path.ps1`（`-File` 调用），注册失败立即传播退出码，不再无条件输出 Done。验收测试加入 `version-resolution-behavior`：在含空格、单引号、感叹号、中文的安装目录中运行 `deepseek.cmd --version`，8/8 通过。

- **位置**：[deepseek.cmd 第 150 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/deepseek.cmd#L150)，[install-command.cmd 第 8 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/install-command.cmd#L8)也使用类似内嵌路径模式。
- **证据**：将必要文件复制到临时 `launcher's copy`，调用 `deepseek.cmd --version`，实际退出 `1` 并产生 PowerShell ParserError。原因是 `%~dp0` 被直接插入 PowerShell 单引号代码字符串。
- **建议**：将复杂内联 PowerShell 移到文件，通过 `-File` 参数或受控环境值传路径。`!` 与 CMD 延迟扩展也是需要专门验证的边界，本次不把未复现的字符问题都列为已确认。
- **验收**：中文、空格、单引号、感叹号路径中的版本查询与安装注册；检查返回值，不仅匹配输出。注册脚本调用后也应立即传播 PowerShell 失败，不能继续无条件输出 Done。

### R9 · P1：DSH 升级缺少覆盖整个事务的互斥

> **实施状态（2026-09-05）：✅ 已修复。** 新增共享 `dsh-maintenance-lock.ps1`（按已解析 launch root 哈希的用户级命名互斥体，锁顺序固定：维护锁 → 启动锁 → 运行时互斥；install.ps1 内嵌同派生副本以支持 `irm|iex`）。`upgrade-dsh.ps1` 以维护锁覆盖“准备—停止—重启验证—提交—清理”整个事务；升级事务引入 `TransactionId`，读/清事务均验证归属（他人事务记录拒绝触碰），事务写入改为 `[IO.File]::Replace` 原子替换，消除短暂缺失窗口；恢复成功后同步活动指针到恢复版本（后续启动可复用恢复运行时）。测试：`upgrade-cache-behavior` 12/12（新增持锁方阻塞快速失败与锁释放后恢复、回退指针同步断言），`runtime-layout-behavior` 11/11（新增事务归属校验）。

- **位置**：[upgrade-dsh.ps1 第 54–77 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/upgrade-dsh.ps1#L54)、[dsh-runtime-layout.ps1 第 228–262 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/dsh-runtime-layout.ps1#L228)。
- **证据级别**：代码确认并发保护缺口；本次未执行两个真实升级，也未声称已经复现生产故障。
- **触发时序**：A、B 分别在不同候选目录准备；A 写 PREPARED，B 覆盖同一个事务文件；A 停止后再读事务时可读到 B 的候选与 token，而 A 本地仍持有自己的 candidate。后续启动、提交与清理可能交错。
- **原因**：`run-dsh.ps1` 的 mutex 按 RuntimeRoot 建立，两个候选目录不互斥；启动锁保护 runner 提交，不能包住“准备—停止—提交—清理”整个升级。事务写入还采用删除旧记录后 Move 的方式，存在短暂缺失窗口。
- **建议**：对同一安装/LaunchRoot 增加维护事务锁，固定加锁顺序；读写、清除事务均验证所属事务 ID，恢复过程中保留证据。与启动器自更新共用明确的维护冲突规则。
- **验收**：用暂停点替身确定性排列两个升级、升级与启动、升级与卸载的时序；断言不能停止另一事务的新服务、不能提交/删除别人的候选。

### R10 · P2：运行时串行化测试在当前环境连续两次失败

> **实施状态（2026-09-05）：✅ 已修复。** `tests/runtime-preparation-behavior.Tests.ps1` 的串行化场景改为信号屏障：以“首进程已把入口调用写入 node 日志（此刻它已持有运行时互斥）”作为启动第二个进程的屏障，等待上限 60 秒仅作超时保护；断言窗口内保持“恰有一行”不变，失败时保存两个子进程的退出码与 stdout/stderr 诊断。未删除串行化断言、未增加盲目 sleep。连续多次运行 11/11 通过。

- **位置**：[tests/runtime-preparation-behavior.Tests.ps1 第 258 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/tests/runtime-preparation-behavior.Tests.ps1#L258)、[第 335–363 行](https://github.com/RYun601/dsh-launcher/blob/9d1433a2e43b14fb87701527ed6b2bff27e77117/tests/runtime-preparation-behavior.Tests.ps1#L335)。
- **实际结果**：前五项通过，第六项 `serializes concurrent users of the shared runtime` 失败，`expected: 1, actual: 0`；未改源码独立重跑仍为同样结果。
- **分析**：测试只等首个进程最多约 3 秒，再启动第二个进程，300ms 后要求日志恰有一行；Node 替身把 2 秒延迟同时施加到 `--version`，并额外启动一个 PowerShell 执行 sleep。断言时两进程都未到达服务入口是可能的，零行本身不能证明运行时锁失效。
- **结论边界**：已确认当前回归不通过；尚未把该失败定位为产品互斥失效，不能用这个结果宣称“双进程同时执行”。
- **建议与验收**：使用“首进程已进入受保护执行区”的信号屏障，再启动第二个进程；固定时间仅用于超时保护。失败时保存子进程退出码、stdout/stderr 和阶段。不能单纯增加 sleep 或删除串行化断言。

## 4. 其他需要安排验证的事项

| 事项 | 当前依据与边界 | 下一步 |
| --- | --- | --- |
| `--check` 检查深度不足 | **✅ 已实施（2026-09-05）**：`--check` 接入 `dsh-doctor.ps1`，覆盖安装/Node/npm/活动运行时与指针/服务与端口/最近失败，问题以非零码退出 | README 的“环境诊断”描述已同步 |
| 插件自动移除与 `.dsh` 保护契约冲突 | 未实施（需要隔离上游实例确认配置落盘位置，本次未验证） | 保留原建议；在契约明确前不扩大配置修改能力 |
| 旧版回退与指针一致性 | **✅ 已实施（2026-09-05）**：升级回退成功后同步活动指针到恢复版本；`upgrade-cache-behavior` 断言“Current 已坏、legacy 恢复、指针同步” | 后续启动可复用恢复版本 |
| 下载完整性与临时文件生命周期 | **✅ 已实施（2026-09-05）**：覆盖安装与自更新均校验包内 VERSION、必需文件、PS 5.1 解析、BOM；自更新另校验 SHA-256 与包内 `release-files.txt` 清单 | 不把缺摘要等同于已发生供应链入侵 |
| 发布验收的可追溯性 | **✅ 已补充（2026-09-05）**：本次实施在下方第 8 节追加了完整 Windows 套件验收记录 | 保留 CI 快速检查边界 |

以上是需要验证或补齐的事项，与第 3 节的隔离复现问题分开跟踪。

## 5. 对历史评估的校正

| 2026-08-25 评估方向 | 本次基线状态 |
| --- | --- |
| 没有统一 Node 版本前置检查 | 已有 `dsh-node-version.ps1`，安装/运行时/升级共用；相关行为测试通过 |
| CLI 多动作混用与退出码 | 主要动作互斥与退出码传播已实现；路径嵌入和轻量自检仍有边角问题 |
| 端口监听就等于 READY | 健康模块已有进程身份、启动证据、HTTP 特征与稳定窗口；停止脚本仍未完全对齐身份判定 |
| 升级直接破坏唯一旧运行时 | 已有候选准备、Current/Previous 指针与失败回退；并发事务和回退持久性仍需收口 |
| 卸载完全没有备份和边界 | 已有备份流程与部分路径检查；回滚路径错误、恢复失败清理和快捷方式归属仍有问题 |
| 可以直接放开任意端口 | 当前生产启动入口已拒绝非 3080；多端口应视为后续完整设计，不是补一个参数 |
| 必须在 GitHub 重跑完整 Windows 套件 | 与当前 AGENTS 不一致；完整套件归本地同 commit 验收，GitHub 保留快速确定性检查 |

## 6. 值得添加的功能

以下均为建议，命令名尚未实现。工作量使用相对大小，避免在缺少实现验证时承诺工期。

| 顺序 | 功能 | 用户价值 | 最小范围与依赖 | 工作量 | 状态（2026-09-05） |
| --- | --- | --- | --- | --- | --- |
| 1 | 启动器自更新 | 不必反复下载安装脚本，明确区分两个产品的升级 | `--update-launcher` / `--upgrade-launcher`；包验证、维护互斥、备份恢复、源码目录拒绝；详见配套设计 | 中至大 | ✅ 已实施（`update-launcher.ps1`，12 项行为测试） |
| 2 | `--doctor` | 一次看清“为什么不能启动、当前运行哪个版本” | Node/npm/入口来源、Current、ready 标记、端口分类、最近失败阶段；默认不读配置或导出完整环境；先输出文本 | 中 | ✅ 已实施（`dsh-doctor.ps1`，`--check` 一并接入） |
| 3 | `--status --json` | 便于快捷方式、脚本及后续自动化稳定消费 | 在现有状态模型上提供版本化 schema、稳定字段、时间戳与退出码；不额外触发启动或浏览器 | 小至中 | ✅ 已实施（文本/JSON 共用同一决策产物） |
| 4 | `--logs --follow` 与轮转 | 启动排错更直接，限制长期日志增长 | 跟随、Ctrl+C 正常退出、日志不存在/轮转后的重连、大小上限和保留数 | 中 | ✅ 已实施（`dsh-logs.ps1` 头部指纹重连；runner 侧 5MB 轮转） |
| 5 | 显式运行时回滚 | 新版不兼容时用户能主动回到已验证版本 | 基于 Current/Previous，不直接移动 npm 目录；准备/健康验证后提交，失败保留现状 | 中 | ◐ 部分覆盖：升级失败自动回退已同步指针；用户主动 `--rollback` 未实施 |
| 6 | 安全重启与只打开页面 | 缩短常见“停止后重启”“服务已有但浏览器关了”的操作 | `--restart` 保留安全停止和真实退出码；`--open` 只打开已验证就绪的地址 | 小至中 | ✗ 未实施（后续任务） |
| 7 | workspace 配置 | 让 DSH 使用明确的项目上下文 | 先定义默认值与兼容迁移，再让前后台、重启与升级一致传递；不能只移除 `cd USERPROFILE` | 中至大 | ✗ 未实施（按第 1 节顺序应最后考虑） |
| 8 | 固定版本/通道与受管 CLI | 可控制升级节奏，减少受管与全局版本混淆 | 先统一版本来源；透传参数需独立于单动作白名单，避免把上游参数当启动器动作 | 中至大 | ◐ 版本来源已统一（R7）；通道与受管 CLI 未实施 |

不建议近期同时加入多实例、托盘 UI、自动 watchdog、任务计划自启动和远程暴露。它们会扩大配置、身份与停止边界。先让现有单实例可靠，再以明确需求推进；尤其不应通过简单修改 host/port 把本地 Web 暴露出去。

`--doctor` 第一版也不应自动打包原始日志：其中可能含带 token 的启动 URL 或插件输出。若后续提供诊断包，应明确脱敏字段，排除 `.dsh`、完整环境变量与未经处理的日志正文。

## 7. 实施阶段与验收要求

| 阶段 | 交付 | 验收要点 |
| --- | --- | --- |
| A：安全验收基线（✅ 已实施 2026-09-05） | R4 测试隔离、R3/R6 卸载恢复与归属、R1 停止识别、R2 路径边界 | 合成外部目录、同名快捷方式、历史备份与陌生进程均保持不变；完整测试能安全运行。验收：stop 13/13、runtime-layout 11/11、runtime-preparation 11/11、uninstall 14/14 通过 |
| B：维护事务（✅ 已实施 2026-09-05） | R5 安装恢复、R9 升级互斥、恢复证据与锁顺序 | 各关键步骤失败/中断均可解释并恢复；两个维护动作不相互覆盖。验收：install 11/11、upgrade-cache 12/12、runtime-layout 11/11 通过 |
| C：自更新（✅ 已实施 2026-09-05） | 配套设计的两个命令、发布包验证和迁移说明 | CMD 自覆盖、路径特殊字符、无网络、版本倒退、运行中实例、恢复失败全部覆盖。验收：launcher-update 12/12（含 CLI 端到端自覆盖、失败恢复、退出码 0/1/2）、startup 40/40（含新动作分派与冲突拒绝）、release-package 通过（清单自包含 + SHA-256 副资产） |
| D：可诊断性（✅ 已实施 2026-09-05） | R7/R8、doctor、JSON 状态与日志跟随 | 显示实际活动版本，诊断结果可自动消费且不包含凭据（状态 JSON 不含启动令牌）。验收：update-check 6/6、version-resolution 8/8、launch-state 32/32（含 JSON 专项）、logs 3/3、startup 40/40 |
| E：可选增强（◐ 部分实施，见第 6 节状态列） | 显式回滚、workspace 与受管 CLI | 全生命周期配置一致；不把上游每个功能都重复实现成启动器参数。升级失败自动回退与指针同步已随 R9 落地；用户主动回滚、workspace 配置、固定通道与受管 CLI 留待后续独立任务 |

实施任何行为变化时，先补能复现目标行为的测试，再做最小修复；同步中英文 README，新增发行文件同步 `release-files.txt`。不需要仓库级 `npm install`，测试继续使用 Windows PowerShell 5.1 和自包含夹具。

## 8. 本次验证记录

验证引擎为 Windows PowerShell `5.1.19041.7663`；编排工具的默认 shell 为 PowerShell 7.6.5，两者没有混作生产兼容性证据。

- 发行清单中的 **17 个 PowerShell 脚本**均通过 Windows PowerShell 5.1 解析。
- `install.ps1` 无 UTF-8 BOM。
- **12 个完整行为套件、合计 130 项场景通过**，逐套件统计见下表。失败的运行时准备套件另有前 5 项通过，不计入这 130 项。
- 运行时准备套件连续两次在串行化场景失败，见 R10；后续测试继续独立执行，不降低断言。
- 原始安装、卸载及发行包安装烟雾未直接运行：R4 的真实桌面/TEMP 隔离问题使本机运行不满足 AGENTS 的测试边界。对应流程通过本次独立隔离复现检查，不计作原套件通过。
- 这不是完整 Windows 验收通过记录，也不是创建发布标签的依据。

| 行为测试文件 | 本次结果 |
| --- | --- |
| `launch-state-behavior.Tests.ps1` | 31 项通过 |
| `node-version-behavior.Tests.ps1` | 3 项通过 |
| `open-when-ready-behavior.Tests.ps1` | 3 项通过 |
| `runtime-layout-behavior.Tests.ps1` | 6 项通过 |
| `runtime-preparation-behavior.Tests.ps1` | 前 5 项通过，第 6 项失败；原文件重跑同样失败 |
| `service-health-behavior.Tests.ps1` | 16 项通过 |
| `shortcut-behavior.Tests.ps1` | 3 项通过 |
| `startup-behavior.Tests.ps1` | 39 项通过 |
| `stop-behavior.Tests.ps1` | 7 项通过 |
| `update-check-behavior.Tests.ps1` | 1 项通过 |
| `upgrade-cache-behavior.Tests.ps1` | 11 项通过 |
| `version-ordering-behavior.Tests.ps1` | 3 项通过 |
| `version-resolution-behavior.Tests.ps1` | 7 项通过 |
| `install-behavior.Tests.ps1` | 原套件未运行，桌面接口未完全隔离 |
| `uninstall-behavior.Tests.ps1` | 原套件未运行，见 R4 |
| `release-package-behavior.Tests.ps1` | 原套件未运行，其中包含未完全隔离桌面的安装烟雾 |

上述统计来自本次实际输出，不使用历史评估的统计替代。专项复现结果如下：

| 复现 | 实际观察 |
| --- | --- |
| 卸载失败回滚 | 退出 1；日志与安装恢复，快捷方式丢失，备份数 0 |
| 无关同名快捷方式 | 完整卸载退出 0，无关哨兵快捷方式被删除 |
| 安装文件锁 | 退出 1；先复制的文件为 new，被锁文件仍为 old |
| 当前版本指针 | Current 为 0.2.0，`--version` 和更新检查仍显示 unknown |
| 单引号安装目录 | `--version` 退出 1，ParserError |
| 无关进程参数 | 原停止身份函数对无关 Node 命令行返回 ALIVE；未执行终止 |
| junction 运行时 | 指向受管树之外的准备好夹具，`-PrepareOnly` 仍退出 0 |
| 桌面路径隔离 | 修改 USERPROFILE 后 GetFolderPath('Desktop') 仍为原真实桌面 |

交付文件为本报告和配套自更新设计；`.gitignore` 仅为这两个文件增加例外。功能脚本、测试源码、双语 README、发行清单与 VERSION 均未修改；历史评估保留。文档检查包含相互链接、基线代码定位、测试计数与 `git diff --check`，未把日志、测试临时目录或发行物加入变更。

本次不修复上述问题。应把文档中的优先级和验收场景拆成后续实施任务，完成针对同一代码版本的验证后再更新“已修复”状态。

## 9. 实施验收记录（2026-09-05）

按本文档第 1 节的建议顺序完成了阶段 A–D 的实施；阶段 E 按第 6 节状态列保留后续任务。以下为本机验收记录，替代“仅凭 GitHub 绿灯发布”的可追溯性要求。

- 引擎：Windows PowerShell `5.1.19041`（全部测试与被测脚本）；编排 shell 为 Git Bash。
- **完整 Windows 行为套件：18 个套件全部通过**（基线 16 套 + 新增 `launcher-update-behavior`、`logs-behavior`），合计约 190 项场景。
- 逐套件：launch-state 32、open-when-ready 3、node-version 3、runtime-layout 11、runtime-preparation 11、service-health 16、shortcut 3、startup 40、stop 13、uninstall 14、update-check 6、upgrade-cache 12、version-ordering 3、version-resolution 8、install 11、release-package 通过、launcher-update 12、logs 3。
- 新增发行文件：`update-launcher.ps1`、`dsh-doctor.ps1`、`dsh-logs.ps1`、`dsh-maintenance-lock.ps1`、`version-info.ps1`、`register-path.ps1`；`release-files.txt` 纳入自身以支持自更新包清单校验；`release.yml` 额外产出 `dsh-launcher.zip.sha256`。
- 完成前检查：23 个发行 PowerShell 脚本通过 PS 5.1 解析；`install.ps1` 无 UTF-8 BOM 且保持 ASCII 源码；`git diff --check` 无空白错误；中英文 README 与 AGENTS.md 已同步。
- 实施过程中的两条工程约束（已写入 AGENTS.md 不变量 14）：无 BOM 脚本内的注释/字符串必须 ASCII（GBK 解码会吞换行）；测试夹具重写带 BOM 脚本时必须保留 BOM。
- 本次未创建发布标签、未修改 `VERSION`；发布前仍需在待发布 commit 上重跑完整套件。

### 9.1 对照核查与补齐（2026-09-05 第二轮）

将本文档与配套自更新设计逐条对照实现后，发现并修复了三处偏差：

- **完整卸载补上维护互斥**：此前 AGENTS 不变量 11 与设计 §7 均承诺“卸载入口参与维护互斥”，但 `uninstall.ps1` 实际未持锁。现已在完整卸载事务外持有共享维护锁（锁释放覆盖全部退出路径），新增“持锁方阻塞卸载”测试。
- **自更新保留原 InstallationId**：设计 §4 要求“保留原 InstallationId 和最终安装路径”，实现曾重新生成 ID。现已改为保留，并在 CLI 端到端测试中断言 ID 跨更新不变。
- **自更新拒绝安装目录中的无关文件**：设计 §4 要求“发现无关文件、未知目录时在变更前拒绝”，此前缺失（无关文件会随旧安装备份一起被删除）。现在更新前将安装目录文件集合与包内清单核对（所有权标记白名单），发现清单之外的文件即拒绝并列出，测试覆盖。

同时补齐了以下验收缺口：R2 的“junction 指向合成 `.dsh`”用例、R5 的 copy 阶段注入用例、设计 §8 的“更新与 DSH 升级事务互斥”“安装目录位于 `.dsh` 边界内拒绝”用例、R8 的“安装注册在特殊字符路径下可用”用例（`register-path.ps1` 新增文件存储测试钩子）、真实生成 `dist/dsh-launcher.zip` 后的解压烟雾验证（按 AGENTS 发行包验证要求）。

核查后全量状态：**18 个套件、约 216 项场景全部通过**（uninstall 15、launcher-update 15、install 12、runtime-layout 12 为补齐后计数）；真实发行包解压烟雾通过；23 个发行脚本解析零错误；`install.ps1` 无 BOM；`git diff --check` 干净。

核查中确认仍与文档存在差距、接受并记录的项（不阻塞本轮）：自更新网络故障仅覆盖“缺摘要/错摘要/包内版本不符”，超时/限流/404/下载中断未逐一测试（错误分类代码存在但无专项用例）；ZIP 重名条目与盘符/流路径条目未构造专项用例（校验代码已实现）；`install-command.cmd` 的 CMD 粘合层未直接测试（其逻辑在 `register-path.ps1` 中已覆盖）；卸载“恢复时文件被锁”用注入模拟而非真实文件锁；安装器不识别遗留的自更新事务目录（设计 §6 提及，属低风险增强项）。
