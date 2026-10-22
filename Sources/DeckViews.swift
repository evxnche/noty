import SwiftUI

// MARK: - Root

struct DeckRootView: View {
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    @ObservedObject var store = NoteStore.shared

    private var edge: DeckEdge { deck.edge }
    private var onRight: Bool { edge == .right }

    /// The corner the deck is anchored to: the docked edge, and the end the
    /// fan runs from.
    private var anchor: Alignment {
        switch edge {
        case .right: return .topTrailing
        case .left: return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    /// The panel's extent along the docked edge — height for a side dock,
    /// width for the bottom.
    private var panelLong: CGFloat {
        max(1, edge.isBottom ? deck.panelSize.width : deck.panelSize.height)
    }

    private var visible: [Note] {
        deck.showAll ? store.active : Array(store.active.prefix(Settings.fanLimit))
    }
    private var hiddenCount: Int { max(0, store.active.count - Settings.fanLimit) }
    private var showsMoreTab: Bool { !deck.showAll && hiddenCount > 0 }
    /// An empty deck still draws one tab, so the stack is never zero-height.
    private var itemCount: Int { max(1, visible.count) }

    /// Longest label currently on the deck — drives how long each tab's strip is.
    private var longestLabel: CGFloat {
        visible.map { DeckGeom.labelWidth($0.displayTitle) }.max() ?? 0
    }

    private func layout(_ panelLong: CGFloat) -> DeckLayout {
        DeckGeom.layout(panelLong: panelLong, count: itemCount,
                        hasMore: showsMoreTab, style: deck.style,
                        longestLabel: longestLabel)
    }

    var body: some View {
        let lay = layout(panelLong)

        return ZStack(alignment: anchor) {

                if deck.fanVisible {
                    FanColumn(deck: deck, controller: controller,
                              notes: visible, hiddenCount: showsMoreTab ? hiddenCount : 0,
                              layout: lay, edge: edge)
                        .padding(edge.isBottom ? .leading : .top, lay.start)
                } else {
                    PillView(notes: store.active, edge: edge)
                        .padding(edge.isBottom ? .leading : .top,
                                 max(0, (panelLong - DeckGeom.pillLength(noteCount: max(1, store.active.count))) / 2))
                        .padding(edge.isBottom ? .bottom : (onRight ? .trailing : .leading), 1)
                        .transition(.opacity)
                }

                // Declared last so it covers the deck, flush to the screen edge.
                if let id = deck.state.expandedID, let note = store.note(id: id) {
                    NoteEditorView(note: note, deck: deck, controller: controller, edge: edge)
                        .frame(width: DeckGeom.editorWidth, height: DeckGeom.editorHeight)
                        .padding(edge.isBottom ? .leading : .top, editorStart(lay, id: id))
                        .transition(.modifier(
                            active: NotePull(hidden: true, edge: edge),
                            identity: NotePull(hidden: false, edge: edge)))
                        .id(id)
                }
            }
        // A ZStack is only as wide as its widest child, so it has to be told to fill
        // the panel — otherwise the deck sits at the panel's left edge with a dead
        // gap against the screen. Filling from the parent's proposal (rather than a
        // measured width) keeps it pinned to the edge through a resize.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
        .animation(.spring(response: 0.30, dampingFraction: 0.9), value: deck.fanVisible)
        .animation(.easeInOut(duration: 0.22), value: deck.style)
    }

    /// Keep the open note level with its own tab, without letting it run off-screen.
    private func editorStart(_ lay: DeckLayout, id: String) -> CGFloat {
        let idx = visible.firstIndex { $0.id == id } ?? 0
        let editorLong: CGFloat = edge.isBottom ? DeckGeom.editorWidth : DeckGeom.editorHeight
        let ideal = lay.center(idx) - editorLong / 2
        let farthest = max(10, lay.panelLong - editorLong - 10)
        return min(max(10, ideal), farthest)
    }
}

// MARK: - Pill (at rest)

struct PillView: View {
    let notes: [Note]
    let edge: DeckEdge

    private var shown: [Note] { Array(notes.prefix(DeckGeom.maxDashes)) }
    private var overflow: Int { max(0, notes.count - DeckGeom.maxDashes) }

    var body: some View {
        Group {
            if edge.isBottom {
                HStack(spacing: DeckGeom.dashGap) { dashes }
                    .padding(.horizontal, DeckGeom.pillPad)
                    .frame(height: DeckGeom.pillWidth)
            } else {
                VStack(spacing: DeckGeom.dashGap) { dashes }
                    .padding(.vertical, DeckGeom.pillPad)
                    .frame(width: DeckGeom.pillWidth)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 6, x: -2, y: 1)
        )
    }

    @ViewBuilder private var dashes: some View {
        if notes.isEmpty { dash(Color.secondary.opacity(0.4)) }
        ForEach(shown) { dash($0.palette.dash) }
        if overflow > 0 { dash(Color.secondary.opacity(0.5)) }
    }

    private func dash(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color)
            .frame(width: edge.isBottom ? DeckGeom.dashHeight : DeckGeom.dashWidth,
                   height: edge.isBottom ? DeckGeom.dashWidth : DeckGeom.dashHeight)
    }
}

// MARK: - Fan

struct FanColumn: View {
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    let notes: [Note]
    let hiddenCount: Int
    let layout: DeckLayout
    let edge: DeckEdge

