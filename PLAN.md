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
| 连接 | ET / Eternal Terminal（TCP 2022） | P2 ✅ 实测 |
| 连接 | Auto 传输协商（mosh→ET→SSH） | P2 ✅ 实测 |
| 终端 | VT/xterm 仿真、滚动、选中、链接可点 | P1 |
| 终端 | 自定义键盘附件栏 + 硬件键盘 ⌘K/⌘O/⌘1-9 | P1 |
| 终端 | 手势：swipe 切窗口、pinch 缩放、双击 Tab | P3 |
| 终端 | 主题 / 字体 / 图标、CJK 输入 | P4 ✅ 主题+字体+图标+CJK |
| 外观 | 主题驱动整个 App（chrome/选中/强调色）、主题导入（粘贴/QR/深链）、光标形状与闪烁、CJK 字形回退、备选 App 图标 | P4 ✅ 实测 |
| 终端 | 鼠标滚轮手势（双指拖动转 wheel）、滚到底收键盘 | P5 ✅ |
| 会话 | 会话持久化、切后台恢复、断线重连 | P1–P2 |
| 多路复用 | tmux 集成、会话选择器、jump-to window | P2 |
| 多路复用 | zellij / herdr 支持 | P5 |
| Agent 层 | cqutmux-hook 网关 + agent 事件捕获 | P3 |
| Agent 层 | Chat View（Inbox）、approvals、teammate 卡片 | P3 |
| Agent 层 | Diff Viewer、文件浏览器、浏览器预览、模拟器预览 | P3 |
| Agent 层 | Usages 看板（5h/7d 用量与 burn pace） | P4 |
| 通知 | 本地/远程推送、webhook 告警 | P4 |
| 系统 | Live Activity / Dynamic Island / Apple Watch | P4 / P6 ✅ 表盘实测 |
| 语音 | 听写四引擎（**Parakeet ✅ + Apple Speech ✅ + whisper.cpp ✅ 端侧三引擎实测**；**Cloud ✅ 指向用户自填端点，已对真实 HTTP 服务端到端实测**——Moshi 的托管端点本身是服务不是代码，故按"机制对齐"实现） | P4 ✅ |
| 输入 | 图片粘贴 / 裁剪 / 标注 / 发送 | P4 |
| 安全 | SSH key 存 Keychain + Face ID 保护 | P1 |
| 安全 | 重开需生物识别（后台 >30s）、key 导出页（显式空缺） | P4 ✅ 实测 |
| 同步 | iCloud 设置同步（hosts/主题/字体/光标/布局/引擎；冲突合并；**载荷无密钥**）；凭据同步显示但禁用并说明 | P4 ✅ 实测 |
| 宿主 | `cqutmux` CLI（`<dir>` 起 tmux / `diff` / `status` / `doctor` / `logs` / `serve` / `install` / `pair`），裸调用仍是网关 | P5 ✅ 实测 |
| 通知 | 通知设置页：权限状态、暂停（客户端强制）、测试通知、远程推送状态 | P4 ✅ 实测 |
| 其他 | 远程剪贴板 OSC 52、Tailscale、iPad 分栏 | P5 |

### 1b. 逐项复核（2026-10-09，对照 getmoshi.app 全部 42 个文档页）

复核时把 Moshi 的功能清单逐条对照代码，**已实测确认存在**（此前 PLAN 未记载）：
OSC 52 远程剪贴板（注入 `\033]52;c;<b64>\007` 后宿主剪贴板确实被改写，经 SwiftTerm 的 `oscClipboard` → 我们已有的 `clipboardCopy`）、
tmux 会话选择器（`SessionPickerView`）、
Diff / 文件浏览 / 浏览器预览 / 模拟器预览（`CodePanelView` + `PreviewView` + `SimulatorPreviewView`）、
Live Activity 与灵动岛（`ActivityManager` + `AgentActivityAttributes`）、
图片粘贴与标注上传（`ImageAnnotatorView`）、
主题与字体持久化、iPad 侧栏、CJK 输入。

**本轮新增**：自定义快捷键（`ShortcutGrammar` + 编辑器 + 附件栏按键，26 项语法用例 + 端到端实测）、
**手势绑定**（`GestureStore` + `GestureEditorView`：双击/三击/左滑/右滑可绑定，共 18 项用例 + 端到端实测）、
herdr 宿主侧对接 + **App 侧会话选择器与 Jump To 树**（含直连 socket 的 `pane.focus`）、APNs 两端代码、主机探测不再 source rc、
**deep link**（`cqutmux://tmux?session=…&window=…`、`cqutmux://zellij`、`cqutmux://herdr`、`cqutmux://host?host=…`，
`DeepLink` 解析 + `CFBundleURLTypes` + `onOpenURL` → 切到终端页 → 解析主机 → 导航进会话 → 连上后自动 attach，
`scripts/deeplink-test.sh` 端到端实测：宿主 shell 确实执行了 attach 命令；非法路由弹「无法打开链接」且不切页）。
**顺带修掉另一个真实缺陷**：快捷键编辑器此前**只有调试环境变量能打开**，也就是用户在 App 里根本进不去；
现在终端页右上角有了真正入口（Custom Keys / Gestures / Jump To）。

