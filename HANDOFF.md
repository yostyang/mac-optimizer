# Mac 一键优化 · 开发交接

更新：2026-11-06 · 当前代码版本 **2.8.0（27）** · 最低系统 macOS 13（2.8 内容见文末「2.8 精致化」）

本文面向接手开发的人：先讲怎么跑起来，再讲 2.5 改了什么、设计令牌在哪、键盘与全局热键怎么接、测试与截图怎么处理，最后是还没做完/需要真机确认的事。

---

## 1. 构建与测试

```bash
./build.sh          # 通用二进制 + 签名；NODMG=1 只出 .app
./test.sh           # 自检 → 界面测试 → 离屏截图（含黄金图比对）
./test.sh --approve # 界面改版后重拍黄金图，随后必须再跑一次 ./test.sh 验证
./measure.sh        # 菜单栏常驻 / 面板打开时的 CPU 与内存（需真机，见 §7）
```

- 纯 `swiftc`，没有 Xcode 工程。**新增 .swift 文件必须同时加进 `build.sh` 的 `SRC`**，否则不会编译。
- 本机 Swift 6.4 编译时 SwiftUI 宏插件受限，`build.sh` 需要 `SWIFTFLAGS=-disable-sandbox`；`test.sh` 会继承这个环境变量：
  ```bash
  SWIFTFLAGS=-disable-sandbox ./test.sh
  ```
- 固定签名证书在 `~/.filebutler-signing/`；充电助手按源码哈希缓存在 `helper-cache/`，源码不变就复用，避免升级后用户重新授权。
- `test.sh` 会退出正在运行的实例、跑完再恢复「常亮 / 接显示器模式」（`appstate.sh`）。别在测试中途手动开 App。

### 测试分三层

| 层 | 入口 | 内容 |
|---|---|---|
| 逻辑 | `--selftest` → `Tests.swift` + `V*_Tests.swift` | 指标读取、诊断、持久化、2.5 设计令牌/搜索/键盘/Toast |
| 交互 | `--uitest` → `uiChecks` | 辅助功能树找控件并点击；`V25.ui` 覆盖设置页与搜索 |
| 截图 | `--snapshot` → `snapshots` | 浅/深色、默认/最小窗口；`MOTests.contrast` 取样检查文字对比度，`MOTests.fits` 检查放得下且不显示滚动条；`MOTests.golden` 与 `goldens/` 比对 |

`test.sh` 会逐个检查 `build-test/shots/*.png` 是否齐全，新增截图名要同步加进 `test.sh` 的清单。

---

## 2. 2.5 做了什么（界面改版 + 全局命令面板）

### 设计基础（`V25Design.swift`、`CDSDesign.swift`、`main.swift` 顶部）

| 项 | 结论 |
|---|---|
| 色彩 | 中性灰阶 `#F2F2F5` / `#FFFFFF`（浅）、`#16162A` / `#1E1E33`（深，接近图标深蓝黑）。**去掉紫蓝渐变侧栏和面板头** |
| 品牌色 | `accent` = 图标那道弧线的紫（浅 `#6B5CFA`、深 `#7C6BFF`）；深色下文字另用 `accentText`（`#A99BFF`），避免紫色文字对比度不足 |
| 渐变 | **只留 `ScoreRing` 健康分圆环**（`accent2 → accent`），呼应图标弧线 |
| `accent2` | 青蓝，只给图表数据线；不再出现在图标、CPU 数字、侧栏 |
| 状态色 | `good` / `warn` / `bad` 单独一套，只表示正常、注意、危险；图标底色用 `statusTint()` |
| 材质 | `Vibrancy`（`NSVisualEffectView`，`.behindWindow`）；主窗口 `isOpaque=false` + `backgroundColor=.clear`。**测试模式自动退回实色**，否则离屏截图会拍成空白 |
| 字号 | 4 档：`DS.title()` 17 / `DS.body()` 13 / `DS.sub()` 11 / `DS.cap()` 10，见 `DS.fontSizes` |
| 圆角 | 3 种：`DS.r.card` 10 / `DS.r.control` 6 / `DS.r.pill` 999。`CDS` 旧令牌指向同一套，别再各写一份 |
| 描边 | 卡片阴影全部换成 1px `DS.border` 细描边；`.card()` 是唯一入口 |
| 图标 | `IconBadge`：彩色小方块 + 白色 SF Symbol；有 App 图标时用 `RowIcon` |