    @State private var revealed = false
    @State private var tabClickGen = 0

    var body: some View {
        Group {
            if deck.showAll && layout.overflows {
                ScrollViewReader { proxy in
                    ScrollView(edge.isBottom ? .horizontal : .vertical, showsIndicators: false) {
                        stack.padding(edge.isBottom ? .horizontal : .vertical, 4)
                    }
                    .frame(width: edge.isBottom ? layout.cap : nil,
                           height: edge.isBottom ? nil : layout.cap)
                    .scrollClipDisabled()
                    // Keep the keyboard's tab in sight while it cycles.
                    .onChange(of: deck.keyboardFocusID) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            } else {
                stack
            }
        }
        .onAppear { revealed = true }
        .onChange(of: deck.revealTick) { _, _ in
            revealed = false
            DispatchQueue.main.async { revealed = true }
        }
    }

    /// The lap comes from negative stack spacing — real layout, so hit areas follow
    /// the tabs. (`.offset` would draw them in the right place but leave their taps
    /// behind at the top of the stack.) Paint order is left to declaration order: a
    /// stack draws later children on top, which is exactly the lap we want. An
    /// explicit `zIndex` per tab is *not* equivalent — it reorders neighbours and
    /// breaks the shingle.
    private var stack: some View {
        Group {
            if edge.isBottom { hStack } else { vStack }
        }
    }

    private var vStack: some View {
        VStack(spacing: layout.spacing) {
            contents
        }
        .frame(width: DeckGeom.tabWidth)
    }

    private var hStack: some View {
        HStack(spacing: layout.spacing) {
            contents
        }
        .frame(height: DeckGeom.tabWidth)
    }

    @ViewBuilder private var contents: some View {
        if notes.isEmpty {
            emptyTab.staged(index: 0, revealed: revealed, edge: edge)
        }
        ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
            tab(idx, note)
                .id(note.id)            // the ScrollViewReader's target for ⌥⌘A cycling
                .staged(index: idx, revealed: revealed, edge: edge)
        }
        if hiddenCount > 0 {
            MoreTab(count: hiddenCount, long: layout.moreLong, edge: edge) {
                deck.showAll = true
            }
            // Undo the lap so the "+N" tab sits clear of the shingle.
            .padding(edge.isBottom ? .leading : .top, layout.moreGap - layout.spacing)
            .staged(index: notes.count, revealed: revealed, edge: edge)
        }
    }

    @ViewBuilder private var emptyTab: some View {
        if edge.isBottom {
            BottomEmptyTab(length: layout.itemLong, strip: layout.pitch) {
                (NSApp.delegate as? AppDelegate)?.newNote()
            }
        } else {
            EmptyTab(height: layout.itemLong, strip: layout.pitch, onRight: edge == .right) {
                (NSApp.delegate as? AppDelegate)?.newNote()
            }
        }
    }

