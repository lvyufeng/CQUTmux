import SwiftTerm
import CQUTTransport
import UIKit

/// A `TerminalView` wired to a `TerminalTransport`. Owns the transport for the
/// lifetime of one session and translates delegate callbacks into I/O.
///
/// `TerminalView` is a UIKit view; the transport pings `onEvent` on the main
/// queue, so every callback below already runs on the main thread.
final class CQUTTerminalView: TerminalView, TerminalViewDelegate, UIGestureRecognizerDelegate {
    enum Status: Equatable {
        case idle, connecting, connected
        case closed(Int?)
        case failed(String)

        var isLive: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    var onStatus: ((Status) -> Void)?
    /// Called when a pinch or a hardware change settles on a new size, so the
    /// user's font preference follows the gesture instead of being lost.
    var onFontSizeChange: ((CGFloat) -> Void)?

    /// Whether a pinch asks the host gateway to zoom herdr's focused pane
    /// instead of resizing the text.
    ///
    /// The gateway route rather than a mux prefix key, because herdr's own
    /// binding is a chord into whatever has focus: it would toggle whichever
    /// pane herdr thinks is focused, which is not necessarily the one the
    /// screen is showing when a jump has not been made. The socket API names
    /// the pane, so the zoom lands where the user is looking.
    var pinchZoomsHerdrPane = false
    /// Asks the host to zoom (`true`) or restore (`false`) the focused pane.
    /// A closure rather than a URL here because the gateway is reached over the
    /// SSH tunnel `HookClient` already owns, and a second connection from the
    /// view would be a second tunnel doing what the first one can.
    var onPinchZoom: ((Bool) -> Void)?
    /// Where a hardware ⌘-shortcut that belongs to the screen rather than to
    /// the terminal is sent. The SwiftUI layer owns the sheets, so the view
    /// cannot open them itself; these mirror the accessory bar's own buttons,
    /// which is what makes ⌘-shortcuts and taps the same feature rather than
    /// two implementations of it.
    var onShowShortcuts: (() -> Void)?
    var onShowSessions: (() -> Void)?
    var onNewConnection: (() -> Void)?
    /// ⌘W. Not "close the window" — there is one window — but Moshi's
    /// minimize: drop the connection and go back to the host list.
    var onMinimize: (() -> Void)?

    private let transport: TerminalTransport
    private let configuration: TransportConfiguration
    private let startupCommand: String?
    /// Sent as a shell line the moment the session is up, ahead of any startup
    /// command. See `IntegrationSettings` for why an export and not the SSH
    /// environment request.
    private let startupPreamble: String?
    private let theme: TerminalTheme
    private var didRunStartup = false
    /// The user's gesture bindings, if any. nil keeps every gesture on its
    /// built-in behaviour, which is what a view built outside the SwiftUI
    /// screen (a preview, a test) gets.
    var gestures: GestureStore?
    /// Send Option+key as ESC + key (Meta) rather than as the accented
    /// character iOS would otherwise compose. Set from `InputSettings` when the
    /// view is built and on every settings change.
    var optionIsMeta = false

    /// Whether a program on the host may read this device's clipboard over
    /// OSC 52. Off unless the user turns it on in Settings → Security; see
    /// `SecuritySettings.allowsClipboardRead` for why it is not the default.
    var allowsClipboardRead = false
    /// The tmux prefix the host is actually configured with. Jump-To and the
    /// keyboard window commands jump by *sending* this key, so it has to be the
    /// one `tmux.conf` binds — see `MuxSettings`, and `selectWindow` for why
    /// getting it wrong fails silently.
    var muxPrefix: MuxSettings.Prefix = .controlB
    /// Which multiplexer the host runs, from `Host.mux`. Nil means we could not
    /// tell, and every multiplexer gesture then falls through to the terminal
    /// rather than sending a keystroke for a program that may not be running —
    /// the failure mode this whole area is most prone to.
    var muxKind: String?
    /// Whether the two-finger swipes drive the multiplexer. See
    /// `InputSettings.muxGestures`.
    var muxGestures = true
    /// Whether scrolling past the end of the buffer dismisses the keyboard. See
    /// `InputSettings.dismissKeyboardOnScrollPastEnd`.
    var dismissKeyboardOnScrollPastEnd = true
    /// Whether a pinch zooms the pane instead of changing the font size. See
    /// `ToolbarSettings.PinchAction`.
    var pinchZoomsPane = false
    /// Font size that pinch zoom scales from, captured when a pinch begins.
    private var baseFontSize: CGFloat = 12

