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
| 连接 | **带口令的私钥**（`bcrypt_pbkdf` + `aes256-ctr` 解出被 `ssh-keygen -N` 加密的 `openssh-key-v1`；口令可记住在 Keychain，按主机存） | ✅ 规则实测（key-import 35 + passphrase 18）+ 真 sshd 端到端实测（服务器 `Accepted publickey`，指纹与 fixture 一致）+ 界面实测 |
| 连接 | Mosh（UDP，抗漫游） | P2 |
| 连接 | ET / Eternal Terminal（TCP 2022） | P2 ✅ 实测 |
| 连接 | Auto 传输协商（mosh→ET→SSH） | P2 ✅ 实测 |
| 连接 | **Easy Pair**（宿主 `cqutmux pair` 生成密钥、写 `authorized_keys`、打印 `cqutmux://pair` 链接与二维码；App 扫码或粘贴即成连接，**私钥走 fragment**） | P5 ✅ 规则实测（pair 36 + qr 33 + qr-js 28 + cli 端到端）+ 界面实测 |
| 终端 | VT/xterm 仿真、滚动、选中、链接可点 | P1 |
| 终端 | 自定义键盘附件栏 + 硬件键盘 ⌘K/⌘O/⌘1-9 | P1 |
| 输入 | Option 当 Meta（`InputSettings.optionMeta`）、栏内按键增删排序、D-pad 四向 + 两角可绑定（Esc/Del/^C/收键盘）、接硬件键盘时自动收栏 | P5 ✅ 规则实测 + 端到端实测 |
| 输入 | **Command History 键**（默认栏外，Settings → Input 可加；More 菜单同入口）：读宿主 `~/.zsh_history` / `~/.bash_history`，两种记录格式（extended/plain）在同一文件里混排都要认，分号按**第一个**切、反斜杠续行按**换行**接回。点选**只打字不回车**——列表是宿主拼的，先读再按 Return。**刻意不做**：与 `/recent-directories` 不同，此路由**不**受 `always_on_discovery` 约束（那是"未经请求就探宿主"，这里是用户自己按的键） | P5 ✅ 规则实测（33）+ 宿主端到端实测 + 界面实测 |
| 终端 | 手势：swipe 切窗口、pinch 缩放、双击 Tab | P3 |
| 终端 | 主题 / 字体 / 图标、CJK 输入 | P4 ✅ 主题+字体+图标+CJK |
| 终端 | **自定义字体导入**（Settings → Font → Import font…，`.ttf/.otf/.ttc`）：**拷贝**进 App 容器（不是引用文档选择器 URL —— 该 URL 只在回调期间有效，终端要天天重新解析），并用**字体自己的 PostScript 名**注册，而不是文件名 | P5 ✅ 规则实测（25）+ 端到端实测 |
| 外观 | 主题驱动整个 App（chrome/选中/强调色）、主题导入（粘贴/QR/深链）、光标形状与闪烁、CJK 字形回退、备选 App 图标 | P4 ✅ 实测 |
| 外观 | **Glass Effect**（Settings → Toolbar → Display）：关掉系统玻璃材质、改用主题自身颜色的不透明面。**iOS 26 上是真系统行为**（`.glassEffect` / `buttonStyle(.glass)` 是 26 独有）；**26 以下是诚实的部分生效**——系统自己画的导航栏材质没有关掉的开关，所以设置页直接写明"只影响键盘栏"，而那一条栏是**我们自己的视图**，任何版本都照着切。默认**开**（用 `object(forKey:)` 而非 `bool(forKey:)` 读取，否则未设置的键会读成 false，把每个存量安装的外观重置一遍） | P5 ✅ 规则实测（7）+ 同步配对检查 + 界面实测（开/关两种状态各截一次，预览与键盘栏都跟着变） |
| 终端 | 鼠标滚轮手势（双指拖动转 wheel）、滚到底收键盘 | P5 ✅ |
| 会话 | 会话持久化、切后台恢复、断线重连 | P1–P2 |
| 多路复用 | tmux 集成、会话选择器、jump-to window | P2 |
| 多路复用 | **tmux prefix 可配置**（Settings → Multiplexer，Ctrl-B / Ctrl-A / Ctrl-Space）：Jump-To 与 ⌘数字是**发前缀键**而不是敲命令，故前缀必须与宿主 `tmux.conf` 一致 | P5 ✅ 规则实测 + 端到端实测 |
| 多路复用 | **窗口快捷行**（key bar 上方，tmux 窗口 1–9 一点直达，可在 Settings → Input 隐藏）：**仅对 session command 判定为 tmux 的宿主显示** | P5 ✅ 端到端实测（tmux 显示 / zellij 隐藏） |
| 多路复用 | zellij / herdr 支持 | P5 |
| Agent 层 | cqutmux-hook 网关 + agent 事件捕获 | P3 |
| Agent 层 | Chat View（Inbox）、approvals、teammate 卡片 | P3 |
| Agent 层 | Diff Viewer、文件浏览器、浏览器预览、模拟器预览 | P3 |
| Agent 层 | Usages 看板（5h/7d 用量与 burn pace） | P4 |
| Agent 层 | **Inbox 看板**：Needs you / Working / Done 三栏、**一个会话一行**（新事件并入而不是堆行）、按项目分组、**归档**（完成 10 分钟、任何东西 6 小时、左滑立即归档） | P5 ✅ 规则实测（79）+ 端到端实测 |
| 通知 | 本地/远程推送、webhook 告警 | P4 |
| 系统 | Live Activity / Dynamic Island / Apple Watch | P4 / P6 ✅ 表盘实测 |
| 系统 | **Apple Watch 两个页签**：Inbox（原有）+ **Usage**（每账号限额环、显示最紧的窗口、色带绿/橙/红、含"更新于"）；手机每 3 分钟推一次用量到 `applicationContext`，与审批各自独立 | P6 ✅ 界面实测 + 端到端回归 |
| 语音 | **听写历史**（TranscriptionHistory，最近 20 条，可重新发送/复制/删除；**只记听写，不记键入或粘贴**，故 sudo 密码不会进列表） | P4 ✅ 规则实测 + 界面实测 |
| 语音 | 听写四引擎（**Parakeet ✅ + Apple Speech ✅ + whisper.cpp ✅ 端侧三引擎实测**；**Cloud ✅ 指向用户自填端点，已对真实 HTTP 服务端到端实测**——Moshi 的托管端点本身是服务不是代码，故按"机制对齐"实现） | P4 ✅ |
| 输入 | 图片粘贴 / 裁剪 / 标注 / 发送 | P4 |
| 安全 | SSH key 存 Keychain + Face ID 保护 | P1 |
| 安全 | 重开需生物识别（后台 >30s）、key 导出页（显式空缺） | P4 ✅ 实测 |
| 同步 | iCloud 设置同步（hosts/主题/字体/光标/布局/引擎；冲突合并；**载荷无密钥**）；凭据同步显示但禁用并说明 | P4 ✅ 实测 |
| 宿主 | `cqutmux` CLI（`<dir>` 起 tmux / `diff` / `status` / `doctor` / `logs` / `serve` / `install` / `pair`），裸调用仍是网关 | P5 ✅ 实测 |
| 宿主 | `pair` 生成/复用 `~/.ssh/cqutmux_ed25519`（**独立密钥，绝不碰用户自己的 `id_ed25519`**）、只把公钥写进 `authorized_keys`、打印可扫描的二维码与链接 | P5 ✅ 规则实测 + 端到端实测 |
| 输入 | 粘贴文件历史与复取（宿主 `/uploads`、`/upload`、`DELETE`；App 侧 Pasted files 页）。**不做**：对外可分享的 HTTPS 短链（那是托管服务） | P4 ✅ 宿主实测 / App 侧未在线实测 |
| 宿主 | 网关配置文件 `[gateway]`：发现/用量采集/嵌套 agent 抑制/扫描端口范围；标志优先于文件 | P5 ✅ 实测 |
| 通知 | 通知设置页：权限状态、暂停（客户端强制）、测试通知、远程推送状态 | P4 ✅ 实测 |
| 其他 | 远程剪贴板 OSC 52、Tailscale、iPad 分栏 | P5 |
| 其他 | **Support 页**（Settings → Help → Support）：把报告要用的东西凑齐——App 版本、**硬件标识**（`uname` 的 machine 串，如 `iPhone17,1`；`UIDevice.model` 只肯说 "iPhone"，分不出有机子的那个和没机子的那个）、系统版本、已连接主机与传输方式、**网关健康**（`GET /health`，走已有的那条 SSH 通道，不另开连接）。规则是**先显示再复制**——报告文本以 monospace 原样列在页面上，因为它是从本机状态拼出来的，只有发的人能判断哪一行不该发出去。**不包括**网关 token 与 SSH 私钥，页脚明写 | P5 ✅ 界面实测（文本与设备行）+ `GET /health` 已实装 |

### 1b. 逐项复核（2026-10-09，对照 getmoshi.app 全部 42 个文档页）

