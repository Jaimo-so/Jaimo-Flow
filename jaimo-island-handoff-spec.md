# Jaimo Flow — macOS 个人工具站产品与实现规格

> 状态：新版重构的实现契约。
>
> 适用范围：macOS 13 或更高版本，Apple Silicon。
>
> 视觉原型：`jaimo-island-prototype.html`。
>
> 设计语言：`DESIGN.md`。
>
> 旧版剪切板与提示词实现契约：`clipflow-handoff-spec.md`。新版未明确替换的剪切板和提示词规则继续有效。

---

## 1. 产品定义

Jaimo Flow 是一个原生 macOS 本地个人工具站。它不再仅是剪切板工具，而是承载高频本地操作的统一入口。产品使用屏幕顶部居中的灵动岛作为紧凑入口，由用户主动展开为完整工具站。

本地优先的意义是：

1. 剪切板、提示词、便签和应用收藏默认只保存在当前 Mac。
2. 不要求用户账户，不依赖云同步，不因复制内容产生隐式网络请求。
3. 摄像头只用于实时本地预览，不录制、不保存、不上传。
4. 应用列表从本机扫描，应用启动使用 macOS 系统能力完成。

### 1.1 第一版目标

1. 建立隐藏、紧凑岛和完整工具站三态窗口。
2. 建立首页、应用、提示词和剪切板四个一级页面。
3. 为首页建立可注册、可排序、可隐藏的组件架构。
4. 自动扫描、搜索、收藏并启动本机应用。
5. 完整保留已有剪切板和提示词数据及功能。
6. 保持开机启动、全局快捷键、本地数据、排除应用和应用更新能力。

### 1.2 第一版不做

1. Windows、iOS、iPadOS 或 Web 版本。
2. 账户、云同步、多人协作。
3. 插件商店、第三方组件安装或未经审核的脚本执行。
4. 任意拖拽缩放的自由画布。第一版组件尺寸由组件定义，用户只调整顺序和可见性。
5. 天气、行情等需要外部网络的默认组件。
6. AI 自动读取或处理剪切板内容。

---

## 2. 技术决策

### 2.1 继续使用现有原生技术栈

- AppKit 负责 `NSPanel`、窗口层级、屏幕定位、外部点击、全局快捷键和应用启动。
- SwiftUI 负责完整界面、导航、组件、列表、详情和设置层。
- SQLite 继续负责剪切板与提示词的持久化。
- `UserDefaults` 用于低频、体积小、无需查询的界面偏好，例如首页组件顺序、可见性、应用收藏和最后访问页面。
- AVFoundation 负责摄像头授权、设备选择和预览会话。

不引入 Electron、Tauri、WebView 或前端运行时。`jaimo-island-prototype.html` 是视觉与交互原型，不是生产界面运行时。

### 2.2 保留与重构边界

#### 保留

- `Sources/ClipFlowKit/SQLiteStore.swift` 的数据库与迁移责任。
- `Sources/ClipFlow/ClipboardMonitor.swift` 的剪切板监听、自身写入忽略与排除应用能力。
- `Sources/ClipFlowKit/Models.swift` 与 `PromptModels.swift` 中已稳定的剪切板和提示词数据定义。
- 全局快捷键、菜单栏常驻、开机启动、应用更新与安装回滚机制。
- 现有内部应用标识 `com.clipflow.mac` 和数据目录 `~/Library/Application Support/ClipFlow/`。

#### 重构

- 将现有固定中心面板替换为三态 `IslandPanelController`。
- 将剪切板与提示词的搜索栏内模式切换替换为全局一级导航。
- 将单一 `AppModel` 拆分为窗口、首页、应用、提示词、剪切板和设置状态。
- 将当前 `ContentView` 改造为只组合导航和功能模块的 `IslandRootView`。

---

## 3. 窗口与灵动岛状态

```swift
enum IslandPresentationState: Equatable {
    case hidden
    case compact
    case expanded(destination: ToolDestination)
}

enum ToolDestination: String, CaseIterable {
    case home
    case applications
    case prompts
    case clipboard
}
```

### 3.1 隐藏态

- 正常启动后默认不显示窗口，菜单栏图标和剪切板监听继续工作。
- 首次启动可以显示一次紧凑岛作为引导，后续启动不再自动展示。
- `⌥Space` 从隐藏态进入紧凑岛。

### 3.2 紧凑岛

