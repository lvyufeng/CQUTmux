import SwiftUI
import AVFoundation
import UIKit

/// Imports a theme from the three places Moshi does: the clipboard, a QR code,
/// or a file of JSON.
///
/// All three land here rather than each getting its own screen, because from
/// the user's side they are one intention — "add this theme" — and the only
/// difference is where the text is coming from. The QR route is what a gallery
/// page actually shows; the text route is what survives when a camera is not
/// pointing at anything.
struct ThemeImportView: View {
    /// Called with the parsed theme once it has been accepted.
    let onImport: (TerminalTheme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var mode: Mode = .paste

    private enum Mode: String, CaseIterable {
        case paste, scan
        var label: String { self == .paste ? "Paste" : "Scan" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .paste: pastePane
                case .scan: scanPane
                }
            }
            .navigationTitle("Import theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if mode == .paste {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { attempt(text) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Couldn't import", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var pastePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    // A placeholder rather than a prompt drawn in the editor,
                    // which would then be part of what gets parsed.
                    if text.isEmpty {
                        Text("Paste the theme's JSON, or a moshi-theme: string.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                // Reading the clipboard first is the common case: the user
                // copied the theme somewhere else and opened this screen.
                if let copied = UIPasteboard.general.string { text = copied }
            } label: {
                Label("Use clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var scanPane: some View {
        QRScannerView { payload in
            // The scanner keeps delivering frames, so a code left in view would
            // import repeatedly; the view is dismissed on the first hit.
            attempt(payload, fromScan: true)
        }
        .overlay(alignment: .bottom) {
            Text("Point at a theme's QR code.")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private func attempt(_ raw: String, fromScan: Bool = false) {
        switch ThemeImport.parse(raw) {
        case .success(let theme):
            onImport(theme)
            dismiss()
        case .failure(let failure):
            error = failure.localizedDescription
            if fromScan { mode = .paste; text = raw }
        }
    }
}

/// A camera view that reports the first QR code it sees.
///
/// `AVCaptureMetadataOutput` rather than a Vision request: the payload is a
/// string, not an image to interpret, and the metadata output is what iOS
/// offers for exactly that. Nothing is stored — the string is handed over and
/// the session is torn down with the view.
private struct QRScannerView: UIViewControllerRepresentable {
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
    /// Set on the first code so the next frame does not deliver a second.
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Asked for only here, at the moment a user chooses to scan, rather
        // than at launch — a camera prompt on first run, before there is
        // anything to scan, is a permission request with no context.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.showDenied()
                    return
                }
                self?.start()
            }
        }
    }

    private func start() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showDenied()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showDenied()
            return
        }
        session.addOutput(output)
        // Set after adding the output: the type list is empty until the output
        // is attached to a session, and assigning earlier silently does
        // nothing, leaving a scanner that never fires.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
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
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                  .first(where: { $0.type == .qr })?.stringValue
        else { return }
        delivered = true
        onCode?(code)
    }

    private func showDenied() {
        let label = UILabel()
        label.text = "Camera access is off. Turn it on in Settings, or paste the theme instead."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }
}