复核时把 Moshi 的功能清单逐条对照代码，**已实测确认存在**（此前 PLAN 未记载）：
OSC 52 远程剪贴板（注入 `\033]52;c;<b64>\007` 后宿主剪贴板确实被改写，经 SwiftTerm 的 `oscClipboard` → 我们已有的 `clipboardCopy`）、
tmux 会话选择器（`SessionPickerView`）、
Diff / 文件浏览 / 浏览器预览 / 模拟器预览（`CodePanelView` + `PreviewView` + `SimulatorPreviewView`）、
Live Activity 与灵动岛（`ActivityManager` + `AgentActivityAttributes`；**注意：这一条当初记成"已实测确认存在"是错的**，见 4b 表中「Live Activity 设置与自检」——plist 缺 `NSSupportsLiveActivities`、错误又被 `try?` 吞掉，它其实从未启动过，2026-10-09 才真正跑通）、
图片粘贴与标注上传（`ImageAnnotatorView`）、
主题与字体持久化、iPad 侧栏、CJK 输入。

**本轮新增：输入自定义（Settings → Input）**。`InputSettings` 三件事放进同一个 store，
因为它们是同一个问题——栏里显示什么：① **Option 当 Meta**；② **栏内按键的增删与排序**
（Ctrl/Esc/Tab/方向/粘贴/图片/会话/听写/自定义键）；③ **D-pad**（四向箭头 + 两个可绑定角，
默认左上 Esc、右上 Del，另可选 ^C 与收键盘）。附 `showsBar(hideWithHardwareKeyboard:hardwareKeyboard:)`
在接了硬件键盘时收起整条栏。

**Option-as-Meta 的做法值得记一笔**：字节到达 `send(source:data:)` 时，键盘**早已把 Option+e 合成成 "é"**，
所以 ESC 前缀不能加在按键上，只能从合成字符**反推**——走一遍 NFD，丢掉组合音标就得到用户按住
Option 想修饰的那个字母。因此「含任何 ASCII 就整串放行」是刻意的：混了 ASCII 的字符串不是一次按键，
而是一次粘贴，改一半会把它弄坏。这条规则也决定了怎么验：
`CQUT_DEV_TYPE` 把整句 UTF-8 写进去，永远只走粘贴分支，**测不到 Meta**；
故新增 `CQUT_DEV_TYPE_COMPOSED` 逐字符调用 delegate（键盘真实的调用形状），
实测宿主 `cat -v` 打出 `^[e`——即线上确实是 ESC + e。
`scripts/input-check.sh` 66 项覆盖以上全部规则（含「普通打字不会被改写」这条最要命的）。

**又补上一处会静默出错的缺陷：tmux prefix**。Jump-To 与 ⌘1-9 打开窗口的方式是**发前缀键**
（让 tmux 去解释，而不是把命令敲进可能正被 agent 占用的 pane），可前缀此前**硬编码 Ctrl-b**——
用户 `tmux.conf` 里写了 `set -g prefix C-a` 的话，跳转会：tmux 收不到有效指令、而那个数字
**落进当前正在跑的程序**（通常是 agent）。无日志、无报错，症状只是"跳不过去，而且好像多打了什么"。
现 `MuxSettings.Prefix` 三选一，`selectWindow` 带上前缀，⌘p/⌘n 与 ⌘数字也一并改用它。
端到端实测：宿主 `cat -v` 在 Ctrl-A 下发 `^A3`、Ctrl-B 下发 `^B3`。
`scripts/mux-check.sh` 20 项覆盖字节算术（`key & 0x1F`）、去重、以及**未知前缀回退而非失败**。

**同轮加上窗口快捷行**：key bar 上方一排 1–9，一点直达 tmux 窗口。它**只对 tmux 宿主显示**——
因为它发的是 tmux 前缀键，对 zellij/herdr 会话来一下就是往 pane 里塞控制字符，与上一条是同一类错误。
**这里正好踩中一个真 bug**：判定最初写成 `sessionCommand.contains("tmux")`，而**我们自己的默认 zellij 命令是
`zellij attach -c cqutmux`——会话名里带 tmux**，于是每个 zellij 宿主都会拿到一排 tmux 按键。
改成按"命令行首/分隔符后的词"匹配（并剥掉路径），`scripts/mux-check.sh` 里 17 项专门覆盖这个判定，
包括拿**我们自己的三条默认命令**去测。模拟器实测：tmux 宿主显示、zellij 宿主隐藏。

**听写历史**：Moshi 的 `/docs/voice` 明确有「transcription history」。实现为 `TranscriptionHistory`（上限 20 条、
连续重复折叠、重复旧条目上移而非再存一份）。关键取舍是**喂数据的入口**：只在 `Dictation.onUpdate` 的 `.final`
里记录，**不挂在终端输入通路上**——后者会把用户在 `sudo` 提示符下键入的密码也收进去，而没有人要"听写历史"时
期望是这个。`scripts/history-check.sh` 24 项覆盖上限（含"正好等于上限时不丢"）、折叠、重启往返、以及
**存储损坏时退化为空而不是崩溃**。

**Inbox 看板**（Moshi `docs/agents-usages`：三栏板 + 会话合并 + 归档）。此前 Inbox 是**一条事件一行的流水**，
那等于把阅读的活交给用户：一个会话二十条事件就是二十行，真正在等你回答的那条混在中间，而且从此永不消失。
现按 Moshi 的规则重做——`InboxBoard.swift`（只依赖 Foundation，故 79 项规则可无宿主驱动）：

- **三栏**：有待答 approval/问题 → Needs you；**已答的 approval → Working 而非 Done**（答了意味着 agent 刚开始做，
  不是做完）；其余 → Done。本 App 自己的"approval allow"通知**不参与定栏**——它是完成形状的，读成完成会让每行
  在刚被回答的瞬间跳进 Done，Working 永远看不到。
- **一行一会话**：按 `data.session` 合并（agent 的 hook 本来就在发）；没有 session 的旧 hook 退化成"每个 source 一行"，
  而不是每条事件一行。新的在前，**读不出时间戳的行排最后**（放进一个损坏的行比漏掉它更糟）。
- **归档**：完成 10 分钟、任何东西 6 小时封顶、左滑立即归档；**待答的行不受 10 分钟约束**——
  Moshi 的规则是它一直 Active 直到被回答或宿主超时，六小时是"宿主超时"的替身。
- **按项目分组**：用 hook 里的 `cwd` 的**最后一段**（`/Users/…/work/api` → `api`；表头要说的是哪个仓库，不是完整路径）。
  只有一个项目时不画表头——一行分组标题盖住每一行只是噪音。

**这一轮抓到三个真 bug，其中两个只有真机跑起来才会露出来**：

1. **给 `Payload` 加 `CodingKeys` 时漏了 `options`**。Swift 里一旦手写 `CodingKeys` 就必须列全，漏掉的键**静默变成 nil**
   ——于是每个"多选问题"都渲染成 Allow/Deny。它看起来和"agent 没给选项"完全一样，所以 47 项单测全绿也照样错；
   **是我看截图才发现的**（`scripts/inbox/main.swift` 里的检查是**直接构造 Payload**，根本不走 decode，看不见这类错）。
   现在补了一段**按网关真实写法 decode** 的用例，这条路由才有人守。
2. **别处回答的 approval 永远卡在 Needs you**。轮询是 `id > lastId`，**已经在本地的事件永远不会被重发**，
   所以"后台去看表盘/另一台手机回答/宿主超时"之后，这个设备只收到一条网关的 notice，而那条 notice 原本只带 `for: id`。
   真机实测：后台点掉 approval 1，回来那行**仍在 Needs you**。修法是两层：网关把 `decision`/`answer`/`session`
   带在 notice 上，App 侧再把 notice 折回它指向的那条事件（`InboxBoard.folding`），然后**把 notice 本身丢掉**——
   它是我们的记账，不是用户会话里发生的事，留在行里会抢占行摘要（截图上一行写着 "CQUTmux · approval allow"）。
3. **`HookClient.resolve` 把网关返回的那条已更新记录扔了**。`/approve/:id` 返回的是**改过的**那条，客户端却忽略了返回值；
   加上轮询不会再发旧 id，本机自己点的回答也不会反映到自己界面上。现在合并回来。

另外顺手修掉 `relative()` 把"未来几秒"显示成 "in 3s" 的问题（设备时钟比宿主慢几秒，刚到的每条事件都成了倒计时）。

**One honest limit**: the 10-minute and 6-hour expiries are checked as rules but not observed live — none of the live
screenshots ran for ten minutes, so "an old row archives itself" is reasoned and unit-checked, not seen.

**自定义字体导入**（Moshi 的 Settings → Terminal Fonts → Import font…，Pro 功能）。
两处取舍都会**先能跑、以后再坏**，所以都写进了检查脚本：

