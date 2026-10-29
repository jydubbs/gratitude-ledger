#!/bin/bash
# The Gratitude Ledger: installer.
# Builds a small menu-bar journal app on this Mac and starts it.
# Run with:  bash ~/Downloads/install-gratitude-ledger.sh
set -euo pipefail

APP_NAME="Gratitude Ledger"
EXEC="GratitudeLedger"
BUILD="a1ce8882ad0b"   # fingerprint of src/ and sounds/; the app compares it with VERSION on GitHub
BUNDLE_ID="com.gratitudeledger.app"
DEST="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

say() { printf '\n  %s\n' "$*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  say "This installer is for macOS."
  exit 1
fi

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then
  say "The Gratitude Ledger needs macOS 13 (Ventura) or newer. This Mac has $(sw_vers -productVersion)."
  exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "One-time step: Apple's free Command Line Tools are needed to build the app."
  say "A window will pop up. Click Install, wait for it to finish (a few minutes),"
  say "then run this same command again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/sounds"

say "Unpacking the ledger…"
cat > "$WORK/src/App.swift" <<'SWIFT_EOF'
import SwiftUI
import AppKit

@main
struct GratitudeLedgerApp: App {
    @StateObject private var store: LedgerStore

    init() {
        // If the ledger is already running (say, opened by hand while macOS also started it),
        // bow out quietly. Exit code 0 tells macOS not to restart this copy.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            exit(0)
        }
        Prefs.registerDefaults()
        _store = StateObject(wrappedValue: LedgerStore())
        Reminder.shared.start()
        // First update check shortly after launch, then once a day from the store's timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            Updater.shared.checkIfDue()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            LedgerView()
                .environmentObject(store)
        } label: {
            // Closed book until today's page is written, open afterwards.
            Image(systemName: store.isTodayWritten ? "book" : "book.closed")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Dates {
    static let long: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        return f
    }()

    static let short: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")
        return f
    }()

    static let month: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    static func long(_ key: String) -> String {
        JournalCalendar.date(fromKey: key).map { long.string(from: $0) } ?? key
    }

    static func short(_ key: String) -> String {
        JournalCalendar.date(fromKey: key).map { short.string(from: $0) } ?? key
    }
}

/// A horizontal dashed rule, like a ledger line.
struct DashedRule: View {
    var color: Color = Ink.rule
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}
SWIFT_EOF

cat > "$WORK/src/Models.swift" <<'SWIFT_EOF'
import Foundation

// MARK: - Emotions

enum Emotion: String, Codable, CaseIterable, Identifiable {
    case happy, excited, calm, grateful, tired, sad, anxious, angry

    var id: String { rawValue }
    var label: String { rawValue }

    /// Base ink colour (full strength) as 0xRRGGBB.
    var hex: UInt32 {
        switch self {
        case .happy:    return 0xD9A93A   // mustard
        case .excited:  return 0xC9763A   // burnt orange
        case .calm:     return 0x6E8A5E   // sage
        case .grateful: return 0xC48A8A   // dusty rose
        case .tired:    return 0x8C8478   // pencil grey
        case .sad:      return 0x3E5A7A   // ink blue
        case .anxious:  return 0xA8473A   // brick red
        case .angry:    return 0x6E2626   // oxblood
        }
    }
}

struct EmotionTag: Codable, Equatable {
    var emotion: Emotion
    /// 1 = mild, 2 = medium, 3 = strong
    var intensity: Int
    /// Tap order, used to break ties (first tapped wins).
    var order: Int
}

// MARK: - Entry

struct Entry: Codable, Equatable, Identifiable {
    /// Journal day key, "yyyy-MM-dd".
    var day: String
    var text: String
    var emotions: [EmotionTag]
    var updatedAt: Date

    var id: String { day }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { !hasText && emotions.isEmpty }

    /// The emotion that colours the square: highest intensity, ties go to the first tapped.
    var dominant: EmotionTag? {
        Entry.dominant(of: emotions)
    }

    static func dominant(of tags: [EmotionTag]) -> EmotionTag? {
        tags.filter { $0.intensity > 0 }.max { a, b in
            if a.intensity != b.intensity { return a.intensity < b.intensity }
            return a.order > b.order
        }
    }

    /// Emotions strongest first, for display.
    var sortedEmotions: [EmotionTag] {
        emotions.sorted { a, b in
            if a.intensity != b.intensity { return a.intensity > b.intensity }
            return a.order < b.order
        }
    }
}

struct LedgerFile: Codable {
    var version: Int = 1
    var entries: [Entry]
}

// MARK: - Journal days (a day ends at 4am)

enum JournalCalendar {
    static let cutoffHour = 4

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2 // Monday
        return c
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The calendar day this moment belongs to, treating 00:00–03:59 as the previous day.
    static func journalDate(for now: Date = Date()) -> Date {
        let shifted = now.addingTimeInterval(TimeInterval(-cutoffHour * 3600))
        return calendar.startOfDay(for: shifted)
    }

    static func key(for date: Date) -> String {
        keyFormatter.timeZone = .current
        return keyFormatter.string(from: date)
    }

    static func date(fromKey key: String) -> Date? {
        keyFormatter.timeZone = .current
        guard let d = keyFormatter.date(from: key) else { return nil }
        return calendar.startOfDay(for: d)
    }

    static func todayKey(now: Date = Date()) -> String {
        key(for: journalDate(for: now))
    }

    static func yesterdayKey(now: Date = Date()) -> String {
        let today = journalDate(for: now)
        let y = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return key(for: y)
    }

    /// Same month/day one year earlier (29 Feb maps to 28 Feb).
    static func lastYearKey(from key: String) -> String? {
        guard let d = date(fromKey: key),
              let prev = calendar.date(byAdding: .year, value: -1, to: d) else { return nil }
        return self.key(for: prev)
    }
}
SWIFT_EOF

cat > "$WORK/src/Store.swift" <<'SWIFT_EOF'
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
SWIFT_EOF

cat > "$WORK/src/Services.swift" <<'SWIFT_EOF'
import Foundation
import AVFoundation
import UserNotifications
import SwiftUI

// MARK: - Settings keys

enum Prefs {
    static let muted = "muted"
    static let reminderOn = "reminderOn"
    static let reminderMinutes = "reminderMinutes"   // minutes after midnight
    static let lastReminderDay = "lastReminderDay"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            muted: false,
            reminderOn: true,
            reminderMinutes: 21 * 60,
        ])
    }
}

// MARK: - Typewriter sounds

final class Typewriter {
    static let shared = Typewriter()

    private var clacks: [AVAudioPlayer] = []
    private var bell: AVAudioPlayer?
    private var next = 0

    private init() {
        for name in ["clack1", "clack2", "clack3"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            // Two players per sample so fast typing can overlap.
            for _ in 0..<2 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.volume = 0.45
                    p.prepareToPlay()
                    clacks.append(p)
                }
            }
        }
        if let url = Bundle.main.url(forResource: "bell", withExtension: "wav"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            p.volume = 0.6
            p.prepareToPlay()
            bell = p
        }
        clacks.shuffle()
    }

    private var muted: Bool { UserDefaults.standard.bool(forKey: Prefs.muted) }

    func clack() {
        guard !muted, !clacks.isEmpty else { return }
        let p = clacks[next % clacks.count]
        next += 1
        p.currentTime = 0
        p.play()
    }

    func ding() {
        guard !muted, let bell else { return }
        bell.currentTime = 0
        bell.play()
    }
}

// MARK: - Evening reminder

final class Reminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminder()

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Called every minute. Fires once per day, only if today is still blank.
    func check(store: LedgerStore) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Prefs.reminderOn) else { return }
        let today = store.todayKey
        guard !store.isTodayWritten, d.string(forKey: Prefs.lastReminderDay) != today else { return }

        let comps = JournalCalendar.calendar.dateComponents([.hour, .minute], from: Date())
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let target = d.integer(forKey: Prefs.reminderMinutes)
        // After the chosen time, but not in the small hours (those still belong to "today",
        // and a reminder after midnight would just be a nag).
        guard nowMinutes >= target, (comps.hour ?? 0) >= JournalCalendar.cutoffHour else { return }

        let content = UNMutableNotificationContent()
        content.title = "The Gratitude Ledger"
        content.body = "Today's page is still blank. What are you grateful for?"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "ledger-\(today)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        d.set(today, forKey: Prefs.lastReminderDay)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Theme

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Ink {
    static let paperHex: UInt32 = 0xF3E9D2
    static let paper = Color(hex: paperHex)
    static let paperShade = Color(hex: 0xEADCBD)
    static let spine = Color(hex: 0x5A3A1E)
    static let spineStitch = Color(hex: 0xA88A5C)
    static let ink = Color(hex: 0x3A2A18)
    static let inkSoft = Color(hex: 0x7A5F3A)
    static let rule = Color(hex: 0xB89A6A)
    static let emptyCell = Color(hex: 0xE3D6B8)
    static let writtenNoMood = Color(hex: mix(0xB89A6A, paperHex, 0.75))

    /// How much of the emotion's ink shows at each intensity.
    static let strengths: [Double] = [0.45, 0.72, 1.0]

    static func hex(_ emotion: Emotion, intensity: Int) -> UInt32 {
        let i = max(1, min(3, intensity))
        return mix(emotion.hex, paperHex, strengths[i - 1])
    }

    static func color(_ emotion: Emotion, intensity: Int) -> Color {
        Color(hex: hex(emotion, intensity: intensity))
    }

    /// Text that sits on top of an inked chip: paper on dark inks, ink on light ones.
    static func textOn(_ hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 150 ? paper : ink
    }

    static func cellColor(for entry: Entry?) -> Color {
        guard let entry, !entry.isEmpty else { return emptyCell }
        if let dom = entry.dominant { return color(dom.emotion, intensity: dom.intensity) }
        return writtenNoMood
    }

    /// Blend `a` over `b` with weight `t` (1 = all a).
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func m(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * t + ch(b, s) * (1 - t)).rounded()) }
        return (m(16) << 16) | (m(8) << 8) | m(0)
    }

    // Fonts that ship with every Mac.
    static func typed(_ size: CGFloat) -> Font { .custom("American Typewriter", size: size) }
    static func typedCondensed(_ size: CGFloat) -> Font { .custom("AmericanTypewriter-Condensed", size: size) }
    static func serif(_ size: CGFloat) -> Font { .custom("Hoefler Text", size: size) }
    static func serifItalic(_ size: CGFloat) -> Font { .custom("HoeflerText-Italic", size: size) }
}
SWIFT_EOF

cat > "$WORK/src/Updater.swift" <<'SWIFT_EOF'
import Foundation
import AppKit

/// Checks GitHub about once a day for a newer build and, on request, runs the installer.
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Where updates come from. A fork would change this one line.
    static let repoRaw = "https://raw.githubusercontent.com/jydubbs/gratitude-ledger/main"

    enum State: Equatable {
        case idle
        case upToDate               // only shown after a manual check
        case available
        case updating
        case failed
    }

    @Published private(set) var state: State = .idle

    /// The fingerprint baked into this build by the installer ("unknown" for builds made before updates existed).
    let currentBuild: String =
        (Bundle.main.object(forInfoDictionaryKey: "GLBuildHash") as? String) ?? "unknown"

    let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gratitude Ledger update.log")

    private let lastCheckKey = "lastUpdateCheck"
    private let checkEvery: TimeInterval = 24 * 3600

    /// Called every minute; only actually checks once a day.
    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last >= checkEvery { check(manual: false) }
    }

    func check(manual: Bool) {
        guard state != .updating, let url = URL(string: Self.repoRaw + "/VERSION") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let remote = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                // Offline or odd reply: stay quiet and try again tomorrow.
                guard ok, !remote.isEmpty, remote.count <= 64 else { return }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                if remote != self.currentBuild {
                    self.state = .available
                } else {
                    self.state = manual ? .upToDate : .idle
                }
            }
        }.resume()
    }

    /// Runs the same install command as the README. The installer quits this app,
    /// replaces it and opens the new one; the journal file in iCloud is untouched.
    func runUpdate() {
        state = .updating
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: Data("Update started \(Date())\n".utf8))
        guard let log = try? FileHandle(forWritingTo: logURL) else { state = .failed; return }
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -o pipefail; curl -fsSL '\(Self.repoRaw)/install-gratitude-ledger.sh' | bash"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] proc in
            // On success the installer has already quit this app, so reaching here means it stopped early.
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 { self?.state = .failed }
            }
        }
        do {
            try process.run()
        } catch {
            log.write(Data("Couldn't start the installer: \(error.localizedDescription)\n".utf8))
            state = .failed
        }
    }

    func dismissMessage() {
        if state == .upToDate || state == .failed { state = .idle }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    /// Short form shown in settings.
    var editionLabel: String {
        currentBuild == "unknown" ? "first edition" : "edition \(currentBuild.prefix(7))"
    }
}
SWIFT_EOF

cat > "$WORK/src/LedgerView.swift" <<'SWIFT_EOF'
import SwiftUI
import AppKit

enum PageChoice: Hashable { case today, yesterday }

