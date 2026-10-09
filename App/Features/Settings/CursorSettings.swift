import Foundation
import SwiftTerm

/// The cursor's shape and whether it blinks.
///
/// Shape and blink are stored separately because SwiftTerm models them as one
/// six-case enum, where the blink is baked into the shape. Keeping the two
/// apart is what lets the settings screen show them as the two choices they
/// are — a user picking "bar" does not expect to re-answer the blink question.
@Observable
final class CursorSettings {
    private enum Key {
        static let shape = "cqutmux.cursor.shape"
        static let blinks = "cqutmux.cursor.blinks"
    }

    enum Shape: String, CaseIterable, Identifiable {
        case block, underline, bar

        var id: String { rawValue }

        var label: String {
            switch self {
            case .block: "Block"
            case .underline: "Underline"
            case .bar: "Bar"
            }
        }
    }

    var shape: Shape {
        didSet { UserDefaults.standard.set(shape.rawValue, forKey: Key.shape) }
    }

    var blinks: Bool {
        didSet { UserDefaults.standard.set(blinks, forKey: Key.blinks) }
    }

    init() {
        let defaults = UserDefaults.standard
        shape = defaults.string(forKey: Key.shape).flatMap(Shape.init(rawValue:)) ?? .block
        // Blinking by default: the cursor moves on its own, which on a phone is
        // the cheapest way to tell a live session from a frozen one.
        blinks = defaults.object(forKey: Key.blinks) as? Bool ?? true
    }

    /// The SwiftTerm style for the current choice.
    var style: CursorStyle {
        switch (shape, blinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    /// Writes the style into a live terminal.
    ///
    /// Through `setCursorStyle`, which also notifies the delegate — so the
    /// caret subview is updated, where assigning `options.cursorStyle` directly
    /// would leave the drawn cursor on the old shape until something else
    /// happened to refresh it.
    func apply(to view: TerminalView) {
        view.getTerminal().setCursorStyle(style)
    }
}