import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum HomeWidgetSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "小型"
        case .medium: return "中型"
        case .large: return "大型"
        }
    }

    var cardHeight: CGFloat {
        switch self {
        case .small: return 178
        case .medium: return 206
        case .large: return 280
        }
    }
}

enum MirrorAspect: String, CaseIterable, Identifiable {
    case automatic, landscape, portrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .landscape: return "横向 16:9"
        case .portrait: return "竖向 9:16"
        }
    }
}

struct HomeWidgetDescriptor: Identifiable {
    let id: HomeDashboardModel.WidgetID
    let title: String
    let defaultOrder: Int
    let defaultVisibility: Bool
    let defaultSize: HomeWidgetSize
    let allowedSizes: [HomeWidgetSize]
}

enum HomeWidgetRegistry {
    static let descriptors: [HomeWidgetDescriptor] = [
        .init(id: .quickNote, title: "快速便签", defaultOrder: 0, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .recentApplications, title: "最近使用", defaultOrder: 1, defaultVisibility: true, defaultSize: .small, allowedSizes: [.small, .medium, .large]),
        .init(id: .audioRecorder, title: "录音", defaultOrder: 2, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .memo, title: "备忘录", defaultOrder: 3, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .camera, title: "镜子", defaultOrder: 4, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .dailyReview, title: "每日复盘", defaultOrder: 5, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium]),
        .init(id: .clock, title: "时间", defaultOrder: 6, defaultVisibility: false, defaultSize: .small, allowedSizes: [.small, .medium])
    ]

    static var orderedIDs: [HomeDashboardModel.WidgetID] {
        descriptors.sorted { $0.defaultOrder < $1.defaultOrder }.map(\.id)
    }

    static func descriptor(for id: HomeDashboardModel.WidgetID) -> HomeWidgetDescriptor {
        descriptors.first { $0.id == id }
            ?? .init(id: id, title: id.rawValue, defaultOrder: .max, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium])
    }
}

@MainActor
final class HomeDashboardModel: ObservableObject {
    // Keep recording alive when the dashboard is hidden or recreated during navigation.
    let audioRecorder: AudioRecorderModel
    let camera = CameraCheckModel()
    @Published private var recordingEnabled = true
    @Published private var mirrorEnabled = true
    @Published private(set) var recordingTranscription: RecordingTranscriptionManager?
    let memoLibrary: MemoLibraryModel
    let dailyReview: DailyReviewModel

    enum WidgetID: String, CaseIterable, Identifiable {
        case dailyReview
        case clock
        case quickNote
        case memo
        case audioRecorder
        case camera
        case recentApplications

        var id: String { rawValue }

        var title: String {
            HomeWidgetRegistry.descriptor(for: self).title
        }
    }

    enum QuickNoteSaveStatus: Equatable {
        case pending
        case saving
        case saved
        case failed

        var text: String {
            switch self {
            case .pending: return "关闭时保存 · 仅本机"
            case .saving: return "正在保存…"
            case .saved: return "已保存 · 仅本机"
            case .failed: return "保存失败，内容已保留，请重试"
            }
        }
    }

    // The native editor owns live text. Notify the dashboard only when its
    // dirty/empty state changes, never for every keystroke or marked-text update.
    var quickNote: String {
        didSet {
            if quickNote != oldValue, quickNoteSaveStatus == .saved {
                quickNoteSaveStatus = .pending
            } else if quickNote.isEmpty != oldValue.isEmpty {
                objectWillChange.send()
            }
        }
    }
    @Published private(set) var quickNoteSaveStatus: QuickNoteSaveStatus = .saved
    @Published private(set) var widgetOrder: [WidgetID]
    @Published private(set) var hiddenWidgets: Set<WidgetID>
    @Published private(set) var widgetSizes: [WidgetID: HomeWidgetSize]
    @Published private(set) var editingWidget: WidgetID?
    @Published private(set) var mirrorPhotoURL: URL?
    private var portraitMirrorPhoto = false
    @Published private(set) var mirrorPhotoError: String?
    @Published private(set) var isLoadingMirrorPhoto = false
    @Published var mirrorAspect: MirrorAspect {
        didSet { defaults.set(mirrorAspect.rawValue, forKey: Key.mirrorAspect) }
    }
    @Published var memoLibraryOpen = false
    @Published var dailyReviewHistoryOpen = false
    @Published private(set) var recordingWorkspaceOpen = false

