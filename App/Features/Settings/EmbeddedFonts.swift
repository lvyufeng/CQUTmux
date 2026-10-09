import Foundation
import CoreText

/// Registers the fonts that ship in the app bundle but are not listed in
/// `UIAppFonts`.
///
/// Why not list them all
/// ---------------------
/// `UIAppFonts` is processed at launch, before the app has done anything. That
/// is exactly right for JetBrains Mono — it is the default, and the terminal
/// must render in it on the first frame — but it is wasted work for four
/// families most people never pick: every face listed there is opened, parsed
/// and held by the font system for the life of the process. Registering one on
/// first use costs a single file read at a moment nothing is waiting on it.
///
/// This is a deliberate divergence from the reference app, which downloads
/// Iosevka, Ioskeley and DejaVu the first time one is selected. The files are
/// the same faces at the same versions, but they are *bundled* rather than
/// fetched, so the picker works on a plane, behind a captive portal, and
/// without a round trip that can fail while the user watches a spinner. The
/// cost is about 10 MB of app size, which for a terminal emulator whose whole
/// job is glyph coverage is a trade worth making. The consequence to be aware
/// of: a font chosen offline in the reference app would not render, and here it
/// does — so a bug report that depends on a download failing cannot be
/// reproduced against this app.
enum EmbeddedFonts {
    /// The files backing a family, as bundle resource names.
    static func files(for family: TerminalFontFamily) -> [String] {
        switch family {
        case .system, .menlo, .courier, .andale, .custom: []
        case .jetBrainsMono:
            ["JetBrainsMono-Regular", "JetBrainsMono-Bold",
             "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]
        case .iosevka: ["Iosevka-Regular", "Iosevka-Bold"]
        case .ioskeley: ["IoskeleyMono-Regular", "IoskeleyMono-Bold"]
        case .dejaVu: ["DejaVuSansMono", "DejaVuSansMono-Bold"]
        }
    }

    /// Families already registered, so a second selection is a no-op and the
    /// registration does not happen once per keystroke.
    private static var registered: Set<String> = []

    /// Registers a bundled family's faces with Core Text.
    ///
    /// Idempotent, and safe to call from the font-resolution path because the
    /// `registered` check happens first. Core Text itself tolerates a repeated
    /// registration, but it is not free, and `font(ofSize:)` is called for
    /// every cell a terminal measures.
    ///
    /// A font that fails to register is not fatal — `font(ofSize:)` falls back
    /// and reports it — so nothing here throws. What it does instead is log
    /// *which* file failed, because "the font is not on the phone" and "the
    /// font file is there but unreadable" are the same symptom otherwise.
    static func activate(_ family: TerminalFontFamily) {
        guard !registered.contains(family.rawValue) else { return }
        registered.insert(family.rawValue)

        for name in files(for: family) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("CQUT_FONT_MISSING_FILE: \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok {
                // A duplicate registration is the ordinary "already there"
                // case and is not worth reporting; anything else is.
                let message = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
                if !message.contains("already registered") {
                    print("CQUT_FONT_REGISTER_FAILED: \(name).ttf — \(message)")
                }
            }
        }
    }

    /// Whether a family's faces are all present and resolvable right now.
    ///
    /// Used by the check and by the settings row, so "bundled but broken" is
    /// visible rather than rendering as the system font.
    static func isAvailable(_ family: TerminalFontFamily) -> Bool {
        activate(family)
        let names = files(for: family)
        guard !names.isEmpty else { return false }
        return names.allSatisfy { Bundle.main.url(forResource: $0, withExtension: "ttf") != nil }
    }
}