- **拷贝而不是引用**。文档选择器给的 security-scoped URL 只在回调期间有效，而终端每次重绘都要解析字体，
  可能是几天后。引用它的实现测试当天完全正常，重启即失效——所以文件被拷进 Application Support 下的 `Fonts/`，
  注册的是这份拷贝。
- **名字取自字体，不是文件名**。`JetBrainsMono-Regular.ttf` 与 `jetbrains-mono.ttf` 是同一个字体，
  而从 zip 里解出来的字体文件常连这两个名字都不是。存下来的必须是 `UIFont(name:)` 之后要找的那个名字，
  否则导入"成功"、渲染成系统字体，用户只会觉得"这个字体不好看"。做法是 `CGFont.postScriptName`。
  显示名走 `CTFontCreateWithGraphicsFont` + `CTFontCopyFamilyName`——**iOS 上 `CGFont` 没有 `familyName`**。
- **非字体文件在导入时就拒**（`CGFont(provider)` 解析失败），而不是等到渲染时静默回退。

`CustomFontStore` 只 import Foundation + CoreText，**完全不碰 UIKit**（对外暴露 `postScriptName(for:)` 而非 `UIFont?`），
所以 `scripts/fonts-check.sh` 25 项无需模拟器即可跑：真实系统字体导入成功、PostScript 名来自字体、文件是拷贝、
重启往返、`.txt`/假 ttf/缺失文件全部被拒、重复导入不产生两条、删除同时删文件、以及**存下的名字能经
`CTFontCreateWithName` 原样解析回来**（而不是被静默替换成别的字体）。
模拟器实测（`CQUT_DEV_IMPORT_FONT` 注入，因为文档选择器无法被任何 simctl 命令驱动）：
列表与 Family 选择器都出现 `Courier New` / `CourierNewPSMT`——**两个名字都不是文件名 `Courier New.ttf`**，正是要验的那点。

**顺带修掉一个测试自身的缺陷**：`InputSettings` 原本硬写 `UserDefaults.standard`，
于是 `scripts/input-check.sh` 既会**改掉跑它的人的设置**，又会把上一次跑剩下的值读回来当输入，
表现为两条随机失败。现 `init(store:)` 可注入，检查脚本用自己的 suite 且先清空——三次连跑结果一致。

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

**`install` 会替用户把 agent hook 写进配置**（对照 Moshi `moshi-hook install`："writes Moshi-owned entries
into supported agent config files"，且**不动用户自己的 hook**）。我们此前只有一个 `claude-code-hook.sh`
脚本，用户得**手改 `~/.claude/settings.json`**——这一步现在由 `install` 完成：
按**命令字符串里是否含本脚本路径**识别自己的条目，于是用户自己的 hook 原样保留、我们的可原地更新而非叠加；
写之前先留一份 `.cqutmux-backup`；**配置文件解析失败就拒绝写入并退出非零**（看不懂的文件是用户的，
猜着改比不改更糟）；`--dry-run` 只打印不落盘。

**实测**：`scripts/cli-check.sh` **18 项**全绿，可重复运行（连跑两次均通过）。该检查抓到**三个真 bug**：
① **`--port 24880` 的值被当成位置参数路径**——扫描位置参数时没有跳过带值标志的值，
   于是"裸调用"直接变成"打不开目录 /private/tmp/24880"；
② **`serve` 什么也不做就退出**——分派分支无条件 `process.exit(0)`，于是 `serve` 既没启动网关、
   又返回成功；现改为 `serve` 不进入分派、直接落到服务器代码；
③ 脚本自身的**端口争用**（后台 `node ... &` 记录的是子 shell 的 pid，`kill $!` 杀不掉 node），
   让 `status` 检查在上一轮残留的服务上"通过"——现按 pid 杀并让这个检查自带端口占用检测。
**另实测**：把 `claude-code-hook.sh` 接在真实网关前，喂一份 Claude Code 的 PreToolUse 载荷，
`GET /events` 确实拿到 `title: Write` / `kind: approval` / `data.session`（不是"脚本退出 0"就算数）。