    /// Whether a dropped session should climb back on its own. This is the
    /// roaming story: the phone loses Wi-Fi or sleeps, and the terminal
    /// reattaches to the persistent tmux/zellij session rather than making the
    /// user notice. Mosh does this at the transport layer; over SSH we do it
    /// with backoff plus a foreground nudge.
    var autoReconnect = true
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    /// Set while the user asks to disconnect, so teardown isn't "a drop".
    private var userInitiated = false
    private var status: Status = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    init(
        frame: CGRect,
        configuration: TransportConfiguration,
        startupCommand: String?,
        startupPreamble: String? = nil,
        theme: TerminalTheme = TerminalTheme.named(nil),
        font: UIFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        transport: TerminalTransport = SSHTransport()
    ) {
        self.configuration = configuration
        self.startupCommand = startupCommand
        self.startupPreamble = startupPreamble
        self.theme = theme
        self.transport = transport
        super.init(frame: frame)

        terminalDelegate = self
        self.font = font
        baseFontSize = font.pointSize
        applyTheme(theme)

        // Links are underlined and tappable without a modifier key. The default
        // is `.hover`, which on a touch screen means a link is only clickable
        // once a hover has already highlighted its whole row — reachable with a
        // trackpad and not with a finger. `AppleTerminalView` is explicit that
        // `.always` exists for this: it accepts implicit (regex-detected) links
        // outright, where the other modes require the row to be highlighted
        // first. `requestOpenLink` below does the opening, because on iOS
        // SwiftTerm hands the URL to the app rather than opening it — which is
        // also why nothing happens without that method.
        linkReporting = .implicit
        linkHighlightMode = .always

        // Moshi's "scroll past the bottom dismisses the keyboard". This is
        // UIKit's own mechanism for exactly that, and the reason it is set here
        // rather than hand-rolled: the terminal's scroll geometry is managed
        // inside SwiftTerm, and a second opinion about where the bottom is
        // would fight it. `.interactive` releases the keyboard as the drag
        // passes the end of the content, which is the gesture Moshi describes.
        // It is now conditional — see `InputSettings.dismissKeyboardOnScrollPastEnd`
        // for the program that has no scrollback to pass the end of, where
        // every drag would otherwise reach it and the keyboard would never
        // stay put.
        applyKeyboardDismissMode()

        installGestures()

        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Applies a theme to a view that is already built.
    ///
    /// Separate from the initialiser because the cursor colour cannot be set
    /// until SwiftTerm has created its caret subview, and because the user can
    /// change theme while a session is open — the terminal should follow rather
    /// than keep the palette it opened with.
    func applyTheme(_ theme: TerminalTheme) {
        theme.apply(to: self)
        // Written through the property, so SwiftTerm's own `cursorColorIsDefault`
        // flag is cleared and a program's later OSC 12 cursor-colour request is
        // still honoured over ours — the theme is a default, not an override.
        caretColor = theme.cursorColor.uiColor
    }

    /// Applies the user's cursor shape. Called once the terminal exists, and
    /// again whenever the setting changes, because the caret is drawn by a
    /// subview that only reads the style when it is told to.
    func applyCursor(_ settings: CursorSettings) {
        settings.apply(to: self)
    }

    /// Applies the scroll-to-dismiss preference. Called when the view is built
    /// and again whenever the setting changes, so a flip lands on the next
    /// drag rather than on the next connection.
    ///
    /// `.interactive` is the scroll-past-the-end gesture; `.none` leaves the
    /// keyboard alone, for a program with no scrollback where the end is
    /// reached by every drag.
    func applyKeyboardDismissMode() {
        keyboardDismissMode = dismissKeyboardOnScrollPastEnd ? .interactive : .none
    }

    deinit {
        retryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        transport.disconnect()
    }

    // MARK: - Gestures

    private lazy var pinch: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        return gesture
    }()

    private func installGestures() {
        addGestureRecognizer(pinch)

        // Each recogniser carries its gesture in `accessibilityValue`, so the
        // handler can look up whatever the user bound it to. SwiftTerm draws
        // the double tap itself (its `TerminalView` is where the recogniser
        // would otherwise come from), which is why ours replaces it here.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.accessibilityValue = TerminalGesture.doubleTap.rawValue
        addGestureRecognizer(doubleTap)

        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.accessibilityValue = TerminalGesture.tripleTap.rawValue
        addGestureRecognizer(tripleTap)
        // The double tap has to wait: the first two taps of a triple tap are
        // otherwise claimed by it, and the triple tap never fires.
        doubleTap.require(toFail: tripleTap)

        // Moshi's terminal gestures use a three-finger horizontal swipe to walk
        // tmux windows; Ctrl-b n / Ctrl-b p by default, bindable like the rest.
        for (direction, gesture) in [(UISwipeGestureRecognizer.Direction.left, TerminalGesture.swipeLeft),
                                     (.right, .swipeRight)] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.accessibilityValue = gesture.rawValue
            addGestureRecognizer(swipe)
        }

        addGestureRecognizer(wheel)
        // SwiftTerm turns one-finger drags into mouse *drag* events, but nothing
        // it installs ever sends a mouse *wheel* — so a program that only reads
        // scroll wheel input, which is most of them (`less`, `htop`, Claude
        // Code's own transcript view), cannot be scrolled from here at all. The
        // two-finger pan above is that missing event, and it and the drag
        // recogniser must not both fire for one gesture.
        wheel.require(toFail: pinch)

