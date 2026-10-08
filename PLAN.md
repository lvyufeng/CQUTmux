# CQUTmux 复刻方案

> 目标：复刻 iOS App **Moshi: herdr/tmux on SSH/MOSH**（bundle id `app.getmoshi.ios`，Moshi Tech Ltd.，作者 rjyo），
> 一个面向 AI coding agent 的移动终端。阶段性开发、每阶段 commit + push，直至功能对齐。

## 0. 情报来源（本方案的事实基础）

本方案**未使用任何破解 IPA**。事实来源全部为公开渠道：

| 来源 | 取得的信息 |
|---|---|
| Apple iTunes Lookup API (`id=6757859949`) | 全量描述、版本、release notes、截图 |
| https://getmoshi.app + /docs/* | 功能清单、连接协议、moshi-hook 架构、定价 |
| https://getmoshi.app/install.sh | 宿主机 daemon 的安装方式与分发结构 |
| GitHub `rjyo/*` | 作者的依赖选型（关键线索） |

**关于逆向**：若要拿到二进制细节（协议字段、私有端点），需要**你自己设备上的合法副本**再解密。
第三方解密 IPA 站点不采用。当前方案不依赖反编译即可实施。

### 关键发现

- **三种传输，全是现成开源技术**，无自研协议：
  - `SSH` — 标准，支持 jump host；**只有 SSH 支持 agent forwarding**。
  - `Mosh` — UDP，抗漫游/休眠；作者有 `rjyo/mosh-android`（把 mosh 编成移动端静态库）。
  - `ET` — **Eternal Terminal**（开源，TCP 默认 `2022`），用于 UDP 被封的网络。
  - `Auto` 模式顺序：**先 mosh，再 ET，最后 SSH**。
- **无 relay 服务器**：流量在手机与主机间直连，官方明确"no session relay"。
- **宿主机组件 `moshi-hook`**：
  - 静态二进制，`curl -fsSL https://getmoshi.app/install.sh | sh` 安装，注册为 launchd/systemd 用户服务。
  - Homebrew tap：`rjyo/homebrew-moshi`。
  - 暴露 **loopback HTTP 网关 `127.0.0.1:24543`**，承载 Chat View / Diff / 文件浏览 / 浏览器预览。
  - **iOS 端通过 SSH 直连通道（direct-tcpip）访问该回环端口** —— 这是"没有 relay 却能做到富交互"的关键设计。
- **端侧语音**：作者有 `rjyo/parakeet.cpp` + 自维护 `ggml` fork，佐证"Parakeet / Whisper / Apple / cloud"四选一的听写实现路径。
- **Herdr** 是作者自研的终端多路复用器；App 同时兼容 `tmux` / `zellij`。
- **定价**：Free（无账号、无卡）→ Pro 月 $9.99 / 年 $89.99 / 终身 $199（3 设备）。
- **UI 观察**：tmux 风格标签栏、绿色主题、自定义键盘附件栏（Ctrl/Esc/Tab + 图标按钮）、
  消息输入框带麦克风与发送键、Inbox/Usages 分段控件、主题列表（Dracula/Nord/Solarized/Catppuccin/Gruvbox）。

## 1. 功能对齐清单（Feature Parity Matrix）

| 模块 | 功能 | 阶段 |
|---|---|---|
| 连接 | SSH（密码 / 私钥 / jump host / agent forwarding） | P1 / P5b |
| 连接 | Mosh（UDP，抗漫游） | P2 |
| 连接 | ET / Eternal Terminal（TCP 2022） | P2 |
| 连接 | Auto 传输协商（mosh→ET→SSH） | P2 |
| 终端 | VT/xterm 仿真、滚动、选中、链接可点 | P1 |
| 终端 | 自定义键盘附件栏 + 硬件键盘 ⌘K/⌘O/⌘1-9 | P1 |
| 终端 | 手势：swipe 切窗口、pinch 缩放、双击 Tab | P3 |
| 终端 | 主题 / 字体 / 图标、CJK 输入 | P4 ✅ 主题+字体+图标+CJK |
| 会话 | 会话持久化、切后台恢复、断线重连 | P1–P2 |
| 多路复用 | tmux 集成、会话选择器、jump-to window | P2 |
| 多路复用 | zellij / herdr 支持 | P5 |
| Agent 层 | cqutmux-hook 网关 + agent 事件捕获 | P3 |
| Agent 层 | Chat View（Inbox）、approvals、teammate 卡片 | P3 |
| Agent 层 | Diff Viewer、文件浏览器、浏览器预览、模拟器预览 | P3 |
| Agent 层 | Usages 看板（5h/7d 用量与 burn pace） | P4 |
| 通知 | 本地/远程推送、webhook 告警 | P4 |
| 系统 | Live Activity / Dynamic Island / Apple Watch | P4 |
| 语音 | 端侧听写（Apple Speech → whisper.cpp/parakeet） | P4 |
| 输入 | 图片粘贴 / 裁剪 / 标注 / 发送 | P4 |
| 安全 | SSH key 存 Keychain + Face ID 保护 | P1 |
| 其他 | 远程剪贴板 OSC 52、Tailscale、iPad 分栏 | P5 |

