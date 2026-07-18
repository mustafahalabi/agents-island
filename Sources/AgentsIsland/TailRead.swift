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
}
