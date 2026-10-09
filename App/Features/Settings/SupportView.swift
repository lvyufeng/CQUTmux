import SwiftUI
import UIKit
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
                     + "the app can see — nothing from a session, and no credentials.")
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
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .task { await checkGateway() }
    }

    /// The report text, shown on screen as well as copied.
    ///
    /// Assembled as lines rather than as prose so it reads as a list of facts in
    /// whatever mail client it lands in, and so a missing field is visible
    /// rather than smoothed over.
    private var report: String {
        var lines = [
            "CQUTmux \(Bundle.main.appVersion)",
            "Device: \(Self.deviceModel)",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
        ]
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
        return lines.joined(separator: "\n")
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