    private enum Key {
        static let quickNote = "home.quickNote"
        static let widgetOrder = "home.widgetOrder"
        static let hiddenWidgets = "home.hiddenWidgets"
        static let widgetSizes = "home.widgetSizes"
        static let mirrorAspect = "home.mirrorAspect"
    }

    private let defaults: UserDefaults
    private let recordingsDirectory: URL?
    private let mirrorDirectoryOverride: URL?

    init(defaults: UserDefaults = .standard, memoLibrary: MemoLibraryModel? = nil,
         recordingsDirectory: URL? = nil, dailyReview: DailyReviewModel? = nil, mirrorDirectory: URL? = nil) {
        self.defaults = defaults
        self.recordingsDirectory = recordingsDirectory
        mirrorDirectoryOverride = mirrorDirectory
        audioRecorder = AudioRecorderModel(recordingsDirectory: recordingsDirectory)
        self.memoLibrary = memoLibrary ?? MemoLibraryModel()
        self.dailyReview = dailyReview ?? DailyReviewModel()
        mirrorAspect = MirrorAspect(rawValue: defaults.string(forKey: Key.mirrorAspect) ?? "") ?? .automatic
        quickNote = defaults.string(forKey: Key.quickNote) ?? ""

        let registeredIDs = HomeWidgetRegistry.orderedIDs
        let savedOrder = defaults.stringArray(forKey: Key.widgetOrder) ?? []
        let decodedOrder = savedOrder.compactMap(WidgetID.init(rawValue:))
        let missing = registeredIDs.filter { !decodedOrder.contains($0) }
        widgetOrder = decodedOrder + missing

        let hidden = defaults.stringArray(forKey: Key.hiddenWidgets) ?? []
        let defaultHidden = missing.filter {
            !HomeWidgetRegistry.descriptor(for: $0).defaultVisibility
        }
        hiddenWidgets = Set(hidden.compactMap(WidgetID.init(rawValue:))).union(defaultHidden)
        let savedSizes = defaults.dictionary(forKey: Key.widgetSizes) as? [String: String] ?? [:]
        widgetSizes = Dictionary(uniqueKeysWithValues: registeredIDs.map { widget in
            let descriptor = HomeWidgetRegistry.descriptor(for: widget)
            let saved = savedSizes[widget.rawValue].flatMap(HomeWidgetSize.init(rawValue:))
            let resolved = saved.flatMap { descriptor.allowedSizes.contains($0) ? $0 : nil }
                ?? descriptor.defaultSize
            return (widget, resolved)
        })
        editingWidget = nil
        mirrorPhotoURL = Self.existingMirrorPhotoURL(directoryOverride: mirrorDirectory)
        if let mirrorPhotoURL,
           let source = CGImageSourceCreateWithURL(mirrorPhotoURL as CFURL, nil) {
            portraitMirrorPhoto = Self.isPortrait(source)
        }
        mirrorPhotoError = nil
        audioRecorder.onDidFinishRecording = { [weak self] url in
            guard let self, self.recordingEnabled,
                  self.recordingTranscription != nil || self.shouldAutoTranscribeRecording else { return }
            self.loadRecordingTranscription().handleNewRecording(url)
        }
    }

    var visibleWidgets: [WidgetID] {
        widgetOrder.filter { isWidgetAvailable($0) && !hiddenWidgets.contains($0) }
    }

    var restorableWidgets: [WidgetID] {
        widgetOrder.filter { isWidgetAvailable($0) && hiddenWidgets.contains($0) }
    }

    func isWidgetAvailable(_ widget: WidgetID) -> Bool {
        switch widget {
        case .audioRecorder: return recordingEnabled
        case .camera: return mirrorEnabled
        default: return true
        }
    }

