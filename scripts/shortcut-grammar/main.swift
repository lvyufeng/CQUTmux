import Foundation

// Exercise the grammar against the examples Moshi documents, plus the
// rejections it promises. Run with:
//   swiftc -o /tmp/shortcut_check/check ShortcutGrammar.swift main.swift && ...

func check(_ input: String, _ expected: [UInt8], _ note: String) {
    do {
        let parsed = try ShortcutGrammar.parse(input)
        let got = parsed.bytes
        let pass = got == expected
        print("\(pass ? "PASS" : "FAIL")  \(input.padding(toLength: 16, withPad: " ", startingAt: 0)) -> \(got)  [\(parsed.label)]  \(note)")
        if !pass { print("        expected \(expected)") }
    } catch {
        print("FAIL  \(input.padding(toLength: 16, withPad: " ", startingAt: 0)) -> threw \(error)")
    }
}

func rejects(_ input: String, _ note: String) {
    do {
        let parsed = try ShortcutGrammar.parse(input)
        print("FAIL  \(input.padding(toLength: 16, withPad: " ", startingAt: 0)) -> unexpectedly parsed \(parsed.bytes)  \(note)")
    } catch {
        print("PASS  \(input.padding(toLength: 16, withPad: " ", startingAt: 0)) -> \(error.localizedDescription)  \(note)")
    }
}

print("— documented examples —")
check("C-c", [0x03], "Ctrl+C")
check("C-b, T", [0x02, 0x54], "tmux chord: Ctrl+b then T")
check("C-b,S-t", [0x02, 0x54], "Shift+t is T: a terminal has no separate shift code")
check("F12, h", [0x1B, 0x5B, 0x32, 0x34, 0x7E, 0x68], "F12 then h")
check("S-Tab", [0x09], "Shift+Tab is still Tab; the CSI-Z form is separate")
check("C-dash", [0x2D], "Ctrl on dash has no control byte, stays a dash")
check("Ctrl+b1", [0x02, 0x31], "modifier applies to the first character, rest literal")
check("Ctrl+a,b", [0x01, 0x62], "comma separates keys")

print("\n— splitting —")
check("C-b,,,c", [0x02, 0x2C, 0x63], "double comma is a literal comma")
check(">", [0x3E], "no modifier: verbatim")
check("Ctrl+a,,b", [0x01, 0x2C, 0x62], "literal comma inside a chord")

print("\n— named keys and modifiers —")
check("Enter", [0x0D], "named key")
check("esc", [0x1B], "lowercase named key")
check("M-x", [0x1B, 0x78], "Meta is an ESC prefix")
check("Opt-Up", [0x1B, 0x1B, 0x5B, 0x41], "Meta on an arrow key")
check("Alt+Left", [0x1B, 0x1B, 0x5B, 0x44], "Alt+Left, the word-jump chord")
check("shift+tab", [0x09], "lowercase modifier spelling")
check("Ctrl+Space", [0x00], "Ctrl+Space is NUL")
check("S-1", [0x21], "Shift+1 is !")
check("S-a", [0x41], "Shift+a is A")

print("\n— text: passthrough —")
do {
    let parsed = try ShortcutGrammar.parse("text:/clear")
    let want: [UInt8] = Array("/clear".utf8) + [0x0D]
    print("\(parsed.bytes == want ? "PASS" : "FAIL")  text:/clear      -> \(parsed.bytes) autoEnter=\(parsed.autoEnter)")
} catch { print("FAIL text:/clear threw \(error)") }
do {
    let parsed = try ShortcutGrammar.parse("text:a,b c")
    let want: [UInt8] = Array("a,b c".utf8) + [0x0D]
    print("\(parsed.bytes == want ? "PASS" : "FAIL")  text:a,b c      -> \(parsed.bytes) (commas kept)")
} catch { print("FAIL text:a,b c threw \(error)") }

print("\n— rejections —")
rejects("Contrl-b", "misspelled modifier")
rejects("F13", "out of range")
rejects("", "empty")
rejects("C-b,", "dangling separator")
rejects("nosuchkey", "unknown key")