## 2. 技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| 语言 / UI | **Swift 6 + SwiftUI**（局部 UIKit 桥接） | iOS 18+，贴近原 App |
| 终端仿真 | **SwiftTerm**（MIT，SPM） | 成熟 VT/xterm 解析 + `TerminalView`，省 2 个月 |
| SSH | **libssh2**（vendored 静态库 + module map） | 完整 PTY/交互式 shell/direct-tcpip，Blink/Termius 同路线 |
| Mosh | `mosh-client` 编为 iOS 静态库（参考 `rjyo/mosh-android`） | 无 Swift 实现，只能移植 |
| ET | Eternal Terminal 客户端编为静态库 | 同上；P2 再评估 |
| 宿主机 daemon | **Node.js**（`host/cqutmux-hook`） | 本机无 Go/Rust/C 工具链，Node 22 已就绪，单文件免编译 |
| 密钥存储 | iOS Keychain + `LocalAuthentication` | 对齐"Face ID for Keys" |
| 语音 | v1 `SFSpeechRecognizer`(on-device) → v2 whisper.cpp | 先快后精 |
| 项目生成 | **XcodeGen**（`project.yml` 为源） | 免手改 pbxproj，适合 agent 迭代 |
| 依赖管理 | Swift Package Manager | 无 brew/CocoaPods 依赖 |

> 传输层抽象成 `Transport` 协议（`openChannel / resize / write / stream`），
> SSH 先行，Mosh/ET 作为可插拔实现，避免早期被 C++ 依赖拖住。

## 3. 目录结构

```
CQUTmux/
├── PLAN.md                      # 本文件
├── project.yml                  # XcodeGen 定义
├── App/
│   ├── CQUTmuxApp.swift
│   ├── Features/
│   │   ├── Hosts/               # 主机/连接配置 CRUD
│   │   ├── Terminal/            # 终端页 + 键盘附件栏 + 手势
│   │   ├── Sessions/            # 会话列表 / tmux 选择器
│   │   ├── Agents/              # Inbox / Chat View / Usages
│   │   ├── Files/               # 文件浏览 / Diff / 预览
│   │   └── Settings/            # 主题 / 字体 / 快捷键 / 安全
│   ├── Resources/               # 主题 JSON、图标
│   └── Info.plist
├── Packages/
│   ├── CQUTTransport/           # Transport 协议 + SSH(libssh2) + Mosh + ET
│   ├── CQUTTerminal/            # SwiftTerm 封装、输入映射
│   ├── CQUTHookClient/          # 访问 host 网关 127.0.0.1:24543
│   ├── CQUTSecurity/            # Keychain + Face ID
│   └── CQUTVoice/               # 端侧听写
├── host/cqutmux-hook/           # 宿主机 Go daemon（网关 + agent hooks）
└── scripts/                     # bootstrap / build / vendor 脚本
```

## 4. 分阶段计划与验收

### Phase 0 — 骨架（本次）
- XcodeGen 工程、SwiftUI 空壳 App、PLAN、README、.gitignore、CI 脚本。
- **验收**：`scripts/build.sh` 能在模拟器编译通过；首个 commit 已 push。

