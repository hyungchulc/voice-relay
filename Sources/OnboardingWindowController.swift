import AVFoundation
import Cocoa
import Speech

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let windowContentSize = NSSize(width: 700, height: 652)

    private enum Step: Int, CaseIterable {
        case welcome
        case identity
        case permissions
        case codex
        case session
        case voice
        case preferences
        case ready

        var sidebarTitle: String {
            switch self {
            case .welcome:
                return "Welcome"
            case .identity:
                return "에이전트 이름"
            case .permissions:
                return "마이크와 음성인식"
            case .codex:
                return "Codex 앱 연결"
            case .session:
                return "Session ID"
            case .voice:
                return "Voice"
            case .preferences:
                return "언어와 복귀 인사"
            case .ready:
                return "준비 완료"
            }
        }
    }
    private static let flow: [Step] = [
        .welcome,
        .identity,
        .permissions,
        .codex,
        .session,
        .voice,
        .ready,
    ]

    private let store: SettingsStore
    private var settings: AppSettings
    private var step: Step = .welcome
    private var probe: CodexAppRemoteClient?
    private var codexVerified = false
    private var voiceVerified = false

    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let stepNameLabel = NSTextField(labelWithString: "")
    private let stepDots = NSStackView()
    private var stepDotViews: [NSView] = []
    private let heroVisual = NSView()
    private let heroOrbView = VoiceOrbView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let pairingCodeControl = NSTextField()
    private let sessionIDControl = NSTextField()
    private let agentNameControl = NSTextField()
    private let wakePhrasesControl = NSTextField()
    private let appLanguageControl = NSPopUpButton()
    private let agentNameLabel = NSTextField(labelWithString: "")
    private let wakePhrasesLabel = NSTextField(labelWithString: "")
    private let appLanguageLabel = NSTextField(labelWithString: "")
    private let identityControls = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryAction = NSButton()
    private let secondaryAction = NSButton()
    private let backButton = NSButton()
    private let continueButton = NSButton()
    private var localizedCopy: AppCopy

    var onFinish: (() -> Void)?

    init(store: SettingsStore = .shared) {
        self.store = store
        settings = store.load()
        localizedCopy = AppCopy(preference: settings.appDisplayLanguage)
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: Self.windowContentSize
            ),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localizedCopy.text("Get Started", "시작하기")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = Self.windowContentSize
        window.contentMaxSize = Self.windowContentSize
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildFancyUI()
        render()
    }

    deinit {
        probe?.shutdown()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        step = .welcome
        render()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(sender)
        window.orderFrontRegardless()
    }

    func shutdown() {
        stopProbe()
    }

    func shutdownSynchronously() {
        probe?.shutdownSynchronously()
        probe = nil
    }

    private func buildFancyUI() {
        guard let content = window?.contentView else { return }

        let ambient = AmbientBackdropView()
        ambient.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(ambient)

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.clear.cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        let brandIcon = VoiceOrbView()
        brandIcon.setAccessibilityElement(false)
        brandIcon.setSurfaceVisible(true)
        brandIcon.update(
            phase: .dormantWake,
            animate: false,
            productName: settings.productName,
            isDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
        )

        let brandTitle = NSTextField(labelWithString: "Voice Relay")
        brandTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        stepNameLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        stepNameLabel.textColor = .secondaryLabelColor
        stepNameLabel.alignment = .right

        let brandRow = NSStackView(views: [
            brandIcon,
            brandTitle,
            NSView(),
            stepNameLabel,
        ])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 9
        brandRow.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(brandRow)

        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = Double(Self.flow.count)
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(progressBar)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.alignment = .right

        heroVisual.translatesAutoresizingMaskIntoConstraints = false
        heroOrbView.translatesAutoresizingMaskIntoConstraints = false
        heroOrbView.toolTip = "Voice Relay"
        iconView.translatesAutoresizingMaskIntoConstraints = false
        heroVisual.addSubview(heroOrbView)
        heroVisual.addSubview(iconView)

        iconView.symbolConfiguration = .init(pointSize: 48, weight: .medium)
        iconView.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 7

        pairingCodeControl.placeholderString = localizedCopy.text(
            "Example: AA1A-1AA1",
            "예시: AA1A-1AA1"
        )
        pairingCodeControl.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        pairingCodeControl.alignment = .center
        pairingCodeControl.isHidden = true
        sessionIDControl.placeholderString = localizedCopy.text(
            "Example: 00000000-0000-0000-0000-000000000000",
            "예시: 00000000-0000-0000-0000-000000000000"
        )
        sessionIDControl.font = .monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )
        sessionIDControl.alignment = .center
        sessionIDControl.isEditable = true
        sessionIDControl.isSelectable = true
        sessionIDControl.stringValue = settings.codexThreadID
        sessionIDControl.isHidden = true
        agentNameControl.placeholderString = "Relay"
        agentNameControl.stringValue = settings.assistantName
        agentNameControl.alignment = .center
        agentNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        agentNameLabel.textColor = .secondaryLabelColor
        wakePhrasesControl.placeholderString = "Relay, Hey Relay"
        wakePhrasesControl.stringValue = settings.wakePhrases.joined(separator: ", ")
        wakePhrasesControl.alignment = .center
        wakePhrasesControl.toolTip = localizedCopy.text(
            "Add up to eight phrases separated by commas or line breaks.",
            "쉼표나 줄바꿈으로 최대 8개까지 추가할 수 있습니다."
        )
        wakePhrasesLabel.font = .systemFont(ofSize: 12, weight: .medium)
        wakePhrasesLabel.textColor = .secondaryLabelColor
        appLanguageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        appLanguageLabel.textColor = .secondaryLabelColor
        configureAppLanguageControl()
        identityControls.orientation = .vertical
        identityControls.alignment = .leading
        identityControls.spacing = 6
        identityControls.addArrangedSubview(appLanguageLabel)
        identityControls.addArrangedSubview(appLanguageControl)
        identityControls.addArrangedSubview(agentNameLabel)
        identityControls.addArrangedSubview(agentNameControl)
        identityControls.addArrangedSubview(wakePhrasesLabel)
        identityControls.addArrangedSubview(wakePhrasesControl)
        identityControls.isHidden = true

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 4

        primaryAction.target = self
        primaryAction.action = #selector(primaryActionPressed)
        primaryAction.bezelStyle = .rounded
        secondaryAction.target = self
        secondaryAction.action = #selector(secondaryActionPressed)
        secondaryAction.bezelStyle = .rounded
        let leftActionSpacer = NSView()
        let rightActionSpacer = NSView()
        let actions = NSStackView(views: [
            leftActionSpacer,
            primaryAction,
            secondaryAction,
            rightActionSpacer,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        leftActionSpacer.widthAnchor.constraint(
            equalTo: rightActionSpacer.widthAnchor
        ).isActive = true

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.cornerRadius = 28
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0
        card.layer?.shadowOpacity = 0
        card.layer?.masksToBounds = false
        card.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(card)

        let hero = NSStackView(views: [
            heroVisual,
            titleLabel,
            bodyLabel,
            identityControls,
            pairingCodeControl,
            sessionIDControl,
            statusLabel,
            actions,
        ])
        hero.orientation = .vertical
        hero.alignment = .centerX
        hero.spacing = 16
        hero.setCustomSpacing(20, after: heroVisual)
        hero.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(hero)

        backButton.title = "이전"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(goForward)

        stepDots.orientation = .horizontal
        stepDots.alignment = .centerY
        stepDots.spacing = 7
        for _ in Self.flow {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            stepDots.addArrangedSubview(dot)
            stepDotViews.append(dot)
        }
        let leftNavigationSpacer = NSView()
        let rightNavigationSpacer = NSView()
        let navigation = NSStackView(views: [
            backButton,
            leftNavigationSpacer,
            stepDots,
            rightNavigationSpacer,
            continueButton,
        ])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 10
        navigation.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(navigation)

        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: content.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            brandRow.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
            brandRow.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            brandRow.topAnchor.constraint(equalTo: background.topAnchor, constant: 22),
            brandIcon.widthAnchor.constraint(equalToConstant: 28),
            brandIcon.heightAnchor.constraint(equalToConstant: 28),

            progressBar.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
            progressBar.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            progressBar.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 16),

            card.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
            card.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            card.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 18),
            card.bottomAnchor.constraint(equalTo: navigation.topAnchor, constant: -18),

            hero.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 42),
            hero.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -42),
            hero.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            hero.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 24),
            hero.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -24),
            heroVisual.widthAnchor.constraint(equalToConstant: 126),
            heroVisual.heightAnchor.constraint(equalToConstant: 126),
            heroOrbView.centerXAnchor.constraint(equalTo: heroVisual.centerXAnchor),
            heroOrbView.centerYAnchor.constraint(equalTo: heroVisual.centerYAnchor),
            heroOrbView.widthAnchor.constraint(equalToConstant: 118),
            heroOrbView.heightAnchor.constraint(equalToConstant: 118),
            iconView.centerXAnchor.constraint(equalTo: heroVisual.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: heroVisual.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 76),
            iconView.heightAnchor.constraint(equalToConstant: 76),
            titleLabel.widthAnchor.constraint(equalTo: hero.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: hero.widthAnchor),
            identityControls.widthAnchor.constraint(equalTo: hero.widthAnchor),
            actions.widthAnchor.constraint(equalTo: hero.widthAnchor),
            appLanguageControl.widthAnchor.constraint(equalTo: identityControls.widthAnchor),
            agentNameControl.widthAnchor.constraint(equalTo: identityControls.widthAnchor),
            wakePhrasesControl.widthAnchor.constraint(equalTo: identityControls.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: hero.widthAnchor),
            pairingCodeControl.widthAnchor.constraint(equalToConstant: 360),
            sessionIDControl.widthAnchor.constraint(equalToConstant: 430),

            navigation.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
            navigation.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            navigation.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
            stepDots.centerXAnchor.constraint(
                equalTo: navigation.centerXAnchor
            ),
        ])
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar)

        let brandMark = NSImageView()
        brandMark.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Relay"
        )
        brandMark.symbolConfiguration = .init(pointSize: 31, weight: .semibold)
        brandMark.contentTintColor = .controlAccentColor

        let brandTitle = NSTextField(labelWithString: "Voice Relay")
        brandTitle.font = .systemFont(ofSize: 22, weight: .bold)
        brandTitle.alignment = .center

        let brandSubtitle = NSTextField(wrappingLabelWithString:
            "Codex와 바로 연결되는\nmacOS Voice")
        brandSubtitle.font = .systemFont(ofSize: 13, weight: .medium)
        brandSubtitle.textColor = .secondaryLabelColor
        brandSubtitle.alignment = .center
        brandSubtitle.maximumNumberOfLines = 2

        stepNameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stepNameLabel.textColor = .labelColor
        stepNameLabel.alignment = .center
        stepNameLabel.maximumNumberOfLines = 2

        let privacy = NSTextField(wrappingLabelWithString:
            "마이크와 음성인식 외의\n추가 권한은 요청하지 않아.")
        privacy.font = .systemFont(ofSize: 11.5)
        privacy.textColor = .tertiaryLabelColor
        privacy.alignment = .center
        privacy.maximumNumberOfLines = 2

        let sidebarSpacer = NSView()
        let sidebarStack = NSStackView(views: [
            brandMark,
            brandTitle,
            brandSubtitle,
            sidebarSpacer,
            stepNameLabel,
            privacy,
        ])
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .centerX
        sidebarStack.spacing = 14
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)

        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = Double(Step.allCases.count)
        progressBar.controlSize = .small

        iconView.symbolConfiguration = .init(pointSize: 42, weight: .medium)
        iconView.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center

        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 8

        pairingCodeControl.placeholderString = localizedCopy.text(
            "Example: AA1A-1AA1",
            "예시: AA1A-1AA1"
        )
        sessionIDControl.placeholderString = localizedCopy.text(
            "Example: 00000000-0000-0000-0000-000000000000",
            "예시: 00000000-0000-0000-0000-000000000000"
        )
        pairingCodeControl.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        pairingCodeControl.alignment = .center
        pairingCodeControl.isEditable = true
        pairingCodeControl.isSelectable = true
        pairingCodeControl.isHidden = true

        sessionIDControl.placeholderString = localizedCopy.text(
            "Example: 00000000-0000-0000-0000-000000000000",
            "예시: 00000000-0000-0000-0000-000000000000"
        )
        sessionIDControl.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sessionIDControl.alignment = .center
        sessionIDControl.isEditable = true
        sessionIDControl.isSelectable = true
        sessionIDControl.stringValue = settings.codexThreadID
        sessionIDControl.isHidden = true

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 4

        primaryAction.target = self
        primaryAction.action = #selector(primaryActionPressed)
        secondaryAction.target = self
        secondaryAction.action = #selector(secondaryActionPressed)
        backButton.title = "이전"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(goForward)

        let actions = NSStackView(views: [primaryAction, secondaryAction])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 24
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(card)

        let contentStack = NSStackView(views: [
            iconView,
            titleLabel,
            bodyLabel,
            pairingCodeControl,
            sessionIDControl,
            statusLabel,
            actions,
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        let navigation = NSStackView(views: [backButton, NSView(), continueButton])
        navigation.orientation = .horizontal
        navigation.distribution = .fill
        navigation.spacing = 10
        navigation.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(navigation)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(progressBar)
        background.addSubview(progressLabel)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 206),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -22),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -28),
            brandMark.widthAnchor.constraint(equalToConstant: 52),
            brandMark.heightAnchor.constraint(equalToConstant: 52),
            sidebarSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),

            progressBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 34),
            progressBar.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -14),
            progressBar.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            progressLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -34),
            progressLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            progressLabel.widthAnchor.constraint(equalToConstant: 46),

            card.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 30),
            card.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            card.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 22),
            card.bottomAnchor.constraint(equalTo: navigation.topAnchor, constant: -22),

            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -34),
            contentStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -24),

            navigation.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 34),
            navigation.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -34),
            navigation.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -24),

            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            bodyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            pairingCodeControl.widthAnchor.constraint(equalToConstant: 360),
            sessionIDControl.widthAnchor.constraint(equalToConstant: 430),
            statusLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    private func render() {
        if window?.contentView?.bounds.size != Self.windowContentSize {
            window?.setContentSize(Self.windowContentSize)
        }
        localizedCopy = AppCopy(preference: settings.appDisplayLanguage)
        let flowIndex = Self.flow.firstIndex(of: step) ?? 0
        progressLabel.stringValue = "\(flowIndex + 1) / \(Self.flow.count)"
        progressBar.doubleValue = Double(flowIndex + 1)
        for (index, dot) in stepDotViews.enumerated() {
            dot.layer?.backgroundColor = (
                index == flowIndex
                    ? NSColor.controlAccentColor
                    : NSColor.tertiaryLabelColor.withAlphaComponent(0.38)
            ).cgColor
        }
        stepNameLabel.stringValue = stepTitle(step)
        window?.title = localizedCopy.text("Get Started", "시작하기")
        agentNameLabel.stringValue = localizedCopy.text(
            "Assistant name",
            "어시스턴트 이름"
        )
        wakePhrasesLabel.stringValue = localizedCopy.text(
            "Wake phrases",
            "웨이크워드"
        )
        appLanguageLabel.stringValue = localizedCopy.text(
            "App language",
            "앱 언어"
        )
        pairingCodeControl.placeholderString = localizedCopy.text(
            "Example: AA1A-1AA1",
            "예시: AA1A-1AA1"
        )
        backButton.isHidden = false
        primaryAction.isHidden = true
        secondaryAction.isHidden = true
        pairingCodeControl.isHidden = true
        sessionIDControl.isHidden = true
        identityControls.isHidden = true
        statusLabel.stringValue = ""
        statusLabel.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
        backButton.title = step == .welcome
            ? localizedCopy.text("Quit", "종료")
            : localizedCopy.text("Back", "이전")
        continueButton.title = step == .ready
            ? localizedCopy.text("Start", "시작")
            : localizedCopy.text("Continue", "계속")
        continueButton.isEnabled = true
        let useOrbHero = step == .welcome || step == .ready
        heroOrbView.isHidden = !useOrbHero
        iconView.isHidden = useOrbHero
        if useOrbHero {
            let systemIsDark =
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua
            heroOrbView.update(
                phase: step == .ready ? .speaking : .listening,
                animate: true,
                productName: settings.productName,
                isDark: AppAppearanceMode.parse(settings.appearanceMode)
                    .resolvesDark(systemIsDark: systemIsDark)
            )
        }

        switch step {
        case .welcome:
            set(
                icon: "app-icon",
                title: localizedCopy.text(
                    "Speak, and the work continues",
                    "말하면 작업이 자연스럽게 이어집니다."
                ),
                body: localizedCopy.text(
                    "Realtime answers simple conversation immediately.\nLarger requests move to Codex only when needed.",
                    "간단한 대화는 Realtime이 즉시 답합니다.\n더 큰 요청만 필요할 때 Codex로 전달합니다."
                )
            )
        case .identity:
            set(
                icon: "person.wave.2.fill",
                title: localizedCopy.text(
                    "Make the assistant yours",
                    "어시스턴트를 원하는 방식으로 설정합니다."
                ),
                body: localizedCopy.text(
                    "Choose its name, wake phrases, and app language.\nYou can change them later in Settings.",
                    "어시스턴트 이름, 웨이크워드와 앱 언어를 선택합니다.\n나중에 설정에서 언제든 변경할 수 있습니다."
                )
            )
            identityControls.isHidden = false
            statusLabel.stringValue = localizedCopy.text(
                "Example: Relay · Relay, Hey Relay",
                "예시: Relay · Relay, Hey Relay"
            )
        case .permissions:
            set(
                icon: "mic.badge.plus",
                title: localizedCopy.text(
                    "Microphone and speech recognition",
                    "마이크와 음성 인식 권한을 설정합니다."
                ),
                body: localizedCopy.text(
                    "These two permissions power voice and local wake phrases.\nCamera, screen recording, and Accessibility are not required.",
                    "두 권한은 음성과 로컬 웨이크워드에 사용합니다.\n카메라, 화면 기록과 접근성 권한은 필요하지 않습니다."
                )
            )
            primaryAction.title = localizedCopy.text(
                "Allow Microphone",
                "마이크 허용"
            )
            primaryAction.isHidden = false
            secondaryAction.title = localizedCopy.text(
                "Allow Speech Recognition",
                "음성 인식 허용"
            )
            secondaryAction.isHidden = false
            refreshPermissionStatus()
        case .codex:
            set(
                icon: "link",
                title: localizedCopy.text(
                    "Connect Codex/ChatGPT",
                    "Codex/ChatGPT에 연결합니다."
                ),
                body: localizedCopy.text(
                    "Pairing lets Voice Relay use your ChatGPT connection.\nIn ChatGPT, open Settings → Connections → Add, then paste the code shown there, such as AA1A-1AA1.",
                    "페어링하면 Voice Relay가 ChatGPT 연결을 사용할 수 있습니다.\nChatGPT에서 설정 → 연결 → 추가를 열고 표시된 코드를 AA1A-1AA1 형식으로 붙여넣으세요."
                )
            )
            pairingCodeControl.isHidden = false
            primaryAction.title = localizedCopy.text(
                "Connect Voice Relay",
                "Voice Relay 연결"
            )
            primaryAction.isHidden = false
            secondaryAction.title = localizedCopy.text(
                "Check Connection",
                "연결 상태 확인"
            )
            secondaryAction.isHidden = false
            continueButton.title = localizedCopy.text("Continue", "계속")
            continueButton.isEnabled = codexVerified
            if store.codexAppConnectionCompleted {
                verifyCodex()
            } else {
                statusLabel.stringValue =
                    localizedCopy.text(
                        "Complete pairing, then check the connection to continue.",
                        "페어링을 완료한 뒤 연결 상태를 확인해야 계속할 수 있습니다."
                    )
            }
        case .session:
            set(
                icon: "rectangle.stack.badge.person.crop",
                title: localizedCopy.text(
                    "Session ID",
                    "Session ID"
                ),
                body: localizedCopy.text(
                    "This is optional. In Codex, right-click a session and choose Copy Session ID, then paste it here to continue that session.\nLeave it empty to create a new dedicated session when voice starts.",
                    "선택 사항입니다. Codex에서 세션을 우클릭하고 Session ID 복사를 선택한 뒤 여기에 붙여넣으면 해당 세션을 이어서 사용합니다.\n비워 두면 음성을 시작할 때 새 전용 세션을 생성합니다."
                )
            )
            sessionIDControl.isHidden = false
            primaryAction.title = localizedCopy.text(
                "Use this Session ID",
                "이 Session ID 사용"
            )
            primaryAction.isHidden = false
            secondaryAction.title = localizedCopy.text(
                "Create new session",
                "새 session 생성"
            )
            secondaryAction.isHidden = false
            if !settings.codexThreadID.isEmpty {
                statusLabel.stringValue = localizedCopy.text(
                    "An existing Session ID is ready.",
                    "기존 Session ID가 입력되어 있습니다."
                )
                statusLabel.textColor = .systemGreen
            } else {
                statusLabel.stringValue = localizedCopy.text(
                    "A new dedicated session will be created when voice starts.",
                    "음성을 시작할 때 새 전용 session을 생성합니다."
                )
            }
        case .voice:
            set(
                icon: "waveform.circle.fill",
                title: localizedCopy.text(
                    "Connect Voice",
                    "Voice 연결"
                ),
                body: localizedCopy.text(
                    "Voice is the main Voice Relay experience.\nRealtime uses the paired ChatGPT connection and does not require an OpenAI API key.",
                    "Voice는 Voice Relay의 기본 기능입니다.\nRealtime은 연결된 ChatGPT를 사용하며 OpenAI API key는 필요하지 않습니다."
                )
            )
            primaryAction.title = localizedCopy.text(
                "Check Voice Connection",
                "Voice 연결 확인"
            )
            primaryAction.isHidden = false
            continueButton.isEnabled = voiceVerified
            verifyVoice()
        case .preferences:
            set(
                icon: "globe",
                title: localizedCopy.text(
                    "Language and return greeting",
                    "언어와 복귀 인사"
                ),
                body: localizedCopy.text(
                    "Speech recognition uses the system language by default.\nVoice Relay greets you once after you return from being away for at least 30 minutes.",
                    "음성 인식 언어는 기본적으로 시스템 언어를 사용합니다.\n30분 이상 자리를 비웠다가 돌아오면 한 번 인사합니다."
                )
            )
            statusLabel.stringValue = localizedCopy.text(
                "Wake phrases · Relay, Hey Relay\nReturn greeting · 30 minutes",
                "웨이크워드 · Relay, Hey Relay\n복귀 인사 · 30분"
            )
        case .ready:
            let resolved = DisplayGeometry(screen: NSScreen.main).resolvedAnchor(
                for: settings.overlayAnchor
            )
            let surfaceName = resolved == .notch ? "Notch" : "Orb"
            set(
                icon: "app-icon",
                title: localizedCopy.text(
                    "Voice Relay is ready",
                    "Voice Relay를 사용할 준비가 되었습니다."
                ),
                body: localizedCopy.text(
                    "\(surfaceName) is placed for this Mac.\nRealtime starts first and only necessary work is handed to Codex.",
                    "\(surfaceName)가 이 Mac에 맞게 배치됩니다.\nRealtime이 먼저 시작되고 필요한 작업만 Codex로 전달합니다."
                )
            )
            statusLabel.stringValue = localizedCopy.text(
                "Languages, wake phrases, and the prompt remain editable in Settings.",
                "언어, 웨이크워드와 프롬프트는 설정에서 언제든 변경할 수 있습니다."
            )
            statusLabel.textColor = .systemGreen
        }
    }

    private func set(icon: String, title: String, body: String) {
        if icon == "app-icon" {
            iconView.image = NSApp.applicationIconImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(
                systemSymbolName: icon,
                accessibilityDescription: title
            )
            iconView.contentTintColor = .controlAccentColor
        }
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        animateCurrentStep()
    }

    private func configureAppLanguageControl() {
        appLanguageControl.removeAllItems()
        let entries: [(String, AppDisplayLanguage)] = [
            (
                localizedCopy.text("System", "시스템 설정"),
                .system
            ),
            ("English", .english),
            ("한국어", .korean),
        ]
        for (title, language) in entries {
            appLanguageControl.addItem(withTitle: title)
            appLanguageControl.lastItem?.representedObject = language.rawValue
        }
        if let item = appLanguageControl.itemArray.first(where: {
            $0.representedObject as? String
                == AppDisplayLanguage.parse(settings.appDisplayLanguage).rawValue
        }) {
            appLanguageControl.select(item)
        }
        appLanguageControl.target = self
        appLanguageControl.action = #selector(appLanguageChanged)
    }

    @objc private func appLanguageChanged() {
        settings.appDisplayLanguage =
            appLanguageControl.selectedItem?.representedObject as? String
                ?? AppDisplayLanguage.system.rawValue
        localizedCopy = AppCopy(preference: settings.appDisplayLanguage)
        configureAppLanguageControl()
        render()
    }

    private func stepTitle(_ step: Step) -> String {
        switch step {
        case .welcome:
            return localizedCopy.text("Welcome", "환영합니다.")
        case .identity:
            return localizedCopy.text("Assistant", "어시스턴트")
        case .permissions:
            return localizedCopy.text("Permissions", "권한")
        case .codex:
            return localizedCopy.text("Codex", "Codex 연결")
        case .session:
            return "Session ID"
        case .voice:
            return localizedCopy.text("Voice", "음성")
        case .preferences:
            return localizedCopy.text("Preferences", "환경 설정")
        case .ready:
            return localizedCopy.text("Ready", "준비 완료")
        }
    }

    private func animateCurrentStep() {
        guard window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }
        let views = [
            heroVisual,
            titleLabel,
            bodyLabel,
            identityControls,
            statusLabel,
            primaryAction,
            secondaryAction,
        ]
        for (index, view) in views.enumerated() {
            view.wantsLayer = true
            view.alphaValue = 0
            let movement = CABasicAnimation(keyPath: "transform.translation.y")
            movement.fromValue = 10 + index * 2
            movement.toValue = 0
            movement.duration = 0.32
            movement.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(movement, forKey: "voice-relay-onboarding-enter")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            views.forEach { $0.animator().alphaValue = 1 }
        }
    }

    @objc private func goBack() {
        if step == .welcome {
            NSApp.terminate(nil)
            return
        }
        guard let index = Self.flow.firstIndex(of: step), index > 0 else { return }
        step = Self.flow[index - 1]
        render()
    }

    @objc private func goForward() {
        if step == .ready {
            finish()
            return
        }
        if step == .identity, !captureIdentitySelection() {
            return
        }
        if step == .codex, !codexVerified {
            statusLabel.stringValue = localizedCopy.text(
                "Pairing must be completed before you continue.",
                "계속하려면 페어링을 먼저 완료해야 합니다."
            )
            statusLabel.textColor = .systemOrange
            return
        }
        if step == .session, !captureSessionSelection() {
            return
        }
        if step == .voice, !voiceVerified {
            return
        }
        guard let index = Self.flow.firstIndex(of: step),
              index + 1 < Self.flow.count else { return }
        step = Self.flow[index + 1]
        render()
    }

    private func captureIdentitySelection() -> Bool {
        let assistantName = SettingsStore.normalizedDisplayName(
            agentNameControl.stringValue,
            fallback: ""
        )
        let wakePhrases = SettingsStore.normalizedWakePhrases(
            wakePhrasesControl.stringValue.components(
                separatedBy: CharacterSet(charactersIn: ",\n")
            )
        )
        guard !assistantName.isEmpty else {
            statusLabel.stringValue = localizedCopy.text(
                "Enter an assistant name.",
                "어시스턴트 이름을 입력해 주세요."
            )
            statusLabel.textColor = .systemRed
            return false
        }
        settings.assistantName = assistantName
        settings.wakePhrases = wakePhrases
        agentNameControl.stringValue = assistantName
        wakePhrasesControl.stringValue = wakePhrases.joined(separator: ", ")
        return true
    }

    @objc private func primaryActionPressed() {
        switch step {
        case .permissions:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissionStatus() }
            }
        case .codex:
            connectCodexApp()
        case .session:
            _ = captureSessionSelection()
        case .voice:
            verifyVoice(force: true)
        default:
            break
        }
    }

    @objc private func secondaryActionPressed() {
        switch step {
        case .permissions:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissionStatus() }
            }
        case .codex:
            verifyCodex(force: true)
        case .session:
            sessionIDControl.stringValue = ""
            settings.codexThreadID = ""
            settings.codexThreadSource = ""
            settings.codexThreadTitle = "Voice Relay"
            statusLabel.stringValue = localizedCopy.text(
                "A new dedicated session will be created when voice starts.",
                "음성을 시작할 때 새 전용 session을 생성합니다."
            )
            statusLabel.textColor = .systemGreen
        default:
            break
        }
    }

    private func refreshPermissionStatus() {
        let mic = permissionText(AVCaptureDevice.authorizationStatus(for: .audio))
        let speech = speechText(SFSpeechRecognizer.authorizationStatus())
        statusLabel.stringValue = localizedCopy.text(
            "Microphone · \(mic)\nSpeech Recognition · \(speech)",
            "마이크 · \(mic)\n음성 인식 · \(speech)"
        )
    }

    private func verifyCodex(force: Bool = false) {
        guard force || !codexVerified else { return }
        let client = makeProbe()
        statusLabel.stringValue = localizedCopy.text(
            "Checking the Codex/ChatGPT Remote connection and configuration…",
            "Codex/ChatGPT Remote 연결과 설정을 확인 중…"
        )
        client.inspect(workspacePath: settings.codexWorkspacePath) { [weak self, weak client] result in
            DispatchQueue.main.async {
                guard let self, self.probe === client, self.step == .codex else { return }
                switch result {
                case let .success(snapshot):
                    self.codexVerified = true
                    self.store.codexAppConnectionCompleted = true
                    self.statusLabel.stringValue =
                        self.localizedCopy.text(
                            "Codex/ChatGPT Remote connected",
                            "Codex/ChatGPT Remote 연결됨"
                        )
                        + " · \(snapshot.accountDescription)\n" +
                        snapshot.effectiveConfig.summary
                    self.statusLabel.textColor = .systemGreen
                    self.continueButton.isEnabled = true
                case let .failure(error):
                    self.codexVerified = false
                    self.statusLabel.stringValue = self.localizedCopy.text(
                        "The Codex/ChatGPT connection could not be verified. \(error.localizedDescription)",
                        "Codex/ChatGPT 연결을 확인하지 못했습니다. \(error.localizedDescription)"
                    )
                    self.statusLabel.textColor = .systemRed
                    self.continueButton.isEnabled = false
                }
            }
        }
    }

    private func connectCodexApp() {
        guard let pairingCode = ManualPairingCode.normalized(
            pairingCodeControl.stringValue
        ) else {
            statusLabel.stringValue = localizedCopy.text(
                "Use the code shown in ChatGPT, for example AA1A-1AA1.",
                "ChatGPT에 표시된 코드를 AA1A-1AA1 형식으로 입력하세요."
            )
            statusLabel.textColor = .systemRed
            return
        }
        pairingCodeControl.stringValue = pairingCode

        let client = makeProbe()
        statusLabel.stringValue = pairingCode.isEmpty
            ? localizedCopy.text(
                "Complete Voice Relay controller authorization in the browser…",
                "브라우저에서 Voice Relay 컨트롤러 인증을 완료하세요…"
            )
            : localizedCopy.text(
                "Pairing with the ChatGPT Remote…",
                "ChatGPT Remote와 연결 중…"
            )
        statusLabel.textColor = .secondaryLabelColor
        client.pair(pairingCode: pairingCode) { [weak self, weak client] result in
            DispatchQueue.main.async {
                guard let self, self.probe === client, self.step == .codex else { return }
                switch result {
                case let .success(connection) where connection.remoteRPCReady:
                    self.store.codexAppConnectionCompleted = true
                    self.codexVerified = false
                    self.pairingCodeControl.stringValue = ""
                    self.verifyCodex(force: true)
                case let .success(connection) where connection.hostClaimRequired:
                    self.codexVerified = false
                    self.statusLabel.stringValue =
                        self.localizedCopy.text(
                            "Controller authorization is ready. In ChatGPT, open Settings → Connections and choose Add, then paste the code shown there.",
                            "컨트롤러 인증이 준비되었습니다. ChatGPT에서 설정 → 연결을 열고 추가를 선택한 뒤 표시된 코드를 붙여넣으세요."
                        )
                    self.statusLabel.textColor = .systemOrange
                    self.continueButton.isEnabled = false
                case .success:
                    self.codexVerified = false
                    self.statusLabel.stringValue =
                        self.localizedCopy.text(
                            "Complete pairing in ChatGPT, then check the connection again.",
                            "ChatGPT에서 페어링을 완료한 뒤 연결 상태를 다시 확인하세요."
                        )
                    self.statusLabel.textColor = .systemOrange
                    self.continueButton.isEnabled = false
                case let .failure(error):
                    self.codexVerified = false
                    self.statusLabel.stringValue = self.localizedCopy.text(
                        "Pairing could not be completed. \(error.localizedDescription)",
                        "페어링을 완료하지 못했습니다. \(error.localizedDescription)"
                    )
                    self.statusLabel.textColor = .systemRed
                    self.continueButton.isEnabled = false
                }
            }
        }
    }

    private func verifyVoice(force: Bool = false) {
        guard force || !voiceVerified else { return }
        let client = makeProbe()
        statusLabel.stringValue = localizedCopy.text(
            "Checking ChatGPT OAuth Realtime…",
            "ChatGPT OAuth Realtime 확인 중…"
        )
        client.inspectRealtimeAvailability { [weak self, weak client] result in
            DispatchQueue.main.async {
                guard let self, self.probe === client, self.step == .voice else { return }
                switch result {
                case let .success(description):
                    self.voiceVerified = true
                    self.statusLabel.stringValue = description
                    self.statusLabel.textColor = .systemGreen
                    self.continueButton.isEnabled = true
                case let .failure(error):
                    self.voiceVerified = false
                    self.statusLabel.stringValue = error.localizedDescription
                    self.statusLabel.textColor = .systemRed
                    self.continueButton.isEnabled = false
                }
            }
        }
    }

    private func makeProbe() -> CodexAppRemoteClient {
        stopProbe()
        let client = CodexAppRemoteClient(
            workspacePath: settings.codexWorkspacePath
        )
        probe = client
        return client
    }

    private func captureSessionSelection() -> Bool {
        let raw = sessionIDControl.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            settings.codexThreadID = ""
            settings.codexThreadSource = ""
            settings.codexThreadTitle = "Voice Relay"
            statusLabel.stringValue = localizedCopy.text(
                "A new dedicated session will be created when voice starts.",
                "음성을 시작할 때 새 전용 session을 생성합니다."
            )
            statusLabel.textColor = .systemGreen
            return true
        }

        let normalized = SettingsStore.normalizedThreadID(raw)
        guard !normalized.isEmpty, UUID(uuidString: normalized) != nil else {
            statusLabel.stringValue = localizedCopy.text(
                "Use the Session ID copied from Codex. It should look like 00000000-0000-0000-0000-000000000000.",
                "Codex에서 복사한 Session ID를 사용하세요. 00000000-0000-0000-0000-000000000000 형식입니다."
            )
            statusLabel.textColor = .systemRed
            return false
        }
        settings.codexThreadID = normalized
        settings.codexThreadSource = "user"
        settings.codexThreadTitle = "Voice Relay"
        sessionIDControl.stringValue = normalized
        statusLabel.stringValue = localizedCopy.text(
            "Voice Relay will continue this dedicated session.",
            "이 전용 session을 이어서 사용합니다."
        )
        statusLabel.textColor = .systemGreen
        return true
    }

    private func finish() {
        settings.codexModel = "inherit"
        settings.codexReasoningEffort = "inherit"
        settings.codexSandbox = "inherit"
        settings.codexApprovalPolicy = "inherit"
        settings.speechLocale = "system"
        settings.voiceIdleTimeoutMinutes = 5
        settings.overlayAnchor = .automatic
        settings.returnGreetingEnabled = true
        settings.returnGreetingMinutes = 30
        do {
            try store.save(settings)
            store.completedFirstVoiceGreeting = false
            store.onboardingCompleted = true
            stopProbe()
            window?.orderOut(nil)
            onFinish?()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
    }

    private func permissionText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return localizedCopy.text("Allowed", "허용됨")
        case .denied:
            return localizedCopy.text("Denied", "거부됨")
        case .restricted:
            return localizedCopy.text("Restricted", "제한됨")
        case .notDetermined:
            return localizedCopy.text("Not requested", "요청 전")
        @unknown default:
            return localizedCopy.text("Unknown", "확인 불가")
        }
    }

    private func speechText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return localizedCopy.text("Allowed", "허용됨")
        case .denied:
            return localizedCopy.text("Denied", "거부됨")
        case .restricted:
            return localizedCopy.text("Restricted", "제한됨")
        case .notDetermined:
            return localizedCopy.text("Not requested", "요청 전")
        @unknown default:
            return localizedCopy.text("Unknown", "확인 불가")
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopProbe()
    }

    private func stopProbe() {
        probe?.shutdown()
        probe = nil
    }
}
