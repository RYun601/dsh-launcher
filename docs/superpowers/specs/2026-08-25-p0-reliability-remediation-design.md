# dsh-launcher P0 可靠性修复设计

日期：2026-08-25

## 背景与目标

本设计补齐 `docs/dsh-launcher-comprehensive-assessment-2026-08-25.md` 中五个 P0 方向的完整验收要求：Node.js 前置检查、CLI 参数与退出码、服务身份与健康、卸载安全边界、升级原子性与回滚。

修复必须保持 Windows PowerShell 5.1 兼容，不访问或修改 `%USERPROFILE%\.dsh`，不把正常 stderr 当成失败，不破坏现有启动锁和浏览器唯一所有者约束。生命周期测试只使用隔离 profile、替身进程和非 3080 测试端口，不作用于真实 DSH 实例。

## 非目标

- 不增加 workspace 或可配置端口等 P1 功能。
- 不改变 DSH 用户配置、凭据或 `%USERPROFILE%\.dsh` 的结构。
- 不引入 Node.js 开发依赖或 PowerShell 模块依赖。
- 不把全局 `dsh` CLI 变成活动运行时的权威来源。

## 方案选择

升级运行时采用“版本化目录 + JSON 指针”，不采用 NTFS junction，也不继续使用活动目录改名交换。

NTFS junction 的替换、权限和不同 Windows 环境行为更难稳定验证；活动目录改名交换则存在当前路径暂时缺失和进程中断后半安装的问题。JSON 指针可由 PowerShell 5.1 原生文件 API实现，可验证、可恢复，并且无需管理员权限。

## 运行时目录与原子指针

新增共享实现 `dsh-runtime-layout.ps1`，集中管理以下路径：

```text
%USERPROFILE%\dsh-launch\
  runtime\                         # 旧式运行时；兼容迁移期间可以继续被指针引用
  runtime-versions\
    <version>-<generation>\        # 不可变的候选或已验证运行时
  runtime-current.json             # 当前与上一运行时指针
  runtime-upgrade.json             # 在途升级事务
```

`runtime-current.json` 使用 schema 1，至少包含：

- `Current.Path`、`Current.Version`
- `Previous.Path`、`Previous.Version`（可为空）
- `UpdatedAt`

所有路径以 `dsh-launch` 为边界解析为规范绝对路径；指针只保存相对路径。拒绝绝对路径、父目录跳转、reparse 后越界路径以及任何指向 `%USERPROFILE%\.dsh` 的路径。

指针写入使用同目录临时文件。已有指针时通过 `[IO.File]::Replace()` 替换；首次创建时通过同目录 `[IO.File]::Move()` 提交。临时文件完整写入并关闭后才能切换。

首次遇到有效的旧式 `runtime` 时，不移动正在使用的目录，而是把它登记为 `Current`。这完成逻辑迁移且没有活动路径缺失窗口。后续成功升级后，旧式目录可以作为 `Previous` 保留；再下一次成功升级时才按保留策略清理。

正常启动只解析指针的 `Current`。若尚无指针，则兼容检查旧式 `runtime`；本地无可用运行时才进行版本发现或首次准备。

## 候选准备、健康切换与回滚

`run-dsh.ps1` 增加只准备不启动的受测入口，并继续允许显式 `RuntimeRoot`：

1. 候选版本安装到 `runtime-versions\<version>-<guid>`。
2. 在候选目录内完成入口验证、必需 peer 修复、`npm ls --all` 审计和 ready 标记写入。
3. 候选准备失败只清理该候选；活动指针和旧运行时不变。
4. 候选准备成功后写入 `runtime-upgrade.json`，记录旧选择、候选选择、启动令牌和阶段。
5. 可靠停止当前服务；停止失败则中止，指针不变。
6. 使用候选目录显式启动后台 runner，并执行服务身份、页面特征及稳定窗口检查。
7. 候选通过健康检查后原子提交指针：原 `Current` 成为 `Previous`，候选成为 `Current`。
8. 指针提交成功后再同步可选的全局 `dsh` CLI，并清理不属于 `Current`、`Previous` 或活动事务的更早受管目录。

候选健康检查失败时停止候选进程，保持旧指针，并显式从旧 `Current` 重新启动。旧版重启的成功或失败必须成为升级命令的最终结果和诊断信息，不能把候选失败掩盖为成功。

在途事务恢复遵循“指针是提交事实”的原则：

