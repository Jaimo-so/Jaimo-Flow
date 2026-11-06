import AppKit
import ClipFlowKit
import Foundation
import SwiftUI

@MainActor
final class DailyReviewModel: ObservableObject {
    @Published var draftText: String
    @Published private(set) var entries: [DailyReviewEntry]
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeDate: Date
    @Published private(set) var toastMessage: String?

    private let store: DailyReviewStore?
    private var toastWork: DispatchWorkItem?

    init(fileURL: URL? = nil, now: Date = .now) {
        activeDate = Calendar.current.startOfDay(for: now)
        do {
            let store = try DailyReviewStore(fileURL: fileURL)
            self.store = store
            entries = store.entries
            draftText = store.entry(for: Self.dateKey(activeDate))?.body ?? ""
        } catch {
            store = nil
            entries = []
            draftText = ""
            errorMessage = "复盘记录读取失败，原文件未被修改：\(error.localizedDescription)"
        }
    }

    var activeDateKey: String { Self.dateKey(activeDate) }
    var characterCount: Int { draftText.filter { !$0.isWhitespace }.count }
    var canSave: Bool { !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasUnsavedChanges: Bool {
        draftText != (store?.entry(for: activeDateKey)?.body ?? "")
    }
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(activeDate)
    }
    var canGoToNextDay: Bool {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: activeDate) ?? activeDate
        return Self.dateKey(tomorrow) <= Self.dateKey(Date())
    }

    func refreshDay(now: Date = .now) {
        let today = Calendar.current.startOfDay(for: now)
        let nextKey = Self.dateKey(today)
        guard nextKey != activeDateKey else { return }
        // Keep an unsaved previous-day draft attached to its displayed date.
        guard !hasUnsavedChanges else { return }
        activeDate = today
        draftText = store?.entry(for: nextKey)?.body ?? ""
    }

    func goToPreviousDay() {
        guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: activeDate) else { return }
        selectDate(previous)
    }

    func goToNextDay() {
        guard canGoToNextDay,
              let next = Calendar.current.date(byAdding: .day, value: 1, to: activeDate) else { return }
        selectDate(next)
    }

    func goToToday(now: Date = .now) {
        selectDate(Calendar.current.startOfDay(for: now))
    }

    func selectDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        let key = Self.dateKey(day)
        guard key != activeDateKey else { return }
        if hasUnsavedChanges && canSave {
            guard save(refreshAfterSave: false) else { return }
        }
        activeDate = day
        draftText = store?.entry(for: key)?.body ?? ""
        errorMessage = nil
    }

    @discardableResult
    func save(refreshAfterSave: Bool = true) -> Bool {
        guard let store else {
            errorMessage = errorMessage ?? "无法读取本机复盘记录，请检查存储文件。"
            return false
        }
        do {
            try store.save(dateKey: activeDateKey, body: draftText)
            entries = store.entries
            errorMessage = nil
            if refreshAfterSave {
                refreshDay()
            }
            return true
        } catch {
            errorMessage = "复盘保存失败，输入的内容仍在编辑框中：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteEntry(dateKey: String) -> Bool {
        guard let store else {
            errorMessage = errorMessage ?? "无法读取本机复盘记录，请检查存储文件。"
            return false
        }
        do {
            try store.delete(dateKey: dateKey)
            entries = store.entries
            if dateKey == activeDateKey {
                draftText = ""
            }
            errorMessage = nil
            showToast("已删除该日复盘")
            return true
        } catch {
            errorMessage = "删除复盘失败：\(error.localizedDescription)"
            return false
        }
    }

    func copyEntryBody(_ body: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(body, forType: .string)
        if ok {
            showToast("已复制完整复盘")
        } else {
            showToast("复制失败，请重试")
        }
        return ok
    }

    private func showToast(_ message: String) {
        toastWork?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    static func dateKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(from key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}

struct DailyReviewWidget: View {
    @ObservedObject var model: DailyReviewModel
    let onOpenHistory: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSaveError = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Button {
                            model.goToPreviousDay()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .accessibilityLabel("前一天")

                        Button {
                            model.goToNextDay()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .disabled(!model.canGoToNextDay)
                        .accessibilityLabel("后一天")

                        if !model.isViewingToday {
                            Button("今天") {
                                model.goToToday()
                            }
                            .buttonStyle(GlassButtonStyle(kind: .quiet))
                            .fixedSize()
                            .accessibilityLabel("回到今天")
                        }
                    }

                    Text(model.activeDate.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    Text(String(Calendar.current.component(.day, from: model.activeDate)))
                        .font(.system(size: 43, weight: .medium))
                        .tracking(-2)
                        .monospacedDigit()
                    Text(model.activeDate.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                }
                .frame(width: 92, alignment: .leading)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1)

                ZStack(alignment: .topLeading) {
                    if model.draftText.isEmpty {
                        Text(model.isViewingToday
                             ? "写一点今天的收获、卡点和明天计划…"
                             : "这一天还没有复盘，写完后点保存。")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.muted)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $model.draftText)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.foregroundSecondary)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(model.isViewingToday ? "今天的复盘内容" : "所选日期的复盘内容")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if model.hasUnsavedChanges {
                    Text("未保存")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                Spacer()
                Text("\(model.characterCount) 字")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button("保存复盘") {
                    if !model.save() { showingSaveError = true }
                }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .disabled(!model.canSave)
                .fixedSize()

                Button("历史复盘", action: onOpenHistory)
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .onAppear { model.refreshDay() }
        .alert("无法保存复盘", isPresented: $showingSaveError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "请稍后重试。")
        }
    }
}

struct DailyReviewHistoryOverlay: View {
    @ObservedObject var model: DailyReviewModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDateKey: String?
    @State private var deleteArmed = false
    @State private var showingDeleteError = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(spacing: 0) {
                    HStack {
                        Text("历史复盘")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .accessibilityLabel("关闭历史复盘")
                    }
                    .padding(14)

                    Divider().overlay(theme.hairline)

                    if model.entries.isEmpty {
                        Text("保存第一篇复盘后，就能在这里查看。")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(spacing: 0) {
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(model.entries) { entry in
                                        Button {
                                            selectedDateKey = entry.dateKey
                                            deleteArmed = false
                                        } label: {
                                            Text(dateLabel(entry.dateKey))
                                                .font(.system(size: 11.5))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(9)
                                                .background(selectedEntry?.dateKey == entry.dateKey ? theme.selection : Color.clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(selectedEntry?.dateKey == entry.dateKey ? [.isSelected] : [])
                                    }
                                }
                                .padding(9)
                            }
                            .frame(width: min(180, max(120, proxy.size.width * 0.29)))

                            Divider().overlay(theme.hairline)

                            if let entry = selectedEntry {
                                VStack(spacing: 0) {
                                    ScrollView {
                                        Text(entry.body)
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.foregroundSecondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                            .padding(16)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                    Divider().overlay(theme.hairline)

                                    HStack(spacing: 8) {
                                        Button {
                                            _ = model.copyEntryBody(entry.body)
                                        } label: {
                                            Label("复制全文", systemImage: "doc.on.doc")
                                        }
                                        .buttonStyle(GlassButtonStyle(kind: .normal))
                                        .fixedSize()

                                        Button("编辑此日") {
                                            if let date = DailyReviewModel.date(from: entry.dateKey) {
                                                model.selectDate(date)
                                            }
                                            onClose()
                                        }
                                        .buttonStyle(GlassButtonStyle(kind: .primary))
                                        .fixedSize()

                                        Button(deleteArmed ? "确认删除" : "删除") {
                                            if deleteArmed {
                                                if model.deleteEntry(dateKey: entry.dateKey) {
                                                    deleteArmed = false
                                                    selectedDateKey = model.entries.first?.dateKey
                                                } else {
                                                    showingDeleteError = true
                                                }
                                            } else {
                                                deleteArmed = true
                                            }
                                        }
                                        .buttonStyle(GlassButtonStyle(kind: deleteArmed ? .danger : .quiet))
                                        .fixedSize()

                                        if deleteArmed {
                                            Button("取消") { deleteArmed = false }
                                                .buttonStyle(GlassButtonStyle(kind: .quiet))
                                                .fixedSize()
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .padding(12)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(width: min(proxy.size.width - 28, 720), height: min(proxy.size.height - 28, 520))
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let toast = model.toastMessage {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            selectedDateKey = model.entries.first?.dateKey
            deleteArmed = false
        }
        .onChange(of: selectedDateKey) { _ in deleteArmed = false }
        .alert("无法删除复盘", isPresented: $showingDeleteError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "请稍后重试。")
        }
    }

    private var selectedEntry: DailyReviewEntry? {
        model.entries.first { $0.dateKey == selectedDateKey } ?? model.entries.first
    }

    private func dateLabel(_ key: String) -> String {
        guard let date = DailyReviewModel.date(from: key) else { return key }
        return date.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }
}
