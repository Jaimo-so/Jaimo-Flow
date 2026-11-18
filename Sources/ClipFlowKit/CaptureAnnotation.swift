import Foundation

public enum CaptureDrawTool: String, CaseIterable, Equatable, Sendable {
    case select
    case rectangle
    case arrow
    case pen
    case highlight
    case mosaic
    case text
    case eraser

    public var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlight: return "荧光笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .eraser: return "橡皮擦"
        }
    }

    public var shortcutLabel: String {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .arrow: return "A"
        case .pen: return "B"
        case .highlight: return "H"
        case .mosaic: return "M"
        case .text: return "T"
        case .eraser: return "E"
        }
    }

    public var tooltip: String {
        "\(title)（\(shortcutLabel)）"
    }

    /// 再次选择当前工具时回到选择模式，与工具栏按钮一致。
    public static func toggling(_ tool: CaptureDrawTool, current: CaptureDrawTool) -> CaptureDrawTool {
        tool == current && tool != .select ? .select : tool
    }
}

public struct CaptureAnnotationColor: Equatable, Sendable {
    public let name: String
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(name: String, red: Double, green: Double, blue: Double) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let palette: [CaptureAnnotationColor] = [
        .init(name: "红色", red: 1, green: 0.231, blue: 0.188),
        .init(name: "橙色", red: 1, green: 0.584, blue: 0),
        .init(name: "黄色", red: 1, green: 0.8, blue: 0),
        .init(name: "绿色", red: 0.204, green: 0.78, blue: 0.349),
        .init(name: "蓝色", red: 0.04, green: 0.52, blue: 1),
        .init(name: "白色", red: 1, green: 1, blue: 1),
        .init(name: "黑色", red: 0.1, green: 0.1, blue: 0.1)
    ]

    public static var `default`: CaptureAnnotationColor { palette[0] }

    public static func clampedIndex(_ index: Int) -> Int {
        min(palette.count - 1, max(0, index))
    }

    public static func color(at index: Int) -> CaptureAnnotationColor {
        palette[clampedIndex(index)]
    }
}

public enum CaptureStrokeWidth: Int, CaseIterable, Equatable, Sendable {
    case thin = 2
    case regular = 3
    case thick = 6

    public var title: String {
        switch self {
        case .thin: return "细"
        case .regular: return "中"
        case .thick: return "粗"
        }
    }

    public var lineWidth: Double { Double(rawValue) }

    public var highlightWidth: Double { Double(rawValue) * 4 }

    public func resolvedWidth(for tool: CaptureDrawTool) -> Double {
        tool == .highlight ? highlightWidth : lineWidth
    }

    public func stepped(_ direction: Int) -> CaptureStrokeWidth {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let next = min(all.count - 1, max(0, index + direction))
        return all[next]
    }
}

public enum CaptureEscapeContext: Equatable, Sendable {
    case textEditorOpen
    case toolActive
    case idle
}

public enum CaptureKeyCommand: Equatable, Sendable {
    case cancelCapture
    case dismissTextEditor
    case backToSelect
    case copyScreenshot
    case copyPickedColor
    case undo
    case redo
    case save
    case pin
    case setTool(CaptureDrawTool)
    case setColor(Int)
    case stepStroke(Int)
}

public enum CaptureHotkeys {
    public static let escape: UInt16 = 53
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let keyC: UInt16 = 8
    public static let keyZ: UInt16 = 6
    public static let keyS: UInt16 = 1
    public static let keyY: UInt16 = 16
    public static let keyV: UInt16 = 9
    public static let keyR: UInt16 = 15
    public static let keyA: UInt16 = 0
    public static let keyB: UInt16 = 11
    public static let keyH: UInt16 = 4
    public static let keyM: UInt16 = 46
    public static let keyT: UInt16 = 17
    public static let keyE: UInt16 = 14
    public static let keyP: UInt16 = 35
    public static let leftBracket: UInt16 = 33
    public static let rightBracket: UInt16 = 30
    public static let digit1: UInt16 = 18

