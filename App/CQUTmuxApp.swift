import SwiftUI

@main
struct CQUTmuxApp: App {
    @State private var hostStore = HostStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .task {
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    #endif
                }
        }
    }
}