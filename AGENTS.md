# AGENTS.md · Jaimo Flow

> 给编程 Agent 的项目导航。用户可见说明见 `README.md`，视觉与动效规范见 `DESIGN.md`。
> 本文件必须与代码保持同步：每次改动代码都要检查并更新本文件（规则见第 1 节第一条）。

## 1. 用户协作约定（必须遵守，优先级最高）

- **每次改动代码后都要维护本文件。** 结束任务前，对照本次改动逐节检查 `AGENTS.md`：
  - 新增、删除或重命名文件、类型、页面、首页组件、扩展、脚本、自检、命令、数据路径、UserDefaults 键、钥匙串服务名、联网行为、不变量或发布流程时，必须同步更新对应章节（目录地图、页面与文件对应表、数据存储、核心不变量、常见任务做法、坑与禁区等）。
  - 修 bug 时如果发现了新的坑或隐性约定，写入「坑与禁区」或「核心不变量」。
  - 只写导航、规则和原因，不贴大段代码，不写行号。
  - 在给用户的回复中说明本次对 `AGENTS.md` 改了什么；如果检查后不需要改，也要明确说明「已检查 AGENTS.md，无需更新」。

- 在进行总结或撰写笔记时，禁止折叠或压缩知识点，禁止删除定义及其意义。
- 用户要求 macOS「应用程序」文件夹始终显示最新版 Jaimo Flow。完成构建并验证后，将最新应用安装到 `/Applications/Jaimo Flow.app`，覆盖该位置的旧版；后续运行、排查权限和引导用户授权时均使用该路径。保留用户数据，不删除其他位置的应用副本。安装到该目录需要系统权限时，按环境要求申请授权。
- 应用搜索应只显示「应用程序」中的正式副本；不要直接启动或注册 build 目录内的临时应用，保持 build 目录的 `.metadata_never_index` 标记。
- 用户明确要求启动台和应用搜索中始终只出现一个 Jaimo Flow，即 `/Applications/Jaimo Flow.app`。构建产物使用非 `.app` 后缀；每次构建、安装或排查后检查并清理临时副本的系统注册记录，验证只剩正式版。不要重置整个启动台或删除用户数据。

## 2. 项目是什么

Jaimo Flow：原生、本地优先的 macOS 个人工具站（菜单栏应用，`LSUIElement`，无 Dock 图标）。
入口有两个：`⌥Space` 全局快捷键，以及屏幕顶部中央的「刘海」悬停入口。窗口内有 6 个页面：首页 / 应用 / 提示词 / 剪切板 / Vibehub / 终端。另外有内置扩展：截图与贴图、截图识别与翻译。

- 内置终端、录音与转写、镜子可在「偏好设置 → 模块」独立开关，三个模块默认开启。
- 提示词是通用可复用模板库，调用时填写 `{{变量}}`。Vibehub 是面向 Vibe Coding 的编程话术与术语知识库，完整记录话术原文、适用场景、术语定义与含义。
- 前身叫 **ClipFlow**，后来叫 **Jaimo clip**。代码、target、Bundle ID、数据目录仍用 ClipFlow 命名，**用户可见品牌一律写 `Jaimo Flow`**。
- 不用账户、不做云同步、不用 Electron。只有用户主动操作时才联网：检查更新、Vibehub Agent、录音转写、镜子随机照片。

## 3. 技术栈与约束

- Swift 5.9 / SwiftPM，SwiftUI + AppKit，最低 **macOS 13**，只构建 **arm64**（`arm64-apple-macosx13.0`）。
- 不依赖任何第三方 Swift 包。SQLite 通过系统库桥接（`Sources/CSQLite`）。终端前端用随包附带的 xterm.js（`Resources/Terminal/`），由 WKWebView 承载。
- 没有 Xcode 工程，也不用 XCTest。测试是独立的可执行自检程序（见第 4 节）。
- 识别与翻译扩展需要 macOS 15（Vision + 系统翻译），代码里必须做可用性判断。

## 4. 常用命令

