import Cocoa
import ServiceManagement

// ============================================================
// Focus — habit consistency tracker for the macOS menu bar.
//
//  · a list of habits you want to keep
//  · one end-of-day check-in: didn't / 5 min+ / 1 hr deep
//  · a GitHub-style consistency chart + streak stats
//  · a live "time wasted" bar, always in the menu bar,
//    fed by apps and websites you mark as wasters yourself
// ============================================================

let dayStartHour = 4                 // anything before 4am belongs to yesterday
let pollInterval: TimeInterval = 1   // UI tick (menu bar clock)
let sampleInterval: TimeInterval = 2 // how often we actually sample the frontmost app
let idleThreshold: TimeInterval = 60 // no input for this long = not wasting time
let distractionGrace: TimeInterval = 15  // seconds on a waster before a session dies
let idleStopAfter: TimeInterval = 600    // idle this long and the session ends

// MARK: - Model

/// 0 = didn't do it, 1 = did 5+ minutes, 2 = an undistracted hour.
enum Mark: Int, Codable, CaseIterable {
    case none = 0, small = 1, deep = 2

    var label: String {
        switch self {
        case .none:  return "Didn't"
        case .small: return "5 min+"
        case .deep:  return "1 hr deep"
        }
    }
}

struct Habit: Codable {
    var id: String
    var name: String
}

/// A finished stretch of work on one habit.
struct HabitSession: Codable {
    var habitID: String
    var dayKey: String
    var start: Date
    var end: Date
    /// "manual", "distraction" (switched to a marked waster) or "idle"
    var endedBy: String
    var seconds: Double { max(0, end.timeIntervalSince(start)) }
}

/// The one currently running, if any.
struct ActiveSession: Codable {
    var habitID: String
    var start: Date
}

struct Store: Codable {
    var habits: [Habit] = []
    var sessions: [HabitSession] = []
    var active: ActiveSession?
    /// dayKey -> habitID -> mark
    var logs: [String: [String: Int]] = [:]
    /// dayKey -> waste source key -> seconds
    var waste: [String: [String: Double]] = [:]
    /// source key ("app:com.x" / "site:youtube.com") -> display name
    var wasters: [String: String] = [:]
    var checkInHour: Int = 21
    var wasteBudgetMinutes: Int = 60
}

// MARK: - Time helpers

let cal = Calendar.current

