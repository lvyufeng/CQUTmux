import Foundation
import AVFoundation
import Observation
import CQUTWhisperC

/// Dictation backed by a whisper.cpp model running on the device.
///
/// This is the engine for the case Apple's can't cover: `SFSpeechRecognizer`
/// accepts `requiresOnDeviceRecognition` and then quietly ignores it on a
/// locale whose model was never downloaded, so the only honest thing it can do
/// there is refuse (see VoiceDictation, which does). Whisper has no such
/// behaviour — the model is a file on disk, and whether it can run is a
/// question with an answer — so it works on every device and in every
/// language the model was trained on, at the cost of the download.
///
/// The shape of use is different, and that difference is the whole design:
/// Apple's recognizer streams partial results while you speak, Whisper wants
/// the finished utterance. So this records, and transcribes when you stop.
/// Pretending otherwise would mean re-running the model on a growing buffer
/// every few hundred milliseconds, which on a phone is a very hot way to be
/// slightly more responsive.
@Observable
public final class WhisperDictation {
    public enum State: Equatable {
        case idle
        case unauthorized(String)
        case recording
        case transcribing
        case failed(String)

        public var isBusy: Bool { self == .recording || self == .transcribing }
    }

    public private(set) var state: State = .idle
    public private(set) var transcript = ""
    /// Set while the model is loading, which is a second or two of real work
    /// on the first phrase and instant afterwards.
    public private(set) var status: String?

    /// Called on the main queue with the finished text.
    public var onResult: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let sampleRate: Double = 16_000
    /// Guarded by `queue`: written from the audio tap, read when recording stops.
    private let queue = DispatchQueue(label: "app.cqutmux.whisper.audio")

    private let models: WhisperModelStore
    private var handle: OpaquePointer?
    private var loaded: String?

    public var isRecording: Bool { state == .recording }

    public init(models: WhisperModelStore) {
        self.models = models
    }

    deinit {
        if let handle { cqut_whisper_free(handle) }
    }

    public func toggle(model: WhisperModel, language: String? = nil) {
        state == .recording ? finish(language: language) : start(model: model)
    }

    public func start(model: WhisperModel) {
        guard state != .recording else { return }
        transcript = ""

        Task { @MainActor in
            guard await requestPermission() else {
                state = .unauthorized("Enable Microphone in Settings to dictate.")
                return
            }
            guard models.isInstalled(model) else {
                state = .failed("\(model.label) is not downloaded yet.")
                return
            }
            do {
                try await load(model)
                try begin()
                state = .recording
            } catch {
                state = .failed("\(error)")
                await tearDown()
            }
        }
    }

