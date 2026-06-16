import AppKit
import SwiftUI
import Combine
import CoreAudio

// MARK: - Watched GUI apps

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

// MARK: - Data model (decoded from glassbar-usage.sh)

struct Session: Codable, Identifiable {
    var name: String
    var cwd: String
    var pid: Int
    var status: String
    var id: Int { pid }
    var project: String {
        let p = (cwd as NSString).lastPathComponent
        return p.isEmpty ? name : p
    }
}
struct Usage: Codable {
    struct Claude: Codable {
        var ok = 0
        var fiveHourPercent = 0.0, fiveHourResetsAt = 0.0
        var weekPercent = 0.0, weekResetsAt = 0.0
        var sonnetPercent = -1.0, opusPercent = -1.0
        var sessions: [Session] = []
    }
    struct Codex: Codable {
        var primaryPercent = 0.0, primaryResetsAt = 0.0
        var weeklyPercent = 0.0, weeklyResetsAt = 0.0
        var sessions: [Session] = []
    }
    var claude = Claude()
    var codex = Codex()
}

// MARK: - Formatting

func resetText(_ epoch: Double) -> String {
    guard epoch > 0 else { return "—" }
    let r = epoch - Date().timeIntervalSince1970
    if r <= 0 { return "now" }
    let h = Int(r) / 3600, m = (Int(r) % 3600) / 60
    if h >= 24 { return "\(h/24)d \(h%24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
func pctColor(_ p: Double) -> Color { p >= 85 ? .red : (p >= 60 ? .orange : .green) }

// MARK: - Status model

final class StatusModel: ObservableObject {
    @Published var running: [String: Bool] = [:]
    @Published var music = ""
    @Published var usage = Usage()
    private(set) var icons: [String: NSImage] = [:]

    private var fast: Timer?, slow: Timer?
    private let mediaControl = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private let usageScript: String = {
        if let u = Bundle.main.url(forResource: "glassbar-usage", withExtension: "sh") { return u.path }
        return NSString(string: "~/Desktop/Code-Projects/GlassBar/Resources/glassbar-usage.sh").expandingTildeInPath
    }()

    func start() {
        loadIcons(); refreshFast(); refreshUsage()
        fast = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshFast() }
        slow = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshUsage() }
    }

    private func loadIcons() {
        let ws = NSWorkspace.shared
        for app in GUI_APPS {
            if let url = ws.urlForApplication(withBundleIdentifier: app.id) { icons[app.id] = ws.icon(forFile: url.path) }
        }
    }

    private func refreshFast() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var run: [String: Bool] = [:]
        for a in GUI_APPS { run[a.id] = ids.contains(a.id) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let np = self.nowPlaying()
            DispatchQueue.main.async { self.running = run; self.music = np }
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

    // Now playing: media-control → app name → CoreAudio "something is playing"
    private func nowPlaying() -> String {
        if let mc = mediaControl {
            let out = Self.shell(mc, ["get"])
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let title = obj["title"] as? String ?? ""
                let artist = obj["artist"] as? String ?? ""
                let bundle = (obj["bundleIdentifier"] as? String)
                    ?? (obj["parentApplicationBundleIdentifier"] as? String) ?? ""
                if !title.isEmpty {
                    var s = artist.isEmpty ? title : "\(artist) — \(title)"
                    if s.count > 40 { s = String(s.prefix(39)) + "…" }
                    return s
                }
                if !bundle.isEmpty { return Self.appName(for: bundle) }
            }
        }
        if let s = appleScriptTrack(), !s.isEmpty { return s }
        return Self.systemAudioActive() ? "Audio playing" : ""
    }

    private func appleScriptTrack() -> String? {
        let script = """
        set out to ""
        tell application "System Events" to set apps to name of processes
        if apps contains "Spotify" then
          tell application "Spotify"
            if player state is playing then set out to (artist of current track) & " — " & (name of current track)
          end tell
        end if
        if out is "" and apps contains "Music" then
          tell application "Music"
            if player state is playing then set out to (artist of current track) & " — " & (name of current track)
          end tell
        end if
        return out
        """
        let s = Self.shell("/usr/bin/osascript", ["-e", script])
        return s.isEmpty ? nil : s
    }

    static func appName(for bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundle.components(separatedBy: ".").last ?? bundle
    }

    static func systemAudioActive() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev) == noErr,
              dev != 0 else { return false }
        var running = UInt32(0); sz = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &raddr, 0, nil, &sz, &running) == noErr else { return false }
        return running != 0
    }

    static func shell(_ launch: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Actions passed into views

struct Actions {
    var activateApp: (String) -> Void
    var focusSession: (Int) -> Void
    var toggleUsage: () -> Void
    var close: () -> Void
    var quit: () -> Void
}

// MARK: - Bar pieces

struct LogoView: View {
    let icon: NSImage?, running: Bool, badge: Bool, tint: Color
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            (icon.map { Image(nsImage: $0).resizable().interpolation(.high) }
                ?? Image(systemName: "app.dashed").resizable())
                .frame(width: 20, height: 20)
                .saturation(running ? 1 : 0).opacity(running ? 1 : 0.32)
            if badge {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 6, weight: .black)).foregroundStyle(.white)
                    .padding(2).background(Circle().fill(running ? tint : .secondary))
                    .offset(x: 3, y: 3)
            }
        }
    }
}