固定品牌紫，**不跟随系统强调色**（与 Raycast 一致，辨识度更高）。只借鉴列表、⌘K、快捷键提示这些 macOS 通行的交互模式，没有用 Raycast 的标志、图标或配色。

### 主窗口（`V25Shell.swift` + `main.swift` 的 `RootView`）

- 顶部 `TopBar`：搜索页面 / 操作 / 进程，输入 `edge` 会列出 Edge 的进程及「关标签 / 退出」；结果分组显示，选中行品牌紫填充。
- 侧栏 `Sidebar`：浅色半透明、分组标题、选中项圆角高亮；新增「设置」页（`sel = -8`）。
- 底部 `BottomBar`：左边当前状态，右边 `主操作 ↵` `操作 ⌘K` `切换页面 ⌘1–9`。
- `ActionPanel`：`⌘K` 弹出选中项的全部操作，可搜索；退出/关标签这类用红色标出。
- 键盘：`↑↓` 选择、`↵` 执行、`⌘↵` 走选中项的操作列表、`Esc` 清空/关闭、`⌘1–9` 切页。事件经 `KeyRouter`（`NSEvent.addLocalMonitorForEvents`）交给 `Shell.handle`；当前页面可通过 `Shell.listHandler` 接管列表导航。
- 处理结果：`Model.log` 不再堆在结论卡片里，改成 `ToastCenter` 底部 Toast，2.6 秒自动消失。

### 菜单栏面板（`Dashboard.swift` 的 `PanelContent`）

- 渐变大卡片 → 一行结论（不卡 / 有点卡 / 很卡 + 原因）。
- 2 列指标卡 → 紧凑列表：`PanelMetric` 每行图标、名称、数值、迷你曲线。曲线直接复用 `Monitor` 已有的 `cpuHist/gpuHist/downHist` 和 `TrafficHistory`，**没有新增采样定时器**。
- 6 个快捷按钮 → `QuickActions` 列表项，带开关状态和快捷键提示；和主窗口共用一份 `QuickActionList`。
- 高占用进程保留列表；`PanelKeys` 处理 `↑↓` 选择、`↵` 处理、`⌘K` 打开 `PanelMore`。
- 面板高度从 ~931 降到 ~657（`380×657`），不出滚动条的要求更容易满足。

### 逐页

- **列表 + 详情**：`ToolPage` 重写，覆盖资源排行、开机启动、浏览器、Spotlight、虚拟机、网络与 VPN、显示性能；右侧详情显示标题、说明和主操作。
- **只换皮**：实时监控、电池、显示器、显示性能、网络诊断、清理预览、改动与提醒——通过 `.card()` / `Card` / `PillButton` / 字号统一收口，图表和控件逻辑未动。
- **概览**：结论放在最上面，问题清单改 Raycast 列表样式，指标卡收成三张紧凑卡。
- 页面标题统一走 `DS.title()`（或 `PageHeader`）。

### 全局命令面板（`V25Shell.swift`）

- `⌥Space` 默认全局热键，用 Carbon `RegisterEventHotKey`，**不需要辅助功能权限，不会多一个授权弹窗**。
- `CommandPalette`：浮动 `PaletteWindow`（620×440），和主窗口共用 `Shell` / `CmdIndex` / `SearchResults`；输入「接显示器」「体检」「关 Chrome 标签」直接执行。
- 设置页可录制快捷键（`set.hotkey`），存 `UserDefaults` 的 `hotkey.code` / `hotkey.mods`，改完重新注册。
- `CmdIndex.processes` 用 libproc（`ProcScan`）而不是 `ps`：只读、免权限、受限环境里也能列全进程。

---

## 3. 键盘与命令速查

| 场景 | 按键 | 行为 |
|---|---|---|
| 主窗口 | 输入任意文字 | 搜索页面 / 操作 / 进程 |
| 主窗口 | `↑` `↓` | 在结果或当前列表中移动 |
| 主窗口 | `↵` | 执行选中项的主操作 |
| 主窗口 / 面板 | `⌘K` | 打开选中项的全部操作 |
| 主窗口 | `⌘1`–`⌘9` | 切换 `navPages` 前 9 个页面 |
| 主窗口 / 面板 | `Esc` | 清空搜索 / 关闭操作面板 / 关闭全局面板 |
| 任意位置 | `⌥Space` | 唤起全局命令面板（可录制修改） |
| 菜单栏面板 | `↑` `↓` `↵` | 选进程、处理 |

