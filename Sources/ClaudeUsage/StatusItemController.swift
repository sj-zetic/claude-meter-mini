import AppKit

enum UsageColor {
    // Two-level and colorblind-simple: GREEN when a limit is healthy (plenty
    // left), otherwise the neutral label color — white on the dark menu bar.
    // No red/amber (hard for the user to read) and NEVER gray, even when stale.
    // "Good" = at least this much of the limit remaining.
    static let goodThreshold = 40

    static func forRemaining(_ percent: Int) -> NSColor {
        percent >= goodThreshold ? .systemGreen : .labelColor
    }

    // Two matching shapes for redundancy in the dropdown rows.
    static func iconName(forRemaining percent: Int) -> String {
        percent >= goodThreshold ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

final class StatusItemController {
    let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = []
        if let button = statusItem.button {
            button.image = Self.crabImage
            button.imagePosition = .imageLeading
        }
        render(titleSegments: [(" …", .labelColor)],
               accessibilityLabel: "Claude usage: loading")
    }

    func update(with state: AppState) {
        let snapshot = state.snapshot

        switch state.phase {
        case .notSignedIn where snapshot == nil:
            render(titleSegments: [(" –", .labelColor)],
                   accessibilityLabel: "Claude usage: not signed in")
            return
        case .authError where snapshot == nil:
            render(titleSegments: [(" –", .labelColor)],
                   accessibilityLabel: "Claude usage: sign-in expired")
            return
        default:
            break
        }

        guard let snapshot else {
            render(titleSegments: [(" –", .labelColor)],
                   accessibilityLabel: "Claude usage: no data yet")
            return
        }

        // Show BOTH frequent blockers — session (5-hour) and weekly. Each number
        // is GREEN when healthy, otherwise WHITE — never gray, even when stale.
        // The reset unit (hours vs days) tells session from weekly.
        let stale = state.isStale || state.phase != .ok
        let ordered = [snapshot.session, snapshot.weekly].compactMap { $0 }
        let shown = ordered.isEmpty ? [snapshot.mostConstrained].compactMap { $0 } : ordered

        var segments: [(String, NSColor)] = []
        var a11yParts: [String] = []
        for (index, bucket) in shown.enumerated() {
            segments.append((index == 0 ? " " : "  ·  ", .labelColor))
            segments.append(("\(bucket.remainingPercent)%", UsageColor.forRemaining(bucket.remainingPercent)))
            if let resetsAt = bucket.resetsAt {
                segments.append((" " + UsageDecoder.countdownShort(to: resetsAt), .labelColor))
            }

            var part = "\(bucket.label): \(bucket.remainingPercent) percent remaining"
            if let resetsAt = bucket.resetsAt { part += ", resets in \(UsageDecoder.countdown(to: resetsAt))" }
            a11yParts.append(part)
        }

        var a11y = "Claude usage. " + a11yParts.joined(separator: ". ")
        if stale {
            a11y += ". Data is stale, from \(UsageDecoder.countdown(to: Date(), now: snapshot.fetchedAt)) ago"
        }
        render(titleSegments: segments, accessibilityLabel: a11y)
    }

    private func render(titleSegments: [(String, NSColor)], accessibilityLabel: String) {
        guard let button = statusItem.button else { return }
        button.image = Self.crabImage
        // The crab is always white; percentages are green (good) or white.
        button.contentTintColor = nil

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        for (text, color) in titleSegments {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        button.attributedTitle = title
        button.setAccessibilityLabel(accessibilityLabel)
    }

    // The user's pixel-art crab, drawn in solid white and NON-template, so it
    // stays white in every state and every appearance — the percentages are the
    // only colored element. Grid is # = filled, space = hole (eyes are cut-outs).
    static let crabImage: NSImage = {
        let rows = [
            "  ########  ",
            "  # #### #  ",
            "  # #### #  ",
            "  ########  ",
            "############",
            "# ######## #",
            "  ########  ",
            "  ##    ##  ",
            "  ##    ##  ",
        ]
        let cols = 12
        let cell: CGFloat = 4
        let size = NSSize(width: CGFloat(cols) * cell, height: CGFloat(rows.count) * cell)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" {
                NSRect(x: CGFloat(c) * cell,
                       y: size.height - CGFloat(r + 1) * cell,
                       width: cell, height: cell).fill()
            }
        }
        image.unlockFocus()
        // Scale to menu-bar height while keeping the pixel proportions.
        let displayHeight: CGFloat = 15
        image.size = NSSize(width: displayHeight * size.width / size.height, height: displayHeight)
        image.isTemplate = false   // keep the drawn white; don't let the system recolor it
        return image
    }()
}
