import Cocoa
import AVFoundation
import Darwin
import Foundation
import Speech

private struct AppConfig {
    let productName: String
    let assistantName: String
    let userDisplayName: String
    let appearanceMode: AppAppearanceMode
    let autoSpeak: Bool
    let speechLocale: String
    let speechVoiceIdentifier: String?
    let speechRate: Float
    let overlayAnchor: OverlayAnchor
    let animateSurface: Bool
    let hoverStartsVoice: Bool
    let hoverStartDelay: TimeInterval
    let collapseDelay: TimeInterval
    let showRecentHistory: Bool
    let recentTurnLimit: Int
    let wakePhraseEnabled: Bool
    let wakePhrases: [String]
    let additionalSpeechLocales: [String]
    let preferModernSpeechAnalyzer: Bool
    let voiceIdleTimeoutMinutes: Int
    let codexExecutablePath: String
    let codexWorkspacePath: String
    let codexThreadTitle: String
    let codexModel: String
    let codexReasoningEffort: String
    let codexSandbox: String
    let codexApprovalPolicy: String
    let includeAuthorityPack: Bool
    let authorityPackRoot: String
    let authorityPackFingerprint: String
    let realtimeModel: String
    let realtimeVoice: String
    let realtimeReasoningEffort: String
    let realtimeInstructions: String
    let returnGreetingEnabled: Bool
    let returnGreetingMinutes: Int

    static func load() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        let settings = SettingsStore.shared.load()

        return AppConfig(
            productName: settings.productName,
            assistantName: settings.assistantName,
            userDisplayName: SettingsStore.normalizedDisplayName(
                settings.userDisplayName,
                fallback: AppCopy(
                    preference: settings.appDisplayLanguage
                ).text("Me", "나")
            ),
            appearanceMode: AppAppearanceMode.parse(settings.appearanceMode),
            autoSpeak: boolValue(
                env["VOICE_RELAY_SPEAK"],
                fallback: settings.autoSpeak
            ),
            speechLocale: SettingsStore.resolvedSpeechLocaleIdentifier(
                nonEmpty(env["VOICE_RELAY_SPEECH_LOCALE"])
                    ?? settings.speechLocale
            ),
            speechVoiceIdentifier: nonEmpty(env["VOICE_RELAY_SPEECH_VOICE"]),
            speechRate: Float(env["VOICE_RELAY_SPEECH_RATE"] ?? "") ?? 0.48,
            overlayAnchor: OverlayAnchor.parse(
                env["VOICE_RELAY_ANCHOR"] ?? settings.overlayAnchor.rawValue
            ),
            animateSurface: boolValue(
                env["VOICE_RELAY_ANIMATE"],
                fallback: settings.animateSurface
            ),
            hoverStartsVoice: boolValue(
                env["VOICE_RELAY_HOVER_STARTS_VOICE"],
                fallback: settings.hoverStartsVoice
            ),
            hoverStartDelay: SettingsStore.clampedHoverStartDelay(
                Double(env["VOICE_RELAY_HOVER_DELAY"] ?? "") ?? settings.hoverStartDelay
            ),
            collapseDelay: SettingsStore.clampedCollapseDelay(
                Double(env["VOICE_RELAY_COLLAPSE_DELAY"] ?? "") ?? settings.collapseDelay
            ),
            showRecentHistory: settings.showRecentHistory,
            recentTurnLimit: SettingsStore.clampedRecentTurnLimit(settings.recentTurnLimit),
            wakePhraseEnabled: boolValue(
                env["VOICE_RELAY_WAKE_PHRASE"],
                fallback: settings.wakePhraseEnabled
            ),
            wakePhrases: settings.wakePhrases,
            additionalSpeechLocales: settings.additionalSpeechLocales,
            preferModernSpeechAnalyzer: settings.preferModernSpeechAnalyzer,
            voiceIdleTimeoutMinutes: SettingsStore.clampedVoiceIdleTimeoutMinutes(
                settings.voiceIdleTimeoutMinutes
            ),
            codexExecutablePath: SettingsStore.normalizedExecutablePath(
                env["VOICE_RELAY_CODEX_EXECUTABLE"] ?? settings.codexExecutablePath
            ),
            codexWorkspacePath: SettingsStore.normalizedLocalPath(
                env["VOICE_RELAY_CODEX_WORKSPACE"] ?? settings.codexWorkspacePath
            ),
            codexThreadTitle: nonEmpty(env["VOICE_RELAY_CODEX_THREAD_TITLE"])
                ?? settings.codexThreadTitle,
            codexModel: SettingsStore.normalizedCodexModel(
                env["VOICE_RELAY_CODEX_MODEL"] ?? settings.codexModel
            ),
            codexReasoningEffort: SettingsStore.normalizedCodexReasoningEffort(
                env["VOICE_RELAY_CODEX_REASONING"] ?? settings.codexReasoningEffort
            ),
            codexSandbox: SettingsStore.normalizedCodexSandbox(
                env["VOICE_RELAY_CODEX_SANDBOX"] ?? settings.codexSandbox
            ),
            codexApprovalPolicy: SettingsStore.normalizedCodexApprovalPolicy(
                env["VOICE_RELAY_CODEX_APPROVAL"] ?? settings.codexApprovalPolicy
            ),
            includeAuthorityPack: boolValue(
                env["VOICE_RELAY_AUTHORITY_ENABLED"],
                fallback: settings.includeAuthorityPack
            ),
            authorityPackRoot: SettingsStore.normalizedLocalPath(
                env["VOICE_RELAY_AUTHORITY_ROOT"] ?? settings.authorityPackRoot
            ),
            authorityPackFingerprint: settings.authorityPackFingerprint,
            realtimeModel: SettingsStore.normalizedRealtimeModel(
                env["VOICE_RELAY_REALTIME_MODEL"] ?? settings.realtimeModel
            ),
            realtimeVoice: SettingsStore.normalizedRealtimeVoice(
                env["VOICE_RELAY_REALTIME_VOICE"] ?? settings.realtimeVoice
            ),
            realtimeReasoningEffort: SettingsStore.normalizedRealtimeReasoningEffort(
                env["VOICE_RELAY_REALTIME_REASONING"] ?? settings.realtimeReasoningEffort
            ),
            realtimeInstructions: settings.realtimeInstructions,
            returnGreetingEnabled: settings.returnGreetingEnabled,
            returnGreetingMinutes: SettingsStore.clampedReturnGreetingMinutes(
                settings.returnGreetingMinutes
            )
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func boolValue(_ value: String?, fallback: Bool) -> Bool {
        guard let value = nonEmpty(value)?.lowercased() else { return fallback }
        if ["1", "true", "yes", "on"].contains(value) {
            return true
        }
        if ["0", "false", "no", "off"].contains(value) {
            return false
        }
        return fallback
    }
}

private struct OverlayColors {
    let material: NSVisualEffectView.Material
    let fill: NSColor
    let border: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let statusText: NSColor
    let iconFill: NSColor
    let accent: NSColor
}

private final class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var allowsTopEdgeOverlap = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTopEdgeOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onOpenSettings {
            onOpenSettings()
            return
        }
        super.rightMouseDown(with: event)
    }

}

private final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func centeredRect(forBounds rect: NSRect) -> NSRect {
        var next = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        next.origin.y = rect.origin.y + floor((rect.height - textHeight) / 2.0) + 1
        next.size.height = textHeight
        return next
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var reportedHoverState = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        hoverTrackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        guard !reportedHoverState else { return }
        reportedHoverState = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard reportedHoverState else { return }
        reportedHoverState = false
        onHoverChanged?(false)
    }
}

private final class NotchBlackGradientView: NSView {
    private var verticalGradient: CAGradientLayer? {
        layer as? CAGradientLayer
    }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        return gradient
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        visible: Bool,
        locations: [CGFloat] = NotchUnifiedSurfacePolicy.blackGradientLocations,
        alphas: [CGFloat] = NotchUnifiedSurfacePolicy.blackGradientAlphas
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = !visible
        verticalGradient?.locations = locations.map {
            NSNumber(value: Double($0))
        }
        verticalGradient?.colors = alphas.map {
            NSColor.black.withAlphaComponent($0).cgColor
        }
        CATransaction.commit()
    }
}

private final class ShadowIconButton: NSButton {
    private let symbolView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        attributedTitle = NSAttributedString(string: "")
        image = nil
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.wantsLayer = true
        symbolView.layer?.backgroundColor = NSColor.clear.cgColor
        symbolView.layer?.shadowColor = NSColor.black.cgColor
        symbolView.layer?.shadowOpacity =
            NotchActionIconPolicy.shadowOpacity
        symbolView.layer?.shadowRadius =
            NotchActionIconPolicy.shadowRadius
        symbolView.layer?.shadowOffset =
            NotchActionIconPolicy.shadowOffset
        symbolView.layer?.masksToBounds = false
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(
                equalToConstant: NotchActionIconPolicy.symbolSize
            ),
            symbolView.heightAnchor.constraint(
                equalToConstant: NotchActionIconPolicy.symbolSize
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              alphaValue > 0,
              super.hitTest(point) != nil else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setSymbol(
        _ name: String,
        color: NSColor,
        accessibilityDescription: String? = nil
    ) {
        image = nil
        title = ""
        attributedTitle = NSAttributedString(string: "")
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        ) else {
            symbolView.image = nil
            return
        }
        image.isTemplate = true
        symbolView.image = image
        symbolView.contentTintColor = color
        if let accessibilityDescription {
            setAccessibilityLabel(accessibilityDescription)
        }
    }
}

private enum NotchSurfaceMode {
    case solid
    case answer(showsGlass: Bool)
}

private final class OverlaySurfaceView: NSView {
    let effectView = NSVisualEffectView()
    private let materialContainer = NSView()
    private var nativeGlassView: NSView?
    private let notchGradientView = NotchBlackGradientView()
    private let lowerBorderLayer = CAShapeLayer()
    private var glassMaterialVisible = true
    private var glassMaterialEnabled = false
    private var glassMaterialOpacity: CGFloat = 1
    private var clipsOnlyBottomCorners = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        lowerBorderLayer.fillColor = nil
        lowerBorderLayer.strokeColor = NSColor.white
            .withAlphaComponent(0.34)
            .cgColor
        lowerBorderLayer.lineWidth = 1
        lowerBorderLayer.isHidden = true
        lowerBorderLayer.zPosition = 100
        layer?.addSublayer(lowerBorderLayer)
        materialContainer.translatesAutoresizingMaskIntoConstraints = false
        materialContainer.wantsLayer = true
        addSubview(materialContainer)
        NSLayoutConstraint.activate([
            materialContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialContainer.topAnchor.constraint(equalTo: topAnchor),
            materialContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        effectView.translatesAutoresizingMaskIntoConstraints = false
        materialContainer.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: materialContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: materialContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: materialContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: materialContainer.bottomAnchor),
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.style = .clear
            materialContainer.addSubview(
                glass,
                positioned: .above,
                relativeTo: effectView
            )
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: materialContainer.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: materialContainer.trailingAnchor),
                glass.topAnchor.constraint(equalTo: materialContainer.topAnchor),
                glass.bottomAnchor.constraint(equalTo: materialContainer.bottomAnchor),
            ])
            nativeGlassView = glass
        }
        notchGradientView.translatesAutoresizingMaskIntoConstraints = false
        materialContainer.addSubview(
            notchGradientView,
            positioned: .above,
            relativeTo: nativeGlassView
        )
        NSLayoutConstraint.activate([
            notchGradientView.leadingAnchor.constraint(
                equalTo: materialContainer.leadingAnchor
            ),
            notchGradientView.trailingAnchor.constraint(
                equalTo: materialContainer.trailingAnchor
            ),
            notchGradientView.topAnchor.constraint(
                equalTo: materialContainer.topAnchor
            ),
            notchGradientView.bottomAnchor.constraint(
                equalTo: materialContainer.bottomAnchor
            ),
        ])
        notchGradientView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        setCornerRadius(
            NotchUnifiedSurfacePolicy.cornerRadius(for: bounds.size)
        )
        updateLowerBorderPath()
    }

    func configure(
        appearance: NSAppearance?,
        material: NSVisualEffectView.Material,
        tint: NSColor,
        cornerRadius: CGFloat,
        glassEnabled: Bool,
        fallbackFill: NSColor,
        prefersClearGlass: Bool = false,
        glassOpacity: CGFloat = 1,
        clipsOnlyBottomCorners: Bool = false
    ) {
        let reduceTransparency =
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let boundedGlassOpacity = min(max(glassOpacity, 0), 1)
        self.clipsOnlyBottomCorners = clipsOnlyBottomCorners
        glassMaterialEnabled = glassEnabled
        glassMaterialOpacity = boundedGlassOpacity
        effectView.appearance = appearance
        effectView.material = material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.alphaValue =
            glassMaterialVisible ? boundedGlassOpacity : 0
        effectView.isHidden = !glassMaterialVisible
            || nativeGlassView != nil
            || !glassEnabled
            || reduceTransparency
        if #available(macOS 26.0, *),
           let glass = nativeGlassView as? NSGlassEffectView {
            glass.appearance = appearance
            glass.style = prefersClearGlass ? .clear : .regular
            glass.tintColor = tint
            glass.alphaValue =
                glassMaterialVisible ? boundedGlassOpacity : 0
            glass.isHidden = !glassMaterialVisible
                || !glassEnabled
                || reduceTransparency
        }
        setCornerRadius(cornerRadius)
        layer?.backgroundColor = NSColor.clear.cgColor
        materialContainer.layer?.backgroundColor = (
            reduceTransparency || !glassEnabled
                ? fallbackFill
                : NSColor.clear
        ).cgColor
    }

    func applyNotchMode(_ mode: NotchSurfaceMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask = nil
        layer?.masksToBounds = true
        switch mode {
        case .solid:
            layer?.borderWidth = 0
            lowerBorderLayer.isHidden = true
            setGlassMaterialVisible(false)
            notchGradientView.configure(
                visible: true,
                locations: [0, 1],
                alphas: [1, 1]
            )
        case let .answer(showsGlass):
            layer?.borderWidth = 0
            lowerBorderLayer.isHidden = !showsGlass
            setGlassMaterialVisible(showsGlass)
            notchGradientView.configure(
                visible: true,
                locations: showsGlass
                    ? NotchUnifiedSurfacePolicy.blackGradientLocations
                    : [0, 1],
                alphas: showsGlass
                    ? NotchUnifiedSurfacePolicy.blackGradientAlphas
                    : [1, 1]
            )
        }
        setCornerRadius(
            NotchUnifiedSurfacePolicy.cornerRadius(for: bounds.size)
        )
        updateLowerBorderPath()
        CATransaction.commit()
    }

    private func setGlassMaterialVisible(_ visible: Bool) {
        glassMaterialVisible = visible
        let reduceTransparency =
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.alphaValue = visible ? glassMaterialOpacity : 0
        effectView.isHidden = !visible
            || nativeGlassView != nil
            || !glassMaterialEnabled
            || reduceTransparency
        if #available(macOS 26.0, *),
           let glass = nativeGlassView as? NSGlassEffectView {
            glass.alphaValue = visible ? glassMaterialOpacity : 0
            glass.isHidden = !visible
                || !glassMaterialEnabled
                || reduceTransparency
        }
    }

    func setMaterialHidden(_ hidden: Bool) {
        materialContainer.isHidden = hidden
    }

    private func setCornerRadius(_ cornerRadius: CGFloat) {
        layer?.cornerRadius = cornerRadius
        layer?.maskedCorners = clipsOnlyBottomCorners
            ? [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
            ]
            : [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        if #available(macOS 26.0, *),
           let glass = nativeGlassView as? NSGlassEffectView {
            glass.cornerRadius = clipsOnlyBottomCorners ? 0 : cornerRadius
        }
    }

    private func updateLowerBorderPath() {
        guard clipsOnlyBottomCorners else {
            lowerBorderLayer.path = nil
            return
        }
        let inset = lowerBorderLayer.lineWidth / 2
        let minX = bounds.minX + inset
        let maxX = bounds.maxX - inset
        let minY = bounds.minY + inset
        let maxY = bounds.maxY - lowerBorderLayer.lineWidth
        let radius = min(
            NotchUnifiedSurfacePolicy.bottomCornerRadius,
            (maxX - minX) / 2,
            maxY - minY
        )
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: minY),
            control: CGPoint(x: minX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: minY + radius),
            control: CGPoint(x: maxX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY))
        lowerBorderLayer.frame = bounds
        lowerBorderLayer.path = path
    }
}