`NavPage` / `navPages` 是页面清单的唯一来源；`features`（工具页 0–6）由它派生，`Loaders.rows(id)` 按 id 取数据。加页面时改 `navPages`，侧栏、搜索、`⌘1–9` 会一起更新。

---

## 4. 关键文件地图

| 文件 | 职责 |
|---|---|
| `main.swift` | 全局色值、`dyn`、`Model` / `Loaders` / `Sys`、`RootView`、`AppDelegate`、`NSWindow` 设置 |
| `V25Design.swift` | 设计令牌、毛玻璃、图标、列表行、Kbd、Toast、搜索框、页面标题 |
| `V25Shell.swift` | 页面清单、快捷操作清单、命令索引、`Shell`、侧栏/顶栏/底栏、`CmdK` 面板、全局热键与设置页 |
| `V25Tests.swift` | 2.5 的令牌/搜索/键盘/Toast 自检、界面测试、新增截图 |
| `Dashboard.swift` | 指标组件、快捷操作、进程列表、面板、实时监控页 |
| `Monitor.swift` | 采样与健康分（2.5 未改采样频率） |
| `Tests.swift` | 测试框架：AX 树、对比度、`fits`、黄金图比对 |
| `CDSDesign.swift` | 旧设计令牌别名 + 动效 / 渐隐（颜色与圆角已迁到 `DS`） |
| `goldens/` | 4 张基准图 × 1x/2x；`--approve` 重拍 |

---

## 5. 截图与对比度

- 改界面后：`./test.sh --approve` 重拍 `goldens/`，**再跑一次** `./test.sh` 确认黄金图比对通过。
- 介绍页截图在 `docs/`，取自 `build-test/shots/` 的 `golden-dashboard-*.png`、`golden-panel-dark.png`、`charge/display/network/bt-light.png`；`panel-dark-2x.png` 与 `panel-actions-2x.png` 是 2 倍放大/裁剪。改版后要同步更新 `docs/index.html` 里的 `width` / `height`。
- `MOTests.contrast` 在 2.5 重写过：10pt 小字的辅助功能框比实际字墨大一圈，取样向外扩 3px，用 5%/95% 分位代替极值；坐标对不上的无标签装饰节点跳过。**半透明背景最容易不达标**，改配色后务必跑浅/深两套。
- `MOTests.fits` 要求默认尺寸和最小尺寸（1080×720）都放得下。资源排行是长列表，允许无滚动条滚动，在 `V25.snapshots` 里单独跳过 `fits`。

### 离屏截图的已知限制

部分机器/会话里，`--snapshot` 进程的离屏窗口不会生成 SwiftUI 辅助功能树（同一批 `--uitest` 却完全正常），表现为所有「文字对比度」检查取不到文字节点。此时 `contrast()` 会跳过并计数，`snapshots()` 结尾打印一条 ⚠️ 提示，**不算测试失败**；浅/深色截图仍然生成在 `build-test/shots/`，需要人工核对对比度。不要为了让 AX 树出现而在 `contrast()` 里对离屏窗口 `makeKeyAndOrderFront`——抢 key 会让后续窗口一起失效。

## 6. 已修的测试隐患

