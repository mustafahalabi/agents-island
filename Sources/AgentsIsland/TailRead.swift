import Foundation

/// Decoding the trailing window of an agent transcript.
///
/// Transcripts grow to 100MB+, so every reader seeks to `size - N` and parses
/// only what follows. That offset is a *byte* count chosen without regard to
/// character boundaries, so the window regularly begins in the middle of a
/// multi-byte UTF-8 sequence — an emoji, a curly quote, an accented letter, a
/// box-drawing character in some tool output.
///
/// `String(data:encoding:.utf8)` is strict and returns nil for exactly that
/// input. Every caller treated nil as "no entries", so a single split character
/// blanked the whole card — title, prompt, activity, model, todos — and the
/// empty result was then cached under the file's mtime, keeping it blank until
/// the next write. Measured on a real transcript, roughly one read in 700 began
/// mid-character; transcripts containing emoji or non-English text fare worse.
///
/// Decoding lossily instead cannot fail. The replacement characters only ever
/// land in the window's first line, which every caller already discards as
/// partial, so nothing downstream sees them.
enum TailRead {

    /// Decode a byte window that may begin mid-character.
    static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Usable lines from a tail window.
    ///
    /// - Parameter dropsFirstLine: whether the window began mid-line, making
    ///   its first line a fragment of a record that started before the offset.
    static func lines(_ data: Data, dropsFirstLine: Bool) -> [Substring] {
        var lines = decode(data).split(separator: "\n", omittingEmptySubsequences: true)
        if dropsFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Stream complete lines from `handle`, starting at the current offset,
    /// without holding the whole file in memory.
    ///
    /// The usage tracker previously read a transcript with `readToEnd()` and
    /// then copied the result into a String. Its offset starts at zero for
    /// every file it has not seen — first launch, and again whenever a file's
    /// state is evicted — so a single 100MB transcript cost roughly 250-300MB
    /// of peak RSS, and the tracker walks every transcript touched in the last
    /// eight days in one pass. That is a lot for a menu bar app.
    ///
    /// A trailing partial line is deliberately left unconsumed: it is still
    /// being written, and the returned byte count excludes it so the next pass
    /// re-reads from the start of that line.
    ///
    /// - Returns: the number of bytes of complete lines consumed.
    @discardableResult
    static func consumeLines(
        handle: FileHandle,
        chunkSize: Int = 4 * 1024 * 1024,
        _ body: (Substring) -> Void
    ) -> UInt64 {
        var carry = Data()          // bytes after the last newline seen so far
        var totalRead: UInt64 = 0

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            totalRead += UInt64(chunk.count)
            var buffer = carry
            buffer.append(chunk)

            guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
                carry = buffer      // still no complete line — keep accumulating
                continue
            }
            // Whole lines only, so a multi-byte character can never be split
            // across the boundary and decoding is exact.
            for line in decode(buffer[...lastNewline])
                .split(separator: "\n", omittingEmptySubsequences: true) {
                body(line)
            }
            carry = Data(buffer[buffer.index(after: lastNewline)...])
        }

        return totalRead - UInt64(carry.count)
    }
}