struct LedgerView: View {
    @EnvironmentObject var store: LedgerStore
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.muted) private var muted = false
    @AppStorage(Prefs.reminderOn) private var reminderOn = true
    @AppStorage(Prefs.reminderMinutes) private var reminderMinutes = 21 * 60

    @State private var page: PageChoice = .today
    @State private var draft = ""
    @State private var tags: [EmotionTag] = []
    @State private var loadedKey = ""
    @State private var suppressClack = false
    @State private var showSettings = false
    @State private var year = JournalCalendar.calendar.component(.year, from: JournalCalendar.journalDate())
    @State private var query = ""
    @State private var hovered: String?
    @State private var pinned: String?
    @FocusState private var writing: Bool

    private let maxChars = 1000

    private var dayKey: String { page == .today ? store.todayKey : store.yesterdayKey }
    private var saved: Entry? { store.entry(dayKey) }
    private var cleanDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { cleanDraft != (saved?.text ?? "") }

    var body: some View {
        HStack(spacing: 0) {
            spine
            VStack(alignment: .leading, spacing: 14) {
                header
                updateBanner
                if showSettings { settings }
                writingPage
                DashedRule()
                history
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 520)
        .background(Ink.paper)
        .foregroundColor(Ink.ink)
        .tint(Ink.spine)
        .environment(\.colorScheme, .light)
        .onAppear {
            store.refresh()
            loadDraft(force: true)
            writing = true
        }
        .onDisappear { commit(ding: false) }
        .onChange(of: dayKey) { _ in loadDraft(force: true) }
        .onChange(of: store.entries) { _ in loadDraft(force: false) }
    }

    // MARK: Spine

    private var spine: some View {
        Ink.spine
            .frame(width: 14)
            .overlay(
                Canvas { ctx, size in
                    var y: CGFloat = 10
                    while y < size.height - 8 {
                        let r = CGRect(x: size.width / 2 - 1, y: y, width: 2, height: 5)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(Ink.spineStitch))
                        y += 12
                    }
                }
            )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The Gratitude Ledger")
                    .font(Ink.serif(23))
                Text(Dates.long(dayKey))
                    .font(Ink.typed(11))
                    .foregroundColor(Ink.inkSoft)
            }
            Spacer()
            pageButton("today", .today)
            pageButton("yesterday", .yesterday)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(showSettings ? Ink.ink : Ink.inkSoft)
                    .padding(.leading, 6)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private func pageButton(_ label: String, _ choice: PageChoice) -> some View {
        Button { switchPage(to: choice) } label: {
            Text(label)
                .font(Ink.typed(11))
                .foregroundColor(page == choice ? Ink.ink : Ink.inkSoft.opacity(0.75))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(alignment: .bottom) {
                    if page == choice { Rectangle().fill(Ink.ink).frame(height: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice == .yesterday ? "Missed a day? You can still fill in yesterday." : "Today's page")
    }

    private func switchPage(to choice: PageChoice) {
        guard choice != page else { return }
        commit(ding: false)
        page = choice
        writing = true
    }

    // MARK: Updates

    @ViewBuilder
    private var updateBanner: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .available:
            banner(icon: "envelope", message: "a new edition of the ledger is available") {
                Button("update") {
                    commit(ding: false)
                    updater.runUpdate()
                }
            }
        case .updating:
            banner(icon: "hourglass", message: "updating… the ledger will close and reopen in about a minute") {
                ProgressView().controlSize(.small)
            }
        case .upToDate:
            banner(icon: "checkmark", message: "you have the latest edition") {
                Button("ok") { updater.dismissMessage() }
            }
        case .failed:
            banner(icon: "exclamationmark.triangle", message: "the update didn't finish. Your entries are safe.") {
                HStack(spacing: 6) {
                    Button("show log") { updater.revealLog() }
                    Button("try again") { updater.runUpdate() }
                }
            }
        }
    }

    private func banner<Trailing: View>(icon: String, message: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(message)
            Spacer(minLength: 6)
            trailing()
        }
        .font(Ink.typed(11))
        .foregroundColor(Ink.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 4).fill(Ink.paperShade))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.rule, lineWidth: 0.8))
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("typewriter sounds", isOn: Binding(get: { !muted }, set: { muted = !$0 }))
            HStack(spacing: 8) {
                Toggle("evening reminder if the page is blank, at", isOn: $reminderOn)
                DatePicker("", selection: reminderTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 80)
                    .disabled(!reminderOn)
            }
            HStack {
                Text(store.isInICloud ? "kept in iCloud Drive › Gratitude Ledger" : "kept in Documents › Gratitude Ledger")
                    .foregroundColor(Ink.inkSoft)
                Spacer()
                Button("show file") { store.revealFile() }
                Button("quit") { NSApp.terminate(nil) }
            }
            HStack {
                Text(updater.editionLabel)
                    .foregroundColor(Ink.inkSoft)
                Spacer()
                Button("check for updates") { updater.check(manual: true) }
                    .disabled(updater.state == .updating)
            }
        }
        .toggleStyle(.checkbox)
        .font(Ink.typed(11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 4).fill(Ink.paperShade))
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(TimeInterval(reminderMinutes * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminderMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 0)
            }
        )
    }

    // MARK: Writing

    private var writingPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // Fixed-height page that scrolls, so long days never squash the layout.
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(page == .today ? "Today I am grateful for…" : "Yesterday I was grateful for…")
                            .font(Ink.typed(15))
                            .foregroundColor(Ink.inkSoft.opacity(0.55))
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(Ink.typed(15))
                        .foregroundColor(Ink.ink)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($writing)
                        .onChange(of: draft) { new in typed(new) }
                }
                .frame(height: 76)
                DashedRule(color: Ink.rule.opacity(0.7))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Emotion.allCases) { e in
                    EmotionChip(emotion: e, intensity: intensity(of: e)) { tap(e) }
                }
            }

            HStack(alignment: .center) {
                pageColourLine
                Spacer()
                sealButton
            }

            if let problem = store.problem {
                Text(problem)
                    .font(Ink.typed(10))
                    .foregroundColor(Color(hex: 0xA8473A))
            }
        }
    }

    private var pageColourLine: some View {
        HStack(spacing: 6) {
            if let dom = Entry.dominant(of: tags) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Ink.color(dom.emotion, intensity: dom.intensity))
                    .frame(width: 9, height: 9)
                Text("page coloured \(dom.emotion.label), \(["mild", "medium", "strong"][dom.intensity - 1])")
            } else {
                Text("tap a feeling to colour the page · tap again to deepen")
            }
        }
        .font(Ink.typed(10))
        .foregroundColor(Ink.inkSoft)
    }

    private var sealButton: some View {
        let done = !isDirty && (saved?.hasText ?? false)
        return Button { commit(ding: true) } label: {
            Text(done ? "sealed" : "seal the page ↵")
                .font(Ink.typed(12))
                .foregroundColor(isDirty ? Ink.paper : Ink.inkSoft)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 3).fill(isDirty ? Ink.spine : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.rule, lineWidth: isDirty ? 0 : 0.8))
        }
        .buttonStyle(.plain)
        .disabled(!isDirty)
    }

    private func intensity(of e: Emotion) -> Int {
        tags.first { $0.emotion == e }?.intensity ?? 0
    }

    /// Cycles off → mild → medium → strong → off, and saves straight away.
    private func tap(_ e: Emotion) {
        var t = tags
        if let i = t.firstIndex(where: { $0.emotion == e }) {
            if t[i].intensity >= 3 { t.remove(at: i) } else { t[i].intensity += 1 }
        } else {
            t.append(EmotionTag(emotion: e, intensity: 1, order: (t.map(\.order).max() ?? 0) + 1))
        }
        tags = t
        Typewriter.shared.clack()
        // Keep the sealed sentence; the draft is only sealed with the button or Return.
        store.save(day: dayKey, text: saved?.text ?? "", emotions: t, animate: true)
    }

    private func typed(_ new: String) {
        // Return seals the page rather than starting a new line.
        if new.contains("\n") {
            suppressClack = true
            draft = new.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            commit(ding: true)
            return
        }
        if new.count > maxChars {
            draft = String(new.prefix(maxChars))
            return
        }
        if suppressClack {
            suppressClack = false
            return
        }
        Typewriter.shared.clack()
    }

    private func commit(ding: Bool) {
        guard isDirty else { return }
        if store.save(day: dayKey, text: draft, emotions: tags, animate: true), ding {
            Typewriter.shared.ding()
        }
    }

    private func loadDraft(force: Bool) {
        let key = dayKey
        let entry = store.entry(key)
        tags = entry?.emotions ?? []
        // Don't throw away words being typed when the file refreshes.
        if !force && key == loadedKey && isDirty { return }
        let text = entry?.text ?? ""
        if text != draft {
            suppressClack = true
            draft = text
        }
        loadedKey = key
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .disabled(year <= store.years.lowerBound)
                    .opacity(year <= store.years.lowerBound ? 0.3 : 1)
                Text(String(year))
                    .font(Ink.typed(14))
                Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(year >= store.years.upperBound)
                    .opacity(year >= store.years.upperBound ? 0.3 : 1)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(Ink.inkSoft)
                    TextField("", text: $query,
                              prompt: Text("search the ledger").foregroundColor(Ink.inkSoft.opacity(0.55)))
                        .textFieldStyle(.plain)
                        .font(Ink.typed(11))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .foregroundColor(Ink.inkSoft)
                    }
                }
                .frame(width: 180)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 0.8) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Ink.ink)

            YearGrid(year: year, query: query, hovered: $hovered, pinned: $pinned)

            readingLine
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .topLeading)

            legend

            Text("\(store.daysWritten) \(store.daysWritten == 1 ? "day" : "days") of gratitude")
                .font(Ink.typed(11))
                .foregroundColor(Ink.inkSoft)
        }
    }

    /// What sits under the grid: a hovered page (preview), a clicked page (stays open, scrolls),
    /// search results, or "on this day".
    @ViewBuilder
    private var readingLine: some View {
        if let key = hovered, key != pinned {
            pageView(key, open: false)
        } else if let key = pinned {
            pageView(key, open: true)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchSummary
        } else if let otd = store.onThisDay() {
            VStack(alignment: .leading, spacing: 3) {
                Text("on this day, \(String(otd.day.prefix(4)))")
                    .font(Ink.typed(11))
                    .foregroundColor(Ink.inkSoft)
                Text("“\(otd.text)”")
                    .font(Ink.serifItalic(14))
                    .lineLimit(3)
            }
        } else {
            Text("hover over a square to peek · click it to keep the page open")
                .font(Ink.typed(11))
                .foregroundColor(Ink.inkSoft)
        }
    }

    private func pageView(_ key: String, open: Bool) -> some View {
        let entry = store.entry(key)
        let hasText = entry?.hasText ?? false
        let words = Text(hasText ? "“\(entry?.text ?? "")”" : "a blank page")
            .font(Ink.serifItalic(14))
            .foregroundColor(hasText ? Ink.ink : Ink.inkSoft)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Dates.short(key))
                    .foregroundColor(Ink.inkSoft)
                ForEach(entry?.sortedEmotions ?? [], id: \.emotion) { tag in
                    Text("\(tag.emotion.label) \(String(repeating: "•", count: tag.intensity))")
                        .foregroundColor(Color(hex: Ink.hex(tag.emotion, intensity: 3)))
                }
                Spacer()
                if open {
                    Button { pinned = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Ink.inkSoft)
                    .help("Close this page")
                } else if hasText {
                    Text("click to open")
                        .foregroundColor(Ink.inkSoft.opacity(0.7))
                }
            }
            .font(Ink.typed(11))
            if open {
                ScrollView(.vertical) {
                    words
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                        .textSelection(.enabled)
                }
            } else {
                words.lineLimit(3)
            }
        }
    }

    private var searchSummary: some View {
        let found = store.matches(query)
        let byYear = Dictionary(grouping: found, by: { String($0.prefix(4)) })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 > $1.0 }
        let detail = byYear.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
        return Text(found.isEmpty
                    ? "no pages mention “\(query)”"
                    : "\(found.count) \(found.count == 1 ? "page" : "pages") found  —  \(detail)")
            .font(Ink.typed(11))
            .foregroundColor(Ink.inkSoft)
    }

    private var legend: some View {
        HStack(spacing: 9) {
            ForEach(Emotion.allCases) { e in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Ink.color(e, intensity: 3))
                        .frame(width: 7, height: 7)
                    Text(e.label)
                }
            }
        }
        .font(Ink.typed(9.5))
        .foregroundColor(Ink.inkSoft)
    }
}

// MARK: - Emotion chip

