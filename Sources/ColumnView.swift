import Cocoa

/// One titled column: a heading strip above a scrolling list.
///
/// Exists so the two columns can live inside an NSSplitView, which gives a draggable
/// divider and remembers where it was put, rather than being painted at a fixed
/// halfway line.
final class ColumnView: NSView {
    let title: String
    let tint: NSColor
    let content: NSView
    let scroll = NSScrollView()

    private let labelHeight: CGFloat = 24

    init(title: String, tint: NSColor, content: NSView) {
        self.title = title
        self.tint = tint
        self.content = content
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Natural height of the content, so the scroller knows its range.
    private var contentHeight: CGFloat {
        if let list = content as? TrafficListView {
            return CGFloat(list.rows.count) * TrafficListView.rowHeight
        }
        if let history = content as? HistoryView {
            return history.items.reduce(0) { $0 + $1.height }
        }
        return content.frame.height
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Text.draw(title,
                  at: NSPoint(x: 16, y: bounds.maxY - labelHeight + 6),
                  font: NSFont.systemFont(ofSize: 10, weight: .bold),
                  color: tint)
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width,
                              height: max(0, bounds.height - labelHeight))
        var f = content.frame
        f.size.width = scroll.contentView.bounds.width
        f.size.height = max(contentHeight, scroll.contentView.bounds.height)
        content.frame = f
    }
}
