import Cocoa

private final class VoiceOrbMaterialView: NSView {
    private let fallbackEffect = NSVisualEffectView()
    private var nativeGlassView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        fallbackEffect.translatesAutoresizingMaskIntoConstraints = false
        fallbackEffect.blendingMode = .behindWindow
        fallbackEffect.material = .popover
        fallbackEffect.state = .active
        fallbackEffect.alphaValue =
            VoiceOrbVisualPolicy.fallbackMaterialOpacity
        addSubview(fallbackEffect)

        NSLayoutConstraint.activate([
            fallbackEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackEffect.topAnchor.constraint(equalTo: topAnchor),
            fallbackEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.style = .clear
            glass.tintColor = .clear
            glass.alphaValue = VoiceOrbVisualPolicy.nativeGlassOpacity
            addSubview(glass, positioned: .above, relativeTo: fallbackEffect)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            nativeGlassView = glass
        }
        updateMaterialVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let radius = min(bounds.width, bounds.height) / 2
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fallbackEffect.layer?.cornerRadius = radius
        nativeGlassView?.layer?.cornerRadius = radius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fallbackEffect.material =
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .hudWindow
                : .popover
        updateMaterialVisibility()
    }

    private func updateMaterialVisibility() {
        let reduceTransparency =
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        fallbackEffect.isHidden = nativeGlassView != nil || reduceTransparency
        nativeGlassView?.isHidden = reduceTransparency
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class VoiceOrbArtworkView: NSView {
    private let flowLayer = CALayer()
    private let flowConicLayer = CAGradientLayer()
    private let flowPoolLayers = [
        CAGradientLayer(),
        CAGradientLayer(),
        CAGradientLayer(),
    ]
    private var phase: VoiceSurfacePhase = .dormantWake
    private var isDark = true
    private var audioLevel: CGFloat = 0
    private var flowIsVisible = false
    private var flowAnimationsRunning = false

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        configureFlowLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = max(1.6, bounds.width * 0.038)
        flowLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        flowLayer.cornerRadius = min(
            flowLayer.bounds.width,
            flowLayer.bounds.height
        ) / 2
        flowConicLayer.frame = flowLayer.bounds.insetBy(dx: -7, dy: -7)
        let poolSize = max(flowLayer.bounds.width * 0.78, 1)
        for pool in flowPoolLayers {
            pool.bounds = CGRect(
                x: 0,
                y: 0,
                width: poolSize,
                height: poolSize
            )
            pool.cornerRadius = poolSize / 2
        }
        setStaticFlowPositions()
        CATransaction.commit()
        if flowIsVisible, !flowAnimationsRunning,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startFlowAnimations()
        }
    }

    func update(
        phase: VoiceSurfacePhase,
        isDark: Bool,
        audioLevel: CGFloat
    ) {
        self.phase = phase
        self.isDark = isDark
        self.audioLevel = min(max(audioLevel, 0), 1)
        updateFlowIntensity()
        needsDisplay = true
    }

    func setFlowVisible(_ visible: Bool, reduceMotion: Bool) {
        flowIsVisible = visible
        updateFlowIntensity()
        if visible, !reduceMotion {
            startFlowAnimations()
        } else {
            stopFlowAnimations()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset = max(1.6, bounds.width * 0.038)
        let sphere = bounds.insetBy(dx: inset, dy: inset)
        let circle = CGPath(ellipseIn: sphere, transform: nil)
        let energy = phaseEnergy

        context.saveGState()
        context.addPath(circle)
        context.clip()

        let base = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(
                    calibratedRed: 0.04,
                    green: 0.14,
                    blue: 0.42,
                    alpha: isDark ? 0.94 : 0.78
                ).cgColor,
                NSColor(
                    calibratedRed: 0.25,
                    green: 0.03,
                    blue: 0.48,
                    alpha: isDark ? 0.86 : 0.70
                ).cgColor,
                NSColor(
                    calibratedRed: 0.00,
                    green: 0.34,
                    blue: 0.48,
                    alpha: isDark ? 0.92 : 0.74
                ).cgColor,
            ] as CFArray,
            locations: [0, 0.48, 1]
        )!
        context.drawLinearGradient(
            base,
            start: CGPoint(x: sphere.minX, y: sphere.maxY),
            end: CGPoint(x: sphere.maxX, y: sphere.minY),
            options: []
        )

