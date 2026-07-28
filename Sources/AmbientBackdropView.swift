import Cocoa

final class AmbientBackdropView: NSView {
    private let baseGradient = CAGradientLayer()
    private let leadingGlow = CAGradientLayer()
    private let trailingGlow = CAGradientLayer()
    private let sheen = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        baseGradient.startPoint = CGPoint(x: 0, y: 1)
        baseGradient.endPoint = CGPoint(x: 1, y: 0)
        leadingGlow.type = .radial
        trailingGlow.type = .radial
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)

        [baseGradient, leadingGlow, trailingGlow, sheen].forEach {
            layer?.addSublayer($0)
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        baseGradient.frame = bounds
        sheen.frame = bounds
        leadingGlow.frame = CGRect(
            x: -bounds.width * 0.22,
            y: bounds.height * 0.12,
            width: bounds.width * 0.82,
            height: bounds.height * 1.08
        )
        trailingGlow.frame = CGRect(
            x: bounds.width * 0.48,
            y: -bounds.height * 0.24,
            width: bounds.width * 0.76,
            height: bounds.height * 1.05
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMotion()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        baseGradient.colors = dark
            ? [
                NSColor(calibratedWhite: 0.045, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).cgColor,
              ]
            : [
                NSColor(calibratedRed: 0.91, green: 0.96, blue: 1, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.99, green: 0.94, blue: 1, alpha: 1).cgColor,
              ]
        leadingGlow.colors = [
            NSColor.systemCyan.withAlphaComponent(dark ? 0.34 : 0.32).cgColor,
            NSColor.systemBlue.withAlphaComponent(0).cgColor,
        ]
        trailingGlow.colors = [
            NSColor.systemPink.withAlphaComponent(dark ? 0.28 : 0.23).cgColor,
            NSColor.systemPurple.withAlphaComponent(0).cgColor,
        ]
        sheen.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.045 : 0.26).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.locations = [0, 0.48, 1]
    }

    private func updateMotion() {
        [leadingGlow, trailingGlow, sheen].forEach {
            $0.removeAnimation(forKey: "voice-relay-ambient-motion")
        }
        guard window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }
        let leading = CABasicAnimation(keyPath: "transform.translation.x")
        leading.fromValue = -18
        leading.toValue = 26
        leading.duration = 7.5
        leading.autoreverses = true
        leading.repeatCount = .infinity
        leading.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leadingGlow.add(leading, forKey: "voice-relay-ambient-motion")

        let trailing = CABasicAnimation(keyPath: "transform.translation.y")
        trailing.fromValue = -16
        trailing.toValue = 24
        trailing.duration = 8.4
        trailing.autoreverses = true
        trailing.repeatCount = .infinity
        trailing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trailingGlow.add(trailing, forKey: "voice-relay-ambient-motion")

        let shimmer = CABasicAnimation(keyPath: "opacity")
        shimmer.fromValue = 0.72
        shimmer.toValue = 1.0
        shimmer.duration = 4.8
        shimmer.autoreverses = true
        shimmer.repeatCount = .infinity
        sheen.add(shimmer, forKey: "voice-relay-ambient-motion")
    }
}
