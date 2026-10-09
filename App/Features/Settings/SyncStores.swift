import Foundation

/// The live stores a sync reads from and writes to.
///
/// Passed as a bundle rather than read from globals so the capture and apply
/// halves are in one place: a field added to `SyncPayload` has exactly two
/// places to be honoured, and forgetting one turns sync into something that
/// silently stops carrying a setting.
///
/// Deliberately not included, and not by oversight:
/// - **Key material and gateway tokens.** They are in the Keychain precisely so
///   they do not travel. Moshi syncs credentials behind a second, separate
///   opt-in; this app has no such toggle, so there is nothing here that could
///   carry them even by accident — which is the point of building the payload
///   by hand rather than encoding the stores themselves.
/// - **Speech models.** Files, sometimes hundreds of megabytes, re-downloadable
///   on the other device. Syncing them would cost more than it saves.
/// - **The sync setting itself.** A device that has sync off must not have it
///   turned on by another device.
struct SyncStores {
    let hosts: HostStore
    let themes: ThemeStore
    let fonts: TerminalFontStore
    let cursor: CursorSettings
    let layout: SessionLayout
    let speech: SpeechSettings
}

extension SyncPayload {
    /// Reads the live configuration into a payload.
    static func capture(from stores: SyncStores) -> SyncPayload {
        var payload = SyncPayload()
        payload.hosts = stores.hosts.hosts
        payload.themeName = stores.themes.current.id
        payload.importedThemes = stores.themes.imported
        payload.fontFamily = stores.fonts.family.id
        payload.fontSize = stores.fonts.size
        payload.lineSpacing = stores.fonts.lineSpacing
        payload.cjkFallback = stores.fonts.cjk.rawValue
        payload.cursorShape = stores.cursor.shape.rawValue
        payload.cursorBlinks = stores.cursor.blinks
        payload.sessionLayout = stores.layout.style.rawValue
        payload.speechEngine = stores.speech.engine.rawValue
        payload.updatedAt = Date()
        return payload
    }

    /// Writes a payload back into the live stores.
    ///
    /// Every field is optional and applied only when present, so a payload
    /// written by a build that did not know about a setting leaves that setting
    /// alone rather than resetting it to a default.
    func apply(to stores: SyncStores) {
        for host in hosts {
            stores.hosts.upsert(host)
        }

        for theme in importedThemes {
            stores.themes.adopt(theme)
        }
        if let themeName, let match = stores.themes.all.first(where: { $0.id == themeName }) {
            stores.themes.select(match)
        }

        if let fontFamily, let family = TerminalFontFamily(rawValue: fontFamily) {
            stores.fonts.family = family
        }
        if let fontSize { stores.fonts.size = fontSize }
        if let lineSpacing { stores.fonts.lineSpacing = lineSpacing }
        if let cjkFallback, let cjk = CJKFallback(rawValue: cjkFallback) {
            stores.fonts.cjk = cjk
        }

        if let cursorShape, let shape = CursorSettings.Shape(rawValue: cursorShape) {
            stores.cursor.shape = shape
        }
        if let cursorBlinks { stores.cursor.blinks = cursorBlinks }

        if let sessionLayout, let style = SessionLayout.Style(rawValue: sessionLayout) {
            stores.layout.style = style
        }
        if let speechEngine, let engine = SpeechSettings.Engine(rawValue: speechEngine) {
            stores.speech.engine = engine
        }
    }
}