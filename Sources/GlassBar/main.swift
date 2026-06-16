import AppKit
import SwiftUI
import Combine
import CoreAudio
import UserNotifications
import Darwin

// MARK: - Config

struct AppDef: Identifiable {
    let id: String          // bundle identifier
    let name: String
    let tint: Color
}
let GUI_APPS: [AppDef] = [
    AppDef(id: "com.microsoft.VSCode",           name: "VS Code", tint: .blue),
    AppDef(id: "com.todesktop.230313mzl4w4u92",  name: "Cursor",  tint: .gray),
    AppDef(id: "com.anthropic.claudefordesktop", name: "Claude",  tint: .orange),
    AppDef(id: "com.openai.chat",                name: "ChatGPT", tint: .green),
]
let CLAUDE_ICON = "com.anthropic.claudefordesktop"
let CODEX_ICON  = "com.openai.chat"
let CLAUDE_MASCOT = "🦀"     // crawls across the screen when a Claude session finishes
let CODEX_MASCOT  = "🦊"     // appears when a Codex session finishes

// MARK: - Models

struct Session: Identifiable {
    var sessionId: String
    var name: String
    var cwd: String
    var pid: Int
    var status: String
    var tokens: Int
    var id: String { sessionId.isEmpty ? "pid-\(pid)" : sessionId }
    var project: String { let p = (cwd as NSString).lastPathComponent; return p.isEmpty ? name : p }
}

struct Limits: Codable {
    struct Claude: Codable {
        var ok = 0
        var fiveHourPercent = 0.0, fiveHourResetsAt = 0.0
        var weekPercent = 0.0, weekResetsAt = 0.0
        var sonnetPercent = -1.0, opusPercent = -1.0
        var extraUsed = 0.0, extraLimit = 0.0, extraCurrency = ""
        var todayCost = 0.0, todayTokens = 0.0, weekCost = 0.0, weekTokens = 0.0
        var sessionTokens: [String: Double] = [:]
    }
    struct Codex: Codable {
        var primaryPercent = 0.0, primaryResetsAt = 0.0
        var weeklyPercent = 0.0, weeklyResetsAt = 0.0
        var todayTokens = 0.0
    }
    var claude = Claude()
    var codex = Codex()
}

// MARK: - Formatting