    @ViewBuilder private func tab(_ idx: Int, _ note: Note) -> some View {
        if deck.style == .compact {
            ChipTab(note: note,
                    isOpen: deck.state.expandedID == note.id,
                    isSelected: deck.keyboardFocusID == note.id,
                    edge: edge,
                    action: { handleTabClick(note) },
                    rename: { controller.beginRename(note.id) })
        } else if edge.isBottom {
            BottomTab(note: note,
                      isOpen: deck.state.expandedID == note.id,
                      isSelected: deck.keyboardFocusID == note.id,
                      length: layout.itemLong,
                      strip: layout.pitch,
                      action: { handleTabClick(note) },
                      rename: { controller.beginRename(note.id) })
        } else {
            VerticalTab(note: note,
                        isOpen: deck.state.expandedID == note.id,
                        isSelected: deck.keyboardFocusID == note.id,
                        height: layout.itemLong,
                        strip: layout.pitch,
                        onRight: edge == .right,
                        action: { handleTabClick(note) },
                        rename: { controller.beginRename(note.id) })
        }
    }

    private func handleTabClick(_ note: Note) {
        controller.endKeyboardFan()
        tabClickGen += 1
        let gen = tabClickGen
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            controller.beginRename(note.id)
            return
        }
        if let renaming = deck.renamingID, renaming != note.id {
            controller.commitRename()
        }
        if deck.state.expandedID == note.id {
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) {
                guard gen == tabClickGen,
                      deck.renamingID != note.id,
                      deck.state.expandedID == note.id else { return }
                controller.collapse()
            }
        } else {
            controller.expand(note.id)
        }
    }

}

/// The note emerging from its tab: a short slide off the edge, a touch of scale
/// anchored there, and a fade. A full-width slide reads as a window flying in.
struct NotePull: ViewModifier {
    let hidden: Bool
    let edge: DeckEdge

    func body(content: Content) -> some View {
        content
            .offset(x: hidden ? (edge == .right ? 40 : (edge == .left ? -40 : 0)) : 0,
                    y: hidden ? (edge.isBottom ? 40 : 0) : 0)
            .scaleEffect(hidden ? 0.965 : 1, anchor: scaleAnchor)
            .opacity(hidden ? 0 : 1)
    }

    private var scaleAnchor: UnitPoint {
        switch edge {
        case .right: return .trailing
        case .left: return .leading
        case .bottom: return .bottom
        }
    }
}

struct EdgeLine: Shape {
    var horizontal = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        if horizontal {
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        } else {
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        return p
    }
}

/// Rounded on the outward-facing side only, so the tab reads as docked to the edge.
func edgeTabShape(edge: DeckEdge, radius r: CGFloat = 11) -> UnevenRoundedRectangle {
    switch edge {
    case .right:
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: 0, topTrailingRadius: 0,
                                      style: .continuous)
    case .left:
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: r, topTrailingRadius: r,
                                      style: .continuous)
    case .bottom:
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0, topTrailingRadius: r,
                                      style: .continuous)
    }
}

// MARK: - Tabs

/// A side-dock tab keeps its colour and carries its label turned on its side.
///
/// Tabs overlap, so the label is pinned to the top of the tab — the part that
/// stays uncovered. Hovering lifts the whole tab clear to reveal the rest of it.
struct VerticalTab: View {
    let note: Note
    let isOpen: Bool
    var isSelected = false            // the tab the ⌥⌘A fan is on
    let height: CGFloat
    let strip: CGFloat          // the part of this tab the next one does not cover
    let onRight: Bool
    let action: () -> Void
    var rename: () -> Void = {}

    @State private var hovering = false

