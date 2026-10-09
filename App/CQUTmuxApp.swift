import SwiftUI

@main
struct CQUTmuxApp: App {
    /// The APNs token and lock-screen actions have no SwiftUI equivalent, so
    /// they arrive through a UIKit delegate that this adaptor installs.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var hostStore = HostStore()
    @State private var connection = AgentConnection()
    /// What each saved host's gateway is doing, for the dot in the host list.
    @State private var probe = GatewayProbe()
    @State private var themes = ThemeStore()
    @State private var fonts = TerminalFontStore()
    @State private var customFonts = CustomFontStore()
    @State private var cursor = CursorSettings()
    @State private var icons = AppIconStore()
    @State private var sessionLayout = SessionLayout()
    @State private var toolbar = ToolbarSettings()
    @State private var app = AppSettings()
    @State private var security = SecuritySettings()
    @State private var gate = SecuritySettings.Gate()
    @State private var sync = SettingsSync()

    /// Whether the app was away long enough that coming back should re-prompt.
    /// A glance at another app is not a handoff, and prompting for it would
    /// make the setting unusable rather than protective.
    @Environment(\.scenePhase) private var scenePhase
    @State private var leftAt: Date?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .environment(connection)
                .environment(probe)
                .environment(themes)
                .environment(fonts)
                .environment(customFonts)
                .environment(cursor)
                .environment(icons)
                .environment(sessionLayout)
                .environment(toolbar)
                .environment(app)
                .environment(security)
                .environment(gate)
                .environment(sync)
                .overlay {
                    if gate.isLocked { LockedView(gate: gate) }
                }
                .task {
                    // Wired here rather than in the font screen, so an imported
                    // font resolves from the first frame the terminal is built
                    // rather than only after someone visits Settings.
                    fonts.customFonts = customFonts
                    #if DEBUG
                    // A UI run cannot drive the document picker, so a font to
                    // look at has to arrive by path. Done here, before the
                    // screen is built, so the picker and the list are already
                    // populated when Settings → Font first appears.
                    if let path = ProcessInfo.processInfo.environment["CQUT_DEV_IMPORT_FONT"],
                       let imported = customFonts.importForTesting(path: path) {
                        fonts.family = .custom
                        fonts.customFontID = imported.id
                    }
                    #endif
                    // Runs before the debug seeds so a synced host list is
                    // what the seeds have to override, not the other way round.
                    await syncStore()
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    // The resolve probe runs here rather than in `RootView`'s
                    // task, which is built in the same pass as the screen: that
                    // one can run before this seeding has happened and see an
                    // empty host list, which is exactly what it did. After
                    // `apply` returns, the seeded host and its Keychain entries
                    // are both in place.
                    DebugSeed.resolveAndReport(hostStore)
                    if ProcessInfo.processInfo.environment["CQUT_DEV_FONT_PROBE"] == "1" {
                        DebugSeed.reportFonts()
                    }
                    // Runs off to the side: it loads a model and transcribes,
                    // which is seconds of work, and the notification prompt
                    // below should not wait behind it.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_TRANSCRIBE"] != nil {
                        Task.detached { await SpeechDiagnostics.runIfRequested() }
                    }
                    if ProcessInfo.processInfo.environment["CQUT_DEV_CLOUD_TRANSCRIBE"] != nil {
                        Task.detached { await SpeechDiagnostics.runCloudIfRequested() }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await syncStore() } }
            switch phase {
            case .background:
                leftAt = Date()
            case .active:
                // A session on a real host is worth protecting when the phone
                // has been put down and handed over; thirty seconds is the
                // boundary Moshi uses and the one that keeps a glance at a
                // notification from demanding a face.
                if let leftAt, Date().timeIntervalSince(leftAt) > 30 {
                    gate.lockIfNeeded(settings: security)
                }
                leftAt = nil
            default:
                break
            }
        }
    }

    /// One sync exchange with every live store attached.
    ///
    /// On return to the foreground as well as at launch, because the interesting
    /// moment for a pull is picking the device up after editing on another one —
    /// and a pull that only happens at launch is a pull the user never sees.
    private func syncStore() async {
        guard sync.isEnabled else { return }
        let coordinator = SettingsSyncCoordinator(sync: sync)
        let stores = SyncStores(
            hosts: hostStore,
            themes: themes,
            fonts: fonts,
            cursor: cursor,
            layout: sessionLayout,
            toolbar: toolbar,
            speech: SpeechSettings(),
            integrations: IntegrationSettings(),
            input: InputSettings(),
            mux: MuxSettings()
        )
        await coordinator.run(stores: stores)
    }
}

/// Covers the app while the biometric prompt is up.
///
/// Deliberately not a `switch`: the app's state has to survive the lock, and
/// tearing the view tree down would drop the terminal's session — which is the
/// thing worth protecting, and losing it would make the setting cost more than
/// it protects.
private struct LockedView: View {
    let gate: SecuritySettings.Gate
    @Environment(SecuritySettings.self) private var security

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("CQUTmux is locked")
                    .font(.headline)
                if let problem = gate.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Unlock") {
                    Task { await gate.unlock(reason: "Unlock CQUTmux") }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}