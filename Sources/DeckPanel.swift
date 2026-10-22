import AppKit
import SwiftUI

// MARK: - Geometry

/// How the deck draws itself once it fans out.
enum DeckStyle: String, CaseIterable {
    case tabs      // labelled vertical tabs — the full deck
    case compact   // colour chips only — barely touches the screen

    var title: String {
        switch self {
        case .tabs: return "Labelled tabs"
        case .compact: return "Colour chips"
        }
    }
}

/// Which screen edge the deck is docked to. Side docks stack their tabs down
/// the edge with the labels turned on their side; the bottom dock runs them
/// across the screen, labels reading flat.
enum DeckEdge: String, CaseIterable {
    case right, left, bottom

    var title: String {
        switch self {
        case .right: return "Right edge"
        case .left: return "Left edge"
        case .bottom: return "Bottom edge"
        }
    }

    var isBottom: Bool { self == .bottom }
}

/// Resolved metrics for one fan. "Long" runs along the docked edge — down it
/// for a side dock, across it for the bottom — and a tab's other dimension is
/// its depth from the edge.
///
/// Tabs *shingle*: each is full length but sits `pitch` along from the one
/// before, so it laps over it like a roof tile. That keeps every tab long
/// enough to carry a label while the deck as a whole stays well short of the
/// screen.
struct DeckLayout {
    var itemLong: CGFloat     // full length of one tab, along the edge
    var pitch: CGFloat        // start-to-start spacing; < itemLong means overlap
    var moreGap: CGFloat
    var moreLong: CGFloat
    var count: Int
    var hasMore: Bool
    var panelLong: CGFloat    // panel extent along the edge

    /// Negative for shingled tabs — stack spacing that produces the overlap.
    var spacing: CGFloat { pitch - itemLong }

    var stackLong: CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * pitch + itemLong
            + (hasMore ? moreGap + moreLong : 0)
    }

    var start: CGFloat { max(12, (panelLong - stackLong) / 2) }

    /// Centre of the strip of item `index` that is actually visible.
    func center(_ index: Int) -> CGFloat {
        let strip = index == count - 1 ? itemLong : pitch
        return start + CGFloat(index) * pitch + strip / 2
    }

    var cap: CGFloat { max(140, panelLong - 76) }
    var overflows: Bool { stackLong > cap }
}

enum DeckGeom {
    // Rest — a 12 pt pill of grey dashes
    static let pillWidth: CGFloat = 12
    static let pillTouchWidth: CGFloat = 14
    static let dashHeight: CGFloat = 14       // dash length, along the edge
    static let dashWidth: CGFloat = 7         // dash depth, out from the edge
    static let dashGap: CGFloat = 5
    static let pillPad: CGFloat = 7
    static let maxDashes = 14

    // Fan
    static let tabWidth: CGFloat = 30
    static let tabHeightMax: CGFloat = 118
    static let tabHeightMin: CGFloat = 58
    static let tabGap: CGFloat = 7
    /// How far the next tab laps over the one before it.
    static let tabLap: CGFloat = 40
    static let pitchMin: CGFloat = 56
    static let pitchMax: CGFloat = 106
    /// The strip is the label plus this much; the label is drawn inside it with
    /// `labelInset`. Keeping the two different is what leaves the last glyph room
    /// — sizing the strip to exactly the text width truncates on rounding.
    static let labelPad: CGFloat = 20
    static let labelInset: CGFloat = 12
    /// Tabs and notes are drawn a little past the screen edge so their lean cannot
    /// open a wedge of background between them and the edge they are stuck to.
    static let bleed: CGFloat = 14

    /// Everything leans the same way — a deck of tabs at matching angles reads as
    /// deliberate, where per-note angles just look scattered.
    static let leanDegrees: Double = 3.0
    static func lean(for edge: DeckEdge) -> Double {
        edge == .left ? leanDegrees : -leanDegrees
    }

