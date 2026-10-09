import Foundation

// Checks for the Cloud dictation engine's two silent-failure surfaces: the WAV
// container and the response parser. Neither fails loudly in the app — a
// malformed header still posts, and a wrongly-parsed answer is still a string
// — so the checks have to read the bytes rather than trust that it ran.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

func u32(_ data: Data, _ offset: Int) -> UInt32 {
    data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}
func u16(_ data: Data, _ offset: Int) -> UInt16 {
    data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
}
func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
    String(decoding: data[offset..<offset + count], as: UTF8.self)
}

// MARK: - WAV container

let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
let rate: Double = 16_000
let wav = CloudTranscription.wav(from: samples, sampleRate: rate)

check(ascii(wav, 0, 4) == "RIFF", "starts with RIFF")
check(ascii(wav, 8, 4) == "WAVE", "declares WAVE")
check(ascii(wav, 12, 4) == "fmt ", "has a fmt chunk")
check(u32(wav, 4) == UInt32(wav.count - 8), "RIFF size counts every byte after it")
check(u32(wav, 16) == 16, "fmt chunk is the 16-byte PCM form")
check(u16(wav, 20) == 1, "format tag is PCM")
check(u16(wav, 22) == 1, "mono")
check(u32(wav, 24) == 16_000, "sample rate is 16 kHz")
check(u32(wav, 28) == 16_000 * 2, "byte rate matches channels x rate x width")
check(u16(wav, 32) == 2, "block align is two bytes")
check(u16(wav, 34) == 16, "16 bits per sample")
check(ascii(wav, 36, 4) == "data", "has a data chunk")
check(u32(wav, 40) == UInt32(samples.count * 2), "data size counts PCM bytes")
check(wav.count == 44 + samples.count * 2, "header is 44 bytes, then PCM")

// The values themselves, little-endian and scaled to Int16.
check(wav[44] == 0 && wav[45] == 0, "0.0 encodes as zero")
// Both signs scale by 32767 and truncate toward zero, so the magnitudes match.
// Using -32768 for the trough would make the two halves of a waveform
// asymmetric by one count for no gain.
let half = Int16(bitPattern: u16(wav, 46))
check(half == 16_383, "0.5 encodes as 16383, not 16384")
let negHalf = Int16(bitPattern: u16(wav, 48))
check(negHalf == -16_383, "-0.5 mirrors 0.5 rather than flooring to -16384")
check(Int16(bitPattern: u16(wav, 50)) == 32_767, "1.0 encodes as the positive peak")
check(Int16(bitPattern: u16(wav, 52)) == -32_767, "-1.0 encodes as the negative peak")

// Clamping: out-of-range values must not wrap. Without the clamp 2.0 would
// scale past Int16 and become a large negative — audible as noise, and the
// kind of corruption no decoder reports.
let loud = CloudTranscription.wav(from: [2.0, -2.0, 100.0], sampleRate: rate)
check(Int16(bitPattern: u16(loud, 44)) == 32_767, "2.0 clamps to the positive peak")
check(Int16(bitPattern: u16(loud, 46)) == -32_767, "-2.0 clamps to the negative peak")
check(Int16(bitPattern: u16(loud, 48)) == 32_767, "100.0 clamps too, rather than wrapping")

// An empty recording is still a well-formed file, not a truncated one.
let empty = CloudTranscription.wav(from: [], sampleRate: rate)
check(empty.count == 44, "an empty recording is a bare header")
check(u32(empty, 40) == 0, "and its data chunk is empty, not missing")

// MARK: - Response parsing

func parsed(_ json: String) -> String? {
    try? CloudTranscription.parse(Data(json.utf8))
}

check(parsed(#"{"text": "hello"}"#) == "hello", "reads the text field")
check(parsed(#"{"transcript": "hi"}"#) == "hi", "reads the transcript alias")
check(parsed(#"{"result": "ok"}"#) == "ok", "reads the result alias")
check(parsed(#""just a string""#) == "just a string", "accepts a bare JSON string")
check(parsed(#"{"text": "line\nbreak"}"#) == "line\nbreak", "unescapes the payload")

// The cases that must be refused rather than guessed at: a wrong guess here
// types something into a shell.
check(parsed(#"{"error": "nope"}"#) == nil, "refuses an unrecognised object")
check(parsed(#"{"text": 42}"#) == nil, "refuses a non-string text field")
check(parsed("not json at all") == nil, "refuses a non-JSON body")
check(parsed("") == nil, "refuses an empty body")
check(parsed(#"{"text": ""}"#) == "", "accepts a legitimately empty transcript")

// Same key ordering as `parse` checks, so an object carrying several is not
// ambiguous.
check(parsed(#"{"transcript": "a", "text": "b"}"#) == "b", "prefers text over transcript")

// MARK: - Structured errors

check(
    CloudTranscription.Failure.badStatus(503).errorDescription?.contains("503") == true,
    "a bad status names the code"
)
check(
    CloudTranscription.Failure.notConfigured.errorDescription?.contains("Settings") == true,
    "the unconfigured message says where to fix it"
)

// MARK: - Request body

let body = CloudTranscription.body(audio: wav, language: "en")
let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
check(object?["language"] as? String == "en", "the body carries the language")
check(
    (object?["audio"] as? String).flatMap { Data(base64Encoded: $0) } == wav,
    "the audio survives base64 round-trip byte for byte"
)
let noLanguage = CloudTranscription.body(audio: wav, language: nil)
let bare = try? JSONSerialization.jsonObject(with: noLanguage) as? [String: Any]
check(bare?["language"] == nil, "no language key when none is known")

print("")
if failures == 0 {
    print("CLOUD_DICTATION_PASS  (\(checks) checks)")
} else {
    print("CLOUD_DICTATION_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}