**本轮新增：粘贴文件列表（`GET /uploads` + App 侧 Pasted files 页）。**
对照 `docs/files` 又核出一处缺口：Moshi 的 Files 是"粘贴盘"——上传后给一个**短期有效的 HTTPS 短链**，
并能从**最近上传历史**里重新取用。我们此前 `POST /upload` 只把文件写进宿主 `~/.cqutmux/paste/`，
**目录是只写的，没有任何读回路径**——同一张截图要用第二次就得重传，这正是历史列表存在的意义。
现补上能诚实补的那一半：宿主 `GET /uploads`（按时间倒序）、`GET /upload?name=`（取字节）、
`DELETE /upload?name=`；App 侧 `UploadsView` 列出缩略图/大小/相对时间，点按复制宿主路径、可滑动删除。
**没补的那一半说清楚**：本 App **不提供**把文件对外用 HTTPS URL 供出去的服务，
所以设置页脚注直说这些是**宿主路径**，只有跑在同一台机器上的 agent 能直接读——
把宿主路径包装得像一个可分享的 URL，比没有这个功能更糟。
`/upload` 的 name 参数来自客户端，故凡含 `/`、`\` 或以 `.` 开头一律拒绝（实测 `../../etc/passwd` 与 `.hidden` 均被拒），
不做路径归一化。
**实测**：宿主三个端点用 curl 跑通（上传→列表→取回→删除→列表计数正确）；
**未实测**：App 侧该页面的**在线渲染**——网关是经 SSH 通道（`direct-ssh`）到达的，
要截图需在模拟器里搭一套真 sshd + 网关 + 传输，代价高于这一步的价值，故如实记为未验证。

**本轮新增：网关配置文件（`~/.config/cqutmux/config.toml`，`[gateway]` 段）。**
对照 `docs/hook-settings` 补齐 Moshi 的五个持久化设置：`always_on_discovery`、`usage_collection`、
`suppress_nested_agent_push`、`scan_ports`（`all` / `none` / 单值 / `"3000-3010"` / 数组）。
**标志优先于文件**（否则"覆盖"就不叫覆盖），且**无文件时行为与从前完全一致**——这是加选项，不是加前提。
两个语义上必须讲清楚的点：
- `suppress_nested_agent_push` 关掉的是**整个事件**（含审批），不只是横幅——
  只静音的话，一个真的在等回答的嵌套 agent 会既被消音、又在 App 里留个待审批，比不做更糟。
- `scan_ports` 是**真的不下发**：范围外的端口从 `/ports` 里被过滤掉，而不是"扫到了但不显示"。
**自写 TOML 读取器**只认段名、`key = value`、字符串/数字/布尔/数组——不是通用 TOML，也不声称是：
网关无依赖是刻意的，五个键不值得引一个解析库。`doctor` 会报出**配置文件是否被读到、认出了几条**，
因为"文件在、却一条也没解析出来"这种状态看着像配好了、其实没有，正是要抓的。
**实测**：`scripts/cli-check.sh` 增至 **23 项**，可重复运行。抓到一个真 bug：
`scan_ports = [3000, "5173", "8000-8010"]` 里**数组中的范围被当成字面量**，
8005 被错误过滤掉（数组走 `includes`，范围匹配只在顶层字符串路径上做）——现已统一为"单个条目与列表中条目同样解释"。
另实测：开启抑制后嵌套事件返回 `{"suppressed":true}` 且不出现在 `GET /events`，顶层事件照常；
默认（无配置）不抑制；`scan_ports` 范围内外分别被保留/剔除。

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
| P5d 内嵌字体 | ✅ 已合并并**实测** | 四个族共十款字面（JetBrains Mono 四款、Ioskeley Mono 两款、Iosevka 两款子集、DejaVu Sans Mono 两款，约 9.4MB）随包发布，`UIAppFonts` 十项落在 bundle 根目录，默认族改为 `JetBrainsMono`。**与 Moshi 的有意分歧**：后三个族是内嵌而非首次选择时下载——Moshi 自己也称 JetBrains Mono 是 embedded，而用户没要过的下载比大 9.4MB 的包更糟。`scripts/fonts-bundled-check.sh` 94 项直接读字体二进制的 `name`/`cmap` 表（无需字体库、无需模拟器），字形下限**按四款里最弱的实测**而非凭记忆（我第一版凭记忆写错两次，方向都一样）。设备那一半（Core Text 是否真的接受）由 `CQUT_DEV_FONT_PROBE=1` 在模拟器实测：四族都解析到真实字面 |
| P5e 模拟器实时触控 | ✅ 已合并并**实测** | 预览从"只看"变成"能操作"：手机上的点按/拖动/双指缩放经 SSH→网关→`IndigoHID` 注入到宿主的模拟器。iOS 无公开接口（`simctl` 能截图不能点击），故唯一路径是 CoreSimulator 私有 API，且它只能在被 ObjC runtime 接管的进程里加载（node 里 dlopen SimulatorKit 直接崩）——所以做成独立 helper `host/cqutmux-hook/simtouch/`，网关首次用到时用 `xcrun swiftc` 现场编译，每个模拟器一个子进程，闲置 5 分钟回收；调用序列参照 serve-sim 的 Apache-2.0 `HIDInjector`（Moshi 文档自己指定的模拟器预览工具）。**踩到的真坑**：第一版 helper 每次都回 `{"ok":true}` 却一个事件都没送到——send 走 XPC，进程在 run loop 转起来前就退出了；此外 down 与 up 之间必须是 `usleep`，换成 run-loop turn 会在触摸中途服务设备连接而丢掉触摸。两者对"只看 helper 回复"的任何检查都是隐形的，所以 `scripts/simulator-touch-check.sh` 的断言是**手势前后的两张截图不同**。App 侧是带 tap/pan/pinch 手势识别器的 `UIViewRepresentable`，Control 开关默认关；坐标必须按**装帧后的实际矩形**映射（用 view bounds 会整体偏移，表现为"中间能点、边缘点不中"）。`scripts/simulator-touch-app-check.sh` 双阶段实测：①经 view 自己的 `send` 发手势；②用真触摸打在手机预览上，跑通识别器与坐标映射 |
| P5b Jump host | ✅ 已合并并**实测** | 在跳跃主机上开 `direct-tcpip` 到目标的 22 端口，把目标 SSH 连接跑在该通道内（`ByteBufferToSSHDataHandler` / `SSHDataToByteBufferHandler` 做 `ByteBuffer`↔`SSHChannelData` 互转）。实测：两条本机 sshd (`:2222` 为跳板，`:2233` 为目标)，`lsof` 确认应用只连 `:2222`、`:2222`→`:2233` 由 sshd 转发；杀掉跳板会话后 UI 报 `jump host … Connection refused` 并自动重连成功；不带跳板的直连路径回归通过 |
| P6 Apple Watch | ✅ 已在 watchOS 模拟器**实测** | `CQUTmuxWatch` watchOS target：待审批列表 + 批准/拒绝，经 `WCSession` 与手机同步，决定回落到手机上的 `HookClient.resolve`。**已跑通完整回路**：手机 Inbox 的待审批经 `updateApplicationContext` 推到表盘并渲染；表盘上的决定经 `sendMessage` 回到手机，手机发出 `POST /approve/3`，网关侧 `decision=allow` + `resolvedAt` 落库。**模拟器限制（非 App 缺陷）**：`simctl` 只把 watch app 装进表盘容器，不会执行真机上的"手机代表表盘安装"那一步握手，于是 phone 侧 WCD 的 `WCDStoredInstalledWatchApps` 始终为空，`updateApplicationContext` 直接以 `WCErrorCodeWatchAppNotInstalled` 失败（`appInstalled: NO`）。实测前需先手工补上该记录并重启 `com.apple.wcd`；代码本身无需改动。真机由系统完成该握手，不存在此问题 |
| P6b 表盘 complication / Smart Stack | ✅ 已合并并**实测** | 数据一向有（`WatchPayload` 算配额百分比），缺的是 watchOS 上的消费方：新增 `CQUTmuxWatchWidgets` app-extension target（watchOS widget，`StaticConfiguration(kind:"CQUTmuxUsage")`，四个 accessory family，`widgetURL` 指向新增的 `cqutmux://usage` 深链），内嵌进 watch app（因而也随手机包走）；`AgentActivityView` 加 `supplementalActivityFamilies([.small,.medium])` 并按 `@Environment(\.activityFamily)` 分流，同一个 Live Activity 既上锁屏也进手表 Smart Stack。两个手表进程靠 **App Group**（`WCSession` 的 context 对 widget extension 不可用）共享数据，`Watch/ApprovalListView` 每次写入后 `reloadAllTimelines()`。`cqutmux://usage` 在**两台设备上实测**：手机落到 Usages、手表落到 Usage 页。**诚实的边界**：complication 是否真的**被摆到某个表盘上**是用户在表盘上的动作，无法无头观测，故 `scripts/watch-complication-check.sh` 断言的是构建能弄错的东西（kind、四个 family、深链、两个 target 的 entitlement、代码读的 group 与 entitlement 声明的一致、appex 的 `NSExtensionPointIdentifier`），不宣称表盘上真的显示了；模拟器在 `-` 签名下会丢掉 App Group entitlement，故共享容器为 nil——读取返回 nil 而非崩溃，complication 显示 `—` 而不是假的 0。`scripts/watch-usage-check.sh`（27 项）覆盖共享容器往返 |
| P6e 主机 locale | 🟡 半程 | Moshi 的 claim 是两半：把 `LANG`/`LC_ALL` 设成 UTF-8，**并且**写进 `~/.zshenv` / 非交互 `~/.bashrc` 让 agent 自己 spawn 的 shell 也继承。前半已做：`IntegrationSettings` 存一个 locale，同时推出 `LANG` 与 `LC_ALL`（**成对**——宿主 `/etc/profile` 若自带 `LC_ALL`，只发 `LANG` 会被它盖掉，而那正是 locale 出错最要命的宿主）；值走三条通路：SSH 的 environment 请求、mosh 的 `-l` 列表（此前启动器**硬编码** `LANG=en_US.UTF-8` 并 `guard name != "LANG"` 跳过配置值——设置看起来生效了其实被丢掉）、以及首个提示符处键入的那几行。默认**空**，和 client marker 默认关同一个理由：给一个没装该 locale 的宿主设 locale 会让每条命令前面多一行 `setlocale` 警告，默认打开等于把升级变成回归，而且恰好砸在最可能缺 locale 的精简宿主上。locale 只在「是 UTF-8 名字且只含 locale 字符」时才发——值是不加引号贴进 shell 行的，所以 `C`（会把终端弄成乱码）和 `en_US.UTF-8; rm -rf /` 都是**丢弃**而不是清洗。<br>**写检查又抓到一个真 bug**：`isUTF8` 一路读到名字末尾，于是把 `UTF-8@euro` 当编码，凡是带 `@修饰` 的 locale（如 `de_DE.UTF-8@euro`）全被拒。`scripts/integrations-check.sh` 从 13 项扩到 41 项，把该修复回退恰好只红那一条。App 构建通过。<br>**仍未做**：后半——rc 注入。全仓没有写 `~/.zshenv`/`~/.bashrc`/`~/.profile` 的代码，gateway 的 `install` 只改 `~/.claude/settings.json`、`pair` 只追加 `authorized_keys` |
| P6f 各 agent 用量窗口 | ✅ 已合并 | 此前**每个 source 都按同一组固定 5h/7d**（那是 Claude Code 的限额，却替别的 agent 也这么宣称）。新增 `host/cqutmux-hook/usage.mjs` 按 hook 实际发出的 source 串持有窗口集：Claude Code 保持 5h/7d；Codex 是可变的「人类标签」集（`5h`、`weekly`——文档给的标签是 weekly 不是 7d）；Kimi Code 周窗；Grok Build 是 **credit 窗口**并带 `credit: true` 标记（余额不是随时间变化的速率，按百分比显示会被读成「会回充的限额」）；OpenCode 给单个与 provider 无关的 rolling 窗，而不是编一对它未必有的 5h/7d。未建模的 agent 回落到 Claude 那组——空卡片会被读成「没有用量」，那是另一个且为假的陈述。标记贯通两端：`HookClient.UsageWindow` 解码它（带默认值，旧 host 仍能解），手机端显示 `% credits`，并经共享 payload 到手表显示 `% cr`。窗口长度取自 getmoshi.app 对 Usages 页的描述（Claude Code 「fixed 5h and 7d」、Codex「a variable set of windows with human labels」、OpenCode「provider-dependent」、Kimi/Grok「weekly / rolling or SuperGrok credit windows」）；cap 仍是本 host 观测到的事件数——hook payload 也只带得来这个。`scripts/usage-check.sh`（29 项）纯 node 跑、不起网关；把 `windowsFor` 改成对所有 source 都返回默认值（即这次要修的那个 bug）会红 7 条 |
| P6g 监听端口元数据 | ✅ 已合并 | 此前端口扫描只返回**裸端口号**，手机再对一个写死的集合（3000、5173…）无条件打上 `dev` 标签——既不认识你启动的那个 server，也和系统 daemon 分不开。新增 `host/cqutmux-hook/listeners.mjs`：把 `lsof`/`ss` 解析成带**进程命令、pid、绑定地址**的 socket，再对每个候选端口做一次有界的 HEAD 探测，给出**框架标签**；`describe()` 合并成「一个端口一行」（具名的 lsof 行胜过 `ss` 的裸行），并给出 `scope`（loopback/all/address）。`index.mjs` 的 `listeningPorts` 现在返回 `{ports, listeners}`——裸 `ports` 保留给旧版 App。App 侧 `PortBoard` 增加 `Listener`（带默认值，旧 host 仍可解），`PreviewView` 在端口旁显示框架名或命令名，并对**只绑 loopback** 的监听打一把锁——那种 server 即使端口开着，隔着 SSH 也够不着。<br>**写检查又抓到真 bug**：`lsof` 打的是内核里的进程名，`Google Chrome` 是**跨两列的一个命令**，第一版按空白定列切分，于是报出一个不属于任何东西的 pid；改为**锚定第一个全数字字段**。`scripts/listeners-check.sh`（43 项）纯 node 跑；把「命令一定不含空格」假设回去恰好只红那 2 条 |
| P6d 手表 Inbox 分组 | ✅ 已合并 | 手机看板自 `InboxBoard.groups(in:)` 起就按项目分组，但**推给表盘前先被拍平**：`WatchPayload.Snapshot.Item` 只有 id/source/title/body/options，表盘画一张平表，表头根本过不了线。现在带着 `project` 与 `at`，由 `Snapshot.groups` / `isGrouped` 在手表侧分组。顺序**照抄手机的优先级**：有待答的先（表盘上每条都待答，故此项为空操作）、无项目的一组垫底、其余按新鲜度新→旧。**有一条故意不等于手机**：新鲜度相同的两个具名组按名字排——手机的 comparator 在这时退化成比时间戳，而相等的时间戳把它交给字典迭代顺序，而这张表每次推送都从字典重建，于是同两个项目可能在注视下互换位置。<br>**写检查时抓到 comparator 一个真 bug**：第一版把新鲜度排在「无项目垫底」之前，于是「最新的一条属于无项目组时它仍应垫底」这条失败了——改的是代码，不是检查。<br>该 claim 还要求工具栏图标反映**是否有事件在等**：`WatchRootView` 尾部的图标原是静态 `tab.icon`，报的是**当前页签**，空 Inbox 也显示 `tray.full`——一个在每次抬腕时都声称「有活」的标记，比什么都不显示更糟。现在是 `WatchPayload.inboxGlyph(hasItems:)`。由 `scripts/watch-inbox-check.sh`（26 项）钉在 watch target 也编译的那份 Foundation-only payload 上；同一套分组规则在 `ApprovalListView` 里落成 `ForEach(groups) { Section { ForEach(group.items) } }`，只有一个组时不画表头。<br>**顺带发现 `docs/parity-audit.json` 的 `counters` 字段比逐条状态落后了三条**，本轮改为从条目重算 |
| P6c 键盘栏键 | ✅ 已合并 | 补上输入栏缺的另一半：原只有「收起键盘」键，而终端里**没有任何东西能把键盘叫回来**——点终端的触摸先被手势识别器吃掉，到不了 responder——所以按一下就是单向的。新增 `Show keyboard` 键，调 `showKeyboard()`：已是 first responder 时用 `reloadInputViews()`（此时 `becomeFirstResponder` 是 no-op），否则才 `becomeFirstResponder()`。两个键都默认关、都进 `optInItems`（Moshi 的默认栏只有一个形状）。`scripts/input-check.sh`（93 项）钉住条目、标签与"每个 case 都能从设置页打开"的不变量。**诚实的边界**：按键动作未做屏幕断言——输入栏的屏幕位置随键盘 frame 移动，脚本无从得知，按坐标点的键会打歪（实测在终端里留下一个多余的 `%`），故不围绕猜出来的像素写检查。顺带实测确认注入本身没问题：点输入栏的 Return 键真的换出了新提示符 |
| P5f 标签快捷行 / 多路复用手势 | ✅ 已合并并**实测** | **审计里 3 条（zellij 标签行、双指切换 pane、双指切换 session）此前记错了**：哈希枚举的是 UIKit 自带识别器，漏了自写的 `UISweepGesture`，而 herdr 独立前缀与手势**在 `edf2834` 就已实现**——审计文本没跟上代码。本轮真正补的是**标签快捷行**：原来只对 tmux 显示且只有 9 个，现在三个多路复用器都显示 20 个按钮（`MuxCommand.selectableTabs`），映射收在 `MuxCommand.selectTab` 一处——tmux 发「前缀+裸数字」（10 以后走命令提示符），herdr 发自家前缀+数字（9 以后发 `herdr tab focus N`），**zellij 没有前缀，发 `Ctrl-T`+数字**（那是它的 tab 模式键，而不是其它 zellij 命令用的 `zellij action` 行——那行要 shell 来跑，而 TUI 在前台时 shell 没有焦点）。`scripts/tab-row-check.sh` 两半：映射 19 项跑解释器，投递用真 sshd + `cat -v` 在宿主上读数（tmux 得 `^B5`、zellij 得 `^T5`）。**踩到的真坑**：zellij 第一次读数只看到裸 `5`，看着像控制字节被吞——其实是**仪器在骗人**：带行编辑的 shell 下 tty 处于 canonical 模式，readline 没有绑定的控制字节会在任何程序看到之前就被丢掉，数字因为是文本才活下来；`stty raw -echo` 后 `^T` 就出现了。与模拟器触控那个 `{"ok":true}` 是同一类错误：从一个看不到正结果的仪器上读出负结论 |