private final class VoiceStatusIndicatorView: NSView {
    private let segments = (0..<8).map { _ in CAShapeLayer() }
    private var lastPhase: VoiceSurfacePhase?
    private var lastColor: NSColor?
    private var lastAnimate = false
    private var lastProductName = ""
    private var lastReduceMotion = false
    var onActivate: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        segments.forEach {
            layer?.addSublayer($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let activity = lastPhase?.usesNotchActivityRing ?? false
        if activity {
            let diameter: CGFloat = 2.5
            let radius: CGFloat = 6
            for (index, segment) in segments.enumerated() {
                let fraction = CGFloat(index) / CGFloat(segments.count)
                let angle = fraction * CGFloat.pi * 2 + CGFloat.pi / 2
                let center = CGPoint(
                    x: bounds.midX + cos(angle) * radius,
                    y: bounds.midY + sin(angle) * radius
                )
                let frame = CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                segment.frame = frame
                segment.path = CGPath(
                    ellipseIn: CGRect(origin: .zero, size: frame.size),
                    transform: nil
                )
                segment.isHidden = false
            }
            return
        }
        let diameter = CompactIndicatorGeometry.dotDiameter
        let spacing = CompactIndicatorGeometry.dotSpacing
        let total = diameter * 3 + spacing * 2
        let startX = floor((bounds.width - total) / 2)
        for (index, segment) in segments.enumerated() {
            let frame = CGRect(
                x: startX + CGFloat(min(index, 2)) * (diameter + spacing),
                y: floor((bounds.height - diameter) / 2),
                width: diameter,
                height: diameter
            )
            segment.frame = frame
            segment.path = CGPath(
                ellipseIn: CGRect(origin: .zero, size: frame.size),
                transform: nil
            )
            segment.isHidden = index >= 3
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onOpenSettings?()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func update(
        phase: VoiceSurfacePhase,
        color: NSColor,
        animate: Bool,
        productName: String
    ) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if lastPhase == phase,
           lastColor?.isEqual(color) == true,
           lastAnimate == animate,
           lastProductName == productName,
           lastReduceMotion == reduceMotion {
            return
        }
        lastPhase = phase
        lastColor = color
        lastAnimate = animate
        lastProductName = productName
        lastReduceMotion = reduceMotion
        for (index, segment) in segments.enumerated() {
            segment.removeAllAnimations()
            segment.fillColor = color.cgColor
            segment.opacity = phase == .dormantWake
                ? (index == 1 ? 0.88 : 0.54)
                : 1
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let label: String
        switch phase {
        case .dormantWake: label = "\(productName) 준비됨"
        case .starting: label = "Voice 연결 중"
        case .listening: label = "듣고 있음"
        case .thinking: label = "Codex 확인 중"
        case .speaking: label = "답변 중"
        case .stopping: label = "Voice 종료 중"
        case .failed: label = "Voice 연결 실패"
        }
        setAccessibilityLabel(label)

        guard phase.animatesNotchIndicator,
              animate,
              !reduceMotion,
              phase != .failed else {
            return
        }
        let visibleSegmentCount = phase.usesNotchActivityRing ? segments.count : 3
        for (index, segment) in segments.prefix(visibleSegmentCount).enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.18, 1.0, 0.18]
            animation.keyTimes = [0, 0.24, 1]
            let duration: CFTimeInterval
            let stagger: CFTimeInterval
            if phase == .starting || phase == .listening {
                duration = 1.45
                stagger = 0.14
            } else if phase == .thinking {
                duration = 1.08
                stagger = 0.085
            } else {
                duration = 1.22
                stagger = 0.10
            }
            animation.duration = duration
            animation.repeatCount = Float.infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * stagger
            segment.add(animation, forKey: "voice-relay-status")
        }
    }
}

private enum ConversationSpeaker: Equatable {
    case user
    case assistant
}

private enum NotchHoverRegion: Hashable {
    case compact
    case conversation
}

private struct ConversationEntry {
    let speaker: ConversationSpeaker
    var text: String
}

private struct SurfaceAnimationTarget {
    let startFrame: NSRect
    let frame: NSRect
    let startAnswerHeight: CGFloat
    let answerHeight: CGFloat
    let startHeaderHeight: CGFloat
    let headerHeight: CGFloat
    let startHeaderWidth: CGFloat
    let headerWidth: CGFloat
    let startStatusIndicatorPosition: CGFloat?
    let statusIndicatorPosition: CGFloat?
    let startAnswerAlpha: CGFloat
    let answerAlpha: CGFloat
    let startActivityAlpha: CGFloat
    let activityAlpha: CGFloat
    let activityLabelVisible: Bool
    let generation: Int
    let startedAt: CFTimeInterval
    let completion: (() -> Void)?
}

private final class OverlayController: NSObject, NSWindowDelegate {
    private let config = AppConfig.load()
    private var displayGeometry: DisplayGeometry
    private let resolvedAnchor: OverlayAnchor

    private let panel: OverlayPanel
    private let orbReplyPanel: OverlayPanel
    private let notchUnifiedBackdropView = OverlaySurfaceView()
    private let inputCardView = OverlaySurfaceView()
    private let answerCardView = OverlaySurfaceView()
    private let statusIndicatorView = VoiceStatusIndicatorView()
    private let activityStatusLabel = NSTextField(labelWithString: "")
    private let notchHoverActionBar = NSStackView()
    private let notchVoiceButton = ShadowIconButton(frame: .zero)
    private let orbView = VoiceOrbView()
    private var statusIndicatorPositionConstraint: NSLayoutConstraint?
    private let toastLabel = NSTextField(labelWithString: "")
    private let answerScrollView = NSScrollView()
    private let answerTextView = NSTextView()
    private let bottomActionBar = NSStackView()
    private let voiceButton = ShadowIconButton(frame: .zero)
    private let settingsButton = ShadowIconButton(frame: .zero)
    private lazy var wakePhrase = WakePhraseController(
        localeIdentifiers: [config.speechLocale] + config.additionalSpeechLocales,
        phrases: config.wakePhrases,
        preferModernSpeechAnalyzer: config.preferModernSpeechAnalyzer,
        captureAdmission: { [weak self] reason in
            self?.wakeCaptureDecision(reason: reason) == .start
        }
    )
    private let codexClient: CodexAppRemoteClient
    private lazy var realtimeController = DirectRealtimeController(
        model: config.realtimeModel,
        voice: config.realtimeVoice,
        reasoningEffort: config.realtimeReasoningEffort,
        instructions: config.realtimeInstructions,
        language: config.speechLocale,
        additionalLanguages: config.additionalSpeechLocales,
        productName: config.productName,
        assistantName: config.assistantName,
        wakePhrases: config.wakePhrases
    )
    private let mediaPlaybackDetector = SystemMediaPlaybackDetector()
    private lazy var presenceMonitor = PresenceMonitor(
        policy: PresencePolicy(
            idleThreshold: TimeInterval(config.returnGreetingMinutes * 60),
            returnWindow: 15,
            greetingCooldown: 4 * 60 * 60
        )
    )
    private var answerHeightConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var inputWidthConstraint: NSLayoutConstraint?
    private var isApplyingFrame = false
    private var isAnimatingHide = false
    private var isWaitingForReply = false
    private var toastHideWorkItem: DispatchWorkItem?
    private var lastAnswer = ""
    private var realtimeStopAcknowledgementFallbackWorkItem: DispatchWorkItem?
    private var hoverStartWorkItem: DispatchWorkItem?
    private var hoverCollapseWorkItem: DispatchWorkItem?
    private var errorCollapseWorkItem: DispatchWorkItem?
    private var nextVoiceStartAllowedAt = Date.distantPast
    private var replyRetainUntil = Date.distantPast
    private var isShowingTransientError = false
    private var isHoveringNotch = false
    private var isHoveringOrbReply = false
    private var hoveredNotchRegions: Set<NotchHoverRegion> = []
    private var isHoverPreviewVisible = false
    private var isReplyPreviewVisible = false
    private var answerTargetVisible = false
    private var surfaceAnimationGeneration = 0
    private var panelAnimationGeneration = 0
    private var voiceState = VoiceSurfaceReducer()
    private var lastNotchActivityLayoutState: Bool?
    private var conversationHistory: [ConversationEntry] = []
    private var streamedAnswer = ""
    private var realtimeUserDraft = ""
    private var realtimeDraft = ""
    private var cancelledCodexGenerations: Set<Int> = []
    private var activeCodexGeneration: Int?
    private var voiceIdleWorkItem: DispatchWorkItem?
    private var mediaDetectionWorkItem: DispatchWorkItem?
    private var wakeResumeWorkItem: DispatchWorkItem?
    private var voiceStopFallbackWorkItem: DispatchWorkItem?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var assistantOutputLifecycle = AssistantOutputLifecycle()
    private var externalAudioConfirmation = ExternalAudioOutputConfirmation()
    private var wakeCaptureAdmission = WakeCaptureAdmission()
    private var mediaDetectedGeneration: Int?
    private var assistantFinalGeneration: Int?
    private var finalPlaybackDrainedGeneration: Int?
    private var userActivityGeneration: Int?
    private var answerLayoutWorkItem: DispatchWorkItem?
    private var pendingAnswerRender: (() -> Void)?
    private var answerLayoutGeneration = 0
    private var surfaceDisplayDriver: AnyObject?
    private var surfaceAnimationTarget: SurfaceAnimationTarget?
    private var orbDragStartFrame: NSRect?
    private var isDraggingOrb = false
    private var remotePrewarmInFlight = false
    private var didPrewarmRemote = false
    var onSettingsRequested: (() -> Void)?

    private var compactHeight: CGFloat
    private let bottomActionHeight: CGFloat = 36
    private let minAnswerHeightFloor: CGFloat = 38
    private let baseMaxAnswerHeight =
        NotchAnswerGeometry.maximumBodyHeight
    private let notchConnectionOverlap =
        NotchAnswerGeometry.connectionOverlap
    private let notchAnswerTopInset: CGFloat = 30
    private var currentAnswerHeight: CGFloat = 0
    private var currentAnswerWidth: CGFloat = 0

    init(codexClient: CodexAppRemoteClient) {
        self.codexClient = codexClient
        let initialScreen = DisplayGeometry.preferredScreen(
            for: config.overlayAnchor
        )
        let initialGeometry = DisplayGeometry(screen: initialScreen)
        let initialResolvedAnchor = initialGeometry.resolvedAnchor(for: config.overlayAnchor)
        displayGeometry = initialGeometry
        resolvedAnchor = initialResolvedAnchor
        let initialCompactHeight = initialGeometry.compactHeight(for: initialResolvedAnchor)
        compactHeight = initialCompactHeight
        let frame = OverlayPlacement.frame(
            display: initialGeometry,
            width: initialGeometry.compactWidth(for: initialResolvedAnchor),
            height: initialCompactHeight,
            anchor: initialResolvedAnchor
        )
        panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        orbReplyPanel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.allowsTopEdgeOverlap = resolvedAnchor == .notch
        buildWindow()
        wireCallbacks()
        wireRealtimeVoice()
        installEscapeMonitoring()
        codexClient.prefetchRealtimeCredential(
            model: config.realtimeModel,
            voice: config.realtimeVoice
        )
        wireWakePhrase()
        wirePresenceGreeting()
        installAppearanceObserver()
        if config.returnGreetingEnabled {
            presenceMonitor.start()
        }
    }

    deinit {
        hoverStartWorkItem?.cancel()
        hoverCollapseWorkItem?.cancel()
        errorCollapseWorkItem?.cancel()
        voiceIdleWorkItem?.cancel()
        mediaDetectionWorkItem?.cancel()
        wakeResumeWorkItem?.cancel()
        voiceStopFallbackWorkItem?.cancel()
        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        cancelAnswerLayout()
        stopSurfaceDisplayLink()
        orbReplyPanel.orderOut(nil)
        wakePhrase.pause(reason: "overlay_deinit")
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
        }
        presenceMonitor.stop()
        realtimeController.shutdown()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func show(onPresented: (() -> Void)? = nil) {
        isAnimatingHide = false
        let shouldFadeIn = !panel.isVisible || panel.alphaValue < 1
        let shouldShowAnswer = isHoverPreviewVisible
            || isReplyPreviewVisible
            || isShowingTransientError
        setAnswerVisible(shouldShowAnswer, animated: false)
        let targetHeight = desiredPanelHeight(answerVisible: shouldShowAnswer)
        let targetFrame = panelFrame(height: targetHeight)
        if shouldFadeIn {
            panel.alphaValue = 0
            panel.setFrame(targetFrame.offsetBy(dx: 0, dy: 14), display: true, animate: false)
        } else {
            positionPanel(height: targetHeight)
        }
        panel.orderFrontRegardless()
        if resolvedAnchor == .orb, shouldShowAnswer {
            positionOrbReplyPanel(animated: false)
            orbReplyPanel.orderFrontRegardless()
        }
        orbView.setSurfaceVisible(true)
        if shouldFadeIn {
            animatePanelEntrance(to: targetFrame, completion: onPresented)
        } else if let onPresented {
            DispatchQueue.main.async(execute: onPresented)
        }
    }

    func toggleVoiceFromMenu() {
        show()
        toggleVoiceInput()
    }

    @discardableResult
    func relayoutForDisplayChange() -> Bool {
        let screen = panel.screen ?? DisplayGeometry.preferredScreen(
            for: config.overlayAnchor
        )
        let geometry = DisplayGeometry(screen: screen)
        let nextAnchor = geometry.resolvedAnchor(for: config.overlayAnchor)
        guard nextAnchor == resolvedAnchor else { return false }
        displayGeometry = geometry
        compactHeight = geometry.compactHeight(for: resolvedAnchor)
        positionPanel(
            height: desiredPanelHeight(answerVisible: answerTargetVisible),
            animated: false
        )
        return true
    }

    func startWakePhraseAfterLaunchIfAuthorized() {
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authorization != .denied,
              authorization != .restricted else {
            return
        }
        show()
        prewarmVoiceBackend()
        guard config.wakePhraseEnabled,
              !voiceState.phase.isSessionActive else {
            return
        }
        resumeWakePhraseSoon(reason: "app_launch")
    }

    func startWakePhraseAfterSettingsSave() {
        guard config.wakePhraseEnabled,
              !voiceState.phase.isSessionActive else {
            return
        }
        resumeWakePhraseSoon(reason: "settings_save")
    }

