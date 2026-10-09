import SwiftUI
import UIKit

/// How the terminal renders text: family, size and leading. Persisted in
/// `UserDefaults` so a session picks up where the last one left off.
@Observable
final class TerminalFontStore {
    private enum Key {
        static let family = "cqutmux.font.family"
        static let size = "cqutmux.font.size"
        static let lineSpacing = "cqutmux.font.lineSpacing"
        static let cjk = "cqutmux.font.cjk"
    }

    /// Pinch-to-zoom clamps to this too, so the two ways of resizing the
    /// terminal can't disagree about what is legible.
    static let sizeRange: ClosedRange<Double> = 7...28

    var family: TerminalFontFamily {
        didSet { UserDefaults.standard.set(family.id, forKey: Key.family) }
    }

    var size: Double {
        didSet { UserDefaults.standard.set(size, forKey: Key.size) }
    }

    var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: Key.lineSpacing) }
    }

    /// Which script's glyphs fill in when the terminal font has none. Not a
    /// font choice — CJK is a fallback, so the Latin face stays as chosen and
    /// only the characters it cannot draw come from here.
    var cjk: CJKFallback {
        didSet { UserDefaults.standard.set(cjk.rawValue, forKey: Key.cjk) }
    }

    init() {
        let defaults = UserDefaults.standard
        family = TerminalFontFamily.named(defaults.string(forKey: Key.family))
        size = defaults.object(forKey: Key.size) as? Double ?? 12
        lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double ?? 1
        cjk = defaults.string(forKey: Key.cjk).flatMap(CJKFallback.init(rawValue:)) ?? .none
    }

    func uiFont() -> UIFont {
        let base = family.font(ofSize: size)
        return cjk.applied(to: base, size: size)
    }
}

/// A script whose glyphs fill gaps in the terminal font.
///
/// Moshi offers Noto Sans for each of these and downloads them. iOS already
/// ships a font per script, so the same choice is offered here without a
/// download — and the label says which script rather than which typeface,
/// because what the user is choosing is "can my terminal show Japanese",
/// not a family name.
enum CJKFallback: String, CaseIterable, Identifiable {
    case none, japanese, simplifiedChinese, traditionalChinese, korean

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .japanese: "Japanese"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .korean: "Korean"
        }
    }

    /// The PostScript name of the system font for this script. All four ship
    /// with iOS; a name that is missing falls back to no fallback rather than
    /// to a wrong script.
    private var postScriptName: String? {
        switch self {
        case .none: nil
        case .japanese: "HiraginoSans-W3"
        case .simplifiedChinese: "PingFangSC-Regular"
        case .traditionalChinese: "PingFangTC-Regular"
        case .korean: "AppleSDGothicNeo-Regular"
        }
    }

    /// The base font with this script's font added to its cascade list, which
    /// is how Core Text is told where to look for a glyph the base font lacks.
    ///
    /// `size` is passed in rather than read from the fallback descriptor: the
    /// cascade list carries its own size, and leaving it at the default would
    /// render CJK at the wrong scale against the Latin text beside it.
    func applied(to base: UIFont, size: Double) -> UIFont {
        guard let postScriptName, let fallback = UIFont(name: postScriptName, size: size) else {
            return base
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [fallback.fontDescriptor],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// The monospaced families worth offering. Everything that isn't guaranteed on
/// iOS is resolved through `UIFont(name:)` and falls back rather than shipping
/// a font picker whose entries silently render as the system font.
enum TerminalFontFamily: String, CaseIterable, Identifiable {
    case system, menlo, courier, andale

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System Mono"
        case .menlo: "Menlo"
        case .courier: "Courier"
        case .andale: "Andale Mono"
        }
    }

    /// The PostScript name, or nil for the system font.
    private var postScriptName: String? {
        switch self {
        case .system: nil
        case .menlo: "Menlo-Regular"
        case .courier: "Courier"
        case .andale: "AndaleMono"
        }
    }

    func font(ofSize size: Double) -> UIFont {
        if let postScriptName, let font = UIFont(name: postScriptName, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func named(_ id: String?) -> TerminalFontFamily {
        id.flatMap(TerminalFontFamily.init(rawValue:)) ?? .system
    }
}

struct FontSettingsView: View {
    @Environment(TerminalFontStore.self) private var fonts

    var body: some View {
        @Bindable var fonts = fonts
        List {
            Section("Family") {
                Picker("Font", selection: $fonts.family) {
                    ForEach(TerminalFontFamily.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Size") {
                HStack {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $fonts.size,
                        in: TerminalFontStore.sizeRange,
                        step: 1
                    ) {
                        Text("Size")
                    } minimumValueLabel: {
                        Text("\(Int(TerminalFontStore.sizeRange.lowerBound))").font(.caption2)
                    } maximumValueLabel: {
                        Text("\(Int(TerminalFontStore.sizeRange.upperBound))").font(.caption2)
                    }
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Points", value: "\(Int(fonts.size))")
            }

            Section("Leading") {
                Slider(value: $fonts.lineSpacing, in: 0.8...1.6, step: 0.05) {
                    Text("Line spacing")
                }
                LabeledContent("Multiplier", value: fonts.lineSpacing.formatted(.number.precision(.fractionLength(2))))
            }

            Section {
                Picker("Fallback", selection: $fonts.cjk) {
                    ForEach(CJKFallback.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("CJK characters")
            } footer: {
                Text("Which script's glyphs fill in when the terminal font has none. "
                     + "The Latin text keeps the font chosen above.")
            }

            Section("Preview") {
                preview
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A few lines of the sort of output the terminal actually shows, so the
    /// size is judged against real text rather than a specimen.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.sample.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .foregroundStyle(line.color)
            }
        }
        .font(Font(fonts.uiFont()))
        .lineSpacing(max(0, (fonts.lineSpacing - 1) * fonts.size))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(hex: "282a36"), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let sample: [(text: String, color: Color)] = [
        ("$ npm run build", Color(hex: "f8f8f2")),
        ("  ✓ 128 modules transformed", Color(hex: "50fa7b")),
        ("  warn  chunk larger than 500 kB", Color(hex: "f1fa8c")),
        // The fallback choice is only visible on characters the terminal font
        // cannot draw, so the preview has to contain some.
        ("  日本語 中文 한국어", Color(hex: "bd93f9")),
        ("$ ", Color(hex: "f8f8f2")),
    ]
}

/// Cursor shape and blink.
///
/// Its own screen rather than a row inside Font because the two are unrelated
/// questions — a user who wants a bar cursor is not editing their font — and
/// because Moshi's Personalization screen presents them separately.
struct CursorSettingsView: View {
    @Environment(CursorSettings.self) private var cursor

    var body: some View {
        @Bindable var cursor = cursor
        List {
            Section {
                Picker("Shape", selection: $cursor.shape) {
                    ForEach(CursorSettings.Shape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Shape")
            }

            Section {
                Toggle("Blink", isOn: $cursor.blinks)
            } footer: {
                Text("A cursor that moves on its own is the cheapest way to tell a live "
                     + "session from a frozen one.")
            }
        }
        .navigationTitle("Cursor")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { FontSettingsView() }
        .environment(TerminalFontStore())
        .environment(ThemeStore())
}