**真机构建：此前记的"已知缺陷"是错的，本轮撤回。**
旧记载说 `generic/platform=iOS` 失败于
`AppIcon did not have any applicable content`，根因归为 watch target 的 product type 是泛用的
`com.apple.product-type.application`（应为 watch 专用类型），导致真机嵌入步骤用 **iphoneos 平台**去编 watch 的 asset catalog。
**本轮重测：不成立。**留在此处的旧派生目录会把这个错误喂回来，删掉后：

- `rm -rf build && scripts/build.sh`（模拟器）→ **BUILD SUCCEEDED**
- `xcodebuild -destination 'generic/platform=iOS'`（全新 `-derivedDataPath`）→ **BUILD SUCCEEDED**，
  产物 `CQUTmux.app/CQUTmux` 为 arm64，`CQUTmux.app/Watch/CQUTmuxWatch.app` 正确嵌入，
  watch 二进制的 Info.plist 带 `WKApplication=true`、`CFBundleIdentifier=app.cqutmux.ios.watchkitapp`，
  架构 fat（arm64 + arm64_32）——即真机切片是齐的。
- 把同样的真机构建放进**已经被模拟器构建用过的** `build/` 目录，也成功。

即：这不是缺陷，是一份旧派生数据。当时"非本轮引入、模拟器全绿"的自证（`git stash -u` 后 HEAD 复现）**没能区分"HEAD 有缺陷"与"HEAD 加脏派生数据有缺陷"**，
而这两者恰恰是这次要分清的东西。教训记在这里：复现构建错误前先清派生目录，否则复现的是缓存。）

**唯一仍然成立的一半**：`type: application.watchapp2` 确实会让**模拟器**构建坏在
`Multiple commands produce .../Debug-watchsimulator/CQUTmuxWatch.app/CQUTmuxWatch`（本轮重测复现，去掉 `embed: true` 也一样）。
但既然当前泛用类型两边都能编，这一条就没有要修的对象了——**保持现状**。
（真正没验证过的是**签名后的真机安装**：本机无付费账号，`CODE_SIGNING_ALLOWED=NO` 只能证明到"编译与嵌入正确"这一步。）

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

**本轮新增：Easy Pair**（Moshi 的设置项，文档原话是"only sets up SSH/Mosh host access"，并把连接和**它自己的密钥**一起保存）。
这是长期以来"连接要靠手填五个字段加一把私钥"的那个缺口。

- **格式是一个 URL**（`cqutmux://pair?v=1&host=…&user=…#key=<base64 seed>`），不是 JSON。
  理由：`cqutmux://` 本来就是 App 注册的 scheme，于是**同一个字符串既是相机读到的东西，也是能发出去、能从终端输出里点开的链接**；
  二维码只是它的渲染，不是第二种格式。**私钥放 fragment**——fragment 不发往服务器，链接被日志、被聊天预览、被代理看到时，密钥不在会travel的那一半里。
- **传的是 32 字节 seed，不是 OpenSSH 私钥文件**：① 它正是 App 存进 Keychain 的东西，跨语言没有转换可出错；
  ② 44 字符 vs 约 400，二维码才小到能在终端打印；③ 同一把密钥不同生成器的 OpenSSH 编码不同，在这里解析等于再信一遍这个 App 已经读过的格式。
- **宿主侧 `cqutmux pair`**（不只是打印信息了）：没有密钥就生成 `~/.ssh/cqutmux_ed25519`、把**公钥**追加进 `authorized_keys`、打印链接和它的二维码。
  密钥文件**独立命名是有意的**——`id_ed25519` 是用户自己的、机器上别的工具也在用，覆盖它等于砸掉用户所有登录，读它等于把一把万能钥匙装进手机。
- **App 侧**：`HostStore.pair(with:)` 按 hostname/port/user 去重再 upsert，只写链接带来的东西——**没带密钥的链接绝不清掉已有的密钥**
  （重新配对常常只是为了换 token，静默忘掉密钥会把这件事变成认证失败）。配对成功直接进会话：这正是这个功能存在的意义。