### Phase 1 — SSH 终端 MVP ★核心
- Host 模型 + 连接表单（host/port/user/密码/私钥）。
- 私钥导入并存入 Keychain，Face ID 读取。
- libssh2 PTY 交互式 shell；SwiftTerm 渲染。
- 自动执行 `tmux new -A -s cqutmux`（tmux 缺失则回退普通 shell）。
- 自定义键盘附件栏：Ctrl / Esc / Tab / 方向键 / ⌘。
- 会话切后台保活、前台重连。
- **验收**：模拟器连真实主机，能在 tmux 里跑 Claude Code 并交互。

### Phase 2 — 传输与多路复用
- Mosh 静态库移植 + `Transport` 接入；Auto 协商。
- ET(TCP 2022) 接入。
- tmux 会话/窗口选择器、jump-to window；zellij 基本支持。
- **验收**：切 Wi-Fi↔蜂窝不断线；可从列表跳转到指定 tmux 窗口。

### Phase 3 — Agent 层（moshi-hook 等价物）
- `cqutmux-hook` Go daemon：`127.0.0.1:24543` 网关，`/diff /files /chat /usage /preview`。
- 通过 Claude Code / Codex hooks 捕获 tool call、approval、stop 事件。
- iOS 经 SSH direct-tcpip 访问网关：Inbox、Chat View、approvals、Diff Viewer、文件浏览器。
- **验收**：手机上收到 agent 提问卡片并可直接批准，diff 正常渲染。

### Phase 4 — 通知 / 系统集成 / 语音 / 输入
- APNs 推送、webhook 告警、Live Activity + Dynamic Island、Apple Watch 审批。
- Usages 看板（5h/7d 进度条 + reset 时间）。
- 端侧听写（Apple Speech → whisper.cpp）；图片粘贴/裁剪/标注。
- 主题/字体、CJK 输入。
- **验收**：锁屏可见 agent 状态；语音可直出到 prompt。

### Phase 5 — 收尾对齐
- herdr 支持、手势映射、iPad 分栏、Tailscale、OSC 52 剪贴板、模拟器/浏览器预览完善。

## 4b. 执行状态（2026-10-09）

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 骨架 | ✅ 已合并 | commit `0311e7e` |
| P1 SSH 终端 | ✅ 已合并并**实测** | 见 commit `d4f663c` / `ab9245a`。公钥认证连真实 sshd、SwiftTerm 渲染活 shell 已验证 |
| P2 Mosh | ✅ 已合并并**实测** | **之前标"受阻"是错的**：clang 一直在（Apple clang 21），缺的只是构建工具（pip 可装）。以 `--with-crypto-library=apple-common-crypto` 交叉编译 mosh 客户端全部库 + protobuf-lite，用自写驱动替代 `stmclient.cc` 的 `main()`，再以 `MoshTransport` 接到 `TerminalTransport`。**实测**：C 层 `scripts/mosh-ios/test.sh` 与 App 层 `scripts/mosh-ios/app-test.sh` 均跑通与真实 `mosh-server` 的双向会话——键入的命令在宿主 shell 执行并把结果回显到 iOS 终端。**踩到的真坑**：`Network::timestamp()` 返回的是 mosh 自己的缓存 `frozen_timestamp()`，而该缓存**只由 mosh 自己的 `Select::select()` 刷新**；自写 run loop 不刷新它，时钟就冻住，`tick()` 永远认为没到发送时刻——会话看起来正常（服务端输出照常到达），但**所有按键都被扣住不发**。修法：驱动器在 `mosh_tick` 里调 `freeze_timestamp()`。此 bug 在只有输出方向的旧测试里完全暴露不出来 |
| P2b ET / Auto | 🟡 Auto 已可用（mosh→SSH 回退） | ET 需 `--enable-et` 编译 + 独立 TCP 端口协议，尚未做；选 ET 时表单明示"不可用"且**不会**静默回退成 SSH。Auto 按 Moshi 的顺序实现为 mosh→SSH（跳过未实现的 ET）：宿主没有 `mosh-server` 时自动改用 SSH |
| P3 Agent 层 | ✅ 已合并并**实测** | 宿主 `cqutmux-hook` ↔ 隧道内 Inbox / Code / Diff / Usages，均经模拟器实测 |
| P4 通知/语音 | ✅ 已合并并**实测** | 端侧听写、Live Activity / 灵动岛、本地通知、webhook 告警、图片标注上传、tmux 会话选择器 |
| P5 收尾 | ✅ 主体完成 | iPad 侧栏、zellij、OSC 52 剪贴板、git 历史、网关 token、断线自动重连（修复会话静默失联的真实 bug）、浏览器预览、模拟器预览均已合并并在模拟器实测 |
| P5c 字体 / 图标 | ✅ 已合并并**实测** | 终端字体（family / 字号 / 行距 + 实时预览）持久化，pinch 手势回写偏好；App 与 Watch 图标（`scripts/make-icon.py` 可复现）。补上 P4 里"字体"和图标两处空缺 |
| P5b Jump host | ✅ 已合并并**实测** | 在跳跃主机上开 `direct-tcpip` 到目标的 22 端口，把目标 SSH 连接跑在该通道内（`ByteBufferToSSHDataHandler` / `SSHDataToByteBufferHandler` 做 `ByteBuffer`↔`SSHChannelData` 互转）。实测：两条本机 sshd (`:2222` 为跳板，`:2233` 为目标)，`lsof` 确认应用只连 `:2222`、`:2222`→`:2233` 由 sshd 转发；杀掉跳板会话后 UI 报 `jump host … Connection refused` 并自动重连成功；不带跳板的直连路径回归通过 |
| P6 Apple Watch | 🟡 构建通过、已嵌入 | `CQUTmuxWatch` watchOS target：待审批列表 + 批准/拒绝，经 `WCSession` 与手机同步，决定回落到手机上的 `HookClient.resolve`。**未运行**——本机只装了 iOS 模拟器 runtime，无 watchOS runtime（SDK 在，runtime 不在），无法启动表盘验证 |

