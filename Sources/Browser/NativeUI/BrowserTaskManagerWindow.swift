// BrowserTaskManagerWindow.swift

import AppKit
import Darwin

// MARK: - BrowserTaskManagerSampler

/// Memory and CPU of a process, from the kernel.
enum BrowserTaskManagerSampler {
    struct Usage: Equatable {
        var memoryBytes: UInt64
        var cpuNanoseconds: UInt64
    }

    static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(
            memoryBytes: info.ri_phys_footprint,
            cpuNanoseconds: ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)),
        )
    }

    static func cpuPercent(from old: Usage?, to new: Usage, elapsed: TimeInterval) -> Double {
        guard let old, elapsed > 0, new.cpuNanoseconds >= old.cpuNanoseconds else { return 0 }
        return Double(new.cpuNanoseconds - old.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100
    }

    static func childProcessIDs(of pid: pid_t) -> [pid_t] {
        let capacity = 256
        var buffer = [pid_t](repeating: 0, count: capacity)
        // Unlike `proc_listpids`, this returns a count of processes, not bytes.
        let count = proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, 256)
        guard length > 0 else { return "\(pid)" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

// MARK: - BrowserTaskManagerWindow

/// Help > Troubleshooting > Open Task Manager: the app's processes, with the tabs each one shows.
/// Chromium's own window needs its full browser UI, which OpenArc's tabs don't run in.
@MainActor final class BrowserTaskManagerWindow: NSObject {
    // MARK: Private

    private struct Row {
        let pid: pid_t
        let title: String
        let memoryBytes: UInt64
        let cpuPercent: Double
    }

    private let pages: () -> [pid_t: [String]]
    private let onClose: () -> Void
    private var window: NSWindow?
    private var timer: Timer?
    private let table = NSTableView()
    private let endProcess = NSButton()
    private var rows = [Row]()
    private var previous = [pid_t: BrowserTaskManagerSampler.Usage]()
    private var previousDate = Date()

    // MARK: Internal

    /// `pages` gives each renderer's process ID and the tabs in it.
    init(pages: @escaping () -> [pid_t: [String]], onClose: @escaping () -> Void) {
        self.pages = pages
        self.onClose = onClose
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        refresh()
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = BrowserStrings.menuTaskManager.replacingOccurrences(of: "Open ", with: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        for (id, title, width) in [
            ("task", BrowserStrings.taskManagerTask, 340.0),
            ("memory", BrowserStrings.taskManagerMemory, 90.0),
            ("cpu", BrowserStrings.taskManagerCPU, 60.0),
            ("pid", BrowserStrings.taskManagerProcessID, 80.0),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        endProcess.title = BrowserStrings.taskManagerEndProcess
        endProcess.bezelStyle = .push
        endProcess.target = self
        endProcess.action = #selector(endProcessPressed)
        endProcess.isEnabled = false
        endProcess.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(endProcess)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: endProcess.topAnchor, constant: -10),
            endProcess.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            endProcess.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()
        return window
    }

    private func refresh() {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].pid : nil
        let own = getpid()
        let tabs = pages()
        let now = Date()
        let elapsed = now.timeIntervalSince(previousDate)
        var next = [pid_t: BrowserTaskManagerSampler.Usage]()
        var result = [Row]()
        for pid in [own] + BrowserTaskManagerSampler.childProcessIDs(of: own) {
            guard let usage = BrowserTaskManagerSampler.usage(of: pid) else { continue }
            next[pid] = usage
            let title = pid == own
                ? BrowserStrings.taskManagerBrowser
                : tabs[pid]?.joined(separator: ", ") ?? BrowserTaskManagerSampler.name(of: pid)
            result.append(Row(
                pid: pid,
                title: title,
                memoryBytes: usage.memoryBytes,
                cpuPercent: BrowserTaskManagerSampler.cpuPercent(from: previous[pid], to: usage, elapsed: elapsed),
            ))
        }
        previous = next
        previousDate = now
        rows = result.sorted { $0.memoryBytes > $1.memoryBytes }
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.pid == selected }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    @objc private func endProcessPressed() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let pid = rows[table.selectedRow].pid
        // Only a process of this app, and never the app itself.
        guard pid != getpid(), BrowserTaskManagerSampler.childProcessIDs(of: getpid()).contains(pid) else { return }
        kill(pid, SIGTERM)
    }
}

// MARK: NSWindowDelegate

extension BrowserTaskManagerWindow: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        timer?.invalidate()
        timer = nil
        window?.delegate = nil
        onClose()
    }
}

// MARK: NSTableViewDataSource, NSTableViewDelegate

extension BrowserTaskManagerWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        let text =
            switch column?.identifier.rawValue {
            case "memory": ByteCountFormatter.string(fromByteCount: Int64(row.memoryBytes), countStyle: .memory)
            case "cpu": String(format: "%.1f", row.cpuPercent)
            case "pid": "\(row.pid)"
            default: row.title
            }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].pid : nil
        endProcess.isEnabled = selected != nil && selected != getpid()
    }
}