- 固定在当前活动屏幕的菜单栏下方居中位置，不进入菜单栏或硬件刘海区。
- 显示 Jaimo Flow 标识、当前时间、本地运行状态、快速便签、摄像头检查和展开操作。
- 紧凑岛不显示完整一级导航，避免把完整工具站压缩到胶囊中。
- 点击便签或摄像头快捷操作时，直接展开首页并将焦点交给目标组件。
- `Escape` 或再次按 `⌥Space` 从紧凑岛进入隐藏态。

### 3.3 完整工具站

- 从紧凑岛的原位向下展开，顶部中心点不跳变。
- 宽屏使用约 948pt 的目标宽度，但不得超出当前屏幕可见区。
- 完整工具站保留顶部导航，内容区只滚动当前页面，导航不随页面滚动。
- `Escape` 首先关闭模态层，再关闭当前页面二级状态，最后从完整工具站收起为紧凑岛。
- 再次按 `⌥Space` 直接隐藏窗口，不经过紧凑岛。

### 3.4 窗口技术要求

- 继续使用 `.nonactivatingPanel`、`.hudWindow`、`.fullSizeContentView` 和 `.floating` level。
- 面板可以成为 key window 以接收输入，但不成为 main window。
- 使用鼠标所在屏幕决定活动屏幕，多屏环境下不永远固定在主屏。
- 窗口必须避开 `visibleFrame` 之外的 Dock、菜单栏和安全区域。
- 展开动效只动画内容的 transform 与 opacity。窗口实际 frame 可以直接切换，不对大面积背景模糊做动画。
- 系统开启“减弱动态效果”时，只保留不透明度反馈，不使用位移和缩放。

---

## 4. 一级导航

顺序固定为：

1. 首页 `home`
2. 应用 `applications`
3. 提示词 `prompts`
4. 剪切板 `clipboard`

设置是全局操作，放在导航右侧，不成为第五个一级页面。收起操作位于设置右侧。

导航需要同时使用图标、文字和当前页指示线表示状态。窄宽度可隐藏文字，但图标按钮必须保留可读取的无障碍名称。

键盘快捷键：

- `⌘1`：首页
- `⌘2`：应用
- `⌘3`：提示词
- `⌘4`：剪切板
- `⌘,`：打开或关闭设置
- `⌘F`：聚焦当前页面的搜索框；首页没有搜索框时无操作

---

## 5. 首页

### 5.1 组件注册定义

```swift
struct ToolWidgetDescriptor: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let defaultOrder: Int
    let defaultVisibility: Bool
    let layoutRole: WidgetLayoutRole
    let makeView: () -> AnyView
}

enum WidgetLayoutRole: String, Codable {
    case compact
    case regular
    case wide
}

struct WidgetLayoutEntry: Codable, Equatable {
    let widgetID: String
    var order: Int
    var isVisible: Bool
}
```

`ToolWidgetDescriptor` 定义组件能力与默认布局，`WidgetLayoutEntry` 只保存用户定制结果。新版本增加组件时，需要将注册表与已保存布局合并，不得覆盖用户已有顺序和隐藏状态。

### 5.2 时间组件

- 显示小时和分钟、完整日期、星期和当前时区。
- 时间每秒或每分钟更新均可，但显示不得出现明显跳宽；数字使用等宽数字。
- 进入后台时不需要保持高频计时器，重新显示时根据当前时间刷新。

### 5.3 快速便签

- 第一版只有一张快速便签，不做多便签列表。
- 便签支持任意纯文本、换行和系统粘贴，不拦截粘贴。
- 输入停顿后自动保存，界面就近显示“正在保存”、“已保存·仅本机”或保存失败。
- 便签不进入剪切板数据表，清空剪切板历史不得删除便签。
- 快速岛的便签操作展开首页后，焦点进入便签编辑区并选择当前文本插入点。

### 5.4 摄像头检查

- 首次仅在用户点击“启动摄像头”时请求权限，不在启动应用或展开首页时请求。
- 状态必须区分未请求、请求中、已授权运行中、已拒绝、无可用设备和运行失败。
- 权限被拒绝时提供打开“系统设置 → 隐私与安全性 → 摄像头”的操作。
- 实时预览默认水平镜像，不采集音频。
- 收起窗口、隐藏窗口、离开首页、隐藏组件或点击“停止预览”时立即停止 `AVCaptureSession` 并释放输入设备。

### 5.5 最近使用

- 第一版的“最近使用”只记录从 Jaimo Flow 启动的应用，不读取全局系统使用历史，避免扩大隐私权限。
- 记录 bundle identifier、最后启动时间和启动次数。
- 默认显示最近三个仍可用的应用，点击后直接启动。