        drawSpectralAurora(context, sphere: sphere, energy: energy)

        let lightCenter = point(
            in: sphere,
            normalized: VoiceOrbVisualPolicy.lightPoint
        )
        context.setBlendMode(.screen)
        drawRadial(
            context,
            colors: [
                NSColor.white.withAlphaComponent(
                    0.82 + audioLevel * 0.16
                ),
                NSColor(
                    calibratedRed: 0.66,
                    green: 0.92,
                    blue: 1,
                    alpha: 0.38 + audioLevel * 0.24
                ),
                NSColor.white.withAlphaComponent(0.06),
                .clear,
            ],
            locations: [0, 0.16, 0.52, 1],
            center: lightCenter,
            endRadius: sphere.width * 0.58
        )

        context.setBlendMode(.overlay)
        context.setFillColor(
            NSColor.white.withAlphaComponent(0.28 + audioLevel * 0.16).cgColor
        )
        context.fillEllipse(
            in: CGRect(
                x: lightCenter.x - sphere.width * 0.17,
                y: lightCenter.y - sphere.height * 0.055,
                width: sphere.width * 0.34,
                height: sphere.height * 0.11
            )
        )

        context.setBlendMode(.multiply)
        drawRadial(
            context,
            colors: [
                .clear,
                NSColor.black.withAlphaComponent(isDark ? 0.08 : 0.04),
                NSColor.black.withAlphaComponent(
                    VoiceOrbVisualPolicy.edgeVignetteAlpha
                ),
            ],
            locations: [0, 0.64, 1],
            center: CGPoint(
                x: sphere.midX + (sphere.midX - lightCenter.x) * 0.28,
                y: sphere.midY + (sphere.midY - lightCenter.y) * 0.28
            ),
            endRadius: sphere.width * 0.72
        )
        context.restoreGState()

