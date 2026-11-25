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
| 核心自检 | `./Scripts/run-self-test.sh` |
| 钥匙串自检 | `./Scripts/run-credential-self-test.sh` |
| 备忘录/便签自检 | `./Scripts/run-memo-self-test.sh` |
| 面板自检 | `./Scripts/run-panel-self-test.sh` |
| Vibehub 自检 | `./Scripts/run-vibehub-self-test.sh` |
| Vibehub Agent 自检 | `./Scripts/run-vibehub-agent-self-test.sh`（模拟模型响应，不联网） |
| 录音转写自检 | `./Scripts/run-recording-asr-self-test.sh` |
| 重新生成图标 | `swift Scripts/generate-icon.swift Resources/AppLogo.png Resources/AppIcon.icns` |

- 所有脚本都通过 `Scripts/swift-sdk-path.sh` 自动挑选与当前编译器兼容的 SDK，不要手写 `swift build` 绕开它。
- **自检的原理**：先 `swift build --product ClipFlow`（debug），再把 `ClipFlow.build/*.o` 中**除 `main.swift.o` 以外**的目标文件，和 `Tests/<Name>/main.swift` 一起用 `swiftc` 链接成新的可执行文件。所以测试能直接访问 App target 的 internal 类型。断言失败时用 `fatalError` 或 `exit(1)`。
- **新增自检**：在 `Tests/<Name>/main.swift` 写测试，再复制一个 `Scripts/run-*-self-test.sh` 改路径。链接 App 目标文件时必须添加 `CTerminal.build` 模块搜索路径和 `CTerminal.build/*.o`（参考 `run-panel-self-test.sh`），因为 App 模块依赖终端。
- 提交前：运行相关自检 + `package-dmg.sh`。

## 5. 目录地图

```
Sources/
  ClipFlow/          主 App target（UI、窗口、系统集成），约 1.3 万行
  ClipFlowKit/       与 UI 无关的核心：模型、SQLite、分类、分块、钥匙串、Release 解析
  ClipFlowUpdater/   独立的更新助手进程：备份 → 替换 → 失败回滚 → 重启
  CSQLite/           SQLite 系统库 modulemap
  CTerminal/         forkpty 启动登录 shell、调整 pty 尺寸（C）
Tests/<Name>/main.swift   各自检程序
Resources/           Info.plist（版本号、更新源）、AppIcon.icns、AppLogo.png、Terminal/（xterm）
Scripts/             构建、打包、自检、SDK 探测、图标生成
docs/releases/       每个版本的发布说明；docs/images/ 是 README 截图
DESIGN.md            当前设计语言（颜色、动效时长、布局尺寸、交互规范）
*-handoff-spec.md   早期方案与实现契约，只作历史参考，不代表当前实现
build/ .build/ dist/ 构建产物（已 gitignore）
```

## 6. 运行时架构

```
main.swift → AppDelegate（@MainActor）
  ├─ PreferencesStore         UserDefaults 偏好（外观、排除应用、工作区尺寸…）
  ├─ AppModel                 剪切板历史、提示词、API Key 分组、toast；持有 UpdateManager 和两个扩展
  │    └─ SQLiteClipStore（ClipFlowKit）
  ├─ ClipboardMonitor         每 0.4s 轮询 NSPasteboard.changeCount → CapturedClip → 写入 store
  ├─ PanelController          主 NSPanel（ClipFlowPanel）的显示/隐藏/动画/退出前保存
  │    ├─ IslandShellModel    当前页面 ToolDestination；懒加载 TerminalSession、VibeHub 模型
  │    ├─ HomeDashboardModel  首页组件布局、快速便签、镜子
  │    └─ IslandRootView      顶部导航 + 各页面视图
  ├─ HotKeyManager            Carbon 注册 ⌥Space → panelController.toggleHotKey()
  └─ TopNotchController       顶部刘海 NSPanel：主体展开工具站，耳翼和拖拽打开连体 FileRelayPanel
```

页面与文件对应关系：

