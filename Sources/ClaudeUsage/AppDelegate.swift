import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusController: StatusItemController!
    private var fetcher: UsageFetcher!
    private var menuBuilder: MenuBuilder!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusController = StatusItemController()
        fetcher = UsageFetcher()
        menuBuilder = MenuBuilder(target: self)

        fetcher.onUpdate = { [weak self] state in
            guard let self else { return }
            self.applyForcedStateIfAny(to: state)
        }

        if let forced = Self.forcedState() {
            render(forced)
        } else {
            fetcher.start()
        }

        // Local per-minute tick: re-render the status item so the reset
        // countdown ticks down between the 90s network polls. No fetch, 0 tokens.
        // Only the title is refreshed (not the menu), so an open menu is undisturbed.
        let tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, Self.forcedState() == nil else { return }
            self.statusController.update(with: self.fetcher.state)
        }
        tick.tolerance = 10
        tickTimer = tick

        if ProcessInfo.processInfo.environment["CLAUDEUSAGE_OPEN_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.statusController.statusItem.button?.performClick(nil)
            }
        }
    }

    private func applyForcedStateIfAny(to state: AppState) {
        render(Self.forcedState() ?? state)
    }

    private func render(_ state: AppState) {
        statusController.update(with: state)
        let menu = menuBuilder.build(from: state)
        menu.delegate = self
        statusController.statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard Self.forcedState() == nil else { return }
        fetcher.refreshIfDue()
    }

    @objc func refreshNow() {
        fetcher.refreshNow()
    }

    @objc func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
        render(fetcher.state)
    }

    @objc func copySetupCommand() {
        guard let command = Self.setupCommand() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    static func setupCommand() -> String? {
        // The desktop-bundled `claude` is a VM-format binary that isn't directly
        // runnable from a shell, so we point users at the standalone CLI, which
        // writes the standard "Claude Code-credentials" keychain item on /login.
        // npx avoids a global install (which fails with EACCES when npm's prefix
        // is /usr/local).
        "npx -y @anthropic-ai/claude-code"
    }

    // CLAUDEUSAGE_FORCE_STATE=notsignedin|stale|error|rate renders every UI
    // state without touching real credentials or the network.
    static func forcedState() -> AppState? {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDEUSAGE_FORCE_STATE"] else {
            return nil
        }
        let sampleBuckets = [
            Bucket(id: "five_hour", label: "5-hour limit", utilization: 63,
                   resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            Bucket(id: "seven_day", label: "Weekly limit", utilization: 88,
                   resetsAt: Date().addingTimeInterval(3 * 86400)),
        ]
        var state = AppState()
        switch raw {
        case "notsignedin":
            state.phase = .notSignedIn
        case "stale":
            state.snapshot = Snapshot(buckets: sampleBuckets,
                                      fetchedAt: Date().addingTimeInterval(-720))
            state.phase = .networkError("timed out")
        case "error":
            state.snapshot = Snapshot(buckets: sampleBuckets,
                                      fetchedAt: Date().addingTimeInterval(-60))
            state.phase = .authError
        case "rate":
            state.snapshot = Snapshot(buckets: sampleBuckets, fetchedAt: Date())
            state.phase = .rateLimited(retryAt: Date().addingTimeInterval(240))
        case "ok":
            state.snapshot = Snapshot(buckets: sampleBuckets, fetchedAt: Date())
            state.phase = .ok
        default:
            return nil
        }
        return state
    }
}