- 指针仍指向旧版：候选从未提交；停止与事务令牌匹配的残留候选，保留或清理候选后继续使用旧版。
- 指针已经指向候选：提交已完成；恢复 `Previous` 保留与旧目录清理阶段。
- 无法验证的事务或路径一律不删除目录，输出明确诊断并失败。

成功升级后始终保留当前版和最近一个上一版。更早版本只有在边界、ready 标记、指针引用和活动事务均验证后才可删除。

## 共享服务身份与健康协议

新增 `dsh-service-health.ps1`，由以下入口共同使用：

- 前台启动端口预检
- `start-background.ps1`
- `open-when-ready.ps1`
- `dsh-launch-state.ps1 --status`
- `stop-dsh.ps1`
- 升级候选健康检查

启动状态 schema 增加：

- `StartupToken`
- `RunnerPid`
- `ServicePid`
- `RuntimeRoot`
- `Entrypoint`
- `State`：`STARTING`、`READY`、`UNHEALTHY`、`FAILED` 或 `STOPPED`

对外端口状态为 `STARTING`、`READY`、`UNHEALTHY`、`FOREIGN_PORT`、`FAILED` 或 `STOPPED`。读取旧状态时兼容 `RUNNING`，但新写入不再产生 `RUNNING`。

一个监听者只有同时满足以下条件才可认定为受管 DSH：

1. 端口监听 PID 可读取且进程仍存活。
2. 启动中的锁令牌与状态 `StartupToken` 一致。
3. 命令行是 Node 启动，并且解析出的入口绝对路径与状态记录或当前受管运行时的 `lib\bin.js` 完全一致；原始字符串包含 `dsh`、注释标记或进程名相同都不够。
4. HTTP 状态为 2xx/3xx，响应是有界 HTML，正文包含 DSH Web 根节点 `id="root"`。
5. 初次就绪时，同一 PID 连续满足上述条件至少 5 秒，且 runner 在此期间未退出。

已记录为 `READY` 的同一 `ServicePid`、token 和入口路径在普通 `--status` 中只需一次有界健康探测，避免每次状态查询阻塞 5 秒。状态身份发生变化时重新进入稳定窗口。

`open-when-ready.ps1` 只有在共享探测返回 `READY` 后才能写状态并打开浏览器。前台入口也必须使用同一探测；任意 3080 监听不再被当作已有 DSH。

上游当前没有正式 readiness 端点。首页 `id="root"` 与 5 秒稳定窗口是当前兼容策略；实现将把响应特征集中在共享模块，以便上游增加正式端点后单点替换。

## 启动锁身份

启动锁除 PID 和 token 外增加规范化的 `CommandPath`、`ScriptPath` 和创建时间。锁存活判断必须同时满足：

- PID 存活；
- token 与调用方预期一致（转移或释放时）；
- 命令行包含完全匹配的 `start-background.ps1`、`background-run.ps1` 或前台协调脚本路径。

只有旧 schema 锁才允许受限兼容：进程名匹配不足以长期保留锁；无法证明身份的旧锁按陈旧锁处理，但不终止对应进程。

## 前台与后台启动

前台复杂协调逻辑从 `deepseek.cmd` 移到 PowerShell 脚本，以便复用状态、token 和健康模块。CMD 继续负责参数校验、动作分派和退出码传播。

前台和后台都在启动前确定 `RuntimeRoot` 与 `Entrypoint`，写入同一状态 schema。每次启动只有 runner 或前台就绪监视器拥有一次浏览器打开权。附着到已有启动时沿用原启动 token，不提交第二个 runner，也不打开第二次浏览器。

## CLI 参数与退出码

`deepseek.cmd` 把动作与修饰符分开：

- 动作仍是 foreground、background、stop、status、logs、upgrade、update、version、uninstall、help、check。
- `--full` 只修饰 uninstall，最终必须调用 `uninstall.ps1 -Full`。
- 数字只允许作为 `--logs` 后唯一的行数参数；裸数字、重复数字、错误位置和多余 token 都返回 1。
- 同一动作的别名可以重复解析为同一动作；不同动作组合失败。
- PowerShell 调用后立即保存 `%ERRORLEVEL%`，后续输出不得覆盖。

测试必须记录完整 PowerShell 参数，不能只断言脚本名。

## Node.js 检查与安装器兼容