func fmtTokens(_ v: Double) -> String {
    if v >= 1_000_000_000 { return String(format: "%.1fB", v/1e9) }
    if v >= 1_000_000 { return String(format: "%.1fM", v/1e6) }
    if v >= 1_000 { return String(format: "%.0fK", v/1e3) }
    return String(format: "%.0f", v)
}
func fmtCost(_ v: Double) -> String { String(format: "$%.2f", v) }
func resetText(_ e: Double) -> String {
    guard e > 0 else { return "—" }
    let r = e - Date().timeIntervalSince1970
    if r <= 0 { return "now" }
    let h = Int(r)/3600, m = (Int(r)%3600)/60
    if h >= 24 { return "\(h/24)d \(h%24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
func pctColor(_ p: Double) -> Color { p >= 85 ? .red : (p >= 60 ? .orange : .green) }

// MARK: - Status model

final class StatusModel: ObservableObject {
    @Published var running: [String: Bool] = [:]
    @Published var music = ""
    @Published var claudeSessions: [Session] = []
    @Published var codexSessions: [Session] = []
    @Published var limits = Limits()
    private(set) var icons: [String: NSImage] = [:]

    var onSessionDone: ((_ tool: String, _ title: String, _ pid: Int) -> Void)?

    private var prevClaudeStatus: [String: String] = [:]
    private var prevCodexPids: Set<Int> = []
    private var lastDone: [String: Date] = [:]
    private var started = false

    private var fast: Timer?, slow: Timer?
    private let mediaControl = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private let usageScript: String = {
        if let u = Bundle.main.url(forResource: "glassbar-usage", withExtension: "sh") { return u.path }
        return NSString(string: "~/Desktop/Code-Projects/GlassBar/Resources/glassbar-usage.sh").expandingTildeInPath
    }()

    func start() {
        loadIcons(); refreshUsage(); refreshFast()
        fast = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshFast() }
        slow = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshUsage() }
    }

    private func loadIcons() {
        let ws = NSWorkspace.shared
        for a in GUI_APPS { if let u = ws.urlForApplication(withBundleIdentifier: a.id) { icons[a.id] = ws.icon(forFile: u.path) } }
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = Self.shell("/bin/zsh", ["-c", "'\(self.usageScript)'"])
            guard let d = out.data(using: .utf8), let l = try? JSONDecoder().decode(Limits.self, from: d) else { return }
            DispatchQueue.main.async { self.limits = l }
        }
    }

    private func refreshFast() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var run: [String: Bool] = [:]; for a in GUI_APPS { run[a.id] = ids.contains(a.id) }
        // Sessions: posted immediately (never blocked by now-playing).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cs = self.readClaudeSessions(), xs = self.readCodexSessions()
            DispatchQueue.main.async {
                self.detectDone(claude: cs, codex: xs)
                self.running = run; self.claudeSessions = cs; self.codexSessions = xs
            }
        }
        // Now playing: independent task.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let np = self.nowPlaying() as String? else { return }
            DispatchQueue.main.async { self.music = np }
        }
    }

    // Sessions -----------------------------------------------------------------
    private func readClaudeSessions() -> [Session] {
        let dir = NSString(string: "~/.claude/sessions").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let tok = limits.claude.sessionTokens
        var out: [Session] = []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { continue }
            let sid = obj["sessionId"] as? String ?? ""
            out.append(Session(sessionId: sid, name: (obj["name"] as? String) ?? String(sid.prefix(8)),
                               cwd: obj["cwd"] as? String ?? "", pid: pid,
                               status: obj["status"] as? String ?? "idle", tokens: Int(tok[sid] ?? 0)))
        }
        return out.sorted { (($0.status == "busy" ? 0 : 1), -$0.tokens) < (($1.status == "busy" ? 0 : 1), -$1.tokens) }
    }

    private func readCodexSessions() -> [Session] {
        let pids = Self.shell("/usr/bin/pgrep", ["-x", "codex"]).split(separator: "\n").compactMap { Int($0) }
        let set = Set(pids)
        var out: [Session] = []
        for pid in pids {
            let pp = Int(Self.shell("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespaces)) ?? -1
            if set.contains(pp) { continue }   // worker, not a leader
            let lsof = Self.shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
            let cwd = lsof.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
            out.append(Session(sessionId: "codex-\(pid)", name: (cwd as NSString).lastPathComponent,
                               cwd: cwd, pid: pid, status: "running", tokens: 0))
        }
        return out
    }

    // Done detection -----------------------------------------------------------
    private func detectDone(claude: [Session], codex: [Session]) {
        if started {
            for s in claude where prevClaudeStatus[s.id] == "busy" && s.status != "busy" {
                fireDone(tool: "claude", title: s.project, pid: s.pid, key: s.id)
            }
            let cur = Set(codex.map { $0.pid })
            for pid in prevCodexPids where !cur.contains(pid) {
                fireDone(tool: "codex", title: "Codex session", pid: pid, key: "codex-\(pid)")
            }
        }
        prevClaudeStatus = Dictionary(claude.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        prevCodexPids = Set(codex.map { $0.pid })
        started = true
    }
    private func fireDone(tool: String, title: String, pid: Int, key: String) {
        let now = Date()
        if let l = lastDone[key], now.timeIntervalSince(l) < 30 { return }
        lastDone[key] = now
        onSessionDone?(tool, title, pid)
    }

    // Now playing --------------------------------------------------------------
    private func nowPlaying() -> String {
        if let mc = mediaControl {
            let out = Self.shell(mc, ["get"])
            if let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let title = o["title"] as? String ?? "", artist = o["artist"] as? String ?? ""
                let bundle = (o["bundleIdentifier"] as? String) ?? (o["parentApplicationBundleIdentifier"] as? String) ?? ""
                if !title.isEmpty {
                    var s = artist.isEmpty ? title : "\(artist) — \(title)"
                    if s.count > 40 { s = String(s.prefix(39)) + "…" }
                    return s
                }
                if !bundle.isEmpty { return Self.appName(for: bundle) }   // app making sound, no metadata
            }
        }
        return Self.systemAudioActive() ? "Audio playing" : ""
    }
    static func appName(for b: String) -> String {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u.deletingPathExtension().lastPathComponent }
        return b.components(separatedBy: ".").last ?? b
    }
    static func systemAudioActive() -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return false }
        var run = UInt32(0); sz = UInt32(MemoryLayout<UInt32>.size)
        var r = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &r, 0, nil, &sz, &run) == noErr else { return false }
        return run != 0
    }

    static func shell(_ launch: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        // Drain stdout BEFORE waitUntilExit — large output (e.g. media-control artwork,
        // >64KB) would otherwise fill the pipe buffer and deadlock the child.
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Actions

struct Actions {
    var activateApp: (String) -> Void
    var openTool: (String) -> Void
    var focusSession: (Int) -> Void
    var toggleUsage: () -> Void
    var close: () -> Void
    var quit: () -> Void
}

// MARK: - Shared pieces

struct LogoView: View {
    let icon: NSImage?, running: Bool, badge: Bool, tint: Color
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            (icon.map { Image(nsImage: $0).resizable().interpolation(.high) } ?? Image(systemName: "app.dashed").resizable())
                .frame(width: 20, height: 20).saturation(running ? 1 : 0).opacity(running ? 1 : 0.32)
            if badge {
                Image(systemName: "terminal.fill").font(.system(size: 6, weight: .black)).foregroundStyle(.white)
                    .padding(2).background(Circle().fill(running ? tint : .secondary)).offset(x: 3, y: 3)
            }
        }
    }
}
struct Sep: View { var body: some View { Rectangle().fill(.secondary.opacity(0.22)).frame(width: 1, height: 16) } }