### 5.6 组件管理

- 点击“管理组件”进入编辑状态，组件显示向前、向后和隐藏操作。
- 排序变更立即持久化。隐藏组件后，首页顶部显示“已隐藏组件”恢复区。
- 键盘用户可使用 `Option+↑/↓` 移动当前组件，隐藏操作必须可通过键盘聚焦。
- 第一版不提供自由拉伸；`WidgetLayoutRole` 的意义是由系统决定的布局权重，不是用户可任意输入的尺寸。

---

## 6. 应用程序

### 6.1 数据定义

```swift
struct LocalApplication: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL
    let icon: NSImage
    let version: String?
    var isFavorite: Bool
    var lastLaunchedAt: Date?
    var launchCount: Int

    var id: String { bundleIdentifier }
}
```

`bundleIdentifier` 是主键。对没有 bundle identifier 的异常应用包，可以使用标准化路径作为临时标识，但不将该路径当作稳定跨版本主键。

### 6.2 扫描范围

- `/Applications`
- `/System/Applications`
- `~/Applications`

扫描只收录可启动的 `.app` bundle。不递归显示其他应用包内部的 Helper、XPC Service、Framework 或插件应用。同一 bundle identifier 出现多次时，优先使用用户安装的 `/Applications` 版本，其次为 `~/Applications`，最后为系统应用。

### 6.3 页面结构

- 左侧常用区使用单列列表，只显示用户收藏的应用。
- 右侧全部应用区使用图标网格，显示本地扫描结果。
- 搜索同时匹配本地化显示名称、原始 bundle 名称和 bundle identifier，匹配不区分大小写。
- 应用图标必须使用 `NSWorkspace.shared.icon(forFile:)` 读取真实图标，不在生产界面使用文字占位。
- 收藏状态在应用网格和左侧常用区立即同步。

### 6.4 启动与异常

- 单击或选中后按回车启动应用。
- 调用 `NSWorkspace.openApplication(at:configuration:completionHandler:)`。
- 启动成功后更新 `lastLaunchedAt` 和 `launchCount`；启动失败不更新记录。
- 应用被删除或移动后，下次扫描移除无效条目；如果条目曾被收藏，可以在左侧显示“应用不可用”状态并提供移除收藏，不反复尝试启动无效路径。

---

## 7. 提示词

提示词是用户主动维护的长期文本模板，不参与剪切板历史上限和自动淘汰。

新版保留全部现有能力：

1. 单层自由文本分组、全部和收藏固定筛选。
2. 标题、正文和分组搜索。
3. 新建、编辑、删除、收藏、使用次数和最后使用时间。
4. 使用 `{{变量名}}` 定义变量，同名变量只生成一个输入项，渲染时替换正文中的所有同名标记。
5. 变量默认值和必填设置，本次填写值不覆盖模板。
6. 无变量时直接复制，有变量时先打开填写层，必填变量为空时禁用复制。
7. 复制成功后才增加使用次数；复制失败不增加。
8. 分组与提示词的拖拽排序和键盘等价排序。
9. 从剪切板保存为提示词时创建独立副本，原剪切板记录删除后不影响提示词。
10. 提示词写入剪切板时复用自身写入忽略机制，不得产生新的剪切板历史。

页面使用左侧列表和右侧详情的双栏结构。窄宽度可隐藏右侧详情，但底部必须保留“填写并复制 / 复制提示词”和收藏操作，不得因隐藏详情而丢失主任务。

---

## 8. 剪切板

剪切板是自动采集的临时历史，与提示词、便签和应用收藏是独立数据域。

新版保留全部现有能力：

1. 每 0.4 秒检查 `NSPasteboard.changeCount`。
2. 自动记录纯文本、代码、HTTP(S) 链接和图片。
3. 支持图片像素数据和 Finder 等应用复制的本地图片文件。
4. 按内容哈希去重，连续相同内容不重复写入。
5. 自身复制引发的 change count 必须被忽略。
6. 支持全部、文字、图片、链接和收藏筛选。
7. 支持搜索、列表选中、详情预览、复制、收藏和删除。
8. 历史上限为 150 条，超出后淘汰最旧的非收藏项，收藏项不参与自动淘汰。
9. SQLite 保存元数据和图片路径，图片文件保存在 `Application Support/ClipFlow/Images/`。
10. 默认排除 1Password、钥匙串访问和终端，用户可在设置中管理排除列表。
11. 清空历史需要 8 秒内的二次确认，只删除剪切板数据，不删除提示词和便签。
12. 长文本预览继续使用分片渐进渲染，不一次排版全部长文本。

