import SwiftUI

/// How the session picker presents what is running on the host.
///
/// Moshi offers both and neither is better: the grouped list is for finding a
/// window you already know you want, and the cards are for seeing what several
/// sessions are doing at once — the shape that matters when a few agents are
/// running and most of them are idle.
@Observable
final class SessionLayout {
    private static let key = "cqutmux.sessions.layout"

    enum Style: String, CaseIterable, Identifiable {
        case list, cards

        var id: String { rawValue }

        var label: String {
            switch self {
            case .list: "List"
            case .cards: "Cards"
            }
        }

        var detail: String {
            switch self {
            case .list: "Every window under its session, in one list."
            case .cards: "One card per session, with its windows as chips."
            }
        }

        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .cards: "rectangle.grid.1x2"
            }
        }
    }

    var style: Style {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    /// The raw value, so the picker can switch on it without importing the type.
    var presents: String { style.rawValue }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        // Cards by default: a phone screen shows two or three sessions that way
        // and only one or two rows of a list, and the list's advantage — many
        // rows visible — only exists on a wider screen than most.
        style = stored.flatMap(Style.init(rawValue:)) ?? .cards
    }
}

struct SessionLayoutView: View {
    @Environment(SessionLayout.self) private var layout
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        @Bindable var layout = layout
        List {
            Section {
                Picker("Layout", selection: $layout.style) {
                    ForEach(SessionLayout.Style.allCases) { style in
                        Label(style.label, systemImage: style.symbol).tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(layout.style.detail)
            }
        }
        .navigationTitle("Sessions layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A wrapping row of chips.
///
/// `Layout` rather than an `HStack` because the chips vary in width and a fixed
/// grid would either clip a long window name or leave a ragged gap. iOS 18 has
/// no built-in flow layout, and `LazyVGrid` needs fixed columns.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Breaks the subviews into rows that fit `width`, each row as tall as its
    /// tallest chip so the chips line up along their centres.
    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}