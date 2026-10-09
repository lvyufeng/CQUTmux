import Foundation
import Observation
import CQUTWhisper

/// Which speech engine dictation uses, and the model choice for the local one.
///
/// The two engines are not interchangeable, and the settings screen says so
/// rather than pretending one is simply better. Apple's is instant and free of
/// any download, but only on locales whose offline model the device already
/// has — and it refuses rather than uploading audio when it doesn't. Whisper
/// works everywhere, in every language the model knows, at the cost of a
/// download and a moment of transcription at the end of each phrase.
@Observable
final class SpeechSettings {
    enum Engine: String, CaseIterable, Sendable {
        case apple
        case whisper

        var label: String {
            switch self {
            case .apple: "Apple"
            case .whisper: "Whisper"
            }
        }

        var detail: String {
            switch self {
            case .apple:
                "On-device, no download. Needs the offline speech model for your language — "
                    + "iOS › General › Keyboard › Dictation."
            case .whisper:
                "whisper.cpp on the device. Works in any language it was trained on; the model is "
                    + "downloaded once and can be removed later."
            }
        }
    }

    private let defaults: UserDefaults
    private static let key = "cqutmux.speech.engine"
    private static let modelKey = "cqutmux.speech.whisperModel"

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Self.key) }
    }

    /// The model to run, defaulting to the smallest English one: it is the
    /// only choice that is both quick to fetch and accurate enough to speak a
    /// shell command into.
    var whisperModelName: String {
        didSet { defaults.set(whisperModelName, forKey: Self.modelKey) }
    }

    var whisperModel: WhisperModel {
        WhisperModel.all.first { $0.name == whisperModelName }
            ?? WhisperModel.all.first { $0.name == "ggml-tiny.en.bin" }
            ?? WhisperModel.all[0]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.key)
        engine = stored.flatMap(Engine.init(rawValue:)) ?? .apple
        whisperModelName = defaults.string(forKey: Self.modelKey) ?? "ggml-tiny.en.bin"
    }
}

/// One microphone button over two engines.
///
/// The terminal should not have to know which engine is selected, and the
/// difference between them is real: Apple's streams partial results while you
/// speak, whisper records and transcribes when you stop. Both end the same way
/// — with a final string — so the button and the shell see one interface, and
/// only the preview line differs.
@Observable
final class Dictation {
    enum Update { case partial(String), final(String) }

    private(set) var isListening = false
    private(set) var preview = ""
    private(set) var problem: String?

    var onUpdate: ((Update) -> Void)?

    private let settings: SpeechSettings
    private let models: WhisperModelStore
    private let apple = VoiceDictationWrapper()
    private var whisper: WhisperDictation?

    init(settings: SpeechSettings, models: WhisperModelStore) {
        self.settings = settings
        self.models = models
        apple.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .partial(let text):
                preview = text
                onUpdate?(.partial(text))
            case .final(let text):
                preview = ""
                isListening = false
                onUpdate?(.final(text))
            }
        }
    }

    /// True when the selected engine cannot run as configured — no model
    /// downloaded, or no offline model for the locale. Surfaced so the button
    /// can say why before the user speaks rather than after.
    var isReady: Bool {
        switch settings.engine {
        case .apple: true
        case .whisper: models.isInstalled(settings.whisperModel)
        }
    }

    var setupHint: String? {
        switch settings.engine {
        case .apple:
            nil
        case .whisper:
            models.isInstalled(settings.whisperModel)
                ? nil
                : "Download \(settings.whisperModel.label) in Settings › Speech to dictate."
        }
    }

    func toggle(locale: Locale = .current) {
        switch settings.engine {
        case .apple:
            apple.toggle(locale: locale)
            isListening = apple.isListening
            problem = apple.state.problem
        case .whisper:
            // Built on first use rather than in `init`: it holds an
            // AVAudioEngine, and constructing one for every `Dictation` the
            // terminal makes — including when Apple's engine is selected —
            // would be work nobody asked for.
            let engine = whisper ?? {
                let made = WhisperDictation(models: models)
                whisper = made
                return made
            }()
            if engine.isRecording {
                engine.finish(language: language(for: locale))
                isListening = false
            } else {
                engine.onResult = { [weak self] text in
                    guard let self else { return }
                    preview = ""
                    isListening = false
                    onUpdate?(.final(text))
                }
                engine.start(model: settings.whisperModel)
                isListening = engine.isRecording
            }
            problem = engine.state.problem
        }
    }

    func stop() {
        switch settings.engine {
        case .apple: apple.stop()
        case .whisper:
            if whisper?.isRecording == true { whisper?.finish(language: nil) }
        }
        isListening = false
    }

    // MARK: - Internals

    private func language(for locale: Locale) -> String? {
        guard settings.whisperModel.multilingual else { return nil }
        return locale.language.languageCode?.identifier
    }
}

/// The `VoiceDictation` interface, narrowed to what `Dictation` needs.
///
/// Kept as a wrapper rather than used directly so the engine switch has one
/// seam: `Dictation` is the only place that knows there are two engines, and
/// `VoiceDictation` stays as it was.
@Observable
final class VoiceDictationWrapper {
    private let engine = VoiceDictation()
    var onUpdate: ((VoiceDictation.Update) -> Void)? {
        get { engine.onUpdate }
        set { engine.onUpdate = newValue }
    }
    var isListening: Bool { engine.isListening }
    var state: VoiceDictation.State { engine.state }

    func toggle(locale: Locale = .current) { engine.toggle(locale: locale) }
    func stop() { engine.stop() }
}

extension VoiceDictation.State {
    /// The reason dictation cannot run, if any — phrased for the terminal's
    /// status line rather than shown raw.
    var problem: String? {
        switch self {
        case .unauthorized(let message), .failed(let message): message
        case .idle, .listening: nil
        }
    }
}

extension WhisperDictation.State {
    var problem: String? {
        switch self {
        case .unauthorized(let message), .failed(let message): message
        case .idle, .recording, .transcribing: nil
        }
    }
}