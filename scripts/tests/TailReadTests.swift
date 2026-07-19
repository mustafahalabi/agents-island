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

        // --- streaming a file in bounded chunks --------------------------------
        // The usage tracker used to read whole transcripts into memory (and then
        // copy them into a String), spiking RSS by ~250-300MB per 100MB file.
        // The chunked reader must produce identical results, and its byte count
        // must exclude a trailing partial line so the next pass re-reads it.
        let dir = NSTemporaryDirectory() + "ai-tailread-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func consume(_ contents: String, chunk: Int, name: String) -> (lines: [String], consumed: UInt64) {
            let path = dir + "/\(name)"
            try? contents.write(toFile: path, atomically: true, encoding: .utf8)
            guard let handle = FileHandle(forReadingAtPath: path) else { return ([], 0) }
            defer { try? handle.close() }
            var seen: [String] = []
            let n = TailRead.consumeLines(handle: handle, chunkSize: chunk) { seen.append(String($0)) }
            return (seen, n)
        }

        // Complete file, tiny chunks: lines must not be split at boundaries.
        let complete = "alpha\nbeta\ngamma\n"
        for chunkSize in [1, 2, 3, 5, 7, 16, 4096] {
            let r = consume(complete, chunk: chunkSize, name: "c\(chunkSize).txt")
            if r.lines != ["alpha", "beta", "gamma"] {
                fail("chunk \(chunkSize): got \(r.lines)")
            }
            if r.consumed != UInt64(complete.utf8.count) {
                fail("chunk \(chunkSize): consumed \(r.consumed), want \(complete.utf8.count)")
            }
        }

        // Trailing partial line: not emitted, and NOT counted — otherwise the
        // next pass would skip past a record that was still being written.
        let partial = "alpha\nbeta\npartial-stil"
        for chunkSize in [1, 4, 64] {
            let r = consume(partial, chunk: chunkSize, name: "p\(chunkSize).txt")
            if r.lines != ["alpha", "beta"] { fail("partial chunk \(chunkSize): got \(r.lines)") }
            if r.consumed != UInt64("alpha\nbeta\n".utf8.count) {
                fail("partial chunk \(chunkSize): consumed \(r.consumed), want 11")
            }
        }

        // A multi-byte character straddling a chunk boundary must survive: the
        // reader only ever cuts at newlines, so characters stay intact.
        let unicode = "one ✅ two\n三 four\ncafé\n"
        for chunkSize in [1, 2, 3, 5, 8, 13] {
            let r = consume(unicode, chunk: chunkSize, name: "u\(chunkSize).txt")
            if r.lines != ["one ✅ two", "三 four", "café"] {
                fail("unicode chunk \(chunkSize): got \(r.lines)")
            }
        }

        // A single line longer than the chunk size must still be assembled.
        let long = String(repeating: "x", count: 10_000) + "\n"
        let longResult = consume(long, chunk: 64, name: "long.txt")
        if longResult.lines.count != 1 || longResult.lines.first?.count != 10_000 {
            fail("a line longer than the chunk was not reassembled")
        }

        // Degenerate inputs.
        if consume("", chunk: 16, name: "e.txt").consumed != 0 { fail("empty file consumed bytes") }
        if !consume("no-newline-at-all", chunk: 4, name: "n.txt").lines.isEmpty {
            fail("a file with no newline should emit nothing")
        }
        if consume("no-newline-at-all", chunk: 4, name: "n2.txt").consumed != 0 {
            fail("a file with no complete line should consume nothing")
        }

        if failures == 0 {
            print("✅ TailReadTests: all passed (byte-split windows no longer blank the card)")
        } else {
            print("❌ TailReadTests: \(failures) failure(s)"); exit(1)
        }
    }
}
