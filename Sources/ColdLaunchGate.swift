import Foundation

// A PID already seen by the monitor is never replayed on an ordinary activation.
// The tiny grace window accounts for the unspecified ordering of the launch and
// foreground-activation notifications. A background launch expires without playing.
struct ColdLaunchGate {
    private(set) var known: Set<Int32>
    private var pending: [Int32: TimeInterval] = [:]
    let activationGrace: TimeInterval

    init(existing: Set<Int32>, activationGrace: TimeInterval = 1.25) {
        known = existing
        self.activationGrace = activationGrace
    }

    mutating func launched(_ pid: Int32, at now: TimeInterval, foreground: Bool, suppress: Bool = false) -> Bool {
        expire(at: now)
        guard pid > 0, known.insert(pid).inserted else { return false }
        if suppress { return false }
        if foreground { return true }
        pending[pid] = now + activationGrace
        return false
    }

    mutating func activated(_ pid: Int32, at now: TimeInterval, recentLaunch: Bool, suppress: Bool = false) -> Bool {
        expire(at: now)
        guard pid > 0 else { return false }
        let isNew = known.insert(pid).inserted
        let deadline = pending.removeValue(forKey: pid)
        if suppress { return false }
        if let deadline { return now <= deadline }
        // Some macOS versions deliver activation before didLaunch.
        return isNew && recentLaunch
    }

    mutating func terminated(_ pid: Int32) {
        known.remove(pid)
        pending.removeValue(forKey: pid)
    }

    private mutating func expire(at now: TimeInterval) {
        pending = pending.filter { $0.value >= now }
    }
}

func runGateTests() -> Bool {
    var failures = 0
    func check(_ condition: Bool, _ description: String) {
        if !condition { print("FAIL: \(description)"); failures += 1 }
    }
    var gate = ColdLaunchGate(existing: [100])
    check(!gate.activated(100, at: 1, recentLaunch: true), "an already-running GPT never plays")
    check(gate.launched(101, at: 2, foreground: true), "fresh foreground launch plays")
    check(!gate.activated(101, at: 2.1, recentLaunch: true), "duplicate activation suppressed")
    check(!gate.launched(102, at: 3, foreground: false), "background launch does not play")
    check(!gate.activated(102, at: 5, recentLaunch: true), "later background-to-foreground switch suppressed")
    check(!gate.launched(103, at: 6, foreground: false), "wait for notification ordering")
    check(gate.activated(103, at: 6.1, recentLaunch: true), "immediate foreground activation plays once")
    check(!gate.activated(103, at: 6.2, recentLaunch: true), "second activation suppressed")
    check(gate.activated(104, at: 7, recentLaunch: true), "activation may precede launch notification")
    check(!gate.launched(104, at: 7.1, foreground: true), "late launch event is deduplicated")
    check(!gate.activated(105, at: 8, recentLaunch: false), "unknown old process is not a cold launch")
    check(!gate.launched(106, at: 9, foreground: true, suppress: true), "login restore is suppressed")
    check(!gate.activated(106, at: 10, recentLaunch: true), "suppressed login restore remains a warm process")
    gate.terminated(101)
    check(gate.launched(101, at: 20, foreground: true), "after actual termination the next launch plays")
    print(failures == 0 ? "COLD_LAUNCH_TESTS=PASS" : "COLD_LAUNCH_TESTS=FAIL count=\(failures)")
    return failures == 0
}
