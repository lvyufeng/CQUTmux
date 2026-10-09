import SwiftUI
import UIKit

/// Live view of a booted iOS simulator running on the host. Mirrors Moshi's
/// simulator preview: pick a simulator, and the app shows its screen, polling
/// for a fresh frame while it is on screen.
///
/// The frames come back as PNGs over the SSH tunnel via the host gateway —
/// the host runs `simctl io … screenshot` for us, so the phone needs nothing
/// but the gateway.
struct SimulatorPreviewView: View {
    let client: HookClient

    @Environment(\.dismiss) private var dismiss

    @State private var board: SimulatorBoard?
    @State private var selected: SimulatorBoard.Simulator?
    @State private var frame: UIImage?
    @State private var error: String?
    @State private var loading = true
    @State private var interval: Double = 1.5
    /// Whether touches on the preview are sent to the simulator rather than
    /// ignored. Off by default so a preview opened to watch stays watch-only.
    @State private var control = false
    /// True while a gesture is in flight, for the spinner over the frame.
    @State private var sending = false
    /// Why the last gesture failed, shown once under the frame. A control that
    /// silently does nothing is worse than one that says why.
    @State private var touchError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    deviceView(selected)
                } else {
                    picker
                }
            }
            .navigationTitle(selected?.name ?? "Simulators")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            selected = nil
                            frame = nil
                        } label: {
                            Label("Simulators", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            .task { await loadList() }
            .task(id: selected?.udid) {
                guard let selected else { return }
                #if DEBUG
                auditionGestureWhenReady()
                #endif
                await poll(selected)
            }
        }
    }

    @ViewBuilder
    private var picker: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Finding simulators…") }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let simulators = board?.simulators, !simulators.isEmpty {
                Section("Booted") {
                    ForEach(simulators) { sim in
                        Button {
                            selected = sim
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sim.name).font(.subheadline)
                                Text(sim.runtime).font(.caption2).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            } else if !loading && error == nil {
                ContentUnavailableView {
                    Label("No booted simulators", systemImage: "iphone.slash")
                } description: {
                    Text("Boot a simulator on the host and it will show up here.")
                }
            }
        }
    }

    @ViewBuilder
    private func deviceView(_ sim: SimulatorBoard.Simulator) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    if let frame {
                        Image(uiImage: frame)
                            .resizable()
                            // The frame is fitted, so it does not fill the
                            // proxy; the touch overlay has to use the same
                            // fitted rectangle or every tap would be off by
                            // the letterbox.
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView("Waiting for the first frame…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let frame, control {
                        TouchSurface(
                            frameSize: frame.size,
                            bounds: proxy.size,
                            enabled: !sending,
                            onTap: { point in send(.tap(x: point.x, y: point.y), to: sim) },
                            onDrag: { from, to in
                                send(.drag(from: from, to: to), to: sim, refresh: true)
                            },
                            onPinch: { centre, scale in
                                send(.pinch(centre: centre, start: 0.6, scale: scale),
                                     to: sim, refresh: true)
                            }
                        )
                    }
                    if sending {
                        // The frame does not arrive for a beat after a gesture,
                        // so an untouched screen looks like a dropped touch.
                        // A spinner says the gesture was taken.
                        ProgressView()
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .background(Color.black)

            HStack {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(touchError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer()
                // Control is off by default: it turns every stray touch on a
                // preview someone opened to *look* at into an input on a device
                // they are not watching. The state lives in the toolbar so the
                // footer stays about the stream.
                Button {
                    control.toggle()
                } label: {
                    Label(control ? "Control on" : "Control",
                          systemImage: control ? "hand.tap.fill" : "hand.tap")
                }
                .font(.caption)
                Button(interval == 0 ? "Resume" : "Pause") {
                    interval = interval == 0 ? 1.5 : 0
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func loadList() async {
        loading = true
        defer { loading = false }
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                do {
                    let board = try await client.simulators()
                    self.board = board
                    #if DEBUG
                    // UI runs can jump straight to a device to exercise polling.
                    if let udid = ProcessInfo.processInfo.environment["CQUT_DEV_SIM_UDID"] {
                        selected = board.simulators.first { $0.udid == udid } ?? board.simulators.first
                    }
                    // Turns touch control on without a tap the harness cannot
                    // make, so a run can drive the preview's real recognisers
                    // rather than only its `send` method.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_SIM_CONTROL"] == "1" {
                        control = true
                    }
                    #endif
                } catch {
                    self.error = "\(error)"
                }
                return
            case .failed(let message):
                error = message
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        error = "Timed out connecting to the host."
    }

    #if DEBUG
    /// Sends one gesture through the view's own path once a device is selected.
    ///
    /// A `UIGestureRecognizer` cannot be driven from a script, and the thing
    /// worth testing is not the recogniser but whether a gesture reaches the
    /// simulator and moves it — so the check calls `send`, which is the same
    /// method the recognisers call, rather than a parallel path built to pass.
    /// The coordinates are the payload's, in the same normalised space the
    /// touch surface produces.
    private func auditionGestureWhenReady(attempt: Int = 0) {
        guard let payload = ProcessInfo.processInfo.environment["CQUT_DEV_SIM_TOUCH"] else { return }
        guard attempt < 60 else { return }
        guard selected != nil, frame != nil, client.state == .connected else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                auditionGestureWhenReady(attempt: attempt + 1)
            }
            return
        }
        // Parsed by the same rules the JSON body uses: `x,y` for a tap and
        // `x,y,x2,y2` for a drag.
        let parts = payload.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let sim = selected else { return }
            if parts.count >= 4 {
                send(.drag(from: CGPoint(x: parts[0], y: parts[1]),
                           to: CGPoint(x: parts[2], y: parts[3])), to: sim, refresh: true)
            } else if parts.count >= 2 {
                send(.tap(x: parts[0], y: parts[1]), to: sim)
            }
        }
    }
    #endif

    /// What the strip under the frame says: why the last touch failed if it
    /// did, otherwise the stream's state. The failure takes the line because a
    /// touch that did nothing is the thing a user is staring at wondering about.
    private var footer: String {
        if let touchError { return touchError }
        // `String(format:)` rather than the view builder's `specifier:` form:
        // this is a plain String, not a `Text`, so the interpolation overload
        // that takes a format specifier is not available.
        return interval == 0 ? "Paused" : String(format: "Updating every %.1fs", interval)
    }

    /// Polls frames until the view goes away or the user pauses. The `task(id:)`
    /// modifier cancels this when `selected` changes.
    private func poll(_ sim: SimulatorBoard.Simulator) async {
        while !Task.isCancelled {
            if interval > 0 {
                if let data = try? await client.simulatorScreenshot(udid: sim.udid),
                   let image = UIImage(data: data) {
                    frame = image
                    error = nil
                } else {
                    error = "Couldn't fetch a frame."
                }
                try? await Task.sleep(for: .seconds(interval))
            } else {
                // Paused: idle without spinning.
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Sends one gesture and, for the gestures that move the screen, waits for
    /// the next frame before clearing the spinner.
    ///
    /// The refresh is not cosmetic. The poll loop may be paused, and even when
    /// it is running the frame it is about to show may have been taken before
    /// the touch landed — so without this the screen would sit on the old frame
    /// and the gesture would look like it had done nothing.
    private func send(_ gesture: SimulatorGesture, to sim: SimulatorBoard.Simulator,
                      refresh: Bool = false) {
        sending = true
        touchError = nil
        Task {
            do {
                try await client.simulatorTouch(udid: sim.udid, gesture: gesture)
                if refresh, let data = try? await client.simulatorScreenshot(udid: sim.udid),
                   let image = UIImage(data: data) {
                    // Only repaint when the frame actually differs: replacing
                    // an identical image would still cost a redraw, and doing
                    // that after every touch makes a drag stutter.
                    if image.pngData() != frame?.pngData() { frame = image }
                }
            } catch {
                touchError = Self.describe(error)
            }
            sending = false
        }
    }

    /// Turns a failure into something that names the fix.
    ///
    /// Every way this can fail is a host setup problem rather than a transient
    /// one — no Xcode, no booted simulator, a helper that will not build — and
    /// the gateway's message already says which, so it is shown as-is. The
    /// generic fallback is for a transport error, which has no such text.
    private static func describe(_ error: Error) -> String {
        if let failure = error as? HookClient.Failure {
            return "Couldn't send the touch: \(failure.errorDescription ?? "unknown error")"
        }
        return "Couldn't send the touch: \(error.localizedDescription)"
    }
}

/// Turns touches on the preview into normalised points on the device screen.
///
/// The frame image is fitted, so it occupies a centred rectangle inside
/// whatever space the layout gives it. Every touch point is mapped through the
/// *same* fit — the image's own size against the available bounds — because
/// using the bounds directly would shift every tap by the letterbox and land
/// progressively further off the further the device is from the view's aspect
/// ratio. That mistake produces taps that work in the centre and miss at the
/// edges, which reads as an intermittent failure rather than an arithmetic one.
///
/// A `UIGestureRecognizer` rather than SwiftUI's `DragGesture`: the preview
/// needs simultaneous single- and two-finger gestures (a drag while a pinch is
/// recognised), and the recogniser delegate is the only place that can decide
/// which of the two a given touch stream belongs to.
private struct TouchSurface: UIViewRepresentable {
    /// The frame's pixel size, used only for its aspect ratio.
    let frameSize: CGSize
    /// The space the fitted frame lives in.
    let bounds: CGSize
    let enabled: Bool
    let onTap: (CGPoint) -> Void
    let onDrag: (CGPoint, CGPoint) -> Void
    let onPinch: (CGPoint, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        (view as? TouchView)?.coordinator = context.coordinator
        view.isUserInteractionEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchSurface
        /// Where the current drag began, in device coordinates — the drag
        /// handler needs the start each time, not just the moving point.
        private var dragOrigin: CGPoint?

        init(parent: TouchSurface) { self.parent = parent }

        /// Maps a point in the view's space to the device screen's 0..1 space
        /// through the frame's fitted rectangle.
        func normalise(_ point: CGPoint) -> CGPoint {
            guard parent.bounds.width > 0, parent.bounds.height > 0,
                  parent.frameSize.width > 0, parent.frameSize.height > 0 else {
                return CGPoint(x: 0.5, y: 0.5)
            }
            let widthScale = parent.bounds.width / parent.frameSize.width
            let heightScale = parent.bounds.height / parent.frameSize.height
            let scale = min(widthScale, heightScale)
            let fitted = CGSize(width: parent.frameSize.width * scale,
                                height: parent.frameSize.height * scale)
            let origin = CGPoint(x: (parent.bounds.width - fitted.width) / 2,
                                 y: (parent.bounds.height - fitted.height) / 2)
            let x = (point.x - origin.x) / fitted.width
            let y = (point.y - origin.y) / fitted.height
            return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }

        @objc func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let view = recogniser.view else { return }
            parent.onTap(normalise(recogniser.location(in: view)))
        }

        @objc func handlePan(_ recogniser: UIPanGestureRecognizer) {
            guard let view = recogniser.view else { return }
            let point = normalise(recogniser.location(in: view))
            switch recogniser.state {
            case .began:
                dragOrigin = point
            case .changed:
                guard let origin = dragOrigin else { return }
                // Sent while the finger moves, so the guest scrolls with it
                // rather than jumping when the finger lifts.
                parent.onDrag(origin, point)
            case .ended, .cancelled, .failed:
                if let origin = dragOrigin { parent.onDrag(origin, point) }
                dragOrigin = nil
            default:
                break
            }
        }

        @objc func handlePinch(_ recogniser: UIPinchGestureRecognizer) {
            guard let view = recogniser.view else { return }
            switch recogniser.state {
            case .began, .changed:
                parent.onPinch(normalise(recogniser.location(in: view)), recogniser.scale)
                // Reset so each callback carries the step since the last one,
                // not the total; the host applies one scale per message.
                recogniser.scale = 1
            default:
                break
            }
        }

        /// A two-finger touch is a pinch, never a scroll, so the pan has to
        /// stand down when a second finger arrives — otherwise a pinch would
        /// also drag the screen sideways.
        func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if recogniser is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer {
                return false
            }
            return true
        }
    }

    /// The view that owns the recognisers. Kept separate from the coordinator
    /// so they are installed once, on the view, rather than rebuilt on every
    /// SwiftUI update.
    final class TouchView: UIView, UIGestureRecognizerDelegate {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            for recogniser in [tap, pan, pinch] {
                recogniser.delegate = self
                addGestureRecognizer(recogniser)
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func tap(_ recogniser: UITapGestureRecognizer) {
            coordinator?.handleTap(recogniser)
        }

        @objc private func pan(_ recogniser: UIPanGestureRecognizer) {
            coordinator?.handlePan(recogniser)
        }

        @objc private func pinch(_ recogniser: UIPinchGestureRecognizer) {
            coordinator?.handlePinch(recogniser)
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            coordinator?.gestureRecognizer(recogniser, shouldRecognizeSimultaneouslyWith: other) ?? false
        }
    }
}