| 页面/功能 | 主要文件 |
|---|---|
| 页面外壳与导航 | `IslandShell.swift`（`ToolDestination` 枚举） |
| 首页（Bento 组件） | `HomeDashboardView.swift`、`HomeWidgetLayout.swift`、`DailyReviewWidget.swift`、`MemoLibrary.swift`、`AudioRecorderWidget.swift` |
| 录音转写 | `RecordingTranscription.swift`、`RecordingASRRequest.swift`、`RecordingWorkspaceView.swift`（Qwen3-ASR / OpenAI 兼容接口 `diarized_json` & `verbose_json`、录音后自动转写、通义听悟风格演讲人与时间轴字幕工作台及同步播放器） |
| 应用启动台 | `ApplicationsView.swift`（`ApplicationsModel`） |
| 提示词 | `PromptLibraryView.swift` + `ClipFlowKit/PromptModels.swift`（`{{变量}}` 模板） |
| 剪切板历史 | `ContentView.swift`、`ClipboardMonitor.swift`、`ProgressiveTextView.swift` |
| API Key 分组 | `CredentialLibrary.swift`、`CredentialLibraryView.swift`、`ClipFlowKit/CredentialStore.swift` |
| Vibehub 话术库 / Agent | `VibeHubLibrary*.swift`、`VibeHubAgent*.swift` |
| 终端 | `TerminalView.swift` + `CTerminal/` + `Resources/Terminal/` |
| 截图/贴图、识别翻译 | `ScreenshotExtension.swift`、`CaptureSession.swift`、`TranslationExtension.swift` |
| 文件中转小兜 | `FileRelay.swift`（串行导入、独立副本、极简弧边小兜视图、主题同步、原生拖出、缩略图和右键菜单）、`TopNotchController.swift`（刘海几何与小兜状态） |
| 设置 | `SettingsView.swift` |
| 更新 | `UpdateManager.swift` + `ClipFlowKit/UpdateRelease.swift` + `ClipFlowUpdater/` |
| 主题 / 动效常量 | `Theme.swift`、`Motion.swift`（`FlowMotion`） |

## 7. 数据存储（升级兼容，路径不可改）

根目录是 `~/Library/Application Support/ClipFlow/`：

| 数据 | 位置 | 负责代码 |
|---|---|---|
| 剪切板历史、提示词等 | `ClipFlow.sqlite3`（表 `clips`、`prompts`） | `SQLiteClipStore` |
| 剪切板图片 | `Images/`（SQLite 只存路径） | `SQLiteClipStore` |
| 备忘录 | `Memos/memos.json` | `MemoLibraryModel` |
| 每日复盘 | `DailyReviews/` | `DailyReviewStore` |
| Vibehub 话术 | `VibeHub/phrases.json` | `VibeHubLibraryModel` |
| 录音与转写文字 | `Recordings/`（`.m4a`、`.transcript.json`、`.txt`） | `AudioRecorderModel`、`RecordingTranscriptionManager` |
| 镜子封面 | `Mirror/` | `HomeDashboardModel` |
| 文件中转 | `FileRelay/` | `FileRelayModel` |
| 偏好 | `UserDefaults`（如 `appearance`、`excludedApps`、`island.lastDestination`、`island.workspaceSize`、`fileRelay.removeAfterDrag`） | `PreferencesStore` 等 |

钥匙串服务名（三者互相独立，不能混用）：
- `com.clipflow.mac.credentials`：剪切板里的 API Key 分组
- `com.clipflow.mac.vibehub.agent`：Vibehub Agent 的模型 API Key
- `com.clipflow.mac.recording-asr`：录音转写服务的 API Key

SQLite 结构变更：在 `SQLiteStore.swift` 里用 `CREATE TABLE IF NOT EXISTS` 加上带默认值的 `ALTER TABLE ADD COLUMN`，参考 `prompts.sortOrder` 的写法，必须兼容旧库。

## 8. 核心不变量（改动前必读）

