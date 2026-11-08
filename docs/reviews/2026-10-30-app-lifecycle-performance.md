# 2026-10-30 App 生命周期性能与内存验证

基于 `98e156d`（main，横屏改版之后）。手机为 iPhone 13 / iOS 26.6.1（60 Hz），Xcode 26.4，`Debug + -O` 构建。测试只连接 Mac 上的 Docker SSH 测试容器（经局域网中继 192.0.2.42:22994），使用独立存储 `AppLifecycleValidation`，不碰用户保存的主机。

## 新增探针

`App/Roamtty/Debug/AppLifecycleValidation.swift`，通过 `scripts/run-memory-validation.py <device> <fixture.json> --app` 启动（`ROAMTTY_LIFECYCLE_ONLY=shell,tmux,host,idle,terminal` 可只跑其中几项）。和 10-25 的探针不同，它走真实的 `AppModel`，页面真的显示在屏幕上：

- shell / tmux 各 6 轮：`launch` → 等待已连接 → 输出 `seq 1 300000`（约 2 MB）→ 打开这个会话的文件页 → 返回 → `closeSession`。用弱引用检查 `SessionRuntime`、`TerminalView`、`Terminal`、会话自己的 `SSHConnection`。
- 主机页 8 轮：主机页 4 秒（监控在采样）→ 文件页 2 秒 → 回首页；检查离开后监控是否停止。
- 首页挂 4 个已连接 tmux 会话空闲 30 秒、终端页空闲 20 秒：进程 CPU 时间（`getrusage`）和 footprint。

## 结果

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 12 轮会话后残留的 runtime / 视图 / 终端模型 / SSH 连接 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| 会话轮次中的 footprint | 25–33 MiB，无增长 | 25–27 MiB，无增长 |
| 全部结束后 footprint | 27 MiB | 27 MiB |
| 首页 4 个 tmux 会话空闲 CPU | 0.41–0.42% | 0.42% |
| 终端页空闲 CPU | 0.27–0.41% | 0.45% |
| Instruments Leaks（MallocStackLogging，13 个连接） | **26 个块**，全部在 libssh2 密钥交换里 | **0** |
| `SSHConnection.reclaimedNativeBlocks`（完整探针，18 个连接） | — | 36 |

**泄漏**：libssh2 1.11.1 在 AES-GCM 下每次密钥交换丢两个 MAC key（libssh2 #1951，上游 2026-05-26 修复但尚未发版）。修法见 [libssh2 说明](../dependencies/libssh2.md)：每个 session 使用自己的分配器，`libssh2_session_free` 之后清零并释放剩下的块。

**卡顿**：Instruments（SwiftUI 模板，含 Animation Hitches）在 60 秒主机页 / 文件页往返中记录 17 次卡顿，除启动时一次 66 ms 外都是单帧 16.7 ms；12 轮 2 MB 输出期间记录 24 次，最长 50 ms，其余 16–33 ms。探针自己的 CADisplayLink 统计偏高（约 50 次 / 60 秒），因为主线程忙时它会漏掉回调，而渲染服务器照样出帧。所以以 Instruments 的数字为准，没有做界面改动。

排除过的怀疑点：每次导航都会 `recordHostUse` → 写 SQLite → 发布 `hosts`。A/B 两轮（50±5 次对比 47–55 次）没有可测差别，所以保持原样。第一次完整运行时出现过 394 次计数，之后连跑三次都复现不出来（49–53 次），判断为机器状态造成的偶发。

## 回归

- Mac 上 `swift test`（Docker 测试容器，端口 22993）：**408 项，14 项跳过，0 失败**。修完测试告警后，重跑 SSHHeap / SSHMemory / SSHExec 共 27 项（2 项跳过），0 失败、0 告警。
- 新增 `SSHHeapTests`（不需要网络）：session 的内存全部经过它自己的分配器，`roam_ssh_set_user` / `roam_ssh_user` 正确，`destroy` 只回收 libssh2 漏掉的块。
- 原有的原生分配计数测试（`testStoppedSFTPDestructors…`、`testPendingWindowAdjustment…`）仍然是 0 blocks / 0 bytes。

范围：这里只覆盖 TCP SSH 路径（中继不转发 UDP，所以没有测 mosh），也没有测远程桌面视频（10-25 的 `--desktop` 探针已覆盖）。没有声称“整个 App 不存在任何泄漏”。
