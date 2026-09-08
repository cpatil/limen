import Cocoa

/// One titled column: a heading strip above a scrolling list.
///
/// Exists so the two columns can live inside an NSSplitView, which gives a draggable
/// divider and remembers where it was put, rather than being painted at a fixed
/// halfway line.
final class ColumnView: NSView {
    let title: String
    let tint: NSColor
    let list: TrafficListView
    let scroll = NSScrollView()

    private let labelHeight: CGFloat = 24

    init(title: String, tint: NSColor, list: TrafficListView) {
        self.title = title
        self.tint = tint
        self.list = list
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
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
        var f = list.frame
        f.size.width = scroll.contentView.bounds.width
        f.size.height = max(CGFloat(list.rows.count) * TrafficListView.rowHeight,
                            scroll.contentView.bounds.height)
        list.frame = f
    }
}
