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
                    ForEach(SpeechSettings.Engine.allCases, id: \.self) { engine in
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

            if settings.engine == .whisper {
                whisperSection
            }

            Section {
                LabeledContent("Permission", value: "Microphone")
            } footer: {
                Text("Audio is transcribed on this device. Whisper models are downloaded from "
                     + "Hugging Face at huggingface.co/ggerganov/whisper.cpp.")
            }
        }
        .navigationTitle("Speech")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var whisperSection: some View {
        Section("Model") {
            ForEach(WhisperModel.all) { model in
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
                } else if settings.whisperModelName == model.name && installed {
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
                    if settings.whisperModelName == model.name {
                        // Falling back rather than leaving the picker pointing
                        // at a file that is gone, which would make the
                        // microphone fail with no visible cause.
                        settings.whisperModelName = WhisperModel.all.first?.name ?? ""
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
        settings.whisperModelName = model.name
        guard !installed else { return }
        do {
            try await models.download(model)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}