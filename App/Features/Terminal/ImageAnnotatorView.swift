import SwiftUI
import PencilKit
import UIKit

/// Paste, crop and annotate an image, then send it to the host. Mirrors
/// Moshi's image flow: the drawing is flattened against the photo so the
/// annotations the user just made are what the agent actually sees.
struct ImageAnnotatorView: View {
    @Environment(ThemeStore.self) private var themes
    /// Base image to annotate (from the clipboard or the photo library).
    let image: UIImage
    let client: HookClient
    /// Called with the host-side path once the upload succeeds.
    let onUploaded: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var canvas = PKDrawing()
    @State private var tool: Tool = .pen
    @State private var color: Color = .red
    @State private var uploading = false
    @State private var error: String?

    private enum Tool: String, CaseIterable {
        case pen = "Pen", marker = "Marker", eraser = "Eraser"

        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .marker: "highlighter"
            case .eraser: "eraser"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Image(uiImage: flattenedPreview)
                        .resizable()
                        .scaledToFit()
                        .background(Color.black)
                    DrawingCanvas(drawing: $canvas, tool: canvasTool)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                toolbar
            }
            .background(Color.black)
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if uploading {
                        ProgressView()
                    } else {
                        Button("Send", action: send)
                    }
                }
            }
            .alert("Upload failed", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ForEach(Tool.allCases, id: \.self) { item in
                Button {
                    tool = item
                } label: {
                    Image(systemName: item.symbol)
                        .frame(width: 34, height: 34)
                        .background(tool == item ? themes.current.accentColor.opacity(0.25) : .clear, in: Circle())
                }
                .tint(tool == item ? themes.current.accentColor : .white)
            }

            Divider().frame(height: 24).overlay(.white.opacity(0.3))

            ForEach([Color.red, .yellow, .green, .blue], id: \.self) { swatch in
                Button { color = swatch } label: {
                    Circle()
                        .fill(swatch)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(.white, lineWidth: color == swatch ? 2 : 0)
                        )
                }
            }

            Spacer()

            Button {
                canvas = PKDrawing()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .tint(.white)
            .disabled(canvas.strokes.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private var canvasTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(.pen, color: UIColor(color))
        case .marker: PKInkingTool(.marker, color: UIColor(color))
        case .eraser: PKEraserTool(.vector)
        }
    }

    /// Burns the annotations onto the photo so what leaves the device is what
    /// the user drew — the host has no PencilKit to render strokes itself.
    private var flattenedPreview: UIImage {
        let bounds = CGRect(origin: .zero, size: image.size)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: bounds)
            canvas.image(from: bounds, scale: image.scale).draw(in: bounds)
        }
    }

    private func send() {
        let output = flattenedPreview
        guard let data = output.pngData() else {
            error = "Couldn't encode the image."
            return
        }
        uploading = true
        Task {
            do {
                let result = try await client.uploadImage(data, filename: "paste.png")
                onUploaded(result.path)
                dismiss()
            } catch {
                self.error = "\(error)"
            }
            uploading = false
        }
    }
}

/// Thin PencilKit host. Uses a plain `PKCanvasView` so strokes stay vector
/// until we flatten them, and so the eraser maps to PencilKit's own tool.
private struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = tool
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let drawing: Binding<PKDrawing>
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}