// MARK: - Bar

struct CLIChip: View {
    let icon: NSImage?, name: String, count: Int, pct: String, pctColor: Color, tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LogoView(icon: icon, running: count > 0, badge: true, tint: tint)
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(tint, in: Capsule())
                }
                if !pct.isEmpty { Text(pct).font(.system(size: 11, weight: .semibold)).foregroundStyle(pctColor) }
            }.fixedSize()
        }.buttonStyle(.plain).help("Click to open the latest \(name) session")
    }
}

struct BarView: View {
    @ObservedObject var model: StatusModel
    let actions: Actions
    var cc: Limits.Claude { model.limits.claude }
    var cx: Limits.Codex { model.limits.codex }
    var body: some View {
        HStack(spacing: 11) {
            ForEach(GUI_APPS) { app in
                Button { actions.activateApp(app.id) } label: {
                    LogoView(icon: model.icons[app.id], running: model.running[app.id] ?? false, badge: false, tint: app.tint)
                }.buttonStyle(.plain)
                .help("\(app.name) — \((model.running[app.id] ?? false) ? "running, click to focus" : "click to open")")
            }
            Sep()
            CLIChip(icon: model.icons[CLAUDE_ICON], name: "Claude Code", count: model.claudeSessions.count,
                    pct: cc.ok == 1 ? "5h \(Int(cc.fiveHourPercent))%" : "", pctColor: pctColor(cc.fiveHourPercent),
                    tint: .orange) { actions.openTool("claude") }
            CLIChip(icon: model.icons[CODEX_ICON], name: "Codex", count: model.codexSessions.count,
                    pct: cx.weeklyPercent > 0 ? "wk \(Int(cx.weeklyPercent))%" : "", pctColor: pctColor(cx.weeklyPercent),
                    tint: .green) { actions.openTool("codex") }
            Sep()
            HStack(spacing: 6) {
                Image(systemName: model.music.isEmpty ? "music.note" : "waveform").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.pink)
                Text(model.music.isEmpty ? "Not playing" : model.music).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.primary)
            }.frame(width: 170, alignment: .leading)
            Button(action: actions.toggleUsage) {
                Image(systemName: "chevron.down.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Usage & sessions")
        }
        .padding(.horizontal, 15).padding(.vertical, 8).fixedSize()
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Usage popover

struct Gauge: View {
    let label: String, pct: Double, reset: Double
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(pct))%").font(.system(size: 11, weight: .bold)).foregroundStyle(pctColor(pct))
                Text("· resets \(resetText(reset))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule().fill(pctColor(pct)).frame(width: max(0, min(1, pct/100)) * g.size.width)
                }
            }.frame(height: 5)
        }
    }
}
struct Stat: View {
    let label: String, value: String, sub: String
    var body: some View {
        HStack { Text(label).font(.system(size: 11)).foregroundStyle(.secondary); Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)); if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundStyle(.secondary) } }
    }
}
struct SessionRow: View {
    let s: Session, focus: (Int) -> Void
    var dot: Color { s.status == "busy" ? .green : (s.status == "waiting" ? .orange : .secondary) }
    var body: some View {
        Button { focus(s.pid) } label: {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(s.project).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                if s.tokens > 0 { Text(fmtTokens(Double(s.tokens))).font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(s.status).font(.system(size: 9)).foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.forward.app").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct UsageView: View {
    @ObservedObject var model: StatusModel
    let actions: Actions
    var cc: Limits.Claude { model.limits.claude }
    var cx: Limits.Codex { model.limits.codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Running & Usage").font(.system(size: 12, weight: .bold))
                Spacer()
                Button(action: actions.close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // ---- Claude ----
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            LogoView(icon: model.icons[CLAUDE_ICON], running: true, badge: true, tint: .orange)
                            Text("Claude Code").font(.system(size: 12, weight: .bold))
                            Spacer(); Text("\(model.claudeSessions.count) live").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if cc.ok == 1 {
                            Gauge(label: "Session · 5h", pct: cc.fiveHourPercent, reset: cc.fiveHourResetsAt)
                            Gauge(label: "Weekly", pct: cc.weekPercent, reset: cc.weekResetsAt)
                            if cc.sonnetPercent >= 0 { Gauge(label: "Weekly · Sonnet", pct: cc.sonnetPercent, reset: cc.weekResetsAt) }
                            if cc.opusPercent >= 0 { Gauge(label: "Weekly · Opus", pct: cc.opusPercent, reset: cc.weekResetsAt) }
                        } else {
                            Text("Limits loading… (refreshes every 5 min; first read needs a Keychain Allow).")
                                .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        Stat(label: "Today", value: fmtCost(cc.todayCost), sub: fmtTokens(cc.todayTokens) + " tok")
                        Stat(label: "This week", value: fmtCost(cc.weekCost), sub: fmtTokens(cc.weekTokens) + " tok")
                        if cc.extraLimit > 0 {
                            Stat(label: "Extra credits", value: "\(Int(cc.extraUsed))/\(Int(cc.extraLimit)) \(cc.extraCurrency)", sub: "")
                        }
                        Text("Limits are account-wide (shared by all sessions).").font(.system(size: 9)).foregroundStyle(.tertiary)
                        if model.claudeSessions.isEmpty {
                            Text("No live sessions").font(.system(size: 10)).foregroundStyle(.tertiary)
                        } else {
                            ForEach(model.claudeSessions) { SessionRow(s: $0, focus: actions.focusSession) }
                        }
                    }
                    Divider().opacity(0.5)
                    // ---- Codex ----
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            LogoView(icon: model.icons[CODEX_ICON], running: true, badge: true, tint: .green)
                            Text("Codex").font(.system(size: 12, weight: .bold))
                            Spacer(); Text("\(model.codexSessions.count) live").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Gauge(label: "Session · 5h", pct: cx.primaryPercent, reset: cx.primaryResetsAt)
                        Gauge(label: "Weekly", pct: cx.weeklyPercent, reset: cx.weeklyResetsAt)
                        Stat(label: "Today", value: fmtTokens(cx.todayTokens) + " tok", sub: "")
                        if model.codexSessions.isEmpty {
                            Text("No live sessions").font(.system(size: 10)).foregroundStyle(.tertiary)
                        } else {
                            ForEach(model.codexSessions) { SessionRow(s: $0, focus: actions.focusSession) }
                        }
                    }
                }.padding(.trailing, 4)
            }.frame(height: 380)
            Divider().opacity(0.5)
            HStack {
                Image(systemName: model.music.isEmpty ? "music.note" : "waveform").font(.system(size: 10))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.pink)
                Text(model.music.isEmpty ? "Not playing" : model.music).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: actions.quit) { Text("Quit").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(.red)
            }
        }
        .padding(16).frame(width: 344)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
    }
}