页面使用左侧列表和右侧预览的双栏结构。窄宽度可隐藏右侧预览，但底部必须保留“复制到剪切板”和收藏操作。

复制行为是写入系统剪切板，不是模拟 `⌘V` 粘贴。如果“复制后收起”开启，成功后将完整工具站收为紧凑岛，在紧凑岛中显示复制成功状态，1.5 秒后自动进入隐藏态。

---

## 9. 设置

设置作为完整工具站上的模态层，保留现有设置并增加新功能配置。

### 通用

- 开机自动启动。
- 唤起快捷键，第一版默认 `⌥Space`。
- 复制后收起并自动隐藏。
- 默认展开页面：上次访问或固定首页。第一版默认使用上次访问。

### 首页

- 组件顺序和可见性。
- 恢复默认组件布局，该操作必须确认，不删除便签内容。

### 剪切板与隐私

- 历史记录上限 150 条。
- 排除的应用列表。
- 仅保存在本机的当前状态。
- 清空剪切板历史的二次确认。

### 外观

- 跟随系统、深色和浅色三种选项。
- 减弱动态效果优先遵循系统设置，应用不另建相反选项。

### 更新与数据

- 当前版本和检查更新。
- 打开本地数据目录。
- 数据库迁移失败或图片目录不可写时显示明确错误，不自动删除原数据。

---

## 10. 状态与模块边界

建议结构：

```text
Sources/ClipFlow/
├── AppShell/
│   ├── IslandPanelController.swift
│   ├── IslandPresentationModel.swift
│   ├── IslandRootView.swift
│   └── ToolDestination.swift
├── Home/
│   ├── HomeView.swift
│   ├── HomeModel.swift
│   ├── WidgetRegistry.swift
│   └── Widgets/
│       ├── ClockWidget.swift
│       ├── QuickNoteWidget.swift
│       ├── CameraCheckWidget.swift
│       └── RecentAppsWidget.swift
├── Applications/
│   ├── ApplicationsView.swift
│   ├── ApplicationsModel.swift
│   └── ApplicationCatalog.swift
├── Prompts/
│   ├── PromptLibraryView.swift
│   └── PromptLibraryModel.swift
├── Clipboard/
│   ├── ClipboardView.swift
│   └── ClipboardModel.swift
├── Settings/
│   ├── SettingsView.swift
│   └── SettingsModel.swift
└── SharedUI/
    ├── Theme.swift
    ├── GlassButtonStyle.swift
    ├── SearchField.swift
    └── EmptyStateView.swift
```

边界要求：

1. `IslandPresentationModel` 只管理窗口状态、当前页面和全局模态层，不直接执行数据库查询。
2. `HomeModel` 不读取剪切板数组；如需显示剪切板统计，通过只读摘要服务提供。
3. `ApplicationsModel` 不依赖剪切板或提示词状态。
4. `PromptLibraryModel` 和 `ClipboardModel` 可以共用剪切板写入服务，但不共用列表选中、搜索或分类状态。
5. 设置修改通过 `PreferencesStore` 或更类型安全的偏好服务传递，不从视图直接操作 `UserDefaults` 键。

---

## 11. 数据兼容与迁移

### 11.1 必须保持

- Bundle identifier：`com.clipflow.mac`
- Application Support 目录：`~/Library/Application Support/ClipFlow/`
- SQLite 文件：`ClipFlow.sqlite3`
- 图片目录：`Images/`
- 现有 `clips`、`prompts` 和提示词分组顺序相关数据。

### 11.2 新增数据

便签可使用 SQLite 独立表或 Application Support 内的原子文本文件，但必须满足：

- 不与剪切板记录混存。
- 应用崩溃时不得因半写入导致全部内容丢失。
- 清空剪切板、删除应用收藏和恢复默认布局都不得删除便签。

应用收藏、启动记录和组件布局属于可重建偏好，可使用 `UserDefaults` 并带 schema version。迁移失败时使用默认布局，但不影响剪切板、提示词和便签数据。

---

## 12. 视觉、响应式与无障碍

### 12.1 宽屏

- 首页使用 12 栏概念网格，时间与便签、摄像头与最近应用形成左右配对。
- 应用页左侧常用区保持窄栏，右侧网格根据宽度自适应列数。
- 提示词与剪切板的右侧详情区保持稳定宽度，左侧列表吸收剩余空间。

