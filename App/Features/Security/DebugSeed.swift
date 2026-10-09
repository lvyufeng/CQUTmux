#if DEBUG
import Foundation

/// Test-only seeding for UI runs: inject a host and an ed25519 seed through the
/// launch environment so a simulator build can be exercised without hand entry.
/// Compiled out of release builds entirely.
enum DebugSeed {
    static func apply(to store: HostStore) {
        let env = ProcessInfo.processInfo.environment
        guard let hostname = env["CQUT_DEV_HOST"] else { return }

        var host = Host()
        host.name = env["CQUT_DEV_NAME"] ?? hostname
        host.hostname = hostname
        host.port = Int(env["CQUT_DEV_PORT"] ?? "22") ?? 22
        host.username = env["CQUT_DEV_USER"] ?? ""
        host.authMethod = .key
        // Selectable so a simulator run can exercise the mosh path, which is
        // otherwise only reachable by hand-editing the form.
        host.transport = TransportKind(rawValue: env["CQUT_DEV_TRANSPORT"] ?? "") ?? .ssh
        host.moshPortRange = env["CQUT_DEV_MOSH_PORT_RANGE"]
        // Empty by default: the harnesses drive a plain shell so a typed
        // command lands on a prompt rather than inside a multiplexer.
        // `CQUT_DEV_SESSION_COMMAND` sets one when the mux itself is what is
        // under test — the window row is only shown for a host whose command
        // says tmux, so that branch cannot be reached otherwise.
        host.sessionCommand = env["CQUT_DEV_SESSION_COMMAND"] ?? ""

        if let jump = env["CQUT_DEV_JUMP"], !jump.isEmpty {
            host.jumpHost = jump
        }

        if let seedB64 = env["CQUT_DEV_KEY_SEED"], let seed = Data(base64Encoded: seedB64) {
            KeychainStore.save(seed, account: host.keySeedAccount)
        }

        if let token = env["CQUT_DEV_GATEWAY_TOKEN"], let data = token.data(using: .utf8) {
            KeychainStore.save(data, account: host.gatewayTokenAccount)
        }

        if let port = env["CQUT_DEV_GATEWAY_PORT"], let value = Int(port) {
            host.gatewayPort = value
        }

        if !store.hosts.contains(where: { $0.hostname == host.hostname && $0.port == host.port }) {
            store.upsert(host)
        }
    }

    /// Types `phrase` into a live session, then reports whether the host echoed
    /// it back.
    ///
    /// This exists because the input half of a transport cannot otherwise be
    /// tested from a script: automating the simulator's keyboard needs
    /// accessibility permissions the test environment does not have. Going
    /// through the terminal view means this takes the same path a keypress does
    /// — delegate callback, then `transport.send` — so a pass is evidence about
    /// the real thing, not a parallel code path built to pass.
    static func typeWhenConnected(view: CQUTTerminalView, phrase: String, attempt: Int = 0) {
        // Poll for the session rather than sleeping a guessed interval: too
        // early and the keystrokes go nowhere, which looks exactly like a broken
        // input path.
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                typeWhenConnected(view: view, phrase: phrase, attempt: attempt + 1)
            }
            return
        }
        // Let the shell settle: the server has sent its prompt, but a login
        // shell may still be printing rc output, which would land on top of a
        // command typed too soon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // `echo TYPED_$((20+4))_OK` rather than the phrase back: the shell
            // has to expand the arithmetic, so the marker in the output proves
            // the host ran the command rather than the terminal printing the
            // characters it was handed.
            view.injectForTesting(phrase + "; echo TYPED_$((20+4))_OK\n")
        }
    }

    /// Fires a gesture once the session is live. A recogniser cannot be
    /// driven from a script, so the view's own handler is called — the same
    /// `send(binding:)` a real swipe reaches, not a parallel path built to
    /// pass.
    static func fireGestureWhenConnected(
        view: CQUTTerminalView?, gesture: TerminalGesture, attempt: Int = 0
    ) {
        guard let view else { return }
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                fireGestureWhenConnected(view: view, gesture: gesture, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            view.fireGestureForTesting(gesture)
        }
    }

    /// Presses a custom shortcut once the session is live, so its bytes go
    /// through `sendRaw` exactly as a tap on the accessory bar would.
    ///
    /// The binding under test is expected to end in a command the host runs;
    /// like the typed test above, the check is that the host's own expansion
    /// comes back, not that the terminal echoed what it was handed.
    static func typeComposedWhenConnected(view: CQUTTerminalView, text: String, attempt: Int = 0) {
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                typeComposedWhenConnected(view: view, text: text, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            view.injectComposedForTesting(text)
        }
    }

    /// Runs a tmux window jump once the session is live. Test-only.
    ///
    /// Goes through the view's own `selectWindow`, so the prefix the user
    /// configured is the one under test — a jump built here would prove nothing
    /// about whether the setting is actually read. Pairs with `cat -v` on the
    /// host, which renders the prefix as `^B` or `^A` and so makes the byte
    /// visible instead of leaving it to a tmux that would just ignore it.
    static func jumpWindowWhenConnected(view: CQUTTerminalView, index: String, attempt: Int = 0) {
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                jumpWindowWhenConnected(view: view, index: index, attempt: attempt + 1)
            }
            return
        }
        // Longer than the typed command's own delay, because the byte under
        // test is meant to be read by a program on the host (`cat -v`) rather
        // than by a shell prompt — arriving first would let the shell eat it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            view.selectWindowForTesting(mux: "tmux", session: "", selector: index)
        }
    }

    static func pressShortcutWhenConnected(
        view: CQUTTerminalView, bytes: [UInt8], attempt: Int = 0
    ) {
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pressShortcutWhenConnected(view: view, bytes: bytes, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            view.sendRaw(Data(bytes))
        }
    }
}
#endif