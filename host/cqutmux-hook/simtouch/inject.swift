// cqutmux-simtouch — inject touch events into a booted iOS Simulator.
//
// The Simulator has no supported touch-injection interface. `simctl` can take
// a screenshot and record video, but it cannot deliver a tap, and no public
// tool can: the only path is CoreSimulator's private IndigoHID API, reached
// through the ObjC runtime out of the frameworks Xcode already installs. This
// is the same mechanism `serve-sim` (the helper Moshi's own docs name for
// simulator preview) and Meta's idb use; the call sequence here was written
// against serve-sim's Apache-2.0 HIDInjector.
//
// Why this is a separate binary rather than part of the Node gateway: the
// frameworks load only into a process the Objective-C runtime takes over, and
// dlopen'ing SimulatorKit inside node crashes at load. The gateway spawns this
// once per simulator and talks to it over stdin/stdout, which also keeps a
// crashed injection from taking the daemon down with it.
//
// Protocol, one command per line on stdin, one JSON reply per line on stdout:
//   {"type":"tap","x":0.5,"y":0.3}
//   {"type":"down","x":0.5,"y":0.3,"edge":0}
//   {"type":"move","x":0.5,"y":0.4}
//   {"type":"up","x":0.5,"y":0.4}
//   {"type":"swipe","x":0.5,"y":0.8,"x2":0.5,"y2":0.2,"ms":300}
//   {"type":"pinch","x":0.5,"y":0.5,"x2":0.6,"y2":0.5,"scale":2,"ms":300}
// Coordinates are normalised 0..1 against the device screen, so the phone does
// not need to know the pixel size.
//
// Usage: cqutmux-simtouch <udid>

import Foundation
import CoreGraphics
import ObjectiveC
import Dispatch

// MARK: - Framework loading

/// Loads CoreSimulator (SimulatorKit's @rpath dependency) and then SimulatorKit,
/// whichever place the installed Xcode keeps them. Xcode 27 moved SimulatorKit
/// from Developer/Library/PrivateFrameworks to Contents/SharedFrameworks, so
/// both are tried. Nothing here is linked or imported — it is all resolved at
/// runtime — which keeps the binary free of an @rpath load command whose
/// location is version-specific.
func loadFrameworks() {
    let env = ProcessInfo.processInfo.environment
    let dev = env["DEVELOPER_DIR"]
        ?? "/Applications/Xcode.app/Contents/Developer"
    let candidates = [
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        "\(dev)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        "\(dev)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
        "\(dev)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
    ]
    for path in candidates { _ = dlopen(path, RTLD_NOW) }
}

// MARK: - The device and its HID client

/// A booted simulator found through CoreSimulator's own services, plus the
/// legacy HID client that carries Indigo messages across XPC.
final class Injector {
    private let client: NSObject
    private let sendSel: Selector
    private let mouseFunc: MouseFunc

