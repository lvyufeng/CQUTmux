import SwiftUI

@main
struct CQUTmuxApp: App {
    @State private var hostStore = HostStore()
    @State private var connection = AgentConnection()
    @State private var themes = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .environment(connection)
                .environment(themes)
                .task {
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    #endif
                    _ = await ApprovalNotifier.requestAuthorization()
                }
        }
    }
}