    func setRecordingEnabled(_ enabled: Bool) {
        guard recordingEnabled != enabled else { return }
        recordingEnabled = enabled
        audioRecorder.setEnabled(enabled)
        if !enabled {
            recordingWorkspaceOpen = false
            recordingTranscription?.shutdown()
            recordingTranscription = nil
            if editingWidget == .audioRecorder { editingWidget = visibleWidgets.first }
        }
    }

    func setMirrorEnabled(_ enabled: Bool) {
        guard mirrorEnabled != enabled else { return }
        mirrorEnabled = enabled
        if !enabled {
            camera.stop()
            if editingWidget == .camera { editingWidget = visibleWidgets.first }
        }
    }

    func move(_ widget: WidgetID, by offset: Int) {
        guard let index = widgetOrder.firstIndex(of: widget) else { return }
        let target = min(max(index + offset, 0), widgetOrder.count - 1)
        guard target != index else { return }
        widgetOrder.remove(at: index)
        widgetOrder.insert(widget, at: target)
        persistLayout()
    }

    func move(_ widget: WidgetID, to targetWidget: WidgetID) {
        guard widget != targetWidget,
              let sourceIndex = widgetOrder.firstIndex(of: widget),
              let targetIndex = widgetOrder.firstIndex(of: targetWidget)
        else { return }
        widgetOrder.remove(at: sourceIndex)
        widgetOrder.insert(widget, at: min(targetIndex, widgetOrder.count))
        editingWidget = widget
        persistLayout()
    }

    func beginEditingWidgets() {
        editingWidget = editingWidget ?? visibleWidgets.first
    }

    func finishEditingWidgets() {
        editingWidget = nil
    }

    func selectWidget(_ widget: WidgetID) {
        editingWidget = widget
    }

    func moveSelectedWidget(by offset: Int) {
        guard let editingWidget else { return }
        move(editingWidget, by: offset)
    }

    func hide(_ widget: WidgetID) {
        hiddenWidgets.insert(widget)
        if editingWidget == widget {
            editingWidget = visibleWidgets.first
        }
        persistLayout()
    }

    func restore(_ widget: WidgetID) {
        guard isWidgetAvailable(widget) else { return }
        hiddenWidgets.remove(widget)
        persistLayout()
    }

    func size(for widget: WidgetID) -> HomeWidgetSize {
        widgetSizes[widget] ?? HomeWidgetRegistry.descriptor(for: widget).defaultSize
    }

    func setSize(_ size: HomeWidgetSize, for widget: WidgetID) {
        guard HomeWidgetRegistry.descriptor(for: widget).allowedSizes.contains(size) else { return }
        widgetSizes[widget] = size
        persistLayout()
    }

    func stepSize(for widget: WidgetID, direction: Int = 1) {
        let allowed = HomeWidgetRegistry.descriptor(for: widget).allowedSizes
        guard allowed.count > 1, let index = allowed.firstIndex(of: size(for: widget)) else { return }
        let target = min(max(index + direction, 0), allowed.count - 1)
        guard target != index else { return }
        setSize(allowed[target], for: widget)
    }

    func chooseMirrorPhoto() {
        guard mirrorEnabled, !isLoadingMirrorPhoto else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择照片"
        guard panel.runModal() == .OK, mirrorEnabled, let sourceURL = panel.url else { return }
        do {
            let extensionName = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            try installMirrorPhoto(Data(contentsOf: sourceURL), extensionName: extensionName)
        } catch {
            mirrorPhotoError = "无法保存照片：\(error.localizedDescription)"
        }
    }