**又修掉一个跨页缺陷**：Terminal 页与 Code 页此前**都不会自己建连**，只靠 `RootView` 的启动 task，
而该 task 与「从磁盘读 HostStore」存在竞态；竞态输了时，先进这两个页会让会话选择器、图片粘贴、
以及 Code 页的整个文件面板**整场不可用**（只有 Inbox 页自己会连）。现两页各自保证：
Terminal 页 `connection.client == nil` 时连到当前主机；Code 页在**只有一个主机**时自动连
（多个时保留选择器——替用户猜该浏览哪台机器比让他点一下更糟）。

**再修掉一个隐私缺陷（听写）**：原实现写着"音频与转写不出设备"，但 `requiresOnDeviceRecognition` 只是**请求**——
当该语言没有装离线模型时，识别器**不会报错**，而是静默回退到 Apple 服务器上传音频。
即"告诉用户声音不出设备、实际传了出去"。现改为**先检查 `supportsOnDeviceRecognition`，不支持就直接拒绝启动**并提示去哪装模型
（`Settings › General › Keyboard › Dictation`）：麦克风说"离线不可用"是小问题，说谎是大问题。
**手势绑定的取舍**：单击**不开放绑定**——SwiftTerm 自己的单击处理驱动鼠标上报与长按选词，
我们的识别器必须先失败才能让路，那样单击就不再是今天的单击。其余四个手势终端本就没用，全部开放。
绑定失效（语法变更）时**回落到内置行为**而非什么都不做，因为那看起来就像 App 坏了。
**顺带修掉一个真实缺陷**：`AgentConnection` 只在 `RootView.task` 里连，
而该 task 与「从磁盘读 HostStore」存在竞态；竞态输了时，**先进 Terminal 页会让会话选择器与图片粘贴按钮整场缺失**
（Inbox 页自己会连，所以只在 Terminal 页暴露）。改为由需要这条隧道的 Terminal 页自己保证。

**本轮新增：端侧 Whisper 听写**。此前端侧只有 Apple Speech，且它在语言没有装离线模型时
会**静默上传音频**（已改为拒绝启动）。现按 `scripts/et-ios/` 的方式把 **whisper.cpp** 编成 iOS
静态库并接到 App：`scripts/whisper-ios/build.sh` 交叉编译 whisper+ggml（Metal / BLAS / CPU 三个后端，
Metal 着色器用 `GGML_METAL_EMBED_LIBRARY` 编进归档，App 不带 `.metal` 文件）；`driver/whisper_shim.c`
是 C 缝，SwiftPM 只出 header（与 CQUTETC / CQUTMoshC 同构，SwiftPM 不允许 header search path 出包）；
`WhisperDictation` 录音—转写，`WhisperModelStore` 按需下载模型（32 MB–574 MB，SHA-256 校验，
可删除），`SpeechSettings` 在 Apple / Whisper 之间切换，设置页 `Speech` 管引擎与模型。
**实测**：`scripts/whisper-ios/check.sh`（直接链归档，jfk.wav → 文本）与
`scripts/whisper-ios/app-test.sh`（走 App 自身路径，同一段录音 → 容器内 transcript.txt）均通过，
转写为 `And so my fellow Americans ask not what your country can do for you ask what you can do for your country.`
**踩到的坑**：① 模拟器 Metal 能注册设备、能编译 kernel，但第一张图就 trap（`recommendedMaxWorkingSetSize = 0.00 MB`）——
用同源码同参数编 macOS 版跑 Apple M4 的 Metal 路径**完全正确**，故判定是模拟器而非构建；App 在
`#if targetEnvironment(simulator)` 下关 GPU，真机开。② 玩具模型贪婪解码会重复尾句，`single_segment` 才根治
（听写本就是一句话，不需要 long-form）。③ `simctl spawn` 只能跑模拟器文件系统内的可执行文件，宿主机 `mktemp`
路径会 dyld abort；且它会挑到第一个已启动设备——本机常常是 Apple Watch 模拟器。

**仍未做**：无原生 Windows、无 macOS 菜单栏 / Moshi Desktop（属另一产品）；
**界面语言固定**（Moshi 可把 UI 语言钉在某个 locale）：本 App **没有任何本地化**——所有字符串
都写死在调用处，全是英文，**没有可钉的对象**。要做对意味着提取并翻译整个界面，那是另一件事，
不是加一个开关；
**会话卡片/紧凑列表布局**已做（默认卡片，见 P4 行）；
Tailscale 不需集成（Moshi 文档亦确认：它工作在系统层，用 100.x 地址直连即可）；
SSH agent forwarding 已实现并实测（见下表）；APNs 投递受环境所限，非代码问题。

