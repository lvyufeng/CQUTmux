import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// How the terminal renders text: family, size and leading. Persisted in
/// `UserDefaults` so a session picks up where the last one left off.
@Observable
final class TerminalFontStore {
    private enum Key {
        static let family = "cqutmux.font.family"
        static let size = "cqutmux.font.size"
        static let lineSpacing = "cqutmux.font.lineSpacing"
        static let cjk = "cqutmux.font.cjk"
        static let customFont = "cqutmux.font.customFont"
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

    /// Which imported font is in use, when `family` is `.custom`.
    var customFontID: String? {
        didSet { UserDefaults.standard.set(customFontID, forKey: Key.customFont) }
    }

    init() {
        let defaults = UserDefaults.standard
        family = TerminalFontFamily.named(defaults.string(forKey: Key.family))
        size = defaults.object(forKey: Key.size) as? Double ?? 12
        lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double ?? 1
        cjk = defaults.string(forKey: Key.cjk).flatMap(CJKFallback.init(rawValue:)) ?? .none
        customFontID = defaults.string(forKey: Key.customFont)
    }

    /// The imported fonts, injected rather than read from a singleton so this
    /// store stays independent of the one that owns the files. Set by the app
    /// at launch.
    @ObservationIgnored var customFonts: CustomFontStore?

    func uiFont() -> UIFont {
        let base = resolveBase()
        return cjk.applied(to: base, size: size)
    }

    /// The chosen family's font, falling back through the custom font and then
    /// to the system's.
    ///
    /// The fallback chain is the point: a user who imported a font and later
    /// removed it would otherwise get a blank terminal, because `family` would
    /// still say `.custom` and there would be nothing to resolve. Landing on the
    /// system mono is legible, and it is obviously not their font, which is the
    /// honest way to report that it is gone.
    private func resolveBase() -> UIFont {
        switch family {
        case .custom:
            if let id = customFontID,
               let name = customFonts?.postScriptName(for: id),
               let font = UIFont(name: name, size: size) {
                return font
            }
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return family.font(ofSize: size)
        }
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
    /// The default, and the only family that ships inside the app rather than
    /// with iOS. Its four faces are in `App/Fonts` and registered through
    /// `UIAppFonts`, so it resolves on first launch with no download.
    case jetBrainsMono
    /// Bundled faces that are *not* registered at launch, because registering
    /// nine more faces costs launch time and memory for fonts almost nobody
    /// has chosen. `EmbeddedFonts.activate` registers one the first time it is
    /// picked, which is cheap because the files are already in the bundle.
    case iosevka, ioskeley, dejaVu
    /// A font the user imported. Not a family of its own — which one it is
    /// lives in `CustomFontStore` — but a distinct choice so the picker can
    /// offer "whatever I imported" without the enum having to know the list.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System Mono"
        case .menlo: "Menlo"
        case .courier: "Courier"
        case .andale: "Andale Mono"
        case .jetBrainsMono: "JetBrains Mono"
        case .iosevka: "Iosevka"
        case .ioskeley: "Ioskeley Mono"
        case .dejaVu: "DejaVu Sans Mono"
        case .custom: "Imported"
        }
    }

    /// The PostScript name, or nil for the system font.
    private var postScriptName: String? {
        switch self {
        case .system: nil
        case .menlo: "Menlo-Regular"
        case .courier: "Courier"
        case .andale: "AndaleMono"
        case .jetBrainsMono: "JetBrainsMono-Regular"
        case .iosevka: "Iosevka"
        case .ioskeley: "Ioskeley-Mono"
        case .dejaVu: "DejaVuSansMono"
        case .custom: nil
        }
    }

    /// Whether the face is expected to be present without any download.
    ///
    /// `jetBrainsMono` is registered from `UIAppFonts` at launch; the rest are
    /// registered on first use. Both are in the bundle, which is why a failure
    /// to resolve either is a bug rather than a missing download — the picker
    /// shows the distinction, since a font that renders as the system font is
    /// otherwise indistinguishable from one that was chosen and ignored.
    var isBundled: Bool {
        switch self {
        case .system, .menlo, .courier, .andale: false
        case .jetBrainsMono, .iosevka, .ioskeley, .dejaVu: true
        case .custom: false
        }
    }