    /// Rendered width of a tab label, used to size the strip that shows it.
    /// Must use the same face the tab draws with or the strip will not fit.
    static func labelWidth(_ title: String) -> CGFloat {
        let text = title as NSString
        guard text.length > 0 else { return 0 }
        return text.size(withAttributes: [.font: Ink.tabNSFont]).width
            + Ink.tabTracking * CGFloat(text.length)
    }
    static let chipWidth: CGFloat = 30        // chip depth, out from the edge
    static let chipHeight: CGFloat = 24       // chip length, along the edge
    static let chipGap: CGFloat = 6
    /// How far the fan reaches out from the docked edge.
    static let fanDepth: CGFloat = 50
    static let moreTabHeight: CGFloat = 34

    /// The deck may claim at most this much of the edge before tabs start shrinking.
    static let longBudget: CGFloat = 0.68

    /// The open note carries its own tab as a gutter, so it reads as
    /// growing out of the deck rather than floating beside it.
    static let gutterWidth: CGFloat = 30

    // Expanded — the note slides clear of the deck
    static let editorWidth: CGFloat = 460
    static let editorHeight: CGFloat = 380
    /// The open note runs to the screen edge and covers its own tab, exactly as a
    /// pulled sticky would — so there is no gap between note and deck to tune.
    /// A little deeper than the note so the lean has somewhere to go.
    static func expandedDepth(for edge: DeckEdge) -> CGFloat {
        let noteDepth = edge.isBottom ? editorHeight : editorWidth
        return max(fanDepth, noteDepth) + 22
    }

    /// The pill's length along the docked edge — one grey dash per note.
    static func pillLength(noteCount: Int) -> CGFloat {
        let shown = min(noteCount, maxDashes)
        let n = max(1, shown + (noteCount > maxDashes ? 1 : 0))
        return pillPad * 2 + CGFloat(n) * dashHeight + CGFloat(n - 1) * dashGap
    }

    static func layout(panelLong: CGFloat, count: Int, hasMore: Bool,
                       style: DeckStyle, longestLabel: CGFloat = 0) -> DeckLayout {
        let n = max(1, count)
        switch style {
        case .compact:
            return DeckLayout(itemLong: chipHeight, pitch: chipHeight + chipGap,
                              moreGap: chipGap, moreLong: 22,
                              count: n, hasMore: hasMore, panelLong: panelLong)
        case .tabs:
            // The uncovered strip of each tab is sized to the longest label on the
            // deck, so titles read in full until they hit the cap and ellipsise.
            var pitch = min(pitchMax, max(pitchMin, longestLabel + labelPad))

            // Guard rail: on a short display, shrink rather than run off-screen.
            let reserved = hasMore ? moreTabHeight + tabGap : 0
            let budget = panelLong * longBudget - reserved
            if CGFloat(n) * pitch + tabLap > budget {
                pitch = max(36, (budget - tabLap) / CGFloat(n))
            }
            return DeckLayout(itemLong: pitch + tabLap, pitch: pitch,
                              moreGap: tabGap, moreLong: moreTabHeight,
                              count: n, hasMore: hasMore, panelLong: panelLong)
        }
    }
}

// MARK: - Panel

/// Borderless, non-activating floating panel. `canBecomeKey` must be overridden or
/// the expanded note silently refuses keystrokes.
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // shadows are drawn per-tab in SwiftUI
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyLevel()
    }

    /// `.statusBar` is required to draw over full-screen apps; `.floating` alone is not.
    func applyLevel() {
        level = Settings.showOverFullScreen ? .statusBar : .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

// MARK: - Tracking container

/// Owns the tracking area that drives pill → fan. Hit-testing is delegated to the
/// SwiftUI hosting view so empty regions stay click-through to the app underneath.
final class DeckContentView: NSView {
    weak var controller: DeckController?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(at: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit    // never swallow clicks on our own blank area
    }

    /// The deck is used while another app is frontmost, so a click must act on the
    /// first press rather than being eaten to activate the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI host that also acts on the first click into an inactive panel, and lets
/// clicks on blank regions fall through to whatever is underneath.
final class DeckHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
