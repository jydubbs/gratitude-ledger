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
