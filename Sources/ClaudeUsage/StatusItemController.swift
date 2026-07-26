import AppKit

enum UsageColor {
    // The user reads green fine; red is the hard one for them. So we keep the
    // familiar green (good) → amber (caution) → red (critical) ramp, and make it
    // colorblind-safe through REDUNDANCY, not hue choice: the number is always
    // shown, and every state carries a distinct SHAPE (see iconName). Critical
    // uses a warning triangle so it never depends on perceiving red.
    static func forRemaining(_ percent: Int) -> NSColor {
        if percent >= 40 { return .systemGreen }
        if percent >= 15 { return .systemOrange }
        return .systemRed
    }

    // Shape-based redundancy: distinguishable without relying on hue.
    static func iconName(forRemaining percent: Int) -> String {
        if percent >= 40 { return "checkmark.circle.fill" }
        if percent >= 15 { return "exclamationmark.circle.fill" }
        return "exclamationmark.triangle.fill"
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
        render(titleSegments: [(" …", .secondaryLabelColor)], dimmed: true,
               accessibilityLabel: "Claude usage: loading")
    }

    func update(with state: AppState) {
        let snapshot = state.snapshot

        switch state.phase {
        case .notSignedIn where snapshot == nil:
            render(titleSegments: [(" –", .secondaryLabelColor)], dimmed: true,
                   accessibilityLabel: "Claude usage: not signed in")
            return
        case .authError where snapshot == nil:
            render(titleSegments: [(" –", .secondaryLabelColor)], dimmed: true,
                   accessibilityLabel: "Claude usage: sign-in expired")
            return
        default:
            break
        }

        guard let snapshot else {
            render(titleSegments: [(" –", .secondaryLabelColor)], dimmed: true,
                   accessibilityLabel: "Claude usage: no data yet")
            return
        }

        // Show BOTH frequent blockers — session (5-hour) and weekly — each number
        // colored by its own severity. Falls back to most-constrained if a bucket
        // is missing. Stale/error dims everything (shape/number still readable).
        let dimmed = state.isStale || state.phase != .ok
        let ordered = [snapshot.session, snapshot.weekly].compactMap { $0 }
        let shown = ordered.isEmpty ? [snapshot.mostConstrained].compactMap { $0 } : ordered

        // Each limit shows "<% left> <reset>", e.g. "77% 4h". The reset unit
        // (hours vs days) tells session from weekly, so no S/W tag is needed.
        // Reading "plenty left + reset near" tells you it's safe to burn more.
        var segments: [(String, NSColor)] = []
        var a11yParts: [String] = []
        for (index, bucket) in shown.enumerated() {
            segments.append((index == 0 ? " " : "  ·  ", .labelColor))
            let color = dimmed ? .secondaryLabelColor : UsageColor.forRemaining(bucket.remainingPercent)
            segments.append(("\(bucket.remainingPercent)%", color))
            if let resetsAt = bucket.resetsAt {
                segments.append((" " + UsageDecoder.countdownShort(to: resetsAt), .labelColor))
            }

            var part = "\(bucket.label): \(bucket.remainingPercent) percent remaining"
            if let resetsAt = bucket.resetsAt { part += ", resets in \(UsageDecoder.countdown(to: resetsAt))" }
            a11yParts.append(part)
        }

        var a11y = "Claude usage. " + a11yParts.joined(separator: ". ")
        if dimmed {
            a11y += ". Data is stale, from \(UsageDecoder.countdown(to: Date(), now: snapshot.fetchedAt)) ago"
        }
        render(titleSegments: segments, dimmed: dimmed, accessibilityLabel: a11y)
    }

    private func render(titleSegments: [(String, NSColor)], dimmed: Bool, accessibilityLabel: String) {
        guard let button = statusItem.button else { return }
        button.image = Self.crabImage
        // The crab is always white — only the percentages carry color. Dim state
        // is signaled by the text color, not the icon.
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
