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
    /// Optional control shown at the right of the heading strip - the per-section sort
    /// picker. It lives here rather than in the toolbar so that it plainly belongs to
    /// this list, and so the toolbar stays short.
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory = accessory { addSubview(accessory) }
            needsLayout = true
        }
    }

    /// A panel between the heading band and the list - this section's own totals.
    /// Inside the column, so it is always exactly as wide as the list beneath it.
    var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header = header { addSubview(header, positioned: .below, relativeTo: nil) }
            needsLayout = true
        }
    }
    var headerHeight: CGFloat = 0

    private let labelHeight: CGFloat = 28

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
            return history.items.reduce(0) { $0 + $1.height(width: scroll.contentView.bounds.width) }
        }
        return content.frame.height
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // A banded heading with a rule under it, in the section's own colour at full
        // strength. Small grey capitals in the same field as the rows read as another
        // row; a band reads as a divider, which is what it is.
        let band = NSRect(x: 0, y: bounds.maxY - labelHeight,
                          width: bounds.width, height: labelHeight)
        // Tinted in the section's own colour rather than neutral grey: it separates the
        // sections far harder than type alone, and tells them apart at a glance even
        // when they are stacked and the words are out of the corner of your eye.
        tint.withAlphaComponent(0.18).setFill()
        band.fill()

        tint.withAlphaComponent(0.9).setFill()
        NSRect(x: 0, y: band.minY, width: 4, height: band.height).fill()
        NSRect(x: 0, y: band.minY, width: bounds.width, height: 1).fill()

        Text.draw(title,
                  at: NSPoint(x: 16, y: band.minY + (labelHeight - 13) / 2),
                  font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                  color: tint,
                  tracking: 1.2)
    }

    override func layout() {
        super.layout()
        if let accessory = accessory {
            let size = accessory.fittingSize
            let width = min(max(112, size.width), max(80, bounds.width - 110))
            accessory.frame = NSRect(x: bounds.maxX - width - 12,
                                     y: bounds.maxY - labelHeight + (labelHeight - 20) / 2 - 1,
                                     width: width, height: 20)
        }
        let headerSpace = header == nil ? 0 : headerHeight
        header?.frame = NSRect(x: 0, y: max(0, bounds.height - labelHeight - headerSpace),
                               width: bounds.width, height: headerSpace)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width,
                              height: max(0, bounds.height - labelHeight - headerSpace))
        var f = content.frame
        f.size.width = scroll.contentView.bounds.width
        f.size.height = max(contentHeight, scroll.contentView.bounds.height)
        content.frame = f
    }
}
