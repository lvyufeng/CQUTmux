import SwiftUI
import AVFoundation
import UIKit

/// Easy Pair: sets up a host from a link the host printed.
///
/// The host runs `cqutmux pair`, which generates a key if it has none and shows
/// this phone a QR code and a URL. Everything the connection needs is in that
/// string — address, port, user, gateway token, and the key — so the phone's
/// side is one scan instead of a form with five fields and a key to copy by
/// hand, which is the part people get wrong.
///
/// Both sources land on the same screen for the same reason they do in the
/// theme importer: from the user's side it is one intention, and the difference
/// is only where the text came from. The text route is also the only one that
/// works when the app is running in a simulator, which is how this is tested.
struct PairingView: View {
    /// Called with the parsed link once the user accepts it.
    let onPair: (Pairing.Payload) -> Void

    /// A link to open with, for a run that cannot type or paste.
    ///
    /// Defaulted to empty, which is every real use. The simulator has no way to
    /// put text in a `TextEditor` or operate a camera, so without this the
    /// confirmation screen could only be reasoned about.
    var initialText: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase
    @State private var preview: Pairing.Payload?
    @State private var error: String?

    /// One state rather than a `mode` and a `text` that have to agree.
    ///
    /// It also removes the initial-value problem: opening straight onto the
    /// paste pane with the link already in it has to happen in `init`, because
    /// a debug link that first draws the camera view starts the camera and
    /// raises the permission prompt before any `.task` can switch away.
    private enum Phase {
        case scan
        case paste(String)
    }

    init(initialText: String = "", onPair: @escaping (Pairing.Payload) -> Void) {
        self.onPair = onPair
        self.initialText = initialText
        _phase = State(initialValue: initialText.isEmpty ? .scan : .paste(initialText))
    }

    private var mode: Mode { if case .paste = phase { .paste } else { .scan } }

    private func setMode(_ mode: Mode) {
        switch mode {
        case .scan: phase = .scan
        case .paste: phase = .paste(currentText)
        }
    }

    private var currentText: String { if case .paste(let value) = phase { value } else { "" } }

    private enum Mode: String, CaseIterable {
        case scan, paste
        var label: String { self == .scan ? "Scan" : "Paste" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: Binding(get: { mode }, set: setMode)) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch phase {
                case .scan: scanPane
                case .paste: pastePane
                }
            }
            .navigationTitle("Pair a host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if mode == .paste {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pair") { attempt(currentText) }
                            .disabled(currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .sheet(item: $preview) { payload in
                PairingConfirmation(payload: payload) {
                    onPair(payload)
                    preview = nil
                    dismiss()
                }
            }
            .alert("Couldn't pair", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task {
                // A debug link goes straight to the confirmation, which is the
                // screen that shows what is about to be saved.
                guard !initialText.isEmpty else { return }
                attempt(initialText)
            }
        }
    }

    private var scanPane: some View {
        QRScannerView { payload in
            // The scanner keeps delivering frames, so a code left in view would
            // fire repeatedly; it only ever reports the first.
            attempt(payload, fromScan: true)
        }
        .overlay(alignment: .bottom) {
            Text("Point at the code from `cqutmux pair`.")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private var pastePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { currentText }, set: { phase = .paste($0) }))
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if currentText.isEmpty {
                        Text("Paste the cqutmux://pair link, or the .conf file's contents.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Button {
                if let copied = UIPasteboard.general.string { phase = .paste(copied) }
            } label: {
                Label("Use clipboard", systemImage: "document.on.clipboard")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func attempt(_ raw: String, fromScan: Bool = false) {
        // A camera sees every code in the room. One that is plainly not ours is
        // not an error to report — the user is simply still looking.
        if fromScan, !Pairing.looksLikePairing(raw) { return }
        do {
            // Shown before it is saved: the link names a machine to connect to
            // and carries a key, and "paired" silently to a host someone pasted
            // by mistake is how a session ends up on the wrong box.
            preview = try Pairing.parse(raw)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            // A code that was not ours is not worth keeping, but a link that
            // is almost right is: it goes into the paste field so it can be
            // corrected rather than retyped.
            if fromScan, Pairing.looksLikePairing(raw) { phase = .paste(raw) }
        }
    }
}

/// What the user is about to save, so pairing is never invisible.
private struct PairingConfirmation: View {
    let payload: Pairing.Payload
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Host", value: payload.host)
                    LabeledContent("Port", value: "\(payload.port)")
                    LabeledContent("User", value: payload.username)
                    if let name = payload.name { LabeledContent("Name", value: name) }
                }
                Section {
                    if payload.seed != nil {
                        Label("An SSH key is included", systemImage: "key.fill")
                    } else {
                        Label("No SSH key — you'll be asked for a password",
                              systemImage: "key.slash")
                    }
                    if payload.token != nil {
                        Label("The gateway token is included", systemImage: "lock.fill")
                    }
                } footer: {
                    Text(payload.seed != nil
                         ? "The key is stored in the keychain, not in the saved connection."
                         : "Pair without a key only works if the host accepts a password.")
                }
            }
            .navigationTitle("Add this host?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: confirm)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// `sheet(item:)` needs an identity, and a payload has none of its own.
extension Pairing.Payload: Identifiable {
    public var id: String { "\(host):\(port)/\(username)" }
}

/// A camera view that reports the first QR code it sees.
///
/// `AVCaptureMetadataOutput` rather than a Vision request: the payload is a
/// URL, the system decoder handles the error correction and the orientation,
/// and this is the same reading a phone's own camera app would do.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Asking here rather than at launch: the prompt should arrive when the
        // camera is actually wanted, not on first run before it means anything.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.configure() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [weak session] in
            session?.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The session holds the camera; leaving it running behind a dismissed
        // sheet keeps the indicator light on.
        session.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered else { return }
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }
        delivered = true
        onCode?(value)
    }
}