- **二维码编码器写了两份**（`App/Shared/QRCode.swift` 与 `host/cqutmux-hook/qr.mjs`），这是刻意为之的坏味道：
  宿主是 Node，App 是 Swift，共用一份不现实。但两份实现正是 bug 藏身之处，所以 **JS 那份拿 Swift 那份的同一批参考矩阵来判**
  （`scripts/qr-js/main.mjs` 直接读 `scripts/qr/main.swift` 里的向量，两组都对同一个独立编码器负责，而不是互相对照）。
- **二维码是安全边界**：扫码即得到一把能登录的私钥，所以命令打印时明说"这是秘密"，确认页在保存**之前**显示将保存什么。

**这套检查抓到的问题**（每一条都是真的会打坏用户的）：
① JS 版把 `placeData` 标过的格子写回了 `reserved`，于是 `applyMask` 时"保留位"= 全部格子，**掩码被套用在空气上**——
   生成的码看上去完全正常，却读不回来；Swift 版当年正是踩过同一个坑，注释里写着，JS 版还是踩了。
② 链接里的密钥走过 `String`：**32 字节随机 seed 多数不是合法 UTF-8**，`String(data:encoding:.utf8)` 返回 nil，密钥被**无声丢弃**。
   现在 `Payload.seed` 是 `Data`，`key` 只是它的 base64 视图；断言里专门加了一条"非 UTF-8 的密钥必须逐字节往返"。
③ 31 字节的 key 字段原本被当成合法——截断的链接会变成连上后认证失败，比"密钥缺失"难查得多，现在按"无密钥"处理。
④ 已有密钥时调用 `ssh-keygen -f` 会**在 stdin 等 "Overwrite (y/n)?"**——命令不是失败而是**永久挂起**，且没有任何输出。
   现在先 `existsSync` 再决定，不去调它。
⑤ 相机权限文案只写了"导入主题"，而扫码器已经被配对复用；一个 prompt 覆盖全 App，文案说错就是**如实性问题**。
⑥ 调试用的配对链接原本要在 `.task` 里切到 Paste 页，但相机视图**先一步出现并拉起权限弹窗**；
   改成 `init` 里就定好初始 phase，相机根本不会被创建。

**实测**：`scripts/build.sh` 通过；`scripts/cli-check.sh` **34 项**（其中 9 项是 Easy Pair 端到端，
用 `scripts/pair-parse.sh` ——它链接的是 **App 真正发布的那份 `Pairing.swift`**，而不是在检查脚本里再写一个读法，
后者只能证明宿主和自己一致）；`scripts/pair-check.sh` **36 项**；`scripts/qr-check.sh` **33 项**；`scripts/qr-js-check.sh` **28 项**。
模拟器截图确认确认页逐字段显示 host/port/user/name、密钥与 token 两项标注正确
（过程中还学到：`simctl privacy grant camera` 在已安装的 app 上不生效，要全新安装或重启模拟器）。

**Support 页去哪了**：Moshi 的 Support 是一个托管入口（他们的表单/邮箱）。**我们没有任何托管服务**，所以没有可填的邮箱、没有可投的表单——编一个 `support@…` 比留空更糟，因为那会让用户以为报告发出去了。落地为**指向本仓库 issue 追踪器的链接**（`https://github.com/lvyufeng/CQUTmux/issues/new`，真实可点、报告公开可见有人回），加上复制到剪贴板。未验证：真机上的 `uname` machine 串（模拟器里读出来的是宿主架构 `arm64`，不是 `iPhone17,1`——这正是它比 `UIDevice.model` 有用的地方，但我只在模拟器里跑过）。

**顺带修掉一个真 bug**：App 的版本号一直是假的。`project.yml` 写 `MARKETING_VERSION: 0.1.0`，`App/Info.plist` 却把 `CFBundleShortVersionString` 硬编码成 `1.0`——手写的 Info.plist 不会被构建设置覆盖，所以**中途改的版本号一直没生效**，Support 页与设置页 About 里显示的都是这个编造出来的 `1.0`。改成 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 后，构建产物自报 `0.1.0 (1)`，与工程文件一致。

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
| Moshi Skill | **本轮查清：它是一个独立仓库 `rjyo/moshi-skill`**（`skills/` 格式的 markdown 包，`npx skills add rjyo/moshi-skill` 装到 agent 的 skill 目录）。读过全文后**判定为不需要**，理由是它整篇教的是"怎么把宿主准备好给 Moshi 用"——Easy Pair、SSH/Mosh 就绪、Herdr 优先、tmux 兜底、`moshi DIR` 启动器、`moshi-hook` 配对。<br>其中**只有两条**是关于我们自己的产品行为的：`MOSHI_CLIENT`（本轮已实现，见上一行）与 `moshi-hook install`（早已实现，且 `scripts/cli-check.sh` 覆盖）。写一份 `cqutmux-best-practices` 把同样的话再说一遍，只是把 `moshi` 换成 `cqutmux`——那是文档，不是功能；而这份 PLAN.md 与 `host/cqutmux-hook/README.md` 已经承担了同样的作用，且不会随代码漂移。<br>另一个不合理处：skill 里把 **Herdr 说成首选**，而我们三端（tmux/zellij/herdr）都支持且没有内置偏好；把某个第三方终端复用器写成我们的默认建议，是**跟着 Moshi 的商业取舍走，而不是跟着我们的功能走** | **判定为不需要**（非功能缺口；结论与理由如上） |
| Chat View | **此前一直没做，本轮补上，是审计出的最大缺口。**（Moshi `docs/chat-view`：把 agent 的会话读成一段对话——正文/思考/工具卡片（命令、文件编辑、迷你 diff）/回合小结。）**实现**：① 宿主 `host/cqutmux-hook/transcript.mjs` 读 agent **自己的会话日志**（Claude Code 的 `~/.claude/projects/<slug>/<session-id>.jsonl`），解析成带类型的块（`text`/`thinking`/`tool`/`result`），`GET /transcript?path=<dir>` 暴露；② App 侧 `ChatTranscript.swift`（宽解码，未知角色/块类型不炸）+ `ChatView.swift`（Code 面板第四个页签 Chat），3 秒轮询，思考默认折叠，工具调用折叠成一行 `Bash · <command>`、点开看完整输入/输出，用户回合右对齐、agent 左对齐。<br>**为什么读日志而不是抓终端**：日志是结构化的——一次 tool call 就是一条带 `tool_use_id` 的调用加一条配对的 `tool_result`，**这正是"工具卡片"能成立的前提**；抓屏幕只能拿到 ANSI 上色后的文本，而且面板一滚、一进 alternate screen、一进 TUI 就没了。<br>**实测**（模拟器 + 真网关 + 本机真实 1 万条会话日志）：`/transcript` 返回 `found:true total:10088`，角色分布 `assistant 24 / tool 16`，块分布 `result 16 / tool 16 / text 6 / thinking 2`；App 内渲染出 agent 正文、`Bash · <命令>` 卡片、折叠的 Result 行、Thinking 折叠块——截图见本轮 commit。<br>**踩到的真坑**：① 第一版把 `tool_result` 当成 user 消息渲染，于是"工具打印的东西"和"人说的话"在同一个气泡里——块的 role 推断（整条只有 result 块 → `tool`）就是为这个加的；② 我的测试夹具一开始用 `--root $HOME` 起网关，于是 `path="."` 解析到 `~` 而不是项目目录，Chat 显示的是**另一个项目的会话**——这不是 bug，是我的 harness 起错了根目录（`/files` 一直是同样的相对语义），但它证明了这个视图确实在如实渲染**被要求渲染的那个目录**的日志。ghost-text 未做：Moshi 的输入框带补全。Chat **视图本身**仍只读（读日志），但发消息已由 **Chat Mode composer** 承担——见上一行 | ✅ 已实现并实测（只读；composer/多选问题卡见下一行） |
| 交互式问题卡（N 选一） | **审计发现是真缺口，本轮补上。**（Moshi `docs/chat-view` / `docs/agents-usages` / Apple Watch：agent 提出多选问题时渲染选项按钮，选中把答案发回。）此前事件模型是**二元的**——`Kind` 只有 `approval | notice`，`POST /approve/:id` 只收 `{decision}`——没有"在 N 个选项里选一个"的通路。<br>**实现**：事件 `data.options: [{label, value}]`；`POST /approve/:id` 多了可选 `answer` 字段（**与 `decision` 并存而不是替换**——老的客户端、webhook 消费方仍然读得懂一个它认识的"已处理"）；App 侧 Inbox 与 **Apple Watch** 都把选项渲染成按钮（有选项就**不**显示 Allow/Deny——把选择题答成 allow/deny 等于把它要做的那个选择丢掉）；`label` 是按钮上的话、`value` 是回给 agent 的东西，两者经常不同（label 是句子，value 是 token）；已答的卡片显示"Chose: <label>"而不是退回按钮。<br>**顺带修掉一个真 bug**：`resolve()` 用字符串插值手拼 JSON（`{"decision":"\(...)"}`），选项值里带引号或反斜杠就会拼出网关解析不了的 body——而那表现为"点了没反应"，什么也看不到。现在走 `JSONEncoder`。cli-check 加了两条：选项要被记下、带引号的选项值要能原样往返。<br>**实测**：真网关 + 真 App，Inbox 渲染出三个选项按钮并带相对时间（截图见 commit） | ✅ 已实现并实测（手机 + 表盘） |
| 时间戳解析 | **本轮修掉一个"看不见"的真 bug。**网关写 `new Date().toISOString()`（**总是带毫秒**：`2026-10-09T04:15:30.123Z`），而 `ISO8601DateFormatter()` 默认配置**不接受小数秒**——对每一个这样的时间戳都返回 `nil`。它不抛错、不打日志，`Date?` 为空只是让相对时间渲染成空白，看起来像布局问题而不是解析问题。结果是**全 App 每一行的相对时间都没有值**，从写出那天起就是这样（Inbox 卡片上显示成 `Claude Code · ` 后面空空如也，我是在看问题卡截图时才注意到的）。<br>**修法**：`App/Shared/ISODate.swift`，两种形式都收（带/不带小数秒），四处调用点统一；`scripts/isodate-check.sh`（9 项）从**生产方**的角度写——拿网关和 agent 真正写出来的形状去断言，写入方以后改坏了读取方会在这里失败。实测修后卡片显示 `Claude Code · 3s ago` | ✅ 已修并加检查 |
| 客户端信号（`MOSHI_CLIENT`） | **此前根本没做，本轮补上**（Moshi 的 `MOSHI_CLIENT`，`moshi-best-practices` 第 4 节）。语义：App 把 `MOSHI_CLIENT=1` 导进远端 shell，让 rc/提示符/tmux 配置能判断"这个会话是被 App 拉起来的"并相应调整。**实现**：`IntegrationSettings`（设置 → Integrations → Shell，关时默认关）提供 `shellExportLine`，会话一建立就**先于 startupCommand** 打进终端。<br>**为什么不是 SSH 的 env 请求**：实测本机 sshd（无 `AcceptEnv`），`SetEnv=PROBE_MARKER=1` 的请求被接受但变量仍是 `unset`——**这是协议本身的行为**，不是我们的实现问题；Moshi 文档对 SSH 路径的原话正是 "via an injected `export` at shell start"，即两边都只能这么做。上方的 `EnvironmentRequest` 保留，因为配了 `AcceptEnv` 的宿主会认，但注释已写明别指望它。<br>**mosh 还多一条**：`mosh-server` 自己拼会话环境，所以启动器的 `-l` 列表里也带一份（`-l CQUTMUX_CLIENT=1`）——否则登录 shell 的 rc 在"用户手打的那行 export"生效之前就已经跑完了，rc 判断会得到错误答案。<br>**ET 做不到**：查 ET 源码（`TerminalServer.cpp::runTerminal`），会话环境**只**从反向端口转发的 `SSH_AUTH_SOCK` 条目拼出来，协议里没有别的通路；`Options` 结构也没有相关字段。已把实测用的那版 `env ... etterminal` 前缀**撤掉**——它只会设到 etterminal 自己进程上然后被丢弃，看着像生效比不生效更糟。设置页脚注直接写明 ET 会话看不到这个变量。<br>**实测**（模拟器 + `/tmp/cqut_sshd` 真 sshd，两条路径各跑通）：<br>`ssh` + 开 → `MARKER_IS:1`；`ssh` + 关 → `MARKER_IS:unset`（默认关，行为与升级前一致）；`mosh` + 开 → `MARKER_IS:1`，且 `mosh-server new -l LANG=… -c 256 -s -l CQUTMUX_CLIENT=1 -- sh -c $SHELL -l` 的 argv 与预期逐字一致。<br>**一处刻意的分歧**：Moshi 把这个开关放在 Pro 后面，我们没有——复刻付费墙是复刻商业模式，不是复刻功能 | ✅ 已实现并实测（SSH / mosh；ET 结构性不支持，已在设置页与代码里写明） |

