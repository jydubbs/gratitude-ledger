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
