import AppKit
import CoreText
import ApparateCore

struct PanelRowContent: Equatable {
    let id: String, usageID: String, title: String, location: String, kind: String
    let itemKind: ItemKind
    let fileURL: URL?
    let highlights: [Int], icon: ItemIcon
    let selected: Bool, number: Int?
    init(_ row: PanelRow, model: PanelModel, index: Int) {
        id = row.entry.item.id; title = row.entry.item.name; itemKind = row.entry.item.kind
        fileURL = row.entry.target.fileURL
        usageID = row.usageID
        selected = id == model.selectedID
        location = selected && model.restartArmed ? "Press Return again" : row.locationOverride ?? PanelText.location(row.entry)
        highlights = row.result.highlights; icon = row.entry.icon
        switch row.entry.item.kind {
        case .app: kind = "Application"
        case .setting: kind = "Setting"
        case .folder: kind = "Folder"
        case .file: kind = "File"
        case .command: kind = "Command"
        case .web: kind = "Web search"
        }
        number = model.visibleRange.contains(index) ? index - model.firstVisibleRow + 1 : nil
    }
}

/// Cached Core Text layout, shared by every row in the current viewport.
@MainActor struct PanelRowDrawing {
    let height: CGFloat
    let iconFrame: NSRect, titleFrame: NSRect, locationFrame: NSRect, hintFrame: NSRect
    let title: CTLine, location: CTLine?, hint: CTLine?
    let titleTruncated: Bool, locationTruncated: Bool
    let highlightedRanges: [NSRange]
    private let locationRightAligned: Bool
    private static func line(_ text: NSAttributedString) -> CTLine { CTLineCreateWithAttributedString(text) }
    private static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
    init(content: PanelRowContent, width: CGFloat, layout: ResultLocation = .inline) {
        height = layout.rowHeight
        locationRightAligned = layout == .right
        let font = NSFont.systemFont(ofSize: 13)
        let foreground = content.selected ? NSColor.alternateSelectedControlTextColor : .labelColor
        let secondary = content.selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let text = NSMutableAttributedString(string: content.title, attributes: attrs)
        highlightedRanges = PanelText.highlightRanges(content.title, offsets: content.highlights)
        for range in highlightedRanges { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: range) }
        let fullTitle = Self.line(text)
        let iconSize = layout.iconSize.points
        iconFrame = NSRect(x: 9, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        hintFrame = NSRect(x: width - 39, y: 0, width: 30, height: height)
        let start = iconFrame.maxX + 9, end = hintFrame.minX - 9, available = max(0, end - start)
        let titleWidth = min(available, ceil(Self.width(fullTitle)))
        titleTruncated = Self.width(fullTitle) > available
        let below = layout == .below && !content.location.isEmpty
        titleFrame = NSRect(x: start, y: below ? 4 : 0, width: titleWidth, height: below ? 16 : height)
        let token = Self.line(NSAttributedString(string: "…", attributes: attrs))
        title = titleTruncated ? (CTLineCreateTruncatedLine(fullTitle, Double(available), .end, token) ?? token) : fullTitle
        let gap: CGFloat = layout == .inline ? 10 : 16
        let locationStart = below ? start : start + titleWidth + gap
        let remaining = max(0, end - locationStart)
        if !content.location.isEmpty && (below || remaining >= 32) {
            let locationAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: below ? 11 : 12), .foregroundColor: secondary]
            let fullLocation = Self.line(NSAttributedString(string: content.location, attributes: locationAttrs))
            let ellipsis = Self.line(NSAttributedString(string: "…", attributes: locationAttrs))
            locationTruncated = Self.width(fullLocation) > remaining
            location = locationTruncated ? CTLineCreateTruncatedLine(fullLocation, Double(remaining), .middle, ellipsis) : fullLocation
            locationFrame = NSRect(x: locationStart, y: below ? 21 : 0, width: remaining, height: below ? 14 : height)
        } else { location = nil; locationFrame = .zero; locationTruncated = false }
        hint = content.number.map { Self.line(NSAttributedString(string: "⌘\($0)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary])) }
    }
    func draw(content: PanelRowContent, in rect: NSRect, icon: NSImage?) {
        if content.selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let symbol = icon?.isTemplate == true ? icon?.withSymbolConfiguration(.init(paletteColors: [content.selected ? .alternateSelectedControlTextColor : .secondaryLabelColor])) : icon
        symbol?.draw(in: iconFrame.offsetBy(dx: rect.minX, dy: rect.minY), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        func drawLine(_ line: CTLine, frame: NSRect, right: Bool = false) {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: right ? frame.maxX - width : frame.minX,
                y: height - frame.maxY + ((frame.height - ascent - descent) / 2).rounded(.down) + descent)
            CTLineDraw(line, context)
        }
        drawLine(title, frame: titleFrame)
        if let location { drawLine(location, frame: locationFrame, right: locationRightAligned) }
        if let hint { drawLine(hint, frame: hintFrame, right: true) }
    }
}