    /// Stops recording and transcribes what was captured.
    public func finish(language: String? = nil) {
        guard state == .recording else { return }
        tearDownSync()

        let audio = queue.sync { () -> [Float] in
            let copy = samples
            samples = []
            return copy
        }

        guard audio.count > Int(sampleRate / 4) else {
            // Under a quarter second is a tap, not a phrase; transcribing it
            // produces hallucinated text, which is worse than nothing.
            state = .idle
            return
        }

        state = .transcribing
        Task { @MainActor in
            do {
                try transcribe(audio, language: language)
                state = .idle
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onResult?(text) }
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    public func cancel() {
        guard state.isBusy else { return }
        tearDownSync()
        queue.sync { samples = [] }
        state = .idle
    }

    /// Transcribes a file instead of the microphone.
    ///
    /// The same load-and-transcribe path the microphone takes, minus the
    /// capture — which is the part that cannot be scripted, so this is how the
    /// rest of it gets tested on a simulator with no audio input. It is also
    /// the shape a "transcribe this recording" feature would need.
    public func transcribeFile(at url: URL, model: WhisperModel, language: String? = nil) async throws -> String {
        try await load(model)

        let samples = try Self.readWave(url, targetRate: sampleRate)
        guard !samples.isEmpty else { throw WhisperError.failed("no audio in \(url.lastPathComponent)") }
        state = .transcribing
        defer { state = .idle }
        try transcribe(samples, language: language)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = text
        return text
    }

    /// 16-bit PCM WAV, any channel count, resampled to `targetRate`.
    ///
    /// Chunks are walked rather than a fixed offset assumed: exported files
    /// routinely carry a LIST or fact chunk before the samples, and reading
    /// from byte 44 on those returns metadata interpreted as audio — which
    /// Whisper transcribes as confident nonsense.
    static func readWave(_ url: URL, targetRate: Double) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 12 else { throw WhisperError.failed("not a WAV file") }

        var offset = 12
        var sourceRate = targetRate
        var channels = 1
        var bits = 16
        var samples: [Float] = []

        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int {
            Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
        }
        func tag(_ at: Int) -> String {
            String(bytes: data[at..<(at + 4)], encoding: .ascii) ?? ""
        }

        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= data.count {
                channels = max(1, u16(body + 2))
                sourceRate = Double(u32(body + 4))
                bits = u16(body + 14)
            } else if id == "data" {
                let available = min(size, data.count - body)
                let bytesPerSample = max(1, bits / 8)
                let frames = available / (bytesPerSample * channels)
                samples.reserveCapacity(frames)
                for frame in 0..<frames {
                    // Only the first channel: Whisper is mono, and averaging
                    // would smear a stereo recording's phase for nothing.
                    let at = body + frame * bytesPerSample * channels
                    if bits == 16 {
                        let raw = Int16(bitPattern: UInt16(u16(at)))
                        samples.append(Float(raw) / 32768)
                    } else if bits == 8 {
                        samples.append((Float(data[at]) - 128) / 128)
                    } else if bits == 32 {
                        let value = Int32(bitPattern: UInt32(truncatingIfNeeded: u32(at)))
                        samples.append(Float(value) / 2_147_483_648)
                    } else {
                        throw WhisperError.failed("\(bits)-bit samples are not supported")
                    }
                }
                break
            }
            // Chunks are word-aligned, and a stray odd length would otherwise
            // walk off into noise.
            offset = body + size + (size & 1)
        }

        guard !samples.isEmpty else { throw WhisperError.failed("no audio in the file") }
        guard abs(sourceRate - targetRate) >= 1 else { return samples }

        let ratio = sourceRate / targetRate
        let count = Int(Double(samples.count) / ratio)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    /// Drops the loaded model. Whisper's tiny model is 77 MB resident and the
    /// large one over a gigabyte, so the app calls this when dictation is
    /// turned off rather than holding it for the life of the process.
    public func unload() {
        if let handle { cqut_whisper_free(handle) }
        handle = nil
        loaded = nil
    }

    // MARK: - Internals

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private func load(_ model: WhisperModel) async throws {
        if loaded == model.name, handle != nil { return }
        unload()

        status = "Loading \(model.label)…"
        defer { status = nil }

        let path = models.path(for: model).path
        // The GPU is asked for only when the platform can actually use it. On
        // the simulator Metal registers a device and then traps on the first
        // graph, because its working-set limit is zero; on device this is the
        // difference between usable and not.
        #if targetEnvironment(simulator)
        let useGPU = false
        #else
        let useGPU = cqut_whisper_gpu_available() != 0
        #endif

        let context = await Task.detached(priority: .userInitiated) { () -> OpaquePointer? in
            path.withCString { cqut_whisper_load($0, useGPU ? 1 : 0) }
        }.value

        guard let context else {
            throw WhisperError.failed(String(cString: cqut_whisper_last_error()))
        }
        handle = context
        loaded = model.name
    }

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)

        queue.sync { samples = [] }
        // 4096 frames: the tap fires on the audio thread, and appending to a
        // Swift array at 1024-frame callbacks allocates often enough to matter
        // on a phone. Handling the rate conversion here too keeps the buffer
        // the model sees at the 16 kHz it requires.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var converted = [Float](repeating: 0, count: count)
        let source = buffer.format.sampleRate
        if abs(source - sampleRate) < 1 {
            converted.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: channel, count: count) }
        } else {
            // Linear resampling. Whisper's front end is a mel spectrogram that
            // is already lossy about fine detail, and the alternative —
            // AVAudioConverter on the audio thread — costs more than the
            // difference it makes.
            let ratio = source / sampleRate
            for i in 0..<count {
                let position = Double(i) / ratio
                let lower = Int(position)
                let upper = min(lower + 1, count - 1)
                let fraction = Float(position - Double(lower))
                converted[i] = channel[lower] * (1 - fraction) + channel[upper] * fraction
            }
        }

        queue.sync { samples.append(contentsOf: converted) }
    }

    private func transcribe(_ audio: [Float], language: String?) throws {
        guard let handle else { throw WhisperError.modelNotLoaded }
        status = "Transcribing…"
        defer { status = nil }

        let rc: Int32 = audio.withUnsafeBufferPointer { buffer in
            let samples = buffer.baseAddress
            if let language {
                return language.withCString { cqut_whisper_transcribe(handle, samples, Int32(buffer.count), $0) }
            }
            return cqut_whisper_transcribe(handle, samples, Int32(buffer.count), nil)
        }

        guard rc == 0 else {
            throw WhisperError.failed(String(cString: cqut_whisper_last_error()))
        }

        var text = ""
        for index in 0..<cqut_whisper_segment_count(handle) {
            if let piece = cqut_whisper_segment_text(handle, index) {
                text += String(cString: piece)
            }
        }
        transcript = text
    }

    private func tearDownSync() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tearDown() async {
        tearDownSync()
    }
}