**环境事实**：本机工具链为 Swift 6.4 / Xcode 27 / Node 22，**且 clang（Apple clang 21）一直都在**——
此前"无 C 编译工具链"的记载是错的，缺的只是构建工具（cmake/protoc 等，pip 可装），这正是 Mosh 一度被误判为受阻的原因。
仍无 brew、无 Go/Rust。
这直接决定了 daemon 选 Node、且 P2 排在 P3 之后。

**未验证项（诚实记录）**：本地通知的**投递**无法在模拟器验证（`simctl` 不能授予通知权限，
仅能确认授权弹窗出现、代码路径执行）；P4/P5 的 UI 均在模拟器以 shim 数据实测，尚未上真机；
Apple Watch 无 runtime，只验证到"编译 + 嵌入 + 配对字段正确"；CJK 输入依赖 SwiftTerm 的
`UITextInput` 实现（已确认其实现 `setMarkedText`/`unmarkText`/`_markedTextRange` 全量协议，
即系统输入法的组合文本路径），但未在真机上用中文键盘实测。

**未对齐项（尚未实现）**：

| 项 | 原因 | 现状 |
|---|---|---|
| ET | 需 `--enable-et` 编译（独立 TCP 端口协议）；Auto 已用 mosh→SSH 覆盖同类场景 | 选 ET 时表单明示不可用，**不静默回退** |
| SSH agent forwarding | swift-nio-ssh 无 agent 通道，且 iOS 上也没有可转发的 ssh-agent socket | 打开开关时表单明确提示不可用 |
| herdr | 作者自研多路复用器，无公开协议；无法在不知协议的情况下对接 | 支持 tmux / zellij 作为等价能力 |
| 远程推送（APNs） | 需开发者账号 + 推送证书，本环境无法配置 | 本地通知 + webhook 告警已覆盖同类场景 |
| Tailscale 网络探测 | 需集成 Tailscale SDK | 未做；直连与隧道不受影响 |

## 5. 主要风险

1. **Mosh/ET 的 iOS 交叉编译**（protobuf/OpenSSL 依赖链）——P2 最大不确定项，必要时先只做 SSH，mosh 用 ET 替代。
2. **SwiftTerm 与 tmux 全屏/鼠标模式的兼容性**——需要真机回归。
3. **App 进入后台被挂起**，SSH 连接会断——需依赖 tmux 侧持久化 + 前台快速重连（Moshi 正是这么做的）。
4. **本地网关的安全性**：回环端口仅经 SSH 通道访问，不暴露公网；需 token 校验。
```