    func windowDidMove(_ notification: Notification) {
        if resolvedAnchor == .orb {
            if !isDraggingOrb {
                savePanelPosition()
                positionOrbReplyPanel(animated: false)
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if resolvedAnchor == .orb {
            savePanelPosition()
        }
    }

    func closeForRebuild() {
        hoverStartWorkItem?.cancel()
        hoverCollapseWorkItem?.cancel()
        errorCollapseWorkItem?.cancel()
        voiceIdleWorkItem?.cancel()
        mediaDetectionWorkItem?.cancel()
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        voiceStopFallbackWorkItem?.cancel()
        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        cancelAnswerLayout()
        isShowingTransientError = false
        isHoverPreviewVisible = false
        isReplyPreviewVisible = false
        replyRetainUntil = .distantPast
        realtimeDraft = ""
        wakePhrase.pause(reason: "surface_rebuild")
        if voiceState.phase.isSessionActive {
            cancelActiveCodexRequest(
                generation: voiceState.generation,
                reason: "surface_rebuild"
            )
            voiceState.requestStop()
            realtimeController.stop(
                generation: voiceState.generation,
                reason: "surface_rebuild"
            )
        }
        realtimeController.shutdown()
        assistantOutputLifecycle.cancelAll(
            generation: voiceState.generation
        )
        hideToast(animated: false)
        orbView.setSurfaceVisible(false)
        orbReplyPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    func shutdownForApplicationTermination() {
        closeForRebuild()
    }

    @objc private func hidePanel() {
        hoverStartWorkItem?.cancel()
        hoverCollapseWorkItem?.cancel()
        errorCollapseWorkItem?.cancel()
        voiceIdleWorkItem?.cancel()
        cancelAnswerLayout()
        isShowingTransientError = false
        isHoveringNotch = false
        isHoverPreviewVisible = false
        isReplyPreviewVisible = false
        replyRetainUntil = .distantPast
        realtimeDraft = ""
        if voiceState.phase.isSessionActive {
            cancelActiveCodexRequest(
                generation: voiceState.generation,
                reason: "panel_hidden"
            )
            voiceState.requestStop()
            realtimeController.stop(
                generation: voiceState.generation,
                reason: "panel_hidden"
            )
        }
        lastAnswer = ""
        setAnswerText("")
        hideToast(animated: true)
        setAnswerVisible(false, animated: false)
        orbReplyPanel.orderOut(nil)
        fadeOutPanel()
    }

    private func codexConnectionOptions() throws -> CodexTurnOptions {
        let liveSettings = SettingsStore.shared.load()
        let workspacePath = try SettingsStore.validatedCodexWorkspacePath(
            config.codexWorkspacePath
        )
        return CodexTurnOptions(
            workspacePath: workspacePath,
            preferredThreadID: liveSettings.codexThreadID,
            preferredThreadTitle: liveSettings.codexThreadTitle,
            model: config.codexModel,
            reasoningEffort: config.codexReasoningEffort,
            sandbox: config.codexSandbox,
            approvalPolicy: config.codexApprovalPolicy,
            additionalContext: nil,
            additionalContextProvidersEnabled: false,
            additionalContextProvidersRoot: nil
        )
    }

    private func codexTurnOptions(
        userText: String,
        generation: Int
    ) throws -> CodexTurnOptions {
        let connection = try codexConnectionOptions()
        let liveSettings = SettingsStore.shared.load()
        let context: [String: [String: String]]?
        if config.includeAuthorityPack {
            do {
                let snapshot = try AuthorityPackComposer.snapshot(
                    from: config.authorityPackRoot
                )
                if snapshot.fingerprint == config.authorityPackFingerprint {
                    context = snapshot.context
                } else {
                    context = nil
                    VoiceRelayDiagnostics.flow(
                        "context_omitted",
                        generation: generation,
                        fields: [
                            "fallback": "without_optional_context",
                            "reason": "fingerprint_mismatch",
                            "source": "authority_pack",
                        ]
                    )
                }
            } catch {
                context = nil
                VoiceRelayDiagnostics.flow(
                    "context_omitted",
                    generation: generation,
                    fields: [
                        "fallback": "without_optional_context",
                        "reason": "snapshot_unavailable",
                        "source": "authority_pack",
                    ]
                )
            }
        } else {
            context = nil
        }
        let providersEnabled = liveSettings.includeAdditionalContextProviders
        let additionalContextProvidersRoot = providersEnabled
            ? SettingsStore.normalizedLocalPath(
                liveSettings.additionalContextProvidersRoot
            )
            : nil
        return CodexTurnOptions(
            workspacePath: connection.workspacePath,
            preferredThreadID: connection.preferredThreadID,
            preferredThreadTitle: connection.preferredThreadTitle,
            model: connection.model,
            reasoningEffort: connection.reasoningEffort,
            sandbox: connection.sandbox,
            approvalPolicy: connection.approvalPolicy,
            additionalContext: context,
            additionalContextProvidersEnabled: providersEnabled,
            additionalContextProvidersRoot: additionalContextProvidersRoot
        )
    }

    private func prewarmVoiceBackend() {
        guard !remotePrewarmInFlight, !didPrewarmRemote else { return }
        remotePrewarmInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let options = try self.codexConnectionOptions()
                self.codexClient.prepareThread(options: options) { result in
                    DispatchQueue.main.async {
                        self.remotePrewarmInFlight = false
                        if case .success = result {
                            self.didPrewarmRemote = true
                        }
                    }
                    if case let .failure(error) = result {
                        NSLog(
                            "Voice Relay task prewarm deferred: %@",
                            error.localizedDescription
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.remotePrewarmInFlight = false
                }
                NSLog(
                    "Voice Relay task prewarm skipped: %@",
                    error.localizedDescription
                )
            }
        }
    }

    private func performCodexRequest(
        _ text: String,
        generation: Int,
        displayResult: Bool,
        finishSurface: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        VoiceRelayDiagnostics.flow(
            "codex_request_preparing",
            generation: generation,
            transcriptFields: ["userText": text]
        )
        NSLog(
            "Voice Relay Codex Remote request preparing generation=%d",
            generation
        )
        let options: CodexTurnOptions
        do {
            options = try codexTurnOptions(
                userText: text,
                generation: generation
            )
        } catch {
            VoiceRelayDiagnostics.flow(
                "codex_request_rejected",
                generation: generation,
                fields: ["reason": error.localizedDescription],
                transcriptFields: ["userText": text]
            )
            NSLog(
                "Voice Relay Codex Remote request rejected generation=%d error=%@",
                generation,
                error.localizedDescription
            )
            completeCodexRequest(
                .failure(error),
                generation: generation,
                displayResult: displayResult,
                finishSurface: finishSurface
            )
            completion(.failure(error))
            return
        }

        streamedAnswer = ""
        activeCodexGeneration = generation
        VoiceRelayDiagnostics.flow(
            "codex_request_started",
            generation: generation,
            transcriptFields: ["userText": text]
        )
        NSLog(
            "Voice Relay Codex Remote ask started generation=%d",
            generation
        )
        codexClient.ask(
            text,
            options: options,
            onCommentary: { [weak self] commentary in
                DispatchQueue.main.async {
                    guard let self,
                          self.voiceState.generation == generation else {
                        return
                    }
                    self.presentCodexCommentary(
                        commentary,
                        generation: generation
                    )
                    VoiceRelayDiagnostics.flow(
                        "codex_commentary_received_host",
                        generation: generation,
                        fields: ["messageID": commentary.messageID],
                        transcriptFields: [
                            "assistantText": commentary.text
                        ]
                    )
                }
            },
            onContextOmission: { omission in
                DispatchQueue.main.async {
                    var fields = [
                        "fallback": omission.fallback,
                        "reason": omission.reason,
                        "source": omission.source,
                    ]
                    if let providerIndex = omission.providerIndex {
                        fields["providerIndex"] = String(providerIndex)
                    }
                    VoiceRelayDiagnostics.flow(
                        "context_omitted",
                        generation: generation,
                        fields: fields
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        if case let .success(reply) = result {
                            VoiceRelayDiagnostics.flow(
                                "codex_final_received_host",
                                generation: generation,
                                fields: ["status": "success"],
                                transcriptFields: [
                                    "assistantText": reply
                                ]
                            )
                        }
                        NSLog(
                            "Voice Relay Codex Remote ask completed generation=%d result=success",
                            generation
                        )
                    case let .failure(error):
                        VoiceRelayDiagnostics.flow(
                            "codex_final_received_host",
                            generation: generation,
                            fields: [
                                "reason": error.localizedDescription,
                                "status": "failure",
                            ]
                        )
                        NSLog(
                            "Voice Relay Codex Remote ask completed generation=%d result=failure error=%@",
                            generation,
                            error.localizedDescription
                        )
                    }
                    if self.activeCodexGeneration == generation {
                        self.activeCodexGeneration = nil
                    }
                    self.completeCodexRequest(
                        result,
                        generation: generation,
                        displayResult: displayResult,
                        finishSurface: finishSurface
                    )
                    completion(result)
                }
            }
        )
    }

    private func presentCodexCommentary(
        _ commentary: CodexCommentary,
        generation: Int
    ) {
        guard voiceState.generation == generation,
              activeCodexGeneration == generation,
              !cancelledCodexGenerations.contains(generation) else {
            return
        }
        let text = commentary.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        realtimeDraft = text
        isReplyPreviewVisible = true
        replyRetainUntil =
            NotchAnswerLifecyclePolicy.retentionDeadline()
        showConversationHistory(
            animated: !answerTargetVisible && config.animateSurface
        )
        scheduleConversationCollapse(
            delay: max(config.collapseDelay, 1.1)
        )
        realtimeController.speakCodexCommentary(
            text,
            messageID: commentary.messageID,
            generation: generation
        )
    }

    private func completeCodexRequest(
        _ result: Result<String, Error>,
        generation: Int,
        displayResult: Bool,
        finishSurface: Bool
    ) {
        guard voiceState.generation == generation,
              !cancelledCodexGenerations.contains(generation) else {
            return
        }
        switch result {
        case let .success(reply):
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayResult {
                lastAnswer = trimmed
                appendConversation(.assistant, text: trimmed)
                isReplyPreviewVisible = true
                replyRetainUntil =
                    NotchAnswerLifecyclePolicy.retentionDeadline()
                showConversationHistory(animated: config.animateSurface)
            }
            if finishSurface {
                isWaitingForReply = false
                voiceState.finishStop()
                updateVoiceSurface()
                if displayResult {
                    scheduleConversationCollapse(
                        delay: config.collapseDelay
                    )
                }
                resumeWakePhraseSoon()
            }
        case let .failure(error):
            if finishSurface {
                isWaitingForReply = false
                _ = voiceState.apply(generation: generation, phase: .failed)
                updateVoiceSurface()
            }
            if displayResult {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func toggleVoiceInput() {
        if voiceState.phase.isSessionActive {
            requestVoiceSessionStop(
                generation: voiceState.generation,
                reason: "voice_toggle"
            )
        } else {
            startRealtimeVoice()
        }
    }

    private func handleOrbPrimaryClick() {
        let hasReply = !lastAnswer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let shouldShowReply = hasReply && !orbReplyPanel.isVisible
        toggleVoiceInput()
        guard hasReply else { return }
        isReplyPreviewVisible = shouldShowReply
        setAnswerText(lastAnswer)
        setAnswerVisible(
            shouldShowReply,
            animated: config.animateSurface
        )
    }

    private func beginOrbDrag() {
        guard resolvedAnchor == .orb else { return }
        isDraggingOrb = true
        orbDragStartFrame = panel.frame
    }

    private func updateOrbDrag(delta: NSPoint) {
        guard resolvedAnchor == .orb,
              let startFrame = orbDragStartFrame else {
            return
        }
        var nextFrame = startFrame.offsetBy(dx: delta.x, dy: delta.y)
        let center = NSPoint(x: nextFrame.midX, y: nextFrame.midY)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(center)
        }) ?? panel.screen ?? DisplayGeometry.preferredScreen(
            for: config.overlayAnchor
        )
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let insetFrame = visibleFrame.insetBy(dx: 8, dy: 8)
        nextFrame.origin.x = min(
            max(nextFrame.minX, insetFrame.minX),
            max(insetFrame.minX, insetFrame.maxX - nextFrame.width)
        )
        nextFrame.origin.y = min(
            max(nextFrame.minY, insetFrame.minY),
            max(insetFrame.minY, insetFrame.maxY - nextFrame.height)
        )
        isApplyingFrame = true
        panel.setFrame(nextFrame, display: true, animate: false)
        isApplyingFrame = false
        positionOrbReplyPanel(animated: false)
    }

    private func finishOrbDrag() {
        guard resolvedAnchor == .orb else { return }
        isDraggingOrb = false
        orbDragStartFrame = nil
        savePanelPosition()
        positionOrbReplyPanel(animated: false)
    }

    private func buildWindow() {
        panel.title = config.productName
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = surfaceAppearance()
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = resolvedAnchor == .notch ? .mainMenu + 3 : .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.delegate = self
        if resolvedAnchor == .notch {
            panel.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
        }
        orbReplyPanel.title = "\(config.productName) Reply"
        orbReplyPanel.isOpaque = false
        orbReplyPanel.backgroundColor = .clear
        orbReplyPanel.appearance = surfaceAppearance()
        orbReplyPanel.hasShadow = false
        orbReplyPanel.isFloatingPanel = true
        orbReplyPanel.level = .floating
        orbReplyPanel.hidesOnDeactivate = false
        orbReplyPanel.isMovableByWindowBackground = false
        orbReplyPanel.collectionBehavior = panel.collectionBehavior
        orbReplyPanel.onCancel = { [weak self] in
            self?.setAnswerVisible(false, animated: true)
        }

        let colors = currentColors()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        configureGlassCard(
            notchUnifiedBackdropView,
            cornerRadius: resolvedAnchor == .notch
                ? NotchUnifiedSurfacePolicy.bottomCornerRadius
                : 0,
            colors: colors,
            glassEnabled: resolvedAnchor == .notch
        )
        notchUnifiedBackdropView.applyNotchMode(
            .solid
        )
        notchUnifiedBackdropView.isHidden = resolvedAnchor != .notch

        configureGlassCard(
            inputCardView,
            cornerRadius: resolvedAnchor == .notch
                ? NotchUnifiedSurfacePolicy.bottomCornerRadius
                : 27,
            colors: colors,
            glassEnabled: false
        )
        inputCardView.setMaterialHidden(resolvedAnchor == .notch)
        if resolvedAnchor == .notch {
            inputCardView.layer?.maskedCorners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
            ]
        } else {
            inputCardView.layer?.maskedCorners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        }
        let inputRow = makeInputRow()
        configureBottomActionBar()
        configureAnswerView()

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let hoverTracker = HoverTrackingView()
        hoverTracker.translatesAutoresizingMaskIntoConstraints = false
        hoverTracker.onHoverChanged = { [weak self] hovering in
            guard self?.resolvedAnchor == .notch else { return }
            self?.handleNotchHover(hovering, region: .compact)
        }
        header.addSubview(hoverTracker)
        header.addSubview(inputRow)
        let headerHeight = header.heightAnchor.constraint(
            equalToConstant: compactHeight
        )
        headerHeightConstraint = headerHeight
        NSLayoutConstraint.activate([
            headerHeight,
            hoverTracker.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hoverTracker.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hoverTracker.topAnchor.constraint(equalTo: header.topAnchor),
            hoverTracker.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            inputRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            inputRow.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
        ])
        inputCardView.addSubview(header)

        answerCardView.translatesAutoresizingMaskIntoConstraints = false
        answerCardView.wantsLayer = true
        answerCardView.layer?.backgroundColor = NSColor.clear.cgColor
        let answerHoverTracker = HoverTrackingView()
        answerHoverTracker.translatesAutoresizingMaskIntoConstraints = false
        answerHoverTracker.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if self.resolvedAnchor == .notch {
                self.handleNotchHover(
                    hovering,
                    region: .conversation
                )
            } else {
                self.isHoveringOrbReply = hovering
                self.hoverCollapseWorkItem?.cancel()
                self.hoverCollapseWorkItem = nil
                if !hovering, self.isReplyPreviewVisible {
                    self.scheduleConversationCollapse(
                        delay: self.config.collapseDelay
                    )
                }
            }
        }
        answerCardView.addSubview(answerHoverTracker)
        answerCardView.addSubview(answerScrollView)
        answerCardView.addSubview(bottomActionBar)
        configureGlassCard(
            answerCardView,
            cornerRadius: resolvedAnchor == .orb ? 20 : 0,
            colors: colors,
            glassEnabled: true
        )
        let surfaceViews: [NSView] = resolvedAnchor == .orb
            ? [inputCardView]
            : [inputCardView, answerCardView]
        let surface = NSStackView(views: surfaceViews)
        surface.orientation = .vertical
        surface.alignment = .centerX
        surface.spacing = -notchConnectionOverlap
        surface.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(notchUnifiedBackdropView)
        root.addSubview(surface)

        panel.contentView = root
        if resolvedAnchor == .orb {
            let replyRoot = NSView()
            replyRoot.wantsLayer = true
            replyRoot.layer?.backgroundColor = NSColor.clear.cgColor
            answerCardView.translatesAutoresizingMaskIntoConstraints = false
            replyRoot.addSubview(answerCardView)
            orbReplyPanel.contentView = replyRoot
        }
        realtimeController.attach(to: root)

        answerHeightConstraint = answerCardView.heightAnchor.constraint(equalToConstant: 0)
        answerHeightConstraint?.isActive = true
        inputWidthConstraint = inputCardView.widthAnchor.constraint(
            equalToConstant: displayGeometry.compactWidth(for: resolvedAnchor)
        )
        inputWidthConstraint?.isActive = true
        inputCardView.layer?.zPosition = 2
        answerCardView.layer?.zPosition = 1
        notchUnifiedBackdropView.layer?.zPosition = 0
        inputCardView.layer?.maskedCorners = resolvedAnchor == .notch
            ? [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
            ]
            : [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        answerCardView.isHidden = true
        answerCardView.alphaValue = 0
        answerCardView.layer?.cornerRadius = resolvedAnchor == .orb ? 20 : 0
        answerCardView.layer?.cornerCurve = .continuous
        answerCardView.layer?.masksToBounds = true
        answerCardView.layer?.maskedCorners = resolvedAnchor == .orb
            ? [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
            : [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
            ]

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),

            notchUnifiedBackdropView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            notchUnifiedBackdropView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notchUnifiedBackdropView.topAnchor.constraint(equalTo: root.topAnchor),
            notchUnifiedBackdropView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: inputCardView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: inputCardView.trailingAnchor),
            header.topAnchor.constraint(equalTo: inputCardView.topAnchor),
            header.bottomAnchor.constraint(equalTo: inputCardView.bottomAnchor),
            answerHoverTracker.leadingAnchor.constraint(
                equalTo: answerCardView.leadingAnchor
            ),
            answerHoverTracker.trailingAnchor.constraint(
                equalTo: answerCardView.trailingAnchor
            ),
            answerHoverTracker.topAnchor.constraint(
                equalTo: answerCardView.topAnchor
            ),
            answerHoverTracker.bottomAnchor.constraint(
                equalTo: answerCardView.bottomAnchor
            ),
            answerScrollView.leadingAnchor.constraint(equalTo: answerCardView.leadingAnchor, constant: 2),
            answerScrollView.trailingAnchor.constraint(equalTo: answerCardView.trailingAnchor, constant: -2),
            answerScrollView.topAnchor.constraint(
                equalTo: answerCardView.topAnchor,
                constant: resolvedAnchor == .notch ? notchAnswerTopInset : 0
            ),
            answerScrollView.bottomAnchor.constraint(equalTo: bottomActionBar.topAnchor),
            bottomActionBar.leadingAnchor.constraint(equalTo: answerCardView.leadingAnchor, constant: 14),
            bottomActionBar.trailingAnchor.constraint(equalTo: answerCardView.trailingAnchor, constant: -14),
            bottomActionBar.bottomAnchor.constraint(equalTo: answerCardView.bottomAnchor, constant: -4),
            bottomActionBar.heightAnchor.constraint(equalToConstant: bottomActionHeight),
        ])
        if resolvedAnchor == .orb,
           let replyRoot = orbReplyPanel.contentView {
            NSLayoutConstraint.activate([
                answerCardView.leadingAnchor.constraint(
                    equalTo: replyRoot.leadingAnchor
                ),
                answerCardView.trailingAnchor.constraint(
                    equalTo: replyRoot.trailingAnchor
                ),
                answerCardView.topAnchor.constraint(
                    equalTo: replyRoot.topAnchor
                ),
                answerCardView.bottomAnchor.constraint(
                    equalTo: replyRoot.bottomAnchor
                ),
            ])
        } else {
            answerCardView.widthAnchor.constraint(
                equalTo: surface.widthAnchor
            ).isActive = true
        }
        updateVoiceSurface()
    }

