import AppKit

final class MenuBuilder {
    private weak var target: AppDelegate?

    init(target: AppDelegate) {
        self.target = target
    }

    func build(from state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let snapshot = state.snapshot {
            for bucket in snapshot.buckets {
                let item = NSMenuItem()
                item.view = UsageRowView(bucket: bucket)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        addStatusLine(to: menu, state: state)

        if state.phase == .notSignedIn {
            addSetupInstructions(to: menu)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(AppDelegate.refreshNow),
                                 keyEquivalent: "r")
        refresh.target = target
        menu.addItem(refresh)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(AppDelegate.toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.target = target
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeUsage", action: #selector(AppDelegate.quit),
                              keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        return menu
    }

    private func addStatusLine(to menu: NSMenu, state: AppState) {
        let text: String
        switch state.phase {
        case .ok:
            if let fetchedAt = state.snapshot?.fetchedAt {
                let age = Date().timeIntervalSince(fetchedAt)
                if age < 90 {
                    text = "Updated just now"
                } else {
                    text = "Data from \(UsageDecoder.countdown(to: Date(), now: fetchedAt)) ago — retrying"
                }
            } else {
                text = "Waiting for first update…"
            }
        case .notSignedIn:
            text = "Not signed in — setup below"
        case .authError:
            text = "Sign-in expired — open Claude or run login again"
        case .rateLimited(let retryAt):
            text = "Rate limited — retrying in \(UsageDecoder.countdown(to: retryAt))"
        case .networkError(let message):
            text = "Offline or error (\(message)) — retrying"
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addSetupInstructions(to menu: NSMenu) {
        let lines = [
            "To connect, sign in to Claude Code once:",
            "1. Run the command below in Terminal",
            "2. Type /login and finish in the browser",
        ]
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let copy = NSMenuItem(title: "Copy Setup Command",
                              action: #selector(AppDelegate.copySetupCommand), keyEquivalent: "")
        copy.target = target
        copy.isEnabled = AppDelegate.setupCommand() != nil
        menu.addItem(copy)
    }
}
