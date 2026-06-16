import AppKit
import SwiftUI

// MARK: - Watched GUI apps

struct AppDef: Identifiable {
    let id: String          // bundle identifier
    let name: String
    let tint: Color
}

let GUI_APPS: [AppDef] = [
    AppDef(id: "com.microsoft.VSCode",            name: "VS Code", tint: .blue),
    AppDef(id: "com.todesktop.230313mzl4w4u92",   name: "Cursor",  tint: .gray),
    AppDef(id: "com.anthropic.claudefordesktop",  name: "Claude",  tint: .orange),
    AppDef(id: "com.openai.chat",                 name: "ChatGPT", tint: .green),
]

// MARK: - Usage model (decoded from glassbar-usage.sh)

struct Usage: Codable {
    struct Claude: Codable {
        var todayTokens = 0.0, todayCost = 0.0
        var weekTokens = 0.0,  weekCost = 0.0
        var blockTokens = 0.0, blockCost = 0.0, blockResetsAt = 0.0
    }
    struct Codex: Codable {
        var primaryPercent = 0.0, primaryResetsAt = 0.0
        var weeklyPercent = 0.0,  weeklyResetsAt = 0.0
        var sessionTokens = 0.0,  todayTokens = 0.0
    }
    var claude = Claude()
    var codex = Codex()
}

// MARK: - Formatting helpers

