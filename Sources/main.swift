import Cocoa
import ServiceManagement

// ============================================================
// Focus — one-file macOS menu bar app.
// Day starts at 4am. First launch after that = unskippable
// setup screen. Priorities live in the menu bar and nudge you
// at T-30, T, T+30 and T+60 minutes.
// ============================================================

let dayStartHour = 4
let nudgeOffsets = [-30, 0, 30, 60]          // minutes relative to start time
let flashSeconds = 5.0
let nudgeGraceSeconds = 300.0                 // don't fire nudges older than this

// MARK: - Model

struct Session: Codable {
    var start: Date
    var end: Date?
    var seconds: Double {
        (end ?? Date()).timeIntervalSince(start)
    }
}

struct Priority: Codable {
    var title: String
    var hour: Int
    var minute: Int
    var status: String = "todo"               // todo | working | done
    var firedNudges: [Int] = []
    var sessions: [Session] = []
    var completedAt: Date?

    var timeLabel: String { String(format: "%02d:%02d", hour, minute) }

    var totalSeconds: Double { sessions.reduce(0) { $0 + $1.seconds } }

    var isRunning: Bool { sessions.last?.end == nil && !sessions.isEmpty }
}

struct Day: Codable {
    var key: String
    var createdAt: Date
    var priorities: [Priority]
}

struct Store: Codable {
    var days: [String: Day] = [:]
}

// MARK: - Time helpers

let cal = Calendar.current

/// The logical day a moment belongs to: anything before 4am counts as yesterday.
func dayKey(for date: Date = Date()) -> String {
    let shifted = date.addingTimeInterval(Double(-dayStartHour) * 3600)
    let c = cal.dateComponents([.year, .month, .day], from: shifted)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Wall-clock date for a priority's start time inside a given logical day.
func startDate(dayKey key: String, hour: Int, minute: Int) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var c = DateComponents()
    c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
    c.hour = hour; c.minute = minute
    guard let base = cal.date(from: c) else { return nil }
    // Times before the 4am cutoff belong to the following calendar day.
    return hour < dayStartHour ? cal.date(byAdding: .day, value: 1, to: base) : base
}

func hms(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Persistence

final class Storage {
    static let shared = Storage()

    private let url: URL
    private(set) var store = Store()

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(Store.self, from: data) else { return }
        store = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var today: Day? {
        get { store.days[dayKey()] }
        set {
            store.days[dayKey()] = newValue
            save()
        }
    }
}

// MARK: - Full screen overlay window

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(blocking: Bool) {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).frame
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(blocking ? 0.97 : 0.88)
        level = .init(Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        hasShadow = false
        setFrame(frame, display: true)
    }

    // Swallow Escape / Cmd-W so a blocking screen stays blocking.
    override func cancelOperation(_ sender: Any?) {}
}

// MARK: - Small UI helpers

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
           color: NSColor = .white) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = .center
    l.lineBreakMode = .byTruncatingTail
    return l
}

func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.font = .systemFont(ofSize: 15, weight: .medium)
    return b
}

// MARK: - Setup screen (the unskippable one)

final class SetupController: NSObject, NSWindowDelegate {
    private var window: OverlayWindow?
    private var focusTimer: Timer?
    private var fields: [(title: NSTextField, time: NSDatePicker)] = []
    private var errorLabel: NSTextField?
    private var onDone: (() -> Void)?

    var isShowing: Bool { window != nil }

    func show(existing: Day?, onDone: @escaping () -> Void) {
        guard window == nil else { return }
        self.onDone = onDone

        let win = OverlayWindow(blocking: true)
        win.delegate = self

        let content = NSView(frame: win.frame)
        content.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("What matters today?", size: 40, weight: .bold))
        stack.addArrangedSubview(label("Pick one thing. Two at most. Give each a start time.",
                                       size: 16, color: .init(white: 0.65, alpha: 1)))
        stack.setCustomSpacing(34, after: stack.arrangedSubviews.last!)

        fields = []
        for i in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY

            let number = label(i == 0 ? "1" : "2", size: 22, weight: .bold,
                               color: .init(white: 0.5, alpha: 1))
            number.alignment = .center
            number.widthAnchor.constraint(equalToConstant: 24).isActive = true

