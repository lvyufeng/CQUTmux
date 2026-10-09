import SwiftUI
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