        drawRim(
            context,
            circle: circle,
            sphere: sphere,
            lightCenter: lightCenter,
            energy: energy
        )
    }

    private var phaseEnergy: CGFloat {
        switch phase {
        case .dormantWake: return 0.78
        case .starting, .stopping: return 0.88
        case .listening: return 0.96
        case .thinking: return 1
        case .speaking: return 1.06
        case .failed: return 0.92
        }
    }

    private func drawSpectralAurora(
        _ context: CGContext,
        sphere: CGRect,
        energy: CGFloat
    ) {
        context.saveGState()
        context.setBlendMode(.screen)
        for accent in VoiceOrbVisualPolicy.spectralAccents {
            let color = NSColor(
                calibratedHue: accent.hue,
                saturation: VoiceOrbVisualPolicy.spectralSaturation,
                brightness: 1,
                alpha: 1
            )
            drawRadial(
                context,
                colors: [
                    color.withAlphaComponent(
                        min(
                            VoiceOrbVisualPolicy.spectralCenterAlpha,
                            0.52 * energy + audioLevel * 0.40
                        )
                    ),
                    color.withAlphaComponent(
                        VoiceOrbVisualPolicy.spectralSecondaryAlpha * energy
                    ),
                    .clear,
                ],
                locations: [0, 0.50, 1],
                center: point(in: sphere, normalized: accent.center),
                endRadius: sphere.width * accent.radius
            )
        }
        context.restoreGState()
    }

    private func configureFlowLayers() {
        flowLayer.masksToBounds = true
        flowLayer.opacity = 0
        layer?.addSublayer(flowLayer)

        flowConicLayer.type = .conic
        flowConicLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        flowConicLayer.endPoint = CGPoint(x: 0.5, y: 0)
        flowConicLayer.colors = [
            NSColor.systemCyan.withAlphaComponent(0.05).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.20).cgColor,
            NSColor.systemPurple.withAlphaComponent(0.24).cgColor,
            NSColor.systemPink.withAlphaComponent(0.22).cgColor,
            NSColor.systemOrange.withAlphaComponent(0.12).cgColor,
            NSColor.systemGreen.withAlphaComponent(0.14).cgColor,
            NSColor.systemCyan.withAlphaComponent(0.05).cgColor,
        ]
        flowConicLayer.locations = [0, 0.15, 0.33, 0.51, 0.68, 0.84, 1]
        flowLayer.addSublayer(flowConicLayer)

        let poolColors: [NSColor] = [
            NSColor(calibratedRed: 0.06, green: 0.88, blue: 1, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.08, blue: 0.72, alpha: 1),
            NSColor(calibratedRed: 0.62, green: 0.18, blue: 1, alpha: 1),
        ]
        for (pool, color) in zip(flowPoolLayers, poolColors) {
            pool.type = .radial
            pool.startPoint = CGPoint(x: 0.5, y: 0.5)
            pool.endPoint = CGPoint(x: 1, y: 1)
            pool.colors = [
                color.withAlphaComponent(0.48).cgColor,
                color.withAlphaComponent(0.18).cgColor,
                color.withAlphaComponent(0).cgColor,
            ]
            pool.locations = [0, 0.42, 1]
            flowLayer.addSublayer(pool)
        }
    }

    private func updateFlowIntensity() {
        let base = phase.isSessionActive
            ? VoiceOrbVisualPolicy.activeFlowOpacity
            : VoiceOrbVisualPolicy.idleFlowOpacity
        let reactiveLevel = sqrt(min(max(audioLevel, 0), 1))
        let opacity = min(
            VoiceOrbVisualPolicy.maximumFlowOpacity,
            base + reactiveLevel * 0.38
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flowLayer.opacity = flowIsVisible ? Float(opacity) : 0
        flowConicLayer.opacity = Float(0.70 + reactiveLevel * 0.30)
        for (index, pool) in flowPoolLayers.enumerated() {
            pool.opacity = Float(
                min(1, 0.62 + reactiveLevel * (0.30 + CGFloat(index) * 0.04))
            )
        }
        CATransaction.commit()
    }

    private func setStaticFlowPositions() {
        let bounds = flowLayer.bounds
        guard !bounds.isEmpty else { return }
        let normalizedPositions = [
            CGPoint(x: 0.25, y: 0.68),
            CGPoint(x: 0.72, y: 0.64),
            CGPoint(x: 0.52, y: 0.25),
        ]
        for (pool, position) in zip(flowPoolLayers, normalizedPositions) {
            pool.position = CGPoint(
                x: bounds.minX + bounds.width * position.x,
                y: bounds.minY + bounds.height * position.y
            )
        }
    }

    private func startFlowAnimations() {
        guard flowIsVisible,
              !flowAnimationsRunning,
              !flowLayer.bounds.isEmpty else {
            return
        }
        flowAnimationsRunning = true

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = VoiceOrbVisualPolicy.flowRotationDuration
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        flowConicLayer.add(rotation, forKey: "voice-orb-flow-rotation")

        let bounds = flowLayer.bounds
        let routes: [[CGPoint]] = [
            [
                CGPoint(x: 0.22, y: 0.70),
                CGPoint(x: 0.48, y: 0.82),
                CGPoint(x: 0.72, y: 0.58),
                CGPoint(x: 0.45, y: 0.38),
                CGPoint(x: 0.22, y: 0.70),
            ],
            [
                CGPoint(x: 0.76, y: 0.66),
                CGPoint(x: 0.62, y: 0.34),
                CGPoint(x: 0.30, y: 0.30),
                CGPoint(x: 0.38, y: 0.68),
                CGPoint(x: 0.76, y: 0.66),
            ],
            [
                CGPoint(x: 0.52, y: 0.22),
                CGPoint(x: 0.76, y: 0.42),
                CGPoint(x: 0.54, y: 0.76),
                CGPoint(x: 0.24, y: 0.48),
                CGPoint(x: 0.52, y: 0.22),
            ],
        ]
        for (index, pool) in flowPoolLayers.enumerated() {
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = routes[index].map { point in
                NSValue(
                    point: NSPoint(
                        x: bounds.minX + bounds.width * point.x,
                        y: bounds.minY + bounds.height * point.y
                    )
                )
            }
            position.duration = VoiceOrbVisualPolicy.flowDriftDurations[index]
            position.repeatCount = .infinity
            position.calculationMode = .paced
            position.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: routes[index].count - 1
            )
            position.isRemovedOnCompletion = false
            pool.add(position, forKey: "voice-orb-flow-position")

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.82 + CGFloat(index) * 0.04
            scale.toValue = 1.12 + CGFloat(index) * 0.03
            scale.duration =
                VoiceOrbVisualPolicy.flowDriftDurations[index] * 0.57
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.timingFunction =
                CAMediaTimingFunction(name: .easeInEaseOut)
            scale.isRemovedOnCompletion = false
            pool.add(scale, forKey: "voice-orb-flow-scale")
        }
    }

    private func stopFlowAnimations() {
        guard flowAnimationsRunning else { return }
        flowAnimationsRunning = false
        flowConicLayer.removeAllAnimations()
        flowPoolLayers.forEach { $0.removeAllAnimations() }
        setStaticFlowPositions()
    }

    private func drawRim(
        _ context: CGContext,
        circle: CGPath,
        sphere: CGRect,
        lightCenter: CGPoint,
        energy: CGFloat
    ) {
        context.saveGState()
        context.addPath(circle)
        let rimColor: NSColor = phase == .failed
            ? .systemOrange
            : NSColor(
                calibratedHue: 0.54,
                saturation: 0.38,
                brightness: 1,
                alpha: 1
            )
        context.setStrokeColor(
            rimColor.withAlphaComponent(0.72 * energy).cgColor
        )
        context.setLineWidth(1.05)
        context.strokePath()

        context.addEllipse(in: sphere.insetBy(dx: 1.2, dy: 1.2))
        context.setStrokeColor(
            NSColor.white.withAlphaComponent(
                0.34 + audioLevel * 0.16
            ).cgColor
        )
        context.setLineWidth(0.66)
        context.strokePath()

        context.setFillColor(
            NSColor.white.withAlphaComponent(
                0.44 + audioLevel * 0.18
            ).cgColor
        )
        context.fillEllipse(
            in: CGRect(
                x: lightCenter.x - sphere.width * 0.11,
                y: lightCenter.y - sphere.height * 0.045,
                width: sphere.width * 0.22,
                height: sphere.height * 0.09
            )
        )
        context.restoreGState()
    }

    private func drawRadial(
        _ context: CGContext,
        colors: [NSColor],
        locations: [CGFloat],
        center: CGPoint,
        endRadius: CGFloat
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations
        ) else {
            return
        }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: endRadius,
            options: [.drawsAfterEndLocation]
        )
    }

    private func point(in rect: CGRect, normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * min(max(normalized.x, 0.08), 0.92),
            y: rect.minY + rect.height * min(max(normalized.y, 0.08), 0.92)
        )
    }
}

