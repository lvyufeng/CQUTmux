import SwiftUI
import UIKit
import OSLog
import CQUTTransport

/// Settings → Support: what to send with a bug report, and where to send it.
///
/// Moshi's Support screen exists to pre-fill the things a report needs and
/// nobody remembers: app version, device, OS. This does the same, and it is
/// built around one rule that matters more than the convenience — **the report
/// text is shown before it is copied**, because it is assembled from this
/// device's own state and the person sending it is the only one who can tell
/// whether something in it should not leave the phone.
///
/// It deliberately does not collect anything automatically and does not talk to
/// any service. What it does is put the details in the clipboard; the report
/// goes wherever the user opens the link, which is a page they can read first.
///
/// The report carries the two things a bug report actually needs that a fact
/// list cannot supply: the headings a report has to fill in (Subject, Steps,
/// Expected, Actual) and the tail of the current agent session. Both are shown
/// in full before anything is copied, and a section with no source says so
/// rather than going quietly missing.
///
/// The diagnostics section attaches the process's recent unified-log entries.
/// There is still no `Logger` and no in-memory buffer in this build, but it
/// does not need either to carry a real log: `OSLogStore.local()` reads back
/// what the system already recorded for this process — `print`, `NSLog` and
/// `os_log` output alike — so the report can show the last few minutes of it
/// without inventing a logging subsystem. The read is bounded (a fixed entry
/// count and time window) and wrapped so a failure to read leaves the report
/// intact rather than empty: when the store returns nothing or throws, the
/// section says that, and why.
struct SupportView: View {
    /// Where a report goes. A URL we can actually be held to: an address we
    /// invented would look more finished and be worse, because a bug report
    /// sent into a mailbox nobody reads is a report the sender believes was
    /// received. There is no hosted CQUTmux service, so there is nothing to
    /// mail; the issue tracker is where a report about this app is visible and
    /// answered.
    static let repository = "https://github.com/lvyufeng/CQUTmux"

    static var issueURL: URL {
        URL(string: "\(repository)/issues/new?labels=bug")!
    }
    @Environment(HostStore.self) private var hosts
    @Environment(AgentConnection.self) private var connection

    @State private var copied = false
    @State private var gateway: GatewayState = .notConnected

    private enum GatewayState {
        case notConnected
        case checking
        case reachable(HookClient.Health)
        case unreachable(String)
    }