**最近目录已接并实测**：`RecentDirectoryStore`（按 `host:port` 分机存储，最多 12 条，
重访上浮去重，`.` 与空串不记）+ `GoToDirectoryView`（可直接输路径，或从最近列表点选），
入口在 Code 页的 Preview 菜单里；点目录进入时也会记录。13 项用例无需模拟器。

**本轮新增：主题真正驱动整个 App**（此前只有终端 16 色 + 字体 + 图标，
说明与 Moshi 的 Personalization 页差得最远的一处）。逐项：

- **chrome 随主题**：原来 `Theme.accent` 是写死的绿色、25 处引用，选 Solarized Light 只改终端、
  App 外壳仍是深色。现由 `ThemeStore` 驱动：根部 `.tint` 取主题强调色，`preferredColorScheme`
  取主题明暗，系统自身的列表/表单随之切换。**刻意不做"每面一个背景色"**——那正是主题与深色模式
  互相打架、而非驱动的方式。主题格式里没有强调色字段，故取调色板自己的绿。
- **主题导入**（Moshi 的 v1 格式，逐字对齐）：JSON / `moshi-theme:` base64 / QR / `cqutmux://theme` 深链，
  四条路都落到同一个导入页。`mode` **必须显式给出**（不从颜色猜），缺 bright 取 base、缺 base 取 foreground。
- **9 个内置主题**（6 深 3 浅），带导入主题的持久化与去重（按名字 slug，重导是同一条而不是两条）。
- **光标形状（Block/Underline/Bar）与闪烁**：SwiftTerm 把二者编码成单个六值枚举，故存储分开、用时合成；
  经 `setCursorStyle` 应用（直接写 `options.cursorStyle` 不会通知 delegate，画出来的光标仍是旧形状）。
- **CJK 字形回退**：是 fallback 不是字体选择——拉丁仍用所选字体，`cascadeList` 补中日韩。
  iOS 自带每种脚本的字体，故不像 Moshi 需要下载。
- **备选 App 图标**：XcodeGen 的 asset 支持不暴露 alternate set，故用松散文件 + `CFBundleAlternateIcons`
  声明；`CFBundlePrimaryIcon` **不是可选项**——缺了它 iOS 能显示备选却回不到默认，用户没有退路。
- **鼠标滚轮手势**：SwiftTerm 把单指拖动转成 mouse drag，**从不发送 wheel**，于是只认滚轮的
  `less`/`htop`/agent transcript 根本没法滚。现双指拖动转 wheel（Cb 64/65），并把它的拖动识别器
  限制为单指，二者不会同时触发。滚到底收键盘用 UIKit 的 `keyboardDismissMode = .interactive`，
  不自己造（终端滚动几何在 SwiftTerm 内部，第二个"底部在哪"的意见只会打架）。
- **深链新增 `cqutmux://theme`**（对应 `moshi://theme`）：链接与点击共用同一个 route 枚举，
  不再各知一份设置页布局。

**实测**：深链按 `scripts/deeplink-test.sh` 的方式从 Usages 页打开且确实压栈；GitHub Light 整 App 变浅色；
Dracula 经真 sshd 进到活终端；导入页渲染正常；`scripts/theme-format/run.sh` **61 项断言全绿**。
**该检查抓到一个真 bug**：ANSI 数组我写成了交错（black, brightBlack, red…），而调色板要的是
前 8 基础色、后 8 亮色——每个导入主题的颜色都会错位且**导入不报错**，正是往返测试存在的意义。

**本轮新增：Security 与 Notifications 两个设置页**（Moshi 设置里的最后两块）。

- **Security**：存储事实（key 在 Keychain、只在本机解锁时可读）、key 保护方式（Face ID / Touch ID / 无）。
  "重开需生物识别"开关会**在后台超过 30 秒后回到前台时**弹一次（`CQUTmuxApp` 的 `scenePhase` +
  `SecuritySettings.Gate`），盖在 App 之上而**不拆视图树**——重建 SwiftUI 树会丢掉正在保护的终端会话，
  那就比不锁更糟。开关在**本机没有录入生物识别**时禁用并说明去哪录，因为 `canEvaluatePolicy`
  是唯一诚实的"是否可用"判据，光有 `biometryType` 会给出一个按下去只会失败的开关。
- **导出密钥**页做成**显式的空缺**（`ContentUnavailableView`），不是隐藏：Moshi 的导出要生物识别确认，
  在那条路径存在之前，声称"密钥安全"的页面上应当写明没有出口，而不是留个空列表。
- ~~**iCloud 同步刻意不做**：它会把密钥复制出本机。~~ **此判断是错的，已翻案并实现**——见下。
- **Notifications**：权限状态、**暂停**（保留注册、不弹横幅）、发送测试通知、远程推送注册状态。
  暂停必须**在客户端强制**——网关无法知道某台设备暂停了，所以拦在 `AppDelegate.willPresent`
  （`completionHandler([])`）并在暂停时清掉已投递的横幅；只在发送侧拦会漏掉已经在途的推送。
