import SwiftUI
import UIKit
import SwiftTerm
import CQUTTransport
import CQUTWhisper

/// `sheet(item:)` needs an `Identifiable`; `UIImage` isn't one.
struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Bridges `CQUTTerminalView` into SwiftUI and hosts the keyboard accessory bar.
struct TerminalScreen: View {
    let host: Host
    let credential: SSHCredential
    /// A session to attach to once the terminal is live, from a link.
    var link: DeepLink? = nil

    @State private var coordinator = TerminalCoordinator()
    @State private var settings = SpeechSettings()
    @State private var speechModels = WhisperModelStore()
    @State private var dictation: Dictation?
    @State private var showSessions = false
    @State private var annotating: PendingImage?
    @State private var pastedNotice: String?
    @State private var shortcuts = ShortcutStore()
    @State private var gestures = GestureStore()
    @State private var cursor = CursorSettings()
    @State private var input = InputSettings()
    @State private var mux = MuxSettings()
    /// Whether a hardware keyboard is attached, inferred from the software
    /// keyboard's absence. See `InputSettings.showsBar`.
    @State private var hardwareKeyboard = false
    @State private var showShortcuts = false
    @State private var showGestures = false
    @State private var showJumpTo = false
    /// Set once the link's attach command has been sent, so a reconnect — which
    /// also reaches `.connected` — does not attach a second time.
    @State private var didFollowLink = false
    @Environment(ThemeStore.self) private var themes
    @Environment(TerminalFontStore.self) private var fonts
    @Environment(AgentConnection.self) private var connection

    var body: some View {
        TerminalViewRepresentable(
                host: host,
                credential: credential,
                coordinator: coordinator,
                theme: themes.current,
                fonts: fonts,
                gestures: gestures,
                cursor: cursor,
                input: input,
                mux: mux
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StatusBadge(status: coordinator.status) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            coordinator.terminal?.reconnect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                        // Until this menu existed the shortcut editor was
                        // reachable only from a debug environment variable,
                        // which is to say not from the app.
                        Button {
                            showShortcuts = true
                        } label: {
                            Label("Custom Keys", systemImage: "keyboard")
                        }
                        Button {
                            showGestures = true
                        } label: {
                            Label("Gestures", systemImage: "hand.tap")
                        }
                        // Only herdr can be addressed by pane, so offering
                        // Jump To without a gateway connection would be a menu
                        // item that can only fail.
                        if connection.client != nil {
                            Button {
                                showJumpTo = true
                            } label: {
                                Label("Jump To", systemImage: "arrow.turn.down.right")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSessions) { sessionPicker }
            .sheet(isPresented: $showShortcuts) {
                NavigationStack { ShortcutEditorView(store: shortcuts) }
            }
            .sheet(isPresented: $showGestures) {
                NavigationStack { GestureEditorView(store: gestures) }
            }
            .sheet(isPresented: $showJumpTo) {
                if let client = connection.client {
                    JumpToView(client: client) {}
                }
            }
            .sheet(item: $annotating) { pending in annotator(pending.image) }
            .overlay(alignment: .top) { pasteNotice }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if InputSettings.showsBar(
                    hideWithHardwareKeyboard: input.hideBarWithHardwareKeyboard,
                    hardwareKeyboard: hardwareKeyboard
                ) {
                    VStack(spacing: 0) {
                        if host.mux == "tmux", !input.hidesWindowRow { windowRow }
                        accessoryBar
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                hardwareKeyboard = InputSettings.isHardwareKeyboard(frameHeight: frame.height)
            }
            // A linked session is attached on the same signal the rest of the
            // UI uses to mean "the shell is up", rather than after a guessed
            // delay — an attach command sent into a session that is not ready
            // yet goes nowhere.
            .onChange(of: coordinator.status) { _, status in
                guard status.isLive, let session = link?.session, !didFollowLink else { return }
                didFollowLink = true
                coordinator.terminal?.attachSession(mux: session.mux, name: session.name)
                if let window = session.window, !window.isEmpty {
                    // A beat, because the client has to have attached before
                    // the jump means "this client, this window"; sending it in
                    // the same write as the attach would be read as text by the
                    // shell the attach is still replacing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        coordinator.terminal?.selectWindow(
                            mux: session.mux, session: session.name, selector: window
                        )
                    }
                }
            }
            // The session picker and the paste-image button both ride the gateway
            // tunnel that the Inbox owns. The shell connects it at launch, but
            // that races the host store being read from disk — and when it
            // loses, opening the Terminal tab first leaves both buttons
            // missing for the rest of the session. Asking here makes the tab
            // that needs the tunnel responsible for it.
            .task {
                if connection.client == nil { connection.connect(to: host) }
            }
            .onAppear {
                if dictation == nil {
                    let engine = Dictation(settings: settings, models: speechModels)
                    engine.onUpdate = { update in
                        switch update {
                        case .partial(let text): coordinator.setDictationPreview(text)
                        case .final(let text):
                            coordinator.setDictationPreview("")
                            coordinator.terminal?.sendDictatedLine(text)
                        }
                    }
                    dictation = engine
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "sessions" {
                    showSessions = true
                }
                // Custom keys have to be composable from the outside to be
                // testable: pressing a button on the bar is not something a
                // simulator command can do, so a run declares the binding it
                // wants and the bar builds it the same way a tap would.
                if let spec = ProcessInfo.processInfo.environment["CQUT_DEV_SHORTCUT"], !spec.isEmpty {
                    shortcuts.add(spec)
                }
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "shortcuts" {
                    showShortcuts = true
                }
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "gestures" {
                    showGestures = true
                }
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "jumpto" {
                    showJumpTo = true
                }
                // A binding cannot be swiped from a script any more than a key
                // can be tapped, so a run declares the gesture and the bytes
                // travel the same `send(binding:)` path a real swipe does.
                // `CQUT_DEV_GESTURE=swipeLeft=text:touch SWIPED` binds a gesture, and
                // `CQUT_DEV_FIRE_GESTURE=swipeLeft` then fires it once the
                // session is live. Firing goes through the view's own
                // `send(binding:)`, which is the path a real recogniser takes,
                // so a pass is evidence about the gesture and not about the
                // test having called `write` itself.
                if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_GESTURE"] {
                    let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, let gesture = TerminalGesture(rawValue: parts[0]) {
                        gestures.set(parts[1], for: gesture)
                    }
                }
                if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_FIRE_GESTURE"],
                   let gesture = TerminalGesture(rawValue: raw) {
                    DebugSeed.fireGestureWhenConnected(view: coordinator.terminal, gesture: gesture)
                }
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "annotate" {
                    // Wait a beat so the gateway tunnel is up; otherwise the
                    // sheet renders its connecting placeholder.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        annotating = PendingImage(image: Self.debugFixture())
                    }
                }
                #endif
            }
    }

