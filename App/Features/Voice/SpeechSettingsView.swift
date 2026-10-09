import SwiftUI
import CQUTWhisper

/// Engine picker and model manager for dictation.
///
/// Worth a screen of its own because the choice has a cost attached: Apple's
/// engine is free but only works where the device already has an offline model,
/// and Whisper works everywhere but has to download one. Hiding that behind a
/// single toggle would mean a microphone that silently does nothing on some
/// phones and not others.
struct SpeechSettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @State private var settings = SpeechSettings()
    @State private var models = WhisperModelStore()
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(SpeechSettings.Engine.offered, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Speech engine")
            } footer: {
                Text(settings.engine.detail)
            }

            if settings.engine == .cloud {
                cloudSection
            } else if settings.engine != .apple {
                modelSection
            }

            languageSection

            Section {
                Toggle("Send after dictating", isOn: $settings.autoSend)
            } header: {
                Label("After dictating", systemImage: "text.badge.checkmark")
            } footer: {
                Text("On, a finished phrase is run as soon as you stop speaking. Off, "
                     + "it is typed into the line and waits for Return, so you can fix "
                     + "a misheard word before the shell sees it.")
            }

            Section {
                LabeledContent("Permission", value: "Microphone")
            } footer: {
                // The claim has to match the engine. Cloud posts audio to a
                // service the user chose, so carrying the on-device line here
                // would be exactly the kind of quiet untruth this app already
                // went out of its way to avoid in the Apple engine.
                if settings.engine == .cloud {
                    Text("The recording is sent to the endpoint above over the network. "
                         + "Use an HTTPS endpoint you trust.")
                } else {
                    Text("Audio is transcribed on this device and never uploaded. Models come from "
                         + "Hugging Face: whisper.cpp models from ggerganov/whisper.cpp, Parakeet "
                         + "from ggml-org/parakeet-GGUF.")
                }
            }
        }
        .navigationTitle("Speech")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            // A UI run cannot work the picker, and the Cloud section only
            // exists while Cloud is selected, so a screenshot of it needs the
            // engine chosen from outside.
            let environment = ProcessInfo.processInfo.environment
            if let raw = environment["CQUT_DEV_SPEECH_ENGINE"],
               let engine = SpeechSettings.Engine(rawValue: raw) {
                settings.engine = engine
            }
            if let endpoint = environment["CQUT_DEV_CLOUD_URL"] {
                settings.cloudEndpoint = endpoint
            }
            #endif
        }
    }

    /// Endpoint and token for the Cloud engine.
    ///
    /// The screen says outright that Moshi hosts this service and this app does
    /// not, because otherwise a user would read "Cloud" and assume it just
    /// works. It is the same choice the rest of these settings make: describe
    /// what is actually there.
    @ViewBuilder
    private var cloudSection: some View {
        Section {
            TextField("https://…/v1/audio/transcriptions", text: $settings.cloudEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Bearer token (optional)", text: tokenBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Endpoint")
        } footer: {
            if !settings.cloudEndpoint.isEmpty && settings.cloudURL == nil {
                Text("That is not an http(s) URL yet, so dictation will refuse to start.")
                    .foregroundStyle(themes.current.accentColor)
            } else {
                Text("POSTs a WAV recording and expects {\"text\": \"…\"} back. The token is kept "
                     + "in the Keychain, not in the app's preferences. Moshi runs this endpoint "
                     + "itself; this app has no service to offer, so bring your own.")
            }
        }
    }

    /// The language dictation listens in: automatic, or pinned.
    ///
    /// Shown for every engine, because hiding it above one and revealing it
    /// below another is how a setting becomes folklore. What each engine does
    /// with it differs, and the footer says which is which rather than letting
    /// someone pin a language on a monolingual model and hear nothing change.
    private var languageSection: some View {
        Section {
            Picker("Language", selection: languageBinding) {
                Text("Automatic (device language)").tag(String?.none)
                ForEach(Self.languages, id: \.code) { language in
                    Text(language.name).tag(String?.some(language.code))
                }
            }
        } header: {
            Label("Language", systemImage: "globe")
        } footer: {
            Text(languageFooter)
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(get: { settings.languageCode }, set: { settings.languageCode = $0 })
    }

    private var languageFooter: String {
        switch settings.engine {
        case .apple:
            return "Apple's recogniser follows the keyboard and device settings; "
                + "pinning a language here overrides the locale it is asked for."
        case .cloud:
            return "Sent to your endpoint with the request. Whether it is honoured "
                + "depends on the service."
        case .parakeet:
            return "Parakeet is trained on English and European languages."
        case .whisper:
            // The one place the model choice and the language choice are the
            // same decision, so it is worth saying outright.
            return settings.model.multilingual
                ? "The selected model is multilingual, so a pinned language is passed to it."
                : "The selected model is English-only (its name ends in .en), so it "
                    + "ignores this and transcribes English whatever you pick."
        }
    }

    /// The languages worth offering. Not the full BCP-47 list: a picker with
    /// six hundred entries is one nobody scrolls, and these are the ones the
    /// bundled models can actually serve.
    private static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
    ]

    /// Reads through the Keychain on every keystroke and writes on every one,
    /// which is why it is not `@State`: the token never sits in a view.
    private var tokenBinding: Binding<String> {
        Binding(get: { settings.cloudToken }, set: { settings.cloudToken = $0 })
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("Model") {
            ForEach(settings.modelsForCurrentEngine) { model in
                row(model)
            }
        }

        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func row(_ model: WhisperModel) -> some View {
        let installed = models.isInstalled(model)
        let progress = models.progress(for: model)

        Button {
            Task { await choose(model, installed: installed) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                    HStack(spacing: 6) {
                        Text(model.sizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if model.multilingual {
                            Text("multilingual")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let progress {
                    // Bytes, not a spinner: 574 MB is long enough that a user
                    // deserves to know it is moving.
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if settings.model.name == model.name && installed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(themes.current.accentColor)
                } else if installed {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "arrow.down.circle.dotted")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(models.isDownloading)
        .swipeActions {
            if installed {
                Button("Delete", role: .destructive) {
                    models.remove(model)
                    if settings.model.name == model.name {
                        // Falling back rather than leaving the picker pointing
                        // at a file that is gone, which would make the
                        // microphone fail with no visible cause.
                        select(firstOf: model.family, in: settings)
                    }
                }
            }
        }
        .contextMenu {
            if installed {
                Button("Delete", role: .destructive) { models.remove(model) }
            }
        }
    }

    private func choose(_ model: WhisperModel, installed: Bool) async {
        select(model, in: settings)
        guard !installed else { return }
        do {
            try await models.download(model)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Writes the choice into whichever family the model belongs to, so
    /// picking a Parakeet model does not overwrite the Whisper choice.
    private func select(_ model: WhisperModel, in settings: SpeechSettings) {
        switch model.family {
        case .whisper: settings.whisperModelName = model.name
        case .parakeet: settings.parakeetModelName = model.name
        }
    }

    private func select(firstOf family: WhisperModel.Family, in settings: SpeechSettings) {
        switch family {
        case .whisper: settings.whisperModelName = WhisperModel.whisperModels.first?.name ?? ""
        case .parakeet: settings.parakeetModelName = WhisperModel.parakeetModels.first?.name ?? ""
        }
    }
}