- **测试通知**用真实审批同一个 category，于是 Allow/Deny 按钮会一起出现——
  这条路径最可能配错、也最难靠等一个真审批来验证。

**实测**：`scripts/build.sh` 通过；Security / Notifications / Cursor 三页在模拟器渲染正常，
调试入口 `CQUT_DEV_TAB` 已覆盖 `cursor`/`icon`/`sessions`/`security`/`notifications`。

**本轮新增：iCloud 设置同步（并纠正上一轮的一处错误判断）。**
上一轮我写"iCloud 同步刻意不做，因为它会把密钥复制出本机"——**查 Moshi 的 `security-sync` 页后确认这是错的**：
Moshi 把两件事**分开**，设置同步（hosts/偏好）与**单独一个、在设置同步之上再显式开启的凭据同步**。
把两者混为一谈，等于用"凭据同步不该做"的结论否掉了本来无害的设置同步。现按 Moshi 的真实形状实现：

- **`SyncPayload` 逐字段手工构造**，不是直接编码各个 store——这正是安全性所在：
  载荷里**没有任何放密钥的位置**，所以"同步主题"不可能变成"把私钥复制到账号下所有设备"。
  检查脚本里有一组断言盯着这件事（`keySeed`/`privateKey`/`gatewayToken`/`password`/`token` 都不得出现在载荷里）。
- **凭据同步在 UI 里显示但禁用**，并说明原因。藏起来会让用户以为 App 坏了；
  给一个"看起来会同步凭据"的开关而它什么也不动，则更糟。
- **合并语义**（`SettingsSync.decide`/`merge`）：用"上次成功交换的基线"判断**哪一侧动过**，
  而不是靠时间戳。两侧都动过 → **合并**而非取舍：hosts 与导入主题**取并集**（丢一台主机远糟于多一行；
  重复导入按 id 去重），标量（字体等）以本地为准（用户正看着这台设备）。
- **关掉同步会丢弃基线**；且**启动时只在同步开启的情况下**才恢复基线——
  否则一个"关掉过同步再重开"的设备会拿几个月前的快照当云端现状，静默丢掉另一侧的改动。

**实测**：`scripts/build.sh` 通过；`scripts/settings-sync/run.sh` **28 项断言**，无需模拟器与 iCloud 账号
（冲突合并是唯一无法手动复现的部分，故单列检查）。该检查抓到**三个真问题**：
① 关掉同步后**重启会把基线又读回来**（`init` 未看 `isEnabled`）——设置看起来没生效；
② 我原本为"两侧都没动却不同"写的 `(false, false)` 分支**不可达**（能进 switch 就说明 local ≠ remote），
   一并写了个测不到的断言——现改成如实注明不可达并断言真正会发生的路径；
③ 我的另外两条断言本身写反了（把"合并"当成"推送"），是**测试错、实现对**。
模拟器截图确认：无 iCloud 账号时开关**禁用并说明去哪登录**，而不是给一个按不动的开关。

**本轮新增：宿主 CLI（`cqutmux`）。**
对照 Moshi 文档页清单逐条核时发现一处漏项：Moshi 在 `moshi-hook` 之外还发一个 **`moshi` 命令**
（`/docs/moshi-cli`："project tmux launcher and one-shot diff viewer"）。
我们的 `host/cqutmux-hook/index.mjs` 一直只有**参数**、没有**子命令**，即文档里的这一项是缺的。
按 Moshi 的形状补齐（同一个文件两个名字，`cqutmux` 与 `cqutmux-hook`）：
`<dir>`（按目录名开/接入 tmux 会话，用 `spawn` 而非 `exec`——见下）、`diff`、`status`、`doctor`、
`logs [-f]`、`serve`、`install`、`pair`、`help`。
**默认路径刻意不变**：不给子命令时仍然启动网关——已装好的机器就是这么调它的，
一个改变"裸调用语义"的改动会直接弄坏现有安装。
单个位置参数按 Moshi 的规则理解为**路径**（`cqutmux ~/src/api` 应是项目名，不能被当成拼错的命令）。

**实测**：`scripts/cli-check.sh` **13 项**全绿，可重复运行（连跑两次均通过）。该检查抓到**三个真 bug**：
① **`--port 24880` 的值被当成位置参数路径**——扫描位置参数时没有跳过带值标志的值，
   于是"裸调用"直接变成"打不开目录 /private/tmp/24880"；
② **`serve` 什么也不做就退出**——分派分支无条件 `process.exit(0)`，于是 `serve` 既没启动网关、
   又返回成功；现改为 `serve` 不进入分派、直接落到服务器代码；
③ 脚本自身的**端口争用**（后台 `node ... &` 记录的是子 shell 的 pid，`kill $!` 杀不掉 node），
   让 `status` 检查在上一轮残留的服务上"通过"——现按 pid 杀并让这个检查自带端口占用检测。