func dayKey(for date: Date = Date()) -> String {
    let shifted = date.addingTimeInterval(Double(-dayStartHour) * 3600)
    let c = cal.dateComponents([.year, .month, .day], from: shifted)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func date(fromDayKey key: String) -> Date? {
    let p = key.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    var c = DateComponents()
    c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
    return cal.date(from: c)
}

func dayKey(daysAgo n: Int) -> String {
    dayKey(for: Date().addingTimeInterval(Double(-n) * 86400))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

func mins(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m"
}

// MARK: - Persistence

final class Storage {
    static let shared = Storage()
    private let url: URL
    private var needsSave = false
    var store = Store() { didSet { needsSave = true } }

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("habits.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(Store.self, from: data) {
            store = decoded
        } else {
            store.habits = [
                Habit(id: UUID().uuidString, name: "Read"),
                Habit(id: UUID().uuidString, name: "Exercise"),
                Habit(id: UUID().uuidString, name: "Deep work")
            ]
        }
    }

    /// Writes only when something changed — the waste tracker touches the
    /// store every couple of seconds and we don't want that hitting the disk.
    func flush() {
        guard needsSave else { return }
        needsSave = false
        save()
    }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: derived

    /// 0…1 — how much of the day's possible credit was earned.
    func score(_ key: String) -> Double {
        guard !store.habits.isEmpty, let marks = store.logs[key] else { return 0 }
        let total = store.habits.reduce(0) { $0 + (marks[$1.id] ?? 0) }
        return min(1, Double(total) / Double(store.habits.count * 2))
    }

    func isLogged(_ key: String) -> Bool { store.logs[key] != nil }

    func wastedSeconds(_ key: String) -> Double {
        (store.waste[key] ?? [:]).values.reduce(0, +)
    }

    // MARK: sessions

    func habit(_ id: String) -> Habit? { store.habits.first { $0.id == id } }

    func name(ofHabit id: String) -> String { habit(id)?.name ?? "(deleted habit)" }

    /// Recorded time for a habit on a day, including the session running right now.
    func trackedSeconds(day key: String, habitID: String) -> Double {
        var total = store.sessions
            .filter { $0.dayKey == key && $0.habitID == habitID }
            .reduce(0) { $0 + $1.seconds }
        if let a = store.active, a.habitID == habitID, dayKey(for: a.start) == key {
            total += Date().timeIntervalSince(a.start)
        }
        return total
    }

    func trackedSeconds(day key: String) -> Double {
        store.habits.reduce(0) { $0 + trackedSeconds(day: key, habitID: $1.id) }
    }

    var activeElapsed: Double? {
        guard let a = store.active else { return nil }
        return Date().timeIntervalSince(a.start)
    }

    func startSession(habitID: String) {
        endSession(reason: "manual")
        var s = store
        s.active = ActiveSession(habitID: habitID, start: Date())
        store = s
        flush()
    }

    /// Ends the running session. `at` lets the caller back-date the end to the
    /// moment the distraction (or the idling) actually started.
    @discardableResult
    func endSession(reason: String, at end: Date = Date()) -> HabitSession? {
        guard let a = store.active else { return nil }
        var s = store
        s.active = nil
        let clamped = max(a.start, end)
        var recorded: HabitSession?
        // Anything under 10 seconds is a misclick, not a session.
        if clamped.timeIntervalSince(a.start) >= 10 {
            let session = HabitSession(habitID: a.habitID,
                                       dayKey: dayKey(for: a.start),
                                       start: a.start, end: clamped, endedBy: reason)
            s.sessions.append(session)
            recorded = session
        }
        store = s
        flush()
        return recorded
    }

    /// Consecutive days ending today (or yesterday, if today isn't logged yet)
    /// on which at least one habit was done.
    var currentStreak: Int {
        var streak = 0
        // Today not being logged yet doesn't break a streak; today logged as a
        // zero does. Start from yesterday in the former case.
        var i = isLogged(dayKey()) ? 0 : 1
        while i < 4000 {
            let key = dayKey(daysAgo: i)
            guard isLogged(key), score(key) > 0 else { break }
            streak += 1
            i += 1
        }
        return streak
    }

    var longestStreak: Int {
        let keys = store.logs.keys.filter { score($0) > 0 }.sorted()
        var best = 0, run = 0
        var previous: Date?
        for key in keys {
            guard let d = date(fromDayKey: key) else { continue }
            if let p = previous, let gap = cal.dateComponents([.day], from: p, to: d).day, gap == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = d
        }
        return best
    }
}

// MARK: - Waste tracking

final class WasteTracker {
    static let shared = WasteTracker()

    private var lastPoll = Date()
    private var lastResolve = Date.distantPast
    private(set) var currentKey: String?
    private(set) var currentName: String?

    private let browsers: [String: String] = [
        "com.apple.Safari":          "tell application \"Safari\" to get URL of front document",
        "com.google.Chrome":         "tell application \"Google Chrome\" to get URL of active tab of front window",
        "com.brave.Browser":         "tell application \"Brave Browser\" to get URL of active tab of front window",
        "company.thebrowser.Browser":"tell application \"Arc\" to get URL of active tab of front window"
    ]

    private var scriptCache: [String: NSAppleScript] = [:]

    func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPoll)
        lastPoll = now
        guard elapsed > 0 else { return }

        // Asking the browser for its front tab is the expensive part, so that
        // runs on its own slower cadence than the menu bar clock.
        if now.timeIntervalSince(lastResolve) >= sampleInterval {
            lastResolve = now
            resolveCurrent()
        }

        // Only count time you were actually present for.
        guard idleSeconds() < idleThreshold else { return }
        guard let key = currentKey, Storage.shared.store.wasters[key] != nil else { return }

        // Clamp so a sleep or a stalled timer can't dump an hour into the log.
        let credit = min(elapsed, sampleInterval * 2)
        let day = dayKey()
        var store = Storage.shared.store
        store.waste[day, default: [:]][key, default: 0] += credit
        Storage.shared.store = store
    }

    private func resolveCurrent() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else {
            currentKey = nil; currentName = nil
            return
        }

        if let script = browsers[bundle], let host = frontTabHost(bundle: bundle, script: script) {
            currentKey = "site:\(host)"
            currentName = host
        } else {
            currentKey = "app:\(bundle)"
            currentName = app.localizedName ?? bundle
        }
    }

    private func frontTabHost(bundle: String, script source: String) -> String? {
        let script: NSAppleScript
        if let cached = scriptCache[bundle] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            scriptCache[bundle] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        // No permission yet, no window open, or a blank tab — fall back to the app.
        guard error == nil, let urlString = result.stringValue,
              let host = URL(string: urlString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var isOnWaster: Bool {
        guard let key = currentKey else { return false }
        return Storage.shared.store.wasters[key] != nil
    }

    func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown,
                                    .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.compactMap {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }
}

// MARK: - Toast

/// A small non-blocking HUD near the menu bar. Deliberately not a system
/// notification: no permission prompts, no Notification Centre clutter.
enum Toast {
    private static var window: NSWindow?
    private static var timer: Timer?

    static func show(title: String, body: String) {
        timer?.invalidate()
        window?.orderOut(nil)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        let bodyLabel = NSTextField(labelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = NSColor(white: 0.75, alpha: 1)

        let stack = NSStackView(views: [titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = 12
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let size = stack.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 20,
                           y: screen.visibleFrame.maxY - size.height - 20,
                           width: size.width, height: size.height)

        let win = NSWindow(contentRect: frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = container
        win.orderFrontRegardless()
        window = win

        NSSound.beep()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            window?.orderOut(nil)
            window = nil
        }
    }
}

// MARK: - Consistency chart

final class ChartView: NSView {
    var weeks = 27                     // ~6 months, fits a reasonable window
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3
    private static let monthNames = DateFormatter().shortMonthSymbols ?? []

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(weeks) * (cell + gap) + 30,
               height: 7 * (cell + gap) + 24)
    }

    private func color(for score: Double, logged: Bool) -> NSColor {
        guard logged else { return NSColor(white: 0.5, alpha: 0.12) }
        if score <= 0 { return NSColor(white: 0.5, alpha: 0.22) }
        let base = NSColor.systemGreen
        // four visible steps, like the contribution graph
        let step = min(4, max(1, Int(ceil(score * 4))))
        return base.withAlphaComponent(0.25 + 0.25 * Double(step - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let today = Date()
        // Column 0 starts on the Sunday of the earliest week we show.
        let weekdayToday = cal.component(.weekday, from: today) - 1   // 0 = Sunday
        let totalDays = (weeks - 1) * 7 + weekdayToday + 1
        let left: CGFloat = 26
        let top = bounds.height - 18

        // month labels
        var lastMonth = -1
        for column in 0..<weeks {
            let daysAgo = totalDays - 1 - column * 7
            guard daysAgo >= 0, let d = date(fromDayKey: dayKey(daysAgo: daysAgo)) else { continue }
            let month = cal.component(.month, from: d)
            if month != lastMonth {
                lastMonth = month
                let name = ChartView.monthNames.indices.contains(month - 1)
                    ? ChartView.monthNames[month - 1] : ""
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                NSAttributedString(string: name, attributes: attrs)
                    .draw(at: NSPoint(x: left + CGFloat(column) * (cell + gap), y: top + 2))
            }
        }

        // weekday labels
        for (i, name) in ["M", "W", "F"].enumerated() {
            let row = [1, 3, 5][i]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            NSAttributedString(string: name, attributes: attrs)
                .draw(at: NSPoint(x: 4, y: top - CGFloat(row + 1) * (cell + gap) + 1))
        }

        // cells
        for column in 0..<weeks {
            for row in 0..<7 {
                let daysAgo = totalDays - 1 - (column * 7 + row)
                guard daysAgo >= 0 else { continue }
                let key = dayKey(daysAgo: daysAgo)
                let rect = NSRect(x: left + CGFloat(column) * (cell + gap),
                                  y: top - CGFloat(row + 1) * (cell + gap),
                                  width: cell, height: cell)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
                color(for: Storage.shared.score(key),
                      logged: Storage.shared.isLogged(key)).setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Stats + chart window

final class StatsWindowController {
    private var window: NSWindow?
    private var chart: ChartView?
    private var text: NSTextField?

    func show() {
        if let w = window {
            refresh()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let chart = ChartView()
        chart.translatesAutoresizingMaskIntoConstraints = false
        self.chart = chart

        let heading = NSTextField(labelWithString: "Consistency")
        heading.font = .systemFont(ofSize: 20, weight: .bold)

        let body = NSTextField(labelWithString: "")
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.lineBreakMode = .byClipping
        body.maximumNumberOfLines = 0
        self.text = body

        let stack = NSStackView(views: [heading, chart, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Focus"
        win.isReleasedWhenClosed = false
        win.center()

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        win.contentView = content
        window = win

        refresh()
        content.layoutSubtreeIfNeeded()
        win.setContentSize(stack.fittingSize)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        chart?.needsDisplay = true

        let s = Storage.shared
        let logged = s.store.logs.keys.sorted()
        var lines = [
            "Current streak     \(s.currentStreak) day\(s.currentStreak == 1 ? "" : "s")",
            "Longest streak     \(s.longestStreak) days",
            "Days logged        \(logged.count)",
            ""
        ]

        for habit in s.store.habits {
            var small = 0, deep = 0
            for (_, marks) in s.store.logs {
                switch marks[habit.id] ?? 0 {
                case 1: small += 1
                case 2: deep += 1
                default: break
                }
            }
            let total = small + deep
            let rate = logged.isEmpty ? 0 : Int(Double(total) / Double(logged.count) * 100)
            let habitSessions = s.store.sessions.filter { $0.habitID == habit.id }
            let recorded = habitSessions.reduce(0.0) { $0 + $1.seconds }
            lines.append("\(pad(habit.name, 18))\(pad("\(total) done", 10))"
                         + "\(pad("\(deep) deep", 10))\(pad("\(rate)%", 7))"
                         + (recorded > 0 ? mins(recorded) : ""))
        }

        // sessions
        let sessions = s.store.sessions
        if !sessions.isEmpty {
            let recorded = sessions.reduce(0.0) { $0 + $1.seconds }
            let killed = sessions.filter { $0.endedBy == "distraction" }.count
            let walked = sessions.filter { $0.endedBy == "idle" }.count
            let longest = sessions.map(\.seconds).max() ?? 0
            lines.append("")
            lines.append("Sessions recorded  \(sessions.count)")
            lines.append("Time recorded      \(mins(recorded))")
            lines.append("Average session    \(mins(recorded / Double(sessions.count)))")
            lines.append("Longest session    \(mins(longest))")
            lines.append("Killed by distraction  \(killed)")
            lines.append("Ended by walking off   \(walked)")
        }

        // waste, last 7 days
        let week = (0..<7).map { dayKey(daysAgo: $0) }
        let weekTotal = week.reduce(0.0) { $0 + s.wastedSeconds($1) }
        lines.append("")
        lines.append("Wasted today       \(mins(s.wastedSeconds(dayKey())))")
        lines.append("Wasted this week   \(mins(weekTotal))   (avg \(mins(weekTotal / 7))/day)")

        var bySource: [String: Double] = [:]
        for key in week {
            for (source, seconds) in s.store.waste[key] ?? [:] {
                bySource[source, default: 0] += seconds
            }
        }
        for (source, seconds) in bySource.sorted(by: { $0.value > $1.value }).prefix(5) {
            let name = s.store.wasters[source] ?? source
            lines.append("  \(pad(name, 18))\(mins(seconds))")
        }

        text?.stringValue = lines.joined(separator: "\n")
    }
}

// MARK: - Nightly check-in

final class CheckInController: NSObject {
    private var window: NSWindow?
    private var controls: [(habit: Habit, control: NSSegmentedControl)] = []
    private var dayBeingLogged = ""
    private var onSave: (() -> Void)?

    var isShowing: Bool { window != nil }

    func show(dayKey key: String, onSave: @escaping () -> Void) {
        guard window == nil else { return }
        self.onSave = onSave
        dayBeingLogged = key

        let habits = Storage.shared.store.habits
        guard !habits.isEmpty else { return }
        let existing = Storage.shared.store.logs[key] ?? [:]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "How did \(pretty(key)) go?")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        stack.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: "Be honest. The chart is only useful if it's true.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(20, after: hint)

        controls = []
        for habit in habits {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY

            let name = NSTextField(labelWithString: habit.name)
            name.font = .systemFont(ofSize: 14)
            name.lineBreakMode = .byTruncatingTail
            name.widthAnchor.constraint(equalToConstant: 170).isActive = true

            let seg = NSSegmentedControl(labels: Mark.allCases.map(\.label),
                                         trackingMode: .selectOne,
                                         target: nil, action: nil)
            // Recorded sessions pre-answer the question; you can still override.
            let tracked = Storage.shared.trackedSeconds(day: key, habitID: habit.id)
            let suggested = tracked >= 3600 ? 2 : (tracked >= 300 ? 1 : 0)
            seg.selectedSegment = existing[habit.id] ?? suggested

            if tracked > 0 {
                name.stringValue = "\(habit.name)  ·  \(mins(tracked))"
                name.toolTip = "Recorded \(mins(tracked)) of tracked sessions"
            }
            seg.segmentDistribution = .fillEqually
            seg.widthAnchor.constraint(equalToConstant: 250).isActive = true

            row.addArrangedSubview(name)
            row.addArrangedSubview(seg)
            stack.addArrangedSubview(row)
            controls.append((habit, seg))
        }

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.controlSize = .large
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(save)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Daily check-in"
        win.isReleasedWhenClosed = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        win.contentView = content
        win.setContentSize(stack.fittingSize)
        win.center()
        window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pretty(_ key: String) -> String {
        if key == dayKey() { return "today" }
        if key == dayKey(daysAgo: 1) { return "yesterday" }
        guard let d = date(fromDayKey: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        return f.string(from: d)
    }

    @objc private func save() {
        var marks: [String: Int] = [:]
        for (habit, control) in controls {
            marks[habit.id] = max(0, control.selectedSegment)
        }
        var store = Storage.shared.store
        store.logs[dayBeingLogged] = marks
        Storage.shared.store = store

        window?.orderOut(nil)
        window = nil
        onSave?()
    }
}

// MARK: - Habit editor

final class HabitsController: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var onSave: (() -> Void)?

    func show(onSave: @escaping () -> Void) {
        self.onSave = onSave
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Habits — one per line"
        win.isReleasedWhenClosed = false
        win.center()

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: 380, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: scroll.bounds)
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.string = Storage.shared.store.habits.map(\.name).joined(separator: "\n")
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        textView = tv

        let save = NSButton(title: "Save", target: self, action: #selector(saveHabits))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 310, y: 18, width: 90, height: 30)
        save.keyEquivalent = "\r"

        win.contentView?.addSubview(scroll)
        win.contentView?.addSubview(save)
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveHabits() {
        let names = (textView?.string ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var store = Storage.shared.store
        // Reuse IDs for names that already exist so history survives a rename-free edit.
        let existing = Dictionary(store.habits.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        store.habits = names.map { Habit(id: existing[$0] ?? UUID().uuidString, name: $0) }
        Storage.shared.store = store

        window?.orderOut(nil)
        window = nil
        onSave?()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let checkIn = CheckInController()
    private let habits = HabitsController()
    private let stats = StatsWindowController()
    private var timer: Timer?
    private var lastPromptedDay = ""
    private var wasteRunSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // A session left running by a crash or a force quit is stale — drop it
        // rather than crediting hours nobody worked.
        if let active = Storage.shared.store.active,
           Date().timeIntervalSince(active.start) > 6 * 3600 {
            Storage.shared.endSession(reason: "interrupted", at: active.start)
        }

        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            WasteTracker.shared.tick()
            self?.policeActiveSession()
            self?.updateStatusItem()
            self?.maybePromptCheckIn()
            ticks += 1
            if ticks % 30 == 0 { Storage.shared.flush() }   // ~every 30s
        }
        timer?.tolerance = 0.5

        updateStatusItem()
        maybePromptCheckIn()
    }

    // MARK: session auto-stop

    /// A running session dies when you spend a sustained moment on something you
    /// yourself marked as wasted time, or when you walk away.
    private func policeActiveSession() {
        guard Storage.shared.store.active != nil else {
            wasteRunSince = nil
            return
        }

        // Walked away: end the session where the idling began, not now.
        let idle = WasteTracker.shared.idleSeconds()
        if idle >= idleStopAfter {
            let began = Date().addingTimeInterval(-idle)
            if let done = Storage.shared.endSession(reason: "idle", at: began) {
                announce(title: "Session ended — you stepped away",
                         body: "\(Storage.shared.name(ofHabit: done.habitID)) · \(mins(done.seconds))")
            }
            wasteRunSince = nil
            return
        }

        guard WasteTracker.shared.isOnWaster else {
            wasteRunSince = nil
            return
        }

        // A glance is forgiven; sinking into it is not.
        let since = wasteRunSince ?? Date()
        wasteRunSince = since
        guard Date().timeIntervalSince(since) >= distractionGrace else { return }

        let distraction = WasteTracker.shared.currentName ?? "a distraction"
        if let done = Storage.shared.endSession(reason: "distraction", at: since) {
            announce(title: "Session stopped — \(distraction)",
                     body: "\(Storage.shared.name(ofHabit: done.habitID)) · \(mins(done.seconds))")
        }
        wasteRunSince = nil
    }

    private func announce(title: String, body: String) {
        Toast.show(title: title, body: body)
    }

    // MARK: status item — the always-present waste bar

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let wasted = Storage.shared.wastedSeconds(dayKey())
        let budget = Double(Storage.shared.store.wasteBudgetMinutes) * 60
        let fraction = budget > 0 ? min(1, wasted / budget) : 0

        button.image = barImage(fraction: fraction)
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // A running session takes over the text; the waste bar stays either way.
        if let active = Storage.shared.store.active, let elapsed = Storage.shared.activeElapsed {
            let name = Storage.shared.name(ofHabit: active.habitID)
            button.title = " ▶ \(name.prefix(14))  \(clock(elapsed))"
            return
        }
        let streak = Storage.shared.currentStreak
        button.title = streak > 0 ? " \(mins(wasted))  🔥\(streak)" : " \(mins(wasted))"
    }

    private func barImage(fraction: Double) -> NSImage {
        let size = NSSize(width: 36, height: 11)
        let image = NSImage(size: size, flipped: false) { rect in
            let track = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5),
                                     xRadius: 3, yRadius: 3)
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            track.fill()

            guard fraction > 0 else { return true }
            var fill = rect.insetBy(dx: 0.5, dy: 1.5)
            fill.size.width = max(3, fill.width * fraction)
            let color: NSColor = fraction >= 1 ? .systemRed
                               : fraction >= 0.6 ? .systemOrange : .systemGreen
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: check-in

    private func maybePromptCheckIn() {
        let s = Storage.shared
        guard !checkIn.isShowing, !s.store.habits.isEmpty else { return }
        let hour = cal.component(.hour, from: Date())

        // A day you've already started tracking but never closed out: ask once.
        let yesterday = dayKey(daysAgo: 1)
        if !s.store.logs.isEmpty, !s.isLogged(yesterday), lastPromptedDay != yesterday,
           hour >= dayStartHour, hour < s.store.checkInHour {
            lastPromptedDay = yesterday
            openCheckIn(for: yesterday)
            return
        }

        // The nightly prompt itself.
        let today = dayKey()
        guard hour >= s.store.checkInHour || hour < dayStartHour,
              !s.isLogged(today), lastPromptedDay != today else { return }
        lastPromptedDay = today
        openCheckIn(for: today)
    }

    private func openCheckIn(for key: String) {
        checkIn.show(dayKey: key) { [weak self] in
            self?.updateStatusItem()
            self?.stats.refresh()
        }
    }

    @objc private func logToday() { openCheckIn(for: dayKey()) }
    @objc private func logYesterday() { openCheckIn(for: dayKey(daysAgo: 1)) }
    @objc private func showStats() { stats.show() }
    @objc private func editHabits() {
        habits.show { [weak self] in self?.updateStatusItem() }
    }

    // MARK: sessions

    @objc private func startSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        wasteRunSince = nil
        Storage.shared.startSession(habitID: id)
        updateStatusItem()
    }

    @objc private func endSessionNow() {
        if let done = Storage.shared.endSession(reason: "manual") {
            Toast.show(title: "Session logged",
                       body: "\(Storage.shared.name(ofHabit: done.habitID)) · \(mins(done.seconds))")
        }
        updateStatusItem()
        stats.refresh()
    }

    // MARK: wasters

    @objc private func markCurrentAsWaster() {
        guard let key = WasteTracker.shared.currentKey,
              let name = WasteTracker.shared.currentName else { return }
        var store = Storage.shared.store
        store.wasters[key] = name
        Storage.shared.store = store
        updateStatusItem()
    }

    @objc private func unmarkWaster(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var store = Storage.shared.store
        store.wasters.removeValue(forKey: key)
        Storage.shared.store = store
    }

    @objc private func setBudget(_ sender: NSMenuItem) {
        var store = Storage.shared.store
        store.wasteBudgetMinutes = sender.tag
        Storage.shared.store = store
        updateStatusItem()
    }

    @objc private func setCheckInHour(_ sender: NSMenuItem) {
        var store = Storage.shared.store
        store.checkInHour = sender.tag
        Storage.shared.store = store
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        Storage.shared.flush()
        let s = Storage.shared

        let wasted = s.wastedSeconds(dayKey())
        header(menu, "Wasted today: \(mins(wasted)) of \(s.store.wasteBudgetMinutes)m")

        let today = s.store.waste[dayKey()] ?? [:]
        for (source, seconds) in today.sorted(by: { $0.value > $1.value }).prefix(4) where seconds > 30 {
            header(menu, "   \(s.store.wasters[source] ?? source)  ·  \(mins(seconds))")
        }

        menu.addItem(.separator())

        if let key = WasteTracker.shared.currentKey, let name = WasteTracker.shared.currentName {
            if s.store.wasters[key] == nil {
                add(menu, "Mark “\(name)” as time wasted", #selector(markCurrentAsWaster))
            } else {
                header(menu, "“\(name)” is marked as wasted")
            }
        }

        let wasters = NSMenuItem(title: "Time wasters (\(s.store.wasters.count))",
                                 action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if s.store.wasters.isEmpty {
            header(sub, "Nothing marked yet")
        } else {
            header(sub, "Click one to remove it")
            for (key, name) in s.store.wasters.sorted(by: { $0.value < $1.value }) {
                let item = NSMenuItem(title: name, action: #selector(unmarkWaster(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                sub.addItem(item)
            }
        }
        wasters.submenu = sub
        menu.addItem(wasters)

        let budget = NSMenuItem(title: "Daily budget", action: nil, keyEquivalent: "")
        let budgetMenu = NSMenu()
        for minutes in [15, 30, 60, 120, 180] {
            let item = NSMenuItem(title: minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h",
                                  action: #selector(setBudget(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = s.store.wasteBudgetMinutes == minutes ? .on : .off
            budgetMenu.addItem(item)
        }
        budget.submenu = budgetMenu
        menu.addItem(budget)

        menu.addItem(.separator())

        // Session controls
        if let active = s.store.active, let elapsed = s.activeElapsed {
            header(menu, "▶ \(s.name(ofHabit: active.habitID))  ·  \(clock(elapsed))")
            add(menu, "End session", #selector(endSessionNow))
        } else if s.store.habits.isEmpty {
            header(menu, "Add a habit to start a session")
        } else {
            let start = NSMenuItem(title: "Start a session", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for habit in s.store.habits {
                let item = NSMenuItem(title: habit.name, action: #selector(startSession(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = habit.id
                let today = s.trackedSeconds(day: dayKey(), habitID: habit.id)
                if today > 0 { item.title = "\(habit.name)  ·  \(mins(today)) today" }
                sub.addItem(item)
            }
            start.submenu = sub
            menu.addItem(start)
        }

        let tracked = s.trackedSeconds(day: dayKey())
        if tracked > 0 { header(menu, "Tracked today: \(mins(tracked))") }

        menu.addItem(.separator())

        let streak = s.currentStreak
        header(menu, streak > 0 ? "🔥 \(streak) day streak" : "No streak — log a day")
        add(menu, s.isLogged(dayKey()) ? "Edit today's check-in…" : "Check in for today…",
            #selector(logToday))
        if !s.isLogged(dayKey(daysAgo: 1)) {
            add(menu, "Check in for yesterday…", #selector(logYesterday))
        }
        add(menu, "Chart & stats…", #selector(showStats))
        add(menu, "Edit habits…", #selector(editHabits))

        let checkInMenu = NSMenu()
        for hour in [17, 18, 19, 20, 21, 22, 23] {
            let item = NSMenuItem(title: String(format: "%02d:00", hour),
                                  action: #selector(setCheckInHour(_:)), keyEquivalent: "")
            item.target = self
            item.tag = hour
            item.state = s.store.checkInHour == hour ? .on : .off
            checkInMenu.addItem(item)
        }
        let checkInItem = NSMenuItem(title: "Ask me at", action: nil, keyEquivalent: "")
        checkInItem.submenu = checkInMenu
        menu.addItem(checkInItem)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        add(menu, "Quit", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func header(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: misc

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        Storage.shared.endSession(reason: "manual")
        Storage.shared.flush()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