| 用途 | 命令 |
|---|---|
| 构建应用包 | `./Scripts/build-app.sh` → 产物在 `build/Jaimo Flow.buildbundle`（刻意不用 `.app` 后缀） |
| 打包 DMG | `./Scripts/package-dmg.sh` → 产物在 `dist/Jaimo-Flow-<版本>-macOS-Apple-Silicon.dmg` 和 `.sha256` |
| 全部七项自检 | `./Scripts/run-all-self-tests.sh`（只构建一次 `ClipFlow` 调试目标，逐项执行，失败立即退出） |
| 指定 App 自检 | `./Scripts/run-app-self-test.sh <TestTargetDir>`（参数为 `Tests/` 下的目录名） |
| 核心自检 | `./Scripts/run-self-test.sh`（含剪贴板去重、SQLite 淘汰及收藏保留） |
| 钥匙串自检 | `./Scripts/run-credential-self-test.sh` |
| 备忘录/便签自检 | `./Scripts/run-memo-self-test.sh` |
| 面板自检 | `./Scripts/run-panel-self-test.sh`（含原生主窗与小兜强制外观、跟随系统及旧偏好兼容，终端、录音、应用目录按需加载，监听生命周期、剪贴板增量一致性与观察通知隔离、资料库快捷键和保存转页，以及模块默认值、持久化、终端导航回落与资源释放、首页可见性及隐藏偏好恢复） |
| Vibehub 自检 | `./Scripts/run-vibehub-self-test.sh` |
| Vibehub Agent 自检 | `./Scripts/run-vibehub-agent-self-test.sh`（模拟模型响应，不联网） |
| 录音转写自检 | `./Scripts/run-recording-asr-self-test.sh` |
| 重新生成图标 | `swift Scripts/generate-icon.swift Resources/AppLogo.png Resources/AppIcon.icns` |

- 所有脚本都通过 `Scripts/swift-sdk-path.sh` 自动挑选与当前编译器兼容的 SDK，不要手写 `swift build` 绕开它。
- **自检的原理**：核心自检由 SwiftPM 运行。App 自检由 `run-app-self-test.sh` 选择 SDK，执行 `swift build --product ClipFlow`（debug），再用 `swiftc` 链接 `Tests/<Name>/main.swift` 与 `ClipFlow.product/Objects.LinkFileList` 中**除 App 的 `main.swift.o` 以外**的目标文件。清单包含 `ClipFlow`、`ClipFlowKit`、`CTerminal` 的当前链接产物，可避开增量构建后遗留的旧对象。要添加 `CTerminal.build` 模块搜索路径，因为 App 模块依赖终端。App 自检可直接访问 App target 的 internal 类型。断言失败时用 `fatalError` 或 `exit(1)`。
- **复用构建**：设置 `CLIPFLOW_SKIP_APP_BUILD=1` 时，App 自检直接链接当前调试目标文件。仅在产物与当前源码和 SDK 一致时复用。全量入口先构建一次，再依次运行其余 App 自检和核心自检。
- **新增 App 自检**：在 `Tests/<Name>/main.swift` 写测试，新增调用公共脚本的薄包装并加入全量入口。使用 `@main` 的套件在公共脚本中传 `-parse-as-library`，参考 Vibehub Agent 自检。
- 提交前：运行相关自检 + `package-dmg.sh`。

## 5. 目录地图

```
Sources/
  ClipFlow/          主 App target（UI、窗口、系统集成）；SwiftPM 递归发现以下目录中的源码
    App/             入口、应用协调器、偏好设置、更新
    Shell/           工作区窗口、刘海、全局快捷键、资料库页面共用组件
    DesignSystem/    主题、动效、图像与文本组件
    Home/            首页布局与状态、镜子与摄像头、复盘、备忘录
    Clipboard/       剪切板历史、监听、API Key 分组
    Prompts/         提示词资料库、模板运行与提示词弹层
    Recording/       录音组件、转写、工作台、字幕、播放器与转写配置
    VibeHub/         Vibehub 话术库与 Agent
    Applications/   应用启动台与应用扫描
    Terminal/       终端会话与 WebView 工作区
    FileRelay/      文件中转小兜、索引、缩略图与拖拽
    Extensions/     截图、贴图、识别翻译
  ClipFlowKit/       与 UI 无关的核心：模型、SQLite、JSON 文件读写、分类、分块、钥匙串、Release 解析
  ClipFlowUpdater/   独立的更新助手进程：备份 → 替换 → 失败回滚 → 重启
  CSQLite/           SQLite 系统库 modulemap
  CTerminal/         forkpty 启动登录 shell、调整 pty 尺寸（C）
Tests/<Name>/main.swift   各自检程序
Resources/           Info.plist（版本号、更新源）、AppIcon.icns、AppLogo.png、Terminal/（xterm）
Scripts/             构建、打包、自检、SDK 探测、图标生成
docs/releases/       每个版本的发布说明；docs/images/ 是 README 截图
DESIGN.md            当前设计语言（颜色、动效时长、布局尺寸、交互规范）
docs/archive/       早期历史资料：clipflow-handoff-spec.md、jaimo-island-handoff-spec.md、jaimo-island-prototype.html、daily-review-demo.html
build/ .build/ dist/ 构建产物（已 gitignore）
```