- `V24Tests` 卸载用例原来会读进本机真实的卸载日志，导致「记录条数」断言偶发失败；现在把 `logURL` 指到临时目录后清空 `records`。
- `V20Tests` / `V21Tests` 的圆角断言从 14/10 更新为 10/6。
- **截图缩放**：同一台机器两次运行，离屏窗口可能一次拍成 1x、一次 2x，导致「`@2x` 基准图没重拍」的假失败。`MOTests.golden` 现在统一降采样到 1x 再比对，`goldens/` 只保留一套；`diffRatio` 的像素阈值从 0.25 提到 0.45，只统计肉眼可见的变化，滤掉 2x→1x 的抗锯齿噪声。
- **辅助功能树**：测试进程改成 `.regular` 前台 App（`.accessory` 下 `NSApp.activate` 可能不生效，SwiftUI 不生成 AX 树，界面测试会大面积误报）；`contrast()` 在取不到文字节点时把离屏窗口置为 key 后重取；`uiChecks` 在窗口 `contentView` 被回收时重建 `RootView`。
- **退出残留**：`test.sh` 的 `osascript quit` 偶尔返回 -10004 且挂着不返回，残留实例会抢前台；现在限 5 秒，之后 `pkill -TERM` 兜底。
- **`install-local.sh` 静默退出**：脚本是 `set -euo pipefail`，而 `appstate.sh` 的 `mo_pid()` 用 `pgrep | head -1`；没有运行实例时 `pgrep` 返回 1，pipefail 让整个管道失败，`-e` 直接终止脚本（无输出、退出码 1）。`test.sh` 没有 `-e` 所以一直正常。现在 `mo_pid()` 末尾加 `|| true`，并把 `pgrep && { …; exit 1; }` 改成 `if`。
- **本机安装注意**：`build.sh` 用固定证书签的充电助手与已安装旧版的 cdhash 不同时，助手需要在「系统设置 › 通用 › 登录项与扩展 › 后台项目」重新允许一次（或到「电池」页重装助手）。`chargeHelperBuild` 已是 22 但 `--charge status` 超时就是这个现象。
- 对比度检查见 §5。

已连续两次 `./test.sh` 全绿：自检 504、界面 120、截图 116。

## 7. 还没做完 / 需要真机确认

1. **毛玻璃 + 实时曲线的 CPU 实测**。本次开发环境禁止 `ps`，`measure.sh` 跑不出数字。请在真机执行：
   ```bash
   ./measure.sh build/Mac一键优化.app 60
   ```
   对比「菜单栏常驻（面板关闭）」和「面板打开」两行的 CPU / RSS；重点看面板打开时 2 秒采样叠加迷你曲线有没有明显抬升。若超预算，优先把 `PanelMetric` 的 `Spark` 换成静态折线或降点数，而不是提高采样间隔（数据准确性优先）。
2. **真机毛玻璃观感**：离屏截图会退回实色，浅/深色下的 `NSVisualEffectView` 透明度、深色模式紫色文字对比度、交通灯与侧栏标题的间距，都需要在实际窗口里看一眼。
3. **全局热键冲突**：`⌥Space` 可能与输入法/其他启动器冲突；设置页可录制，但还没做「注册失败」的提示与自动回退。
4. **⌘K 面板的焦点**：`PaletteWindow` 已覆盖 `canBecomeKey`，但非激活面板在个别 macOS 版本上可能需要手动 `makeFirstResponder`；真机验证输入 `↵` / `↑↓` / `Esc`。
5. `docs/BACKLOG.md` 里的 B/K/D/N/C/X 系列与本次改版无关，仍按原优先级推进；`U03`（键盘操作、小窗口、长名称）随 2.5 完成了一部分。
6. 尚未发布 Release：版本号已在 `Info.plist` 升到 2.5（22），`README.md`、`docs/index.html` 已同步；打 DMG 与公证流程见 `release.sh`。

## 8. 守住的线

- 全中文界面；不出现可见滚动条；自身占用低。
- 只借鉴交互模式，不用 Raycast 的标志、图标和配色，保留自己的品牌紫。
- 数据准确、操作闭环：退出进程等待可观察结果，清理先进废纸篓，不把发出请求当成成功。
- 最低 macOS 13：新 API 都要有退路（毛玻璃用 `NSVisualEffectView`，全局热键用 Carbon，键盘用本地事件监听而非 `onKeyPress`）。

## 2.6（桌面分区）
- 代码：V26Split.swift（布局/坐标/AX 驱动/偏好/页面/命令），V26Tests.swift。导航 id -9。
- 测试用 FakeDriver/FakeScreens，不碰真实 AX。注意：容器上的 accessibilityIdentifier 会覆盖子项，需 .accessibilityElement(children: .contain)。
- 待办：真实窗口（Chrome/微信/Electron）人工验证。

## 2.6.1
- 分区目标：SystemAppTracker 记最近激活的外部应用；CommandPalette.open 先 capture()。结果走 SplitHUD（Toast + 无焦点浮层）。

## 2.6.2
- 空 ⌘K：Shell.contextItem(page:)；撤销按具体窗口（driver.armedWindow / arm）。
- UI 测试稳定性：SwiftUI 树需外部 AX 查询触发（primeAX），等待需分发 AppKit 事件（pump）。