final class VoiceOrbView: NSView {
    private let contentView = NSView()
    private let materialView = VoiceOrbMaterialView()
    private let artworkView = VoiceOrbArtworkView()
    private var phase: VoiceSurfacePhase = .dormantWake
    private var productName = "Voice Relay"
    private var isDark = true
    private var audioLevel: CGFloat = 0
    private var surfaceVisible = false
    private var mouseDownScreenPoint: NSPoint?
    private var isDragging = false

    var onActivate: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        materialView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.masksToBounds = false
        contentView.addSubview(materialView)
        contentView.addSubview(artworkView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: contentView.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: contentView.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateArtwork()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFlowMotion()
    }

    override func layout() {
        super.layout()
        contentView.layer?.shadowPath = CGPath(
            ellipseIn: contentView.bounds.insetBy(dx: 2, dy: 2),
            transform: nil
        )
    }

    func setSurfaceVisible(_ visible: Bool) {
        surfaceVisible = visible
        if !visible {
            audioLevel = 0
            artworkView.layer?.setAffineTransform(.identity)
        }
        updateArtwork()
        refreshFlowMotion()
    }

    func update(
        phase: VoiceSurfacePhase,
        animate _: Bool,
        productName: String,
        isDark: Bool
    ) {
        self.phase = phase
        self.productName = productName
        self.isDark = isDark
        setAccessibilityLabel(accessibilityLabel(for: phase))
        if phase != .listening {
            audioLevel = 0
            artworkView.layer?.setAffineTransform(.identity)
        }
        updateArtwork()
        refreshFlowMotion()
        updateShadow()
    }

