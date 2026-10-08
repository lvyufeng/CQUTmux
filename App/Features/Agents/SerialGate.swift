import Foundation

/// A by-hand async mutex. Swift's `OSAllocatedUnfairLock` has no async acquire,
/// and an actor would hop executors mid-request, so requests take turns through
/// an ordered FIFO of continuations instead.
final class SerialGate {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        lock.lock()
        if !busy {
            busy = true
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}