## 第零期：安全与稳定（2026-11-06，基于 2.6.2）

- `DNSCore.swift` 的 `ProcessRunner` 是通用命令入口，替代原 `sh()`；双路非阻塞排空、输出限额、10 秒默认期限和超时子进程回收。
- `main.swift` 的 `LoginItems` 固定脚本 + argv 传名称，读取 JSON；VPN 建议默认全部不选；工具页使用 `ToolOperation` 回读后统计。
- 新增 `PhaseZeroTests.swift`。验证结果、首次 UI 前台失败与重跑证据、共享助手的构建影响见 [第零期说明](docs/phase-zero-safety.md)。

## 2026-11-06 HTML 改版第一期

已完成规范、7 个组件、监控 3×3/最小窗口紧凑布局、设置迁移、语义页面路由和进程阈值色。详见 `docs/phase-one-monitor.md`。标准流程批准黄金图后复测全绿：587 selftest / 134 uitest / 104 snapshot，0 失败。下一步为用户已授权的第二期网络总览、面板二级信息、概览 KPI 和真机性能比较。

## 2026-11-06 · 2.7.0（26）第零至第二期

第零、一期提交分别为 `5ae4fef`、`a85822f`。第二期加入网络总览、诊断详情入口、菜单指标二级信息与行尾曲线、概览 KPI 条。进程图标缓存为 16 pt / 2x；监控仍为 2/5 秒。约 4 MiB 面板 RSS 增量按用户明确确认接受，不再做无必要微调。

最终 2.7.0：自检 598、交互 137、截图 72 全部执行项通过；48 次离屏 AX 对比度跳过已注明并人工查看相关截图。批准黄金图后正常复测差异 0.00%；实际 DMG 包内自检 598 通过。详见 `docs/phase-two-summary.md` 和 `docs/release-validation-2.7.0.md`。

后续顺序：发布到 GitHub 并回下载核对哈希，再评估待办。用户新发双列下拉面板参考图暂不实现；电池数据、Keychron、电源/显示器能力与窗口工作流也先评估。首版分屏不考虑 iPad。不要把未验证的硬件读数或数据覆盖缺口当作 0。

## 2026-11-06 · 2.8.0（27）精致化

对应 `docs/BACKLOG.md` 的 U03、U04、B03、B05、D02。新代码集中在 `V28.swift`（状态/单位/功率趋势/能耗覆盖/色彩命名）、`V28Panel.swift`（双列面板）、`V28Tests.swift`。

### U04 统一状态与单位
- `StateLine(kind:text:detail:actions:updated:id:)`：六种状态 `loading / empty / unknown / stale / failed / done`，状态色只用 `good/warn/bad`，朗读前缀区分状态。失败或空白时用 `StateAction.retry / .refresh / .openSettings(url:)` 给出下一步。新页面写「正在读取」「暂无」「失败」一律用它，不再手写灰字。
- 单位口径（`extension Fmt`）：`Fmt.watts` 一位小数，`Fmt.percent` 整数，读不到一律 `Fmt.dash`（「—」）而不是 0；时间用 `Fmt.ago`（刚刚 / 42 秒前 / 10 分钟前）、`Fmt.clock`（今天 HH:mm，其他 MM-dd HH:mm）、`Fmt.span`（35 分钟 / 18 小时 40 分）。`UpdatedText` 每 5 秒刷新文字，不触发采样。
- 已迁移：电池功率/能耗、显示器色彩、改动记录、按应用流量、流量历史、卸载记录、清理白名单、进程列表空状态。其余页面的旧写法（例如清理扫描提示、DNS 失败文案）留待 A03 统一。

### U03 双列菜单面板
- 宽 400（`PanelLayout.width`），结构：结论头（图标 + 健康分 + 不卡/有点卡/很卡）→ 系统芯片行（`ViewThatFits` 放不下时依次去掉代理、运行时长）→ 3×2 指标卡（`PanelTile`，右上角状态标签：温度、内存压力、容量、网络类型、风扇个数）→ 电池宽卡（外设电量 `DeviceRing`，读不到画虚线环、朗读「电量未取得」）→ 进程列表（CPU / 内存列头对齐）→ 6 个快捷操作两行网格 + 优化记录。
- 保留的标识：`panel.open`、`panel.traffic`（现在在网络卡上）、`panel.battery.compact`、`act.*`；新增 `panel.header / panel.metrics / panel.battery / panel.stats / panel.device.<名称>`。
- 只用 DS 令牌；参考图里的风扇调速按钮没有做（需要特权写 SMC，会改动充电助手 → 用户要重新授权，也不符合「只读风扇」的现状）。
- 面板高度约 840（`PanelHeight` 仍按屏幕可见高度封顶，矮屏幕可无滚动条滚动）。黄金图 `goldens/panel-*.png` 已按新样式重拍；截图时蓝牙外设用 `V28.btFixture()` 固定数据。

