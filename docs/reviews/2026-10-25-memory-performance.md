# 2026-10-25 内存与性能修复验证

## 范围与复现条件

原审查基于 `ed1ac19c28bc83c79e5c8bcce4644528ac880520`。所有改动在独立 worktree 的 `fix/memory-performance-review` 分支完成，原工作目录及未提交重构保留。测试使用专用 SSH 容器和 UUID 临时文件，没有连接用户保存的主机执行测试命令。

手机为 iPhone 16 Pro / iOS 26.6.2，Xcode 26.4。内存探针使用 `Debug + -O`、生产实现和显式 opt-in 的诊断入口；诊断使用独立本地存储，跳过用户共享收件箱。Release 不包含这些探针。手机的当前测试路径使用 Tailnet SSH/TCP；视频 UDP 没有贯通测试容器的动态端口，因此没有声称本次真机验证覆盖桌面 UDP。

## 已完成的真机测量

| 场景 | 审查基线 | 修复候选结果 | 证据范围 |
|---|---|---|---|
| 10 次创建/丢弃 DesktopGestureView | 10 个残留，普通 UIView 对照 0 | 0 残留；额外 10 次 attach/dismantle/reattach 也为 0 | `1599019`，build 2026102501，弱引用与 run loop 等待 |
| 128 MiB 真实 SFTP 上传 | footprint 71 → 192 → 68 MiB | 71 MiB 起始/峰值，16～128 MiB 进度采样均 64 MiB，完成 64 MiB | `1599019`，build 2026102501；未开 Instruments；当前网络约 62.55 秒，不与不同路径的基线比较吞吐 |
| 真实桌面视频 | 原审查未做端到端视频 | 1280×800 实际显示像素，15 秒 decoded 计数 +410；footprint 61 → 23 MiB | `da458fd` + 后续提交的 Debug 探针，build 2026102500 |
| 暂停后强制断开本测试 SSH 并恢复 | 核心实验丢失暂停状态并接收音频 | 暂停前后 decoded frame count 423 → 423，2 次登录，恢复显示后 +11 帧 | 同上；本次真实视频禁用音频，音频隐藏行为由核心测试覆盖 |
| Time Profiler | — | 46.08 秒记录，823 个 1ms 加权 CPU 样本；>250ms 的 potential-hangs 表 0 行 | 包含 15 秒视频及后续空闲；不能推导全部用户路径无卡顿/泄漏 |

原始 traces、屏幕像素 PNG、JSON、完整构建日志在本地 `review-artifacts/`，没有提交私有测试凭据、设备容器内容或 Instruments 二进制文件。短时采样只验证上述具体场景；没有将 Leaks 导出表为空、view census 为零或 enqueue 回调等同于“整个 App 无泄漏”或实际屏幕呈现时点。

传输竞态修订后的 `918a0f3` / build 2026102502 在同一手机完成 **18/18** 功能诊断：真实认证、PTY 输入与 resize、SFTP 二进制往返/取消清理/连接复用、8 个独立 tmux 会话与重新附着、mosh UDP、agent hooks、隔离事务的 Keychain 分享往返及应用页面快照。开始 02:12:17Z，结束 02:12:30Z。这是 app 内功能诊断，不冒充 XCTest UI 自动化。

终端补丁的 iPhone build 2026102503（`4950779` + 随后提交的提取基准）通过全部弱引用/字节等价/上传检查：reset 后 Terminal 模型 **0/10** 残留（原基线 **10/10**），普通对照 **0/10**。16 KiB 内容逐字节一致；20 次提取的中位数由 **2.249 ms** 降至 **0.305 ms**，总耗时 **46.500 ms → 6.119 ms**。同一轮上传 128 MiB 的 footprint 起始/采样最高 **30 MiB**，16～128 MiB 进度采样与完成均 **22 MiB**（每 16 MiB 采样，不把采样最大值当作高频测得的绝对瞬态峰值）。

全部五组修复合入候选 `501ab74` 后，build **2026102505** 再次在同一手机验证：

- 功能诊断 **18/18**，02:51:13Z～02:51:27Z，包含真实 Keychain 分享事务往返。
- 内存探针开始 02:52:44Z，最终 `status=finished`；桌面手势层普通/重新挂载均 **10 次创建 / 0 残留**，终端普通/reset 的 view、runtime、模型也均 **0/10**。
- 16 KiB 尾部字节完全一致；20 次提取中位数 **2.180 ms → 0.293 ms**。128 MiB 上传起始/采样最高 **29 MiB**，每 16 MiB 进度采样和完成均 **22 MiB**，约 68 秒，UUID 远端临时文件已删除。
- 真实桌面 02:55:02Z～02:55:21Z：取得并查看 **1280×800** 实际显示像素；15 秒 decoded 计数 **+428**，footprint **61 → 22 MiB**；暂停期间强制断开本测试 SSH 后恢复，计数 **441 → 441**，两次登录，恢复显示后 **+13**。仍为 TCP，UDP inactive。

