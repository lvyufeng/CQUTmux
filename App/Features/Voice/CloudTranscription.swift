import Foundation

/// The parts of the Cloud dictation engine that have no dependency on audio
/// hardware: building the request body and understanding the answer.
///
/// Split out so they can be checked without a simulator or a microphone, which
/// is the point — both are places where being wrong is silent. A malformed WAV
/// header is still a valid HTTP body, and a response read from the wrong field
/// is still a string; neither would fail anywhere except in the transcript.
enum CloudTranscription {
    enum Failure: LocalizedError, Equatable {
        case unreadableResponse
        case badStatus(Int)
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .unreadableResponse:
                "The endpoint answered in a shape this app does not recognise — expected "
                    + "{\"text\": \"…\"} or a bare string."
            case .badStatus(let code):
                "The endpoint answered \(code)."
            case .notConfigured:
                "No transcription endpoint is set. Add one in Settings › Speech."
            }
        }
    }

    /// 16-bit mono PCM in a WAV container. Written by hand rather than with
    /// `AVAudioFile` because the samples are already in memory and this is
    /// forty-four bytes of header.
    static func wav(from samples: [Float], sampleRate: Double) -> Data {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            // Clamped before scaling: a sample outside [-1, 1] would overflow
            // `Int16` and wrap, turning a loud passage into noise.
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var out = Data()
        func ascii(_ string: String) { out.append(contentsOf: Array(string.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }

        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bits / 8)
        ascii("RIFF")
        // 36 is everything after this field: "WAVE" + the fmt chunk (24) + the
        // data header (8). It has to count the PCM bytes too, which is the
        // classic way to get this wrong — the file still plays, at the wrong
        // length.
        u32(UInt32(36 + pcm.count))
        ascii("WAVE")
        ascii("fmt ")
        u32(16) // PCM fmt chunk size
        u16(1) // format: PCM
        u16(channels)
        u32(UInt32(sampleRate))
        u32(byteRate)
        u16(channels * (bits / 8)) // block align
        u16(bits)
        ascii("data")
        u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    /// Accepts the two shapes a transcription endpoint plausibly returns: an
    /// object with a `text` (or `transcript`/`result`) field, and a bare
    /// string. Anything else is reported rather than guessed at, because the
    /// wrong guess here silently types garbage into a shell.
    static func parse(_ data: Data) throws -> String {
        if let text = try? JSONDecoder().decode(String.self, from: data) { return text }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["text", "transcript", "result"] {
                if let text = object[key] as? String { return text }
            }
        }
        throw Failure.unreadableResponse
    }

    /// The JSON body the endpoint receives.
    static func body(audio: Data, language: String?) -> Data {
        var object: [String: Any] = ["audio": audio.base64EncodedString()]
        if let language, !language.isEmpty { object["language"] = language }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}