    var body: some View {
        List {
            Section {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy report details",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Link(destination: Self.issueURL) {
                    Label("Open an issue on GitHub", systemImage: "arrow.up.right.square")
                }
            } header: {
                Label("Report a bug", systemImage: "ladybug")
            } footer: {
                Text("Paste this into the report. It is the version, device and OS "
                     + "the app can see, plus the headings the report needs and the "
                     + "tail of the current agent session. No credentials.")
            }

            Section {
                LabeledContent("App", value: Bundle.main.appVersion)
                LabeledContent("Device", value: Self.deviceModel)
                LabeledContent("System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            } header: {
                Text("This device")
            }

            Section {
                if let host = connection.host ?? hosts.hosts.first {
                    LabeledContent("Host", value: host.displayName)
                    LabeledContent("Target", value: host.target)
                    LabeledContent("Transport", value: host.transport.rawValue)
                    LabeledContent("Gateway port", value: String(host.gatewayPort))
                } else {
                    Text("No host saved yet.").foregroundStyle(.secondary)
                }
                switch gateway {
                case .notConnected:
                    EmptyView()
                case .checking:
                    LabeledContent("Gateway", value: "checking…")
                case .reachable(let health):
                    LabeledContent("Gateway", value: "reachable")
                    LabeledContent("Events", value: "\(health.events ?? 0)")
                    LabeledContent("Pending", value: "\(health.pendingApprovals ?? 0)")
                case .unreachable(let why):
                    LabeledContent("Gateway", value: "unreachable")
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Connected host")
            } footer: {
                // Named because it is the field someone will look for: the token
                // and the key are exactly what a bug report must not carry, and
                // saying so is more use than leaving its absence to be noticed.
                Text("The gateway token and your SSH keys are never included.")
            }

            Section {
                Text(report)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("What will be sent")
            } footer: {
                Text("Subject, Steps, Expected and Actual are left blank for you to fill in.")
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await checkGateway()
            await loadAgentSession()
        }
    }

    /// The agent session this report can attach, if one was readable.
    ///
    /// Filled by `loadAgentSession` from the newest directory the user has
    /// browsed on this host — the same lookup the chat icon uses — and left nil
    /// when there is no connection or no session. The report then states that it
    /// could not read one rather than leaving a heading that looks like an empty
    /// attachment.
    @State private var agentSession: (directory: String, file: String?, lines: [String])?

    /// How much of the session tail to attach. Long enough to hold the turns
    /// around a failure, short enough that the report stays a report.
    private static let transcriptTail = 12

    /// The report text, shown on screen as well as copied.
    ///
    /// Assembled as lines rather than as prose so it reads as a list of facts in
    /// whatever mail client it lands in, and so a missing field is visible
    /// rather than smoothed over. It is the bug template a report is expected to
    /// fill in — Subject, Steps, Expected, Actual — followed by the facts this
    /// device can supply under Setup / Versions. The headings are left empty on
    /// purpose: the reporter is the only one who can say what they expected.
    private var report: String {
        var lines: [String] = []

        lines.append("Subject: ")
        lines.append("")
        lines.append("## Steps to reproduce")
        lines.append("1. ")
        lines.append("2. ")
        lines.append("")
        lines.append("## Expected")
        lines.append("")
        lines.append("## Actual")
        lines.append("")

        lines.append("## Setup / Versions")
        lines.append("CQUTmux \(Bundle.main.appVersion)")
        lines.append("Device: \(Self.deviceModel)")
        lines.append("System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        if let host = connection.host ?? hosts.hosts.first {
            lines.append("Host: \(host.displayName) (\(host.target))")
            lines.append("Transport: \(host.transport.rawValue), gateway port \(host.gatewayPort)")
        } else {
            lines.append("Host: none saved")
        }
        switch gateway {
        case .reachable(let health):
            lines.append("Gateway: reachable, \(health.events ?? 0) events, "
                         + "\(health.pendingApprovals ?? 0) pending")
        case .unreachable(let why):
            lines.append("Gateway: unreachable — \(why)")
        case .checking, .notConnected:
            lines.append("Gateway: not checked")
        }
        if let error = connection.lastError {
            lines.append("Last error: \(error)")
        }

        lines.append("")
        lines.append("## Diagnostics")
        lines.append(systemLog)

        lines.append("")
        lines.append("## Agent session")
        if let session = agentSession {
            lines.append("Directory: \(session.directory)")
            if let file = session.file {
                lines.append("Log: \((file as NSString).lastPathComponent)")
            }
            let count = session.lines.count
            lines.append("Last \(count) turn\(count == 1 ? "" : "s"):")
            lines.append(contentsOf: session.lines)
        } else if connection.client == nil {
            lines.append("No host connection, so no agent session could be read.")
        } else {
            lines.append("No readable agent session for this host's recent directories.")
        }

        return lines.joined(separator: "\n")
    }

    /// The last minute's unified-log entries for this process, as report lines.
    ///
    /// The app has no `Logger` and no in-memory buffer, but iOS's unified log
    /// already holds this process's own `print`, `NSLog` and `os_log` output,
    /// and `OSLogStore` can read it back. That is what makes a real log
    /// attachable without growing a logging subsystem: the entries below are
    /// what the system recorded, not something this screen made up. `print`
    /// goes to stdout and is not itself collected, so in practice these are the
    /// framework and `NSLog`/`os_log` lines around a failure.
    ///
    /// `OSLogStore.local()` is macOS-only — on iOS the store is asked for the
    /// current process's scope, which is the process's own entries without
    /// system-wide access the sandbox would refuse. The read is deliberately
    /// cheap and cannot break the report. It is capped at `logEntryLimit`
    /// entries over the last `logWindow` seconds. Any throw — building the
    /// store throws when there is no store to read — or an empty result returns
    /// the honest line instead, so the report never implies a log it does not
    /// have.
    @MainActor private var systemLog: String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let cutoff = Date().addingTimeInterval(-Self.logWindow)
            // Reverse from the newest entry, stopping at the cutoff or the
            // entry cap — so a busy window keeps the newest lines, and both
            // bounds hold without reading the whole store.
            var lines: [String] = []
            for case let entry as OSLogEntryLog in try store.getEntries(with: .reverse, at: nil, matching: nil) {
                if entry.date < cutoff { break }
                let stamp = Self.logStamp.string(from: entry.date)
                lines.append("\(stamp) \(Self.levelName(entry.level)) \(entry.composedMessage)")
                if lines.count >= Self.logEntryLimit { break }
            }
            guard !lines.isEmpty else {
                return "No unified-log entries for this process in the last "
                     + "\((Int(Self.logWindow) / 60)) minute(s)."
            }
            // Newest first from the store, oldest first for a reader.
            lines.reverse()
            return "Last \(lines.count) unified-log entr\(lines.count == 1 ? "y" : "ies") "
                 + "(process \(ProcessInfo.processInfo.processName)):\n"
                 + lines.joined(separator: "\n")
        } catch {
            return "No app log read: \(error.localizedDescription) "
                 + "The unified log was not accessible from this process."
        }
    }