// MARK: - Mascot

struct MascotView: View {
    let emoji: String, label: String, width: CGFloat
    let onDone: () -> Void
    @State private var x: CGFloat = -160
    @State private var hop = false
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(emoji).font(.system(size: 58)).rotationEffect(.degrees(hop ? 10 : -6))
                Text(label).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
            }
            .offset(x: x, y: hop ? -16 : 0)
            .padding(.bottom, 70)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) { hop = true }
            withAnimation(.linear(duration: 6)) { x = width + 180 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { onDone() }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = StatusModel()
    var barPanel: NSPanel!, usagePanel: NSPanel!
    var barHost: NSHostingView<BarView>!, usageHost: NSHostingView<UsageView>!
    var clickMonitor: Any?
    var mascots: [NSPanel] = []
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        let actions = Actions(
            activateApp: { [weak self] in self?.activateApp($0) },
            openTool: { [weak self] in self?.openTool($0) },
            focusSession: { [weak self] in self?.focusSession(pid: $0) },
            toggleUsage: { [weak self] in self?.toggleUsage() },
            close: { [weak self] in self?.hideUsage() },
            quit: { NSApp.terminate(nil) })

        barHost = NSHostingView(rootView: BarView(model: model, actions: actions)); barHost.sizingOptions = [.intrinsicContentSize]
        barPanel = makePanel(movable: true); barPanel.contentView = barHost

        usageHost = NSHostingView(rootView: UsageView(model: model, actions: actions)); usageHost.sizingOptions = [.intrinsicContentSize]
        usagePanel = makePanel(movable: false); usagePanel.contentView = usageHost; usagePanel.orderOut(nil)

        model.onSessionDone = { [weak self] tool, title, pid in self?.sessionDone(tool: tool, title: title, pid: pid) }
        model.start()
        relayout(); barPanel.orderFrontRegardless()
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.relayout() }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func makePanel(movable: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isFloatingPanel = true; p.backgroundColor = .clear; p.isOpaque = false
        p.hasShadow = true; p.isMovableByWindowBackground = movable; p.hidesOnDeactivate = false
        return p
    }

    private func relayout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let bs = barHost.fittingSize
        if bs.width > 20 { barPanel.setContentSize(bs); barPanel.setFrameOrigin(NSPoint(x: vf.midX - bs.width/2, y: vf.maxY - bs.height - 6)) }
        let us = usageHost.fittingSize
        if us.width > 20 { usagePanel.setContentSize(us) }
        positionUsage()
    }
    private func positionUsage() {
        let bf = barPanel.frame
        usagePanel.setFrameOrigin(NSPoint(x: bf.maxX - usagePanel.frame.width, y: bf.minY - usagePanel.frame.height - 8))
    }

    private func toggleUsage() { usagePanel.isVisible ? hideUsage() : showUsage() }
    private func showUsage() {
        positionUsage(); usagePanel.orderFrontRegardless()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hideUsage() }
    }
    private func hideUsage() {
        usagePanel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func activateApp(_ bundleID: String) {
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            a.activate(options: [.activateAllWindows])
        } else if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    private func openTool(_ tool: String) {
        let sessions = tool == "claude" ? model.claudeSessions : model.codexSessions
        if let s = sessions.first { focusSession(pid: s.pid) } else { toggleUsage() }
    }
    private func focusSession(pid: Int) {
        var cur = pid
        for _ in 0..<14 {
            if let a = NSRunningApplication(processIdentifier: pid_t(cur)), a.activationPolicy == .regular {
                a.activate(options: [.activateAllWindows]); hideUsage(); return
            }
            guard let pp = Int(StatusModel.shell("/bin/ps", ["-o", "ppid=", "-p", "\(cur)"]).trimmingCharacters(in: .whitespaces)), pp > 1 else { break }
            cur = pp
        }
        hideUsage()
    }

    // Session done → notification + mascot
    private func sessionDone(tool: String, title: String, pid: Int) {
        let c = UNMutableNotificationContent()
        c.title = tool == "claude" ? "🦀 Claude Code finished" : "🦊 Codex finished"
        c.body = "\(title) — done"
        c.sound = .default
        c.userInfo = ["pid": pid]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        showMascot(tool: tool, title: title)
    }
    private func showMascot(tool: String, title: String) {
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: MascotView(emoji: tool == "claude" ? CLAUDE_MASCOT : CODEX_MASCOT,
            label: "✓ \(title)", width: screen.frame.width) { [weak self] in
                panel.orderOut(nil); self?.mascots.removeAll { $0 === panel }
            })
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host
        mascots.append(panel)
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    // Notification tap → focus the session
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if let pid = r.notification.request.content.userInfo["pid"] as? Int { focusSession(pid: pid) }
        done()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