        // The multiplexer sweeps. Two fingers, and they only claim the gesture
        // when the host's multiplexer has a binding for that direction — see
        // `muxCommand(for:)`. `wheel` is made to wait for them, so on a host
        // where they do fire a two-finger drag switches panes rather than also
        // scrolling, and on one where they do not, the wheel is what answers.
        // The order is the opposite of what it looks like: a recogniser that
        // fails lets the one waiting on it proceed, so this says "the wheel
        // only scrolls if the sweep declined to move".
        wheel.require(toFail: paneSweep)
        wheel.require(toFail: tabSweep)
        paneSweep.delegate = self
        tabSweep.delegate = self
        refreshMuxSweeps()
    }

    /// A two-finger drag that drives the multiplexer: horizontal switches pane,
    /// vertical switches tab (or opens herdr's workspace navigator).
    ///
    /// Two separate recognisers rather than one, because they wait on different
    /// things and because a diagonal drag has to resolve to the axis the user
    /// meant — `velocity(in:)` at `.ended` is what decides, and a recogniser
    /// that had already locked to one axis could not change its mind.
    private lazy var paneSweep: UISweepGesture = {
        let gesture = UISweepGesture(target: self, action: #selector(handleMuxSweep(_:)))
        gesture.requiredTouches = 2
        gesture.axis = .horizontal
        return gesture
    }()

    private lazy var tabSweep: UISweepGesture = {
        let gesture = UISweepGesture(target: self, action: #selector(handleMuxSweep(_:)))
        gesture.requiredTouches = 2
        gesture.axis = .vertical
        return gesture
    }()

    /// Whether either sweep has a command it could send right now.
    ///
    /// This is the whole gate, and it is consulted before a gesture starts
    /// rather than when one ends — see `UISweepGesture.isAvailable`. A plain
    /// shell has no multiplexer, so nothing is claimed and the two-finger drag
    /// still reaches the scrollback.
    func refreshMuxSweeps() {
        paneSweep.isAvailable = muxGestures && MuxSettings.MuxCommand.matching(
            horizontal: .next, vertical: nil, mux: muxKind
        ) != nil
        tabSweep.isAvailable = muxGestures && MuxSettings.MuxCommand.matching(
            horizontal: nil, vertical: .next, mux: muxKind
        ) != nil
    }

    /// The command a sweep has resolved to. Called only after the gesture has
    /// ended in `.ended`, which is what `isAvailable` and the travel threshold
    /// together guarantee has a command behind it.
    func muxCommand(for sweep: UISweepGesture) -> MuxSettings.MuxCommand? {
        switch sweep.direction {
        case .positive:
            return MuxSettings.MuxCommand.matching(
                horizontal: sweep.axis == .horizontal ? .next : nil,
                vertical: sweep.axis == .vertical ? .next : nil,
                mux: muxKind
            )
        case .negative:
            return MuxSettings.MuxCommand.matching(
                horizontal: sweep.axis == .horizontal ? .previous : nil,
                vertical: sweep.axis == .vertical ? .previous : nil,
                mux: muxKind
            )
        case .none:
            return nil
        }
    }

    @objc private func handleMuxSweep(_ gesture: UISweepGesture) {
        guard gesture.state == .ended, let command = muxCommand(for: gesture) else { return }
        guard let bytes = command.bytes(prefix: muxPrefix, mux: muxKind) else { return }
        write(Data(bytes))
    }

    /// Two-finger vertical drag → mouse wheel, when the program asked for mouse
    /// reporting. Moshi documents this mapping; without it the gesture falls
    /// through to ordinary scrollback, which is the right thing when the
    /// program never asked for the mouse.
    private lazy var wheel: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        gesture.minimumNumberOfTouches = 2
        gesture.maximumNumberOfTouches = 2
        gesture.delegate = self
        return gesture
    }()

    /// Accumulated drag, in points. A wheel notch is sent per cell of travel,
    /// so a slow drag sends nothing and a long one sends several — the same
    /// feel as a trackpad.
    private var wheelTravel: CGFloat = 0

    /// The two-finger pan only exists while the program has asked for mouse
    /// reporting. Letting it recognise otherwise would swallow the two-finger
    /// scroll that reaches the terminal's own scrollback, which is what a user
    /// expects when the program is not listening for a mouse.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === wheel { return getTerminal().mouseMode != .off }
        return true
    }

    /// SwiftTerm installs its own one-finger drag-to-mouse pan when a program
    /// turns mouse reporting on, and both pans would claim a two-finger drag.
    /// `super` runs first so the recogniser exists to be constrained: the drag
    /// is held to a single touch, which leaves every two-finger drag to the
    /// wheel above.
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        for recogniser in gestureRecognizers ?? [] where
            recogniser is UIPanGestureRecognizer && recogniser !== wheel && recogniser !== pinch {
            (recogniser as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
        }
    }

