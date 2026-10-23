import ClipFlowKit
import Foundation
import SwiftUI

@MainActor
final class DailyReviewModel: ObservableObject {
    @Published var draftText: String
    @Published private(set) var entries: [DailyReviewEntry]
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeDate: Date

    private let store: DailyReviewStore?

    init(fileURL: URL? = nil, now: Date = .now) {
        activeDate = now
        do {
            let store = try DailyReviewStore(fileURL: fileURL)
            self.store = store
            entries = store.entries
            draftText = store.entry(for: Self.dateKey(now))?.body ?? ""
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

    func refreshDay(now: Date = .now) {
        let nextKey = Self.dateKey(now)
        guard nextKey != activeDateKey else { return }
        // Keep an unsaved previous-day draft attached to its displayed date.
        guard draftText == (store?.entry(for: activeDateKey)?.body ?? "") else { return }
        activeDate = now
        draftText = store?.entry(for: nextKey)?.body ?? ""
    }

    @discardableResult
    func save() -> Bool {
        guard let store else {
            errorMessage = errorMessage ?? "无法读取本机复盘记录，请检查存储文件。"
            return false
        }
        do {
            try store.save(dateKey: activeDateKey, body: draftText)
            entries = store.entries
            errorMessage = nil
            refreshDay()
            return true
        } catch {
            errorMessage = "复盘保存失败，输入的内容仍在编辑框中：\(error.localizedDescription)"
            return false
        }
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
                .frame(width: 75, alignment: .leading)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1)

                TextEditor(text: $model.draftText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSecondary)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("今天的复盘内容")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
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
                                ScrollView {
                                    Text(entry.body)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.foregroundSecondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .padding(16)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(width: min(proxy.size.width - 28, 720), height: min(proxy.size.height - 28, 520))
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .onAppear { selectedDateKey = model.entries.first?.dateKey }
    }

    private var selectedEntry: DailyReviewEntry? {
        model.entries.first { $0.dateKey == selectedDateKey } ?? model.entries.first
    }

    private func dateLabel(_ key: String) -> String {
        guard let date = DailyReviewModel.date(from: key) else { return key }
        return date.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }
}
