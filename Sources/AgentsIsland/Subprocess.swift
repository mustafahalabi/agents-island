import Foundation

/// Running a child process with a hard upper bound on how long it may block.
///
/// The remote scanner shells out to `ssh`, and ssh's own timeouts do not cover
/// the case that actually hangs: `ConnectTimeout` bounds only the TCP connect,
/// and `ServerAliveInterval` applies only once the transport is up. A host that
/// accepts the connection and then stalls in key exchange or authentication —
/// a blackholing firewall, an overloaded or wedged sshd — leaves ssh running
/// indefinitely.
///
/// `readDataToEndOfFile()` returns only when the write end of the pipe closes,
/// which happens when the child exits. So one wedged host blocked the scan
/// thread forever, and because scanning is serial that froze *every* host's
/// status and every subsequent scan until the app was relaunched.
enum Subprocess {

    /// Run `path` with `arguments`, returning its stdout, or nil if it could
    /// not be launched or exceeded `timeout`.
    ///
    /// On timeout the child is sent SIGTERM, which closes its stdout and
    /// releases the blocked read.
    static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        // `isRunning` is checked inside the watchdog rather than cancelling
        // being relied on alone: the work item can already be executing when
        // the process exits, and terminating a reaped process is not safe.
        let timedOut = Atomic(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set(true)
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // A killed scan's partial output is not trustworthy — the caller's
        // sentinel check would mis-read a truncated host as simply empty.
        if timedOut.get() { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Minimal box so the watchdog and the calling thread can share a flag.
    private final class Atomic<T> {
        private var value: T
        private let lock = NSLock()
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }
}