此候选的 Debug 探针编译使用 `-O`。后续交付采用 Release 配置；诊断入口由 `#if DEBUG` 排除。最终 PR 可能另外包含测试/文档/工程整合提交，以下本地证据按实际候选标识保留，不能把某次候选测量冒充之后修改代码的新测量。

最终回调收尾提交 `81c73bc` 已重新编译/安装优化 Debug **2026102510** 并完成相同真机桌面实验（03:20:07Z～03:20:26Z）：实际显示 buffer 与查看过的 **1280×800** PNG 均有效；15 秒 decoded **+432**，footprint **63 → 23 MiB**；暂停重连期间 **444 → 444**、2 次登录，恢复显示后 **+10**，最终 `status=finished / passed=true`，仍使用 TCP。该轮专门覆盖新增 completion overload 与真实 iOS enqueue 的集成；未重复未修改的终端/上传探针。

## 回归入口

最终完整真实 SSH 回归在 `81c73bc` 上执行：**383 项，14 项跳过，0 失败，58.558 秒**。原生 WINDOW_ADJUST 与 pending read（7/65,536 bytes）清理后均为 **0 blocks / 0 bytes**；64 MiB 上传本轮 RSS 增量 **163,840 bytes**。跳过的是没有提供对应环境的专用测试，没有把它们计为通过。最终日志为 `final-wave-live-suite.log`。早先 `f47cd1e` 的 382 项/14 跳过/0 失败记录仍保留为历史候选证据。

图片池的 7 项生产逻辑测试覆盖总预算、真实解码成本、多个消费者/共享句柄释放、取消后的非协作解码、同 key 替换串行与其他 key 的独立推进、错误回收和完成后闭包引用释放。

在独立 iPhone 17 模拟器上运行的生产 UI 回归：

| 用例 | 结果 | 覆盖 |
|---|---|---|
| `FilesUITests.testTextMarkdownAndImagePreviewControls` | 通过，153.352 秒 | 相对路径 PNG 实际渲染、网页图片保持显式链接、代码/Markdown 切换、图片全屏 |
| `PreviewSettingsUITests.testSearchFullscreenAndIndependentPreviewPreferencesPersistAcrossRelaunch` | 通过，302.723 秒 | 搜索、Markdown 全屏/退出、重启后预览设置保留且不改变终端设置 |
| `RoamttyUITests.testShareExtensionQueuesDownloadedFile` | 通过，96.054 秒 | 系统分享扩展接收真实下载文件、唤醒后选择主机并上传完成 |
| `FilesUITests.testSharedUploadRejectsCollisionAndUsesChosenDirectory` | 通过，249.687 秒 | 同名目标拒绝、错误目录拒绝、选择目录、上传、确认持久化、远端内容校验 |

测试维护保留了两次实际失败记录：预览长场景原测试在 `closeTerminal()` 已返回主页后多点一次导航返回；失败 AX 树与基线 `AppModel.leaveTerminal()` 均确认页面已在主页，移除多余点击后完整重跑通过。分享上传原用例在创建初始测试文件、收起输入编辑器之后，尚未进入文件浏览或分享流程，就遇到 XCTest 反复等待 60 秒的动画完成通知，超过终端按钮 5 秒显示时间；当时 3 秒线程采样的主线程均处于 run loop 空闲，CPU 约 0.2%，未证明应用阻塞。完整重跑通过，但尚未确认间歇性动画等待的根因。新增收尾步骤是在上传后重启，确认 receipt 不再出现，再保留原始文件/上传文件逐字节比较与清理；这是持久化覆盖，不是已证实的超时修复。此用例不再证明同一进程经历系统分享之后的终端浮动按钮交互。

图片管线只保证 **32 MiB 解码输出与预留**、**最多 2 个 fetch/decode**。它不会保留空闲 decoded cache，最后一个可见消费者离开即清空共享句柄及 UIImageView 引用。编码输入、ImageIO 的缩略图/内部工作区和一次显示提交仍有额外成本；本次没有将该预算称作总 RSS 上限，也未进行多图页面的真机 jetsam 压力测试。