    /// Lifted clear of the shingle: hovered, open, or the keyboard's tab.
    private var lifted: Bool { isOpen || hovering || isSelected }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(edge: onRight ? .right : .left)
                    .fill(note.palette.paper)
                    .shadow(color: .black.opacity(lifted ? 0.32 : 0.22),
                            radius: lifted ? 9 : 6,
                            x: onRight ? -3 : 3, y: 2)
                    .overlay(
                        // A ring reads the keyboard's pick; hover already lifts.
                        edgeTabShape(edge: onRight ? .right : .left)
                            .stroke(note.palette.ink.opacity(isSelected ? 0.55 : 0),
                                    lineWidth: 1.5)
                    )
                Text(note.displayTitle)
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(note.palette.ink.opacity(0.85))
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
                    .frame(width: DeckGeom.tabWidth, height: strip)
                    .offset(x: onRight ? -DeckGeom.bleed / 2 : DeckGeom.bleed / 2)
            }
            .frame(width: DeckGeom.tabWidth + DeckGeom.bleed, height: height, alignment: .top)
            .rotationEffect(.degrees(DeckGeom.lean(for: onRight ? .right : .left)),
                            anchor: onRight ? .trailing : .leading)
            .offset(x: onRight ? DeckGeom.bleed : -DeckGeom.bleed)
            .frame(width: DeckGeom.tabWidth)
            .contentShape(Rectangle())
        }
        .overlay(alignment: onRight ? .topTrailing : .topLeading) {
            if note.pinned {
                Circle()
                    .fill(note.palette.dash)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(onRight ? .trailing : .leading, 9)
            }
        }
        .buttonStyle(TabPressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOpen)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .noteContextMenu(note, rename: rename)
        .help(note.displayTitle)
    }
}

/// The bottom-dock cut of a tab: a horizontal strip sitting on the edge, its
/// label reading flat in the leading strip the next tab does not cover.
struct BottomTab: View {
    let note: Note
    let isOpen: Bool
    var isSelected = false            // the tab the ⌥⌘A fan is on
    let length: CGFloat          // full length along the edge
    let strip: CGFloat           // the part the next tab does not cover
    let action: () -> Void
    var rename: () -> Void = {}

    @State private var hovering = false

    /// Lifted clear of the shingle: hovered, open, or the keyboard's tab.
    private var lifted: Bool { isOpen || hovering || isSelected }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                edgeTabShape(edge: .bottom)
                    .fill(note.palette.paper)
                    .shadow(color: .black.opacity(lifted ? 0.32 : 0.22),
                            radius: lifted ? 9 : 6, x: -3, y: -2)
                    .overlay(
                        // A ring reads the keyboard's pick; hover already lifts.
                        edgeTabShape(edge: .bottom)
                            .stroke(note.palette.ink.opacity(isSelected ? 0.55 : 0),
                                    lineWidth: 1.5)
                    )
                Text(note.displayTitle)
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(note.palette.ink.opacity(0.85))
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .frame(width: strip, height: DeckGeom.tabWidth)
                    .offset(y: -DeckGeom.bleed / 2)
            }
            .frame(width: length, height: DeckGeom.tabWidth + DeckGeom.bleed, alignment: .leading)
            .rotationEffect(.degrees(DeckGeom.lean(for: .bottom)), anchor: .bottom)
            .offset(y: DeckGeom.bleed)
            .frame(height: DeckGeom.tabWidth)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .topLeading) {
            if note.pinned {
                Circle()
                    .fill(note.palette.dash)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(.leading, 9)
            }
        }
        .buttonStyle(TabPressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOpen)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .noteContextMenu(note, rename: rename)
        .help(note.displayTitle)
    }
}

/// Compact style — colour only, so the deck barely touches the screen.
struct ChipTab: View {
    let note: Note
    let isOpen: Bool
    var isSelected = false            // the chip the ⌥⌘A fan is on
    let edge: DeckEdge
    let action: () -> Void
    var rename: () -> Void = {}

    private var lifted: Bool { isOpen || isSelected }

