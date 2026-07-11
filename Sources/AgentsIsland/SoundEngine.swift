import AppKit

/// Central sound playback: per-event sounds, master volume, quiet hours,
/// and user-imported sounds. Sound prefs store either a system sound name
/// ("Glass"), a custom sound reference ("custom:Airhorn"), or "Off".
final class SoundEngine {
    static let shared = SoundEngine()
    static let off = "Off"
    static let customPrefix = "custom:"

    private var current: NSSound? // keep a reference while playing
    private let defaults = UserDefaults.standard

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: .agentStarted, object: nil, queue: .main) { [weak self] _ in
            self?.playEvent(Pref.soundSessionStart)
        }
        center.addObserver(forName: .agentCompleted, object: nil, queue: .main) { [weak self] _ in
            self?.playEvent(Pref.soundTaskComplete)
        }
        center.addObserver(forName: .agentAcknowledged, object: nil, queue: .main) { [weak self] _ in
            self?.playEvent(Pref.soundAcknowledge)
        }
        center.addObserver(forName: .approvalNeeded, object: nil, queue: .main) { [weak self] _ in
            self?.playEvent(Pref.soundApprovalNeeded)
        }
    }

    /// Play the sound configured for a preference key, honoring master
    /// switch and quiet hours.
    func playEvent(_ prefKey: String) {
        guard defaults.bool(forKey: Pref.soundsEnabled), !inQuietHours else { return }
        play(defaults.string(forKey: prefKey) ?? Self.off)
    }

    /// Unconditional playback for settings previews.
    func preview(_ name: String) { play(name) }

    private func play(_ name: String) {
        guard name != Self.off else { return }
        let sound: NSSound?
        if name.hasPrefix(Self.customPrefix) {
            let base = String(name.dropFirst(Self.customPrefix.count))
            sound = Self.customSoundFiles()
                .first { ($0.lastPathComponent as NSString).deletingPathExtension == base }
                .flatMap { NSSound(contentsOf: $0, byReference: true) }
        } else {
            sound = NSSound(named: name)
        }
        guard let sound else { return }
        sound.volume = Float(defaults.double(forKey: Pref.soundVolume))
        current = sound
        sound.play()
    }

    var inQuietHours: Bool {
        guard defaults.bool(forKey: Pref.quietHoursEnabled) else { return false }
        let start = defaults.integer(forKey: Pref.quietHoursStart)
        let end = defaults.integer(forKey: Pref.quietHoursEnd)
        guard start != end else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // Range crosses midnight when end < start (e.g. 22:00 → 08:00).
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    // MARK: - Sound catalogs

    /// System sounds in /System/Library/Sounds ("Glass", "Ping", …).
    static var systemSounds: [String] {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    /// ~/Library/Application Support/AgentsIsland/Sounds
    static var customSoundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentsIsland/Sounds", isDirectory: true)
    }

    static func customSoundFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: customSoundsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { ["aiff", "aif", "wav", "mp3", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Display names of imported sounds (no extension).
    static func customSoundNames() -> [String] {
        customSoundFiles().map { ($0.lastPathComponent as NSString).deletingPathExtension }
    }

    /// Copy a user-picked audio file into the custom sounds folder.
    @discardableResult
    static func importSound(from url: URL) -> Bool {
        let dir = customSoundsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil
    }

    static func removeSound(named name: String) {
        for file in customSoundFiles()
        where (file.lastPathComponent as NSString).deletingPathExtension == name {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