`dsh-node-version.ps1` 继续作为安装、启动和升级的唯一检查实现。测试覆盖：

- Node 缺失：输出 `当前版本：未检测到`、要求范围和升级方式。
- Node 低于要求：输出实际版本、要求范围和升级方式。
- Node 恰好为最低版本：成功。

`install.ps1` 必须保持 UTF-8 无 BOM，同时整个源码保持 ASCII 安全，使 Windows PowerShell 5.1 在任意活动代码页下可解析。中文用户提示通过 ASCII 形式的 Unicode 转义在运行时构造，源码中不放会被 DBCS 代码页吞并字符串定界符的非 ASCII 字节。

归档内容使用 `Get-ChildItem -LiteralPath $payloadRoot -Force` 后逐项 `Copy-Item -LiteralPath`，不把 `*` 传给 `-LiteralPath`。

安装目标先规范化并验证：

- 位于规范化 `%USERPROFILE%` 内但不等于 profile 根目录；
- 不位于 `%USERPROFILE%\.dsh` 内；
- 不等于或位于 `dsh-launch` 运行数据目录内；
- 不为驱动器根目录。

安装成功后写 `.dsh-launcher-owner.json`，包含 schema、规范安装路径和随机 installation id，不含环境变量、配置或凭据。该标记由安装器生成，不加入发行包清单。

## 卸载事务与安全边界

普通卸载只注销 PATH。完整卸载按以下事务执行：

1. 显示计划并确认；取消时不修改 PATH。
2. 规范化并验证 `%USERPROFILE%\dsh-launch`、安装目录、快捷方式和备份根。
3. 安装目录必须位于 profile 边界内，且 `.dsh-launcher-owner.json` 的路径与当前脚本目录完全一致。
4. 显式拒绝任何等于或位于 `%USERPROFILE%\.dsh` 的目标。
5. `stop-dsh.ps1` 缺失、返回非零或等待后仍有受管 PID、端口或锁时中止。
6. 将快捷方式、运行数据和安装目录移到 profile 内唯一备份根；任一搬移失败则把已搬移项目恢复。
7. 全部搬移成功后再移除 PATH；PATH 更新失败则恢复目录与原 PATH。
8. 最后删除备份。删除失败不伪装成数据丢失：保留剩余备份并输出精确位置。

`stop-dsh.ps1` 必须检查 `taskkill.exe` 的退出码，并以条件等待确认进程、端口和锁均消失；超时返回非零。陌生端口占用者只报告，不终止。

卸载测试只跟踪并清理测试自身创建的备份路径，禁止枚举删除真实 `%TEMP%` 或 profile 下所有同名前缀目录。

## 测试策略

实现严格按失败测试先行：

1. 安装器：Windows PowerShell 5.1 解析、无 BOM、ASCII 源码、真实归档复制、路径边界和所有权标记。
2. Node：缺失、过低、最低版本，并验证安装、启动、升级共享同一函数。
3. CLI：动作矩阵、冲突、未知参数、完整 `-Full`、数字位置和各路径退出码。
4. 健康：外来端口、伪造命令行子串、错误入口、HTTP 500、无根节点页面、稳定窗口退出、真实标记稳定就绪。
5. 状态与锁：token、命令行、入口路径、PID 转移、旧 schema 兼容和五个 P0 状态。
6. 停止与卸载：taskkill 失败、等待超时、陌生进程、缺失停止脚本、边界外路径、标记不匹配、目录与 PATH 回滚。
7. 升级：目标解析失败、候选 npm 安装失败、候选健康失败并重启旧版、成功原子切换、保留上一版、异常事务恢复。

完成前运行：

- 每个改动方向最接近的行为测试；
- Windows PowerShell 5.1 对 `release-files.txt` 全部 PowerShell 文件的解析；
- 完整 `tests\*.Tests.ps1` 套件；
- 发行包组装测试与生成归档后的解压烟雾测试；
- `install.ps1` UTF-8 无 BOM和 ASCII 源码检查；
- `git diff --check` 与工作区内容检查。

## 文档与发行同步

新增的共享运行时布局、服务健康或前台协调脚本必须加入 `release-files.txt` 和发行包行为测试。用户可见的状态、安装路径约束、完整卸载事务、运行时保留策略和升级回滚行为同步更新 `README.md` 与 `README.en.md`。

本修复不修改 `VERSION`；只有后续明确准备发布时才更新版本号。
