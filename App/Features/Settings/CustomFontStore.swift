import Foundation
import CoreText

/// Fonts the user brought themselves.
///
/// A terminal is a place people have opinions about type, and the built-in list
/// is four families chosen because they are guaranteed to exist. This is the
/// escape hatch: a `.ttf` or `.otf` the user picked from Files, copied into the
/// app's own container and registered with Core Text under the name that
/// follows the font itself.
///
/// Two decisions worth stating:
///
/// - **Copied, not referenced.** A security-scoped URL from the document picker
///   is only valid for the span of the picker's callback, and the terminal
///   resolves the font on every repaint, potentially days later. Holding the
///   URL would work in testing and fail after a relaunch, so the file is copied
///   into Application Support and the copy is what gets registered.
///
/// - **Registered under the font's own PostScript name.** Read out of the file
///   rather than taken from its filename: `JetBrainsMono-Regular.ttf` and
///   `jetbrains-mono.ttf` are the same font, and a font picked from a
///   downloaded zip usually has neither name. What gets stored is what
///   `UIFont(name:)` will need to find it again.
@Observable
final class CustomFontStore {
    struct Imported: Identifiable, Equatable, Codable {
        /// Stable across relaunches and across re-imports of the same file, so
        /// the selection survives both.
        var id: String
        /// What the picker shows. The font's own family name where it has one,
        /// so the list reads like a font menu rather than like a file list.
        var displayName: String
        /// What `UIFont(name:size:)` is called with.
        var postScriptName: String
        /// The file's name inside the fonts directory.
        var fileName: String
    }

    private(set) var fonts: [Imported] = []
    /// Why the last import failed, for the screen to show. Nil when the last
    /// attempt succeeded or there has not been one.
    private(set) var lastError: String?

    private let store: UserDefaults
    private static let key = "cqutmux.customFonts"

    init(store: UserDefaults = .standard, directory: URL = CustomFontStore.defaultDirectory) {
        self.store = store
        self.directory = directory
        load()
        // Registered once at launch: a font registered in a previous run is not
        // registered in this one, and the terminal would render its fallback for
        // a font the picker still lists.
        for font in fonts { register(font) }
    }

    private let directory: URL

    /// Application Support, not Documents: the user never manages these files
    /// directly, and a font appearing in Files would be confusing next to the
    /// things they did put there.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fonts", isDirectory: true)
    }

    // MARK: - Importing

    /// Copies a picked file in and registers it.
    ///
    /// The URL is read inside this call, which is the only moment the picker's
    /// security scope is guaranteed to still be open — see the note above.
    @discardableResult
    func importFont(from url: URL) -> Imported? {
        lastError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let extensionName = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(extensionName) else {
            lastError = "\(url.lastPathComponent) is not a font. Pick a .ttf, .otf or .ttc file."
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            lastError = "Could not read \(url.lastPathComponent)."
            return nil
        }
        // Reject a non-font that merely has the extension, here rather than at
        // render time: a corrupt file silently falling back to the system font
        // looks like the import worked and the font is ugly.
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider), let postScript = cgFont.postScriptName as String?
        else {
            lastError = "\(url.lastPathComponent) could not be read as a font."
            return nil
        }

        let fileName = "\(postScript).\(extensionName)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileName)
            // Overwrite: re-importing an updated build of the same font should
            // replace it, not fail because the name is taken.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination)
        } catch {
            lastError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }

        let imported = Imported(
            id: fileName,
            displayName: displayName(of: cgFont, fallback: url.deletingPathExtension().lastPathComponent),
            postScriptName: postScript,
            fileName: fileName
        )
        fonts.removeAll { $0.id == imported.id }
        fonts.append(imported)
        fonts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save()
        register(imported)
        return imported
    }

    func remove(_ font: Imported) {
        fonts.removeAll { $0.id == font.id }
        save()
        // The file goes too. Unregistering but leaving it would mean the next
        // launch re-registers a font the user removed.
        let path = directory.appendingPathComponent(font.fileName)
        if let data = try? Data(contentsOf: path), let provider = CGDataProvider(data: data as CFData),
           let cgFont = CGFont(provider) {
            CTFontManagerUnregisterGraphicsFont(cgFont, nil)
        }
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Registration

    /// Registers the copy with Core Text so `UIFont(name:)` can find it.
    ///
    /// `CTFontManagerRegisterGraphicsFont` takes the data rather than a URL,
    /// which is what makes it work for a font in the app's own container
    /// without the process-scoped registration that would need the file to be
    /// reachable by path for the lifetime of the process.
    private func register(_ font: Imported) {
        let path = directory.appendingPathComponent(font.fileName)
        guard let data = try? Data(contentsOf: path),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return }
        var error: Unmanaged<CFError>?
        // A failure here is not surfaced: the font was already unusable if this
        // fails, and the renderer falls back — an alert about a registration
        // error the user cannot act on would only be noise.
        _ = CTFontManagerRegisterGraphicsFont(cgFont, &error)
    }

    /// What to show for an imported font.
    ///
    /// Tries the family name, then the full name, then falls back to the file's
    /// own. A font with none of the first two is rare but real (some subsets
    /// strip them), and an empty row in a picker is worse than a filename.
    private func displayName(of font: CGFont, fallback: String) -> String {
        // `CGFont` has no family name on iOS — only `fullName` and
        // `postScriptName`. The family is read off a `CTFont` made from it,
        // which is why this takes the `CGFont` rather than the descriptor.
        let ctFont = CTFontCreateWithGraphicsFont(font, 12, nil, nil)
        if let family = CTFontCopyFamilyName(ctFont) as String?, !family.isEmpty { return family }
        if let full = font.fullName as String?, !full.isEmpty { return full }
        return fallback
    }

    /// The PostScript name to render with, or nil if that font is not here.
    ///
    /// Returns the *name* rather than a `UIFont`, so this file needs no UIKit
    /// and can be compiled and exercised without a simulator — the font lookup
    /// itself is a one-line `UIFont(name:)` on the rendering side.
    func postScriptName(for id: String) -> String? {
        fonts.first { $0.id == id }?.postScriptName
    }

    func contains(id: String) -> Bool { fonts.contains { $0.id == id } }

    #if DEBUG
    /// Imports a font from a path, for a UI run that cannot drive the document
    /// picker. The picker is the one part of this screen no simulator command
    /// can operate, so without this the "Imported fonts" list and the family
    /// picker's `.custom` entry could never be seen, only reasoned about.
    @discardableResult
    func importForTesting(path: String) -> Imported? {
        importFont(from: URL(fileURLWithPath: path))
    }
    #endif

    // MARK: - Persistence

    private func load() {
        guard let data = store.data(forKey: Self.key) else { return }
        fonts = (try? JSONDecoder().decode([Imported].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(fonts) else { return }
        store.set(data, forKey: Self.key)
    }
}