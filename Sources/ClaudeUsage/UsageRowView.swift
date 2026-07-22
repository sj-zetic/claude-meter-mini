import AppKit

// One menu row per usage bucket: label + "N% left", a progress bar, and a
// reset countdown. Static views, no animation (Reduce Motion trivially holds).
final class UsageRowView: NSView {
    private let barTrack = NSView()
    private let barFill = NSView()
    private let fraction: CGFloat

    init(bucket: Bucket) {
        fraction = CGFloat(min(max(bucket.utilization / 100, 0), 1))
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))

        let remaining = bucket.remainingPercent
        let nameLabel = Self.label(bucket.label, size: 13, weight: .medium, color: .labelColor)
        let percentLabel = Self.label("\(remaining)% left", size: 13, weight: .semibold,
                                      color: UsageColor.forRemaining(remaining))

        // Shape cue next to the percentage so severity reads without color.
        let severityIcon = NSImageView()
        severityIcon.image = NSImage(
            systemSymbolName: UsageColor.iconName(forRemaining: remaining),
            accessibilityDescription: nil)
        severityIcon.contentTintColor = UsageColor.forRemaining(remaining)
        severityIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        severityIcon.setAccessibilityElement(false)

        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 3
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3

        var resetText = ""
        if let resetsAt = bucket.resetsAt {
            let countdown = UsageDecoder.countdown(to: resetsAt)
            resetText = countdown == "soon" ? "resets soon" : "resets in \(countdown)"
        }
        let resetLabel = Self.label(resetText, size: 11, weight: .regular, color: .secondaryLabelColor)

        for view in [nameLabel, percentLabel, severityIcon, barTrack, resetLabel] { addSubview(view) }
        barTrack.addSubview(barFill)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        severityIcon.translatesAutoresizingMaskIntoConstraints = false
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            severityIcon.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -5),
            severityIcon.centerYAnchor.constraint(equalTo: percentLabel.centerYAnchor),
            barTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            barTrack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            barTrack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            barTrack.heightAnchor.constraint(equalToConstant: 6),
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            resetLabel.topAnchor.constraint(equalTo: barTrack.bottomAnchor, constant: 3),
        ])
        widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        heightAnchor.constraint(equalToConstant: 52).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        var a11y = "\(bucket.label): \(remaining) percent remaining"
        if let resetsAt = bucket.resetsAt {
            a11y += ", resets in \(UsageDecoder.countdown(to: resetsAt))"
        }
        setAccessibilityLabel(a11y)

        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let width = barTrack.bounds.width * fraction
        barFill.frame = NSRect(x: 0, y: 0, width: width, height: barTrack.bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // Resolve dynamic colors under the current appearance so CGColor
        // follows dark/light mode correctly.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            barTrack.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            let remaining = max(0, 100 - Int((fraction * 100).rounded(.up)))
            barFill.layer?.backgroundColor = UsageColor.forRemaining(remaining).cgColor
        }
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                              color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setAccessibilityElement(false)
        return field
    }
}