### 12.2 窄屏

- 一级导航隐藏文字，保留图标、当前页指示和无障碍名称。
- 首页组件退化为单列并垂直滚动。
- 应用页保留左侧常用区，右侧网格减少列数。极窄宽度如无法维持可用双栏，可将常用区改为顶部水平列表。
- 提示词与剪切板隐藏右侧详情，但保留底部主操作。用户选中列表项后，主操作立即对应当前选中项。

### 12.3 无障碍

- 所有图标按钮必须有可读取名称。
- 导航播报当前选中页，列表播报当前选中项、分类、收藏状态和位置。
- 复制、启动应用、保存便签、摄像头权限和错误反馈使用可播报状态。
- 所有可操作目标不小于 24pt，所有键盘可达元素保留明确焦点样式。
- 模态层打开时焦点进入模态层，Tab 与 Shift+Tab 在层内循环，关闭后返回打开它的控件。
- 动效不得成为状态的唯一信号。

---

## 13. 实施阶段

### 阶段 A：基线与保护

1. 运行当前自检和打包，记录重构前基线。
2. 保留当前工作区未提交修改，不覆盖、不回退。
3. 为现有数据库准备包含剪切板、图片、提示词和分组顺序的升级回归测试。

### 阶段 B：新应用外壳

1. 建立 `IslandPresentationState`、顶部定位和三态面板。
2. 建立 `IslandRootView` 和四个空白功能容器。
3. 完成全局导航、快捷键、设置层和收起逻辑。

### 阶段 C：首页与应用

1. 建立 Widget Registry 与布局偏好。
2. 完成时间、快速便签、摄像头检查和最近应用。
3. 完成应用扫描、缓存、搜索、收藏、启动和异常处理。

### 阶段 D：迁移提示词与剪切板

1. 先将现有提示词视图接入新页面，再拆分模型，不在同一步修改数据层和视图层。
2. 再将剪切板视图接入新页面，保持监听器在切换页面时始终运行。
3. 移除搜索栏内的“历史 / 提示词”模式切换，保留两个页面各自的搜索、分类和选中状态。

### 阶段 E：验收与发布

1. 深色、浅色和跟随系统三种外观。
2. 单屏、多屏、全屏应用、菜单栏自动隐藏和带刘海 MacBook。
3. 摄像头未请求、允许、拒绝、无设备和会话失败。
4. 空数据、搜索无结果、数据库失败、应用扫描失败和应用启动失败。
5. VoiceOver、键盘导航、减弱动态效果和高对比度。
6. 从当前公开版本直接升级后，剪切板、图片、提示词、分组和设置均不丢失。

---

## 14. 验收清单

### 窗口与导航

- [ ] 正常启动后不弹出完整工具站。
- [ ] `⌥Space` 从隐藏状态唤起紧凑岛。
- [ ] 紧凑岛与完整工具站均位于鼠标所在屏幕的顶部中央。
- [ ] 展开、收起、隐藏和外部点击不留下摄像头会话、键盘监听或无效焦点。
- [ ] `⌘1`–`⌘4` 可以切换四个一级页面，每个页面保留自己的搜索和选中状态。

### 首页

- [ ] 时间和日期与系统时区一致。
- [ ] 便签自动保存，退出重启后仍存在，清空剪切板不影响便签。
- [ ] 摄像头只在用户主动点击后请求权限，停止后系统摄像头指示灯熄灭。
- [ ] 组件排序、隐藏和恢复在重启后保留。

### 应用

- [ ] 自动扫描三个规定应用目录，不显示应用包内部 Helper。
- [ ] 同一 bundle identifier 不重复显示。
- [ ] 搜索、收藏、取消收藏和启动均支持鼠标与键盘。
- [ ] 应用启动失败显示就近错误，不增加启动次数。

### 提示词与剪切板

- [ ] 升级后现有剪切板、图片、提示词和分组顺序均存在。
- [ ] 两个功能是独立一级页面，不再显示搜索栏内模式切换。
- [ ] 写入剪切板不产生自身重复历史。
- [ ] 窄宽度隐藏详情后，复制和收藏仍可达。
- [ ] 清空剪切板不删除提示词、便签、应用收藏和首页布局。

### 发布安全

- [ ] 保持 `com.clipflow.mac` 和旧数据目录，更新器可以从当前公开版本安全升级。
- [ ] 摄像头用途说明已加入 `Info.plist`，文案明确说明仅用于本地预览。
- [ ] 打包、签名、更新校验和回滚自检通过。
