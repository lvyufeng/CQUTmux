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

            if settings.engine != .apple {
                modelSection
            }

            Section {
                LabeledContent("Permission", value: "Microphone")
            } footer: {
                Text("Audio is transcribed on this device and never uploaded. Models come from "
                     + "Hugging Face: whisper.cpp models from ggerganov/whisper.cpp, Parakeet "
                     + "from ggml-org/parakeet-GGUF.")
            }
        }
        .navigationTitle("Speech")
        .navigationBarTitleDisplayMode(.inline)
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
                        .foregroundStyle(Theme.accent)
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