    /// One tap per tmux window, 1–9, above the key bar.
    ///
    /// Above rather than below on purpose: this is the row a thumb reaches
    /// past to get to the keys, and the keys are the ones pressed constantly.
    /// A row that pushed them up the screen would cost more than it saved.
    ///
    /// Only 1–9 because tmux binds those to bare digits — window 10 needs the
    /// command prompt, which is what Jump To is for. Showing 1–20 as glass
    /// buttons would make two thirds of them do something different from the
    /// rest.
    ///
    /// Only shown for tmux, and that is the whole reason the view consults
    /// `host.mux`: these buttons send prefix-key keystrokes, so on a zellij or
    /// herdr session they would type a control character into the pane instead
    /// of switching tabs — the failure mode this row is most likely to have.
    private var windowRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(1...9, id: \.self) { index in
                    Button {
                        coordinator.terminal?.selectWindow(
                            mux: "tmux", session: "", selector: String(index)
                        )
                    } label: {
                        Text("\(index)")
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minWidth: 30, minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private var accessoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Built from the user's arrangement rather than written out
                // here, so reordering and hiding in Settings and the bar itself
                // cannot disagree.
                ForEach(input.items) { item in
                    barItem(item)
                }
                // Dictation is not optional and not in the list: it is the one
                // control with no key equivalent, and a bar the user emptied
                // completely would leave no way to start it.
                if !input.items.contains(.dictation) { dictationButton }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            if !coordinator.dictationPreview.isEmpty {
                Text(coordinator.dictationPreview)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .offset(y: -22)
                    .transition(.opacity)
            }
        }
    }