    /// How many unified-log entries the report may carry.
    private static let logEntryLimit = 40

    /// How far back to look. Bounded so the Support screen does not stall, and
    /// short enough that the lines are about the failure at hand rather than
    /// the whole run.
    private static let logWindow: TimeInterval = 60

    private static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// A short name for an `OSLogEntryLog.Level`.
    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }

    /// Reads the newest readable session for the host, if there is one.
    ///
    /// The directory is the same one the chat icon opens (`RecentDirectoryStore`,
    /// newest first), and the transcript comes from the gateway the app is
    /// already tunnelled to — the Support screen reaches no network or file the
    /// rest of the app cannot. A directory with no session is skipped rather
    /// than reported, so one stale entry does not hide a newer conversation.
    private func loadAgentSession() async {
        guard let client = connection.client,
              let host = connection.host ?? hosts.hosts.first else { return }
        for directory in RecentDirectoryStore().recent(for: host) {
            guard let transcript = try? await client.transcript(path: directory) else { continue }
            let lines = Self.transcriptLines(transcript)
            guard transcript.found, !lines.isEmpty else { continue }
            agentSession = (directory, transcript.file, lines)
            return
        }
    }

    /// The last few turns of a transcript, one line each.
    ///
    /// Each message is flattened to a single line — role, then its text or a
    /// tool's summary — because this is an attachment to a report, not a second
    /// chat view. Thinking blocks are included: the reasoning around a failure
    /// is often the part that explains it.
    private static func transcriptLines(_ transcript: AgentTranscript) -> [String] {
        transcript.messages.suffix(transcriptTail).compactMap { message in
            let text = message.blocks
                .map { $0.kind == .tool ? $0.toolSummary : $0.displayText }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return "[\(message.role.rawValue)] \(text)"
        }
    }

    /// Asks the gateway it is already tunnelled to, not a fresh connection.
    ///
    /// A failure here is reported rather than hidden: "the gateway is not
    /// answering" is one of the two or three things a report is most often
    /// actually about, and a screen that silently omits it would be collecting
    /// everything except the useful part.
    private func checkGateway() async {
        guard let client = connection.client else {
            gateway = .notConnected
            return
        }
        gateway = .checking
        do {
            gateway = .reachable(try await client.health())
        } catch {
            gateway = .unreachable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// The hardware identifier, e.g. "iPhone17,1".
    ///
    /// `UIDevice.model` only ever says "iPhone", which is useless in a report —
    /// it does not distinguish a device with a problem from one without. The
    /// `uname` machine string is the identifier Apple's own crash reports use.
    static var deviceModel: String {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

#Preview {
    NavigationStack { SupportView() }
        .environment(HostStore())
        .environment(AgentConnection())
}
