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
        case parakeet
        case apple
        case whisper
        case cloud

        var label: String {
            switch self {
            case .parakeet: "Parakeet"
            case .apple: "Apple"
            case .whisper: "Whisper"
            case .cloud: "Cloud"
            }
        }

        /// The order Moshi presents them in, and for the same reason: Parakeet
        /// is the one to start with for English, Apple is there when its
        /// offline model is, and Whisper is the fallback for the languages
        /// neither covers.
        static var offered: [Engine] {
            var engines = allCases
            // Offered only when the vendored build actually has it, so the
            // picker never lists an engine that cannot load a model.
            if WhisperModel.parakeetModels.isEmpty {
                engines.removeAll { $0 == .parakeet }
            }
            return engines
        }

        var detail: String {
            switch self {
            case .parakeet:
                "Fast and accurate for English and many European languages, fully offline once "
                    + "the model is downloaded. Recommended unless you need a language it "
                    + "doesn't cover."
            case .apple:
                "On-device, no download. Needs the offline speech model for your language — "
                    + "iOS › General › Keyboard › Dictation."
            case .whisper:
                "whisper.cpp on the device. Works in any language it was trained on; the model is "
                    + "downloaded once and can be removed later."
            case .cloud:
                "Sends the recording to an endpoint you configure. The only engine here that "
                    + "uploads audio — use it only with a service you trust."
            }
        }
    }

    private let defaults: UserDefaults
    private static let key = "cqutmux.speech.engine"
    private static let modelKey = "cqutmux.speech.whisperModel"
    private static let parakeetModelKey = "cqutmux.speech.parakeetModel"

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Self.key) }
    }

    /// One stored name per family, because they are not interchangeable: the
    /// Parakeet choice would otherwise be lost every time the engine switched
    /// to Whisper and back, and the two engines' models are not substitutable.
    var whisperModelName: String {
        didSet { defaults.set(whisperModelName, forKey: Self.modelKey) }
    }
    var parakeetModelName: String {
        didSet { defaults.set(parakeetModelName, forKey: Self.parakeetModelKey) }
    }

    /// The model the selected engine will run.
    var model: WhisperModel {
        switch engine {
        case .parakeet:
            WhisperModel.parakeetModels.first { $0.name == parakeetModelName }
                ?? WhisperModel.parakeetModels.first
                ?? WhisperModel.whisperModels[0]
        case .apple, .whisper, .cloud:
            // Defaults to the smallest English one: the only choice that is
            // both quick to fetch and accurate enough to speak a shell command
            // into.
            WhisperModel.whisperModels.first { $0.name == whisperModelName }
                ?? WhisperModel.whisperModels.first { $0.name == "ggml-tiny.en.bin" }
                ?? WhisperModel.whisperModels[0]
        }
    }

    /// The models to list for the current engine. Apple's engine has none of
    /// its own — its model is the system's.
    var modelsForCurrentEngine: [WhisperModel] {
        switch engine {
        case .parakeet: WhisperModel.parakeetModels
        case .whisper: WhisperModel.whisperModels
        case .apple, .cloud: []
        }
    }

    private static let endpointKey = "cqutmux.speech.cloudEndpoint"
    private static let tokenAccount = "speech.cloud.token"

    /// The endpoint the Cloud engine posts to.
    ///
    /// Stored as typed and parsed on use, so a half-written URL does not get
    /// silently discarded while the user is in the middle of entering it. An
    /// empty string means "not configured", which the engine reports rather
    /// than failing at the microphone.
    var cloudEndpoint: String {
        didSet { defaults.set(cloudEndpoint, forKey: Self.endpointKey) }
    }

    var cloudURL: URL? {
        let trimmed = cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme, scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// Held in the Keychain rather than `UserDefaults`: it is a bearer token
    /// for someone else's service, and `UserDefaults` is a plist in the app
    /// container that any backup would carry off the device.
    var cloudToken: String {
        get { KeychainStore.load(account: Self.tokenAccount).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set {
            if newValue.isEmpty {
                KeychainStore.delete(account: Self.tokenAccount)
            } else {
                KeychainStore.save(Data(newValue.utf8), account: Self.tokenAccount)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.key)
        engine = stored.flatMap(Engine.init(rawValue:)) ?? .apple
        whisperModelName = defaults.string(forKey: Self.modelKey) ?? "ggml-tiny.en.bin"
        parakeetModelName = defaults.string(forKey: Self.parakeetModelKey)
            ?? WhisperModel.parakeetModels.first?.name
            ?? ""
        cloudEndpoint = defaults.string(forKey: Self.endpointKey) ?? ""
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
    private var cloud: CloudDictation?

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
        case .whisper, .parakeet: models.isInstalled(settings.model)
        case .cloud: settings.cloudURL != nil
        }
    }

    var setupHint: String? {
        switch settings.engine {
        case .apple:
            nil
        case .whisper, .parakeet:
            models.isInstalled(settings.model)
                ? nil
                : "Download \(settings.model.label) in Settings › Speech to dictate."
        case .cloud:
            settings.cloudURL == nil
                ? "Add a transcription endpoint in Settings › Speech to dictate."
                : nil
        }
    }

    func toggle(locale: Locale = .current) {
        switch settings.engine {
        case .apple:
            apple.toggle(locale: locale)
            isListening = apple.isListening
            problem = apple.state.problem
        case .whisper, .parakeet:
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
                engine.start(model: settings.model)
                isListening = engine.isRecording
            }
            problem = engine.state.problem
        case .cloud:
            guard let endpoint = settings.cloudURL else {
                problem = CloudTranscription.Failure.notConfigured.errorDescription
                return
            }
            let engine = cloud ?? {
                let made = CloudDictation()
                cloud = made
                return made
            }()
            if engine.isRecording {
                engine.finish(
                    endpoint: endpoint,
                    token: settings.cloudToken,
                    // Not `language(for:)`: that gates on the local model
                    // being multilingual, which has nothing to do with what a
                    // remote service can accept. The endpoint is told the
                    // device's language and decides for itself.
                    language: locale.language.languageCode?.identifier
                )
                isListening = false
            } else {
                engine.onResult = { [weak self] text in
                    guard let self else { return }
                    preview = ""
                    isListening = false
                    onUpdate?(.final(text))
                }
                engine.start()
                isListening = engine.isRecording
            }
            problem = engine.state.problem
        }
    }

    func stop() {
        switch settings.engine {
        case .apple: apple.stop()
        case .whisper, .parakeet:
            if whisper?.isRecording == true { whisper?.finish(language: nil) }
        case .cloud:
            cloud?.stop()
        }
        isListening = false
    }

    // MARK: - Internals

    private func language(for locale: Locale) -> String? {
        guard settings.model.multilingual else { return nil }
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