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
    /// The agent conversation, opened from the toolbar icon.
    @State private var showChat = false
    /// Directories the user has been in, for the chat's transcript path.
    @State private var recents = RecentDirectoryStore()

    /// The directory whose transcript the chat icon opens.
    ///
    /// The newest directory the user browsed on this host, falling back to "."
    /// — which is the gateway's own working directory. The shell's live cwd is
    /// what this really wants, and nothing reports it: reading it would mean
    /// probing the pane on every open, and a wrong guess is a chat that says
    /// "no session found" rather than the wrong conversation, because the
    /// transcript is looked up per directory.
    private var chatPath: String {
        recents.recent(for: host).first ?? "."
    }
    @State private var annotating: PendingImage?
    /// The four ways an image can arrive, presented as one chooser. The
    /// clipboard case is handled inline (there is nothing to present); the
    /// other three each have their own presentation.
    @State private var showAttachSources = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showFiles = false
    @State private var pastedNotice: String?
    @State private var shortcuts = ShortcutStore()
    @State private var gestures = GestureStore()
    @State private var cursor = CursorSettings()
    @State private var input = InputSettings()
    @State private var mux = MuxSettings()
    @State private var transcriptionHistory = TranscriptionHistory()
    /// Whether a host program may read this device's clipboard (OSC 52 read).
    /// Read from the environment so the Security screen's switch is the one
    /// source of truth for it.
    @Environment(SecuritySettings.self) private var security
    /// Whether a hardware keyboard is attached, inferred from the software
    /// keyboard's absence. See `InputSettings.showsBar`.
    @State private var hardwareKeyboard = false
    @State private var showShortcuts = false
    @State private var showGestures = false
    @State private var showJumpTo = false
    @State private var showHistory = false
    /// The shell's command history, which is a separate list from the dictation
    /// one above despite both being called "history": one is what was said out
    /// loud and lives on the phone, the other is what was run and lives on the
    /// host.
    @State private var showCommandHistory = false
    /// ⌘N opens the host list to start another connection. A sheet rather than
    /// a push: the terminal is presented as one, so pushing would put a list
    /// under it whose back button leads somewhere the user never was.
    @State private var newConnection = false
    /// Raised by a long press on the keyboard button. See `keyboardButton`.
    @State private var showSpeechSettings = false
    /// Set once the link's attach command has been sent, so a reconnect — which
    /// also reaches `.connected` — does not attach a second time.
    @State private var didFollowLink = false
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themes
    @Environment(ToolbarSettings.self) private var toolbar
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
                mux: mux,
                pinchZoomsPane: toolbar.pinchAction == .zoomPane,
                // Only herdr has a socket route that names the pane, and only
                // when a gateway is actually connected — otherwise the pinch
                // falls through to the mux prefix key, which is what tmux and
                // zellij need.
                pinchZoomsHerdrPane: toolbar.pinchAction == .zoomPane
                    && host.mux == "herdr" && connection.client != nil,
                onPinchZoom: { zoomed in
                    guard let client = connection.client else { return }
                    Task { try? await client.zoomHerdrPane(zoomed: zoomed) }
                },
                allowsClipboardRead: security.allowsClipboardRead,
                onShowShortcuts: { showShortcuts = true },
                onShowSessions: { if connection.client != nil { showSessions = true } },
                onNewConnection: { newConnection = true },
                onMinimize: { minimize() }
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The agent icon: one tap from the session to its
                // conversation. Moshi reaches Chat View from the terminal
                // rather than only from the Code pane because the terminal is
                // where you are while the agent runs, and walking to another
                // tab to read what it just did is the trip this saves.
                ToolbarItem(placement: .topBarLeading) {
                    if connection.client != nil {
                        Button {
                            showChat = true
                        } label: {
                            Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    StatusBadge(
                        status: coordinator.status,
                        // A short drag down opens the session switcher, which is
                        // a gesture on the header rather than another bar button
                        // because the header is the part of the screen a thumb
                        // reaches without looking.
                        onSoftDrag: { if connection.client != nil { showSessions = true } },
                        onHardDrag: { minimize() }
                    )
                }
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
                        Button {
                            showHistory = true
                        } label: {
                            Label("Dictation History", systemImage: "waveform")
                        }
                        if connection.client != nil {
                            Button {
                                showCommandHistory = true
                            } label: {
                                Label("Command History", systemImage: "clock.arrow.circlepath")
                            }
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
            .sheet(isPresented: $showChat) {
                if let client = connection.client {
                    NavigationStack {
                        ChatView(client: client, path: chatPath)
                    }
                }
            }
            .sheet(isPresented: $newConnection) {
                // The same screen the Terminal tab shows when nothing is
                // connected, reached without leaving the session. Dismissing it
                // returns here, which is what makes ⌘N safe to press by
                // accident.
                NavigationStack { HostsView(pendingLink: nil) }
            }
            .sheet(isPresented: $showShortcuts) {
                NavigationStack { ShortcutEditorView(store: shortcuts) }
            }
            .sheet(isPresented: $showGestures) {
                NavigationStack { GestureEditorView(store: gestures) }
            }
            .sheet(isPresented: $showCommandHistory) {
                if let client = connection.client {
                    NavigationStack {
                        CommandHistoryView(client: client) { command in
                            // Typed, not run: the command lands in the shell's
                            // line editor with the cursor after it, so it can be
                            // read and edited before Return. Sending the newline
                            // would run a command chosen from a list the host
                            // assembled, which is one keystroke away from
                            // running something the user did not read.
                            coordinator.terminal?.sendRaw(Data(command.utf8))
                        }
                    }
                }
            }
            .sheet(isPresented: $showSpeechSettings) {
                NavigationStack { SpeechSettingsView() }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    TranscriptionHistoryView { text in
                        coordinator.terminal?.sendDictatedLine(text)
                    }
                }
                .environment(transcriptionHistory)
            }
            .sheet(isPresented: $showJumpTo) {
                if let client = connection.client {
                    JumpToView(client: client) {}
                }
            }
            .sheet(item: $annotating) { pending in annotator(pending.image) }
            .sheet(isPresented: $showCamera) { CameraPicker(onPick: attachAfterDismissal) }
            .sheet(isPresented: $showPhotoLibrary) { PhotoLibraryPicker(onPick: attachAfterDismissal) }
            // Files is `fileImporter` rather than a picker: it is the
            // system document flow, and the URL it hands back is only valid
            // for the callback — so the bytes are read here, not referenced.
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: [.image]
            ) { result in
                if case .success(let url) = result { attachFile(at: url) }
            }
            .overlay(alignment: .top) { pasteNotice }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if input.chatMode {
                    // Chat mode replaces the bar wholesale rather than adding a
                    // field above it. The window row goes with it: it sends mux
                    // prefix keys into the pane, which is command-mode behaviour
                    // and not what a message field is for.
                    ChatComposerBar(
                        send: { text in
                            coordinator.terminal?.sendComposed(text) ?? false
                        },
                        insert: { text in
                            // Insert without a trailing Return, so the message
                            // sits in the agent's input for the user to review
                            // or finish — `typeText`'s contract exactly.
                            coordinator.terminal?.typeText(text)
                        }
                    )
                } else if InputSettings.showsBar(
                    hideWithHardwareKeyboard: input.hideBarWithHardwareKeyboard,
                    hardwareKeyboard: hardwareKeyboard
                ) {
                    VStack(spacing: 0) {
                        if tabRowApplies, !input.hidesWindowRow { tabRow }
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
                            // Recorded here rather than on the way into the
                            // terminal: this is the only point that sees
                            // dictated text and not typed or pasted text, which
                            // is what keeps a password out of the history.
                            transcriptionHistory.record(text)
                            // With auto-send off the phrase is typed into the
                            // line and left there: the user is asking to read
                            // what was heard before it runs, so submitting it
                            // would be the one thing the setting exists to
                            // prevent.
                            if settings.autoSend {
                                coordinator.terminal?.sendDictatedLine(text)
                            } else {
                                coordinator.terminal?.typeText(text)
                            }
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
                // The chat-mode bar is a `TextField`, and a script cannot type
                // into one or tap its send button — so a run declares that it
                // wants the bar in chat mode and the screenshot shows it. The
                // delivery half is exercised by `CQUT_DEV_COMPOSE`, which calls
                // the same `sendComposed` the button does.
                if ProcessInfo.processInfo.environment["CQUT_DEV_CHAT_MODE"] == "1" {
                    input.chatMode = true
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
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "history" {
                    showHistory = true
                }
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "command-history" {
                    showCommandHistory = true
                }
                // Seeds the history sheet from the outside, so the screen can
                // be checked without a working microphone and a working voice.
                if let seed = ProcessInfo.processInfo.environment["CQUT_DEV_HISTORY"] {
                    for line in seed.split(separator: "|") {
                        transcriptionHistory.record(String(line))
                    }
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
                // The show-keyboard key answers a state a script cannot reach:
                // `dismissKeyboard` resigns the responder, and no environment
                // variable can put the keyboard away. So a run says which items
                // the bar should hold and the bar builds them exactly as the
                // settings screen would; pressing one is still a real tap.
                if let spec = ProcessInfo.processInfo.environment["CQUT_DEV_BAR_ITEMS"], !spec.isEmpty {
                    input.items = spec.split(separator: ",").compactMap { InputSettings.Item(rawValue: String($0)) }
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

    /// Whether the host has a tab row at all.
    ///
    /// The row is offered on every multiplexer the app detects, and that is the
    /// whole reason the view consults `host.mux`: what each button *sends* differs
    /// per multiplexer (see `MuxCommand.selectTab`), and a host with no
    /// multiplexer has nothing for the row to address — showing it there would be
    /// a row of numbers that type digits into whatever program is running.
    private var tabRowApplies: Bool {
        MuxSettings.MuxCommand.selectTab(
            1, mux: host.mux, prefix: mux.prefix(for: host.mux)
        ) != nil
    }

    /// One tap per tab or window, 1–20, above the key bar.
    ///
    /// Above rather than below on purpose: this is the row a thumb reaches
    /// past to get to the keys, and the keys are the ones pressed constantly.
    /// A row that pushed them up the screen would cost more than it saved.
    ///
    /// All twenty are offered because the page lists twenty for each of the three
    /// multiplexers. What a button sends is not uniform, though, and the row does
    /// not pretend otherwise: tmux reads the bare digits up to nine and its command
    /// prompt past that, herdr reads its own prefix, and zellij — which has no
    /// prefix — reads Ctrl-T and the number as a tab-mode binding. That mapping
    /// lives in `MuxCommand.selectTab` so this view cannot drift from it.
    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MuxSettings.MuxCommand.selectableTabs, id: \.self) { index in
                    Button {
                        coordinator.terminal?.selectTab(index, mux: host.mux)
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
        .background(barSurface)
    }

    /// The key bar's background: the system's material, or an opaque surface in
    /// the theme's own colour when the glass is turned off.
    ///
    /// This is the one toolbar surface the setting can honour on every iOS
    /// version, because the bar is a view of ours rather than one the system
    /// draws. See `ToolbarSettings` for why the navigation bars cannot be.
    ///
    /// The two bars are stacked in one `safeAreaInset`, so both must agree —
    /// switching only one leaves a visible seam between two surface treatments
    /// where the user sees a single bar.
    @ViewBuilder
    private var barSurface: some View {
        if toolbar.glassEffect {
            Rectangle().fill(.bar)
        } else {
            themes.current.barSurface
        }
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
        .background(barSurface)
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
        Group {
            ForEach(shortcuts.shortcuts) { shortcut in
                Button {
                    guard let parsed = shortcut.parsed else { return }
                    coordinator.terminal?.send(parsed)
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
                // Disabled rather than hidden: a key that vanishes when locked
                // leaves nothing to tap to get the bar back, and the positions
                // of the remaining keys would shift under a thumb.
                .disabled(coordinator.shortcutLock.isLocked)
            }
            if !shortcuts.shortcuts.isEmpty { shortcutLockKey }
        }
    }

    /// The head of the custom-key group: a tap opens the editor, a double tap
    /// locks the group. See `ShortcutLock`.
    ///
    /// The two gestures are the same pair the Ctrl key already uses — single
    /// tap does the button's own job, double tap arms it — so there is one
    /// gesture to learn rather than two. It is never disabled, because a tap
    /// while locked is how the bar comes back.
    private var shortcutLockKey: some View {
        let locked = coordinator.shortcutLock.isLocked
        return Button {
            // The whole gesture belongs to the lock: unlocking is the lock's
            // business too, so the view only decides what happens when the tap
            // was *not* consumed.
            if coordinator.shortcutLock.tap() { return }
            showShortcuts = true
        } label: {
            Image(systemName: locked ? "lock.fill" : "keyboard")
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(locked ? .orange : nil)
        .accessibilityLabel(locked ? "Unlock custom keys" : "Custom keys")
        .accessibilityHint(locked
            ? "Tap to let the custom keys through again"
            : "Tap to edit the keys; double tap to stop them sending to the terminal")
    }

    /// Puts the session away and goes back to the host list.
    ///
    /// Two things have to be true for this to be the right gesture and not a
    /// data-losing one. The transport is disconnected, so the session is not
    /// left running in the background competing for the one connection the
    /// gateway allows. And it is *not* a sign-out: the tmux/zellij/herdr
    /// session on the host is untouched — this is the "minimize" Moshi
    /// documents, and a persistent mux session is exactly what makes it
    /// non-destructive. `userInitiated` is set first so the disconnect is not
    /// treated as a dropped connection and retried by the backoff.
    private func minimize() {
        coordinator.terminal?.minimize()
        dismiss()
    }

    /// Image paste needs the gateway to carry the bytes to the host, so the
    /// button only appears when a host is connected.
    @ViewBuilder
    private var pasteImageButton: some View {
        if connection.client != nil {
            Button { showAttachSources = true } label: {
                Image(systemName: "photo.badge.plus").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .confirmationDialog(
                "Add attachment",
                isPresented: $showAttachSources,
                titleVisibility: .visible
            ) {
                ForEach(attachmentSources) { source in
                    Button(source.label) { choose(source) }
                }
            }
        }
    }

    /// Which sources to offer right now.
    ///
    /// The decision is `AttachmentSource.available` — a pure function, checked
    /// in `scripts/attachment-check.sh`. The two inputs come from the device:
    /// a camera that may not exist, and a clipboard that may be empty. Offering
    /// a Clipboard row with nothing on the clipboard is a row that opens onto
    /// "No image on the clipboard", which reads as a broken button.
    private var attachmentSources: [AttachmentSource] {
        AttachmentSource.available(
            hasCamera: UIImagePickerController.isSourceTypeAvailable(.camera),
            hasClipboardImage: UIPasteboard.general.hasImages
        )
    }

    private func choose(_ source: AttachmentSource) {
        switch source {
        case .camera: showCamera = true
        case .photoLibrary: showPhotoLibrary = true
        case .files: showFiles = true
        // The clipboard image is already in hand — there is nothing to present,
        // which is why it goes straight to the annotator.
        case .clipboard: attach(UIPasteboard.general.image ?? UIImage())
        }
    }

    /// Accepts an image from any source and opens the annotator on it.
    ///
    /// The dismiss-then-present is the one part of this that can fail silently:
    /// a picker dismissing and a sheet being asked to present in the same turn
    /// of the run loop sometimes drops the second presentation, leaving the tap
    /// apparently ignored. The short beat is the standard workaround, and it is
    /// recorded here rather than left for someone to rediscover — a ready-made
    /// image (the clipboard) skips it, since nothing is dismissing.
    private func attach(_ image: UIImage) {
        guard image.size != .zero else { return }
        annotating = PendingImage(image: image)
    }

    private func attachAfterDismissal(_ image: UIImage) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            attach(image)
        }
    }

    private func attachFile(at url: URL) {
        // The picker's URL is security-scoped and valid only inside this call.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            notice("That file is not an image")
            return
        }
        attach(image)
    }

    private func notice(_ text: String) {
        pastedNotice = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            pastedNotice = nil
        }
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

    /// Opens the list of commands recently run on the host.
    ///
    /// Only offered when there is a host to ask: the history lives on the
    /// machine the shell runs on, and a button that opens an empty sheet on a
    /// direct SSH connection would be a lie about where the list comes from.
    @ViewBuilder
    private var historyButton: some View {
        if connection.client != nil {
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .accessibilityLabel("Command history")
            .accessibilityHint("Recent commands run on the host")
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

    /// Shows or hides the software keyboard.
    ///
    /// The bar sits above the keyboard, so hiding it is how the bar stops
    /// occupying the bottom of the screen without leaving the session. The D-pad
    /// already has this as a corner action; as a bar item it can be a key of its
    /// own, which is where anyone who uses it often will want it.
    private var keyboardButton: some View {
        Button {
            Self.dismissKeyboard()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        // A long press opens Speech settings. The bar has no room for another
        // key and the keyboard button is the one that is about input, so this is
        // where the dictation settings live from inside a session — otherwise
        // reaching them means leaving the terminal you are dictating into.
        .onLongPressGesture(minimumDuration: 0.4) {
            Self.dismissKeyboard()
            showSpeechSettings = true
        }
        .accessibilityLabel("Hide keyboard")
        .accessibilityHint("Long press for dictation settings")
    }

    /// Brings the software keyboard back after it has been hidden.
    ///
    /// `keyboardButton` can only put the keyboard away: nothing else in the
    /// terminal summons it, since a tap on the pane goes to a gesture recogniser
    /// before the responder ever sees it. So the hide key was one-way for the
    /// rest of the session, which is why this is a key of its own rather than
    /// another state of the one above it.
    private var showKeyboardButton: some View {
        Button {
            coordinator.terminal?.showKeyboard()
        } label: {
            Image(systemName: "keyboard").frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .accessibilityLabel("Show keyboard")
    }

    /// Not named `resignFirstResponder`: that collides with `UIResponder`'s own
    /// instance method and the compiler resolves the call inside a `Button`
    /// action to the view's inherited one rather than to this.
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var dictationButton: some View {
        // The button reflects the selected engine's state, which is why this
        // reads through `dictation` rather than owning a `VoiceDictation`: with
        // whisper chosen, listening continues while the phrase is transcribed,
        // and a button that claimed otherwise would invite a second press.
        let listening = dictation?.isListening ?? false
        return Button {
            dictation?.toggle(locale: dictation?.locale ?? .current)
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
        // Press and hold to talk, release to stop — the walkie-talkie gesture
        // Moshi documents. A long press *after* a tap is not how a touchscreen
        // works, so this cannot fire when the tap does: SwiftUI runs the tap
        // only if the hold never reaches its threshold, and the two cannot both
        // complete for one press.
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60) {
            // Released: stop, having started below.
            if dictation?.isListening == true { dictation?.stop() }
        } onPressingChanged: { pressing in
            if pressing {
                if dictation?.isListening == false { dictation?.start(locale: dictation?.locale ?? .current) }
            } else if dictation?.isListening == true {
                dictation?.stop()
            }
        }
    }

    @ViewBuilder
    private func barItem(_ item: InputSettings.Item) -> some View {
        switch item {
        case .control: controlKey
        case .escape: key("Esc", CtrlKey.escape)
        case .tab: key("Tab", CtrlKey.tab)
        case .enter: key("Return", CtrlKey.enter)
        case .backspace: key("⌫", CtrlKey.backspace)
        case .keyboard: keyboardButton
        case .showKeyboard: showKeyboardButton
        case .arrows:
            icon("arrow.up", CtrlKey.upArrow)
            icon("arrow.down", CtrlKey.downArrow)
            icon("arrow.left", CtrlKey.leftArrow)
            icon("arrow.right", CtrlKey.rightArrow)
        case .dpad: dpad
        case .clipboard: icon("doc.on.doc", CtrlKey.clipboard)
        case .pasteImage: pasteImageButton
        case .sessions: sessionsButton
        case .history: historyButton
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
        // A custom corner with nothing typed yet is blank rather than disabled:
        // it is one keystroke away from working, and greying it out would read
        // as the option not having taken.
        let blank = action == .none
            || (action == .custom && input.cornerBytes(slot) == nil)
        return Button {
            switch action {
            case .none: break
            case .hideKeyboard: Self.dismissKeyboard()
            case .delete: coordinator.terminal?.sendDelete()
            case .interrupt: coordinator.terminal?.sendInterrupt()
            case .escape: coordinator.terminal?.sendEscape()
            case .custom:
                if let parsed = input.cornerParsed(slot) {
                    coordinator.terminal?.send(parsed)
                }
            }
        } label: {
            Text(action.cornerLabel)
                .font(.caption2)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .disabled(blank)
        .accessibilityHint(action == .custom ? input.cornerShortcut(slot) ?? "" : "")
    }

    /// The Ctrl key, which has a second job.
    ///
    /// One tap is the sticky modifier it has always been: the next key becomes a
    /// control character. A double tap *locks* it, so a run of keys is one
    /// gesture — which is what makes `^C ^C` or a shell's `^R` search usable
    /// from a phone. The label changes to say which state it is in, because a
    /// modifier that is silently on is the kind of thing that produces
    /// `^[[A` in the wrong pane and a puzzled user.
    private var controlKey: some View {
        let locked = coordinator.controlLocked
        return Button {
            let now = Date()
            let isDoubleTap = now.timeIntervalSince(coordinator.lastControlTap) < 0.4
            coordinator.lastControlTap = now
            if isDoubleTap {
                // A double tap supersedes the single tap that just fired, so the
                // lock state is set outright rather than toggled twice.
                coordinator.setControlLocked(!coordinator.controlLocked)
            } else {
                coordinator.press(.control)
            }
        } label: {
            Text("Ctrl")
                .font(.system(.subheadline, design: .monospaced))
                .frame(minWidth: 44, minHeight: 32)
                .foregroundStyle(locked ? .white : .primary)
        }
        .buttonStyle(.bordered)
        .tint(locked ? .accentColor : nil)
        .accessibilityLabel(locked ? "Ctrl, locked" : "Ctrl")
        .accessibilityHint(locked ? "Double-tap to unlock" : "Double-tap to lock")
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
    case control, escape, tab, enter, backspace, upArrow, downArrow, leftArrow, rightArrow, clipboard
}

/// Owns the UIKit terminal and the SSH session across SwiftUI updates.
@Observable
final class TerminalCoordinator {
    /// Whether the custom keys are letting taps through to the terminal.
    ///
    /// See `customShortcutKeys` on the view: the keys are ordinary buttons, so
    /// a session that mostly types means every fumbled tap on the bar lands a
    /// control sequence in a shell. Holding here rather than in the view so the
    /// bar survives a rebuild — the same reason `lastControlTap` is here.
    @ObservationIgnored var shortcutLock = ShortcutLock()

    var status: CQUTTerminalView.Status = .idle
    /// Live dictation text, shown above the accessory bar while listening.
    var dictationPreview = ""
    @ObservationIgnored weak var terminal: CQUTTerminalView?

    /// When the Ctrl key was last tapped, so a second tap within the window
    /// counts as a double tap. Held here rather than in the view because the
    /// bar is rebuilt on every settings change and would forget it.
    @ObservationIgnored var lastControlTap = Date.distantPast

    /// Whether Ctrl is locked, mirrored from the terminal view so the bar can
    /// render the state without reaching into a UIKit object during a body.
    var controlLocked = false

    func setDictationPreview(_ text: String) { dictationPreview = text }

    /// Locks or releases Ctrl for every following keystroke.
    func setControlLocked(_ locked: Bool) {
        controlLocked = terminal?.setControlLocked(locked) ?? locked
    }

    func press(_ key: CtrlKey) {
        guard let terminal else { return }
        switch key {
        case .control:
            // A single press while locked releases it: the key that was just
            // armed for the next keystroke should count as that keystroke,
            // rather than leaving Ctrl on with no way to see why.
            if controlLocked { setControlLocked(false) } else { terminal.toggleControl() }
        case .escape: terminal.sendEscape()
        case .tab: terminal.sendTab()
        case .enter: terminal.sendEnter()
        case .backspace: terminal.sendBackspace()
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
    /// Whether a pinch zooms the multiplexer's pane instead of resizing text.
    let pinchZoomsPane: Bool
    /// Whether a pinch should go through herdr's socket API instead of a mux
    /// prefix key. Only set where a gateway connection exists.
    var pinchZoomsHerdrPane = false
    /// Asks the host to zoom or restore herdr's focused pane.
    var onPinchZoom: (Bool) -> Void = { _ in }
    /// Whether a host program may read the clipboard. Passed in rather than
    /// read from the environment because a `UIViewRepresentable`'s
    /// `updateUIView` has no environment of its own.
    let allowsClipboardRead: Bool
    /// Where the hardware ⌘-shortcuts go. Passed in because the representable
    /// cannot reach the screen's state to raise a sheet itself.
    var onShowShortcuts: () -> Void = {}
    var onShowSessions: () -> Void = {}
    var onNewConnection: () -> Void = {}
    var onMinimize: () -> Void = {}

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
            startupPreamble: integrations.shellExportLines.joined(separator: "\n"),
            theme: theme,
            font: fonts.uiFont(),
            transport: transport
        )
        view.gestures = gestures
        view.optionIsMeta = input.optionIsMeta
        view.allowsClipboardRead = allowsClipboardRead
        view.muxPrefix = mux.prefix(for: host.mux)
        // The host's own kind, which is what decides whether a multiplexer
        // gesture has anywhere to go. Read from `Host.mux` rather than from the
        // session command string here, because a user's command can change
        // while the host is saved, and this is the same detector the window row
        // and the session picker already trust.
        view.muxKind = host.mux
        view.muxGestures = input.muxGestures
        view.pinchZoomsPane = pinchZoomsPane
        view.pinchZoomsHerdrPane = pinchZoomsHerdrPane
        view.onPinchZoom = onPinchZoom
        view.refreshMuxSweeps()
        view.onStatus = { status in coordinator.status = status }
        // A pinch resizes the terminal and becomes the saved preference, so the
        // next session opens at the size the user settled on.
        view.onFontSizeChange = { size in
            fonts.size = Double(size)
        }
        // The ⌘-shortcuts reach the same sheets the accessory bar's buttons do.
        // Routed through the coordinator rather than to `showX` directly so the
        // hardware path and the tap path cannot drift apart.
        view.onShowShortcuts = onShowShortcuts
        view.onShowSessions = onShowSessions
        view.onNewConnection = onNewConnection
        view.onMinimize = onMinimize
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
        // Chat mode's delivery, which a script cannot reach: the composer is a
        // TextField and `simctl` cannot type into one. This calls the view's own
        // `sendComposed`, so the bracketed-paste wrap is decided by the
        // program's real mode bit and the bytes are the shipped composer's.
        if let message = ProcessInfo.processInfo.environment["CQUT_DEV_COMPOSE"] {
            DebugSeed.sendComposedWhenConnected(view: view, text: message)
        }
        // Fires a tmux jump so the configured prefix is the one on the wire;
        // the host's `cat -v` then shows it as `^B` or `^A`.
        if let index = ProcessInfo.processInfo.environment["CQUT_DEV_JUMP_WINDOW"] {
            DebugSeed.jumpWindowWhenConnected(view: view, index: index)
        }
        // Sends a multiplexer command through the same table the sweeps use,
        // so the bytes a real two-finger swipe produces can be read on the host
        // (with `cat -v`) even though a script cannot perform the swipe.
        if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_MUX_COMMAND"],
           let command = MuxSettings.MuxCommand(rawValue: raw) {
            DebugSeed.fireMuxCommandWhenConnected(view: view, command: command)
        }
        // The tab row's buttons live in a scroll view above the keyboard, so a
        // script cannot tap one. `CQUT_DEV_TAB=<n>` presses the button for
        // tab `n`, and `CQUT_DEV_TAB_MUX` names which multiplexer it should be
        // read as — the mapping differs per multiplexer, so the host under test
        // has to be told which one it is pretending to be.
        if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_TAB"],
           let number = Int(raw) {
            let mux = ProcessInfo.processInfo.environment["CQUT_DEV_TAB_MUX"] ?? "tmux"
            DebugSeed.selectTabWhenConnected(view: view, number: number, mux: mux)
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
        uiView.allowsClipboardRead = allowsClipboardRead
        uiView.muxPrefix = mux.prefix(for: host.mux)
        uiView.muxKind = host.mux
        uiView.muxGestures = input.muxGestures
        uiView.pinchZoomsPane = pinchZoomsPane
        uiView.pinchZoomsHerdrPane = pinchZoomsHerdrPane
        uiView.onPinchZoom = onPinchZoom
        uiView.refreshMuxSweeps()
    }
}

private struct StatusBadge: View {
    let status: CQUTTerminalView.Status
    /// A short downward drag: open the session switcher.
    var onSoftDrag: () -> Void = {}
    /// A long one, or a flick: put the session away and go back to the hosts.
    var onHardDrag: () -> Void = {}

    /// How far the badge must be dragged before it counts. The soft threshold
    /// is about a thumb's travel on a small target; the hard one is far enough
    /// that it cannot be reached by accident while aiming for the soft one.
    private static let softDrag: CGFloat = 24
    private static let hardDrag: CGFloat = 90

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        // The badge is a small target, so the whole row has to be draggable
        // rather than just the dot and the word.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: Self.softDrag)
                .onEnded { value in
                    let dy = value.translation.height
                    // Downward only, and not a diagonal: an upward drag or a
                    // sideways one is someone aiming at something else and
                    // catching the title on the way past.
                    guard dy > 0, abs(value.translation.width) < abs(dy) else { return }
                    // `predictedEndTranslation` is where the finger was heading,
                    // which is what separates a flick from a slow drag to the
                    // same place — a flick down should put the session away even
                    // though it travelled less than the hard threshold.
                    let projected = value.predictedEndTranslation.height
                    if dy >= Self.hardDrag || projected >= Self.hardDrag * 1.6 {
                        onHardDrag()
                    } else if dy >= Self.softDrag {
                        onSoftDrag()
                    }
                }
        )
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