- **Bundle ID 固定为 `com.clipflow.mac`**，数据目录名 `ClipFlow` 也不能改。改了会让老用户丢数据，更新器也会拒绝安装。
- **笔记延迟保存**：备忘录和快速便签在编辑期间只改内存。只有在关闭编辑界面、离开首页、隐藏窗口、退出应用时，才通过 `homeModel.flushNotes()` 统一保存。保存失败时要保留内容，允许重试，并阻止隐藏或退出（见 `PanelController.hide` 和 `prepareForTermination`）。不要改成实时保存，也不要在备忘录列表内切换记录时提前保存。`run-memo-self-test.sh` 会检查这条规则。
- **Vibehub**：话术编辑会自动保存，切换页面、隐藏、退出时调用 `vibeHubLibrary.flush()`。Agent 整理的结果**只有用户手动确认后才写入**。关闭、取消或隐藏时清空输入和预览，**不保存草稿**。原文必须原样保留（包括空格和换行）。
- **剪切板**：连续相同的内容按 SHA-256 去重；应用自己写回剪贴板产生的 changeCount 要忽略；历史上限 150 条，收藏项不会被淘汰；默认排除 1Password、钥匙串访问、终端。复制 API Key 分组的内容时，不能被记录成普通历史。
- **写回剪贴板**：只写入 `NSPasteboard`，**禁止用模拟粘贴代替**（DESIGN.md 有规定）。提示词的使用记录不能和剪切板历史混在一起存。
- **不产生隐式网络请求**：例如复制链接时不去抓取网页标题。新增联网功能必须由用户主动触发，并在 README 的隐私章节写明。
- **录音删除**：工作台删除需要二次确认，永久删除录音及其字幕 JSON、TXT；正在录制或暂停的当前文件不可删除。删除须取消转写、停止并重置对应播放器、清理缓存与选中状态，并同步首页录音组件；部分文件删除失败需向用户报告。自检使用注入的临时录音目录和独立偏好，不触碰真实录音或钥匙串。
- **文件中转小兜**：保留 `FileRelay/index.json` 格式和每项独立副本；连续导入必须串行排队且逐项容错。小兜贴合刘海下沿居中悬垂，背景外观同步 `PreferencesStore.appearance`（Jaimo Flow 主题），界面仅展示文件图标/缩略图与文件名，不添加额外工具栏、描述和可见按钮（预览/复制/定位/移除/清空收进文件右键菜单与刘海菜单）。拖出仅在成功且用户启用 `fileRelay.removeAfterDrag` 时移除对应副本，默认关闭。固定或原生拖出期间不得自动收起，固定时外部点击也不能收起；工具站和小兜互斥。拖拽剪贴板在结束后可能保留旧文件 URL，必须以空闲 changeCount 排除旧数据，并在拖出期间禁用拖入识别；松手、接收拖放及拖出结束后刷新基准。面板自检使用临时目录和独立偏好。
- **隐藏窗口**：立即停止接受输入并释放摄像头。动画的异步回调要确认当前仍是同一次隐藏，不能误关用户快速重新唤出的窗口。
- **动效**：时长和弹簧参数统一从 `FlowMotion` 读取；必须支持系统「减弱动态效果」；切换页面时不加动画。具体数值以 `DESIGN.md` 为准。

## 9. 常见任务做法

- **新增一个页面**：在 `ToolDestination` 中加 case（包括 title 和 symbolName）→ 在 `IslandRootView` 中接上视图 → 在 `PanelController` 中补 ⌘数字 快捷键和离开页面时的保存逻辑 → 更新 README 的快捷键列表。
- **新增首页组件**：`HomeDashboardModel.WidgetID` + `HomeWidgetRegistry` → 在 `HomeDashboardView` 中渲染。尺寸遵循 `HomeWidgetSize` 和 DESIGN.md 的 Bento 规则。
- **新增需要密钥的功能**：用 `CredentialStore(service: "com.clipflow.mac.<功能名>")` 单独建一个服务名；接口地址等非敏感配置放 UserDefaults。远程地址必须是 HTTPS，本机地址可以用 HTTP。
- **发布新版本**：改 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 和递增 `CFBundleVersion` → 写 `docs/releases/vX.Y.Z.md` → 更新 README 的版本信息 → 运行自检和 `package-dmg.sh` → 按第 1 节安装到 `/Applications` 并验证。GitHub Release 的 tag 必须是 `vX.Y.Z`，并与 plist 版本一致；发布时设为 latest，并同时上传 DMG 与同名 `.sha256`。资产要符合 README「应用内更新」一节的契约，否则用户端更新器会拒绝安装。
- **DMG 兼容入口**：`package-dmg.sh` 会在 DMG 里放一个隐藏的软链接 `Jaimo clip.app`，供 0.3.x–0.5.0 的旧更新器使用，不要删除。

## 10. 坑与禁区

- 禁止直接打开或注册 `build/` 里的应用包，也不要把构建产物改回 `.app` 后缀（会出现在启动台和应用搜索里）。
- 禁止修改 Bundle ID、数据目录名、钥匙串服务名，以及 SQLite 中已有的列。
- 自检会链接 App 的所有目标文件，所以只有 `main.swift` 可以写顶层启动代码；其他文件里不要写顶层副作用代码。
- 钥匙串自检使用独立的临时服务名。写新测试时，绝不能读写用户真实的钥匙串条目和数据目录。
- 不要提交 `.build/`、`build/`、`dist/`、证书、`.env`、`lark-*.png`，以及任何本机剪贴板数据。
- 产品范围：第一版不加入云同步、账户、Windows 支持或第三方插件市场。
- 用户可见文字（界面、错误提示、权限说明）使用简体中文。