struct CLIChip: View {
    let icon: NSImage?, name: String, count: Int, pct: String, tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LogoView(icon: icon, running: count > 0, badge: true, tint: tint)
                Text(name).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(tint, in: Capsule())
                }
                if !pct.isEmpty {
                    Text(pct).font(.system(size: 11, weight: .semibold))
                }
            }.fixedSize()
        }.buttonStyle(.plain)
    }
}

struct Sep: View { var body: some View { Rectangle().fill(.secondary.opacity(0.22)).frame(width: 1, height: 16) } }

struct BarView: View {
    @ObservedObject var model: StatusModel
    let actions: Actions
    var cc: Usage.Claude { model.usage.claude }
    var cx: Usage.Codex { model.usage.codex }

    var body: some View {
        HStack(spacing: 11) {
            ForEach(GUI_APPS) { app in
                Button { actions.activateApp(app.id) } label: {
                    LogoView(icon: model.icons[app.id], running: model.running[app.id] ?? false, badge: false, tint: app.tint)
                }
                .buttonStyle(.plain)
                .help("\(app.name) — \((model.running[app.id] ?? false) ? "running, click to focus" : "click to open")")
            }
            Sep()
            CLIChip(icon: model.icons[CLAUDE_ICON], name: "Claude Code", count: cc.sessions.count,
                    pct: cc.ok == 1 ? "5h \(Int(cc.fiveHourPercent))%" : "", tint: .orange,
                    action: actions.toggleUsage)
                .foregroundStyle(cc.ok == 1 ? pctColor(cc.fiveHourPercent) : .secondary)
            CLIChip(icon: model.icons[CODEX_ICON], name: "Codex", count: cx.sessions.count,
                    pct: cx.weeklyPercent > 0 ? "wk \(Int(cx.weeklyPercent))%" : "", tint: .green,
                    action: actions.toggleUsage)
                .foregroundStyle(cx.weeklyPercent > 0 ? pctColor(cx.weeklyPercent) : .secondary)
            Sep()
            HStack(spacing: 6) {
                Image(systemName: model.music.isEmpty ? "music.note" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.pink)
                Text(model.music.isEmpty ? "Not playing" : model.music)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.primary)
            }.frame(width: 180, alignment: .leading)
            Button(action: actions.toggleUsage) {
                Image(systemName: "chevron.down.circle.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Usage & sessions")
        }
        .padding(.horizontal, 15).padding(.vertical, 8)
        .fixedSize()
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

struct SessionRow: View {
    let s: Session, tint: Color
    let focus: (Int) -> Void
    var dotColor: Color {
        switch s.status { case "busy": return .green; case "waiting": return .orange; default: return .secondary }
    }
    var body: some View {
        Button { focus(s.pid) } label: {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.project).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    if s.name != s.project {
                        Text(s.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(s.status).font(.system(size: 9)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward.app").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ToolSection: View {
    let icon: NSImage?, title: String, tint: Color
    let sessions: [Session]
    let focus: (Int) -> Void
    @ViewBuilder var gauges: () -> AnyView
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                LogoView(icon: icon, running: true, badge: true, tint: tint)
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(sessions.count) live").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            gauges()
            if sessions.isEmpty {
                Text("No live sessions").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(sessions) { SessionRow(s: $0, tint: tint, focus: focus) }
                }
            }
        }
    }
}

struct UsageView: View {
    @ObservedObject var model: StatusModel
    let actions: Actions
    var cc: Usage.Claude { model.usage.claude }
    var cx: Usage.Codex { model.usage.codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Running & Usage").font(.system(size: 12, weight: .bold))
                Spacer()
                Button(action: actions.close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ToolSection(icon: model.icons[CLAUDE_ICON], title: "Claude Code", tint: .orange,
                                sessions: cc.sessions, focus: actions.focusSession) {
                        AnyView(VStack(alignment: .leading, spacing: 6) {
                            if cc.ok == 1 {
                                Gauge(label: "Session (5h)", pct: cc.fiveHourPercent, reset: cc.fiveHourResetsAt)
                                Gauge(label: "Weekly", pct: cc.weekPercent, reset: cc.weekResetsAt)
                                if cc.sonnetPercent >= 0 {
                                    Gauge(label: "Weekly · Sonnet", pct: cc.sonnetPercent, reset: cc.weekResetsAt)
                                }
                                if cc.opusPercent >= 0 {
                                    Gauge(label: "Weekly · Opus", pct: cc.opusPercent, reset: cc.weekResetsAt)
                                }
                            } else {
                                Text("Limits unavailable (run a Claude session so the token refreshes, and Allow Keychain).")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Limits are account-wide (shared by all sessions).")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        })
                    }
                    Divider().opacity(0.5)
                    ToolSection(icon: model.icons[CODEX_ICON], title: "Codex", tint: .green,
                                sessions: cx.sessions, focus: actions.focusSession) {
                        AnyView(VStack(alignment: .leading, spacing: 6) {
                            Gauge(label: "Session (5h)", pct: cx.primaryPercent, reset: cx.primaryResetsAt)
                            Gauge(label: "Weekly", pct: cx.weeklyPercent, reset: cx.weeklyResetsAt)
                        })
                    }
                }
            }.frame(maxHeight: 360)
            Divider().opacity(0.5)
            HStack {
                Image(systemName: model.music.isEmpty ? "music.note" : "waveform").font(.system(size: 10))
                    .foregroundStyle(model.music.isEmpty ? Color.secondary : Color.pink)
                Text(model.music.isEmpty ? "Not playing" : model.music)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: actions.quit) { Text("Quit").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.red)
            }
        }
        .padding(16).frame(width: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StatusModel()
    var barPanel: NSPanel!, usagePanel: NSPanel!
    var barHost: NSHostingView<BarView>!
    var clickMonitor: Any?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        let actions = Actions(
            activateApp: { [weak self] in self?.activateApp(bundleID: $0) },
            focusSession: { [weak self] in self?.focusSession(pid: $0) },
            toggleUsage: { [weak self] in self?.toggleUsage() },
            close: { [weak self] in self?.hideUsage() },
            quit: { NSApp.terminate(nil) })

        barHost = NSHostingView(rootView: BarView(model: model, actions: actions))
        barHost.sizingOptions = [.intrinsicContentSize]
        barPanel = makePanel(movable: true)
        barPanel.contentView = barHost

        let usageHost = NSHostingView(rootView: UsageView(model: model, actions: actions))
        usagePanel = makePanel(movable: false)
        usagePanel.contentView = usageHost
        usagePanel.orderOut(nil)

        model.start()
        relayout(); barPanel.orderFrontRegardless()
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.relayout() }
    }

    private func makePanel(movable: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isFloatingPanel = true; p.backgroundColor = .clear; p.isOpaque = false
        p.hasShadow = true; p.isMovableByWindowBackground = movable; p.hidesOnDeactivate = false
        return p
    }

    private func relayout() {
        let s = barHost.fittingSize
        guard s.width > 20, let screen = NSScreen.main else { return }
        barPanel.setContentSize(s)
        let vf = screen.visibleFrame
        barPanel.setFrameOrigin(NSPoint(x: vf.midX - s.width/2, y: vf.maxY - s.height - 6))
        positionUsage()
    }

    private func positionUsage() {
        let bf = barPanel.frame, uw = usagePanel.frame.width, uh = usagePanel.frame.height
        usagePanel.setFrameOrigin(NSPoint(x: bf.maxX - uw, y: bf.minY - uh - 8))
    }

    private func toggleUsage() { usagePanel.isVisible ? hideUsage() : showUsage() }
    private func showUsage() {
        positionUsage(); usagePanel.orderFrontRegardless()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideUsage()
        }
    }
    private func hideUsage() {
        usagePanel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func activateApp(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Walk the parent-process chain until we hit a real GUI app, then focus it.
    private func focusSession(pid: Int) {
        var cur = pid
        for _ in 0..<14 {
            if let app = NSRunningApplication(processIdentifier: pid_t(cur)), app.activationPolicy == .regular {
                app.activate(options: [.activateAllWindows]); hideUsage(); return
            }
            let out = StatusModel.shell("/bin/ps", ["-o", "ppid=", "-p", "\(cur)"]).trimmingCharacters(in: .whitespaces)
            guard let pp = Int(out), pp > 1 else { break }
            cur = pp
        }
        hideUsage()
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