### B03 电池功率趋势
- `PowerHistory`：只在内存里保留最近 2 小时；`Monitor.sample` 末尾 `record(snapshot)`，同一读数时间戳只记一次，超过 30 秒的旧读数不记。前台每 10 秒读一次电池（原有），后台新增每 30 秒读一次（只读 AppleSmartBattery 一个 IORegistry 对象）。
- 三条线分开画、不相加：输入（电源遥测）、充入、放电；系统功耗是估算，不画。相邻样本间隔 > 75 秒算断档，接电/拔电处断线并画虚线；`PowerHistory.segments` 是唯一的分段逻辑。
- 「功率与能耗」标签改为左右两列：左「整机功率 + 功率趋势」，右「电池详情 + 应用能耗」。原「紧凑条（菜单栏面板同款）」卡已去掉（面板不再用 `BatteryCompactBar`）。

### B05 能耗采样覆盖
- `EnergyStore` 新增可选字段 `sampled`（小时 → 采到的分钟数）、`firstSample`、`lastSample`；旧版 `energy.json` 没有这些字段仍能读，界面注明「约从…（旧记录按小时推断）」。
- `EnergyCoverage.compute(store, range:, now:)` 给出覆盖分钟、覆盖比例（只从首次采样起算）、每格覆盖、缺口段数；`CoverageStrip` 画在时间范围选择器旁。没有数据时显示 `StateLine`，不显示 0。
- 文案明确区分：应用能耗 = 按进程估算的处理器能耗（`ri_energy_nj`），整机功率 = 电源遥测与电池电流。

### D02 色彩模式语义
- 色彩模式卡分三组：① 系统 ICC（只改 Mac 输出换算）② 显示器硬件（VCP 0x14 色彩预设、0xDC 显示模式，写入显示器本身）③ 软件色温（右侧护眼卡）。
- 命名优先级：本机命名 > MCCS 标准名 > 编号。`DDCCaps.modeName`（0xDC）与 `presetStandardName`（0x14）；`DDCNames` 按「显示器身份 | VCP | 值」保存到 `UserDefaults` 的 `ddc.localNames`，多屏互不影响，留空恢复默认。
- 反馈：`DDCFeedback.kind(note)` 把原有核对文案映射成统一状态；失败时给「重试」（`DisplayManager.lastDDCAttempt`）和「恢复」。

### 测试与验收
- 基线（2.7.0 原样）在用户机器上：自检 598 / 界面 137 / 截图 72 全绿。
- 2.8 结果与真机待办见 PR 描述；`./measure.sh` 的面板打开 CPU/RSS 对比、矮屏面板观感、真实外设（含 Keychron「未取得」）与 Kuycon 显示器的硬件模式命名需在真机核对。
- Codex 沙盒里可以编译（`SWIFTFLAGS=-disable-sandbox`、`TMPDIR` 指到项目内），但启动不了图形界面；`test.sh` 必须在普通终端跑。

## 2026-11-08 · 2.9.2（30）升级后充电助手自动切换

对应 `docs/BACKLOG.md` 的 B08，验证记录见 `docs/release-validation-v2.9.2.md`。新代码在 `V292.swift`（`HelperCheck` 判断与切换、`SystemHelperProbe` 读进程和文件 ctime、`ChargeSettingsBackup`）与 `V292Tests.swift`（`MockHelperWorld` 模拟完整升级流程）。

- 入口：`ChargeClient.repairAfterUpdate` 在后台队列跑 `HelperCheck.run`，结果写入 `ChargeClient.upgrade`，成功后才记录 `chargeHelperBuild`。`keepSettings` 在状态刷新时调用，每次启动最多补写一次设置。
- 原则：只改主程序，不碰助手代码，避免用户重新授权。注册后变成需要授权时立即停下提示，不循环注册。
- 测试拖拽替换升级：退出 App → 把 `/Applications/Mac一键优化.app` 移进废纸篓 → 用 `ditto` 放入新版 → 打开，观察助手进程号是否变化。