            let title = NSTextField(string: "")
            title.placeholderString = i == 0 ? "Top priority" : "Second priority (optional)"
            title.font = .systemFont(ofSize: 20)
            title.widthAnchor.constraint(equalToConstant: 520).isActive = true
            title.heightAnchor.constraint(equalToConstant: 38).isActive = true
            title.focusRingType = .none

            let time = NSDatePicker()
            time.datePickerStyle = .textFieldAndStepper
            time.datePickerElements = [.hourMinute]
            time.font = .systemFont(ofSize: 20)
            time.dateValue = defaultTime(offsetHours: i == 0 ? 1 : 3)
            time.widthAnchor.constraint(equalToConstant: 110).isActive = true

            if let day = existing, i < day.priorities.count {
                title.stringValue = day.priorities[i].title
                if let d = startDate(dayKey: day.key,
                                     hour: day.priorities[i].hour,
                                     minute: day.priorities[i].minute) {
                    time.dateValue = d
                }
            }

            row.addArrangedSubview(number)
            row.addArrangedSubview(title)
            row.addArrangedSubview(time)
            stack.addArrangedSubview(row)
            fields.append((title, time))
        }

        let err = label("", size: 14, color: .systemRed)
        errorLabel = err
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(err)

        let go = button("Lock it in", target: self, action: #selector(commit))
        go.keyEquivalent = "\r"
        stack.addArrangedSubview(go)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        win.contentView = content
        window = win

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(fields[0].title)

        // Keep pulling focus back — this screen is meant to be inescapable.
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let w = self.window else { return }
            if !NSApp.isActive || !w.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func defaultTime(offsetHours: Int) -> Date {
        let next = Date().addingTimeInterval(Double(offsetHours) * 3600)
        var c = cal.dateComponents([.year, .month, .day, .hour], from: next)
        c.minute = 0
        return cal.date(from: c) ?? next
    }

    @objc private func commit() {
        var priorities: [Priority] = []
        let key = dayKey()
        let existing = Storage.shared.today

        for (index, field) in fields.enumerated() {
            let title = field.title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let c = cal.dateComponents([.hour, .minute], from: field.time.dateValue)
            var p = Priority(title: title, hour: c.hour ?? 9, minute: c.minute ?? 0)
            // Editing an existing plan keeps its progress.
            if let old = existing, index < old.priorities.count {
                p.status = old.priorities[index].status
                p.sessions = old.priorities[index].sessions
                p.completedAt = old.priorities[index].completedAt
                if old.priorities[index].hour == p.hour && old.priorities[index].minute == p.minute {
                    p.firedNudges = old.priorities[index].firedNudges
                }
            }
            priorities.append(p)
        }

        guard !priorities.isEmpty else {
            errorLabel?.stringValue = "Write at least one thing. That's the whole point."
            return
        }

        Storage.shared.today = Day(key: key,
                                   createdAt: existing?.createdAt ?? Date(),
                                   priorities: priorities)
        close()
        onDone?()
    }

    func close() {
        focusTimer?.invalidate()
        focusTimer = nil
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}

// MARK: - Nudge flash

final class FlashController: NSObject {
    private var window: OverlayWindow?
    private var timer: Timer?
    private var index: Int = 0
    var onAction: ((Int, String) -> Void)?

    func flash(priority: Priority, index: Int, headline: String) {
        dismiss()
        self.index = index

        let win = OverlayWindow(blocking: false)
        let content = NSView(frame: win.frame)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label(headline, size: 22, weight: .semibold,
                                       color: .init(white: 0.6, alpha: 1)))
        let title = label(priority.title, size: 64, weight: .bold)
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = win.frame.width * 0.8
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(label("scheduled \(priority.timeLabel)", size: 18,
                                       color: .init(white: 0.55, alpha: 1)))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.addArrangedSubview(button("I'm on it", target: self, action: #selector(startNow)))
        row.addArrangedSubview(button("Done", target: self, action: #selector(markDone)))
        row.addArrangedSubview(button("Dismiss", target: self, action: #selector(dismissAction)))
        stack.setCustomSpacing(34, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(row)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85)
        ])

        win.contentView = content
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSSound.beep()

        timer = Timer.scheduledTimer(withTimeInterval: flashSeconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    @objc private func startNow() { onAction?(index, "working"); dismiss() }
    @objc private func markDone() { onAction?(index, "done"); dismiss() }
    @objc private func dismissAction() { dismiss() }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let setup = SetupController()
    private let flash = FlashController()
    private var tick: Timer?
    private var statsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"

        flash.onAction = { [weak self] index, action in
            guard let self else { return }
            if action == "working" { self.startWorking(index) } else { self.finish(index) }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(wokeUp),
                           name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(wokeUp),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        tick?.tolerance = 0.3

        checkNewDay()
        rebuildMenu()
    }

    // MARK: Day handling

    @objc private func wokeUp() {
        checkNewDay()
        heartbeat()
    }

    private func checkNewDay() {
        guard Storage.shared.today == nil, !setup.isShowing else { return }
        setup.show(existing: nil) { [weak self] in self?.rebuildMenu() }
    }

    @objc private func editToday() {
        setup.show(existing: Storage.shared.today) { [weak self] in self?.rebuildMenu() }
    }

    // MARK: Heartbeat — status title + nudges

    private func heartbeat() {
        updateStatusTitle()
        guard !setup.isShowing else { return }
        guard var day = Storage.shared.today else {
            checkNewDay()   // machine stayed awake through the 4am rollover
            return
        }

        let now = Date()
        var changed = false

        for i in day.priorities.indices {
            let p = day.priorities[i]
            guard let start = startDate(dayKey: day.key, hour: p.hour, minute: p.minute) else { continue }

            for offset in nudgeOffsets where !p.firedNudges.contains(offset) {
                let fireAt = start.addingTimeInterval(Double(offset) * 60)
                guard now >= fireAt else { continue }

                day.priorities[i].firedNudges.append(offset)
                changed = true

                let stale = now.timeIntervalSince(fireAt) > nudgeGraceSeconds
                let busy = p.status != "todo"          // working or done: leave them alone
                if !stale && !busy {
                    flash.flash(priority: p, index: i, headline: headline(for: offset))
                }
            }
        }

        if changed { Storage.shared.today = day; rebuildMenu() }
    }

    private func headline(for offset: Int) -> String {
        switch offset {
        case -30: return "STARTS IN 30 MINUTES"
        case 0:   return "START NOW"
        case 30:  return "30 MINUTES LATE"
        default:  return "AN HOUR LATE"
        }
    }

    private func updateStatusTitle() {
        guard let day = Storage.shared.today else {
            statusItem.button?.title = "◎ set priorities"
            return
        }
        if let i = day.priorities.firstIndex(where: { $0.isRunning }) {
            let p = day.priorities[i]
            statusItem.button?.title = "▶ \(short(p.title)) \(hms(p.totalSeconds))"
            return
        }
        if let next = day.priorities.first(where: { $0.status != "done" }) {
            statusItem.button?.title = "◎ \(next.timeLabel) \(short(next.title))"
        } else {
            statusItem.button?.title = "✓ done"
        }
    }

    private func short(_ s: String) -> String {
        s.count <= 22 ? s : String(s.prefix(21)) + "…"
    }

    // MARK: Actions

    private func startWorking(_ index: Int) {
        guard var day = Storage.shared.today, day.priorities.indices.contains(index) else { return }
        // Only one thing at a time — pause anything else that's running.
        for i in day.priorities.indices where i != index && day.priorities[i].isRunning {
            day.priorities[i].sessions[day.priorities[i].sessions.count - 1].end = Date()
            if day.priorities[i].status == "working" { day.priorities[i].status = "todo" }
        }
        if !day.priorities[index].isRunning {
            day.priorities[index].sessions.append(Session(start: Date(), end: nil))
        }
        day.priorities[index].status = "working"
        Storage.shared.today = day
        rebuildMenu()
    }

    private func stopWorking(_ index: Int, markDone: Bool) {
        guard var day = Storage.shared.today, day.priorities.indices.contains(index) else { return }
        if day.priorities[index].isRunning {
            day.priorities[index].sessions[day.priorities[index].sessions.count - 1].end = Date()
        }
        if markDone {
            day.priorities[index].status = "done"
            day.priorities[index].completedAt = Date()
        } else if day.priorities[index].status == "working" {
            day.priorities[index].status = "todo"
        }
        Storage.shared.today = day
        rebuildMenu()
    }

    private func finish(_ index: Int) { stopWorking(index, markDone: true) }

    @objc private func menuStart(_ sender: NSMenuItem) { startWorking(sender.tag) }
    @objc private func menuPause(_ sender: NSMenuItem) { stopWorking(sender.tag, markDone: false) }
    @objc private func menuDone(_ sender: NSMenuItem) { finish(sender.tag) }

    @objc private func menuReopen(_ sender: NSMenuItem) {
        guard var day = Storage.shared.today, day.priorities.indices.contains(sender.tag) else { return }
        day.priorities[sender.tag].status = "todo"
        day.priorities[sender.tag].completedAt = nil
        Storage.shared.today = day
        rebuildMenu()
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let day = Storage.shared.today {
            for (i, p) in day.priorities.enumerated() {
                let mark = p.status == "done" ? "✓" : (p.isRunning ? "▶" : "○")
                let time = p.totalSeconds > 0 ? "  ·  \(hms(p.totalSeconds))" : ""
                let item = NSMenuItem(title: "\(mark)  \(p.timeLabel)  \(p.title)\(time)",
                                      action: nil, keyEquivalent: "")
                let sub = NSMenu()

                if p.status == "done" {
                    add(sub, "Reopen", #selector(menuReopen(_:)), tag: i)
                } else {
                    if p.isRunning {
                        add(sub, "Pause session (\(hms(p.totalSeconds)))", #selector(menuPause(_:)), tag: i)
                    } else {
                        add(sub, "I'm working on it", #selector(menuStart(_:)), tag: i)
                    }
                    add(sub, "Mark finished", #selector(menuDone(_:)), tag: i)
                }
                item.submenu = sub
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "No priorities set", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add(menu, "Edit today's priorities…", #selector(editToday))
        add(menu, "Stats…", #selector(showStats))

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit))

        statusItem.menu = menu
        updateStatusTitle()
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        menu.addItem(item)
    }

    // MARK: Stats

    @objc private func showStats() {
        let days = Storage.shared.store.days.values.sorted { $0.key > $1.key }
        let all = days.flatMap(\.priorities)
        let done = all.filter { $0.status == "done" }
        let totalFocus = all.reduce(0.0) { $0 + $1.totalSeconds }
        let sessionCount = all.reduce(0) { $0 + $1.sessions.count }

        var onTime = 0
        for day in days {
            for p in day.priorities {
                guard let scheduled = startDate(dayKey: day.key, hour: p.hour, minute: p.minute),
                      let first = p.sessions.first?.start else { continue }
                if first <= scheduled.addingTimeInterval(300) { onTime += 1 }
            }
        }
        let started = all.filter { !$0.sessions.isEmpty }.count

        var text = """
        FOCUS STATS

        Days planned         \(days.count)
        Priorities set       \(all.count)
        Finished             \(done.count)\(all.isEmpty ? "" : "  (\(pct(done.count, all.count)))")
        Started on time      \(onTime)\(started == 0 ? "" : "  of \(started) started")
        Work sessions        \(sessionCount)
        Total focused time   \(hms(totalFocus))

        ────────────────────────────────

        """

        for day in days.prefix(30) {
            text += "\n\(day.key)\n"
            for p in day.priorities {
                let mark = p.status == "done" ? "✓" : "·"
                let t = p.totalSeconds > 0 ? "   \(hms(p.totalSeconds))" : ""
                text += "  \(mark) \(p.timeLabel)  \(p.title)\(t)\n"
            }
        }

        if let win = statsWindow {
            (win.contentView?.subviews.first as? NSScrollView).map {
                ($0.documentView as? NSTextView)?.string = text
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Focus Stats"
        win.center()
        win.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        win.contentView?.addSubview(scroll)
        statsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pct(_ a: Int, _ b: Int) -> String {
        b == 0 ? "0%" : "\(Int((Double(a) / Double(b)) * 100))%"
    }

    // MARK: Login item

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        // Close any open session so the timer data stays honest.
        if var day = Storage.shared.today {
            for i in day.priorities.indices where day.priorities[i].isRunning {
                day.priorities[i].sessions[day.priorities[i].sessions.count - 1].end = Date()
            }
            Storage.shared.today = day
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