## 6. 运行时架构

```
App/main.swift → AppDelegate（@MainActor）
  ├─ PreferencesStore         UserDefaults 偏好（外观、排除应用、工作区尺寸、模块开关…）
  ├─ AppModel                 协调 SQLite 加载、复制反馈与关闭、跨库交互；发布 phase、设置、toast 和弹层开关；持有 UpdateManager 和两个扩展
  │    ├─ ClipboardLibraryModel   剪切板历史、筛选、选择与读写 → SQLiteClipStore（ClipFlowKit）
  │    ├─ PromptLibraryModel      提示词分组、排序、选择、编辑和模板运行 → 同一 SQLiteClipStore
  │    └─ CredentialLibraryModel  API Key 分组的名称搜索、选择、编辑和复制 → CredentialStore（ClipFlowKit）
  ├─ ClipboardMonitor         每 0.4s 轮询 NSPasteboard.changeCount → CapturedClip → AppModel.receive → 剪切板领域模型
  ├─ PanelController          主 NSPanel（ClipFlowPanel）的显示/隐藏/动画/退出前保存；管理展开时的事件监听和应用目录加载
  │    ├─ IslandShellModel    当前页面 ToolDestination、可用导航与终端开关；首次显示终端页时创建 TerminalSession，Vibehub 模型按需创建
  │    ├─ HomeDashboardModel  首页组件布局、快速便签、镜子与摄像头；由 PanelController 同步录音与镜子开关，按需创建 RecordingTranscriptionManager
  │    └─ IslandRootView      顶部导航 + 各页面视图
  ├─ HotKeyManager            Carbon 注册 ⌥Space → panelController.toggleHotKey()
  └─ TopNotchController       顶部刘海 NSPanel：主体展开工具站，耳翼和拖拽打开连体 FileRelayPanel
```

页面与文件路径以 `Sources/ClipFlow/` 为基准。标注 `ClipFlowKit/`、`ClipFlowUpdater/` 和 `CTerminal/` 的路径以 `Sources/` 为基准。

