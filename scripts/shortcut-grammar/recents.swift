import Foundation

// Exercises the recent-directories store. Like the gesture store it is a plist
// plus plain logic, so the questions worth asking — ordering, the cap, and
// whether two machines can share a path — need no simulator.
// Run with: scripts/shortcut-grammar/run.sh

@main
enum RecentChecks {
    static var failures = 0

    static func main() {
        ordering()
        hostScoping()
        theDotIsNotADirectory()
        theCap()
        clearing()
        survivesRestart()

        print("\n\(failures == 0 ? "recents check passed" : "recents check FAILED (\(failures))")")
        exit(failures == 0 ? 0 : 1)
    }

    static func expect(_ pass: Bool, _ note: String, got: String = "", want: String = "") {
        if !pass { failures += 1 }
        print("\(pass ? "PASS" : "FAIL")  \(note)")
        if !pass { print("        got \(got) wanted \(want)") }
    }

    static func expect(_ got: [String], _ want: [String], _ note: String) {
        expect(got == want, note, got: "\(got)", want: "\(want)")
    }

    static func expect(_ got: Int, _ want: Int, _ note: String) {
        expect(got == want, note, got: "\(got)", want: "\(want)")
    }

    static func expect(_ got: String?, _ want: String, _ note: String) {
        expect(got == want, note, got: String(describing: got), want: want)
    }

    static func expect(_ got: Bool, _ want: Bool, _ note: String) {
        expect(got == want, note, got: "\(got)", want: "\(want)")
    }

    static func store() -> (RecentDirectoryStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "cqutmux.recents.tests.\(UUID().uuidString)")!
        return (RecentDirectoryStore(defaults: suite), suite)
    }

    static func host(_ hostname: String, port: Int = 22) -> Host {
        var host = Host()
        host.hostname = hostname
        host.port = port
        return host
    }

    static func ordering() {
        print("— most recent first —")
        let (recents, _) = store()
        let machine = host("a.example")
        recents.record("~/one", for: machine)
        recents.record("~/two", for: machine)
        recents.record("~/one", for: machine)
        // Revisiting a directory moves it back to the top rather than adding a
        // second copy, which is what makes the list a shortlist.
        expect(recents.recent(for: machine), ["~/one", "~/two"], "a revisit moves to the front, deduplicated")
    }

    static func hostScoping() {
        print("\n— two machines, two lists —")
        let (recents, _) = store()
        let a = host("a.example")
        let b = host("b.example")
        recents.record("/srv/app", for: a)
        recents.record("/srv/app", for: b)
        recents.record("/only-a", for: a)
        expect(recents.recent(for: a), ["/only-a", "/srv/app"], "a's own list")
        expect(recents.recent(for: b), ["/srv/app"], "b was not given a's entries")

        // The port is part of the identity: two hosts on different ports are
        // two machines, which is exactly what a second sshd on the same box is.
        let otherPort = host("a.example", port: 2222)
        expect(recents.recent(for: otherPort), [], "a different port is a different host")
    }

    static func theDotIsNotADirectory() {
        print("\n— `.` is never recorded —")
        let (recents, _) = store()
        let machine = host("a.example")
        recents.record(".", for: machine)
        expect(recents.recent(for: machine), [], "the browse root would push a real directory off the end")
        recents.record("   ", for: machine)
        expect(recents.recent(for: machine), [], "nor is an empty entry")
    }

    static func theCap() {
        print("\n— the list is capped —")
        let (recents, _) = store()
        let machine = host("a.example")
        for index in 0..<(RecentDirectoryStore.limit + 5) {
            recents.record("~/dir\(index)", for: machine)
        }
        let list = recents.recent(for: machine)
        expect(list.count, RecentDirectoryStore.limit, "kept to the limit")
        expect(list.first, "~/dir\(RecentDirectoryStore.limit + 4)", "the newest survived")
        expect(list.contains("~/dir0"), false, "the oldest was dropped")
    }

    static func clearing() {
        print("\n— clearing touches one host —")
        let (recents, _) = store()
        let a = host("a.example")
        let b = host("b.example")
        recents.record("/srv/app", for: a)
        recents.record("/srv/app", for: b)
        recents.clear(for: a)
        expect(recents.recent(for: a), [], "a is empty")
        expect(recents.recent(for: b), ["/srv/app"], "b is untouched")
    }

    static func survivesRestart() {
        print("\n— recents survive a restart —")
        let (recents, suite) = store()
        recents.record("~/kept", for: host("a.example"))
        let reopened = RecentDirectoryStore(defaults: suite)
        expect(reopened.recent(for: host("a.example")), ["~/kept"], "the list was persisted")
        expect(reopened.recent(for: host("b.example")), [], "and another host is still empty")
    }
}