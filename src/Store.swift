import Foundation
import AppKit

/// Holds every entry and keeps them in a plain JSON file in iCloud Drive
/// (falls back to ~/Documents if iCloud Drive isn't switched on).
final class LedgerStore: ObservableObject {
    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var todayKey: String = JournalCalendar.todayKey()
    @Published private(set) var problem: String?
    /// Changes whenever a square should play the ink-in animation.
    @Published private(set) var inkToken = 0
    @Published private(set) var inkedKey: String?

    let fileURL: URL
    let isInICloud: Bool
    private let backupURL: URL
    private var lastModified: Date?
    /// False while the file is unreadable or still downloading, so we never overwrite real data.
    private var safeToWrite = true
    private var timer: Timer?

    init() {
        let (url, cloud) = LedgerStore.resolveFileURL()
        fileURL = url
        isInICloud = cloud
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gratitude Ledger", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        backupURL = support.appendingPathComponent("entries-backup.json")
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 5
    }

    // MARK: Paths

    static func resolveFileURL() -> (URL, Bool) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let cloud = fm.fileExists(atPath: icloud.path)
        let base = cloud
            ? icloud.appendingPathComponent("Gratitude Ledger", isDirectory: true)
            : home.appendingPathComponent("Documents/Gratitude Ledger", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return (base.appendingPathComponent("entries.json"), cloud)
    }

    /// iCloud may have offloaded the file, leaving ".entries.json.icloud" behind.
    private var placeholderURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(".entries.json.icloud")
    }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            if fm.fileExists(atPath: placeholderURL.path) {
                // Ask iCloud to bring it back; hold off writing until it's here.
                try? fm.startDownloadingUbiquitousItem(at: fileURL)
                safeToWrite = false
                problem = "Your ledger is downloading from iCloud…"
            } else {
                entries = [:]
                safeToWrite = true
                problem = nil
            }
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LedgerFile.self, from: data)
            var map: [String: Entry] = [:]
            for e in file.entries { map[e.day] = e }
            entries = map
            lastModified = modificationDate()
            safeToWrite = true
            problem = nil
        } catch {
            safeToWrite = false
            problem = "Couldn't read entries.json, so nothing will be saved until it's fixed."
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Reload if the file changed on disk (e.g. synced from another Mac) and roll the day over.
    func refresh() {
        let newToday = JournalCalendar.todayKey()
        if newToday != todayKey { todayKey = newToday }
        if !safeToWrite || modificationDate() != lastModified { load() }
    }

    private func tick() {
        refresh()
        Reminder.shared.check(store: self)
        Updater.shared.checkIfDue()
    }

    // MARK: Queries

    var yesterdayKey: String { JournalCalendar.yesterdayKey() }

    func entry(_ key: String) -> Entry? { entries[key] }

    var isTodayWritten: Bool { entries[todayKey]?.hasText ?? false }

    var daysWritten: Int { entries.values.filter { $0.hasText }.count }

    func onThisDay() -> Entry? {
        guard let k = JournalCalendar.lastYearKey(from: todayKey), let e = entries[k], e.hasText else { return nil }
        return e
    }

    func matches(_ query: String) -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(entries.values.filter { e in
            e.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || e.emotions.contains { $0.emotion.label.lowercased() == q.lowercased() }
        }.map(\.day))
    }

    var years: ClosedRange<Int> {
        let thisYear = JournalCalendar.calendar.component(.year, from: JournalCalendar.journalDate())
        let first = entries.keys.compactMap { Int($0.prefix(4)) }.min() ?? thisYear
        return min(first, thisYear)...thisYear
    }

    func canEdit(_ key: String) -> Bool { key == todayKey || key == yesterdayKey }

    // MARK: Saving

    @discardableResult
    func save(day: String, text: String, emotions: [EmotionTag], animate: Bool) -> Bool {
        guard canEdit(day) else { return false }
        refresh()
        guard safeToWrite else { return false }
        let entry = Entry(day: day, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          emotions: emotions.filter { $0.intensity > 0 }, updatedAt: Date())
        if entries[day].map({ $0.text == entry.text && $0.emotions == entry.emotions }) == true {
            return true
        }
        var updated = entries
        if entry.isEmpty { updated.removeValue(forKey: day) } else { updated[day] = entry }
        guard write(updated) else { return false }
        entries = updated
        if animate {
            inkedKey = day
            inkToken += 1
        }
        return true
    }

    private func write(_ map: [String: Entry]) -> Bool {
        let file = LedgerFile(entries: map.values.sorted { $0.day < $1.day })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            try? data.write(to: backupURL, options: .atomic)
            lastModified = modificationDate()
            problem = nil
            return true
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func revealFile() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }
}