    /// The user's own bindings, after the built-ins so the bar reads
    /// left-to-right from the keys everyone gets to the ones they chose.
    ///
    /// A shortcut that no longer parses still shows — it is the user's key, and
    /// hiding it would look like the app had lost it — but it is tinted so the
    /// reason it does nothing is visible.
    @ViewBuilder
    private var customShortcutKeys: some View {
        ForEach(shortcuts.shortcuts) { shortcut in
            Button {
                guard let bytes = shortcut.bytes else { return }
                coordinator.terminal?.sendRaw(Data(bytes))
            } label: {
                Text(shortcut.label)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(minWidth: 40, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .tint(shortcut.problem == nil ? nil : .orange)
            .accessibilityHint(shortcut.problem ?? shortcut.text)
        }
    }

    /// Image paste needs the gateway to carry the bytes to the host, so the
    /// button only appears when a host is connected.
    @ViewBuilder
    private var pasteImageButton: some View {
        if connection.client != nil {
            Button(action: pasteImage) {
                Image(systemName: "photo.badge.plus").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            pastedNotice = "No image on the clipboard"
            Task {
                try? await Task.sleep(for: .seconds(2))
                pastedNotice = nil
            }
            return
        }
        annotating = PendingImage(image: image)
    }

    @ViewBuilder
    private func annotator(_ image: UIImage) -> some View {
        // The sheet can open before the tunnel finishes coming up; show a
        // placeholder rather than an empty sheet in that window.
        if let client = connection.client {
            ImageAnnotatorView(image: image, client: client) { path in
                // Drop the uploaded path into the prompt; the user finishes
                // the message and submits it themselves.
                coordinator.terminal?.typeText(path + " ")
                pastedNotice = "Sent to \(path)"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    pastedNotice = nil
                }
            }
        } else {
            NavigationStack { ProgressView("Connecting…") }
        }
    }

    @ViewBuilder
    private var pasteNotice: some View {
        if let pastedNotice {
            Text(pastedNotice)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// A stand-in screenshot so a UI run can exercise the annotator without
    /// staging a real clipboard image. Debug builds only.
    private static func debugFixture() -> UIImage {
        let size = CGSize(width: 640, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "246  func connect() {\n247      status = .connecting\n248      transport.connect(...)\n249  }"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor(red: 0.6, green: 1, blue: 0.7, alpha: 1),
            ]
            (text as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: attributes)
        }
    }

    /// tmux sessions live behind the host gateway, so the picker needs the
    /// shared agent connection. It is hidden when no host is connected.
    @ViewBuilder
    private var sessionsButton: some View {
        if connection.client != nil {
            Button { showSessions = true } label: {
                Image(systemName: "rectangle.stack").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
        }
    }

    @ViewBuilder
    private var sessionPicker: some View {
        if let client = connection.client {
            SessionPickerView(client: client) { action in
                switch action {
                case .attach(let mux, let name):
                    coordinator.terminal?.attachSession(mux: mux, name: name)
                case .window(let mux, let session, let selector):
                    coordinator.terminal?.selectWindow(
                        mux: mux, session: session, selector: selector
                    )
                }
            }
        }
    }

    private var dictationButton: some View {
        // The button reflects the selected engine's state, which is why this
        // reads through `dictation` rather than owning a `VoiceDictation`: with
        // whisper chosen, listening continues while the phrase is transcribed,
        // and a button that claimed otherwise would invite a second press.
        let listening = dictation?.isListening ?? false
        return Button {
            dictation?.toggle()
        } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .symbolEffect(.variableColor, isActive: listening)
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(listening ? themes.current.accentColor : nil)
        .disabled(dictation?.isReady == false)
        .accessibilityHint(dictation?.setupHint ?? "")
    }

    @ViewBuilder
    private func barItem(_ item: InputSettings.Item) -> some View {
        switch item {
        case .control: key("Ctrl", CtrlKey.control)
        case .escape: key("Esc", CtrlKey.escape)
        case .tab: key("Tab", CtrlKey.tab)
        case .arrows:
            icon("arrow.up", CtrlKey.upArrow)
            icon("arrow.down", CtrlKey.downArrow)
            icon("arrow.left", CtrlKey.leftArrow)
            icon("arrow.right", CtrlKey.rightArrow)
        case .dpad: dpad
        case .clipboard: icon("doc.on.doc", CtrlKey.clipboard)
        case .pasteImage: pasteImageButton
        case .sessions: sessionsButton
        case .dictation: dictationButton
        case .customKeys: customShortcutKeys
        }
    }

    /// A four-way pad with the corner slots bindable to the keys a terminal
    /// actually needs on a phone. The arrows alone leave no way to reach
    /// Delete, Interrupt or a full-screen TUI's Escape without the Esc button.
    ///
    /// Corners are two user-chosen actions; the cross sends arrows. Only the
    /// corners are configurable because the arrows are the part a finger aims
    /// at and should not move.
    private var dpad: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                cornerKey(.topLeading)
                icon("arrow.up", CtrlKey.upArrow)
                cornerKey(.topTrailing)
            }
            HStack(spacing: 2) {
                icon("arrow.left", CtrlKey.leftArrow)
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
                    .frame(width: 30, height: 30)
                icon("arrow.right", CtrlKey.rightArrow)
            }
            HStack(spacing: 2) {
                cornerKey(.bottomLeading)
                icon("arrow.down", CtrlKey.downArrow)
                cornerKey(.bottomTrailing)
            }
        }
    }

    private func cornerKey(_ slot: InputSettings.Corner) -> some View {
        let action = input.corner(slot)
        return Button {
            switch action {
            case .none: break
            case .hideKeyboard: UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            case .delete: coordinator.terminal?.sendDelete()
            case .interrupt: coordinator.terminal?.sendInterrupt()
            case .escape: coordinator.terminal?.sendEscape()
            }
        } label: {
            Text(action.cornerLabel)
                .font(.caption2)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .disabled(action == .none)
    }

    private func key(_ label: String, _ key: CtrlKey) -> some View {
        Button { coordinator.press(key) } label: {
            Text(label)
                .font(.system(.subheadline, design: .monospaced))
                .frame(minWidth: 44, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
    }

    private func icon(_ systemName: String, _ key: CtrlKey) -> some View {
        Button { coordinator.press(key) } label: {
            Image(systemName: systemName)
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
    }
}

enum CtrlKey {
    case control, escape, tab, upArrow, downArrow, leftArrow, rightArrow, clipboard
}

/// Owns the UIKit terminal and the SSH session across SwiftUI updates.
@Observable
final class TerminalCoordinator {
    var status: CQUTTerminalView.Status = .idle
    /// Live dictation text, shown above the accessory bar while listening.
    var dictationPreview = ""
    @ObservationIgnored weak var terminal: CQUTTerminalView?

    func setDictationPreview(_ text: String) { dictationPreview = text }

    func press(_ key: CtrlKey) {
        guard let terminal else { return }
        switch key {
        case .control: terminal.toggleControl()
        case .escape: terminal.sendEscape()
        case .tab: terminal.sendTab()
        case .upArrow: terminal.sendArrow(up: true, down: false, left: false, right: false)
        case .downArrow: terminal.sendArrow(up: false, down: true, left: false, right: false)
        case .rightArrow: terminal.sendArrow(up: false, down: false, left: false, right: true)
        case .leftArrow: terminal.sendArrow(up: false, down: false, left: true, right: false)
        case .clipboard: terminal.pasteFromClipboard()
        }
    }
}

private struct TerminalViewRepresentable: UIViewRepresentable {
    let host: Host
    let credential: SSHCredential
    /// Read at connect time, so flipping the toggle and reconnecting takes
    /// effect without anything being rebuilt.
    let integrations = IntegrationSettings()
    let coordinator: TerminalCoordinator
    let theme: TerminalTheme
    let fonts: TerminalFontStore
    let gestures: GestureStore
    let cursor: CursorSettings
    let input: InputSettings
    let mux: MuxSettings

    /// Remembers what the view was last painted with. A `UIViewRepresentable`
    /// has no way to compare its own inputs between updates, and repainting the
    /// terminal on every SwiftUI pass would also re-install the 16-colour
    /// palette each time.
    final class Coordinator {
        var appliedTheme: String?
        var appliedCursor: CursorStyle?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CQUTTerminalView {
        var configuration = TransportConfiguration(
            host: host.hostname,
            port: host.port,
            username: host.username,
            credential: credential,
            // The jump host authenticates with the same credential the user
            // saved for the target; the form takes `user@host:port` but has no
            // separate secret, and a single account hop-through is the usual
            // shape. Parsing handles the bare-IPv6 case without eating it.
            jumpHost: JumpHost.parse(
                host.jumpHost,
                fallbackUser: host.username,
                credential: credential
            ),
            // Only for key auth over plain SSH: mosh and ET are not SSH once
            // they are up, so there is no channel to carry the request.
            forwardAgent: host.forwardAgent && host.transport == .ssh && credential.isKey,
            agentSigner: SSHCredential.agentSigner(for: credential)
        )
        // Read here, where the session is actually built, rather than captured
        // when the transport was constructed: the toggle is a live setting, and
        // a value captured earlier would keep exporting after it was turned off.
        // Carried to the session's shell over SSH, and for mosh also as an
        // explicit `-l` on mosh-server, which builds its own environment and
        // would otherwise not see it. ET has no way to carry it at all; see
        // `SSHETLauncher`.
        configuration.applyIntegrationMarkers(IntegrationSettings())
        // The transport is chosen here rather than defaulted in the view, so a
        // host that asks for something unavailable says why instead of quietly
        // behaving like SSH.
        let transport: TerminalTransport
        switch TransportFactory.make(kind: host.transport, configuration: configuration, host: host) {
        case .success(let built):
            transport = built
        case .failure(let unavailable):
            transport = UnavailableTransport(reason: unavailable.reason)
        }

        let view = CQUTTerminalView(
            frame: .zero,
            configuration: configuration,
            startupCommand: host.sessionCommand.isEmpty ? nil : host.sessionCommand,
            startupPreamble: integrations.shellExportLine,
            theme: theme,
            font: fonts.uiFont(),
            transport: transport
        )
        view.gestures = gestures
        view.optionIsMeta = input.optionIsMeta
        view.muxPrefix = mux.tmuxPrefix
        view.onStatus = { status in coordinator.status = status }
        // A pinch resizes the terminal and becomes the saved preference, so the
        // next session opens at the size the user settled on.
        view.onFontSizeChange = { size in
            fonts.size = Double(size)
        }
        coordinator.terminal = view
        context.coordinator.appliedTheme = theme.id
        context.coordinator.appliedCursor = cursor.style
        view.applyCursor(cursor)
        DispatchQueue.main.async { view.connect() }
        #if DEBUG
        // A simulator cannot be typed into from a test script without
        // accessibility permissions, so the input half of a transport is
        // otherwise untestable. This types a phrase in after the session is up
        // — through the same `send` the on-screen keyboard calls.
        if let phrase = ProcessInfo.processInfo.environment["CQUT_DEV_TYPE"] {
            DebugSeed.typeWhenConnected(view: view, phrase: phrase)
        }
        // Same path, but for the composed characters a keyboard hands over:
        // `CQUT_DEV_TYPE` writes UTF-8 into the terminal, which cannot carry an
        // Option press, so the Meta rewrite is exercised through this instead.
        if let composed = ProcessInfo.processInfo.environment["CQUT_DEV_TYPE_COMPOSED"] {
            DebugSeed.typeComposedWhenConnected(view: view, text: composed)
        }
        // Fires a tmux jump so the configured prefix is the one on the wire;
        // the host's `cat -v` then shows it as `^B` or `^A`.
        if let index = ProcessInfo.processInfo.environment["CQUT_DEV_JUMP_WINDOW"] {
            DebugSeed.jumpWindowWhenConnected(view: view, index: index)
        }
        // Same idea for a custom shortcut: the bar cannot be tapped from a
        // script, so the binding is pressed for it and the bytes travel the
        // path a real tap would.
        if let spec = ProcessInfo.processInfo.environment["CQUT_DEV_SHORTCUT"],
           let parsed = try? ShortcutGrammar.parse(spec) {
            DebugSeed.pressShortcutWhenConnected(view: view, bytes: parsed.bytes)
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: CQUTTerminalView, context: Context) {
        // The theme is a live setting: changing it while a session is open
        // should repaint the terminal, not wait for the next connection. The
        // font is handled by the store's own pinch callback, and reconnecting
        // here would drop the session, so only the palette is pushed.
        if context.coordinator.appliedTheme != theme.id {
            context.coordinator.appliedTheme = theme.id
            uiView.applyTheme(theme)
        }
        if context.coordinator.appliedCursor != cursor.style {
            context.coordinator.appliedCursor = cursor.style
            uiView.applyCursor(cursor)
        }
        // A live setting: flipping it should take effect on the next key, not
        // on the next connection.
        uiView.optionIsMeta = input.optionIsMeta
        uiView.muxPrefix = mux.tmuxPrefix
    }
}

private struct StatusBadge: View {
    let status: CQUTTerminalView.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: SwiftUI.Color {
        switch status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .closed: .orange
        case .idle: .gray
        }
    }

    private var text: String {
        switch status {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .closed(let code): code.map { "closed (\($0))" } ?? "closed"
        case .failed: "failed"
        }
    }
}