    var body: some View {
        Button(action: action) {
            edgeTabShape(edge: edge, radius: 7)
                .fill(note.palette.dash)
                .frame(width: edge.isBottom ? DeckGeom.chipHeight : DeckGeom.chipWidth,
                       height: edge.isBottom ? DeckGeom.chipWidth : DeckGeom.chipHeight)
                .shadow(color: .black.opacity(lifted ? 0.34 : 0.22), radius: lifted ? 8 : 5,
                        x: edge == .left ? 2 : -2, y: edge.isBottom ? -2 : 1)
                .scaleEffect(isSelected ? 1.15 : 1)
                .rotationEffect(.degrees(DeckGeom.lean(for: edge) * 0.6),
                                anchor: edge.isBottom ? .bottom : (edge == .right ? .trailing : .leading))
                .offset(edge.isBottom
                        ? CGSize(width: 0, height: DeckGeom.bleed / 2)
                        : CGSize(width: edge == .right ? DeckGeom.bleed / 2 : -DeckGeom.bleed / 2,
                                 height: 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: isOpen)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .noteContextMenu(note, rename: rename)
        .help(note.displayTitle)
    }
}

struct MoreTab: View {
    let count: Int
    let long: CGFloat            // length along the edge
    let edge: DeckEdge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                edgeTabShape(edge: edge, radius: 9)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 5,
                            x: edge == .left ? 2 : -2, y: edge.isBottom ? -2 : 1)
                Text("+\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: edge.isBottom ? long : DeckGeom.tabWidth,
                   height: edge.isBottom ? DeckGeom.tabWidth : long)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .help("\(count) more note\(count == 1 ? "" : "s")")
    }
}

struct EmptyTab: View {
    let height: CGFloat
    let strip: CGFloat
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(edge: onRight ? .right : .left).fill(.ultraThinMaterial)
                Text("NEW NOTE")
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .foregroundStyle(.secondary)
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
                    .frame(width: DeckGeom.tabWidth, height: strip)
            }
            .frame(width: DeckGeom.tabWidth, height: height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
    }
}

/// The bottom-dock cut of the empty deck's placeholder tab.
struct BottomEmptyTab: View {
    let length: CGFloat
    let strip: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                edgeTabShape(edge: .bottom).fill(.ultraThinMaterial)
                Text("NEW NOTE")
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .foregroundStyle(.secondary)
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .frame(width: strip, height: DeckGeom.tabWidth)
            }
            .frame(width: length, height: DeckGeom.tabWidth + DeckGeom.bleed, alignment: .leading)
            .offset(y: DeckGeom.bleed)
            .frame(height: DeckGeom.tabWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
    }
}

// MARK: - Shared bits

extension View {
    func noteContextMenu(_ note: Note, rename: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Rename") { rename() }
            Button(note.pinned ? "Unpin" : "Pin") { NoteStore.shared.togglePin(id: note.id) }
            Button("Archive") { NoteStore.shared.setArchived(id: note.id, true) }
            Button("Cycle colour  ⌘.") { NoteStore.shared.cycleColor(id: note.id) }
            Divider()
            Button("Delete") { NoteStore.shared.delete(id: note.id) }
        }
    }
}

// MARK: - Staging (the 45 ms shingle)

private struct Staged: ViewModifier {
    let index: Int
    let revealed: Bool
    let edge: DeckEdge

    func body(content: Content) -> some View {
        content
            .offset(revealed ? .zero : hiddenOffset)
            .opacity(revealed ? 1 : 0)
            .animation(.spring(response: 0.36, dampingFraction: 0.82)
                        .delay(Double(index) * 0.045), value: revealed)
    }

    /// Where the tab waits before its turn: past the docked edge.
    private var hiddenOffset: CGSize {
        let d = DeckGeom.tabWidth + 24
        switch edge {
        case .right: return CGSize(width: d, height: 0)
        case .left: return CGSize(width: -d, height: 0)
        case .bottom: return CGSize(width: 0, height: d)
        }
    }
}

private extension View {
    func staged(index: Int, revealed: Bool, edge: DeckEdge) -> some View {
        modifier(Staged(index: index, revealed: revealed, edge: edge))
    }
}

struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