    private func configureGlassCard(
        _ view: OverlaySurfaceView,
        cornerRadius: CGFloat,
        colors: OverlayColors,
        glassEnabled: Bool
    ) {
        let appearance = surfaceAppearance()
        view.appearance = appearance
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0
        view.layer?.borderColor = colors.border.cgColor
        let isUnifiedNotchBackdrop =
            view === notchUnifiedBackdropView && resolvedAnchor == .notch
        let isOrbReply =
            view === answerCardView && resolvedAnchor == .orb
        let replyAppearance = orbReplyAppearance()
        let surfaceFill: NSColor
        if view === inputCardView, resolvedAnchor == .notch {
            surfaceFill = .black
        } else if isUnifiedNotchBackdrop {
            surfaceFill = NSColor.black.withAlphaComponent(0.94)
        } else if isOrbReply {
            surfaceFill = NSColor(
                calibratedWhite: replyAppearance.fallbackWhite,
                alpha: replyAppearance.fallbackAlpha
            )
        } else if view === answerCardView, resolvedAnchor == .notch,
                  NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            surfaceFill = NSColor(calibratedWhite: 0.06, alpha: 0.98)
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            surfaceFill = .windowBackgroundColor
        } else {
            surfaceFill = .clear
        }
        view.configure(
            appearance: appearance,
            material: colors.material,
            tint: isUnifiedNotchBackdrop
                ? NSColor.black.withAlphaComponent(
                    NotchUnifiedSurfacePolicy.nativeGlassTintAlpha
                )
                : (isOrbReply
                    ? NSColor(
                        calibratedWhite: replyAppearance.tintWhite,
                        alpha: replyAppearance.tintAlpha
                    )
                : (view === answerCardView && resolvedAnchor == .notch
                    ? .clear
                    : colors.fill.withAlphaComponent(0.18))),
            cornerRadius: cornerRadius,
            glassEnabled: glassEnabled,
            fallbackFill: surfaceFill,
            prefersClearGlass: (view === answerCardView && resolvedAnchor == .notch)
                || isUnifiedNotchBackdrop,
            glassOpacity: isUnifiedNotchBackdrop
                ? NotchUnifiedSurfacePolicy.nativeGlassOpacity
                : (isOrbReply
                    ? replyAppearance.glassOpacity
                    : 1),
            clipsOnlyBottomCorners: isUnifiedNotchBackdrop
        )
        view.layer?.masksToBounds = true
        if isOrbReply {
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor(
                calibratedWhite: replyAppearance.borderWhite,
                alpha: replyAppearance.borderAlpha
            )
                .cgColor
            view.layer?.shadowColor = NSColor.black.cgColor
            view.layer?.shadowOpacity = 0.28
            view.layer?.shadowRadius = 18
            view.layer?.shadowOffset = CGSize(width: 0, height: -3)
        }
    }

