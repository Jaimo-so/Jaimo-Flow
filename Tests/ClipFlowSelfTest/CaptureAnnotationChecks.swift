import Foundation

#if canImport(ClipFlowKit)
import ClipFlowKit
#endif

/// 截图标注快捷键、线宽、颜色与橡皮擦命中的纯逻辑检查。返回检查条数。
func runCaptureAnnotationChecks() throws -> Int {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        try require(condition, message)
    }

    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyR, command: false, shift: false) == .setTool(.rectangle),
        "R 应切换到矩形"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyA, command: false, shift: false) == .setTool(.arrow),
        "A 应切换到箭头"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyB, command: false, shift: false) == .setTool(.pen),
        "B 应切换到画笔"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyH, command: false, shift: false) == .setTool(.highlight),
        "H 应切换到荧光笔"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyM, command: false, shift: false) == .setTool(.mosaic),
        "M 应切换到马赛克"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyT, command: false, shift: false) == .setTool(.text),
        "T 应切换到文字"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyE, command: false, shift: false) == .setTool(.eraser),
        "E 应切换到橡皮擦"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyV, command: false, shift: false) == .setTool(.select),
        "V 应回到选择"
    )

    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyZ, command: true, shift: false) == .undo,
        "⌘Z 应撤销"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyZ, command: true, shift: true) == .redo,
        "⇧⌘Z 应重做"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyY, command: true, shift: false) == .redo,
        "⌘Y 应重做"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyS, command: true, shift: false) == .save,
        "⌘S 应另存为"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyC, command: true, shift: false) == .copyScreenshot,
        "⌘C 应复制截图"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyC, command: false, shift: false) == .copyPickedColor,
        "单独按 C 应复制取色"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyP, command: true, shift: false) == .pin,
        "⌘P 应贴图"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.returnKey, command: false, shift: false) == .copyScreenshot,
        "回车应复制截图"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keypadEnter, command: false, shift: false) == .copyScreenshot,
        "小键盘回车应复制截图"
    )

    try expect(
        CaptureHotkeys.command(
            keyCode: CaptureHotkeys.escape,
            command: false,
            shift: false,
            escapeContext: .textEditorOpen
        ) == .dismissTextEditor,
        "输入文字时 Esc 应取消输入"
    )
    try expect(
        CaptureHotkeys.command(
            keyCode: CaptureHotkeys.keyR,
            command: false,
            shift: false,
            escapeContext: .textEditorOpen
        ) == nil,
        "输入文字时字母键不应切换工具"
    )
    try expect(
        CaptureHotkeys.command(
            keyCode: CaptureHotkeys.escape,
            command: false,
            shift: false,
            escapeContext: .toolActive
        ) == .backToSelect,
        "使用标注工具时 Esc 应回到选择"
    )
    try expect(
        CaptureHotkeys.command(
            keyCode: CaptureHotkeys.escape,
            command: false,
            shift: false,
            escapeContext: .idle
        ) == .cancelCapture,
        "选择模式下 Esc 应取消截图"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.keyR, command: false, shift: false, option: true) == nil,
        "Option 组合键不应触发工具切换"
    )

    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.leftBracket, command: false, shift: false) == .stepStroke(-1),
        "[ 应减小线宽"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.rightBracket, command: false, shift: false) == .stepStroke(1),
        "] 应增大线宽"
    )
    try expect(CaptureStrokeWidth.regular.stepped(-1) == .thin, "中线宽再细一档应为细")
    try expect(CaptureStrokeWidth.thin.stepped(-1) == .thin, "最细线宽不应再减小")
    try expect(CaptureStrokeWidth.regular.stepped(1) == .thick, "中线宽再粗一档应为粗")
    try expect(CaptureStrokeWidth.thick.stepped(1) == .thick, "最粗线宽不应再增大")
    try expect(CaptureStrokeWidth.regular.resolvedWidth(for: .pen) == 3, "画笔默认线宽应为 3")
    try expect(CaptureStrokeWidth.regular.resolvedWidth(for: .highlight) == 12, "荧光笔默认线宽应保持 12")

    try expect(CaptureAnnotationColor.palette.count == 7, "应提供 7 种标注颜色")
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.digit1, command: false, shift: false) == .setColor(0),
        "1 应选择第一种颜色"
    )
    try expect(
        CaptureHotkeys.command(keyCode: CaptureHotkeys.digit1 + 6, command: false, shift: false) == .setColor(6),
        "7 应选择最后一种颜色"
    )
    try expect(CaptureAnnotationColor.color(at: 99).name == "黑色", "过大的颜色索引应夹紧到最后一种颜色")
    try expect(CaptureAnnotationColor.color(at: -3).name == "红色", "负的颜色索引应夹紧到第一种颜色")
    try expect(CaptureDrawTool.toggling(.rectangle, current: .rectangle) == .select, "再次选择当前工具应回到选择")
    try expect(CaptureDrawTool.toggling(.rectangle, current: .arrow) == .rectangle, "选择其他工具应直接切换")
    try expect(CaptureDrawTool.toggling(.select, current: .select) == .select, "选择工具不应被切换掉")

    let rectangle = CaptureAnnotationMark(tool: .rectangle, points: [(10, 10), (40, 40)])
    try expect(CaptureHitTesting.topMarkIndex(at: (25, 25), in: [rectangle]) == 0, "点击矩形内部应命中")
    try expect(CaptureHitTesting.topMarkIndex(at: (80, 80), in: [rectangle]) == nil, "远离矩形不应命中")

    let line = CaptureAnnotationMark(tool: .pen, points: [(0, 0), (100, 0)])
    try expect(CaptureHitTesting.topMarkIndex(at: (50, 4), in: [line]) == 0, "靠近画笔路径应命中")
    try expect(CaptureHitTesting.topMarkIndex(at: (50, 40), in: [line]) == nil, "远离画笔路径不应命中")
    try expect(
        abs(CaptureHitTesting.distanceToSegment((0, 3), (0, 0), (10, 0)) - 3) < 0.0001,
        "点到线段的垂直距离计算错误"
    )

    let text = CaptureAnnotationMark(tool: .text, points: [(20, 20)], text: "Hello")
    try expect(CaptureHitTesting.topMarkIndex(at: (30, 25), in: [text]) == 0, "点击文字区域应命中")
    try expect(CaptureHitTesting.topMarkIndex(at: (200, 200), in: [text]) == nil, "远离文字不应命中")

    let rear = CaptureAnnotationMark(tool: .rectangle, points: [(0, 0), (50, 50)])
    let front = CaptureAnnotationMark(tool: .pen, points: [(0, 25), (50, 25)])
    try expect(
        CaptureHitTesting.topMarkIndex(at: (25, 25), in: [rear, front]) == 1,
        "重叠时应删除最上层标注"
    )

    return checks
}
