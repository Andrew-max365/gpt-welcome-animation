import AppKit
import CoreGraphics
import QuartzCore
import ServiceManagement
import OSLog

let helperBundleID = "io.github.andrew-max365.gpt-welcome-animation"
let lifecycleLog = Logger(subsystem: helperBundleID, category: "lifecycle")

struct MotionAssets {
    let letters: TracedPath
    let bridge: TracedPath

    static func load() -> MotionAssets? {
        guard let url = Bundle.main.url(forResource: "Welcome-Andrew", withExtension: "html"),
              let markup = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func path(_ name: String) -> TracedPath? {
            let pattern = "(?s)<path id=\"" + name + "\" d=\"([^\"]+)\""
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup)),
                  let r = Range(m.range(at: 1), in: markup) else { return nil }
            return TracedPath.parse(String(markup[r]))
        }
        guard let letters = path("letterGeometry"), let bridge = path("bridgeGeometry") else { return nil }
        return MotionAssets(letters: letters, bridge: bridge)
    }
}

@MainActor
final class OverlayPlayback: NSObject {
    let pid: pid_t
    private(set) var windowID: CGWindowID
    let panel: OverlayPanel
    let motion: MotionView
    private let report: (String) -> Void
    private var onFinish: (() -> Void)?
    private var display: CADisplayLink?
    private var watchdog: Timer?
    private var startTime: CFTimeInterval = 0
    private var clock = PlaybackClock()
    private var focusLostAt: CFTimeInterval?
    private var windowLostAt: CFTimeInterval?
    private var portalReported = false
    private var closed = false