| Live Activity 设置与自检 | **审计确认缺口，本轮补上。**（Moshi：Settings → Hooks 有 Live Activity 开关、"Open Inbox on tap" 开关，以及一个 Test Live Activity 按钮。）此前 Live Activity 是**无条件的**——轮询看到待批就走，看不到就撤，用户没法关，也无法在没真审批可等的时候确认它是否工作。<br>**实现**：Settings → Agents 下新增 **Hooks** 页（`HooksSettingsView`），两个开关 + 一个测试按钮。两个开关**默认开**，且用 `object(forKey:)` 而非 `bool(forKey:)` 读——后者分不清"从未设置"与"设成 false"，那会让一个从没打开过这个页面的设备显示成已经关掉。**活动显示什么**从 `ActivityManager` 移进 `AgentActivityPreview`（只 import Foundation），于是测试按钮走的是 Inbox 同一条判定：否则测试渲染出真实路径永远不会产生的东西，什么也证明不了。判定覆盖三件事：待批审批要计数（复数由数量推出，不写死）、已解决的审批以 0 停留一下而不是中途消失、以及**普通 notice 不产生任何活动**——为 agent 的闲聊在锁屏挂个徽标，等于在没有任何事等人处理时声称有人在等。<br>**"Open Inbox on tap" 在 App 侧判定，不在 widget 里**：widget extension 有自己的 `UserDefaults` 容器且没有 app group，在那边读永远拿到默认值，开关会变成假的。widget 照旧带 `cqutmux://inbox`，由 `RootView.handleInbox` 决定认不认。<br>**检查时抓到一个真 bug**：`Activity.request` 在 Info.plist 缺 `NSSupportsLiveActivities` 时抛 "Target does not include NSSupportsLiveActivities plist key"，而本 App **没有这个键**；请求又包在 `try?` 里，于是失败不产生活动、不报错、不打日志——**Live Activity 从实现那天起一次都没运行过**，而代码、widget 和文档全都读起来像是能用的。修法：`project.yml` 加 `NSSupportsLiveActivities: true`（XcodeGen 从它生成 `App/Info.plist`，手改 plist 会被覆盖），并把 `try?` 换成返回 `ActivityManager.Outcome`，让测试按钮能说出**为什么**没出现。`scripts/hooks-activity-check.sh` 钉住默认值、判定、样例时间戳、plist 键，以及 `try?` 的缺席 | ✅ 已实现并实测（模拟器：`CQUT_TEST_ACTIVITY: started`，widget 渲染出灵动岛紧凑态） |

| Chat Mode（组合后发送） | **审计确认缺口（第 2、37 条），本轮补上。**（Moshi：Chat Mode 先在本地组合一条消息再发送，与"命令模式直接把字打进 shell"相对；CJK 文档又把它列为 TUI 打乱输入法组合时的退路。）此前终端只有命令模式——每个按键经 SwiftTerm 的 `UITextInput` 进 TUI。<br>**为什么终端本身替代不了**：CJK 的组合（marked text + 候选）发生在 TUI **内部**，而会重绘的 TUI 会把标记区覆盖掉，落点/顺序/是否落下都可能出错。composer 是 TUI 之外的**原生 `TextField`**，组合由系统完成，**成串的文本一次性交付**。<br>**实现**：`InputSettings.chatMode`（Settings → Input，默认关）把键盘栏整条换成 `ChatComposerBar`。**交付方式**才是"chat"与"更慢的键盘"的分界：程序开了 bracketed paste 时，消息被 `ESC[200~ … ESC[201~` 包住，作为**一次粘贴**到达，TUI 才会当文本插入而不是当按键解释；这个位取自终端自己的 `bracketedPasteMode`（SwiftTerm 给真粘贴用的是同一个位），所以标记的有无不会和对端的期待脱节。没开（普通 shell）**不加标记**——没协商过它的 shell 会把标记原样打出来。末尾一律跟一个 CR，这就是它和命令模式的区别：**消息是被提交的**，不是留在输入行里。<br>**判定抽成 Foundation-only 的 `ChatComposer`**，由 `scripts/chat-composer-check.sh` 直接跑：只含空白不发送（空 Enter 会触发一个空回合）、CR 在粘贴标记**之外**（标记内的 CR 是插入的换行而非提交）、两端裁剪而**内部换行保留**、CJK 逐字节原样穿过标记。<br>**端到端实测**（模拟器 + 真 sshd）：`CQUT_DEV_COMPOSE` 走视图自己的 `sendComposed`，宿主确实执行了命令；`CQUT_DEV_CHAT_MODE=1` 截图显示 composer 栏取代了按键栏 | ✅ 已实现并实测 |