## 2. 技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| 语言 / UI | **Swift 6 + SwiftUI**（局部 UIKit 桥接） | iOS 18+，贴近原 App |
| 终端仿真 | **SwiftTerm**（MIT，SPM） | 成熟 VT/xterm 解析 + `TerminalView`，省 2 个月 |
| SSH | **libssh2**（vendored 静态库 + module map） | 完整 PTY/交互式 shell/direct-tcpip，Blink/Termius 同路线 |
| Mosh | `mosh-client` 编为 iOS 静态库（参考 `rjyo/mosh-android`） | 无 Swift 实现，只能移植 |
| ET | Eternal Terminal 客户端编为静态库 | 已实现：`scripts/et-ios/` 编出 `libetcore.a`（含自写 C 驱动器），App 侧 `CQUTET` 包接 `TerminalTransport` |
| 宿主机 daemon | **Node.js**（`host/cqutmux-hook`） | 本机无 Go/Rust/C 工具链，Node 22 已就绪，单文件免编译 |
| 密钥存储 | iOS Keychain + `LocalAuthentication` | 对齐"Face ID for Keys" |
| 语音 | `SFSpeechRecognizer`(on-device) **与** whisper.cpp 双引擎，设置页可切 | 两者取舍不同：Apple 无下载但依赖系统离线模型（缺失时拒绝运行），whisper.cpp 需下载模型但语言/机型不受限 |
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
| P2b ET / Auto | ✅ 已合并并在模拟器**实测** | ET 客户端核心全量编到 iOS，写了自己的驱动器（`scripts/et-ios/driver/`），并**实测**：C 层 `test.sh` 与 App 层 `app-test.sh` 均与真实 `etserver` 跑通——握手、输出解码、键入命令被远端 shell 执行（`ET_APP_33_OK` / `TYPED_24_OK`）、resize 存活，`lsof` 可见 App 与 :2022 的 ESTABLISHED 连接。**Auto 现为 mosh→ET→SSH**，Moshi 的原始顺序。**纠错**：此前判定 ET"绑死 forkpty 因而形态不匹配"是**错的**，`Console.hpp` 本就是给非 pty 前端用的显式接口（ET 自己的 `test/FakeConsole.hpp` 就是这么用的），`forkpty` 在**远端**那一侧。踩到的坑都记在 `scripts/et-ios/README.md` |
| P3 Agent 层 | ✅ 已合并并**实测** | 宿主 `cqutmux-hook` ↔ 隧道内 Inbox / Code / Diff / Usages，均经模拟器实测 |
| P4 通知/语音 | ✅ 已合并并**实测** | 端侧听写、Live Activity / 灵动岛、本地通知、webhook 告警、图片标注上传、tmux 会话选择器 |
| P5 收尾 | ✅ 主体完成 | iPad 侧栏、zellij、OSC 52 剪贴板、git 历史、网关 token、断线自动重连（修复会话静默失联的真实 bug）、浏览器预览、模拟器预览均已合并并在模拟器实测 |
| P5c 字体 / 图标 | ✅ 已合并并**实测** | 终端字体（family / 字号 / 行距 + 实时预览）持久化，pinch 手势回写偏好；App 与 Watch 图标（`scripts/make-icon.py` 可复现）。补上 P4 里"字体"和图标两处空缺 |
| P5b Jump host | ✅ 已合并并**实测** | 在跳跃主机上开 `direct-tcpip` 到目标的 22 端口，把目标 SSH 连接跑在该通道内（`ByteBufferToSSHDataHandler` / `SSHDataToByteBufferHandler` 做 `ByteBuffer`↔`SSHChannelData` 互转）。实测：两条本机 sshd (`:2222` 为跳板，`:2233` 为目标)，`lsof` 确认应用只连 `:2222`、`:2222`→`:2233` 由 sshd 转发；杀掉跳板会话后 UI 报 `jump host … Connection refused` 并自动重连成功；不带跳板的直连路径回归通过 |
| P6 Apple Watch | ✅ 已在 watchOS 模拟器**实测** | `CQUTmuxWatch` watchOS target：待审批列表 + 批准/拒绝，经 `WCSession` 与手机同步，决定回落到手机上的 `HookClient.resolve`。**已跑通完整回路**：手机 Inbox 的待审批经 `updateApplicationContext` 推到表盘并渲染；表盘上的决定经 `sendMessage` 回到手机，手机发出 `POST /approve/3`，网关侧 `decision=allow` + `resolvedAt` 落库。**模拟器限制（非 App 缺陷）**：`simctl` 只把 watch app 装进表盘容器，不会执行真机上的"手机代表表盘安装"那一步握手，于是 phone 侧 WCD 的 `WCDStoredInstalledWatchApps` 始终为空，`updateApplicationContext` 直接以 `WCErrorCodeWatchAppNotInstalled` 失败（`appInstalled: NO`）。实测前需先手工补上该记录并重启 `com.apple.wcd`；代码本身无需改动。真机由系统完成该握手，不存在此问题 |

