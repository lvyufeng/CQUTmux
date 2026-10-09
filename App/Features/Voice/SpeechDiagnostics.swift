import Foundation
import CQUTWhisper

#if DEBUG
/// Runs the app's own on-device speech path over a file and writes down what it
/// heard.
///
/// The microphone is the one part of dictation a simulator cannot drive — no
/// input device, and `simctl` has no way to inject audio. Everything downstream
/// of capture is still the real path: the model catalog and its location, the
/// SwiftPM C seam, `WhisperDictation`'s decoding and load, and the transcript
/// the terminal would have received. So a run supplies a recording instead of a
/// voice, and the transcript is written to a file rather than a status line —
/// which is what makes this checkable from a script rather than only by eye.
///
/// Lives at the app level rather than on the terminal screen on purpose: the
/// terminal needs a host and a live SSH session to exist, and needing a host to
/// test the speech engine would mean a failure here could be a failure there.
enum SpeechDiagnostics {
    /// `CQUT_DEV_TRANSCRIBE=/path/in/container/audio.wav`
    static func runIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["CQUT_DEV_TRANSCRIBE"],
              !path.isEmpty else { return }

        let settings = SpeechSettings()
        let store = WhisperModelStore()
        let engine = WhisperDictation(models: store)

        let report: String
        do {
            // The engine the user actually selected, not a fixed one: the
            // point of the harness is to exercise the shipped path, and a
            // Parakeet run that silently used a Whisper model would prove
            // nothing about Parakeet.
            let model = settings.model
            let text = try await engine.transcribeFile(
                at: URL(fileURLWithPath: path),
                model: model,
                language: model.multilingual ? "en" : nil)
            report = "TRANSCRIBE_OK\n\(text)\n"
        } catch {
            report = "TRANSCRIBE_FAIL\n\(error)\n"
        }

        // Both places a script can reach: the container's Documents, which
        // `simctl get_app_container` maps to a host path, and the simulator's
        // shared /tmp.
        if let directory = store.transcriptDirectory {
            try? report.write(to: directory.appendingPathComponent("transcript.txt"),
                              atomically: true, encoding: .utf8)
        }
        try? report.write(to: URL(fileURLWithPath: "/tmp/cqutmux_transcript.txt"),
                          atomically: true, encoding: .utf8)
        NSLog("CQUT_TRANSCRIBE %@", report.replacingOccurrences(of: "\n", with: " | "))
    }

    /// Runs the Cloud engine's request path against a real endpoint, with a
    /// recording instead of a microphone.
    ///
    /// Same reason as the local one: capture is the only part `simctl` cannot
    /// drive, and everything after it — the WAV it posts, the headers it sets,
    /// the answer it parses, the string the terminal would receive — is the
    /// shipped path. A script points this at a local server it controls, so
    /// the request can be read on the other end rather than inferred from the
    /// transcript alone.
    ///
    /// `CQUT_DEV_CLOUD_TRANSCRIBE=/path/in/container/audio.wav`, with the
    /// endpoint in `CQUT_DEV_CLOUD_URL` and the token in `CQUT_DEV_CLOUD_TOKEN`.
    static func runCloudIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CQUT_DEV_CLOUD_TRANSCRIBE"], !path.isEmpty,
              let raw = environment["CQUT_DEV_CLOUD_URL"], let endpoint = URL(string: raw)
        else { return }

        let engine = CloudDictation()
        let report: String
        do {
            let audio = try Data(contentsOf: URL(fileURLWithPath: path)).floatSamples()
            let text = try await engine.transcribe(
                audio,
                to: endpoint,
                token: environment["CQUT_DEV_CLOUD_TOKEN"],
                language: environment["CQUT_DEV_CLOUD_LANGUAGE"]
            )
            report = "CLOUD_TRANSCRIBE_OK\n\(text)\n"
        } catch {
            // `localizedDescription` for the same reason the engine uses it:
            // this harness exists to report what the status line would say,
            // and `"\(error)"` would report the enum case instead.
            report = "CLOUD_TRANSCRIBE_FAIL\n\(error.localizedDescription)\n"
        }

        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? report.write(to: directory.appendingPathComponent("cloud-transcript.txt"),
                          atomically: true, encoding: .utf8)
        try? report.write(to: URL(fileURLWithPath: "/tmp/cqutmux_cloud.txt"),
                          atomically: true, encoding: .utf8)
        NSLog("CQUT_CLOUD %@", report.replacingOccurrences(of: "\n", with: " | "))
    }
}

private extension Data {
    /// 16-bit little-endian PCM back to floats, for reading the same
    /// recordings the local harness uses. Skips a WAV header if one is there.
    func floatSamples() -> [Float] {
        var start = 0
        if count > 44, self[0..<4].elementsEqual("RIFF".utf8) {
            start = 44
        }
        var samples: [Float] = []
        samples.reserveCapacity((count - start) / 2)
        var index = start
        while index + 1 < count {
            let raw = UInt16(self[index]) | UInt16(self[index + 1]) << 8
            samples.append(Float(Int16(bitPattern: raw)) / 32_767)
            index += 2
        }
        return samples
    }
}
#endif