    init(pid: pid_t, target: TargetWindow, assets: MotionAssets, report: @escaping (String) -> Void, onFinish: @escaping () -> Void) {
        self.pid = pid
        windowID = target.id
        self.report = report
        self.onFinish = onFinish
        panel = OverlayPanel(contentRect: target.rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        motion = MotionView(frame: NSRect(origin: .zero, size: target.rect.size), letters: assets.letters, bridge: assets.bridge)
        panel.contentView = motion
        super.init()
    }

    func start() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("not-frontmost"); return }
        startTime = CACurrentMediaTime()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        guard !closed else { return }
        // Use the actual display refresh clock, not a free-running animation timer.
        let link = panel.displayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(max(1, min(60, panel.screen?.maximumFramesPerSecond ?? 60)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        display = link
        let timer = Timer(timeInterval: 0.085, target: self, selector: #selector(checkWindow(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        report("OVERLAY_STARTED pid=\(pid) window=\(windowID) size=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard focusLostAt == nil, windowLostAt == nil, panel.isVisible else { clock.pause(); return }
        let elapsed = clock.tick(at: CACurrentMediaTime())
        if elapsed >= Double(MotionTiming.portalStart), !portalReported {
            portalReported = true
            report("PORTAL_OPEN frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        }
        if elapsed >= Double(MotionTiming.finish) { stop("animation-complete"); return }
        motion.t = CGFloat(elapsed)
        motion.needsDisplay = true
    }

    @objc private func checkWindow(_ timer: Timer) {
        refreshTarget()
    }

    func refreshTarget() {
        guard !closed else { return }
        let now = CACurrentMediaTime()
        if now - startTime > 22 { stop("animation-timeout"); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if focusLostAt == nil {
                focusLostAt = now
                clock.pause()
                panel.orderOut(nil)
                report("OVERLAY_PAUSED reason=focus-change elapsed=\(String(format: "%.2f", clock.elapsed))")
            }
            if let lost = focusLostAt, now - lost > 0.85 { stop("target-no-longer-frontmost") }
            return
        }
        if focusLostAt != nil { focusLostAt = nil; clock.pause(); report("OVERLAY_RESUMED reason=focus-returned") }

        // Electron-style startup windows can be destroyed and replaced while the
        // app PID remains unchanged. Follow the frontmost eligible GPT window.
        guard let target = targetWindow(pid: pid) else {
            if windowLostAt == nil {
                windowLostAt = now
                clock.pause()
                report("OVERLAY_PAUSED reason=window-rebuilding elapsed=\(String(format: "%.2f", clock.elapsed))")
            }
            if let lost = windowLostAt {
                // Keep a very brief same-app gap visually covered; don't cover a
                // different application or a minimized window indefinitely.
                if now - lost > 0.55, panel.isVisible { panel.orderOut(nil) }
                if now - lost > 2.5 { stop("target-no-longer-visible") }
            }
            return
        }
        if windowLostAt != nil { windowLostAt = nil; clock.pause(); report("OVERLAY_RESUMED reason=window-returned") }
        if target.id != windowID {
            report("WINDOW_REBOUND old=\(windowID) new=\(target.id)")
            windowID = target.id
        }
        if target.rect != panel.frame {
            panel.setFrame(target.rect, display: false)
            motion.needsDisplay = true
        }
        if !panel.isVisible {
            clock.pause()
            panel.orderFrontRegardless()
            motion.needsDisplay = true
        }
    }

    func stop(_ reason: String) {
        guard !closed else { return }
        closed = true
        display?.invalidate(); display = nil
        watchdog?.invalidate(); watchdog = nil
        panel.orderOut(nil); panel.close()
        report("OVERLAY_CLOSED reason=\(reason) elapsed=\(String(format: "%.2f", clock.elapsed))")
        let finish = onFinish; onFinish = nil; finish?()
    }
}

@MainActor
final class LaunchMonitor: NSObject {
    let targetBundleID: String
    let report: (String) -> Void
    private let assets: MotionAssets
    private let workspace = NSWorkspace.shared
    private let startTime = CACurrentMediaTime()
    private let loginGrace: CFTimeInterval
    private let enabled: () -> Bool
    private var gate: ColdLaunchGate
    private var candidate: (pid: pid_t, started: CFTimeInterval)?
    private var windowWait: Timer?
    private var playback: OverlayPlayback?

    init(targetBundleID: String = gptBundleID, assets: MotionAssets, loginGrace: CFTimeInterval = 4, enabled: @escaping () -> Bool = { true }, report: @escaping (String) -> Void = { _ in }) {
        self.targetBundleID = targetBundleID
        self.assets = assets
        self.loginGrace = loginGrace
        self.enabled = enabled
        self.report = report
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).filter { !$0.isTerminated }.map(\.processIdentifier)
        gate = ColdLaunchGate(existing: Set(existing))
        super.init()
        let center = workspace.notificationCenter
        center.addObserver(self, selector: #selector(launched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(terminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionEnded(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionEnded(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        report("MONITOR_READY existing=\(existing.count)")
    }

    private func runningApp(_ n: Notification) -> NSRunningApplication? {
        n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func shouldSuppress(_ now: CFTimeInterval) -> Bool { now - startTime < loginGrace || !enabled() }

    @objc private func launched(_ n: Notification) {
        guard let app = runningApp(n), app.bundleIdentifier == targetBundleID else { return }
        let now = CACurrentMediaTime(), pid = app.processIdentifier
        let front = workspace.frontmostApplication?.processIdentifier == pid
        if gate.launched(pid, at: now, foreground: front, suppress: shouldSuppress(now)) {
            report("COLD_LAUNCH pid=\(pid) event=didLaunch")
            requestPlayback(pid: pid)
        } else { report("LAUNCH_OBSERVED pid=\(pid) foreground=\(front)") }
    }

    @objc private func activated(_ n: Notification) {
        guard let app = runningApp(n) else { return }
        guard app.bundleIdentifier == targetBundleID else {
            // A transient startup focus event mustn't permanently consume the
            // cold-launch animation. The watchdog hides it and applies a grace period.
            playback?.refreshTarget()
            return
        }
        playback?.refreshTarget()
        let now = CACurrentMediaTime(), pid = app.processIdentifier
        let recent = app.launchDate.map { Date().timeIntervalSince($0) < 6 } ?? false
        if gate.activated(pid, at: now, recentLaunch: recent, suppress: shouldSuppress(now)) {
            report("COLD_LAUNCH pid=\(pid) event=didActivate")
            requestPlayback(pid: pid)
        } else { report("WARM_ACTIVATION_IGNORED pid=\(pid)") }
    }

    @objc private func terminated(_ n: Notification) {
        guard let app = runningApp(n), app.bundleIdentifier == targetBundleID else { return }
        let pid = app.processIdentifier
        gate.terminated(pid)
        if candidate?.pid == pid { cancelWaiting() }
        if playback?.pid == pid { playback?.stop("target-terminated") }
        report("TARGET_TERMINATED pid=\(pid)")
    }

    @objc private func sessionEnded(_ n: Notification) {
        cancelWaiting()
        playback?.stop("session-inactive")
    }

    func requestPlayback(pid: pid_t) {
        guard playback == nil, candidate?.pid != pid else { return }
        cancelWaiting()
        candidate = (pid, CACurrentMediaTime())
        let timer = Timer(timeInterval: 0.035, target: self, selector: #selector(pollWindowTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        windowWait = timer
        pollWindow()
    }

    @objc private func pollWindowTick(_ timer: Timer) { pollWindow() }

    private func pollWindow() {
        guard let next = candidate else { cancelWaiting(); return }
        let elapsed = CACurrentMediaTime() - next.started
        if elapsed > 8 { report("PLAYBACK_SKIPPED no-window"); cancelWaiting(); return }
        if workspace.frontmostApplication?.processIdentifier != next.pid {
            if elapsed > 0.85 { cancelWaiting() }
            return
        }
        guard let target = targetWindow(pid: next.pid) else { return }
        cancelWaiting()
        let player = OverlayPlayback(pid: next.pid, target: target, assets: assets, report: report) { [weak self] in self?.playback = nil }
        playback = player
        player.start()
    }

    private func cancelWaiting() { windowWait?.invalidate(); windowWait = nil; candidate = nil }

    func stop() {
        workspace.notificationCenter.removeObserver(self)
        cancelWaiting()
        playback?.stop("monitor-disabled")
    }
}

func serviceState() -> String {
    switch SMAppService.mainApp.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notRegistered: return "notRegistered"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: LaunchMonitor?
    private let args = CommandLine.arguments
    private var dialogOpen = false
    private func makeMonitor(_ assets: MotionAssets) -> LaunchMonitor {
        let verbose = args.contains("--verbose")
        return LaunchMonitor(assets: assets, loginGrace: 4, enabled: { SMAppService.mainApp.status == .enabled }, report: { message in
            // A handful of lifecycle messages per launch, managed by macOS; no local log file or screen data.
            lifecycleLog.info("\(message, privacy: .public)")
            if verbose { print(message); fflush(stdout) }
        })
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let assets = MotionAssets.load() else { print("MOTION_ASSETS_INVALID"); NSApp.terminate(nil); return }
        #if INTEGRATION_TESTS
        if let i = args.firstIndex(of: "--test-listen"), i + 1 < args.count {
            monitor = LaunchMonitor(targetBundleID: args[i + 1], assets: assets, loginGrace: 0, report: { print($0); fflush(stdout) })
            return
        }
        #endif
        if args.contains("--enable"), SMAppService.mainApp.status != .enabled, SMAppService.mainApp.status != .requiresApproval {
            do { try SMAppService.mainApp.register() }
            catch { print("LOGIN_REGISTRATION_ERROR \(error.localizedDescription)"); fflush(stdout); NSApp.terminate(nil); return }
        }
        if SMAppService.mainApp.status == .enabled || (args.contains("--enable") && SMAppService.mainApp.status == .requiresApproval) {
            // The currently running ChatGPT is already in the snapshot, so installation
            // itself never triggers the animation.
            monitor = makeMonitor(assets)
            print("LOGIN_ITEM=\(serviceState())"); fflush(stdout)
            return
        }
        showControl(assets: assets)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let assets = MotionAssets.load() else { return false }
        showControl(assets: assets)
        return false
    }

    private func showControl(assets: MotionAssets) {
        guard !dialogOpen else { return }
        dialogOpen = true
        defer { dialogOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GPT Welcome"
        let enabled = SMAppService.mainApp.status == .enabled
        let pending = SMAppService.mainApp.status == .requiresApproval
        if enabled || pending {
            alert.informativeText = enabled ? "冷启动动画已启用。切换到已运行的 ChatGPT 时不会重播。" : "请在系统设置的登录项中允许 GPT Welcome 启动。"
            alert.addButton(withTitle: pending ? "打开登录项设置" : "播放预览")
            alert.addButton(withTitle: "停用并退出")
            alert.addButton(withTitle: "关闭")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                if pending { SMAppService.openSystemSettingsLoginItems() }
                else { if monitor == nil { monitor = makeMonitor(assets) }; preview() }
            } else if choice == .alertSecondButtonReturn { disable() }
        } else {
            alert.informativeText = "开启后，只有 ChatGPT 前台冷启动才显示动画。不会修改官方应用，也不会读取屏幕内容。"
            alert.addButton(withTitle: "启用")
            alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn {
                do {
                    try SMAppService.mainApp.register()
                    monitor = makeMonitor(assets)
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { showError(error.localizedDescription); NSApp.terminate(nil) }
            } else { NSApp.terminate(nil) }
        }
    }

    private func preview() {
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: gptBundleID).first(where: { !$0.isTerminated }) else {
            showError("请先打开 ChatGPT 再预览。"); return
        }
        _ = target.activate(options: [])
        let pid = target.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.monitor?.requestPlayback(pid: pid) }
    }

    private func disable() {
        do {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            monitor?.stop(); monitor = nil
            NSApp.terminate(nil)
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "GPT Welcome"; alert.informativeText = message; alert.runModal()
    }

    func applicationWillTerminate(_ n: Notification) { monitor?.stop() }
}

let args = CommandLine.arguments
if args.contains("--self-test") {
    let passed = runGateTests()
    let assetsValid = MotionAssets.load().map { $0.letters.length > 1000 && $0.bridge.length > 100 } ?? false
    print("MOTION_ASSETS=\(assetsValid ? "PASS" : "FAIL")")
    exit(passed && assetsValid ? 0 : 1)
}
if args.contains("--status") {
    let other = NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID).filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    print("LOGIN_ITEM=\(serviceState()) RUNNING=\(!other.isEmpty)")
    exit(0)
}
if args.contains("--unregister") {
    do {
        if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID) where instance.processIdentifier != ProcessInfo.processInfo.processIdentifier { _ = instance.terminate() }
        print("LOGIN_ITEM=\(serviceState())")
        exit(0)
    } catch { print("UNREGISTER_ERROR \(error.localizedDescription)"); exit(1) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