    /// Resolves the face for a size, registering a bundled family first if it
    /// is not already available.
    func font(ofSize size: Double) -> UIFont {
        if isBundled { EmbeddedFonts.activate(self) }
        if let postScriptName, let font = UIFont(name: postScriptName, size: size) {
            return font
        }
        // The bundled families are supposed to always resolve. Falling back
        // silently would hide a missing `UIAppFonts` entry behind text that
        // looks merely plain, so the failure is logged where a UI run can see
        // it — the picker shows the chosen name either way.
        if isBundled {
            print("CQUT_FONT_UNRESOLVED: \(rawValue) (\(postScriptName ?? "?"))")
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The built-in families, without `custom`. Used to keep the custom case
    /// out of the loop that writes the PostScript names, where it has none.
    static var builtIn: [TerminalFontFamily] {
        allCases.filter { $0 != .custom }
    }

    /// The default family.
    ///
    /// Deliberately not `.system`. JetBrains Mono ships in the bundle, so a
    /// first launch gets it with no download and no choice to make — which is
    /// the point of embedding it at all. `.system` would make the bundled font
    /// something only people who go looking ever see.
    static let defaultFamily: TerminalFontFamily = .jetBrainsMono

    static func named(_ id: String?) -> TerminalFontFamily {
        id.flatMap(TerminalFontFamily.init(rawValue:)) ?? defaultFamily
    }
}

struct FontSettingsView: View {
    @Environment(TerminalFontStore.self) private var fonts
    @Environment(CustomFontStore.self) private var customFonts

    @State private var importing = false

    var body: some View {
        @Bindable var fonts = fonts
        List {
            Section("Family") {
                Picker("Font", selection: $fonts.family) {
                    ForEach(TerminalFontFamily.builtIn) { Text($0.label).tag($0) }
                    // Offered only once something has been imported: a picker
                    // entry that resolves to the system font would look like the
                    // import had silently failed.
                    if !customFonts.fonts.isEmpty {
                        Text(TerminalFontFamily.custom.label).tag(TerminalFontFamily.custom)
                    }
                }
                if fonts.family == .custom {
                    Picker("Imported", selection: $fonts.customFontID) {
                        Text("None").tag(String?.none)
                        ForEach(customFonts.fonts) { font in
                            Text(font.displayName).tag(String?.some(font.id))
                        }
                    }
                }
                // Only shown when something is wrong. A bundled family that
                // will not resolve renders as the system font, which is
                // indistinguishable from having chosen the system font — so
                // the one case a user cannot diagnose gets a line of its own.
                if fonts.family.isBundled, !EmbeddedFonts.isAvailable(fonts.family) {
                    Label("Not available in this build", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(customFonts.fonts) { font in
                    LabeledContent(font.displayName, value: font.postScriptName)
                        .font(.caption)
                }
                .onDelete { offsets in
                    for index in offsets { customFonts.remove(customFonts.fonts[index]) }
                }
                Button {
                    importing = true
                } label: {
                    Label("Import font\u{2026}", systemImage: "plus")
                }
            } header: {
                Text("Imported fonts")
            } footer: {
                Text(importFooter)
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
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.fontTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            customFonts.importFont(from: url)
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The footer is a computed property rather than an inline concatenation:
    /// the interpolations plus the literals exceed what the type checker will
    /// do inside a view builder, and it reports that as a timeout.
    private var importFooter: String {
        var text = "A .ttf, .otf or .ttc file. It is copied into CQUTmux, so "
            + "removing it from Files later does not break the terminal."
        if let error = customFonts.lastError {
            text += "\n\n\(error)"
        }
        return text
    }

    /// What the picker will let the user choose. A font is not a standard
    /// content type on iOS, so the extensions are declared here rather than
    /// relying on a UTI that does not exist.
    private static var fontTypes: [UTType] {
        ["public.truetype-font", "public.opentype-font", "public.truetype-font-collection"]
            .compactMap { UTType($0) }
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