    private func makeInputRow() -> NSView {
        let row = NSView()
        let copy = AppCopy(
            preference: SettingsStore.shared.load().appDisplayLanguage
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        if resolvedAnchor == .notch {
            statusIndicatorView.translatesAutoresizingMaskIntoConstraints = false
            statusIndicatorView.toolTip = "Relay Voice"
            statusIndicatorView.onActivate = { [weak self] in
                self?.toggleVoiceInput()
            }
            statusIndicatorView.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
            activityStatusLabel.translatesAutoresizingMaskIntoConstraints = false
            activityStatusLabel.font = NotchActivityGeometry.font
            activityStatusLabel.textColor = NSColor.white.withAlphaComponent(0.88)
            activityStatusLabel.lineBreakMode = .byTruncatingTail
            activityStatusLabel.alignment = .center
            activityStatusLabel.setContentCompressionResistancePriority(
                .required,
                for: .horizontal
            )
            activityStatusLabel.setContentCompressionResistancePriority(
                .required,
                for: .vertical
            )
            activityStatusLabel.isHidden = true

            let notchActionColor = NSColor.white.withAlphaComponent(
                NotchActionIconPolicy.whiteAlpha
            )
            configureIconButton(
                notchVoiceButton,
                symbol: "mic.fill",
                color: notchActionColor,
                action: #selector(toggleVoiceInput)
            )
            notchVoiceButton.toolTip = copy.text(
                "Start or stop voice",
                "Voice 시작 또는 종료"
            )
            notchHoverActionBar.orientation = .horizontal
            notchHoverActionBar.alignment = .centerY
            notchHoverActionBar.translatesAutoresizingMaskIntoConstraints = false
            notchHoverActionBar.addArrangedSubview(notchVoiceButton)
            notchHoverActionBar.alphaValue = 0
            notchHoverActionBar.isHidden = true

            row.addSubview(statusIndicatorView)
            row.addSubview(activityStatusLabel)
            row.addSubview(notchHoverActionBar)
            let notchWidth = displayGeometry.hasHardwareNotch
                ? displayGeometry.hardwareNotchWidth
                : 210
            var constraints = [
                statusIndicatorView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                statusIndicatorView.widthAnchor.constraint(
                    equalToConstant: CompactIndicatorGeometry.viewWidth
                ),
                statusIndicatorView.heightAnchor.constraint(
                    equalToConstant: CompactIndicatorGeometry.viewHeight
                ),
                activityStatusLabel.centerXAnchor.constraint(equalTo: row.centerXAnchor),
                activityStatusLabel.leadingAnchor.constraint(
                    greaterThanOrEqualTo: row.leadingAnchor,
                    constant: 44
                ),
                activityStatusLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: row.trailingAnchor,
                    constant: -44
                ),
                activityStatusLabel.topAnchor.constraint(
                    equalTo: row.topAnchor,
                    constant: NotchActivityGeometry.labelTopInset(
                        safeTopInset: displayGeometry.safeTopInset
                    )
                ),
                activityStatusLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: row.bottomAnchor,
                    constant: -NotchActivityGeometry.labelBottomPadding
                ),
                notchHoverActionBar.trailingAnchor.constraint(
                    equalTo: row.trailingAnchor,
                    constant: -8
                ),
                notchHoverActionBar.centerYAnchor.constraint(
                    equalTo: row.centerYAnchor
                ),
                notchVoiceButton.widthAnchor.constraint(equalToConstant: 26),
                notchVoiceButton.heightAnchor.constraint(equalToConstant: 26),
            ]
            let centerConstraint = statusIndicatorView.centerXAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: CompactIndicatorGeometry.centerX(
                    windowWidth: displayGeometry.compactWidth(for: resolvedAnchor),
                    notchWidth: notchWidth
                )
            )
            statusIndicatorPositionConstraint = centerConstraint
            constraints.append(centerConstraint)
            NSLayoutConstraint.activate(constraints)
        } else {
            orbView.translatesAutoresizingMaskIntoConstraints = false
            orbView.toolTip = "Voice Relay"
            orbView.onActivate = { [weak self] in
                self?.handleOrbPrimaryClick()
            }
            orbView.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
            orbView.onDragBegan = { [weak self] in
                self?.beginOrbDrag()
            }
            orbView.onDragChanged = { [weak self] delta in
                self?.updateOrbDrag(delta: delta)
            }
            orbView.onDragEnded = { [weak self] in
                self?.finishOrbDrag()
            }
            row.addSubview(orbView)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 46),
                orbView.centerXAnchor.constraint(equalTo: row.centerXAnchor),
                orbView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                orbView.widthAnchor.constraint(equalToConstant: 46),
                orbView.heightAnchor.constraint(equalToConstant: 46),
            ])
        }

        return row
    }

    private func configureBottomActionBar() {
        let colors = currentColors()
        let copy = AppCopy(
            preference: SettingsStore.shared.load().appDisplayLanguage
        )
        let actionIconColor = resolvedAnchor == .notch
            ? NSColor.white.withAlphaComponent(
                NotchActionIconPolicy.whiteAlpha
            )
            : colors.secondaryText

        toastLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        toastLabel.textColor = colors.statusText
        toastLabel.lineBreakMode = .byTruncatingTail
        toastLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(
            voiceButton,
            symbol: "mic.fill",
            color: actionIconColor,
            action: #selector(toggleVoiceInput)
        )
        voiceButton.toolTip = copy.text(
            "Start or stop voice",
            "Voice 시작 또는 종료"
        )

        configureIconButton(
            settingsButton,
            symbol: "gearshape",
            color: actionIconColor,
            action: #selector(openSettings)
        )
        settingsButton.toolTip = copy.text("Settings", "설정")

        bottomActionBar.orientation = .horizontal
        bottomActionBar.alignment = .centerY
        bottomActionBar.spacing = 9
        bottomActionBar.translatesAutoresizingMaskIntoConstraints = false
        bottomActionBar.addArrangedSubview(toastLabel)
        bottomActionBar.addArrangedSubview(NSView())
        bottomActionBar.addArrangedSubview(settingsButton)
        bottomActionBar.addArrangedSubview(voiceButton)

        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
            voiceButton.widthAnchor.constraint(equalToConstant: 26),
            voiceButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @objc private func openSettings() {
        onSettingsRequested?()
    }

    private func configureAnswerView() {
        let colors = currentColors()
        let answerColor = resolvedAnchor == .orb
            ? orbReplyTextColor()
            : colors.text

        answerTextView.isEditable = false
        answerTextView.isSelectable = true
        answerTextView.drawsBackground = false
        answerTextView.textColor = answerColor
        answerTextView.font = answerFont()
        answerTextView.textContainerInset = NSSize(width: 16, height: 10)
        answerTextView.textContainer?.lineFragmentPadding = 0
        answerTextView.textContainer?.widthTracksTextView = true
        answerTextView.isVerticallyResizable = true
        answerTextView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor]

        answerScrollView.documentView = answerTextView
        answerScrollView.hasVerticalScroller = true
        answerScrollView.autohidesScrollers = true
        answerScrollView.scrollerStyle = .overlay
        answerScrollView.scrollerKnobStyle = .default
        answerScrollView.drawsBackground = false
        answerScrollView.borderType = .noBorder
        answerScrollView.translatesAutoresizingMaskIntoConstraints = false
        answerScrollView.wantsLayer = true
        answerScrollView.layer?.cornerRadius =
            resolvedAnchor == .notch ? 0 : 18
        answerScrollView.layer?.cornerCurve = .continuous
        answerScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        answerScrollView.verticalScroller?.controlSize = .mini
        answerScrollView.verticalScroller?.alphaValue = 0.55
        answerScrollView.scrollerInsets = NSEdgeInsets(
            top: NotchAnswerGeometry.scrollerTerminalInset,
            left: 0,
            bottom: NotchAnswerGeometry.scrollerTerminalInset,
            right: 2
        )
        answerScrollView.alphaValue = 1
    }

    private func configureIconButton(
        _ button: ShadowIconButton,
        symbol: String,
        color: NSColor,
        action: Selector
    ) {
        button.setSymbol(symbol, color: color)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func installAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceDidChange(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.applySystemAppearance()
        }
    }

    private func applySystemAppearance() {
        UserDefaults.standard.synchronize()

        let appearance = surfaceAppearance()
        let colors = currentColors()
        let replyAppearance = orbReplyAppearance()

        panel.appearance = appearance
        orbReplyPanel.appearance = appearance

        inputCardView.appearance = physicalNotchAppearance()
        answerCardView.appearance = appearance

        inputCardView.configure(
            appearance: physicalNotchAppearance(),
            material: colors.material,
            tint: .clear,
            cornerRadius: resolvedAnchor == .notch
                ? NotchUnifiedSurfacePolicy.bottomCornerRadius
                : 27,
            glassEnabled: false,
            fallbackFill: resolvedAnchor == .notch ? .black : .clear,
            clipsOnlyBottomCorners: resolvedAnchor == .notch
        )
        notchUnifiedBackdropView.configure(
            appearance: appearance,
            material: colors.material,
            tint: NSColor.black.withAlphaComponent(
                NotchUnifiedSurfacePolicy.nativeGlassTintAlpha
            ),
            cornerRadius: resolvedAnchor == .notch
                ? NotchUnifiedSurfacePolicy.bottomCornerRadius
                : 0,
            glassEnabled: resolvedAnchor == .notch,
            fallbackFill: NSColor.black.withAlphaComponent(0.94),
            prefersClearGlass: true,
            glassOpacity: NotchUnifiedSurfacePolicy.nativeGlassOpacity,
            clipsOnlyBottomCorners: resolvedAnchor == .notch
        )
        answerCardView.configure(
            appearance: appearance,
            material: colors.material,
            tint: resolvedAnchor == .notch
                ? .clear
                : (resolvedAnchor == .orb
                    ? NSColor(
                        calibratedWhite: replyAppearance.tintWhite,
                        alpha: replyAppearance.tintAlpha
                    )
                    : colors.fill.withAlphaComponent(0.18)),
            cornerRadius: resolvedAnchor == .orb
                ? OrbReplyPlacementPolicy.cornerRadius
                : 0,
            glassEnabled: true,
            fallbackFill: resolvedAnchor == .notch
                ? NSColor(calibratedWhite: 0.06, alpha: 0.98)
                : (resolvedAnchor == .orb
                    ? NSColor(
                        calibratedWhite: replyAppearance.fallbackWhite,
                        alpha: replyAppearance.fallbackAlpha
                    )
                    : .clear),
            prefersClearGlass: resolvedAnchor == .notch,
            glassOpacity: resolvedAnchor == .orb
                ? replyAppearance.glassOpacity
                : 1
        )
        if resolvedAnchor == .orb {
            answerCardView.layer?.borderWidth = 1
            answerCardView.layer?.borderColor = NSColor(
                calibratedWhite: replyAppearance.borderWhite,
                alpha: replyAppearance.borderAlpha
            )
                .cgColor
        }
        toastLabel.textColor = colors.statusText
        updateVoiceSurface()

        answerTextView.textColor = resolvedAnchor == .orb
            ? orbReplyTextColor()
            : colors.text
        if !answerTextView.string.isEmpty {
            setAnswerText(answerTextView.string)
        }

        if toastLabel.stringValue.isEmpty
            || toastLabel.stringValue == "Working..." {
            toastLabel.textColor = colors.statusText
        }
    }

    private func wireCallbacks() {
        panel.onCancel = { [weak self] in
            self?.cancelActiveInteractionAndCollapse(
                reason: "panel_cancel"
            )
        }
    }

    private func installEscapeMonitoring() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.keyCode == 53,
                  self?.handleEscapeIfNeeded() == true else {
                return event
            }
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                _ = self?.handleEscapeIfNeeded()
            }
        }
    }

    @discardableResult
    private func handleEscapeIfNeeded() -> Bool {
        let hasCancellableInteraction =
            voiceState.phase.isSessionActive
            || activeCodexGeneration != nil
            || isWaitingForReply
            || answerTargetVisible
        guard hasCancellableInteraction else { return false }
        cancelActiveInteractionAndCollapse(reason: "escape")
        return true
    }

    private func cancelActiveInteractionAndCollapse(reason: String) {
        hoverStartWorkItem?.cancel()
        hoverStartWorkItem = nil
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil
        errorCollapseWorkItem?.cancel()
        errorCollapseWorkItem = nil
        voiceIdleWorkItem?.cancel()
        voiceIdleWorkItem = nil
        mediaDetectionWorkItem?.cancel()
        mediaDetectionWorkItem = nil
        cancelAnswerLayout()
        assistantOutputLifecycle.cancelAll(
            generation: voiceState.generation
        )

        if activeCodexGeneration == voiceState.generation {
            cancelActiveCodexRequest(
                generation: voiceState.generation,
                reason: reason
            )
        }
        if voiceState.phase.isSessionActive {
            requestVoiceSessionStop(
                generation: voiceState.generation,
                reason: reason
            )
        }

        isWaitingForReply = false
        isShowingTransientError = false
        isHoveringNotch = false
        isHoverPreviewVisible = false
        isReplyPreviewVisible = false
        replyRetainUntil = .distantPast
        realtimeUserDraft = ""
        realtimeDraft = ""
        hideToast(animated: false)
        setAnswerVisible(false, animated: false)
        updateVoiceSurface()
    }

    private func wireRealtimeVoice() {
        realtimeController.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleRealtimeVoiceEvent(event)
            }
        }
        realtimeController.onInputLevel = { [weak self] level in
            guard let self, self.resolvedAnchor == .orb else { return }
            self.orbView.updateAudioLevel(level)
        }
        realtimeController.onCodexRequest = { [weak self] text, completion in
            guard let self else {
                completion(.failure(CodexAppRemoteError.processExited("앱이 닫혔어")))
                return
            }
            let generation = self.voiceState.generation
            self.performCodexRequest(
                text,
                generation: generation,
                displayResult: false,
                finishSurface: false,
                completion: completion
            )
        }
        realtimeController.onCodexSteer = { [weak self] text, completion in
            guard let self else {
                completion(.failure(CodexAppRemoteError.processExited("앱이 닫혔어")))
                return
            }
            self.codexClient.steerActiveTurn(text, completion: completion)
        }
        realtimeController.onSDPOffer = { [weak self] sdp, completion in
            guard let self else {
                completion(.failure(CodexAppRemoteError.processExited("앱이 닫혔어")))
                return
            }
            self.codexClient.startRealtime(
                offerSDP: sdp,
                model: self.config.realtimeModel,
                voice: self.config.realtimeVoice,
                completion: completion
            )
        }
    }

    private func wirePresenceGreeting() {
        presenceMonitor.onReturnCandidate = { [weak self] in
            guard let self,
                  !self.voiceState.phase.isSessionActive,
                  !self.isWaitingForReply else {
                return false
            }
            self.show()
            self.showToast(
                "다시 왔네",
                color: self.currentColors().statusText,
                autoHideAfter: 4
            )
            return true
        }
    }

    private func wireWakePhrase() {
        wakePhrase.onWake = { [weak self] match in
            VoiceRelayDiagnostics.flow(
                "wake_to_realtime_handoff",
                fields: [
                    "reason": match.command.isEmpty
                        ? "wake_only"
                        : "wake_with_command",
                ],
                transcriptFields: ["command": match.command]
            )
            self?.startRealtimeVoice(
                prefill: match.command,
                acknowledgeWake: match.command.isEmpty
            )
        }
        wakePhrase.onError = { [weak self] message in
            guard let self else { return }
            self.showToast(message, color: NSColor.systemOrange, autoHideAfter: 3.0)
        }
        wakePhrase.onCaptureDeferred = { [weak self] in
            self?.scheduleWakePhraseResumeCheck()
        }
    }

    private func handleRealtimeVoiceEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "ready" {
            VoiceRelayDiagnostics.flow(
                "realtime_runtime_ready",
                fields: ["source": "embedded_runtime"]
            )
            return
        }
        guard let generation = (event["generation"] as? NSNumber)?.intValue,
              generation == voiceState.generation else {
            return
        }
        var eventFields = ["type": type]
        for key in ["code", "kind", "phase", "responseId"] {
            if let value = event[key] as? String, !value.isEmpty {
                eventFields[key] = value
            }
        }
        let eventText = event["text"] as? String ?? ""
        let userEventTypes: Set<String> = [
            "userTranscript",
            "userTranscriptPartial",
        ]
        VoiceRelayDiagnostics.flow(
            "realtime_host_event",
            generation: generation,
            fields: eventFields,
            transcriptFields: userEventTypes.contains(type)
                ? ["userText": eventText]
                : ["assistantText": eventText]
        )

        switch type {
        case "state":
            guard let rawPhase = event["phase"] as? String,
                  let phase = VoiceSurfacePhase(rawValue: rawPhase),
                  voiceState.apply(generation: generation, phase: phase) else {
                return
            }
            updateVoiceSurface()
            if phase == .listening || phase == .speaking {
                prewarmVoiceBackend()
            }
            if phase == .listening {
                scheduleVoiceIdleTimeout()
                scheduleExternalAudioCheck(generation: generation)
                if !assistantOutputLifecycle.isActive {
                    scheduleConversationCollapse(
                        delay: isReplyPreviewVisible
                            ? max(config.collapseDelay, 1.1)
                            : config.collapseDelay
                    )
                }
            }
        case "userTranscriptPartial":
            guard let text = event["text"] as? String else { return }
            realtimeUserDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !realtimeUserDraft.isEmpty else { return }
            beginExternalAudioUserTurn(generation: generation)
            if resolvedAnchor == .notch {
                isReplyPreviewVisible = true
                showConversationHistory(
                    animated: !answerTargetVisible && config.animateSurface
                )
            }
        case "userTranscript":
            guard let text = event["text"] as? String else { return }
            SettingsStore.shared.completedFirstVoiceGreeting = true
            scheduleVoiceIdleTimeout()
            beginExternalAudioUserTurn(generation: generation)
            realtimeUserDraft = ""
            appendConversation(.user, text: text)
            if resolvedAnchor == .notch {
                isReplyPreviewVisible = true
                showConversationHistory(
                    animated: !answerTargetVisible && config.animateSurface
                )
            }
        case "assistantProgress":
            guard let text = event["text"] as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            realtimeDraft = trimmed
            isReplyPreviewVisible = true
            replyRetainUntil =
                NotchAnswerLifecyclePolicy.retentionDeadline()
            showConversationHistory(
                animated: !answerTargetVisible && config.animateSurface
            )
            scheduleConversationCollapse(
                delay: max(config.collapseDelay, 1.1)
            )
        case "assistantPartial":
            guard let text = event["text"] as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            realtimeDraft = trimmed
            isReplyPreviewVisible = true
            showConversationHistory(
                animated: !answerTargetVisible && config.animateSurface
            )
        case "codexHandoff":
            guard let text = event["text"] as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            realtimeDraft = trimmed
            if resolvedAnchor == .notch {
                isReplyPreviewVisible = true
                replyRetainUntil =
                    NotchAnswerLifecyclePolicy.retentionDeadline()
                showConversationHistory(
                    animated: !answerTargetVisible && config.animateSurface
                )
                scheduleConversationCollapse(
                    delay: max(config.collapseDelay, 1.1)
                )
            }
        case "assistantFinal":
            guard let text = event["text"] as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let responseID = (event["responseId"] as? String) ?? ""
            SettingsStore.shared.completedFirstVoiceGreeting = true
            assistantFinalGeneration = generation
            scheduleVoiceIdleTimeout()
            realtimeDraft = ""
            lastAnswer = trimmed
            appendConversation(.assistant, text: trimmed)
            isReplyPreviewVisible = true
            showConversationHistory(animated: true)
            if assistantOutputLifecycle.registerNativeFinal(
                generation: generation,
                responseID: responseID
            ) {
                replyRetainUntil = .distantPast
            } else {
                replyRetainUntil =
                    NotchAnswerLifecyclePolicy.retentionDeadline()
                scheduleConversationCollapse(
                    delay: max(config.collapseDelay, 1.1)
                )
            }
        case "assistantPlaybackDrained":
            guard let responseID = event["responseId"] as? String,
                  assistantOutputLifecycle.finishNativePlayback(
                    generation: generation,
                    responseID: responseID
                  ) else {
                return
            }
            finalPlaybackDrainedGeneration = generation
            replyRetainUntil =
                NotchAnswerLifecyclePolicy.retentionDeadline()
            scheduleConversationCollapse(
                delay: max(config.collapseDelay, 1.1)
            )
            stopForDetectedMediaIfReady(generation: generation)
        case "stopIntent":
            beginRealtimeSpokenStop(generation: generation)
        case "stopAcknowledgementDrained":
            finishRealtimeSpokenStop(generation: generation)
        case "terminal":
            guard !isShowingTransientError else { return }
            completeVoiceStop(generation: generation)
        case "turnError":
            realtimeDraft = ""
            isWaitingForReply = false
            scheduleVoiceIdleTimeout()
            let copy = AppCopy(
                preference: SettingsStore.shared.load().appDisplayLanguage
            )
            showToast(
                copy.text(
                    "I couldn't complete that request. Please try again.",
                    "그 요청만 처리하지 못했어. 다시 말해줘"
                ),
                color: NSColor.systemOrange,
                autoHideAfter: 3.0
            )
        case "error":
            let copy = AppCopy(
                preference: SettingsStore.shared.load().appDisplayLanguage
            )
            let message = (event["message"] as? String)
                ?? copy.text(
                    "Realtime connection error",
                    "Realtime 연결 오류"
                )
            NSLog("Voice Relay Realtime failed: %@", message)
            let wasEstablished = voiceState.phase != .starting
            let interruptedAnswer = realtimeDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
            isWaitingForReply = false
            voiceIdleWorkItem?.cancel()
            mediaDetectionWorkItem?.cancel()
            mediaDetectionWorkItem = nil
            assistantOutputLifecycle.cancelAll(generation: generation)
            if activeCodexGeneration == generation {
                cancelActiveCodexRequest(
                    generation: generation,
                    reason: "realtime_error"
                )
            }
            nextVoiceStartAllowedAt = Date().addingTimeInterval(2.5)
            _ = voiceState.apply(generation: generation, phase: .failed)
            updateVoiceSurface()
            showError(
                message,
                wasEstablished: wasEstablished,
                interruptedAnswer: interruptedAnswer
            )
            realtimeController.stop(
                generation: generation,
                reason: "realtime_error"
            )
        default:
            break
        }
    }

    private func startRealtimeVoice(
        prefill: String? = nil,
        acknowledgeWake: Bool = false
    ) {
        guard !voiceState.phase.isSessionActive,
              Date() >= nextVoiceStartAllowedAt else {
            VoiceRelayDiagnostics.flow(
                "realtime_start_suppressed",
                generation: voiceState.generation,
                fields: [
                    "active": String(voiceState.phase.isSessionActive),
                    "reason": voiceState.phase.isSessionActive
                        ? "session_already_active"
                        : "restart_cooldown",
                ],
                transcriptFields: ["prefill": prefill ?? ""]
            )
            return
        }
        nextVoiceStartAllowedAt = Date().addingTimeInterval(0.8)
        hoverStartWorkItem?.cancel()
        errorCollapseWorkItem?.cancel()
        errorCollapseWorkItem = nil
        isShowingTransientError = false
        isHoverPreviewVisible = false
        isReplyPreviewVisible = false
        realtimeDraft = ""
        resetExternalAudioMonitoring()
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        hideToast(animated: false)
        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        realtimeStopAcknowledgementFallbackWorkItem = nil
        setAnswerVisible(false, animated: config.animateSurface)
        wakePhrase.pause(reason: "realtime_handoff")
        let generation = voiceState.begin()
        VoiceRelayDiagnostics.flow(
            "realtime_surface_starting",
            generation: generation,
            fields: [
                "reason": prefill?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false
                    ? "wake_with_command"
                    : (acknowledgeWake ? "wake_only" : "manual"),
                "wake_microphone": "paused",
            ],
            transcriptFields: ["prefill": prefill ?? ""]
        )
        assistantOutputLifecycle.reset(generation: generation)
        userActivityGeneration = nil
        assistantFinalGeneration = nil
        finalPlaybackDrainedGeneration = nil
        mediaDetectedGeneration = nil
        externalAudioConfirmation.reset()
        scheduleVoiceIdleTimeout()
        scheduleExternalAudioCheck(generation: generation)
        prepareCodexGeneration(generation)
        if !panel.isVisible {
            show()
        }
        updateVoiceSurface()

        let exactPrefill = prefill?.trimmingCharacters(in: .whitespacesAndNewlines)
        realtimeController.start(
            generation: generation,
            prefill: exactPrefill?.isEmpty == false ? exactPrefill : nil,
            shouldGreet: acknowledgeWake
                || (conversationHistory.isEmpty
                    && !SettingsStore.shared.completedFirstVoiceGreeting),
            reason: exactPrefill?.isEmpty == false
                ? "wake_with_command"
                : (acknowledgeWake ? "wake_only" : "manual")
        )
    }

    private func wakeCaptureDecision(
        reason: String
    ) -> WakeCaptureAdmissionDecision {
        let snapshot = mediaPlaybackDetector.snapshot()
        let decision = wakeCaptureAdmission.observe(snapshot)
        VoiceRelayDiagnostics.flow(
            "wake_capture_admission",
            generation: voiceState.generation,
            fields: [
                "decision": String(describing: decision),
                "detector_available": snapshot.isAvailable ? "true" : "false",
                "media_latched":
                    wakeCaptureAdmission.mediaLatched ? "true" : "false",
                "process_count": String(snapshot.processLabels.count),
                "reason": reason,
                "stable_idle_samples":
                    String(wakeCaptureAdmission.stableIdleSamples),
            ]
        )
        return decision
    }

    private func resumeWakePhraseSoon(
        reason: String = "voice_session_completed",
        delay: TimeInterval = WakeMonitoringResumePolicy.activationDelay
    ) {
        guard config.wakePhraseEnabled else { return }
        wakeResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeResumeWorkItem = nil
            let captureDecision = self.wakeCaptureDecision(reason: reason)
            let captureBlocked = captureDecision != .start
            guard WakeMonitoringResumePolicy.shouldStart(
                voiceSessionActive: self.voiceState.phase.isSessionActive,
                externalAudioPlaying: captureBlocked,
                assistantOutputActive: self.assistantOutputLifecycle.isActive
            ) else {
                self.wakePhrase.pause(
                    reason: captureBlocked
                        ? "capture_admission_wait"
                        : "voice_or_assistant_output_active"
                )
                if !self.voiceState.phase.isSessionActive,
                   captureBlocked {
                    self.scheduleWakePhraseResumeCheck()
                }
                return
            }
            self.wakePhrase.startMonitoring(
                reason: reason
            )
        }
        wakeResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func scheduleWakePhraseResumeCheck() {
        guard config.wakePhraseEnabled,
              wakeResumeWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeResumeWorkItem = nil
            self.resumeWakePhraseSoon(
                reason: "media_admission_recheck",
                delay: 0
            )
        }
        wakeResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.75,
            execute: workItem
        )
    }

    private func scheduleVoiceIdleTimeout() {
        voiceIdleWorkItem?.cancel()
        guard voiceState.phase.isSessionActive else { return }
        let generation = voiceState.generation
        let delay = TimeInterval(config.voiceIdleTimeoutMinutes * 60)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.voiceState.generation == generation,
                  self.voiceState.phase.isSessionActive else {
                return
            }
            self.requestVoiceSessionStop(
                generation: generation,
                reason: "idle_timeout"
            )
        }
        voiceIdleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleExternalAudioCheck(
        generation: Int,
        delay: TimeInterval = 0.25
    ) {
        guard voiceState.generation == generation,
              voiceState.phase.isSessionActive,
              mediaDetectedGeneration != generation,
              mediaDetectionWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.mediaDetectionWorkItem = nil
            guard self.voiceState.generation == generation,
                  self.voiceState.phase.isSessionActive,
                  self.mediaDetectedGeneration != generation else {
                return
            }
            let snapshot = self.mediaPlaybackDetector.snapshot()
            _ = self.wakeCaptureAdmission.observe(snapshot)
            if self.externalAudioConfirmation.observe(snapshot) {
                self.mediaDetectedGeneration = generation
                VoiceRelayDiagnostics.flow(
                    "external_audio_detected",
                    generation: generation,
                    fields: [
                        "process_count": String(snapshot.processLabels.count),
                        "processes":
                            snapshot.processLabels.sorted()
                                .joined(separator: ","),
                    ]
                )
                self.stopForDetectedMediaIfReady(generation: generation)
                return
            }
            self.scheduleExternalAudioCheck(generation: generation)
        }
        mediaDetectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func stopForDetectedMediaIfReady(generation: Int) {
        guard voiceState.generation == generation,
              voiceState.phase.isSessionActive,
              mediaDetectedGeneration == generation else {
            return
        }
        guard ExternalMediaVoiceYieldPolicy.shouldStop(
            mediaConfirmed: mediaDetectedGeneration == generation,
            finalPlaybackDrained: finalPlaybackDrainedGeneration == generation,
            userActivityObserved: userActivityGeneration == generation,
            assistantFinalObserved: assistantFinalGeneration == generation,
            backendWorkActive: activeCodexGeneration == generation,
            phase: voiceState.phase
        ) else {
            return
        }
        requestVoiceSessionStop(
            generation: generation,
            reason: "external_audio_yield",
            interruptsCodex: false
        )
    }

    private func beginExternalAudioUserTurn(generation: Int) {
        let beginsNewTurn = ExternalMediaTurnBoundaryPolicy.beginsNewUserTurn(
            userActivityObserved: userActivityGeneration == generation,
            assistantFinalObserved: assistantFinalGeneration == generation,
            finalPlaybackDrained: finalPlaybackDrainedGeneration == generation,
            mediaConfirmed: mediaDetectedGeneration == generation,
            assistantOutputActive: assistantOutputLifecycle.isActive
        )
        userActivityGeneration = generation
        guard beginsNewTurn else { return }
        assistantOutputLifecycle.cancelAll(generation: generation)
        externalAudioConfirmation.reset()
        mediaDetectedGeneration = nil
        assistantFinalGeneration = nil
        finalPlaybackDrainedGeneration = nil
        scheduleExternalAudioCheck(generation: generation)
    }

    private func resetExternalAudioMonitoring() {
        mediaDetectionWorkItem?.cancel()
        mediaDetectionWorkItem = nil
        externalAudioConfirmation.reset()
        mediaDetectedGeneration = nil
        assistantFinalGeneration = nil
        finalPlaybackDrainedGeneration = nil
        userActivityGeneration = nil
    }

    private func requestVoiceSessionStop(
        generation: Int,
        reason: String = "user_request",
        interruptsCodex: Bool = true
    ) {
        guard voiceState.generation == generation,
              voiceState.phase.isSessionActive else {
            return
        }
        voiceIdleWorkItem?.cancel()
        voiceIdleWorkItem = nil
        mediaDetectionWorkItem?.cancel()
        mediaDetectionWorkItem = nil
        assistantOutputLifecycle.cancelAll(generation: generation)
        if interruptsCodex, activeCodexGeneration == generation {
            cancelActiveCodexRequest(
                generation: generation,
                reason: reason
            )
        }
        VoiceRelayDiagnostics.flow(
            "voice_session_stop_requested",
            generation: generation,
            fields: [
                "interruptsCodex": interruptsCodex ? "true" : "false",
                "reason": reason,
            ]
        )
        voiceState.requestStop()
        updateVoiceSurface()
        realtimeController.stop(
            generation: generation,
            reason: reason
        )

        voiceStopFallbackWorkItem?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self,
                  self.voiceState.generation == generation,
                  self.voiceState.phase == .stopping else {
                return
            }
            self.completeVoiceStop(generation: generation)
        }
        voiceStopFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.6,
            execute: fallback
        )
    }

    private func beginRealtimeSpokenStop(generation: Int) {
        guard voiceState.generation == generation,
              voiceState.phase.isSessionActive else {
            return
        }
        voiceIdleWorkItem?.cancel()
        voiceIdleWorkItem = nil
        mediaDetectionWorkItem?.cancel()
        mediaDetectionWorkItem = nil
        assistantOutputLifecycle.cancelAll(generation: generation)
        if activeCodexGeneration == generation {
            cancelActiveCodexRequest(
                generation: generation,
                reason: "spoken_stop"
            )
        }
        VoiceRelayDiagnostics.flow(
            "spoken_stop_accepted",
            generation: generation,
            fields: ["reason": "semantic_stop"]
        )
        voiceState.requestStop()
        updateVoiceSurface()

        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self,
                  self.voiceState.generation == generation,
                  self.voiceState.phase == .stopping else {
                return
            }
            self.requestVoiceSessionStop(
                generation: generation,
                reason: "spoken_stop_timeout"
            )
        }
        realtimeStopAcknowledgementFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 5,
            execute: fallback
        )
    }

    private func finishRealtimeSpokenStop(generation: Int) {
        guard voiceState.generation == generation,
              voiceState.phase == .stopping else {
            return
        }
        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        realtimeStopAcknowledgementFallbackWorkItem = nil
        requestVoiceSessionStop(
            generation: generation,
            reason: "spoken_stop_completed"
        )
    }

    private func completeVoiceStop(generation: Int) {
        guard voiceState.generation == generation else { return }
        realtimeStopAcknowledgementFallbackWorkItem?.cancel()
        realtimeStopAcknowledgementFallbackWorkItem = nil
        voiceStopFallbackWorkItem?.cancel()
        voiceStopFallbackWorkItem = nil
        isWaitingForReply = false
        voiceIdleWorkItem?.cancel()
        voiceIdleWorkItem = nil
        resetExternalAudioMonitoring()
        voiceState.finishStop()
        hideToast(animated: false)
        updateVoiceSurface()
        scheduleConversationCollapse(delay: max(config.collapseDelay, 1.1))
        resumeWakePhraseSoon()
    }

    private func prepareCodexGeneration(_ generation: Int) {
        cancelledCodexGenerations.remove(generation)
        cancelledCodexGenerations = Set(
            cancelledCodexGenerations.filter { $0 >= generation - 32 }
        )
    }

    private func cancelActiveCodexRequest(
        generation: Int,
        reason: String = "host_cancel"
    ) {
        guard activeCodexGeneration == generation else { return }
        VoiceRelayDiagnostics.flow(
            "codex_interrupt_requested",
            generation: generation,
            fields: ["reason": reason]
        )
        activeCodexGeneration = nil
        cancelledCodexGenerations.insert(generation)
        isWaitingForReply = false
        codexClient.interruptActiveTurn { [weak self] result in
            switch result {
            case .success:
                VoiceRelayDiagnostics.flow(
                    "codex_interrupt_completed",
                    generation: generation,
                    fields: [
                        "reason": reason,
                        "status": "success",
                    ]
                )
                return
            case let .failure(error):
                VoiceRelayDiagnostics.flow(
                    "codex_interrupt_completed",
                    generation: generation,
                    fields: [
                        "error_code": String((error as NSError).code),
                        "error_domain": (error as NSError).domain,
                        "reason": reason,
                        "status": "failure",
                    ]
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.codexClient.shutdown()
                    VoiceRelayDiagnostics.flow(
                        "codex_connection_closed",
                        generation: generation,
                        fields: [
                            "reason": "interrupt_confirmation_failed",
                        ]
                    )
                    if self.panel.isVisible {
                        self.showToast(
                            "Codex 중단 확인 실패, 연결을 닫았어",
                            color: .systemOrange,
                            autoHideAfter: 3
                        )
                    }
                    NSLog(
                        "Voice Relay turn interrupt failed: %@",
                        VoiceRelayDiagnostics.safe(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func handleNotchHover(
        _ hovering: Bool,
        region: NotchHoverRegion
    ) {
        if hovering {
            hoveredNotchRegions.insert(region)
            applyNotchHoverState(true)
            return
        }
        hoveredNotchRegions.remove(region)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyNotchHoverState(!self.hoveredNotchRegions.isEmpty)
        }
    }

    private func applyNotchHoverState(_ hovering: Bool) {
        guard resolvedAnchor == .notch else { return }
        guard hovering != isHoveringNotch else { return }
        isHoveringNotch = hovering
        hoverStartWorkItem?.cancel()
        hoverStartWorkItem = nil
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil

        if hovering {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            isHoverPreviewVisible = true
            let hasConversation = !conversationHistory.isEmpty
                || !lastAnswer.isEmpty
                || !realtimeUserDraft.isEmpty
                || !realtimeDraft.isEmpty
            if hasConversation && !answerTargetVisible {
                showConversationHistory(animated: config.animateSurface)
            }
        } else if isHoverPreviewVisible || isReplyPreviewVisible {
            scheduleConversationCollapse(delay: config.collapseDelay)
        }
        updateVoiceSurface()
    }

    private func scheduleConversationCollapse(delay: TimeInterval) {
        guard !isHoveringNotch,
              !isHoveringOrbReply,
              isHoverPreviewVisible || isReplyPreviewVisible else {
            return
        }
        hoverCollapseWorkItem?.cancel()
        let resolvedDelay = isReplyPreviewVisible
            ? NotchAnswerLifecyclePolicy.collapseDelay(
                requestedDelay: delay,
                retainUntil: replyRetainUntil
            )
            : delay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverCollapseWorkItem = nil
            guard self.isHoverPreviewVisible
                    || self.isReplyPreviewVisible else {
                return
            }
            let collapseBlocked =
                self.isHoveringNotch
                || self.isHoveringOrbReply
                || self.isWaitingForReply
                || self.isShowingTransientError
                || self.assistantOutputLifecycle.isActive
                || self.voiceState.phase.blocksConversationCollapse
            if collapseBlocked {
                self.scheduleConversationCollapse(delay: 0.5)
                return
            }
            self.isHoverPreviewVisible = false
            self.isReplyPreviewVisible = false
            self.replyRetainUntil = .distantPast
            self.setAnswerVisible(false, animated: self.config.animateSurface)
        }
        hoverCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(resolvedDelay, 0.2),
            execute: workItem
        )
    }

    private func updateVoiceSurface() {
        let colors = currentColors()
        let copy = AppCopy(
            preference: SettingsStore.shared.load().appDisplayLanguage
        )
        let symbol = voiceState.phase.isSessionActive ? "stop.fill" : "mic.fill"
        let accessibilityDescription: String
        let activityText: String

        switch voiceState.phase {
        case .dormantWake:
            accessibilityDescription = copy.text(
                "Start voice",
                "Voice 시작"
            )
            activityText = ""
        case .starting:
            accessibilityDescription = copy.text(
                "Connecting voice",
                "Voice 연결 중"
            )
            activityText = ""
        case .listening:
            accessibilityDescription = copy.text(
                "Listening",
                "듣고 있음"
            )
            activityText = ""
        case .thinking:
            accessibilityDescription = copy.text(
                "Checking",
                "확인 중"
            )
            activityText = copy.text("Checking", "확인 중")
        case .speaking:
            accessibilityDescription = copy.text(
                "Responding",
                "답변 중"
            )
            activityText = copy.text("Responding", "답변 중")
        case .stopping:
            accessibilityDescription = copy.text(
                "Stopping voice",
                "Voice 종료 중"
            )
            activityText = ""
        case .failed:
            accessibilityDescription = copy.text(
                "Voice connection failed",
                "Voice 연결 실패"
            )
            activityText = ""
        }
        activityStatusLabel.stringValue = activityText

        let voiceButtonColor: NSColor
        if resolvedAnchor == .notch {
            voiceButtonColor = voiceState.phase == .failed
                ? .systemOrange
                : NSColor.white
        } else {
            voiceButtonColor =
                voiceState.phase.isSessionActive || voiceState.phase == .failed
                    ? colors.accent
                    : colors.secondaryText
        }
        voiceButton.setSymbol(
            symbol,
            color: voiceButtonColor,
            accessibilityDescription: accessibilityDescription
        )
        if resolvedAnchor == .notch {
            notchVoiceButton.setSymbol(
                symbol,
                color: voiceButtonColor,
                accessibilityDescription: accessibilityDescription
            )
        }
        let indicatorColor: NSColor
        if voiceState.phase == .failed {
            indicatorColor = .systemOrange
        } else if resolvedAnchor == .notch {
            indicatorColor = voiceState.phase.isSessionActive
                ? .controlAccentColor
                : NSColor.white.withAlphaComponent(0.72)
        } else {
            indicatorColor = voiceState.phase.isSessionActive
                ? colors.accent
                : colors.secondaryText
        }
        statusIndicatorView.update(
            phase: voiceState.phase,
            color: indicatorColor,
            animate: config.animateSurface,
            productName: config.productName
        )
        orbView.update(
            phase: voiceState.phase,
            animate: config.animateSurface,
            productName: config.productName,
            isDark: resolvedAppearanceIsDark()
        )
        if resolvedAnchor == .notch {
            let presentation = NotchPresentation.resolve(
                phase: voiceState.phase,
                answerVisible: answerTargetVisible,
                hovering: isHoveringNotch
            )
            notchHoverActionBar.alphaValue =
                presentation.showsHoverVoiceAction ? 1 : 0
            notchHoverActionBar.isHidden =
                !presentation.showsHoverVoiceAction
            let activeLayout = presentation.headerExpanded
            if presentation.showsActivityLabel && !activityText.isEmpty {
                activityStatusLabel.isHidden = false
            }
            if lastNotchActivityLayoutState != activeLayout {
                lastNotchActivityLayoutState = activeLayout
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lastNotchActivityLayoutState == activeLayout else {
                        return
                    }
                    self.positionPanel(
                        height: self.desiredPanelHeight(
                            answerVisible: self.answerTargetVisible
                        ),
                        animated: self.panel.isVisible
                    )
                }
            } else if !presentation.showsActivityLabel || activityText.isEmpty {
                activityStatusLabel.alphaValue = 0
                activityStatusLabel.isHidden = true
            }
        }
    }

    private func appendConversation(_ speaker: ConversationSpeaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = conversationHistory.last,
           last.speaker == speaker,
           last.text == trimmed {
            return
        }
        conversationHistory.append(ConversationEntry(speaker: speaker, text: trimmed))
        if conversationHistory.count > config.recentTurnLimit {
            conversationHistory.removeFirst(
                conversationHistory.count - config.recentTurnLimit
            )
        }
    }

    private func showConversationHistory(animated: Bool) {
        if resolvedAnchor == .orb {
            let reply = realtimeDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                ? lastAnswer
                : realtimeDraft
            let trimmed = reply.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else {
                setAnswerVisible(false, animated: animated)
                return
            }
            setAnswerText(trimmed)
            currentAnswerHeight = measuredAnswerHeight(for: trimmed)
            setAnswerVisible(true, animated: animated)
            return
        }
        guard config.showRecentHistory
                || isWaitingForReply else {
            restoreLatestAnswer(animated: animated)
            return
        }
        var renderedImmediately = false
        if !answerTargetVisible {
            let text = setConversationHistoryText()
            currentAnswerHeight = measuredAnswerHeight(for: text)
            setAnswerVisible(true, animated: animated)
            renderedImmediately = true
        } else if animated {
            cancelAnswerLayout()
            let text = setConversationHistoryText()
            currentAnswerHeight = measuredAnswerHeight(for: text)
            updatePanelHeight(animated: true)
            renderedImmediately = true
        } else {
            scheduleAnswerLayout { [weak self] in
                guard let self else { return }
                _ = self.setConversationHistoryText()
            }
        }
        if renderedImmediately {
            scheduleScrollHistoryToBottom()
        }
    }

    private func restoreLatestAnswer(animated: Bool) {
        if !lastAnswer.isEmpty {
            setAnswerText(lastAnswer)
            currentAnswerHeight = measuredAnswerHeight(for: lastAnswer)
            if !answerTargetVisible {
                setAnswerVisible(true, animated: animated)
            } else {
                updatePanelHeight(animated: animated)
            }
        } else {
            setAnswerText("")
            setAnswerVisible(false, animated: animated)
        }
    }

    private func showError(
        _ message: String,
        wasEstablished: Bool = false,
        interruptedAnswer: String = ""
    ) {
        errorCollapseWorkItem?.cancel()
        isShowingTransientError = true
        isHoverPreviewVisible = false
        isReplyPreviewVisible = false
        realtimeDraft = ""
        isWaitingForReply = false
        let copy = AppCopy(
            preference: SettingsStore.shared.load().appDisplayLanguage
        )
        let friendlyMessage: String
        if message.localizedCaseInsensitiveContains("threadid")
            || message.localizedCaseInsensitiveContains("task") {
            friendlyMessage = copy.text(
                "Voice Relay could not prepare its dedicated session.\nCheck the Session ID in Settings.",
                "Voice용 전용 session을 준비하지 못했습니다.\n설정에서 Session ID를 확인해 주세요."
            )
        } else if wasEstablished {
            friendlyMessage = copy.text(
                "The voice connection was interrupted.\nPlease try that request again.",
                "답변 중 Voice 연결이 끊겼습니다.\n같은 요청을 다시 말해 주세요."
            )
        } else {
            friendlyMessage = copy.text(
                "Voice Relay could not start the voice connection.\nTry again in a moment.",
                "Voice 연결을 시작하지 못했습니다.\n잠시 후 다시 시도해 주세요."
            )
        }
        let displayedMessage =
            interruptedAnswer.isEmpty || !wasEstablished
                ? friendlyMessage
                : "\(interruptedAnswer)\n\n\(friendlyMessage)"
        setAnswerText(displayedMessage)
        currentAnswerHeight = measuredAnswerHeight(for: displayedMessage)
        setAnswerVisible(true, animated: config.animateSurface)
        showToast(
            wasEstablished
                ? copy.text(
                    "Voice connection interrupted",
                    "Voice 연결 끊김"
                )
                : copy.text(
                    "Voice connection failed",
                    "Voice 연결 실패"
                ),
            color: NSColor.systemRed
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingTransientError = false
            self.errorCollapseWorkItem = nil
            self.voiceState.finishStop()
            self.hideToast(animated: false)
            self.setAnswerText(self.lastAnswer)
            self.setAnswerVisible(false, animated: self.config.animateSurface)
            self.resumeWakePhraseSoon()
        }
        errorCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2, execute: workItem)
    }

    private func answerFont() -> NSFont {
        NSFont.systemFont(ofSize: 14.2, weight: .medium)
    }

    private func minimumAnswerHeight() -> CGFloat {
        let font = answerFont()
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let verticalInset = answerTextView.textContainerInset.height * 2
        let topInset = resolvedAnchor == .notch ? notchAnswerTopInset : 0
        return max(
            minAnswerHeightFloor + bottomActionHeight + topInset,
            ceil(lineHeight + verticalInset + bottomActionHeight + topInset + 2)
        )
    }

    private func answerParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.2
        style.paragraphSpacing = 0
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func answerAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: answerFont(),
            .foregroundColor: resolvedAnchor == .orb
                ? orbReplyTextColor()
                : currentColors().text,
            .paragraphStyle: answerParagraphStyle()
        ]
    }

    private func setAnswerText(_ text: String) {
        guard !text.isEmpty else {
            answerTextView.string = ""
            if !answerTargetVisible {
                currentAnswerWidth = 0
            }
            return
        }
        answerTextView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: answerAttributes())
        )
        scheduleScrollHistoryToBottom()
    }

    @discardableResult
    private func setConversationHistoryText() -> String {
        guard !conversationHistory.isEmpty
                || !realtimeUserDraft.isEmpty
                || !realtimeDraft.isEmpty else {
            setAnswerText("")
            return ""
        }

        let result = NSMutableAttributedString()
        for (index, entry) in conversationHistory.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            let label = entry.speaker == .user
                ? config.userDisplayName
                : config.assistantName
            result.append(
                NSAttributedString(
                    string: "\(label)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: entry.speaker == .user
                            ? currentColors().secondaryText
                            : currentColors().accent,
                        .paragraphStyle: answerParagraphStyle(),
                    ]
                )
            )
            result.append(
                NSAttributedString(
                    string: entry.text,
                    attributes: answerAttributes()
                )
            )
        }
        if !realtimeUserDraft.isEmpty {
            if !conversationHistory.isEmpty {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(
                NSAttributedString(
                    string: "\(config.userDisplayName)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: currentColors().secondaryText,
                        .paragraphStyle: answerParagraphStyle(),
                    ]
                )
            )
            result.append(
                NSAttributedString(
                    string: realtimeUserDraft,
                    attributes: answerAttributes()
                )
            )
        }
        if !realtimeDraft.isEmpty {
            if !conversationHistory.isEmpty || !realtimeUserDraft.isEmpty {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(
                NSAttributedString(
                    string: "\(config.assistantName)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: currentColors().accent,
                        .paragraphStyle: answerParagraphStyle(),
                    ]
                )
            )
            result.append(
                NSAttributedString(
                    string: realtimeDraft,
                    attributes: answerAttributes()
                )
            )
        }
        answerTextView.textStorage?.setAttributedString(result)
        scheduleScrollHistoryToBottom()
        return result.string
    }

    private func scrollHistoryToBottom() {
        guard let textContainer = answerTextView.textContainer else { return }
        answerTextView.layoutManager?.ensureLayout(for: textContainer)
        let range = NSRange(location: answerTextView.string.utf16.count, length: 0)
        answerTextView.scrollRangeToVisible(range)
    }

    private func scheduleScrollHistoryToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.answerTargetVisible else { return }
            if self.resolvedAnchor == .orb {
                self.orbReplyPanel.layoutIfNeeded()
            } else {
                self.panel.layoutIfNeeded()
            }
            self.scrollHistoryToBottom()
        }
    }

    private func measuredAnswerWidth(for text: String) -> CGFloat {
        if resolvedAnchor == .orb {
            let horizontalPadding =
                answerTextView.textContainerInset.width * 2 + 20
            let maxTextWidth = OrbReplyPlacementPolicy.maximumWidth
                - horizontalPadding
            let attributed = NSAttributedString(
                string: text,
                attributes: answerAttributes()
            )
            let measured = attributed.boundingRect(
                with: NSSize(
                    width: maxTextWidth,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            currentAnswerWidth = min(
                max(
                    ceil(measured.width) + horizontalPadding,
                    OrbReplyPlacementPolicy.minimumWidth
                ),
                OrbReplyPlacementPolicy.maximumWidth
            )
            return currentAnswerWidth
        }
        let geometry = DisplayGeometry(
            screen: panel.screen ?? DisplayGeometry.preferredScreen(
                for: config.overlayAnchor
            )
        )
        currentAnswerWidth = geometry.expandedWidth(for: resolvedAnchor)
        return currentAnswerWidth
    }

    private func measuredAnswerHeight(for text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let screenFrame = (
            panel.screen ?? DisplayGeometry.preferredScreen(
                for: config.overlayAnchor
            )
        )?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetWidth = measuredAnswerWidth(for: trimmed)
        let horizontalInset = answerTextView.textContainerInset.width * 2
        let textWidth = max(120, targetWidth - horizontalInset)
        let attributed = answerTextView.attributedString().string == text
            ? answerTextView.attributedString()
            : NSAttributedString(string: trimmed, attributes: answerAttributes())
        let rect = attributed.boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let measured = ceil(rect.height)
            + answerTextView.textContainerInset.height * 2
            + bottomActionHeight
            + (resolvedAnchor == .notch ? notchAnswerTopInset : 0)
        let policyMaxHeight = resolvedAnchor == .orb
            ? OrbReplyPlacementPolicy.maximumHeight
            : baseMaxAnswerHeight
        let maxHeight = min(policyMaxHeight, screenFrame.height * 0.54)
        return min(max(measured, minimumAnswerHeight()), maxHeight)
    }

    private func setAnswerVisible(_ visible: Bool, animated: Bool) {
        if resolvedAnchor == .orb {
            setOrbReplyVisible(visible, animated: animated)
            return
        }
        if visible == answerTargetVisible {
            if !visible {
                currentAnswerHeight = 0
                currentAnswerWidth = 0
                answerHeightConstraint?.constant = 0
                if answerCardView.isHidden {
                    answerCardView.alphaValue = 0
                }
                return
            }
            currentAnswerHeight = measuredAnswerHeight(for: answerTextView.string)
            if animated {
                cancelAnswerLayout()
                updatePanelHeight(animated: true)
            } else {
                scheduleAnswerLayout()
            }
            scheduleScrollHistoryToBottom()
            return
        }
        cancelAnswerLayout()
        surfaceAnimationGeneration += 1
        let animationGeneration = surfaceAnimationGeneration
        let wasActuallyHidden = answerCardView.isHidden
        answerTargetVisible = visible
        if resolvedAnchor == .notch {
            lastNotchActivityLayoutState = NotchPresentation.resolve(
                phase: voiceState.phase,
                answerVisible: visible,
                hovering: isHoveringNotch
            ).headerExpanded
        }
        if visible {
            currentAnswerHeight = measuredAnswerHeight(for: answerTextView.string)
            if wasActuallyHidden {
                answerCardView.isHidden = false
                answerHeightConstraint?.constant = 0
                answerCardView.alphaValue = 0
                panel.layoutIfNeeded()
            }
        } else {
            currentAnswerHeight = 0
        }

        if animated {
            positionPanel(
                height: desiredPanelHeight(answerVisible: visible),
                animated: true,
                answerHeight: visible ? currentAnswerHeight : 0
            ) {
                guard self.surfaceAnimationGeneration == animationGeneration else {
                    return
                }
                if !visible {
                    self.answerCardView.isHidden = true
                    self.answerCardView.alphaValue = 0
                    self.panel.layoutIfNeeded()
                    self.currentAnswerWidth = 0
                } else {
                    self.scheduleScrollHistoryToBottom()
                }
            }
        } else {
            answerCardView.alphaValue = visible ? 1 : 0
            positionPanel(
                height: desiredPanelHeight(answerVisible: visible),
                animated: false,
                answerHeight: visible ? currentAnswerHeight : 0
            )
            answerCardView.isHidden = !visible
            if visible {
                scheduleScrollHistoryToBottom()
            } else {
                currentAnswerWidth = 0
            }
        }
    }

    private func setOrbReplyVisible(_ visible: Bool, animated: Bool) {
        cancelAnswerLayout()
        surfaceAnimationGeneration += 1
        let transitionGeneration = surfaceAnimationGeneration
        answerTargetVisible = visible
        if visible {
            let text = answerTextView.string
            currentAnswerWidth = measuredAnswerWidth(for: text)
            currentAnswerHeight = measuredAnswerHeight(for: text)
            answerHeightConstraint?.constant = currentAnswerHeight
            answerCardView.isHidden = false
            positionOrbReplyPanel(animated: false)
            if !orbReplyPanel.isVisible {
                orbReplyPanel.alphaValue = animated ? 0 : 1
                orbReplyPanel.orderFrontRegardless()
            }
            if animated
                && !NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction =
                        CAMediaTimingFunction(name: .easeOut)
                    orbReplyPanel.animator().alphaValue = 1
                }
            } else {
                orbReplyPanel.alphaValue = 1
            }
            answerCardView.alphaValue = 1
            scheduleScrollHistoryToBottom()
            return
        }

        currentAnswerHeight = 0
        currentAnswerWidth = 0
        answerHeightConstraint?.constant = 0
        let finishHide = { [weak self] in
            guard let self,
                  self.surfaceAnimationGeneration == transitionGeneration,
                  !self.answerTargetVisible else {
                return
            }
            self.answerCardView.alphaValue = 0
            self.answerCardView.isHidden = true
            self.orbReplyPanel.orderOut(nil)
            self.orbReplyPanel.alphaValue = 1
        }
        if animated, orbReplyPanel.isVisible,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction =
                    CAMediaTimingFunction(name: .easeIn)
                orbReplyPanel.animator().alphaValue = 0
            } completionHandler: {
                finishHide()
            }
        } else {
            finishHide()
        }
    }

    private func updatePanelHeight(animated: Bool) {
        if resolvedAnchor == .orb {
            guard answerTargetVisible else { return }
            currentAnswerWidth = measuredAnswerWidth(
                for: answerTextView.string
            )
            currentAnswerHeight = measuredAnswerHeight(
                for: answerTextView.string
            )
            answerHeightConstraint?.constant = currentAnswerHeight
            positionOrbReplyPanel(animated: animated)
            scheduleScrollHistoryToBottom()
            return
        }
        let answerVisible = answerTargetVisible
        if answerVisible {
            currentAnswerHeight = measuredAnswerHeight(for: answerTextView.string)
        }
        let height = desiredPanelHeight(answerVisible: answerVisible)
        let targetConstraint = answerVisible ? currentAnswerHeight : 0
        if abs((answerHeightConstraint?.constant ?? 0) - targetConstraint) < 0.5,
           abs(panel.frame.height - height) < 0.5 {
            return
        }

        positionPanel(
            height: height,
            animated: animated,
            answerHeight: targetConstraint
        )
    }

    private func scheduleAnswerLayout(render: (() -> Void)? = nil) {
        if let render {
            pendingAnswerRender = render
        }
        guard answerTargetVisible,
              answerLayoutWorkItem == nil else {
            return
        }
        answerLayoutGeneration += 1
        let generation = answerLayoutGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.answerLayoutGeneration == generation else {
                return
            }
            self.answerLayoutWorkItem = nil
            guard self.answerTargetVisible else { return }
            let render = self.pendingAnswerRender
            self.pendingAnswerRender = nil
            render?()
            self.updatePanelHeight(animated: self.config.animateSurface)
            self.scheduleScrollHistoryToBottom()
        }
        answerLayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func cancelAnswerLayout() {
        answerLayoutGeneration += 1
        answerLayoutWorkItem?.cancel()
        answerLayoutWorkItem = nil
        pendingAnswerRender = nil
    }

    private static func smoothOutTiming() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    }

    private static func softEaseInTiming() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.67, 0.0)
    }

    private func animatePanelAlpha(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alpha
        }
    }

    private func animatePanelEntrance(
        to targetFrame: NSRect,
        completion: (() -> Void)? = nil
    ) {
        guard config.animateSurface,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: true, animate: false)
            savePanelPosition()
            DispatchQueue.main.async {
                completion?()
            }
            return
        }
        isApplyingFrame = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = Self.smoothOutTiming()
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.isApplyingFrame = false
            self?.savePanelPosition()
            completion?()
        }
    }

    private func showToast(_ text: String, color: NSColor, autoHideAfter delay: TimeInterval? = nil) {
        guard !text.isEmpty else {
            hideToast(animated: true)
            return
        }

        toastHideWorkItem?.cancel()
        toastLabel.stringValue = text
        toastLabel.textColor = color

        if let delay {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideToast(animated: true)
            }
            toastHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func hideToast(animated: Bool, completion: (() -> Void)? = nil) {
        toastHideWorkItem?.cancel()
        toastHideWorkItem = nil
        toastLabel.stringValue = ""
        updateVoiceSurface()
        completion?()
    }

    private func fadeOutPanel() {
        guard panel.isVisible else { return }
        guard config.animateSurface else {
            orbView.setSurfaceVisible(false)
            orbReplyPanel.orderOut(nil)
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        isAnimatingHide = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = Self.softEaseInTiming()
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isAnimatingHide else { return }
            self.orbView.setSurfaceVisible(false)
            self.orbReplyPanel.orderOut(nil)
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isAnimatingHide = false
        }
    }

    private func desiredPanelHeight(answerVisible: Bool) -> CGFloat {
        if resolvedAnchor == .orb {
            return compactHeight
        }
        let headerHeight = resolvedAnchor == .notch
            && lastNotchActivityLayoutState == true
            ? displayGeometry.activeHeight(for: resolvedAnchor)
            : compactHeight
        if answerVisible {
            let separation: CGFloat = resolvedAnchor == .orb
                ? 10
                : -notchConnectionOverlap
            return headerHeight
                + separation
                + max(currentAnswerHeight, minimumAnswerHeight())
        }
        return headerHeight
    }

    private func positionPanel(
        height: CGFloat,
        animated: Bool = false,
        answerHeight: CGFloat? = nil,
        completion: (() -> Void)? = nil
    ) {
        if resolvedAnchor == .orb {
            let frame = panelFrame(height: compactHeight)
            headerHeightConstraint?.constant = compactHeight
            inputWidthConstraint?.constant =
                displayGeometry.compactWidth(for: resolvedAnchor)
            panel.setFrame(frame, display: true, animate: false)
            isApplyingFrame = false
            if answerTargetVisible {
                if let answerHeight {
                    answerHeightConstraint?.constant = answerHeight
                }
                positionOrbReplyPanel(animated: animated)
            }
            savePanelPosition()
            completion?()
            return
        }
        let frame = panelFrame(height: height)
        let activityVisible = resolvedAnchor == .notch
            && lastNotchActivityLayoutState == true
        let targetHeaderHeight = activityVisible
            ? displayGeometry.activeHeight(for: resolvedAnchor)
            : compactHeight
        let targetHeaderWidth = activityVisible
            ? displayGeometry.activeWidth(
                for: resolvedAnchor,
                activityLabelWidth: activityStatusLabel.intrinsicContentSize.width
            )
            : displayGeometry.compactWidth(for: resolvedAnchor)
        let activityLabelVisible = NotchPresentation.resolve(
            phase: voiceState.phase,
            answerVisible: answerTargetVisible,
            hovering: isHoveringNotch
        ).showsActivityLabel && !activityStatusLabel.stringValue.isEmpty
        let shouldAnimate = animated
            && config.animateSurface
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let continuationVisible = answerTargetVisible
            || (shouldAnimate && !answerCardView.isHidden)
        configureNotchSurfacePresentation(
            continuationVisible: continuationVisible,
            answerMaterialVisible: answerTargetVisible
        )
        inputCardView.setMaterialHidden(resolvedAnchor == .notch)
        answerCardView.setMaterialHidden(resolvedAnchor == .notch)
        let headerCornerRadius = resolvedAnchor == .notch
            ? NotchUnifiedSurfacePolicy.bottomCornerRadius
            : targetHeaderHeight / 2
        inputCardView.layer?.cornerRadius = headerCornerRadius
        inputCardView.layer?.maskedCorners = resolvedAnchor == .notch
            ? [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
            ]
            : [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        panelAnimationGeneration += 1
        let animationGeneration = panelAnimationGeneration
        isApplyingFrame = true
        if shouldAnimate {
            panel.contentView?.layoutSubtreeIfNeeded()
            if activityLabelVisible {
                activityStatusLabel.isHidden = false
            }
            surfaceAnimationTarget = SurfaceAnimationTarget(
                startFrame: panel.frame,
                frame: frame,
                startAnswerHeight: answerHeightConstraint?.constant ?? 0,
                answerHeight: answerHeight
                    ?? answerHeightConstraint?.constant
                    ?? 0,
                startHeaderHeight: headerHeightConstraint?.constant
                    ?? targetHeaderHeight,
                headerHeight: targetHeaderHeight,
                startHeaderWidth: inputWidthConstraint?.constant
                    ?? targetHeaderWidth,
                headerWidth: targetHeaderWidth,
                startStatusIndicatorPosition:
                    statusIndicatorPositionConstraint?.constant,
                statusIndicatorPosition: statusIndicatorTargetPosition(
                    panelWidth: targetHeaderWidth
                ),
                startAnswerAlpha: answerCardView.alphaValue,
                answerAlpha: answerTargetVisible || !answerCardView.isHidden
                    ? 1
                    : 0,
                startActivityAlpha: activityStatusLabel.alphaValue,
                activityAlpha: activityLabelVisible ? 1 : 0,
                activityLabelVisible: activityLabelVisible,
                generation: animationGeneration,
                startedAt: CACurrentMediaTime(),
                completion: completion
            )
            startSurfaceDisplayLinkIfNeeded()
            scheduleSurfaceAnimationSettlement(
                surfaceAnimationTarget,
                generation: animationGeneration
            )
        } else {
            stopSurfaceDisplayLink()
            if let answerHeight {
                answerHeightConstraint?.constant = answerHeight
            }
            headerHeightConstraint?.constant = targetHeaderHeight
            inputWidthConstraint?.constant = targetHeaderWidth
            if let target = statusIndicatorTargetPosition(
                panelWidth: targetHeaderWidth
            ) {
                statusIndicatorPositionConstraint?.constant = target
            }
            if !answerCardView.isHidden {
                answerCardView.alphaValue = answerTargetVisible ? 1 : 0
            }
            activityStatusLabel.alphaValue = activityLabelVisible ? 1 : 0
            activityStatusLabel.isHidden = !activityLabelVisible
            if !answerTargetVisible {
                answerCardView.alphaValue = 0
                answerCardView.isHidden = true
            }
            panel.setFrame(frame, display: true, animate: false)
            panel.layoutIfNeeded()
            isApplyingFrame = false
            savePanelPosition()
            completion?()
        }
    }

    private func configureNotchSurfacePresentation(
        continuationVisible: Bool,
        answerMaterialVisible: Bool = true
    ) {
        let notchVisible = resolvedAnchor == .notch
        notchUnifiedBackdropView.isHidden = !notchVisible
        guard notchVisible else { return }
        if continuationVisible {
            notchUnifiedBackdropView.applyNotchMode(
                .answer(showsGlass: answerMaterialVisible)
            )
        } else {
            notchUnifiedBackdropView.applyNotchMode(.solid)
        }
    }

    private func statusIndicatorTargetPosition(
        panelWidth: CGFloat
    ) -> CGFloat? {
        guard resolvedAnchor == .notch,
              statusIndicatorPositionConstraint != nil else {
            return nil
        }
        let notchWidth = displayGeometry.hasHardwareNotch
            ? displayGeometry.hardwareNotchWidth
            : 210
        return CompactIndicatorGeometry.centerX(
            windowWidth: panelWidth,
            notchWidth: notchWidth
        )
    }

    private func startSurfaceDisplayLinkIfNeeded() {
        guard surfaceDisplayDriver == nil else { return }
        if #available(macOS 14.0, *) {
            let link = panel.displayLink(
                target: self,
                selector: #selector(surfaceDisplayLinkTick(_:))
            )
            link.add(to: .main, forMode: .common)
            surfaceDisplayDriver = link
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(surfaceTimerTick(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            surfaceDisplayDriver = timer
        }
    }

    private func scheduleSurfaceAnimationSettlement(
        _ target: SurfaceAnimationTarget?,
        generation: Int
    ) {
        guard let target else { return }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SurfaceMotionPolicy.maximumDuration
        ) { [weak self] in
            guard let self,
                  self.panelAnimationGeneration == generation,
                  self.surfaceAnimationTarget?.generation == generation else {
                return
            }
            self.finishSurfaceAnimation(target)
        }
    }

    private func stopSurfaceDisplayLink() {
        if #available(macOS 14.0, *),
           let link = surfaceDisplayDriver as? CADisplayLink {
            link.invalidate()
        } else {
            (surfaceDisplayDriver as? Timer)?.invalidate()
        }
        surfaceDisplayDriver = nil
        surfaceAnimationTarget = nil
    }

    @available(macOS 14.0, *)
    @objc private func surfaceDisplayLinkTick(_ displayLink: CADisplayLink) {
        advanceSurfaceAnimation(timestamp: CACurrentMediaTime())
    }

    @objc private func surfaceTimerTick(_ timer: Timer) {
        advanceSurfaceAnimation(timestamp: CACurrentMediaTime())
    }

    private func advanceSurfaceAnimation(timestamp: CFTimeInterval) {
        guard let target = surfaceAnimationTarget else {
            stopSurfaceDisplayLink()
            return
        }
        let progress = SurfaceMotionPolicy.animationProgress(
            elapsed: timestamp - target.startedAt
        )
        guard progress < 1 else {
            finishSurfaceAnimation(target)
            return
        }

        func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            SurfaceMotionPolicy.interpolatedValue(
                from: start,
                to: end,
                progress: progress
            )
        }

        let nextFrame = NSRect(
            x: interpolate(
                target.startFrame.origin.x,
                target.frame.origin.x
            ),
            y: interpolate(
                target.startFrame.origin.y,
                target.frame.origin.y
            ),
            width: interpolate(
                target.startFrame.width,
                target.frame.width
            ),
            height: interpolate(
                target.startFrame.height,
                target.frame.height
            )
        )
        if let constraint = answerHeightConstraint {
            constraint.constant = interpolate(
                target.startAnswerHeight,
                target.answerHeight
            )
        }
        if let constraint = headerHeightConstraint {
            constraint.constant = interpolate(
                target.startHeaderHeight,
                target.headerHeight
            )
        }
        if let constraint = inputWidthConstraint {
            constraint.constant = interpolate(
                target.startHeaderWidth,
                target.headerWidth
            )
        }
        if let position = target.statusIndicatorPosition,
           let constraint = statusIndicatorPositionConstraint {
            constraint.constant = interpolate(
                target.startStatusIndicatorPosition ?? constraint.constant,
                position
            )
        }
        if !answerCardView.isHidden {
            answerCardView.alphaValue = interpolate(
                target.startAnswerAlpha,
                target.answerAlpha
            )
        }
        activityStatusLabel.alphaValue = interpolate(
            target.startActivityAlpha,
            target.activityAlpha
        )
        panel.setFrame(nextFrame, display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func finishSurfaceAnimation(_ target: SurfaceAnimationTarget) {
        panel.setFrame(target.frame, display: true, animate: false)
        answerHeightConstraint?.constant = target.answerHeight
        headerHeightConstraint?.constant = target.headerHeight
        inputWidthConstraint?.constant = target.headerWidth
        if let position = target.statusIndicatorPosition {
            statusIndicatorPositionConstraint?.constant = position
        }
        if !answerCardView.isHidden {
            answerCardView.alphaValue = target.answerAlpha
        }
        activityStatusLabel.alphaValue = target.activityAlpha
        panel.contentView?.layoutSubtreeIfNeeded()
        stopSurfaceDisplayLink()
        guard panelAnimationGeneration == target.generation else { return }
        isApplyingFrame = false
        if !target.activityLabelVisible {
            activityStatusLabel.isHidden = true
        }
        if !answerTargetVisible {
            answerCardView.alphaValue = 0
            answerCardView.isHidden = true
        }
        configureNotchSurfacePresentation(
            continuationVisible: answerTargetVisible
                || !answerCardView.isHidden,
            answerMaterialVisible: answerTargetVisible
        )
        savePanelPosition()
        target.completion?()
    }

    private func panelFrame(height: CGFloat) -> NSRect {
        let screen = panel.screen ?? DisplayGeometry.preferredScreen(
            for: config.overlayAnchor
        )
        let geometry = DisplayGeometry(screen: screen)
        displayGeometry = geometry
        let width: CGFloat
        if resolvedAnchor == .orb {
            width = geometry.surfaceWidth(
                for: resolvedAnchor,
                answerVisible: false,
                activityVisible: false,
                activityLabelWidth: 0
            )
        } else if answerTargetVisible {
            width = currentAnswerWidth > 0
                ? currentAnswerWidth
                : measuredAnswerWidth(for: answerTextView.string)
        } else {
            width = geometry.surfaceWidth(
                for: resolvedAnchor,
                answerVisible: false,
                activityVisible: resolvedAnchor == .notch
                    && lastNotchActivityLayoutState == true,
                activityLabelWidth: activityStatusLabel.intrinsicContentSize.width
            )
        }
        let savedTopLeft = savedOrbCenterTop().map {
            NSPoint(x: $0.x - width / 2, y: $0.y)
        }
        return OverlayPlacement.frame(
            display: geometry,
            width: width,
            height: height,
            anchor: resolvedAnchor,
            savedTopLeft: savedTopLeft
        )
    }

    private func positionOrbReplyPanel(animated: Bool) {
        guard resolvedAnchor == .orb,
              answerTargetVisible else {
            return
        }
        let screen = panel.screen ?? NSScreen.screens.first(where: {
            $0.frame.intersects(panel.frame)
        }) ?? DisplayGeometry.preferredScreen(
            for: config.overlayAnchor
        )
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let requestedSize = NSSize(
            width: currentAnswerWidth > 0
                ? currentAnswerWidth
                : measuredAnswerWidth(for: answerTextView.string),
            height: currentAnswerHeight > 0
                ? currentAnswerHeight
                : measuredAnswerHeight(for: answerTextView.string)
        )
        let layout = OrbReplyPlacementPolicy.layout(
            orbFrame: panel.frame,
            requestedSize: requestedSize,
            visibleFrame: visibleFrame
        )
        answerHeightConstraint?.constant = layout.frame.height
        let shouldAnimate = animated
            && orbReplyPanel.isVisible
            && config.animateSurface
            && !NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction =
                    CAMediaTimingFunction(name: .easeOut)
                orbReplyPanel.animator().setFrame(
                    layout.frame,
                    display: true
                )
            }
        } else {
            orbReplyPanel.setFrame(
                layout.frame,
                display: true,
                animate: false
            )
        }
        orbReplyPanel.contentView?.layoutSubtreeIfNeeded()
    }

    private func savePanelPosition() {
        guard resolvedAnchor == .orb,
              !isApplyingFrame,
              panel.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.midX, forKey: "lastPanelCenterX")
        defaults.set(panel.frame.maxY, forKey: "lastPanelTopY")
    }

    private func savedOrbCenterTop() -> NSPoint? {
        guard resolvedAnchor == .orb else { return nil }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "lastPanelCenterX") != nil,
              defaults.object(forKey: "lastPanelTopY") != nil else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: "lastPanelCenterX"),
            y: defaults.double(forKey: "lastPanelTopY")
        )
    }

    private func systemPrefersDark() -> Bool {
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return true
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func systemAppearance() -> NSAppearance? {
        switch config.appearanceMode {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    private func physicalNotchAppearance() -> NSAppearance? {
        resolvedAnchor == .notch
            ? NSAppearance(named: .darkAqua)
            : systemAppearance()
    }

    private func surfaceAppearance() -> NSAppearance? {
        resolvedAnchor == .notch
            ? NSAppearance(named: .darkAqua)
            : systemAppearance()
    }

    private func resolvedAppearanceIsDark() -> Bool {
        resolvedAnchor == .notch
            || config.appearanceMode.resolvesDark(
                systemIsDark: systemPrefersDark()
            )
    }

    private func orbReplyAppearance() -> OrbReplyAppearance {
        OrbReplyAppearancePolicy.resolve(
            isDark: resolvedAppearanceIsDark(),
            reduceTransparency:
                NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    private func orbReplyTextColor() -> NSColor {
        let appearance = orbReplyAppearance()
        return NSColor(
            calibratedWhite: appearance.textWhite,
            alpha: appearance.textAlpha
        )
    }

    private func currentColors() -> OverlayColors {
        let isDark = resolvedAppearanceIsDark()
        return OverlayColors(
            material: .popover,
            fill: NSColor.windowBackgroundColor.withAlphaComponent(isDark ? 0.72 : 0.58),
            border: .clear,
            text: .labelColor,
            secondaryText: .secondaryLabelColor,
            statusText: .secondaryLabelColor,
            iconFill: NSColor.controlBackgroundColor.withAlphaComponent(
                isDark ? 0.22 : 0.34
            ),
            accent: .controlAccentColor
        )
    }

}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?
    private var displayChangeWorkItem: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private lazy var remoteClient: CodexAppRemoteClient = {
        let client = CodexAppRemoteClient(
            workspacePath: AppConfig.load().codexWorkspacePath
        )
        client.onThreadCreated = { threadID in
            do {
                try SettingsStore.shared.setManagedCodexThreadID(threadID)
            } catch {
                NSLog(
                    "Voice Relay task persistence failed: %@",
                    error.localizedDescription
                )
            }
        }
        return client
    }()
    private lazy var settingsController = SettingsWindowController(
        remoteClient: remoteClient
    )
    private lazy var onboardingController: OnboardingWindowController = {
        let controller = OnboardingWindowController(remoteClient: remoteClient)
        controller.onFinish = { [weak self] in
            self?.rebuildOverlay(show: true)
            self?.overlayController?.startWakePhraseAfterLaunchIfAuthorized()
        }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationIcon()
        installMainMenu()
        installStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        settingsController.onSave = { [weak self] in
            self?.installMainMenu()
            self?.installStatusItem()
            self?.rebuildOverlay(show: true)
            self?.overlayController?.startWakePhraseAfterSettingsSave()
        }
        settingsController.onReset = { [weak self] in
            self?.overlayController?.closeForRebuild()
            self?.overlayController = nil
            self?.onboardingController.showWindow(nil)
        }
        settingsController.onConnectionRecoveryWillBegin = { [weak self] in
            self?.overlayController?.closeForRebuild()
            self?.overlayController = nil
        }
        settingsController.onConnectionRecoveryDidEnd = { [weak self] in
            guard SettingsStore.shared.onboardingCompleted else { return }
            self?.rebuildOverlay(show: true)
            self?.overlayController?.startWakePhraseAfterLaunchIfAuthorized()
        }
        if SettingsStore.shared.onboardingCompleted {
            rebuildOverlay(show: true)
            overlayController?.startWakePhraseAfterLaunchIfAuthorized()
        } else {
            onboardingController.showWindow(nil)
        }
    }

    @objc private func displayParametersDidChange(_ notification: Notification) {
        displayChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, SettingsStore.shared.onboardingCompleted else { return }
            if self.overlayController?.relayoutForDisplayChange() == true {
                return
            }
            self.rebuildOverlay(show: true)
            self.overlayController?.startWakePhraseAfterLaunchIfAuthorized()
        }
        displayChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SettingsStore.shared.onboardingCompleted {
            if overlayController == nil {
                rebuildOverlay(show: true)
            } else {
                overlayController?.show()
            }
        } else {
            onboardingController.showWindow(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.shutdownForApplicationTermination()
        settingsController.shutdownSynchronously()
        if !SettingsStore.shared.onboardingCompleted {
            onboardingController.shutdownSynchronously()
        }
        remoteClient.shutdownSynchronously()
    }

    @objc private func openSettings() {
        settingsController.showWindow(nil)
    }

    @objc private func showVoiceRelay() {
        guard SettingsStore.shared.onboardingCompleted else {
            onboardingController.showWindow(nil)
            return
        }
        if overlayController == nil {
            rebuildOverlay(show: true)
        } else {
            overlayController?.show()
        }
    }

    @objc private func toggleVoiceFromMenu() {
        guard SettingsStore.shared.onboardingCompleted else {
            onboardingController.showWindow(nil)
            return
        }
        if overlayController == nil {
            rebuildOverlay(show: true)
        }
        overlayController?.toggleVoiceFromMenu()
    }

    private func rebuildOverlay(show: Bool) {
        overlayController?.closeForRebuild()
        let controller = OverlayController(codexClient: remoteClient)
        controller.onSettingsRequested = { [weak self] in
            self?.openSettings()
        }
        overlayController = controller
        if show {
            controller.show()
        }
    }

    private func installMainMenu() {
        let settings = SettingsStore.shared.load()
        let productName = settings.productName
        let copy = AppCopy(preference: settings.appDisplayLanguage)
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: productName)
        appMenuItem.submenu = appMenu
        let settingsItem = NSMenuItem(
            title: copy.text("Settings…", "설정…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: copy.text(
                "Hide \(productName)",
                "\(productName) 가리기"
            ),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: copy.text(
                "Quit \(productName)",
                "\(productName) 종료"
            ),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: copy.text("Edit", "편집"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: copy.text("Cut", "잘라내기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: copy.text("Copy", "복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: copy.text("Paste", "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: copy.text("Select All", "전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(
            forResource: "VoiceRelayIcon-1024",
            withExtension: "png"
        ),
        let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        icon.size = NSSize(width: 512, height: 512)
        NSApp.applicationIconImage = icon
    }

    private func installStatusItem() {
        let settings = SettingsStore.shared.load()
        let copy = AppCopy(preference: settings.appDisplayLanguage)
        let item = statusItem ?? NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        statusItem = item
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: settings.productName
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = settings.productName
        }
        let menu = NSMenu(title: settings.productName)
        let showItem = NSMenuItem(
            title: copy.text("Show \(settings.productName)", "\(settings.productName) 열기"),
            action: #selector(showVoiceRelay),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
        let voiceItem = NSMenuItem(
            title: copy.text("Start or stop voice", "음성 시작 또는 종료"),
            action: #selector(toggleVoiceFromMenu),
            keyEquivalent: ""
        )
        voiceItem.target = self
        menu.addItem(voiceItem)
        let settingsItem = NSMenuItem(
            title: copy.text("Settings…", "설정…"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: copy.text(
                "Quit \(settings.productName)",
                "\(settings.productName) 종료"
            ),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
    }
}

@main
private struct VoiceRelayApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