## 2026-11-10 · 2.10.0（31）自定义分区、拖动到分区、清理记录恢复

对应 `docs/BACKLOG.md` 的 S02、C01，验证记录见 `docs/release-validation-v2.10.0.md`。新代码在 `V210.swift`（自定义比例、开关、清理恢复）、`V210Drag.swift`（拖动到分区）、`V210Tests.swift`。

### 自定义比例
- `SplitPrefs.weights(uuid)` 是唯一的取值入口：固定模板（`split.templates`）或自定义（`split.custom`，`[uuid: [Int]]`），二选一，互相清除。`SplitLayout.rects(weights:in:)` 负责布局。
- `SplitController.place(_ zone:)` 仍按左/中/右；`place(index:)` 按序号。四栏时没有唯一的中区，命令面板额外给出第 2、3 区。
- 上下平分：`split.customRows`（`[uuid: [Int]]`，每栏 1 或 2），只对自定义比例有效。`SplitPrefs.zones(uuid, in:)` 是取全部区的唯一入口（比例 + 上下平分 + 间距），归位、拖动高亮都走它；区的顺序是从左到右、每栏从上到下，`SplitLayout.firstZone(ofColumn:rows:)` 把栏换成序号。预览图是 y 向下的坐标，要传 `flipped: true`。
- 间距：`split.gap`（0–24，默认 `SplitLayout.gap` = 8），所有屏幕共用。

### 拖动到分区
- `DragGesture` 是纯逻辑状态机：按下 → 候选（按住 ⇧ 且移动 ≥ 6 pt 时取鼠标下的窗口）→ 拖动中（窗口尺寸不变、位置变化且方向与鼠标一致）→ 松手给出落点。坐标一律用辅助功能坐标。
- 不要把跟随判断改回「位移相等」：真机上窗口位置读数比鼠标慢，严格比较会大量误拒。
- 撤销位置在松手后用 `DragGesture.originalFrame` 反推（鼠标在窗口里的相对位置不变），不受读数延迟影响。
- `AXDragSource.window(at:)` 先按坐标取元素，取不到再查窗口列表按位置匹配；排除本应用、非标准窗口和全屏窗口。
- `DragZones` 负责全局监听（每秒最多 30 次采样）、高亮浮层和落点；只在偏好 `split.dragZones` 打开时启动，测试里不启动。
- 调试：`--dragspike <日志路径>` 强制启用并写日志，同时跳过充电助手核对（供从测试副本直接运行）。

### 清理记录恢复
- `CleanRestore.status / restore / freePath` 是纯逻辑；`CleanStore.restore` 更新记录的 `restored`（可选字段，旧记录可读）并写改动记录。

### Keychron 键盘电量（K02）
- `V210HID.swift`：`KeychronHID.parse` 解析 3 号报告，`read` 用 IOHIDManager 找蓝牙连接、产品名含 Keychron 的设备，依次试输入报告和特性报告。需要「输入监控」权限（`IOHIDCheckAccess` / `IOHIDRequestAccess`），没有权限时不碰 HID。
- `BTParse.apply(hid:to:access:)` 只把地址对得上的读数并进列表；对不上、没权限都写明原因。做法参考开源的 Keychron K3 Battery Sync。
- 排查：`Mac一键优化.app/Contents/MacOS/MacOptimizer --read-keychron-battery`。

### 其他
- `HelperCheck.autoRepairAllowed(bundlePath:)`：从 `/Volumes` 或 AppTranslocation 运行时不自动重新注册充电助手。
- 截图测试里「改动与提醒」「清理」「桌面分区」都用固定样例，不读本机真实数据。

## 2026-11-10 · 2.10.1（33）拖动到分区更可靠

用户反馈微信主窗口按住 ⇧ 拖动时有高亮，但松手后有时不归位。改动都在 `V210Drag.swift`：

