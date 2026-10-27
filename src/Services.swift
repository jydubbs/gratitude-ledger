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
