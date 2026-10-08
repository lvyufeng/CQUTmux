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

    init() {
        let defaults = UserDefaults.standard
        family = TerminalFontFamily.named(defaults.string(forKey: Key.family))
        size = defaults.object(forKey: Key.size) as? Double ?? 12
        lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double ?? 1
    }

    func uiFont() -> UIFont {
        family.font(ofSize: size)
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
        ("$ ", Color(hex: "f8f8f2")),
    ]
}

#Preview {
    NavigationStack { FontSettingsView() }
        .environment(TerminalFontStore())
}