func fmtTokens(_ v: Double) -> String {
    let n = v
    if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
    if n >= 1_000_000     { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000         { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}
func fmtCost(_ v: Double) -> String { String(format: "$%.2f", v) }

func resetText(_ epoch: Double) -> String {
    guard epoch > 0 else { return "—" }
    let remaining = epoch - Date().timeIntervalSince1970
    if remaining <= 0 { return "now" }
    let h = Int(remaining) / 3600
    let m = (Int(remaining) % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0   { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Status model

final class StatusModel: ObservableObject {
    @Published var running: [String: Bool] = [:]   // bundleID -> running
    @Published var claudeSessions = 0
    @Published var codexSessions = 0
    @Published var music = ""
    @Published var usage = Usage()

    private(set) var icons: [String: NSImage] = [:]
    private var fastTimer: Timer?
    private var slowTimer: Timer?

    private let mediaControl: String? = ["/opt/homebrew/bin/media-control",
                                         "/usr/local/bin/media-control"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private let usageScript: String = {
        if let u = Bundle.main.url(forResource: "glassbar-usage", withExtension: "sh") {
            return u.path
        }
        return NSString(string: "~/Desktop/Code-Projects/GlassBar/Resources/glassbar-usage.sh")
            .expandingTildeInPath
    }()

    func start() {
        loadIcons()
        refreshFast()
        refreshUsage()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshFast()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    private func loadIcons() {
        let ws = NSWorkspace.shared
        for app in GUI_APPS {
            if let url = ws.urlForApplication(withBundleIdentifier: app.id) {
                icons[app.id] = ws.icon(forFile: url.path)
            }
        }
    }

    // Fast: running apps, CLI sessions, now playing
    private func refreshFast() {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var run: [String: Bool] = [:]
        for app in GUI_APPS { run[app.id] = runningIDs.contains(app.id) }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cc = self.sessionLeaderCount(name: "claude")
            let cx = self.sessionLeaderCount(name: "codex")
            let np = self.nowPlaying()
            DispatchQueue.main.async {
                self.running = run
                self.claudeSessions = cc
                self.codexSessions = cx
                self.music = np
            }
        }
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = Self.shell("/bin/zsh", ["-c", "'\(self.usageScript)'"])
            guard let data = out.data(using: .utf8),
                  let u = try? JSONDecoder().decode(Usage.self, from: data) else { return }
            DispatchQueue.main.async { self.usage = u }
        }
    }

    // MARK: detection helpers

    private func sessionLeaderCount(name: String) -> Int {
        let out = Self.shell("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        var pids = Set<Int>(), ppid = [Int: Int](), nameOf = [Int: String]()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let pp = Int(parts[1]) else { continue }
            let comm = parts[2...].joined(separator: " ")
            let base = (comm as NSString).lastPathComponent
            if base == name { pids.insert(pid); ppid[pid] = pp; nameOf[pid] = base }
        }
        return pids.filter { nameOf[ppid[$0] ?? -1] != name }.count
    }

    private func nowPlaying() -> String {
        if let mc = mediaControl {
            let out = Self.shell(mc, ["get"])
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let title = obj["title"] as? String ?? ""
                let artist = obj["artist"] as? String ?? ""
                if !title.isEmpty {
                    var s = artist.isEmpty ? title : "\(artist) — \(title)"
                    if s.count > 42 { s = String(s.prefix(41)) + "…" }
                    return s
                }
            }
        }
        return ""   // nothing playing
    }

    static func shell(_ launch: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Bar UI

struct AppLogo: View {
    let app: AppDef
    let icon: NSImage?
    let running: Bool
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .saturation(running ? 1 : 0)
        .opacity(running ? 1 : 0.32)
        .help("\(app.name): \(running ? "running" : "not running")")
    }
}

struct CLIChip: View {
    let symbol: String
    let label: String
    let sessions: Int
    let trailing: String
    let tint: Color
    var active: Bool { sessions > 0 }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? tint : Color.secondary)
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.primary : Color.secondary)
            if sessions > 0 {
                Text("\(sessions)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tint, in: Capsule())
            }
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

struct Sep: View {
    var body: some View {
        Rectangle().fill(.secondary.opacity(0.22)).frame(width: 1, height: 16)
    }
}

struct BarView: View {
    @ObservedObject var model: StatusModel
    var onToggleUsage: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ForEach(GUI_APPS) { app in
                    AppLogo(app: app, icon: model.icons[app.id], running: model.running[app.id] ?? false)
                }
            }
            Sep()
            CLIChip(symbol: "sparkle", label: "CC", sessions: model.claudeSessions,
                    trailing: fmtCost(model.usage.claude.todayCost), tint: .orange)
            CLIChip(symbol: "chevron.left.forwardslash.chevron.right", label: "cx",
                    sessions: model.codexSessions,
                    trailing: model.usage.codex.weeklyPercent > 0
                        ? "\(Int(model.usage.codex.weeklyPercent))%wk" : "",
                    tint: .green)
            Sep()
            HStack(spacing: 6) {
                Image(systemName: model.music.isEmpty ? "music.note" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.pink)
                Text(model.music.isEmpty ? "Not playing" : model.music)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
            Button(action: onToggleUsage) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Usage details")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Usage popover

struct StatRow: View {
    let label: String
    let value: String
    let sub: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            if !sub.isEmpty {
                Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct GaugeRow: View {
    let label: String
    let percent: Double
    let reset: Double
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent))%").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(percent >= 85 ? .red : (percent >= 60 ? .orange : .primary))
                Text("· resets \(resetText(reset))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule().fill(percent >= 85 ? Color.red : (percent >= 60 ? .orange : .green))
                        .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
                }
            }.frame(height: 5)
        }
    }
}

struct UsageView: View {
    @ObservedObject var model: StatusModel
    var onQuit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Claude
            VStack(alignment: .leading, spacing: 7) {
                Label("Claude Code", systemImage: "sparkle")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                StatRow(label: "Today", value: fmtCost(model.usage.claude.todayCost),
                        sub: fmtTokens(model.usage.claude.todayTokens) + " tok")
                StatRow(label: "This week", value: fmtCost(model.usage.claude.weekCost),
                        sub: fmtTokens(model.usage.claude.weekTokens) + " tok")
                StatRow(label: "5h block", value: fmtCost(model.usage.claude.blockCost),
                        sub: "resets " + resetText(model.usage.claude.blockResetsAt))
                Text("Plan weekly-limit % isn't stored locally — see /usage in Claude Code.")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            // Codex
            VStack(alignment: .leading, spacing: 7) {
                Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                GaugeRow(label: "5-hour", percent: model.usage.codex.primaryPercent,
                         reset: model.usage.codex.primaryResetsAt)
                GaugeRow(label: "Weekly", percent: model.usage.codex.weeklyPercent,
                         reset: model.usage.codex.weeklyResetsAt)
                StatRow(label: "Session", value: fmtTokens(model.usage.codex.sessionTokens) + " tok", sub: "")
                StatRow(label: "Today", value: fmtTokens(model.usage.codex.todayTokens) + " tok", sub: "")
            }
            Divider().opacity(0.5)
            HStack {
                Text(model.music.isEmpty ? "♪ Not playing" : "♪ " + model.music)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: onQuit) {
                    Text("Quit").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 290)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - App delegate / panels

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StatusModel()
    var barPanel: NSPanel!
    var usagePanel: NSPanel!
    let barW: CGFloat = 560, barH: CGFloat = 40

    func applicationDidFinishLaunching(_ note: Notification) {
        // Bar
        let bar = NSHostingView(rootView: BarView(model: model, onToggleUsage: { [weak self] in
            self?.toggleUsage()
        }))
        barPanel = makePanel(size: NSSize(width: barW, height: barH), content: bar, movable: true)

        // Usage popover (hidden initially)
        let usage = NSHostingView(rootView: UsageView(model: model, onQuit: { NSApp.terminate(nil) }))
        usagePanel = makePanel(size: NSSize(width: 322, height: 330), content: usage, movable: false)
        usagePanel.orderOut(nil)

        positionBar()
        barPanel.orderFrontRegardless()
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.positionBar() }
    }

    private func makePanel(size: NSSize, content: NSView, movable: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = movable
        p.hidesOnDeactivate = false
        content.frame = NSRect(origin: .zero, size: size)
        p.contentView = content
        return p
    }

    private func positionBar() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - barW / 2
        let y = vf.maxY - barH - 6
        barPanel.setFrameOrigin(NSPoint(x: x, y: y))
        positionUsage()
    }

    private func positionUsage() {
        let bf = barPanel.frame
        let uw = usagePanel.frame.width
        let x = bf.maxX - uw
        let y = bf.minY - usagePanel.frame.height - 8
        usagePanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func toggleUsage() {
        if usagePanel.isVisible {
            usagePanel.orderOut(nil)
        } else {
            positionUsage()
            usagePanel.orderFrontRegardless()
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
