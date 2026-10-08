import SwiftUI

@main
struct CQUTmuxApp: App {
    @State private var hostStore = HostStore()
    @State private var connection = AgentConnection()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .environment(connection)
                .task {
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    #endif
                }
        }
    }
}