import AppKit
import ClipFlowKit
import CoreGraphics
import UniformTypeIdentifiers

@MainActor
final class CaptureSession {
    private var panels: [CapturePanel] = []
    private let completion: (NSImage?, Bool) -> Void
    private var finished = false

    init(completion: @escaping (NSImage?, Bool) -> Void) { self.completion = completion }

    func start() -> Bool {
        let screens = NSScreen.screens
        let captures: [(NSScreen, CGImage)] = screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let image = CGDisplayCreateImage(id) else { return nil }
            return (screen, image)
        }
        guard captures.count == screens.count, !captures.isEmpty else { return false }
        for (screen, image) in captures {
            let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.isReleasedWhenClosed = false
            let view = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
            view.onFinish = { [weak self] image, pin in self?.finish(image, pin: pin) }
            view.onSave = { [weak self] image in self?.save(image, on: screen) }
            panel.contentView = view
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.forEach { $0.makeKeyAndOrderFront(nil) }
        if let mouseScreen = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { mouseScreen.makeKey() }
        return true
    }
    func cancel() { finish(nil, pin: false) }
    private func save(_ image: NSImage, on screen: NSScreen) {
        guard !finished else { return }
        panels.forEach { $0.orderOut(nil) }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        savePanel.nameFieldStringValue = "截图 \(formatter.string(from: Date())).png"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                guard let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
                      let data = representation.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                finish(nil, pin: false)
                return
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "无法保存截图"
                alert.runModal()
            }
        }
        guard !finished else { return }
        panels.forEach { $0.makeKeyAndOrderFront(nil) }
        panels.first(where: { $0.screen == screen })?.makeKey()
    }
    private func finish(_ image: NSImage?, pin: Bool) {
        guard !finished else { return }
        finished = true
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        completion(image, pin)
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct Mark {
    var tool: CaptureDrawTool
    var points: [CGPoint]
    var text: String = ""
    var colorIndex: Int = 0
    var strokeWidth: CaptureStrokeWidth = .regular

    var logicMark: CaptureAnnotationMark {
        CaptureAnnotationMark(
            tool: tool,
            points: points.map { ($0.x, $0.y) },
            text: text,
            colorIndex: colorIndex,
            strokeWidth: strokeWidth
        )
    }

    var strokeColor: NSColor {
        let color = CaptureAnnotationColor.color(at: colorIndex)
        let base = NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        return tool == .highlight ? base.withAlphaComponent(0.5) : base
    }

    var lineWidth: CGFloat { CGFloat(strokeWidth.resolvedWidth(for: tool)) }
}

private final class CaptureTextField: NSTextField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class CaptureView: NSView, NSTextFieldDelegate {
    let image: CGImage
    private let bitmap: NSBitmapImageRep
    var onFinish: ((NSImage?, Bool) -> Void)?
    var onSave: ((NSImage) -> Void)?
    private let blue = NSColor(calibratedRed: 0.03, green: 0.57, blue: 0.95, alpha: 1)
    private var selection: CGRect = .zero
    private var origin: CGPoint = .zero
    private var originalSelection: CGRect = .zero
    private var pointer: CGPoint = .zero
    private var dragging = false
    private var adjustment: Int? // -1 move, 0...7 resize
    private var tool: CaptureDrawTool = .select
    private var colorIndex = 0
    private var strokeWidth: CaptureStrokeWidth = .regular
    private var marks: [Mark] = []
    private var redoMarks: [Mark] = []
    private var draft: Mark?
    private var toolButtons: [NSButton] = []
    private var actionButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var widthButtons: [NSButton] = []
    private var editor: CaptureTextField?
    private var editorPoint: CGPoint = .zero
    private var hexColor = false
    private var shiftIsDown = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage) {
        self.image = image
        self.bitmap = NSBitmapImageRep(cgImage: image)
        super.init(frame: frame)
        wantsLayer = true
        setupToolbar()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawImage(in: bounds, context: context)
        NSColor.black.withAlphaComponent(0.48).setFill(); bounds.fill()
        if selection.width > 1, selection.height > 1 {
            context.saveGState(); context.clip(to: selection); drawImage(in: bounds, context: context)
            drawMarks(context: context, offset: .zero)
            context.restoreGState()
            blue.setStroke(); let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
            for point in handles() {
                let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                blue.setFill(); dot.fill(); NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            let size = "\(Int(selection.width)) × \(Int(selection.height)) pt"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
            let textSize = size.size(withAttributes: attrs)
            let label = CGRect(x: selection.minX, y: max(0, selection.minY - 27), width: textSize.width + 14, height: 23)
            NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
            size.draw(at: CGPoint(x: label.minX + 7, y: label.minY + 3), withAttributes: attrs)
        }
        drawToolbar()
        drawLoupe(context: context)
    }
    private func drawImage(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }
    private func handles() -> [CGPoint] {
        let r = selection
        return [CGPoint(x:r.minX,y:r.minY), CGPoint(x:r.midX,y:r.minY), CGPoint(x:r.maxX,y:r.minY), CGPoint(x:r.maxX,y:r.midY), CGPoint(x:r.maxX,y:r.maxY), CGPoint(x:r.midX,y:r.maxY), CGPoint(x:r.minX,y:r.maxY), CGPoint(x:r.minX,y:r.midY)]
    }
    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(bounds.maxX,max(0,p.x)), y: min(bounds.maxY,max(0,p.y))) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = clamp(convert(event.locationInWindow, from: nil)); pointer = p; origin = p; dragging = true
        if !selection.isEmpty, tool != .select, selection.contains(p) {
            if tool == .text { beginText(at: p); dragging = false; return }
            if tool == .eraser {
                if let index = CaptureHitTesting.topMarkIndex(at: (p.x, p.y), in: marks.map(\.logicMark)) {
                    redoMarks.append(marks.remove(at: index))
                    needsDisplay = true
                }
                dragging = false
                return
            }
            draft = Mark(tool: tool, points: [p], colorIndex: colorIndex, strokeWidth: strokeWidth)
            return
        }
        if !selection.isEmpty, let index = handles().firstIndex(where: { hypot($0.x-p.x,$0.y-p.y) < 10 }) {
            adjustment = index; originalSelection = selection
        } else if !selection.isEmpty && selection.contains(p) {
            adjustment = -1; originalSelection = selection
        } else {
            adjustment = nil; selection = .zero; marks.removeAll(); redoMarks.removeAll(); updateToolbar()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = clamp(convert(event.locationInWindow, from: nil)); pointer = p
        if draft != nil { draft?.points.append(p); needsDisplay = true; return }
        if let adjustment {
            if adjustment == -1 {
                let x = min(max(0, originalSelection.minX + p.x - origin.x), bounds.width - originalSelection.width)
                let y = min(max(0, originalSelection.minY + p.y - origin.y), bounds.height - originalSelection.height)
                let dx = x - originalSelection.minX, dy = y - originalSelection.minY
                selection.origin = CGPoint(x:x,y:y)
                for i in marks.indices { marks[i].points = marks[i].points.map { CGPoint(x:$0.x+dx,y:$0.y+dy) } }
                origin = p; originalSelection = selection
            } else {
                var a = CGPoint(x: originalSelection.minX, y: originalSelection.minY)
                var b = CGPoint(x: originalSelection.maxX, y: originalSelection.maxY)
                if [0,6,7].contains(adjustment) { a.x = p.x }; if [2,3,4].contains(adjustment) { b.x = p.x }
                if [0,1,2].contains(adjustment) { a.y = p.y }; if [4,5,6].contains(adjustment) { b.y = p.y }
                selection = rect(a,b)
            }
        } else { selection = rect(origin,p) }
        updateToolbar(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if let draft { if draft.points.count > 1 { marks.append(draft); redoMarks.removeAll() }; self.draft = nil }
        if selection.width < 3 || selection.height < 3 { selection = .zero }
        updateToolbar(); needsDisplay = true
    }
    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)) }
    override func keyDown(with event: NSEvent) {
        let context: CaptureEscapeContext = editor != nil ? .textEditorOpen : (tool == .select ? .idle : .toolActive)
        guard let command = CaptureHotkeys.command(
            keyCode: event.keyCode,
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            escapeContext: context
        ) else {
            super.keyDown(with: event)
            return
        }
        apply(command)
    }
    override func flagsChanged(with event: NSEvent) {
        let down = event.modifierFlags.contains(.shift)
        if down && !shiftIsDown {
            hexColor.toggle()
            needsDisplay = true
        }
        shiftIsDown = down
    }
    private func apply(_ command: CaptureKeyCommand) {
        switch command {
        case .cancelCapture:
            onFinish?(nil, false)
        case .dismissTextEditor:
            dismissTextEditor(save: false)
        case .backToSelect:
            tool = .select
            updateToolbar()
            needsDisplay = true
        case .copyScreenshot:
            complete(pin: false)
        case .copyPickedColor:
            copyColor()
        case .undo:
            undoMark()
        case .redo:
            redoMark()
        case .save:
            saveAction()
        case .pin:
            pinAction()
        case .setTool(let next):
            tool = CaptureDrawTool.toggling(next, current: tool)
            updateToolbar()
            needsDisplay = true
        case .setColor(let index):
            colorIndex = CaptureAnnotationColor.clampedIndex(index)
            updateToolbar()
            needsDisplay = true
        case .stepStroke(let direction):
            strokeWidth = strokeWidth.stepped(direction)
            updateToolbar()
            needsDisplay = true
        }
    }
    private func beginText(at p: CGPoint) {
        let field = CaptureTextField(frame: CGRect(x:p.x,y:p.y,width:180,height:26))
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = strokeColor(for: colorIndex, tool: .text)
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        field.onCancel = { [weak self] in self?.dismissTextEditor(save: false) }
        addSubview(field); editor = field; editorPoint = p; window?.makeFirstResponder(field)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        dismissTextEditor(save: true)
    }
    private func dismissTextEditor(save: Bool) {
        guard let editor else { return }
        if save, !editor.stringValue.isEmpty {
            marks.append(Mark(tool: .text, points: [editorPoint], text: editor.stringValue, colorIndex: colorIndex, strokeWidth: strokeWidth))
            redoMarks.removeAll()
        }
        editor.onCancel = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        self.editor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    private func strokeColor(for index: Int, tool: CaptureDrawTool) -> NSColor {
        let color = CaptureAnnotationColor.color(at: index)
        let base = NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        return tool == .highlight ? base.withAlphaComponent(0.5) : base
    }
    private func setupToolbar() {
        let tools: [(String, CaptureDrawTool)] = [
            ("rectangle.on.rectangle", .rectangle),
            ("arrow.up.right", .arrow),
            ("pencil", .pen),
            ("highlighter", .highlight),
            ("square.grid.3x3.fill", .mosaic),
            ("textformat", .text),
            ("eraser", .eraser)
        ]
        for (symbol, item) in tools {
            toolButtons.append(makeIconButton(symbol: symbol, title: "\(item.title)（\(item.shortcutLabel)）", action: #selector(selectTool(_:)), tag: tools.firstIndex(where: { $0.1 == item }) ?? 0))
        }
        let actions: [(String, String, Selector)] = [
            ("arrow.uturn.backward", "撤销（⌘Z）", #selector(undoMark)),
            ("arrow.uturn.forward", "重做（⇧⌘Z）", #selector(redoMark)),
            ("xmark", "取消（Esc）", #selector(cancelAction)),
            ("pin.fill", "贴图（⌘P）", #selector(pinAction)),
            ("square.and.arrow.down", "另存为 PNG（⌘S）", #selector(saveAction)),
            ("checkmark", "复制截图（⏎）", #selector(copyAction))
        ]
        for (symbol, title, action) in actions {
            actionButtons.append(makeIconButton(symbol: symbol, title: title, action: action, tag: 0))
        }
        for (index, color) in CaptureAnnotationColor.palette.enumerated() {
            let button = NSButton(frame: .zero)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.title = ""
            button.imagePosition = .noImage
            button.tag = index
            button.target = self
            button.action = #selector(selectColor(_:))
            button.toolTip = "\(color.name)（\(index + 1)）"
            button.setAccessibilityLabel(button.toolTip)
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            button.layer?.borderWidth = 0.6
            addSubview(button)
            colorButtons.append(button)
        }
        for (index, width) in CaptureStrokeWidth.allCases.enumerated() {
            widthButtons.append(makeIconButton(symbol: "lineweight", title: "线宽：\(width.title)（[ / ]）", action: #selector(selectWidth(_:)), tag: index))
            widthButtons[index].title = width.title
            widthButtons[index].imagePosition = .noImage
            widthButtons[index].font = .systemFont(ofSize: 11, weight: .medium)
        }
        updateToolbar()
    }
    private func makeIconButton(symbol: String, title: String, action: Selector, tag: Int) -> NSButton {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.target = self
        button.action = action
        button.tag = tag
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.contentTintColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        addSubview(button)
        return button
    }
    private var toolbarTools: [CaptureDrawTool] { [.rectangle, .arrow, .pen, .highlight, .mosaic, .text, .eraser] }
    private func toolbarFrame() -> CGRect {
        let topWidth = CGFloat(toolButtons.count + actionButtons.count) * 34 + 12
        let bottomWidth = CGFloat(colorButtons.count) * 22 + CGFloat(widthButtons.count) * 28 + 24
        let width = max(topWidth, bottomWidth)
        let height: CGFloat = 68
        let y = selection.maxY + 9 + height <= bounds.height ? selection.maxY + 9 : max(0, selection.minY - height - 9)
        return CGRect(x: min(max(4, selection.maxX - width), max(4, bounds.width - width - 4)), y: y, width: width, height: height)
    }
    private func updateToolbar() {
        let show = selection.width >= 3 && selection.height >= 3 && !dragging
        let bar = toolbarFrame()
        for (i, button) in toolButtons.enumerated() {
            button.isHidden = !show
            button.frame = CGRect(x: bar.minX + 6 + CGFloat(i) * 34, y: bar.minY + 4, width: 32, height: 32)
            let active = i < toolbarTools.count && tool == toolbarTools[i]
            button.layer?.backgroundColor = active ? blue.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        }
        let actionStart = bar.minX + 6 + CGFloat(toolButtons.count) * 34
        for (i, button) in actionButtons.enumerated() {
            button.isHidden = !show
            button.frame = CGRect(x: actionStart + CGFloat(i) * 34, y: bar.minY + 4, width: 32, height: 32)
        }
        for (i, button) in colorButtons.enumerated() {
            button.isHidden = !show
            button.frame = CGRect(x: bar.minX + 8 + CGFloat(i) * 22, y: bar.minY + 44, width: 16, height: 16)
            button.layer?.borderWidth = i == colorIndex ? 2 : 0.6
            button.layer?.borderColor = (i == colorIndex ? blue : NSColor.black.withAlphaComponent(0.35)).cgColor
        }
        let widthStart = bar.minX + 8 + CGFloat(colorButtons.count) * 22 + 8
        for (i, button) in widthButtons.enumerated() {
            button.isHidden = !show
            button.frame = CGRect(x: widthStart + CGFloat(i) * 28, y: bar.minY + 41, width: 26, height: 22)
            let active = CaptureStrokeWidth.allCases.indices.contains(i) && strokeWidth == CaptureStrokeWidth.allCases[i]
            button.layer?.backgroundColor = active ? blue.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        }
    }
    private func drawToolbar() {
        guard !selection.isEmpty, !dragging else { return }
        let path = NSBezierPath(roundedRect: toolbarFrame(), xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.96, alpha: 0.98).setFill(); path.fill()
        NSColor(calibratedWhite: 0.7, alpha: 0.8).setStroke(); path.lineWidth = 0.7; path.stroke()
    }
    private func drawMarks(context: CGContext, offset: CGPoint) {
        context.saveGState(); context.translateBy(x:offset.x,y:offset.y)
        for mark in marks + (draft.map { [$0] } ?? []) {
            guard let first = mark.points.first else { continue }
            let last = mark.points.last ?? first
            if mark.tool == .text {
                mark.text.draw(at: first, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                    .foregroundColor: mark.strokeColor
                ])
                continue
            }
            if mark.tool == .mosaic {
                let area = rect(first, last).intersection(bounds)
                let sx = CGFloat(image.width)/bounds.width, sy = CGFloat(image.height)/bounds.height
                let block: CGFloat = 10
                if !area.isEmpty {
                    var y = area.minY
                    while y < area.maxY {
                        var x = area.minX
                        while x < area.maxX {
                            let px = min(image.width-1,max(0,Int((x+block/2)*sx)))
                            let py = min(image.height-1,max(0,Int((y+block/2)*sy)))
                            (bitmap.colorAt(x:px,y:py) ?? .gray).setFill()
                            CGRect(x:x,y:y,width:min(block,area.maxX-x),height:min(block,area.maxY-y)).fill()
                            x += block
                        }
                        y += block
                    }
                }
                continue
            }
            let path = NSBezierPath(); path.lineCapStyle = .round; path.lineJoinStyle = .round
            mark.strokeColor.setStroke()
            path.lineWidth = mark.lineWidth
            if mark.tool == .rectangle { path.appendRect(rect(first,last)) }
            else if mark.tool == .arrow {
                path.move(to:first); path.line(to:last)
                let angle = atan2(last.y-first.y,last.x-first.x), length: CGFloat = 13
                path.move(to:CGPoint(x:last.x-length*cos(angle-0.5),y:last.y-length*sin(angle-0.5))); path.line(to:last)
                path.line(to:CGPoint(x:last.x-length*cos(angle+0.5),y:last.y-length*sin(angle+0.5)))
            } else { path.move(to:first); mark.points.dropFirst().forEach { path.line(to:$0) } }
            path.stroke()
        }
        context.restoreGState()
    }
    private func sampledColor() -> NSColor {
        let x = min(image.width-1,max(0,Int(pointer.x * CGFloat(image.width)/bounds.width)))
        let y = min(image.height-1,max(0,Int(pointer.y * CGFloat(image.height)/bounds.height)))
        return (bitmap.colorAt(x:x,y:y) ?? .black).usingColorSpace(.deviceRGB) ?? .black
    }
    private func colorString() -> String {
        let c = sampledColor(); let r = Int((c.redComponent*255).rounded()), g = Int((c.greenComponent*255).rounded()), b = Int((c.blueComponent*255).rounded())
        return hexColor ? String(format:"#%02X%02X%02X",r,g,b) : "\(r),  \(g),  \(b)"
    }
    private func copyColor() { let p = NSPasteboard.general; p.clearContents(); p.setString(colorString(), forType:.string) }
    private func drawLoupe(context: CGContext) {
        guard bounds.contains(pointer), editor == nil else { return }
        let width: CGFloat = 180, height: CGFloat = 174
        let x = pointer.x + 22 + width < bounds.width ? pointer.x + 22 : max(0,pointer.x-width-22)
        let y = pointer.y + 22 + height < bounds.height ? pointer.y + 22 : max(0,pointer.y-height-22)
        let box = CGRect(x:x,y:y,width:width,height:height)
        let preview = CGRect(x:x,y:y,width:width,height:112)
        NSColor.black.withAlphaComponent(0.9).setFill(); box.fill()
        let sx = CGFloat(image.width)/bounds.width, sy = CGFloat(image.height)/bounds.height
        let source = CGRect(x:max(0,min(CGFloat(image.width)-31,pointer.x*sx-15)),y:max(0,min(CGFloat(image.height)-21,pointer.y*sy-10)),width:31,height:21).integral
        if let cropped = image.cropping(to:source) {
            context.saveGState(); context.interpolationQuality = .none
            context.translateBy(x:preview.minX,y:preview.maxY); context.scaleBy(x:1,y:-1)
            context.draw(cropped,in:CGRect(x:0,y:0,width:preview.width,height:preview.height)); context.restoreGState()
        }
        blue.withAlphaComponent(0.65).setStroke()
        let cross = NSBezierPath(); cross.lineWidth = 1; cross.move(to:CGPoint(x:preview.midX,y:preview.minY)); cross.line(to:CGPoint(x:preview.midX,y:preview.maxY)); cross.move(to:CGPoint(x:preview.minX,y:preview.midY)); cross.line(to:CGPoint(x:preview.maxX,y:preview.midY)); cross.stroke()
        blue.setFill(); CGRect(x:x,y:y+112,width:width,height:4).fill()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.white]
        "(\(Int(pointer.x)), \(Int(pointer.y)))".draw(at:CGPoint(x:x+9,y:y+120),withAttributes:attrs)
        sampledColor().setFill(); CGRect(x:x+9,y:y+139,width:13,height:13).fill()
        colorString().draw(at:CGPoint(x:x+27,y:y+138),withAttributes:attrs)
        "C 复制颜色 · Shift 切换".draw(at:CGPoint(x:x+9,y:y+156),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.white])
    }
    private func renderedSelection() -> NSImage? {
        guard selection.width >= 3, selection.height >= 3 else { return nil }
        if editor != nil { window?.makeFirstResponder(self) }
        let sx = CGFloat(image.width)/bounds.width, sy = CGFloat(image.height)/bounds.height
        let crop = CGRect(x:selection.minX*sx,y:selection.minY*sy,width:selection.width*sx,height:selection.height*sy).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let base = image.cropping(to:crop), let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:base.width,pixelsHigh:base.height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let graphics = NSGraphicsContext(bitmapImageRep:rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.draw(base, in:CGRect(x:0,y:0,width:base.width,height:base.height))
        ctx.translateBy(x:0,y:CGFloat(base.height)); ctx.scaleBy(x:sx,y:-sy)
        drawMarks(context:ctx,offset:CGPoint(x:-selection.minX,y:-selection.minY))
        graphics.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: selection.size); result.addRepresentation(rep)
        return result
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard toolbarTools.indices.contains(sender.tag) else { return }
        apply(.setTool(toolbarTools[sender.tag]))
    }
    @objc private func selectColor(_ sender: NSButton) { apply(.setColor(sender.tag)) }
    @objc private func selectWidth(_ sender: NSButton) {
        guard CaptureStrokeWidth.allCases.indices.contains(sender.tag) else { return }
        strokeWidth = CaptureStrokeWidth.allCases[sender.tag]
        updateToolbar()
        needsDisplay = true
    }
    @objc private func undoMark() { if let mark = marks.popLast() { redoMarks.append(mark); needsDisplay = true } }
    @objc private func redoMark() { if let mark = redoMarks.popLast() { marks.append(mark); needsDisplay = true } }
    @objc private func cancelAction() { onFinish?(nil,false) }
    private func complete(pin: Bool) {
        guard let image = renderedSelection() else { return }
        onFinish?(image, pin)
    }
    @objc private func pinAction() { complete(pin:true) }
    @objc private func saveAction() { if let image = renderedSelection() { onSave?(image) } }
    @objc private func copyAction() { complete(pin:false) }
}