    func randomizeMirrorPhoto() async {
        guard mirrorEnabled, !isLoadingMirrorPhoto else { return }
        isLoadingMirrorPhoto = true
        mirrorPhotoError = nil
        defer { isLoadingMirrorPhoto = false }
        do {
            let url = URL(string: "https://picsum.photos/seed/\(UUID().uuidString)/1600/900.jpg")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard mirrorEnabled else { return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try installMirrorPhoto(data, extensionName: "jpg")
        } catch {
            guard mirrorEnabled else { return }
            mirrorPhotoError = "随机照片加载失败，请重试或选择本地照片。"
        }
    }

    private func installMirrorPhoto(_ data: Data, extensionName: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = try Self.mirrorDirectory(override: mirrorDirectoryOverride)
        let destination = directory.appendingPathComponent("cover.\(UUID().uuidString).\(extensionName)")
        try data.write(to: destination, options: .atomic)
        let oldURL = mirrorPhotoURL
        portraitMirrorPhoto = Self.isPortrait(source)
        mirrorPhotoURL = destination
        mirrorPhotoError = nil
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
    }

    func removeMirrorPhoto() {
        guard mirrorEnabled, !isLoadingMirrorPhoto else { return }
        guard let mirrorPhotoURL else { return }
        do {
            try FileManager.default.removeItem(at: mirrorPhotoURL)
            portraitMirrorPhoto = false
            self.mirrorPhotoURL = nil
            mirrorPhotoError = nil
        } catch {
            mirrorPhotoError = "无法删除照片：\(error.localizedDescription)"
        }
    }

    private static func isPortrait(_ source: CGImageSource) -> Bool {
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int else { return false }
        let orientation = metadata[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? width > height : height > width
    }

    func mirrorAspectRatio(liveCamera: Bool) -> CGFloat {
        switch mirrorAspect {
        case .landscape: return 16 / 9
        case .portrait: return 9 / 16
        case .automatic: return !liveCamera && portraitMirrorPhoto ? 9 / 16 : 16 / 9
        }
    }

    private func persistLayout() {
        defaults.set(widgetOrder.map(\.rawValue), forKey: Key.widgetOrder)
        defaults.set(hiddenWidgets.map(\.rawValue).sorted(), forKey: Key.hiddenWidgets)
        defaults.set(
            Dictionary(uniqueKeysWithValues: widgetSizes.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: Key.widgetSizes
        )
    }

    @discardableResult
    func flushQuickNote() -> Bool {
        guard quickNoteSaveStatus != .saved else { return true }
        quickNoteSaveStatus = .saving
        let value = quickNote
        defaults.set(value, forKey: Key.quickNote)
        quickNoteSaveStatus = defaults.string(forKey: Key.quickNote) == value ? .saved : .failed
        return quickNoteSaveStatus == .saved
    }

    @discardableResult
    func flushNotes() -> Bool {
        let quickNoteSaved = flushQuickNote()
        let memosSaved = memoLibrary.flush()
        return quickNoteSaved && memosSaved
    }

    func closeMemoLibrary() {
        guard memoLibrary.flush() else { return }
        memoLibraryOpen = false
    }

    var isRecordingTranscriptionLoaded: Bool { recordingTranscription != nil }

    var shouldAutoTranscribeRecording: Bool {
        recordingEnabled && RecordingTranscriptionManager.shouldAutoTranscribe(defaults: defaults)
    }

    private func loadRecordingTranscription() -> RecordingTranscriptionManager {
        if let recordingTranscription { return recordingTranscription }
        let transcription = RecordingTranscriptionManager(defaults: defaults, recordingsDirectory: recordingsDirectory)
        transcription.canDeleteRecording = { [weak audioRecorder] url in
            audioRecorder?.canDeleteRecording(url) ?? false
        }
        transcription.onRecordingDeleted = { [weak audioRecorder] url, latest in
            audioRecorder?.recordingWasDeleted(url, latestRemaining: latest)
        }
        recordingTranscription = transcription
        return transcription
    }

    func openRecordingWorkspace(selecting url: URL?) {
        guard recordingEnabled else { return }
        let transcription = loadRecordingTranscription()
        if let url { transcription.selectRecording(url) }
        recordingWorkspaceOpen = true
    }

    func closeRecordingWorkspace() {
        recordingTranscription?.playback.stop()
        recordingTranscription?.showingSettings = false
        recordingWorkspaceOpen = false
    }

    private static func mirrorDirectory(override: URL?) throws -> URL {
        let directory = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("Mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private static func existingMirrorPhotoURL(directoryOverride: URL?) -> URL? {
        guard let directory = try? mirrorDirectory(override: directoryOverride),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return files.first { $0.lastPathComponent.hasPrefix("cover.") }
    }
}