| 页面/功能 | 主要文件 |
|---|---|
| 页面外壳与导航 | `Shell/IslandShell.swift`（`ToolDestination` 六页共用顶部品牌、导航、窗口操作三段胶囊，入口统一承载窗口背景、设置、Toast 和两页资料库弹层）；`Shell/LibraryPageComponents.swift`（搜索、分类栏、主体布局、页脚及弹层容器） |
| 首页（Bento 组件） | `Home/HomeDashboardModel.swift`（首页状态、`WidgetID`、`HomeWidgetRegistry`、模块可见性过滤、镜子比例解析和摄像头生命周期）；`Home/HomeDashboardView.swift`、`Home/HomeWidgetLayout.swift`（24pt 卡片、组件语义色与布局）；`Home/MirrorWidgetView.swift`（镜子卡片、摄像头采集与预览）；`Home/DailyReviewWidget.swift`、`Home/MemoLibrary.swift`、`Recording/AudioRecorderWidget.swift` |
| 录音转写 | `Recording/RecordingTranscription.swift`、`Recording/RecordingASRRequest.swift`（Qwen3-ASR / OpenAI 兼容接口 `diarized_json` 与 `verbose_json`，录音后自动转写）；`Recording/RecordingWorkspaceView.swift`（通义听悟风格工作台与演讲人）；`Recording/RecordingSubtitleFeedView.swift`（时间轴字幕）；`Recording/RecordingAudioPlayerBar.swift`（同步播放器）；`Recording/RecordingASRSettingsView.swift`（服务商配置）；`Recording/AudioRecorderWidget.swift` |
| 应用启动台 | `Applications/ApplicationsView.swift`（`ApplicationsModel`），`Shell/PanelController.swift` 调度按需扫描 |
| 提示词 | `Prompts/PromptLibraryView.swift`（`PromptLibraryPage` 与提示词弹层）、`Prompts/PromptLibraryModel.swift`、`ClipFlowKit/PromptModels.swift`（`{{变量}}` 模板） |
| 剪切板历史 | `Clipboard/ClipboardPage.swift`（历史列表与预览）、`Clipboard/ClipboardMonitor.swift`、`Clipboard/ClipboardLibraryModel.swift`、`DesignSystem/ProgressiveTextView.swift`、`ClipFlowKit/SQLiteStore.swift` |
| API Key 分组 | `Clipboard/CredentialLibraryModel.swift`、`Clipboard/CredentialLibraryView.swift`、`ClipFlowKit/CredentialStore.swift` |
| Vibehub 话术库 / Agent | `VibeHub/VibeHubLibrary*.swift`、`VibeHub/VibeHubAgent*.swift` |
| 终端 | `Terminal/TerminalView.swift`、`CTerminal/`、仓库根目录下的 `Resources/Terminal/` |
| 截图/贴图、识别翻译 | `Extensions/ScreenshotExtension.swift`、`Extensions/CaptureSession.swift`、`Extensions/TranslationExtension.swift` |
| 文件中转小兜 | `FileRelay/FileRelay.swift`（串行导入、独立副本、极简弧边小兜视图、主题同步、原生拖出、缩略图和右键菜单），`Shell/TopNotchController.swift`（刘海几何与小兜状态） |
| 设置 | `App/SettingsView.swift`（「模块」分组与按镜子开关显示的「首页照片」）、`App/PreferencesStore.swift` |
| 更新 | `App/UpdateManager.swift`、`ClipFlowKit/UpdateRelease.swift`、`ClipFlowUpdater/` |
| 主题 / 动效常量 | `App/PreferencesStore.swift` 的 `FlowAppearance` 决定有效外观。`DesignSystem/Theme.swift` 的 `ClipFlowTheme`、`FlowWindowBackground`、`WindowMetrics` 与共享胶囊、卡片和内嵌槽控制样式。`DesignSystem/Motion.swift` 的 `FlowMotion` 管理动效 |

## 7. 数据存储（升级兼容，路径不可改）

根目录是 `~/Library/Application Support/ClipFlow/`：

| 数据 | 位置 | 负责代码 |
|---|---|---|
| 剪切板历史、提示词等 | `ClipFlow.sqlite3`（表 `clips`、`prompts`） | `SQLiteClipStore` |
| 剪切板图片 | `Images/`（SQLite 只存路径） | `SQLiteClipStore` |
| 备忘录 | `Memos/memos.json` | `MemoLibraryModel` |
| 每日复盘 | `DailyReviews/reviews.json` | `DailyReviewStore` |
| Vibehub 话术 | `VibeHub/phrases.json` | `VibeHubLibraryModel` |
| 录音与转写文字 | `Recordings/`（`.m4a`、`.transcript.json`、`.txt`） | `AudioRecorderModel`、`RecordingTranscriptionManager` |
| 镜子封面 | `Mirror/` | `HomeDashboardModel` |
| 文件中转 | `FileRelay/`（独立副本和 `index.json`） | `FileRelayModel` |
| 偏好 | `UserDefaults`（`appearance` 取 `system` / `light` / `black`，其余如 `excludedApps`、`island.lastDestination`、`island.workspaceSize`、`fileRelay.removeAfterDrag`） | `PreferencesStore` 等 |
| 模块开关 | `UserDefaults`（`module.terminalEnabled`、`module.recordingEnabled`、`module.mirrorEnabled` 均默认 `true`） | `PreferencesStore` |
| 首页组件隐藏偏好 | `UserDefaults`（`home.hiddenWidgets` 保存用户手动隐藏的组件） | `HomeDashboardModel` |