    @objc private func handleWheel(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            wheelTravel = 0
        case .changed:
            wheelTravel += gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            let pitch = max(cellSize.height, 1)
            while abs(wheelTravel) >= pitch {
                // Up is wheel-up: the wheel's own axes point the opposite way
                // to the drag that produces them.
                sendWheel(up: wheelTravel > 0, at: gesture.location(in: self))
                wheelTravel -= wheelTravel > 0 ? pitch : -pitch
            }
        case .ended, .cancelled, .failed:
            wheelTravel = 0
        default:
            break
        }
    }

    /// One cell, in points.
    ///
    /// `cellDimension` is internal to SwiftTerm, so this goes through the
    /// public `cellSizeInPixels` and divides by the display scale. The terminal
    /// grid is laid out in points, and the row width is what a wheel notch is
    /// measured against.
    private var cellSize: CGSize {
        guard let pixels = cellSizeInPixels(source: getTerminal()) else {
            return CGSize(width: 8, height: 16)
        }
        let scale = max(traitCollection.displayScale, 1)
        return CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
    }

    /// One wheel notch at `point`.
    ///
    /// The row comes from SwiftTerm's own `accessibilityLineNumber`, which is
    /// the view's public point-to-row conversion; the column is not, so it is
    /// derived from the cell width. A wheel event carries the pointer position
    /// because the protocol has nowhere else to put it — programs use it to
    /// decide which pane is being scrolled.
    private func sendWheel(up: Bool, at point: CGPoint) {
        let row = accessibilityLineNumber(for: point)
        let column = Int(floor(max(point.x, 0) / max(cellSize.width, 1)))
        // Cb is 64 for wheel-up and 65 for wheel-down; SwiftTerm's `sendEvent`
        // adds the 32 for the button bits itself.
        getTerminal().sendEvent(buttonFlags: up ? 64 : 65, x: column, y: row)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // Zooming a pane is a single toggle, not a continuous scale, so it is
        // sent once per gesture rather than per frame the way the font is.
        // Anything else would spray the key at the mux and leave the pane
        // flickering between states.
        //
        // The gesture's direction picks the mode: pinching out full-screens the
        // pane and pinching back restores the layout. A bare toggle would make
        // the same gesture mean different things on alternate pinches, which is
        // the one thing a gesture cannot be.
        if pinchZoomsHerdrPane, gesture.state == .ended {
            onPinchZoom?(gesture.scale > 1)
            return
        }
        if pinchZoomsPane, MuxSettings.MuxCommand.zoomPane.isAvailable(on: muxKind) {
            if gesture.state == .ended,
               let bytes = MuxSettings.MuxCommand.zoomPane.bytes(prefix: muxPrefix, mux: muxKind) {
                write(Data(bytes))
            }
            return
        }
        switch gesture.state {
        case .changed:
            let size = min(
                max(CGFloat(TerminalFontStore.sizeRange.lowerBound), baseFontSize * gesture.scale),
                CGFloat(TerminalFontStore.sizeRange.upperBound)
            )
            font = font.withSize(size)
        case .ended, .cancelled, .failed:
            baseFontSize = font.pointSize
            onFontSizeChange?(font.pointSize)
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let raw = gesture.accessibilityValue,
              let gestureKind = TerminalGesture(rawValue: raw) else { return }
        send(binding: gestureKind)
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard let raw = gesture.accessibilityValue,
              let gestureKind = TerminalGesture(rawValue: raw) else { return }
        send(binding: gestureKind)
    }

    /// Sends whatever the gesture is bound to, falling back to its built-in
    /// meaning. The bytes come from `GestureStore`, so a gesture and a key on
    /// the accessory bar that share a binding also share an implementation.
    private func send(binding gesture: TerminalGesture) {
        guard let bytes = gestures?.bytes(for: gesture), !bytes.isEmpty else { return }
        write(Data(bytes))
    }

    // MARK: - Session control

    func connect() {
        guard case .idle = status else { return }
        userInitiated = false
        status = .connecting
        let terminal = getTerminal()
        transport.connect(configuration, cols: max(terminal.cols, 80), rows: max(terminal.rows, 24))
        _ = becomeFirstResponder()
    }

    /// Puts the software keyboard back after the bar's hide button took it away.
    ///
    /// Separate from `connect()`'s `becomeFirstResponder` because this one has to
    /// work on a view that is already live: calling `becomeFirstResponder` alone
    /// would be a no-op there, since this view is *already* the first responder —
    /// the keyboard is hidden because the user resigned it system-wide, not
    /// because focus moved. `reloadInputViews` is what makes the system re-show
    /// the keyboard for a responder that is still focused.
    func showKeyboard() {
        if isFirstResponder {
            reloadInputViews()
        } else {
            _ = becomeFirstResponder()
        }
    }

    /// Manual retry from the toolbar: clears any pending backoff and starts
    /// immediately.
    func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        transport.disconnect()
        didRunStartup = false
        attempt = 0
        status = .idle
        connect()
    }

    func disconnect() {
        userInitiated = true
        retryTask?.cancel()
        retryTask = nil
        transport.disconnect()
    }

    /// Ends this client without disturbing the session on the host.
    ///
    /// The same teardown as `disconnect` — the difference is what the caller
    /// does next, which is pop back to the host list. The host's tmux/zellij/
    /// herdr session keeps running, which is the whole reason minimizing is
    /// safe to offer as a gesture rather than a menu item with a warning.
    func minimize() { disconnect() }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            status = .connected
            attempt = 0
            if !didRunStartup {
                didRunStartup = true
                // Preamble first: the startup command may itself branch on a
                // variable the preamble sets, and a line that would only take
                // effect for the *next* command would be a trap.
                var lines: [String] = []
                if let startupPreamble, !startupPreamble.isEmpty { lines.append(startupPreamble) }
                if let startupCommand, !startupCommand.isEmpty { lines.append(startupCommand) }
                if !lines.isEmpty {
                    write(Data((lines.joined(separator: "\n") + "\n").utf8))
                }
            }
        case .output(let data):
            feed(byteArray: ArraySlice(data))
        case .closed(let code):
            status = .closed(code)
            scheduleReconnect(reason: "connection closed")
        case .failed(let message):
            status = .failed(message)
            feed(text: "\r\n\u{1b}[31m[connection failed] \(message)\u{1b}[0m\r\n")
            scheduleReconnect(reason: message)
        }
    }

    // MARK: - Reconnection

    /// Exponential backoff capped at 30s. The first retries come fast so a
    /// brief Wi-Fi blip is a blink; later ones slow down so a genuinely gone
    /// host doesn't hammer the radio.
    private func scheduleReconnect(reason: String) {
        guard autoReconnect, !userInitiated else { return }
        // A transport that recovers on its own (mosh) must not be torn down and
        // restarted: the stall it is recovering from would become a lost
        // session, which is exactly what mosh exists to avoid.
        guard !transport.handlesReconnect else { return }
        retryTask?.cancel()
        let delay = min(30, pow(2, Double(attempt)))
        attempt += 1
        retryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.feed(text: "\r\n\u{1b}[33m[reconnecting · attempt \(self.attempt)]\u{1b}[0m\r\n")
            self.didRunStartup = false
            self.status = .idle
            self.connect()
        }
    }

    /// Coming back to the foreground after a suspend is the common case where
    /// the SSH socket has already been torn down, so kick a retry right away
    /// instead of waiting for the backoff timer.
    @objc private func appDidBecomeActive() {
        guard autoReconnect, !userInitiated else { return }
        switch status {
        case .connected, .connecting:
            return
        case .closed, .failed, .idle:
            attempt = 0
            scheduleReconnect(reason: "foreground")
        }
    }

    // MARK: - Hardware keyboard

    /// Shortcuts for a physical keyboard, matching the set Moshi documents.
    /// SwiftTerm has no hardware-key chrome of its own, so these are declared
    /// here and dispatched to the same helpers the accessory bar uses.
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(hardwareShowShortcuts),
                         discoverabilityTitle: "Show shortcuts"),
            UIKeyCommand(input: "o", modifierFlags: .command, action: #selector(hardwareShowSessions),
                         discoverabilityTitle: "Session switcher"),
            UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(hardwareNewConnection),
                         discoverabilityTitle: "New connection"),
            UIKeyCommand(input: "w", modifierFlags: .command, action: #selector(hardwareMinimize),
                         discoverabilityTitle: "Minimize session"),
            // Clear screen moves to ⌘L, which is where every terminal puts it
            // and where a user's fingers already go. It previously sat on ⌘K,
            // which Moshi documents for opening the shortcut list.
            UIKeyCommand(input: "l", modifierFlags: .command, action: #selector(hardwareClear),
                         discoverabilityTitle: "Clear screen"),
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(hardwareReconnect),
                         discoverabilityTitle: "Reconnect"),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(hardwarePaste),
                         discoverabilityTitle: "Paste"),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(hardwarePrevWindow),
                         discoverabilityTitle: "Previous window"),
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(hardwareNextWindow),
                         discoverabilityTitle: "Next window"),
        ]
        // ⌘1…⌘9 jump to a tmux window by index.
        for index in 1...9 {
            commands.append(
                UIKeyCommand(input: String(index), modifierFlags: .command,
                             action: #selector(hardwareWindow(_:)),
                             discoverabilityTitle: "Window \(index)")
            )
        }
        return (super.keyCommands ?? []) + commands
    }

    /// Ctrl-L clears the screen without touching the running program's state.
    @objc private func hardwareClear() { write(Data([0x0C])) }
    @objc private func hardwareShowShortcuts() { onShowShortcuts?() }
    @objc private func hardwareShowSessions() { onShowSessions?() }
    @objc private func hardwareNewConnection() { onNewConnection?() }
    @objc private func hardwareMinimize() { onMinimize?() }
    @objc private func hardwareReconnect() { reconnect() }
    @objc private func hardwarePaste() { pasteFromClipboard() }

    @objc private func hardwarePrevWindow() {
        write(Data(muxPrefix.bytes)); write(Data([0x70])) // prefix, then p
    }

    @objc private func hardwareNextWindow() {
        write(Data(muxPrefix.bytes)); write(Data([0x6E])) // prefix, then n
    }

    @objc private func hardwareWindow(_ sender: UIKeyCommand) {
        guard let input = sender.input, let index = Int(input) else { return }
        selectWindow(mux: "tmux", session: "", selector: String(index))
    }

    // MARK: - Key injection (used by the accessory bar)

    /// Ctrl is a sticky modifier SwiftTerm already understands: toggling it
    /// turns the next key the user types into its control character.
    func toggleControl() { controlModifier.toggle() }

    /// Whether Ctrl is being held down for every key rather than for the next
    /// one.
    ///
    /// A double-tap on the Ctrl key sets this. It is done by re-arming
    /// SwiftTerm's own `controlModifier` after each keystroke rather than by
    /// translating keys ourselves: SwiftTerm clears the flag the moment it
    /// sends data, and its clearing is also what tells its accessory view to
    /// redraw. Fighting that would mean a second, divergent path for turning a
    /// key into a control character.
    private(set) var isControlLocked = false

    /// Locks or releases Ctrl. Returns the state after the change, so the bar
    /// can label itself without reading back.
    @discardableResult
    func setControlLocked(_ locked: Bool) -> Bool {
        isControlLocked = locked
        controlModifier = locked
        return locked
    }

    /// Re-arms the lock after a keystroke, if it is on.
    ///
    /// Called from the same place `write` reaches the terminal, so a key that
    /// goes through any path — the bar, a hardware keyboard, a pasted string —
    /// stays under the lock. Called unconditionally: checking `isControlLocked`
    /// at every call site is how the lock would come to apply to some keys and
    /// not others, which is worse than not having it.
    func rearmControlLockIfNeeded() {
        guard isControlLocked else { return }
        controlModifier = true
    }

    func sendEscape() { write(Data([0x1B])) }

    func sendTab() { write(Data([0x09])) }

    /// Return, as the Return key sends it. A bar without this is missing the
    /// one key a phone keyboard cannot reach without dismissing and retargeting
    /// it, which is the whole reason the bar exists.
    func sendEnter() { write(Data([0x0D])) }

    /// Backspace sends BS (0x08). Distinct from `sendDelete`: a terminal's
    /// "Delete" key is DEL (0x7F) — forward delete in the shell's own model —
    /// while Backspace is the backward-delete most people mean. Sending DEL for
    /// both would make one of the two buttons a lie.
    func sendBackspace() { write(Data([0x08])) }

    /// Delete sends DEL (0x7F), not Backspace (0x08). A terminal's "Delete"
    /// key is DEL — that is what the hardware key sends and what readline and
    /// every TUI expect for backward-delete-char. 0x08 is Ctrl-H.
    func sendDelete() { write(Data([0x7F])) }

    /// Ctrl-C. Named for what it does to a running process rather than for the
    /// key, because that is the reason it has a button at all.
    func sendInterrupt() { write(Data([0x03])) }

    func sendArrow(up: Bool, down: Bool, left: Bool, right: Bool) {
        let final: Character = up ? "A" : down ? "B" : right ? "C" : "D"
        write(Data("\u{1B}[\(final)".utf8))
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else { return }
        write(Data(text.utf8))
    }

    /// Sends a composed message to the session as one piece.
    ///
    /// The difference from `typeText`/`sendDictatedLine` is the whole point of
    /// chat mode: the text is handed to the program in a single write, wrapped
    /// in bracketed-paste markers when the program has asked for them, so a
    /// full-screen TUI receives it as text to insert rather than as keys to
    /// interpret. `getTerminal().bracketedPasteMode` is the program's own
    /// answer to "wrap it or not" — the same bit SwiftTerm reads for a real
    /// paste — so the markers and their absence cannot drift from what the
    /// other end expects.
    ///
    /// Returns whether anything was sent, so a caller can clear its field only
    /// on success.
    @discardableResult
    func sendComposed(_ text: String) -> Bool {
        guard let data = ChatComposer.payload(
            for: text, bracketed: getTerminal().bracketedPasteMode
        ) else { return false }
        write(data)
        return true
    }

    /// Sends a dictated phrase followed by Return, so the shell runs it.
    func sendDictatedLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write(Data((trimmed + "\n").utf8))
    }

    /// Types text into the session without a trailing newline, so the user can
    /// finish (or edit) the line before submitting. Used after an image paste
    /// to drop the uploaded path into the agent's prompt.
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        write(Data(text.utf8))
    }

    /// Walks the session to a directory.
    ///
    /// Not routed through `attachSession`: a folder is not a multiplexer
    /// session, so this types a `cd` at the shell rather than an attach
    /// command. Quoted single-quoted with the standard `'\''` escape, because
    /// a path is arbitrary text and one containing a space or a quote would
    /// otherwise split into arguments — or run a second command — in the pane.
    func attachSessionDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write(Data("cd \(Self.shellQuoted(trimmed))\n".utf8))
    }

    /// A path as one safely-quoted shell word.
    ///
    /// The single-quote escape is the shape every POSIX shell understands: end
    /// the quote, emit an escaped quote, reopen. Double quotes would leave
    /// `$`, backticks and backslashes live, so this is the one to use for text
    /// that came from a log file rather than from a person.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Switches to a session on whichever multiplexer owns it. tmux prefers
    /// `switch-client` when we are already inside a client and `attach`
    /// otherwise; zellij and herdr both re-attach by name.
    func attachSession(mux: String, name: String) {
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch mux {
        case "zellij":
            write(Data("zellij attach \(quoted)\n".utf8))
        case "herdr":
            // `herdr --session` launches or attaches to the named persistent
            // session; the bare form would attach to the default one and land
            // the user in the wrong place.
            write(Data("herdr --session \(quoted)\n".utf8))
        default:
            write(Data("tmux switch-client -t \(quoted) 2>/dev/null || tmux attach -t \(quoted)\n".utf8))
        }
    }

    /// Jumps to a window/tab in the attached client.
    ///
    /// `selector` is how the owning mux addresses the window, and it is not a
    /// number for every mux: tmux and zellij use an index, herdr addresses a
    /// tab by id (`w1:t2`). The picker passes back whatever it was given, so
    /// this never has to reconstruct an id from a position.
    ///
    /// tmux jumps by sending the prefix key — so the command is interpreted by
    /// tmux rather than typed into a pane that may be busy running an agent —
    /// falling back to the command prompt past index 9. zellij has no prefix
    /// port; it gets a `go-to-tab` action instead.
    /// The prefix comes from the view's own `muxPrefix`, set from the setting,
    /// rather than from a parameter: a caller that could pass a prefix could
    /// pass the wrong one, and this is exactly the code path where that failure
    /// is silent. Reading it here means `MuxSettings` has one consumer.
    /// Jumps to tab or window `number` — what the quick-access row sends.
    ///
    /// Deliberately not routed through `selectWindow`: that method predates the
    /// row offering more than nine and takes a *selector string*, which is the
    /// shape the session picker needs. The row knows a number, and the mapping
    /// from a number to bytes is per multiplexer, so it lives in
    /// `MuxCommand.selectTab` where it can be checked against the published
    /// behaviour without a simulator.
    func selectTab(_ number: Int, mux: String?) {
        guard let bytes = MuxSettings.MuxCommand.selectTab(number, mux: mux, prefix: muxPrefix) else {
            return
        }
        write(Data(bytes))
    }

    func selectWindow(mux: String, session: String, selector: String) {
        switch mux {
        case "zellij":
            guard let index = Int(selector) else { return }
            write(Data("zellij -s \(session) action go-to-tab \(index + 1)\n".utf8))
        case "herdr":
            guard !selector.isEmpty else { return }
            write(Data("herdr tab focus \(selector)\n".utf8))
        default:
            guard let index = Int(selector) else { return }
            // The user's prefix, not ours: this keystroke is tmux's to read.
            write(Data(muxPrefix.bytes))
            if (0...9).contains(index) {
                write(Data(String(index).utf8))
            } else {
                write(Data(":select-window -t \(index)\n".utf8))
            }
        }
    }

    /// Writes bytes the app composed itself rather than bytes the user typed —
    /// a custom shortcut, whose whole point is that the app already knows the
    /// exact sequence the terminal should receive.
    func sendRaw(_ data: Data) {
        guard !data.isEmpty else { return }
        write(data)
    }

    /// Sends a parsed shortcut, pacing its steps apart.
    ///
    /// A multi-step shortcut is several keystrokes — `C-b, T` is the tmux
    /// prefix and then a letter — and the remote only acts on the second once
    /// it has processed the first. Written as one blob both bytes land in the
    /// same read and the chord works only by luck. A single step is still one
    /// write, so nothing about an ordinary key changes.
    ///
    /// Pacing runs on the main actor as one task, so a second shortcut or a
    /// keystroke cannot wedge its bytes between the steps of the first: the
    /// interleaved order is the failure that no byte-level check would catch.
    func send(_ parsed: ShortcutGrammar.Parsed) {
        guard parsed.needsPacing else {
            sendRaw(Data(parsed.bytes))
            return
        }
        let schedule = parsed.schedule
        Task { @MainActor [weak self] in
            for (index, chunk) in schedule.enumerated() {
                if index > 0, chunk.after > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(chunk.after * 1_000_000_000))
                }
                guard let self else { return }
                self.sendRaw(Data(chunk.bytes))
            }
        }
    }

    private func write(_ data: Data) {
        transport.send(data)
        rearmControlLockIfNeeded()
    }

    /// A key from a hardware keyboard or the software one, which SwiftTerm
    /// routes through here rather than through our own `write`. Re-arming after
    /// the base call — not before — is what makes the lock hold: SwiftTerm
    /// clears `controlModifier` while handling the text, so setting it
    /// beforehand would be undone by the very keystroke it is meant to affect.
    override func insertText(_ text: String) {
        super.insertText(text)
        rearmControlLockIfNeeded()
    }

    #if DEBUG
    /// Whether the session is up right now. Test-only.
    var isLiveForTesting: Bool { status.isLive }

    /// Sends a multiplexer command exactly as the sweep's handler does, without
    /// needing a two-finger drag — which a script cannot perform. Test-only.
    ///
    /// Goes through `muxCommand(for:)`-adjacent machinery rather than building
    /// the bytes here, so what a script exercises is the same table and the same
    /// gate a real gesture reaches. An unavailable command sends nothing, which
    /// is the behaviour under test.
    func fireMuxCommandForTesting(_ command: MuxSettings.MuxCommand) {
        guard status.isLive, muxGestures else { return }
        guard let bytes = command.bytes(prefix: muxPrefix, mux: muxKind) else { return }
        write(Data(bytes))
    }

    /// Runs a gesture's binding exactly as the recogniser's handler does.
    /// Test-only; see `DebugSeed.fireGestureWhenConnected`.
    func fireGestureForTesting(_ gesture: TerminalGesture) {
        guard status.isLive else { return }
        send(binding: gesture)
    }

    /// Types into the live session exactly as the keyboard does. Test-only;
    /// see `DebugSeed.typeWhenConnected`.
    ///
    /// Goes through the delegate rather than `write`, because "exactly as the
    /// keyboard does" includes the Option-as-Meta rewrite — the keyboard hands
    /// the terminal composed characters and the delegate is where they are
    /// turned back into escape sequences. Calling `write` here would skip that
    /// and make the Meta path untestable from a script.
    func injectForTesting(_ text: String) {
        guard status.isLive else { return }
        send(source: self, data: ArraySlice(Data(text.utf8)))
    }

    /// Types a string one character per delegate call, which is the shape the
    /// keyboard actually delivers in. Test-only.
    ///
    /// The distinction is not cosmetic: `optionMeta` deliberately refuses to
    /// rewrite a string that mixes an accented character with ASCII, because
    /// that is what a paste looks like, and rewriting half of a paste would
    /// corrupt it. A whole phrase in one call therefore exercises the paste
    /// branch and can never exercise the Meta one. One keystroke at a time is
    /// both the real shape and the only shape the rewrite applies to.
    func injectComposedForTesting(_ text: String) {
        guard status.isLive else { return }
        for character in text {
            send(source: self, data: ArraySlice(Data(String(character).utf8)))
        }
    }

    /// Runs a window jump with the view's own configured prefix. Test-only;
    /// see `DebugSeed.jumpWindowWhenConnected`.
    func selectWindowForTesting(mux: String, session: String, selector: String) {
        guard status.isLive else { return }
        selectWindow(mux: mux, session: session, selector: selector)
    }

    /// Presses a tab-row button with the view's own configured prefix.
    /// Test-only; see `DebugSeed.selectTabWhenConnected`.
    func selectTabForTesting(_ number: Int, mux: String) {
        guard status.isLive else { return }
        selectTab(number, mux: mux)
    }
    #endif

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        transport.send(InputSettings.optionMeta(Data(data), enabled: optionIsMeta))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport.resize(cols: newCols, rows: newRows)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    /// OSC 52 read. Denied unless the user has allowed it, because the request
    /// comes from the remote side with no gesture here — see
    /// `SecuritySettings.allowsClipboardRead`. Denying returns nil, which
    /// SwiftTerm reports to the remote as "not permitted" rather than as an
    /// empty clipboard, so a program can tell the difference.
    func clipboardRead(source: TerminalView) -> Data? {
        guard allowsClipboardRead,
              let text = UIPasteboard.general.string
        else { return nil }
        return Data(text.utf8)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func bell(source: TerminalView) {}

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    /// Opens a tapped link, but only if it is a web URL.
    ///
    /// The text on screen comes from whatever program is running on the far
    /// end, and SwiftTerm will hand over anything that looks like a link —
    /// including OSC 8 payloads, which the protocol allows to carry arbitrary
    /// key/value metadata rather than a URL. Passing that straight to
    /// `UIApplication.open` would let a remote program launch other apps on the
    /// phone through custom schemes; the tab's purpose here is to be read, so
    /// http and https are the whole of what opens.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        UIApplication.shared.open(url)
    }
}