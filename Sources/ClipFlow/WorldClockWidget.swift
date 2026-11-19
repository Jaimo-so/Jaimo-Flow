import AppKit
import ClipFlowKit
import SwiftUI

/// 首页“时间”组件：本地时间 + 自选的其他城市时间（时差、跨日提示）。
struct WorldClockWidget: View {
    @ObservedObject var model: HomeDashboardModel
    let size: HomeWidgetSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var pickerOpen = false
    @State private var copiedZone: String?

    private var visibleLimit: Int {
        switch size {
        case .small: return 1
        case .medium: return 3
        case .large: return WorldClock.maxExtraZones
        }
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: model.worldClockZones.isEmpty ? 34 : 28, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    addButton(theme)
                }
                Text(context.date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.foregroundSecondary)
                if model.worldClockZones.isEmpty {
                    if size != .small {
                        Text("点右上角 + 添加其他城市，跨时区沟通时一眼看清对方几点。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(model.worldClockZones.prefix(visibleLimit)), id: \.self) { identifier in
                            zoneRow(identifier, date: context.date, theme: theme)
                        }
                    }
                    if model.worldClockZones.count > visibleLimit {
                        Text("还有 \(model.worldClockZones.count - visibleLimit) 个时区，放大组件可查看")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addButton(_ theme: ClipFlowTheme) -> some View {
        Button { pickerOpen = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(FlowIconButtonStyle())
        .disabled(model.worldClockZones.count >= WorldClock.maxExtraZones)
        .help(model.worldClockZones.count >= WorldClock.maxExtraZones
              ? "最多添加 \(WorldClock.maxExtraZones) 个时区"
              : "添加城市 / 时区")
        .accessibilityLabel("添加时区")
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            WorldClockPicker(excluding: Set(model.worldClockZones + [TimeZone.current.identifier])) { identifier in
                model.addWorldClockZone(identifier)
                pickerOpen = false
            }
        }
    }

    private func zoneRow(_ identifier: String, date: Date, theme: ClipFlowTheme) -> some View {
        let zone = TimeZone(identifier: identifier) ?? .current
        let relation = WorldClock.dayRelation(of: zone, relativeTo: .current, at: date)
        let name = WorldClock.cityName(for: identifier)
        let difference = WorldClock.differenceText(of: zone, relativeTo: .current, at: date)
        return HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Text(copiedZone == identifier ? "已复制" : difference)
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if relation != .today {
                Text(relation.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(theme.chip)
                    .clipShape(Capsule())
                    .foregroundStyle(theme.foregroundSecondary)
            }
            Text(WorldClock.timeText(at: date, in: zone))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { copy(identifier) }
        .help("\(name) · \(WorldClock.utcOffsetText(zone, at: date)) · 双击复制时间")
        .contextMenu {
            Button { copy(identifier) } label: { Label("复制时间", systemImage: "doc.on.doc") }
            Divider()
            Button { model.moveWorldClockZone(identifier, by: -1) } label: { Label("上移", systemImage: "arrow.up") }
                .disabled(model.worldClockZones.first == identifier)
            Button { model.moveWorldClockZone(identifier, by: 1) } label: { Label("下移", systemImage: "arrow.down") }
                .disabled(model.worldClockZones.last == identifier)
            Divider()
            Button(role: .destructive) { model.removeWorldClockZone(identifier) } label: {
                Label("移除", systemImage: "minus.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(relation == .today ? "" : relation.label) \(WorldClock.timeText(at: date, in: zone))，\(difference)")
        .accessibilityAction(named: "复制时间") { copy(identifier) }
        .accessibilityAction(named: "移除") { model.removeWorldClockZone(identifier) }
    }

    private func copy(_ identifier: String) {
        guard let text = WorldClock.copyText(identifier: identifier, at: Date()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedZone = identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedZone == identifier { copiedZone = nil }
        }
    }
}

/// 添加时区的搜索弹窗：支持中文名、英文名、拼音和系统时区标识，↑↓ 选择、↵ 添加。
private struct WorldClockPicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [WorldClockCity] {
        WorldClock.search(query, excluding: excluding, limit: 30)
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let results = self.results
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索城市，如 东京、new york、niuyue", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { pick(at: highlighted, in: results) }
                .onChange(of: query) { _ in highlighted = 0 }
            if results.isEmpty {
                Text("没有匹配的城市或时区")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, city in
                                Button { onPick(city.identifier) } label: {
                                    row(city, highlighted: index == highlighted, theme: theme)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .frame(height: 220)
                    .onChange(of: highlighted) { reader.scrollTo($0) }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { searchFocused = true }
        .background(KeyArrowHandler { offset in
            guard !results.isEmpty else { return }
            highlighted = min(max(highlighted + offset, 0), results.count - 1)
        })
    }

    private func row(_ city: WorldClockCity, highlighted: Bool, theme: ClipFlowTheme) -> some View {
        let zone = TimeZone(identifier: city.identifier) ?? .current
        let now = Date()
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(city.name).font(.system(size: 12, weight: .medium))
                Text(city.identifier).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(WorldClock.timeText(at: now, in: zone)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(WorldClock.utcOffsetText(zone, at: now)).font(.system(size: 10)).foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(highlighted ? theme.chipHigh : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func pick(at index: Int, in results: [WorldClockCity]) {
        guard results.indices.contains(index) else { return }
        onPick(results[index].identifier)
    }
}

/// 在弹窗内监听 ↑↓，不影响输入法组合输入（有 marked text 时不拦截）。
private struct KeyArrowHandler: NSViewRepresentable {
    let onMove: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onMove: onMove) }

    final class Coordinator {
        var onMove: (Int) -> Void
        private var monitor: Any?

        init(onMove: @escaping (Int) -> Void) { self.onMove = onMove }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient, client.hasMarkedText() {
                    return event
                }
                switch event.keyCode {
                case 125: self.onMove(1); return nil
                case 126: self.onMove(-1); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