钥匙串服务名（三者互相独立，不能混用）：
- `com.clipflow.mac.credentials`：剪切板里的 API Key 分组
- `com.clipflow.mac.vibehub.agent`：Vibehub Agent 的模型 API Key
- `com.clipflow.mac.recording-asr`：录音转写服务的 API Key

SQLite 结构变更：在 `SQLiteStore.swift` 里用 `CREATE TABLE IF NOT EXISTS` 加上带默认值的 `ALTER TABLE ADD COLUMN`，参考 `prompts.sortOrder` 的写法，必须兼容旧库。

`ClipFlowKit/JSONFileStore.swift` 为每日复盘、备忘录、Vibehub 话术和文件中转索引负责创建父目录、JSON 编解码与原子写入。调用方保留各自的数据路径、字段、首次加载行为、读取错误处理与保存时机。

## 8. 核心不变量（改动前必读）

- **Bundle ID 固定为 `com.clipflow.mac`**，数据目录名 `ClipFlow` 也不能改。改了会让老用户丢数据，更新器也会拒绝安装。
- **双主题和导航**：已有 `appearance` 原始值 `system`、`black` 必须可读写，`light` 强制白天。主窗口与文件小兜同步解析外观，原生模糊层不参与动画；终端 WebView 按有效外观重绘调色板并保留会话。主窗 SwiftUI 与 AppKit 共用 30pt 连续圆角。两种主题共用顶部导航，默认六项，终端关闭时为五项。鼠标、快捷键和模块关闭引发的切页都禁用动画事务。
- **镜子卡片**：常态只展示画面；管理模式才叠加编辑控件。宽高比在横向 16:9、竖向 9:16 中选择，自动模式使用考虑 EXIF 方向的照片元数据，实时摄像头默认横向。只在载入或更换照片时更新方向，布局不读磁盘。无封面时显示本地占位，随机照片请求只由用户点击触发。
- **笔记延迟保存**：备忘录和快速便签在编辑期间只改内存。只有在关闭编辑界面、离开首页、隐藏窗口、退出应用时，才通过 `homeModel.flushNotes()` 统一保存。保存失败时要保留内容，允许重试，并阻止隐藏或退出（见 `PanelController.hide` 和 `prepareForTermination`）。不要改成实时保存，也不要在备忘录列表内切换记录时提前保存。`run-memo-self-test.sh` 会检查这条规则。
- **Vibehub**：话术编辑会自动保存，切换页面、隐藏、退出时调用 `vibeHubLibrary.flush()`。Agent 整理的结果**只有用户手动确认后才写入**。关闭、取消或隐藏时清空输入和预览，**不保存草稿**。原文必须原样保留（包括空格和换行）。
- **模板与知识库**。提示词的分组、搜索、收藏、调用和变量填写继续使用 SQLite 的 `prompts` 表。Vibehub 的完整原文、适用场景、术语定义与含义继续通过独立的 `VibeHub/phrases.json` 存储。两页用现有搜索占位、空态与帮助文案说明用途。
- **剪切板**：连续相同的内容按 SHA-256 去重；应用自己写回剪贴板产生的 changeCount 要忽略；历史保留最近 150 条非收藏项，收藏项额外保留。插入与淘汰使用同一 SQLite 事务，`insertWithHistoryChanges` 返回实际存储的记录和淘汰 ID，`ClipboardLibraryModel.receive` 按 `copiedAt DESC, id DESC` 增量更新内存及选中状态。取消收藏后超出额度时同样淘汰最旧非收藏项。默认排除 1Password、钥匙串访问、终端。复制 API Key 分组的内容时，不能被记录成普通历史。
- **资料库观察范围**：剪切板、提示词和 API Key 的列表与编辑器直接观察对应领域模型。剪切板的搜索词由历史与 API Key 分组共用，API Key 只匹配名称。协调器单独发布供工作区使用的聚合弹层开关。剪贴板增量更新不得经过协调器转发观察通知，面板自检验证这一点。
- **剪切板与提示词导航**：页面及快捷键由 `ToolDestination` 决定。`PanelController` 保留最近使用的资料库页，用于重新展开时恢复原有的首项选中规则。从剪贴板「保存为提示词」成功后，通过同一导航进入提示词页；保存失败时保留当前页面和编辑内容。
- **写回剪贴板**：只写入 `NSPasteboard`，**禁止用模拟粘贴代替**（DESIGN.md 有规定）。提示词的使用记录不能和剪切板历史混在一起存。
- **不产生隐式网络请求**：例如复制链接时不去抓取网页标题。新增联网功能必须由用户主动触发，并在 README 的隐私章节写明。
- **按需加载**：首次显示终端页才创建会话并挂载 WKWebView，之后切页保留会话；查询是否已加载或正在选择文件夹不创建会话。打开录音工作台或录音完成且已配置自动转写时才创建转写管理器，创建时绑定删除回调；隐藏和关闭只操作已存在的播放器。应用目录只在展开的面板显示应用页或首页可见组件包含「最近使用」时加载，恢复该组件时也会触发。直接打开设置时，终端和应用目录延迟到显示对应页面后再加载。
- **模块开关**。关闭终端后隐藏入口，停用 `⌘6`。当前页面或启动恢复页为终端时，立即无动画回到首页并保存该页面。关闭已加载的 shell 会话，解除 WKWebView 消息处理器并释放视图和会话。重新开启后首次进入终端才创建新会话。
- **录音模块关闭**。结束录制中或暂停的录音并保存文件，作废待处理的麦克风授权回调。关闭录音工作台，取消转写任务，释放播放器和转写管理器。关闭时结束的录音不触发自动转写。录音、已保存字幕和转写配置均保留。
- **镜子模块关闭**。立即停止预览和待处理的摄像头启动请求，在采集队列停止会话并移除设备输入；设置隐藏「首页照片」，保留本地封面。重新开启时恢复镜子原来的显示或隐藏状态，用户可手动启动摄像头。
- **首页组件可用性**。关闭录音或镜子会把对应组件从网格和「已隐藏」恢复入口同时过滤。模块状态独立于 `home.hiddenWidgets`，重新开启后恢复原有的显示或隐藏状态。
- **录音删除**：工作台删除需要二次确认，永久删除录音及其字幕 JSON、TXT；正在录制或暂停的当前文件不可删除。删除须取消转写、停止并重置对应播放器、清理缓存与选中状态，并同步首页录音组件；部分文件删除失败需向用户报告。自检使用注入的临时录音目录和独立偏好，不触碰真实录音或钥匙串。
- **文件中转小兜**：保留 `FileRelay/index.json` 格式和每项独立副本；连续导入必须串行排队且逐项容错。小兜贴合刘海下沿居中悬垂，背景外观同步 `PreferencesStore.appearance`（Jaimo Flow 主题），界面仅展示文件图标/缩略图与文件名，不添加额外工具栏、描述和可见按钮（预览/复制/定位/移除/清空收进文件右键菜单与刘海菜单）。拖出仅在成功且用户启用 `fileRelay.removeAfterDrag` 时移除对应副本，默认关闭。固定或原生拖出期间不得自动收起，固定时外部点击也不能收起；工具站和小兜互斥。拖拽剪贴板在结束后可能保留旧文件 URL，必须以空闲 changeCount 排除旧数据，并在拖出期间禁用拖入识别；松手、接收拖放及拖出结束后刷新基准。面板自检使用临时目录和独立偏好。
- **隐藏窗口**：立即停止接受输入并释放摄像头。主面板的全局外部点击、本地与全局指针、键盘监听在展开时安装，收起动画结束时卸载，销毁时兜底。动画的异步回调要确认当前仍是同一次隐藏，不能误关用户快速重新唤出的窗口或卸载重新展开后的监听。
- **动效**：时长和弹簧参数统一从 `FlowMotion` 读取；必须支持系统「减弱动态效果」；切换页面时不加动画。具体数值以 `DESIGN.md` 为准。