- `swift test`：核心、DesktopCore、Transport 测试。未提供现场服务变量时，真实 SSH 用例会明确跳过。
- `scripts/test-desktop-sample-ownership.sh`：直接使用生产 `DesktopSampleBuffer` helper 的 CoreMedia ASan 所有权检查。
- `scripts/test-terminal-url.sh`：终端模型、历史文本及既有 URL/宽字符/滚动行为检查。
- `swiftc App/Shared/ShareInboxStore.swift scripts/test-share-inbox.swift -o <临时二进制> && <临时二进制>`：分享收件箱事务、路径别名和取消验证。
- `swiftc App/Shared/ShareInboxStore.swift App/Shared/ShareInboxWorker.swift App/Roamtty/Services/SharedInbox.swift scripts/test-share-worker.swift -o <临时二进制> && <临时二进制>`：生产 worker/facade 的六组检查：后台执行、consume/ack 交错与顺序发布、scope/取消/失败清理、共享目录恢复、确认失败重试、同时打开去重与独立观察者取消。
- `scripts/run-memory-validation.py <device-udid> <私有fixture.json>`：安装本提交 Debug 构建后运行生命周期和真实上传；检查 `Documents/MemoryValidation/report.json` 的 `status=finished` 及每个 passed 字段。
- 上一命令加 `--desktop`：对配置好的真实桌面测试主机运行视频、暂停/恢复、像素和内存检查；结果在 `Documents/DesktopMemoryValidation/`。

必须使用显式、可丢弃的测试主机；JSON 只通过子进程环境传入，没有放进命令行/源码/PR。诊断结果必须取到新的本地目录并核对 build、startedAt、status，避免误读上次结果。

Scope harness 使用可控的系统权限钩子来确认原始 URL 与 start/stop 平衡；它不能证明每个真实 iCloud/第三方 provider 的权限授予行为。iPhone Keychain 实测验证了签名权限下的分享存储事务，UI 分享扩展用例另行覆盖完整用户流程。这些证据的范围分别保留。

## 正式插件 pin 校验

实际下载并解压官方 v0.9.1 linux-x86_64 文件，得到 1,860,656 bytes，SHA-256 `0acd56cb2e5053f769e2a9c2adb4052053ff4c81c25dbb6153d395b3a41c1508`，与 bundled manifest 一致。旧测试的两个预期值过期，本次按实际文件校正，没有更改插件下载目标。

## 依赖与复核

SwiftTerm 基于 v1.13.0 / `8e7a1e154f470e19c709a00a8768df348ba5fc43`，现改用用户账号下的 [yahaa/SwiftTerm fork](https://github.com/yahaa/SwiftTerm)，App 与终端 harness 都锁定完整提交 `0a311223749cf1b96294772a2c5478be67915572`。移除 App 仓库中的 `ThirdParty/SwiftTerm` 源码副本，保留 MIT 许可及[补丁来源说明](../dependencies/swiftterm.md)。fork 保留上游 package 和仓库结构，唯一源码差异是 `Terminal.swift` 的 reset 弱捕获与有界尾部接口（+26/-1）；迁移前逐一确认 73 个源码/许可文件与此前审查版本字节一致，其中 72 个与上游一致。

迁移验证：Xcode 与 SwiftPM 均从 fork 拉取并解析到上述完整提交，两个实际 checkout 均干净；终端回归重新执行 **783 项全部通过**（URL 518、宽字符 17、滚动 33、内存 215），工程重生成无额外变化，iPhone 优化 Debug **2026102512** 构建通过。此构建在同一手机复测普通/reset 后终端模型、runtime 与视图均 **0/10** 残留，16 KiB 尾部逐字节等价，20 次提取中位数 **2.164 ms → 0.289 ms**。仅迁移依赖来源，没有再次改动 App、核心业务或测试用例实现；此前其他完整回归的候选标识和覆盖边界保持上文所述。

完整分支独立复核在 `cb78903` 结束时没有 Critical/Important，指出两项非阻断 Minor。本次一并处理，并在 `81c73bc` 完成唯一一轮定向复核，两个发现均 ADDRESSED，无新增问题：

- 图片池测试不再用 30 次 `Task.yield()` 猜测调度完成；等待实际 loader 进入、consumer 发布或资源 discard，并用有超时的期待与明确失败替代强制解包。
- 视频提交携带绑定 frame/generation 的完成闭包；reset 后复用帧号时，旧完成事件不能消耗新帧的统计记录。iOS 仍在成功 `layer.enqueue` 后同步完成，未改变显示 executor/readiness 协议。旧 `didRender` 接口保留同步调用兼容性，延迟报告者须使用新的绑定闭包。移除 generation guard 的故障注入使回归在错误延迟统计处失败，恢复后通过。
- 收尾的 DesktopCore 与图片池定向套件：148 项，5 项明确依赖外部环境而跳过，0 失败；随后上述完整真实 SSH 套件也通过。

最终交付使用 Release 配置的开发签名 IPA；版本、提交、签名检查、实际手机安装/正常启动及 OTA 三方 SHA-256 校验以对应 PR 的交付记录为准。此前候选 Release 2026102509 已在连接的 iPhone 安装并正常启动；不将安装/启动本身代替完整用户流程验证。