| 原生 Windows 宿主 | **审计确认缺口（第 12 条），本轮补上。**（Moshi：Windows 宿主用 PowerShell `Get-Command` 解析 `herdr.exe`。）Windows 上两件事必须不同，且**只在没人看着的那个平台上出错**：① `execFile('herdr', …)` **永远找不到** `herdr.exe`（也找不到包管理器的 `.cmd` shim），所以 win32 上探测走 PowerShell 的 `Get-Command`（等价于 `command -v`）而不是裸名；② herdr 的 API socket 在 macOS/Linux 是 Unix domain socket，在 Windows 是**命名管道**，所以路径按平台推导（`\\.\pipe\herdr-<account>`，名字做过 sanitize，分隔符逃不出管道命名空间，且带账号名，同机两个用户不撞）。<br>**判定抽成新的纯模块 `host/cqutmux-hook/platform.mjs`**：接收平台字符串、返回描述、**不做任何 spawn**——因为出错的正是这些判定，而被检查过的判定比不可测的代码有价值。`scripts/windows-host-check.sh`（18 项）钉住每个平台的程序、参数、存在信号与 socket 路径。<br>**诚实的边界**：本仓库的网关**只在 Linux/macOS 上跑过**，Windows 分支只经纯函数断言、**未端到端验证**。POSIX 路径未变，`scripts/herdr-test.sh` 对真实 herdr server 仍然通过 | ✅ 判定已实测；**Windows 运行时未验证**（已在审计中写明） |
| Inbox 上下文环 | **审计确认缺口（第 66 条），本轮补上。**（Moshi：Inbox 每行有一个小环显示**上下文窗口剩余**，低于约 15% 时告警，同一读数也喂表盘。）事件里**没有** token 计数（网关的 event 不带），所以读数取自 agent **自己的 transcript 日志**，与 Chat 视图读的是同一份。<br>**算法是关键，因此放进 Foundation-only 的 `ContextWindow`**：窗口是**最后一轮**的 `input_tokens + cache_read + cache_creation + output_tokens`，**不是跨轮求和**——input 每轮都要重发，求和会把同一个窗口按消息数重复计数，把一个健康的会话显示成永远满，**看着合理的错值**。只报 0 的一轮被跳过而不是画成 0%（agent 正在 compaction 时会谎称上下文是空的）；比例 clamp 到 1，超限读成"满"而不是超过环的末端；limit 为 0 不读成除零。<br>**分母是唯一诚实的假设**：日志记录每轮用了多少 token，但从不记录能装多少。所以窗口大小是设置项（Settings → Agents → Context window，默认 200k，0 隐藏环），页脚直说是假设、请按模型改。<br>**只有拿到读数才画环**：读不到日志的会话留空槽，而不是对着没人量过的数字画。读数**按目录缓存一份**——transcript 读是宿主上的文件读，Inbox 几秒轮询一次，按行取会为一个每轮才变一次的数制造大量流量。`scripts/context-window-check.sh` 钉住算法，`scripts/transcript-check.sh` 补齐网关透传数值、丢弃字符串计数的用例。**实测**（模拟器 + 真网关 + 真日志）：181k/200k 的一轮显示 **91%** 且为告警色 | ✅ 已实现并实测 |

| 待批审批的 "Read first" | **审计确认缺口（introduction 页第 1 条：approvals 要能"先读后答"），本轮补上。** Moshi 的审批卡片在 Allow/Deny 之外还有一个"先看一眼再决定"的入口；此前 Inbox 行**只画标题**（工具名，如 `Bash`），prompt 正文（命令、要改的文件）**根本没渲染**，等于凭工具名答一个问题。<br>**实现**：`AgentEvent.promptText`（正文里是 JSON 的 tool_input，拆成它真正想说的那句话——命令或文件路径，与 Chat 视图 `AgentBlock.toolSummary` 同一套读法）、`promptClampLines` / `promptOffersReading`（四行封顶 + Read first / Show less 切换），`InboxView.SessionRow` 渲染；同一读法经 `AgentConnection` 快照送到表盘，表盘同样封顶并可展开。<br>**这一版先写错了两处，都被对抗式复核抓出来，且两处都看不出来**：① 宿主 `claude-code-hook.sh` 发的是 `json.dumps(tool_input)`——多行命令**在线上是一条物理行**，`\n` 是转义的两个字符。逐字渲染出来的是花括号和反斜杠，而且四行封顶**在真实路径上从不触发**（实测：186 字符、0 个真换行、5 个 `\n` 字面量）。② 封顶按**行**数、按钮按**字符**数，两个单位互不相干，于是"五行短命令"会被折掉两行**且不给任何展开入口**——正是这个功能存在的意义（别盲答）从它自己新开的那扇门里溜回来。修法：两处都读**同一个行数**（`promptLineCount`），正文先经 `promptText` 还原成多行。<br>**钉住**：`scripts/inbox-check.sh`（79 项），含一条**按 hook 真实写法**构造的 wire 用例（转义 `\n` 的 tool_input）与两个方向的单位用例。**已编译验证**：App target 与 watch target 均 `BUILD SUCCEEDED`。<br>**仍缺（另记）**：Live Activity 与推送通知正文仍只给标题，两者在上面各处已单独记录为未完成 | ✅ 已实现（规则实测 + 双 target 编译通过） |

| 多步快捷方式的步间延时 | **审计确认缺口（keyboard 页：multi-step binding 要在步与步之间插一个小延时），本轮补上。** 此前 `Parsed.bytes` 把每一步的字节**拼成一坨**，发送路径一次性 `transport.send`——于是 tmux 的 `C-b, T` 两个字节落在同一次 read 里，**能不能生效全靠运气**；手势路径共用同一份 `bytes`，同样中招。<br>**实现**：`ShortcutGrammar.Parsed.schedule` 给出每一步"距上一步多久"，**第一步为 0**；`interStepDelay` 是那个间隔；`CQUTTerminalView.send(_:)` 把 schedule 作为**一个 main-actor 任务**逐步发出，于是第二个快捷方式或一次误触**无法把字节楔进前一个的步与步之间**（这个乱序是字节级断言看不见的）。单步走原路径（`needsPacing`），普通按键的体感不变。<br>**关键点**：延时在**步与步之间**，绝不在第一步之前——把延时放在最前面会让快捷栏上每一个键都"变卡"，而这两者只能靠 schedule 的形状区分开。**钉住**：`scripts/shortcut-grammar`（新增 "multi-step pacing" 段）断言延时的**形状**而不只是字节：单步是一个 0 延时的块、`text:` 的回车是独立的一块并被同样节奏、三步各在第二步与第三步前有间隔、`needsPacing` 单步为假两步为真。**已编译验证**：App target `BUILD SUCCEEDED` | ✅ 已实现（规则实测 + 编译通过） |

| 附件的四种来源 | **审计确认缺口（image-paste 页：Add attachment 要有 Camera / Photo / Files / Clipboard 四种来源，Clipboard 仅在可用时出现），本轮补上。** 此前 `pasteImage` 只读 `UIPasteboard.general.image`，**只有剪贴板一条路**。<br>**实现**：一个来源选择器接到既有的标注/上传管线上，图片怎么发出去**一个字没改**——三种新来源和剪贴板走同一个 `attach(_:)`。**相册刻意用 `PHPickerViewController`**：它跑在进程外、**不需要相册权限**，所以"选一张图"不会多弹一个权限框；相机是唯一需要 `NSCameraUsageDescription` 的路径，其文案从"扫二维码"扩写成也覆盖"拍照"。<br>**会静默出错的是"哪些行出现"这个判定**：剪贴板为空时那一行点进去是"No image on the clipboard"，看起来就是个坏按钮；所以它被放进 Foundation-only 的 `AttachmentSource.available`（**有图才给 Clipboard、有相机才给 Camera**），由 `scripts/attachment-check.sh`（14 项）直接驱动——截图只能显示**画出来的**行，显示不了**本该画出来却没画**的那一行。<br>**已编译验证**：App target `BUILD SUCCEEDED`（工程由 `project.yml` 重新生成，两个新文件已入 target）。**局限**：picker 本身无法无头驱动（命令行点不了相机与相册），所以钉住的是**来源选择规则 + 编译**，不是真拍一张；picker 关闭与标注页弹出之间那个 350ms 的间隔（一个 sheet 正在关闭时请求弹出另一个偶会被丢弃）同样是检查看不见的行为，已在调用点注释说明 | ✅ 已实现（规则实测 + 编译通过） |

## 5. 主要风险

1. ~~**Mosh/ET 的 iOS 交叉编译**（protobuf/OpenSSL 依赖链）~~ —— **已排除**。两者均已编通并实测；ET 的 libsodium 用 `scripts/et-ios/libsodium.sh`，host 侧 `etserver` 用 `host-tools.sh` 从源码构建（ET 不发布 macOS 产物）。
2. **SwiftTerm 与 tmux 全屏/鼠标模式的兼容性**——需要真机回归。
3. **App 进入后台被挂起**，SSH 连接会断——需依赖 tmux 侧持久化 + 前台快速重连（Moshi 正是这么做的）。
4. **本地网关的安全性**：回环端口仅经 SSH 通道访问，不暴露公网；需 token 校验。
```