## 9. 常见任务做法

- **新增一个页面**：在 `ToolDestination` 中加 case（包括 title 和 symbolName）→ 在 `IslandRootView` 中接上视图 → 在 `PanelController` 中补 ⌘数字 快捷键和离开页面时的保存逻辑 → 更新 README 的快捷键列表。
- **新增首页组件**：`HomeDashboardModel.WidgetID` + `HomeWidgetRegistry` → 在 `HomeDashboardView` 中渲染。尺寸遵循 `HomeWidgetSize` 和 DESIGN.md 的 Bento 规则。
- **新增需要密钥的功能**：用 `CredentialStore(service: "com.clipflow.mac.<功能名>")` 单独建一个服务名；接口地址等非敏感配置放 UserDefaults。远程地址必须是 HTTPS，本机地址可以用 HTTP。
- **发布新版本**：改 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 和递增 `CFBundleVersion` → 写 `docs/releases/vX.Y.Z.md` → 更新 README 的版本信息 → 运行自检和 `package-dmg.sh` → 按第 1 节安装到 `/Applications` 并验证。GitHub Release 的 tag 必须是 `vX.Y.Z`，并与 plist 版本一致；发布时设为 latest，并同时上传 DMG 与同名 `.sha256`。资产要符合 README「应用内更新」一节的契约，否则用户端更新器会拒绝安装。
- **DMG 兼容入口**：`package-dmg.sh` 会在 DMG 里放一个隐藏的软链接 `Jaimo clip.app`，供 0.3.x–0.5.0 的旧更新器使用，不要删除。

