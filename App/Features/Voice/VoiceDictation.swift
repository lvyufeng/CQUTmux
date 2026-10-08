import Foundation
import AVFoundation
import Speech
import Observation

/// On-device speech to text for the terminal. Audio and transcripts never
/// leave the device: `requiresOnDeviceRecognition` is set, and the recognizer
/// is asked to run offline.
@Observable
final class VoiceDictation {
    enum State: Equatable {
        case idle
        case unauthorized(String)
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Latest transcript, updated as the user speaks.
    private(set) var transcript = ""

    /// Called on the main queue whenever the transcript changes, with the mode:
    /// `.partial` while speaking, `.final` when the phrase is committed.
    enum Update { case partial(String), final(String) }
    var onUpdate: ((Update) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    var isListening: Bool { state == .listening }

    func toggle(locale: Locale = .current) {
        isListening ? stop() : start(locale: locale)
    }

    func start(locale: Locale = .current) {
        guard state != .listening else { return }
        transcript = ""

        Task { @MainActor in
            guard await requestAuthorization() else {
                state = .unauthorized("Enable Microphone and Speech Recognition in Settings.")
                return
            }
            do {
                try begin(locale: locale)
                state = .listening
            } catch {
                state = .failed("\(error)")
                await tearDown()
            }
        }
    }

    func stop() {
        task?.finish()
        Task { await tearDown() }
        if state == .listening { state = .idle }
    }

    // MARK: - Internals

    private func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private func begin(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.transcript = text
                self.onUpdate?(result.isFinal ? .final(text) : .partial(text))
                if result.isFinal { self.stop() }
            } else if let error {
                self.state = .failed("\(error)")
                Task { await self.tearDown() }
            }
        }
    }

    private func tearDown() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum DictationError: Error, CustomStringConvertible {
        case recognizerUnavailable

        var description: String {
            "speech recognizer is unavailable for this language"
        }
    }
}