- `DragGesture.shiftCounts`：松手时 ⇧ 正按着，或松开不超过 `shiftGrace`（0.3 秒）都算数。`DragZones` 用事件时间记录 `lastShift`。
- 归位 0.25 秒后复查：`DragGesture.needsRetry` 判断位置是否偏离落区超过 4 pt，偏了就 `SplitController.replaceDragged` 再放一次（不改撤销位置）。尺寸受限不算偏离。
- 尺寸受限的提示改为「…但它的窗口不能缩到这个区这么小（尺寸受应用限制）」。
- 三种原因是推断，真机上哪一种在起作用还没有确认；`--dragspike <日志>` 的日志会写明松手时 ⇧ 的状态和是否触发了复查。

排查 Keychron：从终端直接运行二进制时，输入监控权限算在终端头上；要用 `open -n -W --stdout <文件> <App> --args --read-keychron-battery` 才按应用自己的权限判断。

## 2026-11-10 · 2.11.0（34）菜单栏合并状态图标（M01）

代码在 `V211Trio.swift`、`V211Tests.swift`；基于 `fix/2.10.1-drag-reliability`。

- 菜单栏显示内容新增 `trio`（`BatteryAlerts.settings.menuIndicator`）。`StatusBar.render` 在该模式下用 `TrioIcon.image` 画图标；`TrioModel` 变化（配置、音量、Wi-Fi）会触发重画。
- `TrioConfig`（`menubar.trio`，JSON）：显示哪几项、紧凑/并排、大小、百分比、着色、面板控制、Wi-Fi 名称。`sanitized()` 保证至少一项、顺序固定。
- `TrioLayout.make` 是纯计算，决定各项在图标里的位置；紧凑模式下 Wi-Fi 与音量上下叠放。没有电池的 Mac 自动不画电池。
- 单色模式输出模板图（跟随菜单栏深浅）；着色模式是非模板图，墨色取 `labelColor`。
- 数据：Wi-Fi 用 CoreWLAN（`rssiValue`、`powerOn`，名称需要定位权限且默认不读）；音量用 CoreAudio 的虚拟主音量和静音属性，变化靠属性监听，不轮询。Wi-Fi 跟随现有的低频采样刷新。
- 面板：`TrioPanelCard` 只在该模式且 `config.panel` 为真时出现。
- 设置：`TrioSettings` 嵌在设置页「菜单栏显示内容」下方，只在选了「合并状态」时出现。
- 截图测试新增 `trio-gallery`（各种设置下的图标）、`trio-settings`、`trio-panel`，供人工查看。


## 2026-11-11 · 2.12.0（35）可读性 P0（分支 v2.12，未发布）

依据《视觉与交互优化方案》P0，代码在 `V25Design.swift`（令牌）、`V211Trio.swift`（电池符号）、`V212Tests.swift`（静态对比度与图标检查）。

- 文字承载色 `DS.text`：`secondary` #62626E / #A1A1B0，`good` #08744F / #34D399，`warn` #8B5100 / #FFB340，`bad` #B42318 / #FF6B6B；选中行字 `onSelection` 白、`onSelectionSecondary` #EEECFB。**小字一律用 `DS.text.*`，图标、圆环、曲线继续用 `good/warn/bad/accent`**；颜色来自变量时用 `DS.text.tone(c)` 换成对应文字色。
- `DS.selectionFill` #5846D6：承载白字的填充（列表/操作面板/进程选中行、主按钮）。品牌紫 `accent` 只做图形、焦点和开关。
- 全部 `.foregroundColor(.secondary)` 已换成 `DS.text.secondary`（旧的是半透明黑，浅色约 3.9:1）。`Color.secondary` 只剩描边等图形用途；`tempTint(nil)` 仍返回 `.secondary`（V28 测试约定），标签文字经 `tone()` 转成 `DS.text.secondary`。
- 菜单栏电池：`TrioIcon.batteryMarks` 决定画数字/闪电；显示百分比时充电也画闪电，放在数字左边，放不下就缩小字号。
- 内边距：`Card` → `DS.cardPadding`（16），面板卡与 `Tile` → `DS.tilePadding`（10）。离屏布局测量（未上屏窗口，实时数据）：最紧的是 1180×780 下的显示器页，内容 687 / 可见 694 pt；最小窗口下显示器页 604 / 634 pt、电池页 536 / 634 pt。最终以 `./test.sh` 的 `fits` 为准。
- 颜色变化会让黄金图比对失败，属于预期：用户放行后 `./test.sh --approve` 重拍，再跑一次 `./test.sh` 确认。
