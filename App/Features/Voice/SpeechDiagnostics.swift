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
            let text = try await engine.transcribeFile(
                at: URL(fileURLWithPath: path),
                model: settings.whisperModel,
                language: settings.whisperModel.multilingual ? "en" : nil)
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
}
#endif