    // IndigoHIDMessageForMouseNSEvent(CGPoint*, CGPoint*, IndigoHIDTarget,
    // NSEventType, NSSize, IndigoHIDEdge). On arm64 the two CGFloat sizes go in
    // d0/d1, the integers and pointers in x0-x4. Passing NSSize(1, 1) makes the
    // function's internal ratio equal the coordinate it is handed, so the value
    // passed here is already the normalised point.
    typealias MouseFunc = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32,
        CGFloat, CGFloat, UInt32
    ) -> UnsafeMutableRawPointer?

    // idb's touch target. 0x32 is the digitizer.
    private static let touchTarget: UInt32 = 0x32

    // NSEventType values the C function accepts for a touch. Dragged (6) is
    // rejected, so a move is sent as another Down — which is what the
    // Simulator itself does while a finger is down.
    private static let eventDown: Int32 = 1
    private static let eventUp: Int32 = 2

    private static let secondsPerFrame: Double = 1.0 / 60.0

    init?(udid: String) {
        guard let device = Self.findDevice(udid) else {
            FileHandle.standardError.write(Data("cqutmux-simtouch: no booted simulator \(udid)\n".utf8))
            return nil
        }
        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            FileHandle.standardError.write(Data("cqutmux-simtouch: SimulatorKit HID client unavailable\n".utf8))
            return nil
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        typealias InitFunc = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?
        guard let initIMP = class_getMethodImplementation(hidClass, initSel) else { return nil }
        let initFunc = unsafeBitCast(initIMP, to: InitFunc.self)
        var error: NSError?
        guard let client = initFunc(hidClass.alloc(), initSel, device, &error) as? NSObject else {
            FileHandle.standardError.write(Data("cqutmux-simtouch: \(error?.localizedDescription ?? "HID client init failed")\n".utf8))
            return nil
        }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") else {
            FileHandle.standardError.write(Data("cqutmux-simtouch: IndigoHIDMessageForMouseNSEvent missing\n".utf8))
            return nil
        }
        self.client = client
        self.sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        self.mouseFunc = unsafeBitCast(symbol, to: MouseFunc.self)
    }

    /// Finds the booted device the same way CoreSimulator's own clients do,
    /// through `SimServiceContext` for the active developer directory.
    private static func findDevice(_ udid: String) -> NSObject? {
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else { return nil }
        let dev = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        guard let context = contextClass
            .perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"), with: dev, with: nil)?
            .takeUnretainedValue() as? NSObject,
            let set = context.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?
                .takeUnretainedValue() as? NSObject,
            let devices = set.value(forKey: "devices") as? [NSObject]
        else { return nil }
        return devices.first {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(udid) == .orderedSame
        }
    }

    /// Hands one built message to the guest and frees it.
    ///
    /// The send crosses XPC, so a caller that exits immediately after can drop
    /// the event on the floor — which is exactly what happened the first time
    /// this was written, and why the run loop is pumped below.
    private func rawSend(_ message: UnsafeMutableRawPointer) {
        typealias SendFunc = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        guard let sendIMP = class_getMethodImplementation(object_getClass(client)!, sendSel) else {
            free(message)
            return
        }
        unsafeBitCast(sendIMP, to: SendFunc.self)(client, sendSel, message, ObjCBool(true), nil, nil)
    }

    /// Builds and sends a single-finger touch at a normalised point.
    func send(_ kind: Int32, x: Double, y: Double, edge: UInt32 = 0) {
        var point = CGPoint(x: x, y: y)
        guard let message = mouseFunc(&point, nil, Self.touchTarget, kind, 1.0, 1.0, edge) else { return }
        rawSend(message)
    }

    /// Builds and sends a two-finger touch, which is what the Simulator turns
    /// into a pinch or a rotate depending on how the two points move.
    func send(_ kind: Int32, x1: Double, y1: Double, x2: Double, y2: Double) {
        var first = CGPoint(x: x1, y: y1)
        var second = CGPoint(x: x2, y: y2)
        guard let message = mouseFunc(&first, &second, Self.touchTarget, kind, 1.0, 1.0, 0) else { return }
        rawSend(message)
    }

    // MARK: - Gestures

    /// A tap: down then up at one point, held long enough to register.
    func tap(x: Double, y: Double) {
        send(Self.eventDown, x: x, y: y)
        // A plain sleep, not a run-loop turn: the touch has to stay down while
        // no other work happens, and a run loop that services the device
        // connection mid-touch can drop it.
        usleep(80_000)
        send(Self.eventUp, x: x, y: y)
    }

    func swipe(from: (Double, Double), to: (Double, Double), milliseconds: Double) {
        let steps = max(2, Int(milliseconds / 1000 / Self.secondsPerFrame))
        let step = max(Self.secondsPerFrame, milliseconds / 1000 / Double(steps))
        send(Self.eventDown, x: from.0, y: from.1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            send(Self.eventDown, x: from.0 + (to.0 - from.0) * t, y: from.1 + (to.1 - from.1) * t)
            RunLoop.current.run(until: Date().addingTimeInterval(step))
        }
        send(Self.eventUp, x: to.0, y: to.1)
    }

    /// A pinch. The two fingers start apart and move to a target separation; a
    /// scale above 1 spreads them (zoom in), below 1 brings them together out.
    func pinch(centre: (Double, Double), start: Double, scale: Double, milliseconds: Double) {
        let steps = max(2, Int(milliseconds / 1000 / Self.secondsPerFrame))
        let step = max(Self.secondsPerFrame, milliseconds / 1000 / Double(steps))
        let axis = 1.0 - centre.0  // keep both fingers inside the screen
        let radius = min(0.2, axis) * start
        func fingers(_ r: Double) -> ((Double, Double), (Double, Double)) {
            ((centre.0 - r, centre.1), (centre.0 + r, centre.1))
        }
        var (a, b) = fingers(radius)
        send(Self.eventDown, x1: a.0, y1: a.1, x2: b.0, y2: b.1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            (a, b) = fingers(radius * (1 + (scale - 1) * t))
            send(Self.eventDown, x1: a.0, y1: a.1, x2: b.0, y2: b.1)
            RunLoop.current.run(until: Date().addingTimeInterval(step))
        }
        send(Self.eventUp, x1: a.0, y1: a.1, x2: b.0, y2: b.1)
    }
}

// MARK: - Line protocol

func reply(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

func number(_ object: Any?) -> Double? {
    if let d = object as? Double { return d }
    if let i = object as? Int { return Double(i) }
    if let n = object as? NSNumber { return n.doubleValue }
    return nil
}

/// Runs a gesture, then pumps the run loop so its XPC sends have been delivered
/// before the reply is written. Without this the app receives "ok" for a touch
/// that never reached the guest.
func perform(_ injector: Injector, _ command: [String: Any]) -> Bool {
    guard let type = command["type"] as? String else { return false }
    let x = number(command["x"]) ?? 0.5
    let y = number(command["y"]) ?? 0.5
    switch type {
    case "tap":
        injector.tap(x: x, y: y)
    case "down":
        injector.send(1, x: x, y: y, edge: UInt32(number(command["edge"]) ?? 0))
    case "move", "up":
        // A move is a Down with a new point; only the contact is a Down.
        injector.send(type == "up" ? 2 : 1, x: x, y: y)
    case "swipe":
        injector.swipe(from: (x, y),
                       to: (number(command["x2"]) ?? x, number(command["y2"]) ?? y),
                       milliseconds: number(command["ms"]) ?? 300)
    case "pinch":
        injector.pinch(centre: (x, y),
                       start: number(command["start"]) ?? 0.6,
                       scale: number(command["scale"]) ?? 2,
                       milliseconds: number(command["ms"]) ?? 300)
    default:
        return false
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    return true
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: cqutmux-simtouch <udid>\n".utf8))
    exit(2)
}
loadFrameworks()
guard let injector = Injector(udid: arguments[1]) else { exit(3) }
// Ready line, so the gateway knows the frameworks loaded and the device was
// found before it starts handing over gestures.
reply(["type": "ready"])

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        reply(["ok": false, "error": "malformed command"])
        continue
    }
    let ok = perform(injector, command)
    reply(ok ? ["ok": true] : ["ok": false, "error": "unknown gesture"])
}
