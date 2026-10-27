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