**已知构建缺陷（真机 iOS 构建，非代码问题，模拟器不受影响）**：`xcodebuild -destination 'generic/platform=iOS'` 失败于
`Watch/Assets.xcassets: error: The stickers icon set, app icon set, or icon stack named "AppIcon" did not have any applicable content`。
**已确诊根因**：watch target 的 product type 是泛用的 `com.apple.product-type.application`（应为 watch 专用类型），
于是真机嵌入步骤用 **iphoneos 平台**去编 watch 的 asset catalog（actool 收到 `--platform iphoneos --target-device iphone/ipad`），
watch 图标集在 iOS 平台下"没有适用内容"。**试过的修法都不成立**：改用 `application.watchapp2` 后
模拟器构建反而坏掉（`Multiple commands produce .../Debug-watchsimulator/CQUTmuxWatch.app/CQUTmuxWatch`，
`CreateUniversalBinary normal arm64 x86_64` 与某个 `CopyAndPreserveArchs` 命令争同一个输出）；
加 `ARCHS: arm64_32` 则模拟器切片无效。**这是已存在的缺陷，不是本轮引入**（`git stash -u` 后 HEAD 复现同样错误），
模拟器上的 `scripts/build.sh` 全绿。要修得整体重做 watch 的嵌入方式，不是本轮的范围。

**环境事实**：本机工具链为 Swift 6.4 / Xcode 27 / Node 22，**且 clang（Apple clang 21）一直都在**——
此前"无 C 编译工具链"的记载是错的，缺的只是构建工具（cmake/protoc 等，pip 可装），这正是 Mosh 一度被误判为受阻的原因。
仍无 brew、无 Go/Rust。
这直接决定了 daemon 选 Node、且 P2 排在 P3 之后。

**本轮新增：Cloud 语音引擎**（Moshi 四个引擎里的最后一个）。
Moshi 把它做成**自己托管的服务**——这是本 App 唯一无法靠写代码对齐的部分：托管端点是一个产品，不是一个构建步骤。
**能对齐的是机制**，所以这个引擎指向**用户自己填的端点**。这是不同的产品决定，设置页也直说是哪一种，
而不是暗示一个并不存在的服务。
- 端点与 token：token 存 **Keychain**（不是 `UserDefaults`——那是容器里的 plist，备份会把它带出设备）。
- 端点按输入原样存储、用时才解析，这样输入到一半的半截 URL 不会被静默丢掉；空串即"未配置"。
- **`app` 侧唯一的"上传音频"引擎，所以它的说明不得沿用其它引擎的"不上传"那句**——
  继续写"音频不上传"就是又犯一次 Apple 引擎静默上传那类的不实陈述。
- 请求体：16-bit 单声道 16 kHz WAV（base64 进 JSON），`Authorization: Bearer` 可选；
  回复接受 `{"text":…}` / `{"transcript":…}` / `{"result":…}` 或裸字符串。

**实测**：`scripts/build.sh` 通过；
① `scripts/cloud-dictation/run.sh` **40 项断言**（WAV 头逐字节、越界钳位、空录音、四种回复形态、拒绝猜错、base64 往返）；
② `scripts/cloud-dictation/end-to-end.sh` **4 个用例**，在模拟器里对着**真实 HTTP 服务**跑通：
服务端回读请求，确认 `POST`、`Content-Type`、`Bearer` 头、以及**自洽的 16 kHz 单声道 WAV**（RIFF/data 长度与实到字节一致）；
裸字符串回复被接受；503 被当作失败且**打印写给人看的那句话**（不是 `badStatus(503)`）。
**这套检查抓到四个真问题**：① 我把 `-0.5` 的断言写错了（应为 -16383 而非 -16384，即"想当然"而非实现错）；
② 引擎与诊断 harness 都用 `"\(error)"` 打印错误，终端状态行会显示 `badStatus(503)` 而不是写好的句子；
③ harness 第一轮**不清空上一轮的报告文件**，于是每个用例立刻"通过"在上一轮的内容上——一次失败会被算到错误的用例头上；
④ 端口被残留进程占用时每个用例都表现为"连不上"，与 App 坏掉无法区分，现已先行报错。

**未验证项（诚实记录）**：本地通知的**投递**无法在模拟器验证（`simctl` 不能授予通知权限，
仅能确认授权弹窗出现、代码路径执行）；P4/P5 的 UI 均在模拟器以 shim 数据实测，尚未上真机；
Apple Watch 已在 watchOS 模拟器跑通（见 P6 行），表盘上的决定如何送达则用 `CQUT_DEV_WATCH_APPROVE`
注入 —— 模拟器无法用命令行点击表盘按钮，该注入走的正是 `decide`→`WatchLink.send` 同一条路径；
CJK 输入依赖 SwiftTerm 的
`UITextInput` 实现（已确认其实现 `setMarkedText`/`unmarkText`/`_markedTextRange` 全量协议，
即系统输入法的组合文本路径），但未在真机上用中文键盘实测。