struct EmotionChip: View {
    let emotion: Emotion
    let intensity: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let fillHex = Ink.hex(emotion, intensity: max(1, intensity))
        let textColor = intensity > 0 ? Ink.textOn(fillHex) : Ink.ink
        return Button(action: action) {
            HStack(spacing: 4) {
                Text(emotion.label)
                    .font(Ink.typed(12))
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    ForEach(1...3, id: \.self) { i in
                        Circle()
                            .fill(i <= intensity ? textColor : Color.clear)
                            .overlay(Circle().stroke(textColor.opacity(0.6), lineWidth: 0.7))
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(intensity > 0 ? Color(hex: fillHex) : (hover ? Ink.paperShade : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(intensity > 0 ? Color.clear : Ink.rule, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Click to deepen: mild → medium → strong → off")
        .animation(.easeOut(duration: 0.25), value: intensity)
    }
}
SWIFT_EOF

cat > "$WORK/src/YearGrid.swift" <<'SWIFT_EOF'
import SwiftUI

/// A GitHub-style contribution grid for one calendar year, Monday-first rows.
struct YearGrid: View {
    @EnvironmentObject var store: LedgerStore
    let year: Int
    let query: String
    @Binding var hovered: String?
    /// The day clicked open; stays shown until clicked again or closed.
    @Binding var pinned: String?

    /// 0 → 1 drives the ink-soaking-in animation on the most recently inked square.
    @State private var ink: CGFloat = 1

    private let cell: CGFloat = 7
    private let gap: CGFloat = 1.5
    private let labelWidth: CGFloat = 14
    private let rowLabels: [String] = ["M", "", "W", "", "F", "", ""]

    struct Column: Identifiable {
        let id: Int
        let days: [String?]     // 7 day keys, Monday first
        let monthLabel: String?
    }

    private var columns: [Column] {
        let cal = JournalCalendar.calendar
        guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)) else { return [] }
        let lead = (cal.component(.weekday, from: jan1) + 5) % 7   // weekday 1 = Sunday → Monday = 0
        var cols: [Column] = []
        var current: [String?] = Array(repeating: nil, count: lead)
        var label: String? = nil
        var d = jan1
        while cal.component(.year, from: d) == year {
            // Label a month over the first week that starts (on a Monday) inside it.
            if current.isEmpty && cal.component(.day, from: d) <= 7 { label = Dates.month.string(from: d) }
            current.append(JournalCalendar.key(for: d))
            if current.count == 7 {
                cols.append(Column(id: cols.count, days: current, monthLabel: label))
                current = []
                label = nil
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        if !current.isEmpty {
            current += Array(repeating: nil, count: 7 - current.count)
            cols.append(Column(id: cols.count, days: current, monthLabel: label))
        }
        return cols
    }

    var body: some View {
        let cols = columns
        let today = store.todayKey
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let found = store.matches(query)

        return VStack(alignment: .leading, spacing: 3) {
            // Month names
            HStack(alignment: .top, spacing: gap) {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(cols) { col in
                    Text(col.monthLabel ?? "")
                        .font(Ink.typed(9))
                        .foregroundColor(Ink.inkSoft)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            .frame(height: 11)

            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(rowLabels[row])
                            .font(Ink.typed(8))
                            .foregroundColor(Ink.inkSoft)
                            .fixedSize()
                            .frame(width: labelWidth, height: cell, alignment: .leading)
                    }
                }
                ForEach(cols) { col in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let key = col.days[row] {
                                square(for: key, today: today, dim: searching && !found.contains(key))
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                    .zIndex(col.days.contains(where: { $0 != nil && $0 == store.inkedKey }) ? 1 : 0)
                }
            }
            .onHover { inside in if !inside { hovered = nil } }
        }
        .onChange(of: store.inkToken) { _ in
            ink = 0
            withAnimation(.easeOut(duration: 1.3)) { ink = 1 }
        }
    }

    private func square(for key: String, today: String, dim: Bool) -> some View {
        let entry = store.entry(key)
        let future = key > today
        let inked = key == store.inkedKey
        let spread = 1 - ink
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(future ? Ink.emptyCell.opacity(0.4) : Ink.cellColor(for: entry))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(outline(key, today: today), lineWidth: key == pinned ? 1.6 : (key == today ? 1 : 0.8))
            )
            .opacity(dim ? 0.18 : 1)
            // Ink soaking into the paper: starts big, faint and blurred, settles into the square.
            .scaleEffect(inked ? 1 + spread * 1.8 : 1)
            .opacity(inked ? Double(0.15 + 0.85 * ink) : 1)
            .blur(radius: inked ? spread * 2.5 : 0)
            .zIndex(inked ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = key } else if hovered == key { hovered = nil }
            }
            .onTapGesture {
                pinned = (pinned == key) ? nil : key
            }
    }

    private func outline(_ key: String, today: String) -> Color {
        if key == pinned { return Ink.spine }
        if key == today { return Ink.ink }
        if key == hovered { return Ink.inkSoft }
        return .clear
    }
}
SWIFT_EOF

base64 --decode > "$WORK/sounds/clack1.wav" <<'B64_EOF'
UklGRiYfAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQIfAACGAjEQBBwODPnsIuuD
9g71qfXe+Pn0AfCo61zk7eMg9ZwTjynWKIYe9B/SLRZCulqhUAcSC+U3+LkpDVFlZu9g7jRJE7Af
LzPnLZcOjvIk/F4WGCD3IkgoayqiLl01OzS3LcMvbTYpLvocFRZYGkIg+SLXKGwn0hmYFoYjRi2t
JVUbJx5IJ6cxOzEDIFQZ5iCzG6sNswnyDBcLlvkN5Gzi4PVuD8QYIAwsB30cjjOgNvQwny8qMpsy
2CpOHXoWLhPPCX0JABNRGtchpyr9MiQ2IzbiNPcodhEmBSsQ6hnTFZsPgw7dEV8STwznBqQGNwmK
EsIYLAnW9cT+jRSoEvAAhfay8ify4fZ9/WIAyf9h+z71c/I+9K34HPru/BkFrAbo/pD07+nE42Xk
ROSs4SjiA+Lq3wPiLOy+9gz2ZOtq4L/g0uiZ6ZDih91W3RrgIuIk3CbR68spz4bWEd3J3VnbCd2y
3t3eLuQ+6wfs6OXh4vfpUu7758Hi5uQC6xjzLvtEAer9y/Dy5g3nqu5i9YH0+e9d8NDwuOkf4YXc
WNtl3hrkpOS94BfdFdnO1TfVDNcK2uneKuXD6qnubPGQ86bzxvGS7//tv+5r8fXx4vBL8UPxTe12
6EPp8uz27lrwHfAU7z7w7/K7807zRPRv8jXutuxT7QnuYu7L74HyNfYj+8r+DwGSBHcIDwoSCroJ
EAh2ByYJygonDGgNCQ0fCjwH/wTDBDcIxgjtBNMBu/4p++r6kPz4+4b6JPq4+0kAgwX2CPELNBC3
FQgbzx1QHb8ahRdQFdMVIhemFZcSShFiEkkVTBmpHUYhmyKCIvsh7CBGH/UbGhjqFcsUSBSFFKQV
Ohh+GrgaExo9GvoaFBvpGggbOBu/G8cbKRp8F2EVKhVWFlMYTBlDGDUYiRqRHVwfCiCuIKAgnh4+
G5cYcBdGFjgVhBaaGRUcNh1CHcYcWhzjG5obsxomGJUVnRTfFJUUARP1EWYSWhKGEPwOqg7XDegM
RA2JDQUMIQnoBVwCJ/72+SP2RPNS8rXyoPKP8fDwIvFL8Tvx5vBy8Fjwwu8J7uPry+ms6N7pduxw
7hnwK/LI9Hz3M/nX+kT9P/8wALEAFwGEAPz+5v1P/Z781/tb+xP7Zfp0+WD45vYZ9R3z4PBI7kfr
rOf641fhKuD73yzg3OB/4tHkb+fJ6cfqD+pw6PLmFOZL5d7j8+E/4HDfzN/u4CziHePP46fkIOXd
5IvkKOSC49/igeK54oTjJOWf5xHqAez/7bfwf/Ne9V/2zvbq9gr3TPdG9472PPW7877ygPK/8k7z
KvRu9YH2s/ZE9rT1L/Wo9Gv0l/QU9Q/2F/fd9/X4yfoh/XD/QAGJAl0D+gMbBEIDsQHv/1T+2Pxw
+1X6AfrP+rz8Z//TAYIDBAWgBgwIewkPC2EM8gybDIgLNgpeCRQJ6wizCHgIPQgvCKcIgwlECpgK
iQrCCokLIAwJDHwLNQu3C78M3w3SDrEPjhAsEWIR/BDpD5IOUA0/DHwL0wpeCugKWwziDVkPBRHg
ErQUuhYqGX0bQR1wHuMeQB7HHAIb/xjPFrwU8xJuES0QJw9BDoEN2AxzDJIMCg2bDScOqw4tD5MP
DBC/EFwRqhG5EfwRlxIVE1ATaBNOE8US0RG+EMIP3A63DR8MhQpWCWYIcAdoBnoFoQSYA5gCBgLL
AasBQAFaAJP/VP9d/zP/2f7g/jH/Zv+H/6//KQD5AKQB3wF+AZIApf8Z/8j+fv5Y/oT+5f4z/5T/
MADYAEUBQgHDAPz/P/+K/rr9w/yI+xD6c/i39hb1rfM+8tLwp++67uPtGu1M7EXrFurP6KrnG+cz
56jnaOib6Rfrt+yJ7nPwA/Lo8lbzYfPU8t3xAPFb8NHveO9G7yvvOO9R74Lvze/n79Dvtu+I70Xv
/e697pfudO5N7mnuFe9I8NnxxPPB9Yj3Vvk6+6H8Sf2N/Yr97fyi+wj6bfj09s31F/XC9J70ZPQU
9Mnzf/NF8yjzG/MV8//ywPKk8vfytfPo9Gr2/Pew+Y77N/15/oX/cAACAQEBpgAsAIz/0/44/tT9
0f1T/gz/ov8KAEMAXQCnACUBjwHOAdEBfAHkAGMAVgDOAKEBtgIoBNIFXge9COAJjQqoClQKzAk8
CccIbgj6B1EHtQZjBj4GQwbABr8H+ggiCucKQwtyC4oLfwtKCxILBAsMCzoLpAstDM8Mlw1UDsMO
9A4VDzUPNg8PD+wO5A4BD0cPmw/hDyoQjhAIEYkR8RErEiUSxxEkEV8Qdw9nDicNvAt8CqwJKQnf
CNoIAAkoCSkJDAkFCRkJNwlPCUQJBgmSCPYHaAckByAHKwdPB5IH6QdQCKcI1wjFCEUIWgdRBngF
2wRaBNsDagMsAxYD/QLgAuoCMAN7A60D0wPjA88DmANbAxADpAInAqcBLwHZAJoAMgCl/yH/w/6c
/on+Uf72/av9i/1y/Tn9+Pyo/DX8w/th+/b6cPrR+SD5YPiM97T27PUy9WL0ZvNi8snxyvH98Uvy
6vLV8+v0A/b99rP3DPgN+ML3JPcM9pz0N/Mo8oLxJPHy8PfwN/GP8Qbye/K18tLy9vIG8+7yxvKs
8rjy4fIJ8y/zavPJ8z70tfQm9Y/19/VV9n72cPZP9hL2uvVs9Tv1HvUK9RD1U/XD9S/2fPbM9kv3
4PdY+Lj4AfkZ+Rn5O/l5+aX50vkv+rn6U/v3+7X8kP1m/gL/R/8y/8z+Nv6b/Qr9kvxE/Dz8jvw0
/RP+C/8IAOsAiwHmARoCTAKDArIC0ALKAssCBgNPA4ADvgNDBPgEmAXzBfsF5gXMBZIFVgU8BTsF
OwVLBYkF8QVuBuwGXAe9BxUIXwh6CEIIzAdUB/AGhgYXBsYFvQUCBnQG8gZ1BwMImAgfCZUJ/wk+
CjoKAgqrCVwJNAkhCQ0J7gjsCDUJqwkQClsKpAroCh8LPAsfC9cKiQo5CtsJfQk3CQQJzgieCIUI
jAi3CN4I9QggCVkJYQkSCYAIvwf3Bl8G/QXFBbcFzwX3BTAGiQb7BnMH2gciCEwIYAhjCD8I4AdJ
B5AG0AUIBUMErgNJA/ACrAJvAhcCowE3Ae0AuQCKAFYAKgAHANj/ov9u/zH/7f6l/mf+QP4q/hL+
4v2L/Q/9fPzi+1H71vpn+gf6zvmu+Y35dPlw+YH5svn5+Tn6d/qp+qz6dvox+vr5vvlw+Sn5A/kS
+U/5oPnq+Rf6L/o/+j/6Ivrb+XH59/h4+Bb46/fq9xL4ZvjJ+B75Zfms+f35XPqr+sL6vfq7+qz6
ffo3+u/5pvld+R756fiy+Hr4Tfgl+Pj3xvec94T3ffd390n3/vbK9rP2q/au9sH28fY693X3j/ej
97v3wPeo9433jve09//3bvj1+Hv58/le+q766/o5+6D7/Psr/Dv8Rvxp/ML8Rv3d/YH+Ff+X/xUA
fgDUACgBcgG0AeQB9QH3AfoB9QHhAcABhwFMATABQQFxAZwBuQHRAeMB+AEVAjMCWgKVAsUC7AIq
A4ED6gNhBNMEPwW0BSMGZwZ8BnkGYAYsBugFnQVYBSkFEAUABfwEBAUWBTcFYAWIBZ8FoQWwBdkF
/gULBgcG+AXiBdYF5AUFBjMGdQa1BtkG6QbvBukG1ga5BqAGiQZxBl4GSAY2BjoGVAZ/BrkG8gYf
BzsHQgcpB/QGrgZfBhwG7gXTBcoFxQWvBZIFfQVqBVgFUQVMBToFJAUXBRQFEwUNBRAFJgVEBWMF
dAVfBTcFDgXcBKcEfARWBCkE8AOwA2cDCQOXAioC0gGHATsB9QC9AIkAVAAnAAAAz/+L/0D/6/5+
/gD+hP0S/bj8iPyA/Jj8xPz9/Dz9av18/Xv9cf1f/Tz9Cf3L/ID8Lvzi+6T7eftf+0f7L/ss+zn7
Ofsg++D6ffof+uH5ufmf+ZX5m/mr+bv50/n7+ST6Qvpl+pb60PoF+yj7M/sn+wz74fqp+nL6Svo2
+kP6b/qq+uz6K/th+4j7lvuP+3b7Pvvu+pf6SvoK+tn5xPnR+en5//kV+jL6V/p8+pX6nfqf+pz6
ivpv+lj6TfpP+mb6ifqx+uX6Jft4+9P7Hvxj/LT8Cv1S/Yn9s/3G/cf9yf3Q/d/98f0N/tcAbwRq
Akn8YvQy7QfuVPfIAVII9QoZD0wV6RWOES0JGflq6ZLjsuk79w0BYQZyCtMKaQpCCs4I0ggoCXIG
OQAI/L/9Iv/f/RH9Mf4qAKUA7QHyAzADgQBj/on/2ALJBikK/glfCLwG0gMWAW8BTgKfAOD/kALL
BeYGzwf0CV8KdQeZAm38kPm+/CMD/wnfDRYO0wy7Ck4I5gb4BVUFUwVQBHUBtP5w/gUBAgM8Aen/
qgLEBrsJ2ArZCpQJdwdUB3UI1wboAXL+wP/wAvwCBwB1/50Cvwb3CTAL+wlbBvsCfwE3AogF+AYg
BBMAFv2q/N7+zAHQA/8DLgOlAh4CJQGQABsAkv9qAMEBVgItA+kDiQMzA3ADAgOOAaD/bP7U/lf/
FP43/Ff8Nf5DAKcBEAIaArcBeADl/tH9jv1z/T79Rf0t/dz8BP2T/ZH9PP1g/UD9Q/xR+5r7M/3F
/rL+5fxq+5H7SPyB/Cj8bPvi+pr6gvrc+lz7mfu9+5n8eP0K/bj7svpk+gv6sPky+jn7sfvY+x/8
+/tv+wD79fp2+yf8mfyp/DX8qPuZ+9X7+vs1/HD8T/zX+5j7yPse/Hz8TPys+5T75vsa/Cf8N/ww
/Mz7ivvw+3X8uvzQ/NP84vzD/J/87PyW/SL+S/4+/jD+Cf6c/T/9Lf0l/V79Ov5C/8n/vv+T/87/
RwBoACkAw/9t/y//2/64/gP/Uf+F/yAA0ADtALoAiABEABAAOQCGALEA0wDtAP0A4wDCAO0AJQH4
AHUAGQAbAEEAgADlADMBVAGFAeABOwJLAg4C3wHtASMCeALwAlYDcgNUAyoDLAN7A8kDvgOIA4oD
vQPNA8EDsQOUA5oD2QP5A8oDkwOOA5cDiQOFA4kDcwNbA1wDYwN/A7kDywOVA1IDOgNaA5gDygPF
A34DKwP8AtgCpgKQAqgCzQLpAgMDJAM5A0MDVgNpA3wDiAN1A1ADMgMRA/IC1gK+ArsCuQKmApMC
kgKlAqkCjwKDAowCgwJXAiEC9QHGAYcBQQEVAQkBDgEYAR8BIwEhAQIB1ACuAI4AewB4AGsASgAg
AP//8P/8/xcAMgBFAFQAUgA5ABEA4P+n/3b/UP8l/+7+rf5z/k7+Nv4g/v/92v23/Zn9hP11/XP9
fv2B/XT9aP1t/X39jP2h/cD93f3x/fv99/3u/eL91/3H/a39kv1w/T39C/3l/MH8ovyL/Hn8a/xX
/D/8Mfwz/EL8UPxd/GP8XfxP/D78M/w5/FP8efya/Lj82/wB/Sv9Vf1u/Wz9Wv1K/UT9QP0//Ur9
X/11/Yn9nv2z/cL9xv3C/cT91P3r/QP+G/4s/i/+Kv4g/hP+DP4N/hD+Fv4i/jj+VP5w/oP+k/6o
/rf+vP66/rn+v/7G/sn+0v7m/gL/Jf9K/3D/k/+z/9H/7/8MACkARgBgAHoAkwCoALsA0QDtAAsB
KgFGAV8BdQGJAZQBmgGcAZYBjAGEAX4BfAGAAYoBmAGpAbkBwQHEAcoB0wHaAdcByQG4AbMBvgHT
Ae0BCQIlAj8CWQJyAoQCkAKYApoClwKUApUCmgKlArUCxALPAtkC5QL2AgYDFAMeAygDMAMzAzED
LgMqAyIDFgMNAwYDBAMJAw8DDgMHA/8C8wLeAsMCowJ8AlACJgIBAuUBzwHAAbUBsAGsAakBpAGg
AZsBkgGHAXgBYwFIASkBCgHyAOMA2QDPAMQAuQCxALAAtQC4ALgAsgCoAJ8AmQCVAI8AiACCAHgA
awBeAFIARgA5ACoAGQAFAPD/2v/F/7L/of+U/4f/ef9q/1v/S/87/y3/Iv8e/x//Hf8Y/w7/AP/u
/tv+xf6t/pX+gv5x/l7+Rv4o/gr+7/3a/cv9wf27/bL9p/2h/aH9pP2n/a/9vP3M/dX91/3a/d79
4v3h/d793P3c/dr92P3W/dD9xv26/a/9qf2n/an9q/2u/a79qP2c/Y79f/1x/Wf9Yf1g/V/9YP1q
/X39lP2t/cb94P35/Q/+I/4y/j7+R/5R/l3+bf5+/o7+nP6p/rP+vP7D/sj+0P7Z/uL+7f78/g//
I/84/0z/YP9y/4b/m/+v/8D/zv/b/+j/8//6/wEACQAOABQAGAAdACQAKAArACwAMgA/AE4AWwBn
AHYAhQCTAKEArgC2ALsAwADGAMwA1wDoAP0AEAEgAS8BOAE6ATcBMAEmAR0BFQEQARABEgEVARsB
JgE0AUIBUgFjAXMBgwGSAaABrQG8AcsB1wHiAfAB/gENAhoCJgIvAjYCOwI/AkMCRgJIAkgCRAI9
AjcCMwIwAisCJgIiAiACHwIeAhsCFQILAv8B9AHlAdQBxQG4AawBnwGUAY4BjgGPAZABkAGNAYUB
dwFmAVMBQAEtARgBAQHrANYAxQC3AKwApQChAKAAoACeAJkAkQCHAHsAcQBnAF0AVQBNAEcAQwBB
AEEAQgBBAEAAPQA4ADEAKgAeABEAAwD0/+L/0v/G/7v/sP+l/5r/kP+C/3H/Xv9N/0H/OP8w/yf/
IP8c/xr/GP8W/xX/Fv8Y/xn/GP8R/wj//f7x/uT+1/7L/rz+rf6h/pb+if56/mz+X/5V/k7+Sv5G
/kT+Q/4//jn+M/4t/in+J/4l/if+Lf40/jr+P/5F/kr+Tv5S/lT+Vv5Y/ln+Wv5Z/lr+Xf5g/mT+
Z/5r/nP+fv6J/pL+lv6Y/pr+m/6c/pv+mv6e/qT+rf65/sb+1f7l/vb+B/8Y/yj/Nv9C/0v/Uf9V
/1T/VP9U/1b/Wv9i/2//gP+S/6T/sv+9/8X/y//R/9f/2v/d/+H/5f/r//D/9v/7/wAAAwAHAAwA
EQAVABsAIAAmAC4AOABEAE8AWwBoAHYAhACVAKQAswC/AMgAzgDUANoA4QDoAPIA/gAKARYBIAEp
ATMBPgFGAUsBUQFXAV0BYwFoAWsBawFrAWsBbQFwAXIBcwF0AXIBcAFsAWYBYAFZAVUBUgFRAVEB
UQFQAVABUAFSAVYBWgFcAV8BYQFfAV0BWQFWAVMBTwFKAUMBPgE6ATUBLwEnASEBHAEaARkBFwEV
ARQBEwETARMBEgERARABDQEJAQQB/gD3AO8A5gDaAMoAuACmAJMAgwB1AGkAXgBYAFMATwBLAEgA
RQBCAEAAPgA7ADcAMgAsACMAGAANAAEA9v/r/+L/2//U/83/xf+7/7P/q/+j/5n/jf+A/3P/aP9g
/1v/V/9S/07/Sv9G/0T/RP9D/0H/Pf84/zH/KP8e/xT/Cv///vb+7v7o/uL+3/7e/t/+4P7h/uL+
4f7f/tv+2f7W/tT+0f7P/sz+yv7J/sf+xv7F/sT+wf6+/rz+vP67/rv+vP69/sD+xP7J/s3+0P7U
/tv+4/7s/vb+//4F/wn/C/8N/w7/EP8S/xX/F/8a/xz/H/8h/yT/KP8q/yr/Kf8p/yv/Lv8y/zn/
Qv9L/1X/Xv9o/3L/fP+G/5D/mf+j/6v/s/+5/7//xf/K/8//1f/c/+T/7P/y//n///8FAAoADwAU
ABkAHwAlACwAMgA4AD4ARQBOAFcAYQBrAHQAfACEAIwAkgCXAJoAnACdAJ4AnwCgAKIApQCqALAA
tgC9AMIAxwDMAM8A0gDVANoA3wDkAOcA6wDvAPQA+QD7APwA/AD6APcA9ADxAO0A6ADmAOUA5ADl
AOcA7ADxAPgA/wAFAQsBEAETARUBFAERAQ0BCAECAf0A+wD6APoA+AD2APIA7QDqAOcA5QDjAOAA
2wDWANEAywDFAMAAuwC3ALMAsACtAKoApwCjAJ0AmACSAIwAhgB/AHgAbwBnAF8AWABSAE0ASABF
AEIAPwA6ADQALAAlAB4AGAAQAAkAAwAAAPz/+P/0//D/7P/n/+L/3f/a/9b/0P/I/8H/u/+1/6//
q/+n/6L/nf+Y/5L/jP+G/3//ef9z/2//bP9o/2T/Yf9f/13/W/9b/1r/Wf9X/1P/Tv9I/0P/Pf84
/zP/Lv8p/yX/Iv8g/x//H/8f/x//H/8h/yL/JP8l/yX/Jf8k/yP/I/8l/yf/Kf8q/yz/Lf8u/y7/
MP8x/zH/MP8v/y7/Lv8v/zL/Nf85/z3/QP9D/0f/Sv9M/07/UP9R/1P/VP9V/1f/Wv9f/2T/af9w
/3j/gP+I/4//lv+d/6P/qP+s/6//sv+1/7j/u/++/8L/x//L/8//0//X/9z/4v/o/+3/8v/3//v/
//8BAAUACQAMABAAEwAYAB0AIgAoAC4AMwA5AD8ARQBMAFIAVwBcAGEAZwBtAHMAeQB+AIMAhwCK
AIwAjACNAI0AjQCNAI8AkACTAJYAmQCdAKIApgCqAK4AsQC0ALYAuAC5ALoAugC5ALgAuAC4ALgA
uQC6ALsAuwC7ALkAtgCzALEAsACvAK4ArgCuAK8AsACyALQAtgC4ALgAtwC2ALUAtACyAK8ArACn
AKMAnwCbAJgAlgCTAJAAjgCNAIoAhwCDAH8AeQB0AG8AagBlAGAAWgBVAFEATgBKAEgARgBDAD8A
OwA3ADQAMgAvAC0AKgApACcAJgAkACIAHwAbABcAEwAPAAoABAD///j/8f/p/+P/3f/Y/9P/z//K
/8b/wv++/7v/uP+1/7L/rv+q/6b/o/+g/53/m/+a/5j/lv+U/5P/kv+R/47/i/+H/4P/gP98/3n/
df9x/27/bP9q/2n/Z/9m/2T/Yv9f/13/XP9a/1n/V/9V/1T/VP9V/1b/WP9a/1v/XP9d/1//YP9i
/2P/Zf9n/2n/a/9r/2v/a/9r/2z/bf9u/27/b/9x/3P/dv94/3v/fP99/3//gf+D/4b/if+N/5D/
lP+Y/5z/oP+k/6j/q/+w/7X/uv++/8L/xf/J/83/0P/S/9b/2f/c/9//4v/l/+f/6f/r/+3/7//w
//P/9f/4//z/AAAFAAoADwATABcAGwAfACMAJgAoACsALQAwADQANwA6AD4AQgBFAEkATQBQAFMA
VwBaAFwAXgBhAGQAZgBpAGsAbgBwAHIAcwB1AHYAdwB4AHgAeQB5AHgAeAB4AHkAegB6AHsAfQB9
AH4AfgB+AH8AgACBAIIAgwCDAIMAhACEAIUAhgCIAIkAiQCKAIsAjACMAI0AjACLAIoAiQCHAIYA
hACCAIAAfQB6AHYAcwBwAG0AagBnAGQAYQBcAFgAVABQAE0ASgBHAEQAQQA/AD0AOwA4ADYAMwAx
AC8ALQAsACsAKQAoACYAJAAiACAAHwAcABoAFwAUABEADAAIAAQAAAD9//n/9f/y//D/7v/r/+n/
5v/j/+D/3f/a/9f/0//Q/8z/yP/E/8D/vP+5/7b/s/+w/63/q/+p/6j/qP+n/6f/p/+n/6b/pv+m
/6X/pP+j/6H/n/+d/5v/mf+X/5X/k/+R/5D/jv+M/4r/if+I/4f/hv+H/4j/if+K/4v/jP+N/47/
j/+R/5P/lP+U/5X/lv+X/5j/mf+a/5v/nP+d/53/nv+e/57/nf+d/53/nf+e/5//oP+i/6X/p/+p
/6z/r/+y/7X/uf+8/8D/w//G/8n/y//O/9D/0f/T/9X/1//Z/9z/3v/g/+L/5P/m/+j/6v/r/+3/
7//x//L/9P/2//f/+v/9/wAAAwAGAAgACwANABAAEwAWABoAHQAgACMAJgApACsALgAwADEAMwA1
ADcAOQA6ADwAPgA/AEEAQwBFAEYASABJAEsATQBPAFEAUwBVAFYAWABZAFsAXABdAF8AXwBgAGEA
YgBiAGIAYwBjAGMAYwBiAGIAYQBgAGAAYABfAF8AXgBeAF4AXgBfAF8AXwBeAF0AXABbAFoAWgBZ
AFkAWABXAFYAVQBUAFIAUQBPAE0ASwBJAEgARwBGAEUARABDAEIAQQA/AD0AOwA5ADcANQAzADEA
LwAtACsAKQAnACQAIgAhAB8AHAAaABgAFgAUABEADwAOAAsACQAGAAMAAAD+//z/+v/3//X/8//x
/+7/7P/p/+j/5v/k/+P/4f/g/97/3P/b/9n/2P/W/9X/0//S/9H/z//O/8v/yf/G/8P/wf+//73/
vP+7/7v/uv+6/7n/uf+5/7j/uP+4/7j/uP+4/7j/uP+4/7n/uf+6/7v/vP+8/73/vf++/77/v/+/
/77/v/+//7//wP/A/8H/wv/C/8P/xP/F/8f/yP/J/8r/y//M/83/zv/Q/9H/0v/T/9T/1f/W/9f/
2P/Z/9n/2v/b/9z/3f/f/+D/4v/j/+X/5v/n/+n/6v/r/+z/7f/u//D/8f/y//P/9P/1//b/9//5
//r/+//8//3//v//////AAAAAAAAAQACAAIAAwADAAQABQAFAAYABgAHAAcACAAIAAkACQAJAAoA
CgAKAAoACwALAAsACwALAAwADAAMAAwADAAMAAwADAAMAAwADAAMAAwADAAMAAwADAAMAAsACwAL
AAsACgAKAAoACQAJAAgACAAIAAcABwAHAAYABgAFAAUABAAEAAQAAwADAAIAAgABAAEAAQAAAAAA
AAA=
B64_EOF

base64 --decode > "$WORK/sounds/clack2.wav" <<'B64_EOF'
UklGRiYfAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQIfAABdAfwDb/4m6zLoOh6f
U6VPbTC3DJrzHfJH84HqZ+m3+skQ8BiQEJMDmgEBErMj7CepGlgHXhHrIRAEVtRj0wIHLD+XWcdP
SC4eDeT+TQCY/44FaCMcQSM4RxghEVknbEDiQ1wxRiyBLmMfnxp/KM0x9jkEP04rFAf087/+CxRT
I+AuXTPKJfoMFwqRLP1VZWbHUqkv3hxYFyMTfh5tOyhMJkNQK0caCRz4H34ccxeLFBMbySIBIYMa
+w5XAiL8xgC9DG4UGxWiE1wRqBFVHHUtZTcbOA8xNBqUARf4FfcS+if/cALZBqoUXCJgKvU0lDi9
K+gYqg4OEHUX0BiyDWAAy/k1+8EFvhYHKIQuuCUfGTIW+hyTH0AYwwyXB20NmxbfGJcTzA5oDt4P
+wzdAsz1GO6G7DjvEvUG+mb9PP5O+W3sq9xL1bLV2tim4KzmGOdW5lDjWdu40xLVD9wS45Lrte61
6UHmWekp8t32xO8Z5vjir+Zh7cvufOlX4ULaZ9zi5B7ok+bG6PzsI+lu4C3avdWO1efZq91H32Th
j+D42b/WXt857gr3ePaC8mfwiu/L7ETplOmp6bHmbOaH5Xjex9eI2aHfd+Fi4f/k6eiG7bH15PkX
9GXpcOAU3CPeleLZ40zkhee96qHrSOpJ5iHiVeJI6cTyuPjb+C/0du8E7cftofHo8Rzrg+Jk3O3Z
A9vT3PPd+d5x4PXhuONB507sc/Gb9iD74/vy+JP1MfSl9Yf2g/VL9jf32PVo9sX57fwiAGIEqggC
DOsMyAmvBAAABfyK+L/29vj//gkF9wZIBMQAbwBlAW8Adv72/fv/8gFCAg8C1AEsAQ4AS/+MAJkF
+grXC8kKawuxDecQGRUBGowdaB9HIEcfBx0YHNwcyhwoGjUW/hM6FDcWNRmnGiMa5hr8HR0h4iIG
Iz0iryDaHXkbfhoMGvkZhRm2F0sVpBNdE28UsRZeGZUbvR0/H1cfrh5iHakc/R0eIIogvB6jHOYb
2xtXG4MakxnvGHAZtRqJG3cctx4yIfMh0SBVH3keoh0hHEMZXxU2Em4QEBDSEBYRZRDeD4APMQ8h
D3MOoQzJCuYJswiqBggFgwNnAff+yfyq+9D7Qfx8/LP9BgBUAjAExgWRB2EJNApuCmoK3QgTBk0D
IQGz/9X+o/5c/vL9Lf4j/5MAVwEVAdAA0ABZAMD+Gvwm+a72yvRF84HyyvLt8+P13PhF/B7/SgHm
ApYDIAOEAU3/Qf0i+5H4OfZq9MHy2/Cz7vXs9eva64/see2I7gHwvvEr8xv0jfTn8zfyYvDY7rnt
u+xZ69npzOh26Nfo0OkT617sGe7j74Dw4u/67gTuney96lnomuVd4/HhGuED4a3hseKo49bkY+bR
597oMOn/6APpCOnD6IPolOi56ArpAupm66bs0e1X7xbxu/Ii9D71H/ae9n72q/V79D/z6fGl8MTv
P+/v7vruu+848QzzofSu9aD21ffj+ED59fgR+Kb2JPXm8+vy6fGx8KHvI++H7+nwt/KV9JT2mPiM
+h/8If0k/l3/TwCDANz/1/4V/qz9hP22/TD+0/7c/2sBYgOuBesHeQleCg0LkAvYC+wLqQsbC1kK
YglLCEcHtAaXBrEGBQeOB1AIfQkAC3YMsQ2oDv8OmA7NDdEM+AtgC8MKKwq/CZAJ0wmACjMLpQsF
DJIMLA2oDS4O3g6mD4gQZRH1EUgSZxIGElgREhFrERoSvxICE+USzRLvEh4TIRP9ErISLBKbEc8Q
mg+DDtMNew2HDesNeg4TD8sPshCXEVcSuhLNEu0S6RJhEm4RehC+DxcPbw7kDYQNYA2ZDS8O7w6T
D/wPVxCdEJYQSRCrD7MOkg16DG8LXwpxCcEIQgg4CL4IcgkMCncKywozC6AL2wvKC34LNQsLC+AK
oQpCCpwJkAg5B94FbwSKAmUAk/46/Tn8iPs++2n75vt4/Pb8Lf0N/ef8+/z9/MT8yPxC/ef9ZP6F
/mf+Qf7+/YT93/wR/BD74vmg+EH3sPUJ9Lby/PHU8RLyafKr8t3yHfOk81T02/QV9QH1zfSH9CX0
v/Na8xbz9/LL8qTysvIG83Xz4fN59D/1y/XW9Yv1CfUd9MLyNfGg7yHur+xw69zq8epV69rrW+y2
7AftiO1Y7m7vfPBZ8SfyzvIM8wfz8/LK8ovyWfKE8gLzXfOZ8wD0jPQH9TX1DvXb9Nr0KvWZ9b/1
rfW19eX1KfZv9qj23vb99gn3L/dt97b38fcV+Db4PPgF+ID3pPal9dH0PvQA9C30qfRc9U32gvfn
+Ev6lvvA/LX9fv5C/wQAkwDXAPQADAEyAYEBBAKLAuAC+ALlAskCuwKrApICXAIMArMBSQHRAEUA
vf9U/wX/w/6G/nn+0/6n/+8AewIKBHEFsAbRB6wIIAk6CUkJdwllCdcIDQhNB5QG6QVxBSIF8ATk
BO8ELwWhBQ8GcQazBsAGkQY9Bt4FdgUuBUQFmwXgBQwGSAa2BpMH3wg9Cl0LTgwpDd0Ncg7zDlsP
lw+NDzwPvg46DsMNWQ0nDUcNiQ2sDa8NvA3VDeUN1w2UDRcNcAy9CxMLcQrnCZ0JhgmiCfoJVAq9
CkYLwAsbDHYM7AxwDeANIw46DjIOBg7CDXMNCA2GDPMLXwvlCm0K4wlYCeoIsAi1CO0INAlkCWcJ
HQmKCNEH/wY1BpAFBwWeBEYE9gPNA8EDnwNaA/kCigIFAkIBVwB6/6n+1P0S/YT8EfyK+xn78Pru
+vv6JPtq+8H7EvxI/HP8mfyk/ID8Lvy2+xj7aPqs+eL4JviA9+/2hPZK9kr2ePav9uv2Mvds95H3
uPfu9xv4J/gm+Dz4fPjK+CH5ifn4+X36E/uU+/n7Vvy0/OX81PyS/B38cPum+uX5Qvm9+EX42veE
9zL31vZ19hf20PWm9YT1WvUn9fH00/TQ9Mb0tPTG9An1YPXK9TT2hfbH9gP3Qfd393b3Pffj9mj2
3PVW9ef0kfRW9CT07/PQ8+PzFfRe9M70YvUM9tH2uPer+HT56PkI+vL50vnD+cX57vk++o763fon
+1r7ffuq+/37avzR/B39Xv2c/b/9uv2a/Wv9Kv3m/K38gPxg/FL8Rvwt/Pr7xfvY+zf8pvwG/VT9
nf3b/QX+Hv4n/j/+h/76/oP/JADsAKwBPgKmAusCJANuA9oDWgTGBBgFUgVkBWAFYQVeBXEFsgUR
Bn8G2AYgB3sH5AdACI0I3wgsCUgJOAkVCeQIpAhcCCMIAgjtB+8HBQgXCCAIGQgPCBwIOAhVCGkI
bghqCFcIOAgWCPAHwgeeB5EHigd6B10HQwc5ByoHEAcEBwkHAQfcBqIGXQYWBswFdwUtBQQF/QQM
BSwFUwWGBeIFXAbcBlgHwgcJCCIIHwgJCOkH0QfIB9wHBwg1CFYIbgihCOoIIwk3CSYJCAniCKQI
SgjRBz8HlgbcBSkFpwRLBOcDegMRA7YCYAIBAqUBUwENAdUAogBwAEcALQAAALr/dv9N/0b/S/9K
/0X/Rf9U/3f/ov/N//n/GAAtADgANwAwACgAIwAPANv/jf8+//X+mf4k/q79T/0I/cv8mfx6/GT8
Pfz7+8D7n/uE+2b7Q/sZ+/f61fqp+on6hvqp+uT6J/t2+9f7O/yE/Kf8pvyT/IH8afwu/ML7QPvF
+mX6L/ob+h/6K/os+iP6Jfou+jr6R/pH+jX6Ffrr+cL5m/l5+WT5XPlX+Uz5OvkY+d/4lfhM+Az4
3vfS99f3zve796b3lfeC93H3gfe29wL4YvjD+BL5UPmF+a75wvnH+cn5yPnB+a/5kvl7+Wr5YPlv
+aj5Bvp5+vX6b/vc+zj8gPyu/NP8+fwb/TP9Pf1H/VP9Vv1Q/T/9H/31/M/8ufyu/MD8BP1m/cr9
Gv5P/oT+wf70/hf/Lv9B/13/hf+z/9r/7P/w//n/EgBEAIoAzQAFAUIBjwHjATACcwKyAvICNANz
A7ED9gNHBJwE6QQjBU4FbAVyBV8FPAUNBdgEowRwBEIEHAT5A9kDxwPDA8IDxgPfAxYEXwSsBO8E
JwVdBYoFpQW4BccF2AXqBfAF6wXyBQ0GJQYnBh8GFAb5BdEFpAWABXQFeQWIBZcFnAWWBTwGvAve
EisRDQef/Bv2c/Fo8Tv7EQr0EWMP/ApyDGoRHQ5cA4H+bAH4Apf/LPx1+iP9fgcFENYOrggHA0MA
MQChAP//2wCKBQIJFgntBgQDOQL/BFQEkwD0ASMG9AcHCG4E9QBKA9kG2AYABPr+FPpw+isBBQiO
C8YMsQhUAHH6V/f78xn0MfnL/YMBdgZPCSUF5fyr+aH86f79/U3+HgJCBbsEMwLP/xP+yfwy/DP9
hv/EAOv/7/y/+W35PvyQAQgGhgX5AUz/Lv6l/lP/Of8s/37+yvwp+pj3BPfI+Ej7gPz//Fj+Xv8m
/nT7xfgy90j48vs1/zH/K/35+6n7g/vT+1/88vsx+lb4ivee99X3K/lg/Lf+Gf79+2H63/nx+WD6
efuM/F/85/oA+RH4ovhA+Uj56fl2+/L8ov2g/cT9b/7d/vn9Ifwx+tP3gfYD+Cz6bfvi/CL+yP2h
/OD74fqs+TT5UPmG+XP6o/zj/nv/sP76/Q/+Vv6k/dv73fow/In+QADZAKcAIgBY/1L+Nv1v/B78
//s8/EP97f5WAJ0A9/9D/zD/BACrAIEATwBTAEsAUABnACIA4P8OAGMApACzAO4A+ABeAA4AHgD6
/9j/KQC4AM8AYwDZ/4z/kf/K/yAAWABrAJEA9gCoARcC2wGQAdcBUwKrAksDDgQfBHgDxQKHAswC
agPuAx8EXASIBHcEjASdBEIEtQMsA8wCngKRAsQCFANQA3EDlgPcAx8ELQThA3kDTgOIAyUE8gR/
BW8F/gSABBoE4wP8A2IEqgSUBD0E6wO/A7ADtQPfAywETgQnBOQDsgOWA4gDrAMOBGoEbwQlBKsD
KQPvAvkCAQP6AgsDIAMVAxwDSwNlA0MDBAPgAgUDTgNiAxoDmwI/AjQCTQJbAlwCXwJmAmICPgL/
AaIBHwHMANQA5ADYANMA7wAWASsBMQE0AUEBWgF2AYkBeQEZAZQAVQBXAFEAIwDb/53/gP9r/zb/
7f7O/tv+1/68/qn+of6Z/of+fP6I/pT+kv6E/m/+Q/7+/db94f3n/eH98/0Z/kT+cv6L/oH+YP4s
/vb9zf2q/ZH9if2J/Y39mf2m/az9q/2e/ZP9mv2j/aP9lv1w/UX9J/0O/fT8z/yx/KX8nPyM/Hv8
b/xi/Eb8HPz7++z76/v0+/j7+fsH/B38MPxA/E/8ZPx+/KD8wPzR/NL8zPzF/Mb82Pzy/AT9Ef0X
/Rn9IP0s/Tn9Rf1f/Yv9tv3K/dD9z/3K/cb9vf21/bX9wf3Z/en94P3P/cf9wP2z/ar9qf2p/aj9
p/2r/bf9z/30/Sf+Xf6F/qD+t/7O/uP+8P7z/vX+A/8b/yv/Lv8s/zf/Uv9u/4j/pf/F/+b/AwAY
ACAAIAAhACQAKQA0AEUAXgB/AKQAwwDYAOsABQEmAUQBVAFaAVoBVQFKAUABRQFUAWABagF9AZ4B
yQH6ASQCTAJ4AqgC1ALzAgUDCAMBA/cC7gLgAswCtAKbAoMCbgJgAlsCXQJlAnACfQKJApMCnQKn
ArACuwLCAscCzwLdAusC7QLgAsYCqgKVAocCfQJ1AnECbwJqAmICXAJYAlgCWAJPAjwCLQIlAiIC
IQInAjUCSwJkAnoCkQKuAskC2QLgAuIC4ALdAtkC0QLBAqsCjwJyAlYCPAIpAhsCDQL7AegB1QHE
AbcBpQGNAXMBVgE0ARIB8wDZAMAAqwCgAKIAqwC1AL4AwQDAAL4AuQCvAJ4AjQB7AGYAUAA7ACsA
GgALAAAA9P/m/9j/y/++/7D/n/+O/33/cP9l/13/V/9O/0T/Pf80/yj/IP8a/xX/FP8T/xH/CP/3
/uP+0/7K/sT+vf64/rL+qv6f/pP+hf50/mD+Tf49/i/+If4Y/hT+Ff4W/hb+Ev4M/gj+CP4I/gr+
Cv4I/gT+Af7//f79+v3z/ev94v3V/cT9rv2Y/Yj9e/1t/V79TP07/TT9Of1G/Vf9af1//Zj9sP3E
/dX95P3v/fH97P3m/eX96f3v/fL98v3w/fD99P3+/Q3+HP4p/jX+QP5J/lD+V/5b/l7+Yf5i/mH+
Yv5m/mn+av5n/mT+Y/5i/mP+Z/5u/nj+hv6X/qn+v/7Z/vL+Bv8a/zD/Rv9b/23/gf+V/6j/u//K
/9X/3P/j/+v/9f8AAA0AGgApADgARwBUAGEAbwB6AIIAiwCVAKEArgC5AMEAxwDNANQA3ADiAOgA
6gDqAO0A9AD/AAwBGQEnATUBQwFPAVgBYAFlAWgBZwFkAWEBXwFbAVUBUAFMAUoBSgFLAU4BUAFR
AVMBWQFiAW4BewGIAZgBqQG8AdAB5gH9ARMCJAIzAkECSwJUAlgCWAJTAkgCNwIiAgsC9QHkAdcB
zgHGAb8BvQG+AcABwAHBAcQBxwHHAcUBxAHGAcYBwwG8AbABowGYAZIBjAGIAYgBiwGNAYwBhwF/
AXUBawFiAVsBVAFNAUQBOgEvASEBEQEBAfQA7QDoAOIA2wDYANQA0ADLAMUAvgC2AK0ApACcAJcA
kwCMAIQAfAB1AGwAYgBYAE8ARQA5ACoAGAAGAPf/5//Y/8z/wv+4/6//pv+g/5z/mf+Z/5r/mf+X
/5T/jf+E/3f/af9b/0v/Of8n/xX/Bv/5/uz+4v7a/tb+0v7P/s7+zf7K/sP+uf6u/qL+mP6P/on+
hP6B/oH+gf6B/oH+gv6C/oL+g/6F/of+i/6Q/pL+kP6L/oX+ff5y/mj+YP5c/lz+X/5k/mv+cf51
/nn+e/58/nv+ef51/nH+bv5r/mv+bP5u/nD+cv51/nr+gP6H/o7+lP6Y/pz+of6n/qv+rv6y/rX+
uf68/r3+vv7A/sH+w/7G/sv+0v7c/ub+7/71/vv+Av8K/xP/HP8l/yz/M/8+/0z/Wv9p/3r/if+Y
/6b/sv+8/8T/zP/T/9j/3v/n/+//9//8//7//v8AAAIABwAOABUAGwAiACgALQAuAC8AMwA2ADgA
OgA+AEYATwBXAF0AZABrAHEAdQB3AHoAfgCCAIgAjwCXAKAAqQCzALwAxADLANMA3QDpAPMA+wAB
AQUBCwESARgBHQEgASABHwEhASUBKgEvATcBQQFNAVkBYgFpAW4BcAFxAXABbgFrAWYBXwFYAVIB
TgFJAUUBQgFAAT8BPwE+ATwBOAE1ATQBNQE2ATgBOgE8AUABQwFEAUUBRQFGAUcBRwFHAUgBSQFH
AUMBPwE6ATQBLAEiARYBCwEBAfYA7QDmAOEA3gDbANgA1ADRAM4AygDGAMEAvAC3ALIArgCrAKoA
qQCmAKMAnwCbAJYAkACJAIAAdwBwAGgAXwBWAEwAQwA5AC8AJAAaABAABQD8//L/6f/h/9r/0//K
/8P/vP+4/7b/sv+t/6X/nP+S/4j/fP9x/2b/XP9T/0r/Rf9C/0L/Qv9C/0P/R/9K/0v/Sv9H/0T/
Qf87/zX/L/8p/yH/Gf8P/wb//f71/u/+6/7n/uX+4v7f/t3+2/7a/tf+1P7Q/s3+zP7M/s/+1P7b
/uL+6f7u/vH+9P73/vj++f76/vz+/v4C/wb/Cv8O/xH/Ff8Z/xz/IP8k/yf/J/8l/yH/HP8Y/xX/
Ev8P/wv/B/8F/wb/Cv8Q/xf/H/8m/y3/Mv83/zv/P/9C/0T/Rf9H/0n/Sv9M/07/UP9T/1X/V/9b
/17/Yf9m/2z/dP98/4T/jP+T/5j/nP+f/6P/qP+t/7P/uf/B/8n/0P/X/93/4//q//H/+P/+/wQA
CgAPABMAFgAaACAAJwAvADcAPQBBAEMARABFAEYASQBMAE8AVABaAGAAZwBuAHUAfACCAIgAjgCU
AJoAoQCoAK8AtQC7AMAAxADGAMgAyQDKAMsAywDNAM4A0ADSANUA1wDbAN8A5ADpAO8A9AD5APwA
/QD9AP0A/AD7APkA9wD2APUA9ADyAPIA8QDxAPEA8QDxAPAA8QDyAPIA8ADsAOcA4gDdANkA1gDU
ANIA0QDPAM8A0ADQANAAzgDLAMcAwwDAALwAuQC2ALQAsQCuAKsApwCkAKEAngCbAJcAkQCMAIcA
ggB+AHkAcwBtAGYAXwBaAFYAVABSAE8ATQBLAEoASABHAEYAQwBAADwANwAxACsAJQAeABgAEgAN
AAcABAABAP///P/6//j/9f/y/+7/6f/k/97/2P/R/8r/xP++/7n/tf+y/6//q/+n/6L/nv+Z/5X/
kP+M/4f/g/+A/3z/ef92/3T/c/9x/3D/b/9t/2v/af9m/2P/YP9c/1j/U/9P/0z/Sf9H/0X/RP9D
/0L/Qv9C/0L/Q/9D/0L/Qf9A/0H/Qf9B/0H/P/89/zv/Of84/zf/Nv82/zb/Nv83/zj/Of87/z7/
QP9C/0T/Rf9F/0X/Rf9E/0T/Rf9H/0r/Tf9R/1b/W/9f/2L/Zf9o/2v/bv9y/3X/ev9+/4P/h/+M
/5H/lf+Y/5v/nv+g/6L/pP+l/6b/p/+p/6v/rf+v/7D/sv+0/7b/uf+8/7//xP/J/87/0//Y/93/
4v/n/+z/8f/2//v/AAAGAAsAEAAUABgAGwAeACAAIQAiACQAJQAmACYAJwApACwALwAzADcAPQBD
AEgATQBSAFgAXQBhAGYAagBsAG4AbwBvAHAAcgBzAHUAeAB7AH0AgACCAIMAhACFAIYAhgCHAIcA
iACKAIwAjgCRAJQAlwCZAJwAnwCjAKYAqQCtAK8AsACwAK8ArQCrAKkApwClAKIAoACeAJwAmwCa
AJoAmgCaAJsAnACeAJ8AoACfAJ8AoAChAKAAnwCcAJgAkwCPAIwAiQCGAIQAggCAAH4AfQB8AHsA
eQB3AHQAcQBuAGsAaABlAGIAYABeAFwAWgBZAFgAVgBTAFAATQBKAEYAQgA9ADgAMwAvACsAJwAj
ACAAHAAYABQAEAAMAAkABQACAP///P/4//X/8v/v/+z/6P/l/+L/4P/e/9v/2f/X/9T/0f/O/8v/
yf/H/8X/w//B/7//vP+6/7j/tf+z/7H/rv+s/6r/qP+m/6X/pP+j/6H/oP+e/5z/m/+Z/5f/lf+T
/5H/kP+P/47/jv+O/47/jv+N/4z/iv+I/4b/hP+C/3//ff96/3f/dP9x/2//bv9u/27/bv9v/3D/
cf9z/3X/dv94/3n/ef96/3r/ev97/3z/ff99/37/fv9//4D/gv+D/4X/h/+J/4z/jv+Q/5P/lf+X
/5n/m/+d/5//oP+h/6P/pf+n/6n/q/+t/7D/sv+0/7f/uf+7/77/wP/C/8T/xv/J/8z/z//T/9f/
2//e/+L/5P/n/+n/7P/v//H/8//1//j/+//+/wAAAwAFAAcACQALAA0ADwARABMAFQAYABkAGwAc
AB4AHwAhACMAJQAoACsALgAyADUAOQA8AD4AQQBDAEUARgBGAEcASABJAEkASwBMAE8AUQBSAFMA
VQBXAFgAWQBaAFsAWwBbAFwAXQBfAGEAYwBlAGcAaQBrAG0AbwBwAHIAcwB0AHUAdQB0AHQAcwBz
AHIAcgByAHIAcQBxAHAAbwBtAGwAawBqAGoAaQBpAGkAaQBpAGkAaQBoAGcAZgBlAGUAYwBiAGAA
XwBdAFsAWgBYAFYAVABTAFEAUABQAE8ATgBNAEwASwBJAEcARQBDAEEAPwA8ADoAOAA2ADQAMwAx
AC4ALAAqACgAJQAjACAAHQAaABcAFAARAA4ADAAKAAgABgAEAAIAAQAAAP7//P/5//f/9f/z//H/
7//t/+v/6v/o/+f/5f/k/+L/4P/e/9v/2P/W/9T/0f/P/8z/yv/I/8f/xf/D/8H/v/+9/7v/uv+5
/7n/uP+3/7b/tf+0/7P/s/+z/7L/sv+x/7D/sP+v/6//rv+t/6z/q/+q/6j/p/+m/6X/pP+j/6L/
of+g/6D/oP+g/6D/oP+h/6H/of+h/6H/of+i/6L/o/+j/6P/o/+j/6T/pf+m/6f/qf+q/6z/rf+v
/7D/sf+x/7L/s/+0/7X/tv+2/7f/uP+5/7r/u/+9/77/v//A/8H/wv/D/8T/xf/H/8n/zP/O/9H/
0//W/9j/2v/c/9//4f/k/+b/6P/q/+z/7v/v//D/8f/z//X/9//5//v//P/+////AAABAAIAAwAF
AAYABwAIAAkACgALAAwADQAPABAAEgATABUAFwAZABoAHAAdAB4AHgAfACAAIAAhACEAIQAiACIA
IgAiACMAIwAjACQAJAAkACQAJAAkACQAJAAkACQAJAAlACUAJQAlACUAJQAlACUAJQAlACQAJAAj
ACMAIwAjACIAIgAiACIAIgAiACIAIQAhACEAIAAfAB8AHgAeAB0AHAAcABsAGwAaABkAGQAYABgA
FwAXABYAFgAVABQAFAATABIAEgARABAAEAAPAA4ADgANAAwADAALAAsACgAKAAkACQAIAAgACAAH
AAcABgAGAAUABQAEAAQAAwADAAMAAgACAAIAAQABAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAA=
B64_EOF

base64 --decode > "$WORK/sounds/clack3.wav" <<'B64_EOF'
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
ku+Y7w/w4PDk8Tbz1/ST9kD4tfnk+uf7vPw7/XH9av00/RL9K/10/cD98/0e/j/+SP5J/if+x/1C
/av8Cvxp+836T/of+lv67vq3+7H8v/2o/oj/cgApAZQByQHoARkCZQK8AicDuwNrBBMFvQV3BhoH
mQf8BzYIQggjCOAHfgcoB/YG+AZNB+8HyAi7CZkKPguwCw8MRAwjDLcLJQulCmwKgwrKCgwLPgtg
CzQLnwq1Cc0ILAi8B44HsAfwB0EIxAhnCfEJcQoBC3kL0gsPDBYM3QttC9kKLgp5CeEIkwiSCLkI
AAl4CfEJOApBCg8KoQkDCUUIewe/BjcGBAYdBoUGJQflB5cICglTCWsJLgmqCPYHMAeOBh4G2QWx
BY4FWwUdBeYEpwRRBOcDaQPkAlsCtgH3AEAAqP9D/yX/P/9g/2L/RP8K/7D+K/55/an8wfvY+hT6
kPlT+T35OPlk+a35yfmw+YH5KPmf+BD4kPcu9/P2x/ao9rf28/ZH96b3//c2+Cn45PeA9+32OPaI
9ej0TvTP85nzsvP780r0ivS49L70nPRw9EX0E/Tt8+bzBfRZ9NH0S/XO9Vz2zvYD9wr3Affr9sP2
qvbA9v32Sven9y/4zPhJ+Yn5jfly+T75A/nP+Jb4ZvhD+DX4YvjE+Ef55fmI+h37rPsy/IL8oPyn
/JT8cfxO/Cv8Hfw9/Jn8MP35/eT+z/+iAF8BBgKPAusCHQMmAxMDAQP4AvgCIQOAA/sDcgS/BPIE
LgVhBXcFWwUVBdwE1wQTBYoFHAaiBv8GQAd/B84HLwiNCMcI0AixCH8IUwg/CCwIAQjiBwgIVgiR
CK0ItQioCHAI9wdWB8QGXgYwBj8GdwbHBisHlwcDCGUIpQjECNgI1wimCEgI4webB2IHGgfYBrcG
tAa9BsIGqgZtBhAGjwX6BG8E+wOqA40DqQP6A3kEEQWjBSUGkAbYBuAGlAYXBokF8QRcBNsDdQM/
AzkDTgNlA10DLAPYAmgC6wF5ARwB0gCZAGgARwBHAE4APgAnAA0A2f+H/yr/0f59/hb+q/1q/WP9
iP3F/f39Gf4d/gT+vP1Y/fv8qvxK/OP7hfsv++v6zfrR+tH6s/qR+nz6X/oq+t/5j/lC+fj4vfie
+Jb4lviW+Jz4vPj6+EL5ffmt+cn5xvmk+WT5IvkB+f74EPk3+WX5hPmO+Yz5ivmW+an5ovlz+TD5
6fio+Hf4WfhO+F/4kvjb+Cj5bvms+db54vnT+bT5jPlu+XX5ovnr+Uf6sPok+5P78Ps5/H/8x/wL
/TX9Mv0e/Rv9If0l/Tn9Zf2W/b39zv3D/a/9m/2G/Xj9gP2k/db9Cf47/m7+sf4T/47/EwCdABoB
fwHKAfwBIQJBAmACegKeAuYCTwPGA0EEtQQaBWoFqwXiBQ0GMAZSBoEGsQbMBuIGDAc/B3EHowfe
BxsISQhVCEYIKwjzB6IHYQc0BwwH8QbuBgEHLQdgB3wHgQd9B2wHSwcdB+QGowZbBiYGHQYvBjAG
EQbtBdQFuQWOBUgF6QR2BPoDkANOAy0DHQMbAyADLAM7A0IDQgM/AzkDKAMKA+gCwwKYAm0CRwIj
Ag4CBwIEAvoB5gHQAcMBwAHJAeABAQIiAj4CVAJmAnkCjAKZApwCiwJbAhECsgE8AbsAQQDX/3n/
L//8/uL+3P7b/sv+qP57/j/++f2x/W39Jv3R/HP8IPzf+6n7g/t0+3b7e/t4+277XvtG+0z6MPlq
/GYBJgKWABr9S/e88rPyePkIAnMC0vzc+a73MvT58prz9fXM+J345vd/90712/IW83f4y/6bADr+
NvtM+/D9cwJLBgEE5v6m/EP8Mf29/gT+8/di72Xsh/LE++D/F/53+bb3/fuFATMDDQF//rD8Kfq4
90j38/ZB9VT1W/jg+y//JQO0BfQGmAjGB3sDCP5N+qT4NfaT9dT4ovqh+mr8z/+oBOoJigoiBRwA
ef8WAJP/wwCNBOYGcQXzAi8EQAc4B/kEwwGc/VX7BP1HALACnQQ6B3kJ/gcaAzr/cv89AtMEZgZP
BqsEEQPXAp8D4wMiAzED6QQLByII5wa7BAsDYgF5ABsCgwXEB2sIRgh5BgkDIACM/+wByQWPCDkJ
Owg1BukD0wEVADb/Jf///z0CywQNBgkGvQXMBY4FzAR6BGIEegTwBJYEwQJsAMv/0gD3AXADbASv
BMYEFwQjA78CRAO4BGMFvAPeAdcBmAIeA8EC3QCj/rv9SP5l/24ApgAf/w39UfwQ/aX+agDyAacC
TAJQAV8Au/9+/4L/YP9f/+H/kABiAD7/Yf5J/o3+xf6e/in+g/2u/A/83fv/+zP8LvwZ/Ob7o/sO
/PT8Xf0n/eP8zPy5/IP8AfzC+xr8Mvzi+8X74/se/Ff8Zvxe/En8LPz/+8T7vfsi/Lr89PzW/Nr8
B/0H/ab8Mfw4/Jr8zvyt/E38+vvx+xn8RfxE/AD8uPuZ+5L7r/vI+7b7uvsx/On8H/3S/I78Ufw3
/I38Of3G/cP9Tv0E/UH9p/3e/Qr+Hf4g/lj+n/6+/uH+Nv+H/6//wv+v/5v/0f8uAGQAegCeAL0A
sQCOAGcAWgCHAM4A/QAIAQQB9QDNAJIAcAChABkBdwFxATIBJgFvAcoBAAIKAiICYAKKAn4CbQJ8
AowCoQLOAvQCDAMuA0gDTwNoA5YDvQPWA9UDuQOaA4kDiwOeA84DHwRKBCQE4wO0A58DngOdA40D
gwOeA9YDCAQjBC4ELwQnBB0EBwTSA4cDTQNEA2IDggOJA3UDVAMuAwYD1wKhAmsCPQIYAv4B/wET
AhgC+wHSAbABjQFsAVYBSQFCAS4BBAHUAK8AngCfALIA0QDsAPwA+ADlAMgAoQB4AFQAQgBGAEwA
OAAPAOz/4f/h/9z/1//Q/7j/m/+B/2H/Pf8h/wL/0/6c/m7+WP5X/lz+Vv4//hn+5f2t/Yb9cv1q
/XH9hv2a/aT9rv2//cv9zf3G/bz9tf2y/bT9sf2f/YD9WP00/Rn9Bf33/PL88Pzq/OP81Py4/JT8
cPxR/D78Nvw3/ET8YfyJ/LP83vwE/R/9L/0+/Vb9b/1//Yv9lv2g/ab9pf2k/aX9qv2y/bn9wP2+
/bL9n/2M/X/9f/2H/ZT9qf3H/e79Hf5I/mj+hP6h/rv+2P75/hj/NP9V/3v/pv/S//n/FQAoADUA
RABaAHUAigCVAJwAogChAJ4AnQChALAAzgDuAAYBFwEhASQBJAEnASoBMAE5AUEBRwFQAWIBfQGZ
AbQBygHbAfABDgIqAkMCXQJ6ApoCuwLVAuIC6wL3AgIDBwMCA/cC5gLNArAClQKBAnICZgJlAmwC
dgJ/AocCiwKLAoYCgAJ9AnoCdAJtAmgCYgJdAlkCVAJMAkQCQgJDAjwCMQIkAhMC/gHtAeMB3wHf
Ad4B3wHkAegB6AHmAeEB2wHRAcIBrQGVAYABagFUAT4BLQEfARIBBQH7APIA5ADRAL0AowCHAGsA
TAAtABIA///w/+D/zv+8/6b/if9m/z//Gf/2/tj+x/7A/rr+s/6q/qL+oP6k/qj+qf6n/qP+nP6X
/pX+lP6P/ov+if6F/nv+b/5h/k3+Nf4f/gb+7P3T/cD9sf2k/Z39nf2m/bb9x/3S/df90/3K/cD9
tf2u/ar9p/2n/av9sP24/cX92P3t/fz9A/4E/gX+C/4S/hf+F/4a/iD+Kv41/j7+Q/5K/lH+Vf5Z
/mD+aP5v/nj+hP6R/p/+rf65/sX+zf7T/tj+2/7a/tn+2/7c/tn+1f7X/t/+7P79/hD/Iv8z/0f/
W/9y/4r/nv+q/7H/uP/B/8r/1//q/wIAHQAzAEUAVgBmAHcAjACiALgAzQDeAO8A/QAJARUBIQEt
ATcBPQFBAUYBTgFXAWABaQFzAX8BjgGfAbEBwgHNAdUB3QHkAesB9AH7Af4B/gH+Af8BBQIPAhkC
IAIkAiUCJQIjAh4CGQITAg0CBwIBAv4B/QH+Af8BAgIIAg8CEwITAhECDAIFAv0B8wHnAd0B1gHR
Ac0BywHIAcIBugGvAaABjgF7AWcBUgE7ASMBDgEAAfMA5QDYAM0AwwC6AK8AoQCTAIUAdwBqAF4A
VQBPAE4AUQBTAFIATwBIAD8AMAAbAAEA5//O/7X/nf+H/3X/ZP9U/0b/Of8r/xv/DP/8/u7+4v7Z
/tP+0v7V/tf+1v7R/sv+x/7B/rb+qP6b/pH+hv56/m3+Yf5X/lP+VP5Y/lr+WP5S/kz+Rf48/jT+
Lv4p/iX+Iv4h/iP+Kv4y/jr+Pv5B/kP+Q/5D/kL+Qf5F/kz+VP5c/mX+cf59/ov+l/6j/rD+u/7E
/sj+yf7J/sz+zv7P/tD+0v7a/uf+9f7+/gP/Bv8K/xD/Ff8b/yH/KP8v/zb/Pf9F/03/Vf9d/2X/
bP9z/3v/hf+R/57/qv+1/8L/zv/b/+r/+v8NACMAOQBOAGEAcwCCAJAAngCsALgAwQDFAMgAzADR
ANYA3QDkAOoA7wD0APcA+wACAQoBFAEiATEBPQFGAU0BUwFaAWABZgFtAXIBcgFvAWsBaAFpAW0B
dQF+AYUBigGNAYwBiQGIAYcBhQF/AXgBbgFkAV4BWwFaAVsBWwFbAVwBXAFZAVQBTQFIAUQBQAE9
AToBNgEyASwBJgEeARYBDgEHAQQBAwEBAf0A9wDxAO0A6gDnAOUA4wDgANgAzAC9AK0AmwCKAHsA
bABfAFUATABEAD8AOQA1AC8AKAAgABcADQAEAP3/9P/o/9r/yv+6/6v/nf+Q/4T/eP9s/2P/Xf9Y
/1P/Tv9J/0X/Qv9B/z7/PP85/zf/NP8u/yj/Iv8d/xj/Ev8L/wP//P72/vL+7v7p/uP+2v7Q/sX+
u/61/rP+sv6y/rP+tP60/rb+uP65/rn+uf64/rf+tP6v/qr+qP6n/qf+qf6s/rD+tf68/sP+y/7S
/tf+3P7j/uv+9P78/gT/Cv8P/xP/F/8c/yD/I/8m/yb/Jf8k/yP/Jf8p/y//N/9A/0v/Vv9i/2z/
dv+A/4n/kf+a/6L/qv+z/73/yP/T/+D/7////w0AHQArADUAPQBCAEUASABNAFQAXQBnAHAAeQCD
AI0AlwCfAKQApwCpAKoArQCwALUAvADEAMwA1ADaAOAA5wDuAPMA+AD8AAEBBQEIAQsBDgESARYB
GgEeASQBKAErASwBLAErASoBKAEmASYBJgEkASIBIgEhASABHgEeAR4BGwEXARQBEAELAQYBAAH7
APYA8QDuAOwA6wDqAOcA4gDbANMAygDBALsAuAC3ALUAswCwAKsApQCfAJkAlQCQAIkAgQB3AGwA
YgBZAFAASQBEAD8AOgA0AC8AKgAlACAAGQAQAAcAAAD4//D/6v/l/9//2P/R/8v/x//E/8D/u/+1
/6//qP+i/5z/lv+S/4//i/+F/37/d/9w/2r/Zv9j/2D/XP9Z/1b/Uv9N/0f/Qf88/zf/Mf8s/yb/
IP8a/xX/EP8N/wz/Df8O/w7/Df8N/w3/Df8M/wz/DP8K/wn/CP8H/wn/C/8N/w//Ef8T/xP/E/8T
/xL/Ef8R/xH/Ef8S/xX/Gf8c/yD/Jf8q/zD/N/8+/0X/S/9S/1j/Xv9l/2z/df9+/4j/kf+Z/6H/
pv+r/6//sf+y/7P/s/+0/7b/uP+7/8D/x//O/9X/3P/j/+r/8v/5/wAABgAMABMAGwAkAC4AOQBD
AEsAUgBYAF0AYABkAGgAbABwAHUAegB/AIUAiwCRAJcAnACgAKQApwCpAKoAqwCtAK8AsQC1ALkA
vQDDAMgAywDOANAA0gDUANQA1QDWANcA2QDbAN0A4ADjAOUA5gDmAOYA5ADiAN0A1wDSAM4AywDI
AMYAwwDBAL4AvAC7ALsAugC3ALMArQCnAKIAnQCaAJcAlQCTAJEAjwCOAI0AiwCIAIQAgAB8AHcA
cgBtAGgAYwBdAFcAUABJAEIAOwAzACsAIwAcABQADgAIAAIA/f/4//P/7//s/+n/5//l/+L/3v/Z
/9P/zf/H/8H/vP+2/7L/r/+t/6r/pv+h/5z/l/+R/4v/hv+D/4D/fv98/3r/eP92/3X/dP9z/3H/
b/9t/2v/af9o/2b/ZP9h/17/W/9Y/1b/U/9Q/0z/Sf9G/0L/QP8+/zz/O/87/zz/Pf8//0H/Qv9D
/0T/Rv9J/0z/T/9R/1P/Vf9Y/1r/Xf9g/2T/af9t/3L/dv95/3v/fv+B/4X/if+N/5P/mP+e/6P/
p/+r/6//s/+2/7n/u/+8/77/wf/G/8z/0f/W/9r/4P/l/+r/7v/y//b/+f/7//7/AAAEAAcACwAQ
ABUAGQAeACMAKAAtADMANwA8AEEARgBKAFAAVQBaAF4AYgBmAGkAbABuAG8AbwBwAHEAdAB2AHkA
fQCAAIIAhQCIAIoAjQCQAJIAkwCVAJYAmACaAJwAngCfAKEAogCjAKQApQCmAKYApgCmAKYApgCl
AKUApQClAKQApACiAKAAngCbAJcAlACQAIsAhwCCAH4AewB4AHUAcgBvAGsAZwBjAF8AXABZAFcA
VABRAE8ATQBMAEsASQBHAEUAQgA9ADgAMwAvACwAKAAlACAAHAAZABUAEQANAAkABAAAAPz/9//y
/+7/6f/l/+L/3//b/9f/1P/R/87/y//I/8X/wv+//7v/t/+0/7H/rv+s/6v/qf+o/6X/o/+g/5z/
mv+W/5L/jv+J/4X/gv+A/37/fP97/3v/e/96/3r/ef95/3r/ev97/3v/e/97/3r/ef94/3b/df9z
/3L/cP9w/3D/cP9x/3L/c/91/3f/ev98/3//gv+F/4j/i/+O/5H/lf+Y/5r/nf+f/6L/pP+m/6j/
qv+s/67/sP+z/7b/uf+8/7//wv/F/8n/zf/Q/9T/2f/d/+H/5v/q/+7/8v/1//n//f8AAAMABgAJ
AAwADgAQABIAFAAXABoAHgAhACQAJwAqAC4AMQA0ADgAOwA+AEEARABHAEkASwBMAE4AUQBUAFcA
WwBeAGEAZABmAGkAagBrAG0AbgBvAHAAcQBzAHQAdQB2AHYAdwB3AHcAdwB2AHUAdAB0AHQAdAB0
AHQAdAB1AHUAdgB3AHcAdwB3AHYAdQB0AHMAcgBwAG4AawBpAGcAZABiAGAAXQBbAFgAVQBTAFEA
TwBNAEwASgBJAEcARABCAD8APAA4ADQALwArACYAIQAcABgAFQASAA8ADAAKAAcABQACAAAA/v/9
//v/+f/3//b/9P/y/+//7f/r/+n/5v/k/+H/3v/b/9j/1P/R/87/yv/H/8T/wv+//73/vP+7/7n/
uP+2/7T/s/+x/7D/sP+v/67/rf+r/6r/qP+m/6T/ov+g/53/m/+Z/5f/lv+V/5X/lf+V/5X/lf+W
/5b/lv+V/5X/lf+V/5b/mP+Z/5v/nP+e/6D/ov+k/6X/p/+o/6n/qv+r/6z/rf+v/7H/s/+1/7f/
uP+6/7z/vv+//8H/wv/E/8b/yP/K/8z/z//S/9T/1//a/93/4P/j/+X/5//p/+r/7f/v//L/9f/4
//v///8BAAUACAALAA4AEAATABUAGAAaAB0AHwAiACQAJwApACsALQAvADEAMwA0ADYANwA5ADsA
PAA+AEAAQgBEAEUARwBIAEkASwBMAEwATQBPAFAAUQBSAFMAVABUAFQAVABTAFMAUwBTAFMAUwBU
AFQAVQBWAFYAVgBXAFcAVwBYAFgAWABYAFgAVwBXAFYAVQBUAFIAUQBPAE4ATABKAEgARgBEAEEA
QAA9ADsAOQA3ADUAMwAyADAALgAtACsAKQAnACQAIgAgAB4AHQAbABoAGAAXABUAEwARAA4ADAAK
AAcABQADAAAA///9//z/+v/4//f/9f/z//H/7//u/+3/7P/r/+r/6f/p/+n/6f/o/+j/5//l/+T/
4//i/+H/3//e/97/3f/c/9z/2//b/9v/2//b/9v/2v/a/9r/2v/Z/9n/2f/Y/9j/2P/Y/9j/2P/Y
/9j/2f/Z/9r/2//c/93/3f/e/9//4P/g/+H/4f/i/+L/4//k/+X/5f/m/+f/6P/p/+n/6v/r/+z/
7f/u/+7/7//w//H/8f/y//P/9P/1//X/9v/3//j/+P/5//r/+v/7//v//P/8//z//f/9//3//v/+
//7/////////AAAAAAAAAAAAAAAAAAAAAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAAAAAAAAAAA
AAA=
B64_EOF

base64 --decode > "$WORK/sounds/bell.wav" <<'B64_EOF'
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
vACAADkA8P+r/3D/RP8n/xr/HP8x/1j/kP/V/x4AZQCgAMoA3wDjANUAuQCQAFoAGwDX/5P/WP8u
/xr/HP8y/1j/iP+///v/OAB0AKkA0gDmAOQAzACgAGgAKgDt/7P/f/9T/zL/IP8i/zr/Zv+h/+X/
JwBjAJQAuQDQANgA0gC6AJAAVgASAM3/jP9Z/zf/J/8p/zn/V/+C/7n/+f89AH4AtADXAOUA3QDD
AJsAaQAwAPT/tf95/0X/Iv8T/xz/O/9s/6j/6P8mAGEAlgDCAOEA7gDkAMQAkABNAAUAwP+D/1L/
L/8a/xb/JP9F/3n/vf8JAFQAlgDIAOcA8gDqANIAqgB0ADEA5/+b/1b/Iv8E//7+EP81/2j/pv/r
/zIAeQC6AO0ACwEOAfcAyACJAD8A9f+s/2n/Mf8G/+/+7/4J/z3/hP/X/ysAeQC7AOwACgEWAQwB
7AC1AGsAEwC6/2b/Iv/0/t/+4v77/if/Zf+y/wgAYgC2APsAJwE3ASkBAQHFAHsAKADS/3z/Lv/v
/sb+u/7Q/gP/Tf+l/wIAXQCvAPQAKAFFAUcBKwHyAKAAPQDW/3T/If/j/r7+sf6//ub+Jv99/+T/
TwC1AAkBRAFfAVsBOwECAbUAWQDz/4n/Jv/U/p7+iv6a/sv+Fv9z/9v/QwCoAAIBSQF2AYEBaAEr
AdEAZQDy/4P/IP/Q/pn+ff6B/qb+7P5O/8T/PwC1ABgBYAGIAY8BdwFAAe4AhQANAJD/Gv+5/nb+
Wv5l/pP+3/5C/7T/LQCmABQBbgGnAbkBoAFgAQABiwAMAJD/HP+6/nD+R/5E/mn+t/4k/6j/MQC1
ACYBfAGyAcUBswF8ASMBrAAjAJT/Df+e/lH+LP4x/lz+qf4S/5H/HACpACsBkwHXAe0B1QGSAS0B
sAAmAJr/FP+f/kX+Ef4K/jL+hv7//o7/JAC1ADUBmgHfAfwB7wG1AVMBzgAzAJT///6E/i3+//38
/ST+dP7m/nP/EACxAEMBuAEDAh4CBwLDAVoB1QA+AKH/B/+A/hn+3P3T/f/9W/7c/nb/GAC3AEYB
uwENAjMCKALqAXwB6QBAAJT/8v5r/gn+0f3I/e39Qf6+/lz/CwC8AFwB2wEtAkwCNwLzAYUB9wBR
AKL/9v5f/u39q/2i/dH9Mv67/l7/DAC6AFoB3wE9AmkCXQIYAqABAQFMAJP/5v5T/uT9ov2T/bn9
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
B64_EOF


say "Building (this takes about a minute)…"
ARCH="$(uname -m)"
xcrun swiftc -O -parse-as-library \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "${ARCH}-apple-macos13.0" \
  "$WORK"/src/*.swift \
  -o "$WORK/$EXEC"

say "Binding the pages…"
GUI="gui/$(id -u)"
# Stop the running ledger (and its start-at-login job) before replacing it.
launchctl bootout "$GUI/$BUNDLE_ID" >/dev/null 2>&1 || true
pkill -x "$EXEC" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x "$EXEC" >/dev/null 2>&1 || break
  sleep 0.5
done
pkill -9 -x "$EXEC" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$WORK/$EXEC" "$DEST/Contents/MacOS/$EXEC"
cp "$WORK"/sounds/*.wav "$DEST/Contents/Resources/"

cat > "$DEST/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>GLBuildHash</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_EOF

codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

# Start at login, and have macOS restart the ledger if it ever quits unexpectedly.
# Choosing "quit" in the gear menu is respected: it stays closed until the next login.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<AGENT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST/Contents/MacOS/$EXEC</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>AbandonProcessGroup</key><true/>
</dict>
</plist>
AGENT_EOF

# Load the job now (this also starts the ledger). Retry briefly in case the old job is still unloading.
STARTED=no
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$GUI" "$AGENT" >/dev/null 2>&1; then STARTED=yes; break; fi
  sleep 1
done
if [[ "$STARTED" != yes ]]; then
  open "$DEST"
fi

say "Done. Look for the little closed book in your menu bar (top right)."
say "Your entries are kept in iCloud Drive > Gratitude Ledger > entries.json"
say "To uninstall later:  launchctl bootout $GUI/$BUNDLE_ID; rm -rf \"$DEST\" \"$AGENT\""
echo
