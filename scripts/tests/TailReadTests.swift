// Tests for transcript tail decoding.
//
// The bug these cover: readers seek to `size - N`, an arbitrary BYTE offset, so
// the window regularly starts inside a multi-byte UTF-8 sequence. The old
// strict `String(data:encoding:.utf8)` returned nil for exactly that input and
// every caller read nil as "no entries" — blanking the whole session card, and
// caching the blank under the file's mtime so it stayed blank until the next
// write.
//
// Compiled against the real TailRead.swift by scripts/run-tests.sh.
import Foundation

@main
struct TailReadTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func check(_ label: String, _ got: [String], _ want: [String], _ line: Int = #line) {
        if got != want {
            failures += 1
            print("FAIL:\(line)  \(label)\n        got  \(got)\n        want \(want)")
        }
    }

    static func main() {
        // A realistic transcript line containing multi-byte characters.
        let full = #"{"a":1}"# + "\n" + #"{"b":"✅ done — “quoted”"}"# + "\n" + #"{"c":3}"# + "\n"
        let bytes = Array(full.utf8)

        // Slice at EVERY byte offset, including the ones that land inside a
        // multi-byte sequence. Two properties must hold at every offset:
        //
        //   1. decoding never collapses a non-empty window to nothing — that
        //      total loss is exactly what the strict decoder did, and what
        //      blanked the card;
        //   2. no corruption leaks past the discarded first line: every line
        //      handed back must still be parseable JSON.
        //
        // (An offset near EOF legitimately yields no lines once the partial
        // first line is dropped — that is correct, not a loss.)
        var emptied = 0, corrupted = 0
        for offset in 0..<bytes.count {
            let window = Data(bytes[offset...])
            if TailRead.decode(window).isEmpty { emptied += 1 }
            for line in TailRead.lines(window, dropsFirstLine: offset > 0) {
                if (try? JSONSerialization.jsonObject(with: Data(line.utf8))) == nil {
                    corrupted += 1
                }
            }
        }
        if emptied > 0 { fail("\(emptied) offsets decoded a non-empty window to nothing") }
        if corrupted > 0 { fail("\(corrupted) lines survived the partial-line drop corrupted") }

        // Concretely: an offset landing inside the ✅ (3 bytes) must still
        // surface the record that follows.
        let checkIdx = full.utf8.distance(
            from: full.utf8.startIndex,
            to: full.range(of: "✅")!.lowerBound.samePosition(in: full.utf8)!)
        let midEmoji = Data(bytes[(checkIdx + 1)...])   // 1 byte into the emoji
        let lines = TailRead.lines(midEmoji, dropsFirstLine: true).map(String.init)
        check("split mid-emoji still yields following records", lines, [#"{"c":3}"#])

        // Aligned to a line boundary with dropsFirstLine false — nothing lost.
        let aligned = Data((#"{"a":1}"# + "\n" + #"{"b":2}"#).utf8)
        check("aligned window keeps every line",
              TailRead.lines(aligned, dropsFirstLine: false).map(String.init),
              [#"{"a":1}"#, #"{"b":2}"#])

        // Pure ASCII is untouched.
        check("ascii passthrough",
              TailRead.lines(Data("one\ntwo\nthree".utf8), dropsFirstLine: false).map(String.init),
              ["one", "two", "three"])

        // Degenerate inputs must not crash or over-drop.
        check("empty data", TailRead.lines(Data(), dropsFirstLine: true).map(String.init), [])
        check("single partial line drops to nothing",
              TailRead.lines(Data("partial".utf8), dropsFirstLine: true).map(String.init), [])
        check("blank lines are skipped",
              TailRead.lines(Data("a\n\n\nb".utf8), dropsFirstLine: false).map(String.init),
              ["a", "b"])

        // decode never fails, even on bytes that are not valid UTF-8 at all.
        let garbage = Data([0xFF, 0xFE, 0x41, 0x42])
        if !TailRead.decode(garbage).contains("AB") {
            failures += 1
            print("FAIL: decode dropped valid trailing bytes after invalid ones")
        }

        if failures == 0 {
            print("✅ TailReadTests: all passed (byte-split windows no longer blank the card)")
        } else {
            print("❌ TailReadTests: \(failures) failure(s)"); exit(1)
        }
    }
}
