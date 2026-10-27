import SwiftUI

@main
struct GratitudeLedgerApp: App {
    @StateObject private var store: LedgerStore

    init() {
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