    public static func command(
        keyCode: UInt16,
        command: Bool,
        shift: Bool,
        option: Bool = false,
        control: Bool = false,
        escapeContext: CaptureEscapeContext = .idle
    ) -> CaptureKeyCommand? {
        if escapeContext == .textEditorOpen {
            return keyCode == escape ? .dismissTextEditor : nil
        }
        if option || control {
            return nil
        }

        if command {
            switch keyCode {
            case keyZ: return shift ? .redo : .undo
            case keyY: return .redo
            case keyS: return .save
            case keyC: return .copyScreenshot
            case keyP: return .pin
            default: return nil
            }
        }

        switch keyCode {
        case escape:
            return escapeContext == .toolActive ? .backToSelect : .cancelCapture
        case returnKey, keypadEnter:
            return .copyScreenshot
        case keyC:
            return .copyPickedColor
        case keyV:
            return .setTool(.select)
        case keyR:
            return .setTool(.rectangle)
        case keyA:
            return .setTool(.arrow)
        case keyB:
            return .setTool(.pen)
        case keyH:
            return .setTool(.highlight)
        case keyM:
            return .setTool(.mosaic)
        case keyT:
            return .setTool(.text)
        case keyE:
            return .setTool(.eraser)
        case leftBracket:
            return .stepStroke(-1)
        case rightBracket:
            return .stepStroke(1)
        default:
            if keyCode >= digit1 && keyCode <= digit1 + 6 {
                return .setColor(Int(keyCode - digit1))
            }
            return nil
        }
    }
}

public struct CaptureAnnotationMark: Equatable, Sendable {
    public var tool: CaptureDrawTool
    public var points: [(x: Double, y: Double)]
    public var text: String
    public var colorIndex: Int
    public var strokeWidth: CaptureStrokeWidth

    public init(
        tool: CaptureDrawTool,
        points: [(x: Double, y: Double)],
        text: String = "",
        colorIndex: Int = 0,
        strokeWidth: CaptureStrokeWidth = .regular
    ) {
        self.tool = tool
        self.points = points
        self.text = text
        self.colorIndex = CaptureAnnotationColor.clampedIndex(colorIndex)
        self.strokeWidth = strokeWidth
    }

    public static func == (lhs: CaptureAnnotationMark, rhs: CaptureAnnotationMark) -> Bool {
        lhs.tool == rhs.tool
            && lhs.text == rhs.text
            && lhs.colorIndex == rhs.colorIndex
            && lhs.strokeWidth == rhs.strokeWidth
            && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
    }
}

public enum CaptureHitTesting {
    public static func topMarkIndex(
        at point: (x: Double, y: Double),
        in marks: [CaptureAnnotationMark],
        threshold: Double = 8
    ) -> Int? {
        for index in marks.indices.reversed() {
            if hits(point, marks[index], threshold: threshold) {
                return index
            }
        }
        return nil
    }

    public static func hits(
        _ point: (x: Double, y: Double),
        _ mark: CaptureAnnotationMark,
        threshold: Double
    ) -> Bool {
        guard let first = mark.points.first else { return false }
        let last = mark.points.last ?? first
        switch mark.tool {
        case .select, .eraser:
            return false
        case .text:
            let width = max(24, Double(max(1, mark.text.count)) * 11)
            let box = padded(
                minX: first.x,
                minY: first.y,
                maxX: first.x + width,
                maxY: first.y + 24,
                by: threshold
            )
            return contains(point, box)
        case .rectangle, .mosaic:
            let padding = max(threshold, mark.strokeWidth.lineWidth / 2)
            let box = padded(
                minX: min(first.x, last.x),
                minY: min(first.y, last.y),
                maxX: max(first.x, last.x),
                maxY: max(first.y, last.y),
                by: padding
            )
            return contains(point, box)
        case .arrow, .pen, .highlight:
            let width = mark.strokeWidth.resolvedWidth(for: mark.tool)
            return distanceToPolyline(point, mark.points) <= max(threshold, width / 2 + 2)
        }
    }

    public static func distanceToPolyline(
        _ point: (x: Double, y: Double),
        _ points: [(x: Double, y: Double)]
    ) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }
        var best = Double.infinity
        for index in 1..<points.count {
            best = min(best, distanceToSegment(point, points[index - 1], points[index]))
        }
        return best
    }

    public static func distanceToSegment(
        _ point: (x: Double, y: Double),
        _ start: (x: Double, y: Double),
        _ end: (x: Double, y: Double)
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = dx * dx + dy * dy
        guard length > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private static func padded(minX: Double, minY: Double, maxX: Double, maxY: Double, by amount: Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (minX - amount, minY - amount, maxX + amount, maxY + amount)
    }

    private static func contains(
        _ point: (x: Double, y: Double),
        _ box: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    ) -> Bool {
        point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY
    }
}