## 10. 坑与禁区

- `AppearanceRootView` 和 `FileRelayAppearanceView` 在内容层覆盖有效色彩方案；向宿主窗口写入 `preferredColorScheme` 会使返回“跟随系统”时仍继承上一次强制外观。面板自检会在系统浅深色之间切换验证原生材质。
- `PanelController` 将同一个 `PreferencesStore` 传给 `IslandShellModel`，并把 `preferences.defaults` 传给默认的 `HomeDashboardModel`；面板自检中创建的临时窗口控制器（如超大尺寸适配验证）必须在对应断言后立即收起并释放，且注入隔离的 `UserDefaults` 与临时备忘录目录，避免残留全屏窗口遮挡屏幕或污染 `UserDefaults.standard`（如 `island.lastDestination`）。
- 模块开关的 `@Published` 订阅使用发布的新值，因为回调发出时偏好属性和 `UserDefaults` 仍可能是旧值。摄像头的停止和新启动通过同一串行队列执行，旧的启动回调只认当前操作 ID。
- `TopNotchController.handleEvent` 只在处理左键拖拽及松开时访问拖拽剪贴板。普通移动直接走指针路径，并保留 `handlePointerEvent` 可注入拖拽状态的自检入口。
- 自检录音和剪贴板增量时分别注入临时录音目录及 SQLite 数据库，应用目录偏好跟随面板使用的 `UserDefaults`。资料库快捷键自检用独立偏好、临时 SQLite、测试剪贴板和独立钥匙串服务。
- 模块开关自检使用独立偏好和临时录音、封面、备忘录与每日复盘数据，验证关闭后录音与封面仍可原样读取。
- SQLite 加载完成时，SwiftUI 可能尚未注册预览按钮的 Return 快捷键。面板自检让主线程事件循环继续处理布局，在限定时间内经 AppKit 分派真实快捷键，并校验测试剪贴板内容与对应提示词的使用次数。
- 禁止直接打开或注册 `build/` 里的应用包，也不要把构建产物改回 `.app` 后缀（会出现在启动台和应用搜索里）。
- 禁止修改 Bundle ID、数据目录名、钥匙串服务名，以及 SQLite 中已有的列。
- 自检会链接 App 的所有目标文件，所以只有 `main.swift` 可以写顶层启动代码；其他文件里不要写顶层副作用代码。
- 钥匙串自检使用独立的临时服务名。写新测试时，绝不能读写用户真实的钥匙串条目和数据目录。
- 不要提交 `.build/`、`build/`、`dist/`、证书、`.env`、`lark-*.png`，以及任何本机剪贴板数据。
- 产品范围：第一版不加入云同步、账户、Windows 支持或第三方插件市场。
- 用户可见文字（界面、错误提示、权限说明）使用简体中文。