    func updateAudioLevel(_ level: CGFloat) {
        let target = phase == .listening ? min(max(level, 0), 1) : 0
        audioLevel = OrbAudioLevelPolicy.smoothed(
            current: audioLevel,
            target: target
        )
        applyArtworkScale()
        updateArtwork()
        updateShadow()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = screenPoint(for: event)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownScreenPoint,
              let current = screenPoint(for: event) else {
            return
        }
        let delta = NSPoint(
            x: current.x - start.x,
            y: current.y - start.y
        )
        if !isDragging, hypot(delta.x, delta.y) >= 4 {
            isDragging = true
            onDragBegan?()
        }
        if isDragging {
            onDragChanged?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finalDelta: NSPoint? = {
            guard let start = mouseDownScreenPoint,
                  let current = screenPoint(for: event) else {
                return nil
            }
            return NSPoint(
                x: current.x - start.x,
                y: current.y - start.y
            )
        }()
        let endedAsDrag = isDragging || finalDelta.map {
            hypot($0.x, $0.y) >= 4
        } == true
        defer {
            mouseDownScreenPoint = nil
            isDragging = false
        }
        if endedAsDrag {
            if !isDragging, let finalDelta {
                onDragBegan?()
                onDragChanged?(finalDelta)
            }
            onDragEnded?()
        } else {
            onActivate?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onOpenSettings?()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func updateArtwork() {
        artworkView.update(
            phase: phase,
            isDark: isDark,
            audioLevel: audioLevel
        )
    }

    private func applyArtworkScale() {
        let scale = OrbAudioLevelPolicy.scale(
            for: audioLevel,
            reduceMotion:
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        artworkView.layer?.setAffineTransform(
            CGAffineTransform(scaleX: scale, y: scale)
        )
    }

    private func refreshFlowMotion() {
        artworkView.setFlowVisible(
            surfaceVisible && window != nil,
            reduceMotion:
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    @objc private func accessibilityDisplayOptionsDidChange(
        _ notification: Notification
    ) {
        applyArtworkScale()
        refreshFlowMotion()
        updateArtwork()
    }

    private func updateShadow() {
        let shadowColor: NSColor = phase == .failed
            ? .systemOrange
            : NSColor(
                calibratedHue: 0.56,
                saturation: 0.72,
                brightness: 1,
                alpha: 1
            )
        contentView.layer?.shadowColor = shadowColor.cgColor
        contentView.layer?.shadowOffset = .zero
        contentView.layer?.shadowRadius = 10 + audioLevel * 4
        contentView.layer?.shadowOpacity = Float(
            0.26 + audioLevel * 0.24
        )
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let eventWindow = event.window else { return nil }
        return eventWindow.convertPoint(toScreen: event.locationInWindow)
    }

    private func accessibilityLabel(
        for phase: VoiceSurfacePhase
    ) -> String {
        switch phase {
        case .dormantWake: return "\(productName) ready"
        case .starting: return "Voice connecting"
        case .listening: return "Listening"
        case .thinking: return "Checking"
        case .speaking: return "Speaking"
        case .stopping: return "Voice stopping"
        case .failed: return "Voice connection failed"
        }
    }
}
