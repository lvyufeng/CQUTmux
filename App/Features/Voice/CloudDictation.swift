import Foundation
import AVFoundation
import Observation
import CQUTWhisper

/// Dictation against an HTTP transcription endpoint.
///
/// Moshi ships this as a service it hosts, which is the one part of the
/// feature that cannot be replicated by writing code — a hosted endpoint is a
/// product, not a build step, and this app has none to offer. What *can* be
/// replicated is the mechanism, so this engine points at an endpoint the user
/// supplies instead. That is a different product decision, and the settings
/// screen says which one it is rather than implying a service that is not
/// there.
///
/// It is also the only engine here that sends audio off the device, so it is
/// the only one whose screen must not carry the "never uploaded" line the
/// others do. Saying otherwise would be the same class of untruth as the
/// Apple engine silently uploading because it ignored `requiresOnDevice`.
///
/// Reuses `WhisperDictation.State` deliberately: the terminal reads one state
/// type, and a second identical enum would be a second thing to keep in step.
@Observable
final class CloudDictation {
    typealias State = WhisperDictation.State

    private(set) var state: State = .idle
    /// Called on the main queue with the finished text.
    var onResult: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let sampleRate: Double = 16_000
    /// Written from the audio tap, read when recording stops.
    private let queue = DispatchQueue(label: "app.cqutmux.cloud.audio")

    var isRecording: Bool { state == .recording }

    func start() {
        guard state != .recording else { return }
        Task { @MainActor in
            guard await Self.requestPermission() else {
                state = .unauthorized("Enable Microphone in Settings to dictate.")
                return
            }
            do {
                try begin()
                state = .recording
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    /// Stops recording and sends what was captured.
    func finish(endpoint: URL, token: String?, language: String?) {
        guard state == .recording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let audio = queue.sync { () -> [Float] in
            let copy = samples
            samples = []
            return copy
        }

        // Same floor the local engines use: under a quarter second is a tap,
        // and a tap sent to a server comes back as a hallucinated phrase.
        guard audio.count > Int(sampleRate / 4) else {
            state = .idle
            return
        }

        state = .transcribing
        Task { @MainActor in
            do {
                let text = try await send(audio, to: endpoint, token: token, language: language)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                state = .idle
                if !text.isEmpty { onResult?(text) }
            } catch {
                // `localizedDescription`, not string interpolation of the
                // error: every message on this path is written to be read in
                // the terminal's status line, and `"\(error)"` would print
                // `badStatus(503)` instead of the sentence meant for the user.
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard state.isBusy else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { samples = [] }
        state = .idle
    }

    // MARK: - Capture

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        queue.sync { samples = [] }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            // Downsampled by decimation rather than a resampler: 16 kHz is the
            // rate every speech service expects, and the anti-aliasing this
            // skips costs nothing on speech that is about to be transcribed
            // anyway — but doing it here keeps the upload tiny.
            let stride = max(1, Int(format.sampleRate / sampleRate))
            let picked = Swift.stride(from: 0, to: count, by: stride).map { channel[$0] }
            queue.sync { self.samples.append(contentsOf: picked) }
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Transport

    /// Posts an already-captured recording and returns the transcript. Public so
/// the diagnostics harness can drive the same request path with a file instead
/// of a microphone — a second copy of this for testing would be able to pass
/// while the real one fails.
    func transcribe(
        _ audio: [Float], to endpoint: URL, token: String?, language: String?
    ) async throws -> String {
        try await send(audio, to: endpoint, token: token, language: language)
    }

    private func send(
        _ audio: [Float], to endpoint: URL, token: String?, language: String?
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = CloudTranscription.body(
            audio: CloudTranscription.wav(from: audio, sampleRate: sampleRate),
            language: language
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw CloudTranscription.Failure.badStatus(http.statusCode)
            }
        }
        return try CloudTranscription.parse(data)
    }

    /// The one honest test of whether the microphone can be used. Returns
    /// immediately if the user has already answered.
    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}