**曾判定为"未对齐"、现已逐条落地或查明不必做的项**：

（下表每行都保留了当初的判断与后来的结论。它存在的意义不是记录进度，而是这几条里有三条当初都判错了——agent forwarding 判成环境所限、herdr 判成无公开协议、Parakeet 判成 ggml 冲突不可解——错法各不相同，记下来比记结果有用。）

| 项 | 原因 | 现状 |
|---|---|---|
| SSH agent forwarding | **此前把它归为"环境所限"是错的——它是 Moshi 真有的功能，且现已实现并实测通过。** Moshi 的语义：转发的是**这条连接自己存的那把私钥**（"Exactly one identity"，"not a bridge to an external or hardware SSH agent"），即 App 自己当 agent，**不需要 iOS 上有 agent socket**。<br>**实现**：① vendored `swift-nio-ssh` fork（`Packages/ThirdParty/`），加 `auth-agent-req@openssh.com` 请求类型与 `AgentForwardingRequest` 事件（上游没建模，且子通道请求路径是 internal）；② `SSHAgent`/`SSHAgentChannel` 实现 OpenSSH agent 协议（`REQUEST_IDENTITIES`/`SIGN_REQUEST`），私钥只在进程内、经 `Crypto` 签名，走 `SSHCredential.agentSigner` 闭包，从不落盘到远端。<br>**实测**（`AgentForwardingChecks`，对 127.0.0.1:2222 的真 sshd，连跑 3 次全绿）：会话起来后宿主 `ssh-add -l` 列出 `SHA256:AyOOb6… cqutmux (ED25519)`——正是本连接的密钥指纹；再在会话内套一层 `ssh -p 2222 user@host 'echo AGENT_NESTED_OK'`，**嵌套连接用我们转发的密钥认证成功**（`AGENT_NESTED_OK`），即签名真的跨进程产生了。<br>**踩到的两个真坑**：① `wireBlob` 一开始把算法名又拼了一遍（70 字节而非 51）——OpenSSH 公钥的 base64 **本身就是完整的 wire blob**，重复前缀会让 `authorized_keys` 静默拒绝；协议单测 `SSHAgentChecks`（24 项）抓到了它。② 请求**必须发在 `shell` 请求之前**：发在之后 sshd 照样回 `reply 0`，但**从不创建 agent socket**，`SSH_AUTH_SOCK` 为空、`ssh-add -l` 报 "Could not open a connection to your authentication agent"——静默失败，与 Moshi 文档描述的一致。 | ✅ 已实现并实测 |
| herdr | **此前"无公开协议"的判断是错的**：herdr 是开源项目（`herdrdev/herdr`，Apache-2.0，Rust），有公开 CLI 与 socket API。**宿主侧已对接并实测**：`host/cqutmux-hook/herdr.mjs` 经 `herdr api snapshot` / `pane send-text` / `pane read`（走 SSH exec，无需转发——socket 是 Unix socket，`direct-tcpip` 到不了）暴露 `GET /herdr`、`GET /herdr/pane/:id`、`POST /herdr/approve/:id`。**App 侧已接入并实测**：herdr 的 workspace 折进既有的 `/sessions` 板（`mux: "herdr"`），会话选择器直接渲染，并显示 herdr 自己的 agent 状态；跳转走 `herdr tab focus <tab_id>`。上表已实测：对真实 herdr 0.9.3，选择器列出 `~ herdr blocked attached 2w` 与两个 tab；`herdr tab focus w1:t2` 使 `focused_tab_id` 实际变为 `w1:t2`。**踩到的真坑**：最初从 `agents` 数组反推 tab 列表，导致**没有 agent 的 tab 被静默丢掉**（实测 w1:t2 就消失了）；改为读 snapshot 自己的 `tabs` 数组。另：herdr 按 **tab id** 而非序号寻址 tab，因此窗口选择器从 `Int index` 改成字符串 `selector`（tmux/zellij 传序号字符串，herdr 传 `w1:t2`）。
**Jump To 树已接并实测**：`GET /herdr` 多返回 tabs 及其 panes，App 侧 `JumpToView` 渲染 workspace→tab→pane 三级。
**关键技术点**：`herdr pane focus` 是**方向性**的（`--direction left|right|up|down`），**无法指名**某个 pane，
所以 Jump To 不能走 CLI。但 socket API 有 `pane.focus`，参数是 `PaneTarget{pane_id}`。
网关本就跑在宿主上、紧挨着那个 Unix socket，于是直接说协议（`callHerdrSocket`，一行 JSON，`{id,method,params}` 信封，与 CLI 自身一致）。
实测：`POST /herdr/focus/w1:p1` 后 herdr 自报 `focused_pane_id=w1:p1`，再 focus `w1:p2` 又变回 `w1:p2`——**确认焦点真的动了**，而不是返回 ok 却什么也没发生 |
| 远程推送（APNs） | **两端代码已写全并已跑通到系统边界**：App 侧 `PushCoordinator`/`AppDelegate`（令牌注册、`CQUT_APPROVAL` 分类的锁屏 Allow/Deny、前后台推送回调）→ `POST /push/register` → 宿主 `push.mjs`（HTTP/2 + ES256 provider JWT，签名经 openssl 生成的测试密钥**验签通过**、64 字节裸 r‖s 编码正确）。**卡在签名**：模拟器日志 `Push registration with a nil environment`——无 `aps-environment` entitlement，而该 entitlement 必须有付费开发者账号的 provisioning profile。本地通知 + webhook 告警已覆盖同类场景。<br>**查 Moshi 文档后的两点更正**：① 推送**不需要账号登录**，也不需要用户自备 Apple 开发者证书——Moshi 自己是发送方，走 `api.getmoshi.app` 再分发（Expo Push / APNs），文档只说 per-device "license join"，从未要求用户有开发者账号。也就是说，**如果要对齐，需要的不是用户掏钱，而是我们也得有一个托管推送服务**——这与 Moshi 自己声称的 "no session relay" 并不矛盾（它明确区分了会话中转与推送服务）。② 我们目前是**直接对 APNs 发**（provider JWT），所以确实需要付费账号；Moshi 的路线不需要。两条路都能到，只是前者要多一个自有服务。 |
| Parakeet 语音引擎 | **Moshi 有四个语音引擎，Parakeet 是它当前推荐的默认**（getmoshi.app/docs/voice："the engine we currently recommend for English and many European languages"）。此前只对齐了 Apple + whisper，现已补齐并实测。<br>**关键发现**：**whisper.cpp 1.9.5 自带 Parakeet**（`src/parakeet.cpp` + `include/parakeet.h` + 独立 `parakeet` target），且**用的是同一个 ggml**。它本来就在 `scripts/whisper-ios/build.sh` 编出的那套 archive 里，只是我们没收集。所以"再加一个引擎"实际是加一行 target 和一行 `-lparakeet`。<br>**此前判断的翻案**：先前记的障碍（独立项目 `rjyo/parakeet.cpp` 自带一份打过补丁的 ggml，与本 App 已链的 whisper ggml 符号冲突）**是真的**——实测 `libggml-base.a` 重叠 910 个符号，且两者静态链接**不退错**，第二份被静默丢弃、其中一个引擎绑到另一个的 ggml 上，一个链接两者的测试二进制退出码 0。但这条路**根本不必走**：in-tree 的 Parakeet 是同一个引擎、同一份 ggml，没有第二份可冲突。<br>**实测**：① `scripts/whisper-ios/check.sh`（`CQUT_ENGINE=parakeet`，走 App 自己的 C seam 而非 CLI）：`PASS transcript contains "Phoebe"/"portrait"` + 时间戳单位断言通过；② App 级 `app-test.sh`：`TRANSCRIBE_OK / Well, I don't wish to see it any more, observed Phoebe, turning away her eyes...`；③ Whisper 同一构建回归通过，两个引擎共用一个 ggml 必须两个都验；④ 设置页三个引擎按 Moshi 顺序排列（Parakeet / Apple / Whisper）。<br>**踩到的真坑**：parakeet.cpp 的 segment 时间是**帧数**（100 fps），数值上恰好等于 whisper 的厘秒。第一版 seam 按注释里写的"毫秒"原样透传，7.4 秒的片段返回 end=744——看着像个合理的亚秒时间戳，而不是差了 10 倍，任何文本比对都抓不到。现在检查脚本拿它和音频长度对照。<br>**模型**：`ggml-org/parakeet-GGUF` 的 GGML 格式（**不是** parakeet.cpp 的 GGUF，两者互不可读），q4_k 415.6 MB / q8_0 668.8 MB / f16 1.26 GB，sha256 记在 `parakeet_shim.c` 里 | ✅ 已实现并实测 |
| Tailscale 网络探测 | **不需要**：Moshi 自己的文档写明它不做内置集成（"no built-in Tailscale host picker"，VPN 在系统层透明工作），用 `100.x.y.z` / MagicDNS 名当普通 SSH 目标即可 | 与 Moshi 一致；直连与隧道不受影响 |

## 5. 主要风险

1. ~~**Mosh/ET 的 iOS 交叉编译**（protobuf/OpenSSL 依赖链）~~ —— **已排除**。两者均已编通并实测；ET 的 libsodium 用 `scripts/et-ios/libsodium.sh`，host 侧 `etserver` 用 `host-tools.sh` 从源码构建（ET 不发布 macOS 产物）。
2. **SwiftTerm 与 tmux 全屏/鼠标模式的兼容性**——需要真机回归。
3. **App 进入后台被挂起**，SSH 连接会断——需依赖 tmux 侧持久化 + 前台快速重连（Moshi 正是这么做的）。
4. **本地网关的安全性**：回环端口仅经 SSH 通道访问，不暴露公网；需 token 校验。
```