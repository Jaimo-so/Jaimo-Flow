import SwiftUI

struct HomeWidgetSpan: LayoutValueKey {
    static let defaultValue = 1
}

struct HomeWidgetHeight: LayoutValueKey {
    static let defaultValue: CGFloat = 206
}

struct HomeWidgetAspectRatio: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Flat, stable children preserve editor identity during moves. Each row fills
/// the available width; photos keep a fixed aspect ratio within the row’s bounded height.
struct HomeWidgetLayout: Layout {
    let columns: Int
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        HomeWidgetGeometry.frames(
            width: width,
            columns: columns,
            spacing: spacing,
            items: subviews.map { .init(span: $0[HomeWidgetSpan.self], height: $0[HomeWidgetHeight.self], aspectRatio: $0[HomeWidgetAspectRatio.self]) }
        )
    }
}

/// Pure geometry also lets us verify compact, resized and hidden-widget layouts.
enum HomeWidgetGeometry {
    struct Item {
        let span: Int
        let height: CGFloat
        var aspectRatio: CGFloat = 0
    }

    static func frames(width: CGFloat, columns: Int, spacing: CGFloat, items: [Item]) -> [CGRect] {
        let columns = max(1, columns)
        var result: [CGRect] = []
        var row: [Item] = []
        var usedColumns = 0
        var y: CGFloat = 0

        func appendRow() {
            guard !row.isEmpty else { return }
            let rowHeight = row.map(\.height).max() ?? 0
            let available = max(0, width - CGFloat(row.count - 1) * spacing)
            let unitWidth = available / CGFloat(usedColumns)
            let fixedWidths = row.map { item in
                item.aspectRatio > 0
                    ? min(unitWidth * CGFloat(item.span), item.height * item.aspectRatio)
                    : 0
            }
            let flexibleSpans = row.filter { $0.aspectRatio <= 0 }.reduce(0) { $0 + $1.span }
            let flexibleUnitWidth = flexibleSpans > 0
                ? (available - fixedWidths.reduce(0, +)) / CGFloat(flexibleSpans)
                : 0
            var x: CGFloat = 0
            for (index, item) in row.enumerated() {
                let fixed = item.aspectRatio > 0
                let cardWidth = fixed ? fixedWidths[index] : flexibleUnitWidth * CGFloat(item.span)
                let cardHeight = fixed ? cardWidth / item.aspectRatio : rowHeight
                result.append(CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
                x += cardWidth + spacing
            }
            y += rowHeight + spacing
            row.removeAll(keepingCapacity: true)
            usedColumns = 0
        }

        for item in items {
            let span = min(columns, max(1, item.span))
            if usedColumns + span > columns { appendRow() }
            row.append(Item(span: span, height: item.height, aspectRatio: item.aspectRatio))
            usedColumns += span
            if usedColumns == columns { appendRow() }
        }
        appendRow()
        return result
    }
}
