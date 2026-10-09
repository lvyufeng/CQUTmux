#if DEBUG
import Foundation
import CQUTTransport

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

        // An encrypted key, stored the way the import path stores one: the PEM
        // itself, with the passphrase in a second Keychain entry. This is the
        // only way to reach the password-protected path from a simulator run,
        // since the file picker needs a document on the device. Both halves are
        // supplied so the run can exercise "passphrase already remembered"; set
        // no passphrase to exercise the prompt instead.
        if let pem = env["CQUT_DEV_KEY_PEM"], !pem.isEmpty {
            KeychainStore.save(Data(pem.utf8), account: host.keySeedAccount)
            if let passphrase = env["CQUT_DEV_KEY_PASSPHRASE"], !passphrase.isEmpty {
                KeychainStore.save(Data(passphrase.utf8), account: host.keyPassphraseAccount)
            } else {
                KeychainStore.delete(account: host.keyPassphraseAccount)
            }
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

    /// Sends a message the way chat mode does, once the session is live.
    /// Test-only.
    ///
    /// Goes through `sendComposed`, so the bracketed-paste decision is the
    /// program's own `bracketedPasteMode` and the bytes are the shipped
    /// `ChatComposer`'s — a script cannot type into a `TextField`, and a
    /// payload assembled here would test the harness instead of the feature.
    static func sendComposedWhenConnected(view: CQUTTerminalView, text: String, attempt: Int = 0) {
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sendComposedWhenConnected(view: view, text: text, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            view.sendComposed(text)
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

    /// Sends a multiplexer command once the session is live. Test-only.
    ///
    /// A two-finger sweep cannot be performed by a script, so this reaches the
    /// view's own send path with the same command table a real gesture uses —
    /// which is the only way to see the bytes on the wire. Pairs with `cat -v`
    /// on the host, which renders a prefix as `^B`.
    static func fireMuxCommandWhenConnected(
        view: CQUTTerminalView, command: MuxSettings.MuxCommand, attempt: Int = 0
    ) {
        guard attempt < 60 else { return }
        guard view.isLiveForTesting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                fireMuxCommandWhenConnected(view: view, command: command, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            view.fireMuxCommandForTesting(command)
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

    /// Resolves a seeded host's key and reports what happened, for a UI run.
    ///
    /// This exercises the real path rather than the decision alone: it reads
    /// the Keychain back — a stored PEM that came back truncated would pass
    /// every in-process check and fail only here — and compares the public key
    /// derived from the result against what `ssh-keygen` says, which is the
    /// only comparison that catches a decryption that produced *a* key rather
    /// than *the* key.
    ///
    /// Called from `CQUTmuxApp` right after `apply(to:)` rather than from a
    /// view. A view's task is built in the same pass as the screen and can run
    /// before the host list has been seeded, which is exactly what a first
    /// attempt at this did — it reported an empty list.
    ///
    /// The result goes to a file as well as stderr: `simctl launch
    /// --console-pty` only attaches to a process it starts, and a relaunch of
    /// an app iOS has not fully torn down returns without the output.
    static func resolveAndReport(_ store: HostStore) {
        let env = ProcessInfo.processInfo.environment
        guard let hostname = env["CQUT_DEV_RESOLVE_KEY"] else { return }
        report("started hosts=\(store.hosts.map(\.hostname).joined(separator: ","))")
        guard let host = store.hosts.first(where: { $0.hostname == hostname }) else {
            report("no host named \(hostname)")
            return
        }
        let stored = KeychainStore.load(account: host.keySeedAccount)
        let requirement = KeyMaterial.requirement(for: stored, passphrase: host.keyPassphrase)
        let size = stored.map { "\($0.count)B" } ?? "-"
        guard let seed = host.resolveSeed() else {
            report("\(requirement) stored=\(size) seed=nil")
            return
        }
        let line = (try? Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "x")) ?? "?"
        let body = line.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
        report("\(requirement) stored=\(size) seed=\(seed.count)B pub=\(body)")
    }

    private static func report(_ outcome: String) {
        print("CQUT_RESOLVE_KEY: \(outcome)")
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? outcome.write(to: docs.appendingPathComponent("resolve.txt"), atomically: true, encoding: .utf8)
    }
}
#endif