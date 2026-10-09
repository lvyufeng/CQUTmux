import SwiftUI

@main
struct CQUTmuxApp: App {
    /// The APNs token and lock-screen actions have no SwiftUI equivalent, so
    /// they arrive through a UIKit delegate that this adaptor installs.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var hostStore = HostStore()
    @State private var connection = AgentConnection()
    @State private var themes = ThemeStore()
    @State private var fonts = TerminalFontStore()
    @State private var cursor = CursorSettings()
    @State private var icons = AppIconStore()
    @State private var sessionLayout = SessionLayout()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .environment(connection)
                .environment(themes)
                .environment(fonts)
                .environment(cursor)
                .environment(icons)
                .environment(sessionLayout)
                .task {
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    // Runs off to the side: it loads a model and transcribes,
                    // which is seconds of work, and the notification prompt
                    // below should not wait behind it.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_TRANSCRIBE"] != nil {
                        Task.detached { await SpeechDiagnostics.runIfRequested() }
                    }
                    // UI runs can skip the permission prompt, which otherwise
                    // covers every screenshot taken in the first seconds.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_NO_NOTIFS"] == "1" { return }
                    // The permission dialog blocks this task until it is
                    // answered, and no simulator command can answer it, so an
                    // automated run needs a way past it to reach APNs.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_PUSH"] == "1" {
                        PushCoordinator.shared.register()
                        return
                    }
                    #endif
                    guard await ApprovalNotifier.requestAuthorization() else { return }
                    // Only worth asking APNs once the user has said yes to
                    // notifications at all; registering first would burn a
                    // round trip to fetch a token for pushes we'd drop.
                    PushCoordinator.shared.register()
                }
        }
    }
}