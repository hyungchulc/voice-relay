import AVFoundation
import ApplicationServices
import Cocoa
import Speech

private protocol SettingsAppearanceRefreshing: AnyObject {
    func refreshSettingsAppearance()
}

private func settingsAppearanceIsDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

private func settingsCanvasColor(_ appearance: NSAppearance) -> NSColor {
    settingsAppearanceIsDark(appearance)
        ? NSColor(calibratedWhite: 0.09, alpha: 1)
        : .white
}

private func settingsCardColor(_ appearance: NSAppearance) -> NSColor {
    settingsAppearanceIsDark(appearance)
        ? NSColor(calibratedWhite: 0.135, alpha: 1)
        : NSColor(calibratedWhite: 0.985, alpha: 1)
}

private final class SettingsCanvasView:
    NSView,
    SettingsAppearanceRefreshing
{
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshSettingsAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSettingsAppearance()
    }

    func refreshSettingsAppearance() {
        layer?.backgroundColor = settingsCanvasColor(effectiveAppearance).cgColor
    }
}

private final class FlippedSettingsDocumentView:
    NSView,
    SettingsAppearanceRefreshing
{
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshSettingsAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSettingsAppearance()
    }

    func refreshSettingsAppearance() {
        layer?.backgroundColor = settingsCanvasColor(effectiveAppearance).cgColor
    }
}

private final class SettingsScrollView:
    NSScrollView,
    SettingsAppearanceRefreshing
{
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSettingsAppearance()
    }

    func refreshSettingsAppearance() {
        let color = settingsCanvasColor(effectiveAppearance)
        drawsBackground = true
        backgroundColor = color
        contentView.drawsBackground = true
        contentView.backgroundColor = color
        needsDisplay = true
    }
}

private final class SettingsCardView:
    NSView,
    SettingsAppearanceRefreshing
{
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        refreshSettingsAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSettingsAppearance()
    }

    func refreshSettingsAppearance() {
        layer?.borderColor = (
            settingsAppearanceIsDark(effectiveAppearance)
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.12)
        ).cgColor
        layer?.backgroundColor = settingsCardColor(effectiveAppearance).cgColor
    }
}

final class SettingsWindowController:
    NSWindowController,
    NSWindowDelegate,
    NSToolbarDelegate
{
    private enum Pane: String, CaseIterable {
        case general
        case voice
        case connection
        case permissions
        case advanced

        var identifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("VoiceRelay.Settings.\(rawValue)")
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .voice: return "Voice"
            case .connection: return "Connection"
            case .permissions: return "Permissions"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .voice: return "waveform"
            case .connection: return "link"
            case .permissions: return "hand.raised"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private let store: SettingsStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let remoteClient: CodexAppRemoteClient
    private var probeGeneration = 0
    private var connectionRecoveryInFlight = false

    private let codexStatus = NSTextField(wrappingLabelWithString: "")
    private let voiceStatus = NSTextField(wrappingLabelWithString: "")
    private let connectionRecoveryStatus = NSTextField(wrappingLabelWithString: "")
    private let pairingCodeControl = NSTextField()
    private let taskStatus = NSTextField(labelWithString: "")
    private let threadIDControl = NSTextField()
    private let productNameControl = NSTextField()
    private let assistantNameControl = NSTextField()
    private let userDisplayNameControl = NSTextField()
    private let appLanguageControl = NSPopUpButton()
    private let appearanceControl = NSPopUpButton()
    private let surfaceControl = NSPopUpButton()
    private let wakeControl = NSButton(
        checkboxWithTitle: "로컬 웨이크워드 사용",
        target: nil,
        action: nil
    )
    private let wakePhrasesControl = NSTextField()
    private let modernSpeechAnalyzerControl = NSButton(
        checkboxWithTitle: "Use latest SpeechAnalyzer",
        target: nil,
        action: nil
    )
    private let localeControl = NSPopUpButton()
    private let additionalLocaleControls = [
        NSPopUpButton(),
        NSPopUpButton(),
        NSPopUpButton(),
    ]
    private let realtimeVoiceControl = NSPopUpButton()
    private let voiceIdleTimeoutControl = NSPopUpButton()
    private let realtimePromptStatus = NSTextField(labelWithString: "")
    private let microphonePermissionStatus = NSTextField(labelWithString: "")
    private let speechPermissionStatus = NSTextField(labelWithString: "")
    private let accessibilityPermissionStatus = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "Voice Relay")
    private var realtimePromptDraft = SettingsStore.defaultRealtimeInstructions
    private var promptEditor: RealtimePromptEditorController?
    private let returnControl = NSButton(
        checkboxWithTitle: "자리로 돌아오면 인사",
        target: nil,
        action: nil
    )
    private let returnMinutesControl = NSPopUpButton()
    private let historyControl = NSButton(
        checkboxWithTitle: "최근 대화 표시",
        target: nil,
        action: nil
    )
    private let authorityPackControl = NSButton(
        checkboxWithTitle: "Use Authority Pack",
        target: nil,
        action: nil
    )
    private let authorityPackRootControl = NSTextField()
    private let additionalContextProvidersControl = NSButton(
        checkboxWithTitle: "Use Additional Context Providers",
        target: nil,
        action: nil
    )
    private let additionalContextProvidersRootControl = NSTextField()
    private let launchAtLoginControl = NSButton(
        checkboxWithTitle: "로그인할 때 Voice Relay 열기",
        target: nil,
        action: nil
    )
    private let launchAtLoginStatus = NSTextField(labelWithString: "")
    private let launchAtLoginSettingsButton = NSButton()
    private let aboutVersionStatus = NSTextField(labelWithString: "")
    private let aboutChannelStatus = NSTextField(labelWithString: "")
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let checkForUpdatesButton = NSButton()
    private let saveButton = NSButton()
    private let resetButton = NSButton()
    private let quitButton = NSButton()
    private let tabView = NSTabView()
    private var selectedPane: Pane = .general
    private var localizedCopy: AppCopy
    private var builtLanguage: AppDisplayLanguage
    private var builtAppearanceMode: AppAppearanceMode
    private var displayedAppearanceMode: AppAppearanceMode

    var onSave: (() -> Void)?
    var onReset: (() -> Void)?
    var onConnectionRecoveryWillBegin: (() -> Void)?
    var onConnectionRecoveryDidEnd: (() -> Void)?

    init(
        remoteClient: CodexAppRemoteClient,
        store: SettingsStore = .shared,
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager()
    ) {
        self.remoteClient = remoteClient
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager
        let initialSettings = store.load()
        localizedCopy = AppCopy(preference: initialSettings.appDisplayLanguage)
        builtLanguage = localizedCopy.language
        builtAppearanceMode = AppAppearanceMode.parse(
            initialSettings.appearanceMode
        )
        displayedAppearanceMode = builtAppearanceMode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedCopy.text("Voice Relay Settings", "Voice Relay 설정")
        window.minSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        applyCanvasAppearance()
        buildModernUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        let settings = store.load()
        let nextCopy = AppCopy(preference: settings.appDisplayLanguage)
        let nextAppearanceMode = AppAppearanceMode.parse(
            settings.appearanceMode
        )
        displayedAppearanceMode = nextAppearanceMode
        if nextCopy.language != builtLanguage {
            rebuildModernUI(using: nextCopy)
        } else {
            localizedCopy = nextCopy
            builtAppearanceMode = nextAppearanceMode
        }
        loadValues()
        super.showWindow(sender)
        applyCanvasAppearance()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissions()
        refreshConnections()
        refreshLaunchAtLogin()
    }

    func shutdown() {
        stopProbe()
    }

    func shutdownSynchronously() {
        stopProbe()
    }

    private func rebuildModernUI(using nextCopy: AppCopy) {
        guard let window, let oldContent = window.contentView else { return }
        localizedCopy = nextCopy
        builtLanguage = nextCopy.language
        builtAppearanceMode = AppAppearanceMode.parse(
            store.load().appearanceMode
        )
        displayedAppearanceMode = builtAppearanceMode
        while tabView.numberOfTabViewItems > 0 {
            tabView.removeTabViewItem(tabView.tabViewItems[0])
        }
        surfaceControl.removeAllItems()
        appearanceControl.removeAllItems()
        returnMinutesControl.removeAllItems()
        realtimeVoiceControl.removeAllItems()
        voiceIdleTimeoutControl.removeAllItems()
        window.toolbar = nil
        window.contentView = NSView(frame: oldContent.frame)
        applyCanvasAppearance()
        buildModernUI()
    }

    private func buildModernUI() {
        guard let content = window?.contentView, let window else { return }

        let toolbar = NSToolbar(identifier: "VoiceRelay.Settings.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        let storedPane = UserDefaults.standard.string(
            forKey: "voiceRelay.settings.selectedPane"
        )
        selectedPane = Pane(rawValue: storedPane ?? "") ?? .general

        content.wantsLayer = true
        let background = SettingsCanvasView()
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        codexStatus.maximumNumberOfLines = 3
        codexStatus.stringValue = localizedCopy.text("Not checked", "확인 전")
        codexStatus.textColor = .secondaryLabelColor
        voiceStatus.maximumNumberOfLines = 2
        voiceStatus.stringValue = localizedCopy.text("Not checked", "확인 전")
        voiceStatus.textColor = .secondaryLabelColor
        connectionRecoveryStatus.maximumNumberOfLines = 3
        connectionRecoveryStatus.stringValue = ""
        connectionRecoveryStatus.textColor = .secondaryLabelColor
        pairingCodeControl.placeholderString = localizedCopy.text(
            "Example: AA1A-1AA1",
            "예시: AA1A-1AA1"
        )
        taskStatus.font = .systemFont(ofSize: 11.5)
        taskStatus.textColor = .secondaryLabelColor

        productNameControl.placeholderString = "Voice Relay"
        assistantNameControl.placeholderString = "Relay"
        userDisplayNameControl.placeholderString =
            localizedCopy.text("Me", "나")
        threadIDControl.placeholderString =
            "00000000-0000-0000-0000-000000000000"
        threadIDControl.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        wakePhrasesControl.placeholderString = "Relay, Hey Relay"
        wakePhrasesControl.toolTip = localizedCopy.text(
            "Add up to eight phrases separated by commas or line breaks.",
            "쉼표나 줄바꿈으로 최대 8개까지 추가할 수 있습니다."
        )
        wakeControl.title = localizedCopy.text(
            "Use local wake phrases",
            "로컬 웨이크워드를 사용합니다."
        )
        modernSpeechAnalyzerControl.title = localizedCopy.text(
            "Use latest SpeechAnalyzer",
            "최신 SpeechAnalyzer를 사용합니다."
        )
        if #available(macOS 26.0, *) {
            modernSpeechAnalyzerControl.isEnabled = true
            modernSpeechAnalyzerControl.toolTip = localizedCopy.text(
                "Uses the latest on-device recognizer when every selected language is ready, with automatic classic fallback.",
                "선택한 모든 언어가 준비되면 최신 온디바이스 인식기를 사용하고, 사용할 수 없으면 기존 인식기로 자동 전환합니다."
            )
        } else {
            modernSpeechAnalyzerControl.isEnabled = false
            modernSpeechAnalyzerControl.toolTip = localizedCopy.text(
                "Requires macOS 26 or later.",
                "macOS 26 이상이 필요합니다."
            )
        }
        returnControl.title = localizedCopy.text(
            "Greet me when I return",
            "자리로 돌아오면 인사합니다."
        )
        historyControl.title = localizedCopy.text(
            "Show recent conversations",
            "최근 대화를 표시합니다."
        )
        authorityPackControl.title = localizedCopy.text(
            "Use Authority Pack",
            "Authority Pack을 사용합니다."
        )
        authorityPackRootControl.placeholderString = localizedCopy.text(
            "Choose a folder containing the seven required files",
            "필수 파일 7개가 있는 폴더를 선택하세요."
        )
        authorityPackRootControl.font =
            .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        authorityPackRootControl.isEditable = true
        authorityPackRootControl.isSelectable = true
        additionalContextProvidersControl.title = localizedCopy.text(
            "Use Additional Context Providers",
            "Additional Context Providers를 사용합니다."
        )
        additionalContextProvidersRootControl.placeholderString =
            localizedCopy.text(
                "Choose a folder containing provider scripts",
                "provider 스크립트가 있는 폴더를 선택하세요."
            )
        additionalContextProvidersRootControl.font =
            .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        additionalContextProvidersRootControl.isEditable = true
        additionalContextProvidersRootControl.isSelectable = true
        realtimePromptStatus.font = .systemFont(ofSize: 11.5)
        realtimePromptStatus.textColor = .secondaryLabelColor

        populateLocales()
        populateRealtimeVoices()
        populateAppLanguages()
        populateAppearances()
        appearanceControl.target = self
        appearanceControl.action = #selector(previewAppearance(_:))
        surfaceControl.addItems(withTitles: ["Automatic", "Notch", "Orb"])
        for (index, value) in OverlayAnchor.allCases.enumerated() {
            surfaceControl.item(at: index)?.representedObject = value.rawValue
        }
        returnMinutesControl.addItems(withTitles: ["5", "15", "30", "60", "120", "180"])
        for value in [1, 3, 5, 10, 15, 30, 60] {
            voiceIdleTimeoutControl.addItem(
                withTitle: localizedCopy.text(
                    value == 1 ? "1 minute" : "\(value) minutes",
                    "\(value)분"
                )
            )
            voiceIdleTimeoutControl.lastItem?.representedObject = value
        }
        launchAtLoginControl.title = localizedCopy.text(
            "Open Voice Relay at login",
            "로그인할 때 Voice Relay 열기"
        )
        launchAtLoginControl.target = self
        launchAtLoginControl.action = #selector(toggleLaunchAtLogin)
        launchAtLoginStatus.font = .systemFont(ofSize: 11.5)
        launchAtLoginSettingsButton.title = localizedCopy.text(
            "Open Login Items…",
            "로그인 항목 열기…"
        )
        launchAtLoginSettingsButton.bezelStyle = .rounded
        launchAtLoginSettingsButton.target = self
        launchAtLoginSettingsButton.action =
            #selector(openLoginItemsSettings)

        let generalCard = card(
            icon: "sparkles",
            title: localizedCopy.text("Assistant & Surface", "어시스턴트 및 화면"),
            subtitle: localizedCopy.text(
                "Choose the assistant name and the surface that fits this Mac.",
                "어시스턴트 이름과 이 Mac에 맞는 표시 방식을 설정합니다."
            ),
            views: [
                settingsRow(
                    localizedCopy.text("Your display name", "내 표시 이름"),
                    userDisplayNameControl
                ),
                settingsRow(
                    localizedCopy.text("Assistant name", "어시스턴트 이름"),
                    assistantNameControl
                ),
                note(localizedCopy.text(
                    "This is the name the assistant uses when introducing itself.",
                    "Voice Relay가 자신을 소개할 때 사용하는 이름입니다."
                )),
                settingsRow(
                    localizedCopy.text("App language", "앱 언어"),
                    appLanguageControl
                ),
                settingsRow(
                    localizedCopy.text("Appearance", "화면 모드"),
                    appearanceControl
                ),
                divider(),
                settingsRow(localizedCopy.text("Surface", "표시 방식"), surfaceControl),
                note(localizedCopy.text(
                    "Automatic uses Notch on supported Macs and a floating Orb elsewhere.",
                    "자동은 하드웨어 노치가 있으면 Notch를, 없으면 떠 있는 Orb를 사용합니다."
                )),
                divider(),
                returnControl,
                settingsRow(localizedCopy.text("Return after", "복귀 기준"), returnMinutesControl),
                historyControl,
                divider(),
                launchAtLoginControl,
                rowStack([
                    launchAtLoginStatus,
                    NSView(),
                    launchAtLoginSettingsButton,
                ]),
                note(localizedCopy.text(
                    "This changes the macOS Login Items setting immediately.",
                    "macOS 로그인 항목 설정에 즉시 반영됩니다."
                )),
            ]
        )

        let voiceCard = card(
            icon: "waveform",
            title: localizedCopy.text("Voice", "음성"),
            subtitle: localizedCopy.text(
                "Manage languages, wake phrases, and Realtime conversation.",
                "언어, 웨이크워드와 Realtime 대화 방식을 관리합니다."
            ),
            views: [
                wakeControl,
                modernSpeechAnalyzerControl,
                note(localizedCopy.text(
                    "On macOS 26 or later, SpeechAnalyzer is used only when every selected language is available. Otherwise Voice Relay automatically uses classic on-device recognition.",
                    "macOS 26 이상에서 선택한 모든 언어를 사용할 수 있을 때만 SpeechAnalyzer를 사용합니다. 그 외에는 기존 온디바이스 인식기로 자동 전환합니다."
                )),
                fieldLabel(
                    localizedCopy.text("Wake phrases", "웨이크워드"),
                    detail: localizedCopy.text(
                        "Up to eight, separated by commas or line breaks",
                        "쉼표나 줄바꿈으로 최대 8개까지 설정할 수 있습니다."
                    )
                ),
                wakePhrasesControl,
                settingsRow(localizedCopy.text("Primary", "기본 언어"), localeControl),
                settingsRow(localizedCopy.text("Additional 1", "추가 언어 1"), additionalLocaleControls[0]),
                settingsRow(localizedCopy.text("Additional 2", "추가 언어 2"), additionalLocaleControls[1]),
                settingsRow(localizedCopy.text("Additional 3", "추가 언어 3"), additionalLocaleControls[2]),
                settingsRow(
                    localizedCopy.text("Realtime voice", "Realtime 보이스"),
                    realtimeVoiceControl
                ),
                note(localizedCopy.text(
                    "Marin and Cedar are recommended. A voice change applies when the next Realtime session starts.",
                    "Marin과 Cedar를 권장합니다. 보이스 변경은 다음 Realtime 세션을 시작할 때 적용됩니다."
                )),
                settingsRow(localizedCopy.text("Idle timeout", "무응답 전환"), voiceIdleTimeoutControl),
                note(localizedCopy.text(
                    "After this period of silence, Realtime closes and wake phrase listening resumes.",
                    "설정한 시간 동안 말이 없으면 Realtime을 종료하고 웨이크워드 대기로 돌아갑니다."
                )),
                divider(),
                fieldLabel(
                    localizedCopy.text("Realtime prompt", "Realtime 프롬프트"),
                    detail: localizedCopy.text(
                        "Configure greetings, tone, and Codex handoff guidance.",
                        "첫 인사, 말투와 Codex 전달 안내를 설정합니다."
                    )
                ),
                rowStack([
                    realtimePromptStatus,
                    NSView(),
                    button(localizedCopy.text("Edit…", "편집…"), #selector(editRealtimePrompt)),
                ]),
            ]
        )

        let connectionCard = card(
            icon: "link",
            title: localizedCopy.text("Connection", "연결"),
            subtitle: localizedCopy.text(
                "Realtime connects directly. Only complex requests are handed to Codex Remote.",
                "Realtime은 직접 연결하고 복잡한 요청만 Codex Remote로 전달합니다."
            ),
            views: [
                settingsRow(
                    "Codex",
                    codexStatus,
                    button(localizedCopy.text("Check again", "다시 확인"), #selector(refreshConnections))
                ),
                settingsRow("Realtime", voiceStatus),
                divider(),
                fieldLabel(
                    "Session ID",
                    detail: localizedCopy.text(
                        "Optional. Leave empty to create a new dedicated session when voice starts.",
                        "선택 사항입니다. 비워 두면 음성을 시작할 때 새 전용 session을 생성합니다."
                    )
                ),
                threadIDControl,
                rowStack([
                    taskStatus,
                    NSView(),
                    button(localizedCopy.text("New session", "새로 생성"), #selector(clearTaskField)),
                ]),
                divider(),
                fieldLabel(
                    localizedCopy.text("Connection recovery", "연결 복구"),
                    detail: localizedCopy.text(
                        "Recover Codex Remote without resetting onboarding or other app settings.",
                        "온보딩이나 다른 앱 설정을 지우지 않고 Codex Remote만 복구합니다."
                    )
                ),
                rowStack([
                    button(
                        localizedCopy.text("Reconnect", "다시 연결"),
                        #selector(restartCodexConnection)
                    ),
                    button(
                        localizedCopy.text("Reset local pairing…", "로컬 페어링 재설정…"),
                        #selector(confirmResetLocalPairing)
                    ),
                    button(
                        localizedCopy.text("Open ChatGPT", "ChatGPT 열기"),
                        #selector(openChatGPTConnections)
                    ),
                    NSView(),
                ]),
                settingsRow(
                    localizedCopy.text("Pairing code", "페어링 코드"),
                    pairingCodeControl,
                    button(
                        localizedCopy.text("Pair", "연결"),
                        #selector(pairCodexConnection)
                    )
                ),
                note(localizedCopy.text(
                    "Use an 8-character code from ChatGPT only when the host asks for it. Server-side Revoke access remains in ChatGPT Settings → Connections → Control this Mac.",
                    "호스트가 요구할 때만 ChatGPT의 8자리 코드를 입력합니다. 서버 권한 해제는 ChatGPT 설정 → Connections → Control this Mac의 Revoke access에서 합니다."
                )),
                connectionRecoveryStatus,
            ]
        )

        let permissionsCard = card(
            icon: "hand.raised",
            title: localizedCopy.text("App Permissions", "앱 권한"),
            subtitle: localizedCopy.text(
                "Review voice permissions and open the corresponding System Settings page.",
                "음성 권한을 확인하고 필요한 시스템 설정으로 바로 이동합니다."
            ),
            views: [
                settingsRow(
                    localizedCopy.text("Microphone", "마이크"),
                    microphonePermissionStatus,
                    button(localizedCopy.text("Open", "열기"), #selector(openMicrophonePrivacy))
                ),
                settingsRow(
                    localizedCopy.text("Speech Recognition", "음성 인식"),
                    speechPermissionStatus,
                    button(localizedCopy.text("Open", "열기"), #selector(openSpeechPrivacy))
                ),
                settingsRow(
                    localizedCopy.text("Accessibility", "접근성"),
                    accessibilityPermissionStatus,
                    button(localizedCopy.text("Open", "열기"), #selector(openAccessibilityPrivacy))
                ),
                note(localizedCopy.text(
                    "Accessibility is optional and is not required for Realtime voice.",
                    "접근성은 선택 권한이며 기본 Realtime 음성에는 필요하지 않습니다."
                )),
            ]
        )

        resetButton.title = localizedCopy.text("Reset Voice Relay…", "Voice Relay 초기화…")
        resetButton.bezelStyle = .rounded
        resetButton.contentTintColor = .systemRed
        resetButton.target = self
        resetButton.action = #selector(resetApp)
        quitButton.title = localizedCopy.text("Quit Voice Relay", "Voice Relay 종료")
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        aboutVersionStatus.font =
            .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        aboutChannelStatus.textColor = .secondaryLabelColor
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.maximumNumberOfLines = 2
        checkForUpdatesButton.title = localizedCopy.text(
            "Check for Updates",
            "업데이트 확인"
        )
        checkForUpdatesButton.bezelStyle = .rounded
        checkForUpdatesButton.target = self
        checkForUpdatesButton.action = #selector(checkForUpdates)

        let aboutCard = card(
            icon: "info.circle",
            title: localizedCopy.text(
                "About Voice Relay",
                "Voice Relay 정보"
            ),
            subtitle: localizedCopy.text(
                "See the installed release and securely download verified GitHub prerelease updates.",
                "설치된 릴리스를 확인하고 검증된 GitHub prerelease 업데이트를 안전하게 설치합니다."
            ),
            views: [
                settingsRow(
                    localizedCopy.text("Version", "버전"),
                    aboutVersionStatus
                ),
                settingsRow(
                    localizedCopy.text("Channel", "채널"),
                    aboutChannelStatus
                ),
                updateStatus,
                rowStack([
                    checkForUpdatesButton,
                    NSView(),
                ]),
            ]
        )

        let advancedCard = card(
            icon: "gearshape.2",
            title: localizedCopy.text("App Management", "앱 관리"),
            subtitle: localizedCopy.text(
                "Add optional guidance and context providers or manage Voice Relay.",
                "선택형 지침과 context provider를 연결하거나 Voice Relay를 관리합니다."
            ),
            views: [
                fieldLabel(
                    "Authority Pack",
                    detail: localizedCopy.text(
                        "Optional user-authored guidance sent with Codex requests.",
                        "Codex 요청과 함께 전송되는 선택형 사용자 지침입니다."
                    )
                ),
                authorityPackControl,
                settingsRow(
                    localizedCopy.text("Folder", "폴더"),
                    authorityPackRootControl,
                    button(
                        localizedCopy.text("Browse…", "선택…"),
                        #selector(chooseAuthorityPackFolder)
                    )
                ),
                note(localizedCopy.text(
                    "The folder must contain AGENTS.md, SOUL.md, USER.md, SOURCE_RULES.md, TOOLS.md, IDENTITY.md, and WORKFLOW_AUTO.md. Voice Relay never ships or uploads a selected folder path.",
                    "폴더에는 AGENTS.md, SOUL.md, USER.md, SOURCE_RULES.md, TOOLS.md, IDENTITY.md, WORKFLOW_AUTO.md가 있어야 합니다. 선택한 폴더 경로는 앱이나 공개 저장소에 포함되지 않습니다."
                )),
                divider(),
                fieldLabel(
                    "Additional Context Providers",
                    detail: localizedCopy.text(
                        "Optional local scripts that produce fresh grounding context for each Codex request.",
                        "각 Codex 요청에 최신 grounding context를 만드는 선택형 로컬 스크립트입니다."
                    )
                ),
                additionalContextProvidersControl,
                settingsRow(
                    localizedCopy.text("Folder", "폴더"),
                    additionalContextProvidersRootControl,
                    button(
                        localizedCopy.text("Browse…", "선택…"),
                        #selector(chooseAdditionalContextProvidersFolder)
                    )
                ),
                note(localizedCopy.text(
                    "Voice Relay runs up to eight executable files in filename order. Each receives the current request on standard input and returns bounded UTF-8 text or JSON. Provider files, paths, and output are never bundled in the public app or DMG.",
                    "Voice Relay는 파일명 순서로 최대 8개의 실행 파일을 호출합니다. 각 provider는 현재 요청을 표준 입력으로 받고 제한된 UTF-8 텍스트 또는 JSON을 반환합니다. provider 파일, 경로와 출력은 공개 앱이나 DMG에 포함되지 않습니다."
                )),
                divider(),
                rowStack([resetButton, quitButton, NSView()]),
            ]
        )

        let advancedPage = NSStackView(views: [aboutCard, advancedCard])
        advancedPage.orientation = .vertical
        advancedPage.alignment = .leading
        advancedPage.spacing = 16
        aboutCard.widthAnchor.constraint(equalTo: advancedPage.widthAnchor).isActive = true
        advancedCard.widthAnchor.constraint(equalTo: advancedPage.widthAnchor).isActive = true

        let pages: [(Pane, String, String, NSView)] = [
            (
                .general,
                localizedCopy.text("General", "일반"),
                localizedCopy.text(
                    "Choose the assistant name and how Voice Relay appears.",
                    "어시스턴트 이름과 Voice Relay의 표시 방식을 설정합니다."
                ),
                generalCard
            ),
            (
                .voice,
                localizedCopy.text("Voice", "음성"),
                localizedCopy.text(
                    "Listen naturally and hand off only when more work is needed.",
                    "자연스럽게 듣고 더 큰 작업이 필요할 때만 전달합니다."
                ),
                voiceCard
            ),
            (
                .connection,
                localizedCopy.text("Connection", "연결"),
                localizedCopy.text(
                    "Review Realtime and Codex connection status.",
                    "Realtime과 Codex 연결 상태를 한곳에서 확인합니다."
                ),
                connectionCard
            ),
            (
                .permissions,
                localizedCopy.text("Permissions", "권한"),
                localizedCopy.text(
                    "Review the permissions Voice Relay can use on this Mac.",
                    "이 Mac에서 Voice Relay가 사용할 수 있는 권한을 확인합니다."
                ),
                permissionsCard
            ),
            (
                .advanced,
                localizedCopy.text("Advanced", "고급"),
                localizedCopy.text(
                    "Manage the local app lifecycle.",
                    "로컬 앱의 상태를 관리합니다."
                ),
                advancedPage
            ),
        ]

        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for (pane, title, subtitle, section) in pages {
            let item = NSTabViewItem(identifier: pane.rawValue)
            item.view = settingsPage(title: title, subtitle: subtitle, section: section)
            tabView.addTabViewItem(item)
        }
        background.addSubview(tabView)

        let cancelButton = button(localizedCopy.text("Cancel", "취소"), #selector(cancel))
        saveButton.title = localizedCopy.text("Save", "저장")
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let footer = rowStack([NSView(), cancelButton, saveButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: background.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
        ])

        selectPane(selectedPane)
    }

    private func settingsPage(
        title: String,
        subtitle: String,
        section: NSView
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitleLabel = note(subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13.5)
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel, subtitleLabel, section])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = SettingsScrollView()
        scroll.refreshSettingsAppearance()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(
                greaterThanOrEqualTo: scroll.contentView.heightAnchor
            ),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: document.bottomAnchor,
                constant: -30
            ),
            section.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return scroll
    }

    private func selectPane(_ pane: Pane) {
        selectedPane = pane
        tabView.selectTabViewItem(withIdentifier: pane.rawValue)
        (tabView.selectedTabViewItem?.view as? NSScrollView)?
            .contentView.scroll(to: .zero)
        window?.toolbar?.selectedItemIdentifier = pane.identifier
        let productName = store.load().productName
        window?.title = "\(productName) — \(paneTitle(pane))"
        UserDefaults.standard.set(
            pane.rawValue,
            forKey: "voiceRelay.settings.selectedPane"
        )
    }

    private func paneTitle(_ pane: Pane) -> String {
        switch pane {
        case .general:
            return localizedCopy.text("General", "일반")
        case .voice:
            return localizedCopy.text("Voice", "음성")
        case .connection:
            return localizedCopy.text("Connection", "연결")
        case .permissions:
            return localizedCopy.text("Permissions", "권한")
        case .advanced:
            return localizedCopy.text("Advanced", "고급")
        }
    }

    private func applyCanvasAppearance() {
        guard let window, let content = window.contentView else { return }
        switch displayedAppearanceMode {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
        let color = resolvedCanvasColor()
        window.backgroundColor = color
        content.wantsLayer = true
        content.layer?.backgroundColor = color.cgColor
        refreshAppearanceSurfaces(in: content)
        content.needsDisplay = true
    }

    private func resolvedAppearanceIsDark() -> Bool {
        let systemIsDark = (
            window?.effectiveAppearance ?? NSApp.effectiveAppearance
        ).bestMatch(from: [.darkAqua, .aqua])
                == .darkAqua
        return displayedAppearanceMode.resolvesDark(systemIsDark: systemIsDark)
    }

    private func resolvedCanvasColor() -> NSColor {
        settingsCanvasColor(
            window?.effectiveAppearance ?? NSApp.effectiveAppearance
        )
    }

    private func resolvedCardColor() -> NSColor {
        settingsCardColor(
            window?.effectiveAppearance ?? NSApp.effectiveAppearance
        )
    }

    private func refreshAppearanceSurfaces(in view: NSView) {
        (view as? SettingsAppearanceRefreshing)?.refreshSettingsAppearance()
        for subview in view.subviews {
            refreshAppearanceSurfaces(in: subview)
        }
    }

    @objc private func previewAppearance(_ sender: NSPopUpButton) {
        displayedAppearanceMode = AppAppearanceMode.parse(
            sender.selectedItem?.representedObject as? String
        )
        applyCanvasAppearance()
    }

    @objc private func selectToolbarPane(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: {
            $0.identifier == sender.itemIdentifier
        }) else {
            return
        }
        selectPane(pane)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: {
            $0.identifier == itemIdentifier
        }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = paneTitle(pane)
        item.paletteLabel = paneTitle(pane)
        item.image = NSImage(
            systemSymbolName: pane.symbol,
            accessibilityDescription: paneTitle(pane)
        )
        item.target = self
        item.action = #selector(selectToolbarPane(_:))
        return item
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        let mark = NSImageView()
        mark.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Voice Relay"
        )
        mark.symbolConfiguration = .init(pointSize: 23, weight: .semibold)
        mark.contentTintColor = .controlAccentColor

        headingLabel.font = .systemFont(ofSize: 27, weight: .bold)

        let subtitle = note(
            "Voice와 Codex 앱 연결을 관리해. 모델, thinking, 파일 권한과 승인은 현재 Codex config를 그대로 따라가."
        )
        subtitle.maximumNumberOfLines = 2

        let headingText = NSStackView(views: [headingLabel, subtitle])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 3

        let header = NSStackView(views: [mark, headingText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 15
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)

        codexStatus.maximumNumberOfLines = 3
        codexStatus.textColor = .secondaryLabelColor
        voiceStatus.maximumNumberOfLines = 2
        voiceStatus.textColor = .secondaryLabelColor
        taskStatus.font = .systemFont(ofSize: 11.5)
        taskStatus.textColor = .secondaryLabelColor

        threadIDControl.placeholderString =
            "00000000-0000-0000-0000-000000000000"
        threadIDControl.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        threadIDControl.isEditable = true
        threadIDControl.isSelectable = true
        productNameControl.placeholderString = "Voice Relay"
        assistantNameControl.placeholderString = "Relay"
        userDisplayNameControl.placeholderString = "나"

        let connectionCard = card(
            icon: "link",
            title: "Connection",
            subtitle: "Codex/ChatGPT 앱과 Voice 상태",
            views: [
                settingsRow("앱 이름", productNameControl),
                settingsRow("내 표시 이름", userDisplayNameControl),
                settingsRow("어시스턴트 이름", assistantNameControl),
                note("배포 이름과 Voice가 자신을 소개할 이름을 각각 변경할 수 있습니다."),
                divider(),
                settingsRow(
                    "Codex",
                    codexStatus,
                    button("다시 확인", #selector(refreshConnections))
                ),
                settingsRow("Voice", voiceStatus),
                divider(),
                fieldLabel("Session ID", detail: "선택 사항이며 비워 두면 새 전용 session을 생성합니다."),
                threadIDControl,
                rowStack([
                    taskStatus,
                    NSView(),
                    button("새로 생성", #selector(clearTaskField)),
                ]),
            ]
        )

        populateLocales()
        wakePhrasesControl.placeholderString = "Relay, Hey Relay"
        wakePhrasesControl.toolTip = "쉼표나 줄바꿈으로 최대 8개까지 추가할 수 있습니다."
        realtimePromptStatus.font = .systemFont(ofSize: 11.5)
        realtimePromptStatus.textColor = .secondaryLabelColor
        let voiceCard = card(
            icon: "waveform",
            title: "Voice",
            subtitle: "웨이크워드, 인식 언어와 Realtime 응답",
            views: [
                wakeControl,
                fieldLabel(
                    "웨이크워드",
                    detail: "쉼표나 줄바꿈으로 최대 8개까지 설정해."
                ),
                wakePhrasesControl,
                settingsRow("주 언어", localeControl),
                settingsRow("추가 언어 1", additionalLocaleControls[0]),
                settingsRow("추가 언어 2", additionalLocaleControls[1]),
                settingsRow("추가 언어 3", additionalLocaleControls[2]),
                settingsRow("Realtime 보이스", realtimeVoiceControl),
                note("Marin과 Cedar를 권장합니다. 변경한 보이스는 다음 Realtime 세션부터 적용됩니다."),
                note("시스템 언어와 최대 3개 추가 언어를 함께 인식해. 로컬 웨이크워드는 이 Mac이 on-device 인식을 지원하는 언어만 사용해."),
                divider(),
                fieldLabel(
                    "Realtime prompt",
                    detail: "말투와 진행 안내를 변경할 수 있습니다. 안전한 라우팅 경계는 변경되지 않습니다."
                ),
                rowStack([
                    realtimePromptStatus,
                    NSView(),
                    button("편집…", #selector(editRealtimePrompt)),
                ]),
                historyControl,
            ]
        )

        returnMinutesControl.addItems(withTitles: ["5", "15", "30", "60", "120", "180"])
        let presenceCard = card(
            icon: "figure.walk.arrival",
            title: "Presence",
            subtitle: "카메라 없이 입력 복귀만 감지해.",
            views: [
                returnControl,
                settingsRow("자리 비운 시간", returnMinutesControl),
            ]
        )

        let permissionsCard = card(
            icon: "hand.raised",
            title: "Permissions",
            subtitle: "Voice 권한 상태를 확인하고 macOS 설정으로 바로 이동해.",
            views: [
                settingsRow(
                    "마이크",
                    microphonePermissionStatus,
                    button("열기", #selector(openMicrophonePrivacy))
                ),
                settingsRow(
                    "음성 인식",
                    speechPermissionStatus,
                    button("열기", #selector(openSpeechPrivacy))
                ),
                settingsRow(
                    "접근성",
                    accessibilityPermissionStatus,
                    button("열기", #selector(openAccessibilityPrivacy))
                ),
                note("접근성은 보조 기능용 선택 권한입니다. 기본 Voice 연결에는 필요하지 않습니다."),
            ]
        )

        let leftColumn = NSStackView(views: [connectionCard, voiceCard])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 14

        let rightColumn = NSStackView(views: [
            presenceCard,
            permissionsCard,
        ])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 14

        let columns = NSStackView(views: [leftColumn, rightColumn])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 14
        columns.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(columns)

        resetButton.title = "Reset Voice Relay…"
        resetButton.bezelStyle = .rounded
        resetButton.contentTintColor = .systemRed
        resetButton.target = self
        resetButton.action = #selector(resetApp)

        quitButton.title = "Quit Voice Relay"
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        let cancelButton = button("취소", #selector(cancel))
        saveButton.title = "저장"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)

        let footer = rowStack([
            resetButton,
            quitButton,
            NSView(),
            cancelButton,
            saveButton,
        ])
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            mark.widthAnchor.constraint(equalToConstant: 44),
            mark.heightAnchor.constraint(equalToConstant: 44),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 24),

            columns.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            columns.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -18),
            leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),

            connectionCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            voiceCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            presenceCard.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            permissionsCard.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),

            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
        ])
    }

    private func loadValues() {
        let settings = store.load()
        localizedCopy = AppCopy(preference: settings.appDisplayLanguage)
        window?.title = localizedCopy.text(
            "\(settings.productName) Settings",
            "\(settings.productName) 설정"
        )
        headingLabel.stringValue = settings.productName
        resetButton.title = localizedCopy.text(
            "Reset \(settings.productName)…",
            "\(settings.productName) 초기화…"
        )
        quitButton.title = localizedCopy.text(
            "Quit \(settings.productName)",
            "\(settings.productName) 종료"
        )
        threadIDControl.placeholderString =
            "00000000-0000-0000-0000-000000000000"
        productNameControl.stringValue = settings.productName
        assistantNameControl.stringValue = settings.assistantName
        userDisplayNameControl.stringValue = settings.userDisplayName
        selectAppLanguage(settings.appDisplayLanguage)
        selectAppearance(settings.appearanceMode)
        for item in surfaceControl.itemArray
        where item.representedObject as? String == settings.overlayAnchor.rawValue {
            surfaceControl.select(item)
        }
        wakeControl.state = settings.wakePhraseEnabled ? .on : .off
        modernSpeechAnalyzerControl.state =
            settings.preferModernSpeechAnalyzer ? .on : .off
        wakePhrasesControl.stringValue = settings.wakePhrases.joined(separator: ", ")
        selectLocale(localeControl, identifier: settings.speechLocale)
        for (index, control) in additionalLocaleControls.enumerated() {
            let identifier = settings.additionalSpeechLocales.indices.contains(index)
                ? settings.additionalSpeechLocales[index]
                : ""
            selectLocale(control, identifier: identifier)
        }
        selectRealtimeVoice(settings.realtimeVoice)
        for item in voiceIdleTimeoutControl.itemArray
        where item.representedObject as? Int == settings.voiceIdleTimeoutMinutes {
            voiceIdleTimeoutControl.select(item)
        }
        realtimePromptDraft = settings.realtimeInstructions
        updateRealtimePromptStatus()
        returnControl.state = settings.returnGreetingEnabled ? .on : .off
        returnMinutesControl.selectItem(withTitle: String(settings.returnGreetingMinutes))
        historyControl.state = settings.showRecentHistory ? .on : .off
        authorityPackControl.state =
            settings.includeAuthorityPack ? .on : .off
        authorityPackRootControl.stringValue = settings.authorityPackRoot
        additionalContextProvidersControl.state =
            settings.includeAdditionalContextProviders ? .on : .off
        additionalContextProvidersRootControl.stringValue =
            settings.additionalContextProvidersRoot
        refreshLaunchAtLogin()
        threadIDControl.stringValue = settings.codexThreadID
        taskStatus.stringValue = settings.codexThreadID.isEmpty
            ? localizedCopy.text(
                "A new dedicated session will be created when voice starts.",
                "음성을 시작할 때 새 전용 session을 생성합니다."
            )
            : localizedCopy.text(
                "This dedicated session is connected.",
                "현재 전용 session에 연결되어 있습니다."
            )
        refreshAboutStatus()
    }

    @objc private func refreshPermissions() {
        applyPermissionStatus(
            microphonePermissionStatus,
            status: permissionStatus(
                AVCaptureDevice.authorizationStatus(for: .audio)
            )
        )
        applyPermissionStatus(
            speechPermissionStatus,
            status: permissionStatus(SFSpeechRecognizer.authorizationStatus())
        )
        applyPermissionStatus(
            accessibilityPermissionStatus,
            status: AXIsProcessTrusted()
                ? (localizedCopy.text("Allowed", "허용됨"), true)
                : (localizedCopy.text("Not allowed", "허용되지 않음"), false)
        )
    }

    private func refreshAboutStatus() {
        let identity = VoiceRelayReleaseIdentity()
        aboutVersionStatus.stringValue =
            "\(identity.displayVersion) (Build \(identity.build))"
        aboutChannelStatus.stringValue =
            identity.channel == "prerelease"
                ? localizedCopy.text(
                    "Public Alpha · Prerelease",
                    "Public Alpha · Prerelease"
                )
                : localizedCopy.text(
                    "Development build",
                    "개발 빌드"
                )
        checkForUpdatesButton.isEnabled = identity.canCheckForUpdates
        updateStatus.stringValue = identity.canCheckForUpdates
            ? localizedCopy.text(
                "Sparkle securely downloads, verifies, installs, and relaunches updates after you choose the button.",
                "버튼을 누르면 Sparkle이 업데이트를 안전하게 다운로드하고 검증한 뒤 설치하고 다시 실행합니다."
            )
            : localizedCopy.text(
                "Update checking is unavailable because this build has no release tag.",
                "이 빌드에는 릴리스 태그가 없어 업데이트를 확인할 수 없습니다."
            )
    }

    @objc private func checkForUpdates() {
        let identity = VoiceRelayReleaseIdentity()
        guard identity.canCheckForUpdates else {
            refreshAboutStatus()
            return
        }
        VoiceRelayUpdateController.shared.checkForUpdates(
            checkForUpdatesButton
        )
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginControl.state == .on
        do {
            _ = try launchAtLoginManager.setEnabled(shouldEnable)
        } catch {
            refreshLaunchAtLogin()
            present(error)
            return
        }
        refreshLaunchAtLogin()
    }

    @objc private func openLoginItemsSettings() {
        launchAtLoginManager.openLoginItemsSettings()
    }

    private func refreshLaunchAtLogin() {
        switch launchAtLoginManager.status {
        case .enabled:
            launchAtLoginControl.state = .on
            launchAtLoginControl.isEnabled = true
            launchAtLoginStatus.stringValue =
                localizedCopy.text("Enabled", "켜짐")
            launchAtLoginStatus.textColor = .systemGreen
            launchAtLoginSettingsButton.isHidden = true
        case .requiresApproval:
            launchAtLoginControl.state = .on
            launchAtLoginControl.isEnabled = true
            launchAtLoginStatus.stringValue = localizedCopy.text(
                "Approval required in System Settings",
                "시스템 설정에서 승인이 필요합니다."
            )
            launchAtLoginStatus.textColor = .systemOrange
            launchAtLoginSettingsButton.isHidden = false
        case .notRegistered:
            launchAtLoginControl.state = .off
            launchAtLoginControl.isEnabled = true
            launchAtLoginStatus.stringValue =
                localizedCopy.text("Off", "꺼짐")
            launchAtLoginStatus.textColor = .secondaryLabelColor
            launchAtLoginSettingsButton.isHidden = true
        case .notFound:
            launchAtLoginControl.state = .off
            launchAtLoginControl.isEnabled = true
            launchAtLoginStatus.stringValue = localizedCopy.text(
                "Not registered yet. Turn it on to create the login item.",
                "아직 등록되지 않았습니다. 켜서 로그인 항목을 만드세요."
            )
            launchAtLoginStatus.textColor = .secondaryLabelColor
            launchAtLoginSettingsButton.isHidden = true
        }
    }

    private func applyPermissionStatus(
        _ label: NSTextField,
        status: (text: String, allowed: Bool?)
    ) {
        label.stringValue = status.text
        switch status.allowed {
        case true:
            label.textColor = .systemGreen
        case false:
            label.textColor = .systemOrange
        case nil:
            label.textColor = .secondaryLabelColor
        }
    }

    private func permissionStatus(
        _ status: AVAuthorizationStatus
    ) -> (text: String, allowed: Bool?) {
        switch status {
        case .authorized:
            return (localizedCopy.text("Allowed", "허용됨"), true)
        case .denied:
            return (localizedCopy.text("Denied", "거부됨"), false)
        case .restricted:
            return (localizedCopy.text("Restricted", "제한됨"), false)
        case .notDetermined:
            return (localizedCopy.text("Not requested", "요청 전"), nil)
        @unknown default:
            return (localizedCopy.text("Unknown", "알 수 없음"), nil)
        }
    }

    private func permissionStatus(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> (text: String, allowed: Bool?) {
        switch status {
        case .authorized:
            return (localizedCopy.text("Allowed", "허용됨"), true)
        case .denied:
            return (localizedCopy.text("Denied", "거부됨"), false)
        case .restricted:
            return (localizedCopy.text("Restricted", "제한됨"), false)
        case .notDetermined:
            return (localizedCopy.text("Not requested", "요청 전"), nil)
        @unknown default:
            return (localizedCopy.text("Unknown", "알 수 없음"), nil)
        }
    }

    @objc private func openMicrophonePrivacy() {
        openPrivacyPane("Privacy_Microphone")
    }

    @objc private func openSpeechPrivacy() {
        openPrivacyPane("Privacy_SpeechRecognition")
    }

    @objc private func openAccessibilityPrivacy() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @objc private func refreshConnections() {
        let settings = store.load()
        codexStatus.stringValue = localizedCopy.text("Checking…", "확인 중…")
        codexStatus.textColor = .secondaryLabelColor
        voiceStatus.stringValue = localizedCopy.text("Checking…", "확인 중…")
        voiceStatus.textColor = .secondaryLabelColor
        let generation = beginProbe()
        remoteClient.inspect(workspacePath: settings.codexWorkspacePath) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.probeGeneration == generation else { return }
                switch result {
                case let .success(snapshot):
                    self.codexStatus.stringValue =
                        self.localizedCopy.text("Connected", "연결됨")
                        + " · \(snapshot.accountDescription)\n" +
                        snapshot.effectiveConfig.summary
                    self.codexStatus.textColor = .systemGreen
                case let .failure(error):
                    self.codexStatus.stringValue = error.localizedDescription
                    self.codexStatus.textColor = .systemRed
                }
            }
        }
        remoteClient.inspectRealtimeAvailability { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.probeGeneration == generation else { return }
                switch result {
                case let .success(description):
                    self.voiceStatus.stringValue = description
                    self.voiceStatus.textColor = .systemGreen
                case let .failure(error):
                    self.voiceStatus.stringValue = error.localizedDescription
                    self.voiceStatus.textColor = .systemRed
                }
            }
        }
    }

    @objc private func restartCodexConnection() {
        performConnectionRecovery(resetLocalPairing: false)
    }

    @objc private func confirmResetLocalPairing() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = localizedCopy.text(
            "Reset local Codex pairing?",
            "로컬 Codex 페어링을 재설정할까?"
        )
        alert.informativeText = localizedCopy.text(
            "This removes only Voice Relay's local enrollment and secure device key. It does not revoke the server-side device entry or reset onboarding and preferences.",
            "Voice Relay의 로컬 등록 상태와 보안 기기 키만 지웁니다. 서버의 기기 권한, 온보딩과 다른 설정은 그대로 유지됩니다."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedCopy.text("Reset pairing", "페어링 재설정"))
        alert.addButton(withTitle: localizedCopy.text("Cancel", "취소"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performConnectionRecovery(resetLocalPairing: true)
        }
    }

    private func performConnectionRecovery(resetLocalPairing: Bool) {
        stopProbe()
        beginConnectionRecovery()
        connectionRecoveryStatus.stringValue = localizedCopy.text(
            "Recovering Codex Remote…",
            "Codex Remote 복구 중…"
        )
        connectionRecoveryStatus.textColor = .secondaryLabelColor
        let generation = beginProbe()
        let completion: (Result<CodexConnectionResetResult, Error>) -> Void = {
            [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.probeGeneration == generation else { return }
                self.stopProbe()
                self.finishConnectionRecovery()
                switch result {
                case let .success(outcome):
                    self.connectionRecoveryStatus.stringValue =
                        resetLocalPairing
                        ? self.localizedCopy.text(
                            "Local pairing cleared. Use Pair when you are ready. Revoke access in ChatGPT if the server entry must also be removed.",
                            "로컬 페어링을 지웠어. 준비되면 연결을 눌러. 서버 권한도 지우려면 ChatGPT에서 Revoke access를 사용해."
                        )
                        : self.localizedCopy.text(
                            "Session transport reset. Local pairing and settings were preserved.",
                            "세션 연결을 재설정했어. 로컬 페어링과 설정은 유지했어."
                        )
                    self.connectionRecoveryStatus.textColor =
                        outcome.localStateCleared ? .systemGreen : .systemOrange
                    self.refreshConnections()
                case let .failure(error):
                    self.connectionRecoveryStatus.stringValue = error.localizedDescription
                    self.connectionRecoveryStatus.textColor = .systemRed
                }
            }
        }
        if resetLocalPairing {
            remoteClient.forgetLocalPairing(completion: completion)
        } else {
            remoteClient.resetSession(completion: completion)
        }
    }

    @objc private func pairCodexConnection() {
        guard let code = ManualPairingCode.normalized(
            pairingCodeControl.stringValue
        ) else {
            connectionRecoveryStatus.stringValue = localizedCopy.text(
                "Use the code shown in ChatGPT, for example AA1A-1AA1.",
                "ChatGPT에 표시된 코드를 AA1A-1AA1 형식으로 입력하세요."
            )
            connectionRecoveryStatus.textColor = .systemRed
            return
        }
        pairingCodeControl.stringValue = code
        stopProbe()
        beginConnectionRecovery()
        connectionRecoveryStatus.stringValue = localizedCopy.text(
            "Pairing with ChatGPT…",
            "ChatGPT와 연결 중…"
        )
        connectionRecoveryStatus.textColor = .secondaryLabelColor
        let generation = beginProbe()
        remoteClient.pair(pairingCode: code) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.probeGeneration == generation else { return }
                self.stopProbe()
                self.finishConnectionRecovery()
                switch result {
                case let .success(outcome):
                    self.connectionRecoveryStatus.stringValue =
                        outcome.hostClaimRequired
                        ? self.localizedCopy.text(
                            "Local enrollment is ready. In ChatGPT, open Settings → Connections and choose Add, then paste the code shown there.",
                            "로컬 등록이 준비되었습니다. ChatGPT에서 설정 → 연결을 열고 추가를 선택한 뒤 표시된 코드를 붙여넣으세요."
                        )
                        : self.localizedCopy.text(
                            "Codex Remote pairing is ready.",
                            "Codex Remote 페어링이 준비됐어."
                        )
                    self.connectionRecoveryStatus.textColor =
                        outcome.remoteRPCReady ? .systemGreen : .systemOrange
                    self.refreshConnections()
                case let .failure(error):
                    self.connectionRecoveryStatus.stringValue = error.localizedDescription
                    self.connectionRecoveryStatus.textColor = .systemRed
                }
            }
        }
    }

    @objc private func openChatGPTConnections() {
        let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.connectionRecoveryStatus.stringValue = error.localizedDescription
                    self.connectionRecoveryStatus.textColor = .systemRed
                } else {
                    self.connectionRecoveryStatus.stringValue =
                        self.localizedCopy.text(
                            "In ChatGPT, open Settings → Connections and choose Add or Revoke access.",
                            "ChatGPT에서 설정 → 연결을 열고 추가 또는 접근 권한 취소를 선택하세요."
                        )
                    self.connectionRecoveryStatus.textColor = .secondaryLabelColor
                }
            }
        }
    }

    @objc private func clearTaskField() {
        threadIDControl.stringValue = ""
        taskStatus.stringValue = localizedCopy.text(
            "A new dedicated session will be created when voice starts.",
            "음성을 시작할 때 새 전용 session을 생성합니다."
        )
        window?.makeFirstResponder(threadIDControl)
    }

    @objc private func chooseAuthorityPackFolder() {
        let panel = NSOpenPanel()
        panel.title = localizedCopy.text(
            "Choose Authority Pack Folder",
            "Authority Pack 폴더 선택"
        )
        panel.prompt = localizedCopy.text("Choose", "선택")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        authorityPackRootControl.stringValue = url.standardizedFileURL.path
        authorityPackControl.state = .on
    }

    @objc private func chooseAdditionalContextProvidersFolder() {
        let panel = NSOpenPanel()
        panel.title = localizedCopy.text(
            "Choose Additional Context Providers Folder",
            "Additional Context Providers 폴더 선택"
        )
        panel.prompt = localizedCopy.text("Choose", "선택")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        additionalContextProvidersRootControl.stringValue =
            url.standardizedFileURL.path
        additionalContextProvidersControl.state = .on
    }

    @objc private func save() {
        var settings = store.load()
        let previousThreadID = settings.codexThreadID
        let taskID = threadIDControl.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        settings.productName = SettingsStore.normalizedDisplayName(
            productNameControl.stringValue,
            fallback: AppSettings.defaults.productName
        )
        settings.assistantName = SettingsStore.normalizedDisplayName(
            assistantNameControl.stringValue,
            fallback: AppSettings.defaults.assistantName
        )
        settings.userDisplayName = SettingsStore.normalizedDisplayName(
            userDisplayNameControl.stringValue,
            fallback: AppSettings.defaults.userDisplayName
        )
        settings.appDisplayLanguage =
            appLanguageControl.selectedItem?.representedObject as? String
                ?? AppDisplayLanguage.system.rawValue
        settings.appearanceMode =
            appearanceControl.selectedItem?.representedObject as? String
                ?? AppAppearanceMode.system.rawValue
        settings.overlayAnchor = OverlayAnchor.parse(
            surfaceControl.selectedItem?.representedObject as? String
        )
        settings.wakePhraseEnabled = wakeControl.state == .on
        settings.preferModernSpeechAnalyzer =
            modernSpeechAnalyzerControl.state == .on
        settings.wakePhrases = SettingsStore.normalizedWakePhrases(
            wakePhrasesControl.stringValue.components(
                separatedBy: CharacterSet(charactersIn: ",\n")
            )
        )
        settings.speechLocale = localeControl.selectedItem?.representedObject as? String ?? "system"
        settings.additionalSpeechLocales =
            SettingsStore.normalizedAdditionalSpeechLocales(
                additionalLocaleControls.compactMap {
                    $0.selectedItem?.representedObject as? String
                },
                primary: settings.speechLocale
            )
        settings.voiceIdleTimeoutMinutes =
            voiceIdleTimeoutControl.selectedItem?.representedObject as? Int ?? 5
        settings.realtimeVoice = SettingsStore.normalizedRealtimeVoice(
            realtimeVoiceControl.selectedItem?.representedObject as? String
                ?? AppSettings.defaults.realtimeVoice
        )
        settings.realtimeInstructions = realtimePromptDraft
        settings.returnGreetingEnabled = returnControl.state == .on
        settings.returnGreetingMinutes = Int(returnMinutesControl.titleOfSelectedItem ?? "") ?? 30
        settings.hoverStartsVoice = false
        settings.showRecentHistory = historyControl.state == .on
        settings.includeAuthorityPack = authorityPackControl.state == .on
        settings.authorityPackRoot = authorityPackRootControl.stringValue
        settings.authorityPackFingerprint = ""
        settings.includeAdditionalContextProviders =
            additionalContextProvidersControl.state == .on
        settings.additionalContextProvidersRoot =
            additionalContextProvidersRootControl.stringValue
        settings.codexThreadID = taskID
        if taskID.isEmpty {
            settings.codexThreadSource = ""
            settings.codexThreadTitle = ""
        } else if taskID != previousThreadID {
            settings.codexThreadSource = "user"
            settings.codexThreadTitle = settings.productName
        }
        settings.codexModel = "inherit"
        settings.codexReasoningEffort = "inherit"
        settings.codexSandbox = "inherit"
        settings.codexApprovalPolicy = "inherit"
        do {
            try store.save(settings)
            builtAppearanceMode = AppAppearanceMode.parse(
                settings.appearanceMode
            )
            displayedAppearanceMode = builtAppearanceMode
            stopProbe()
            window?.orderOut(nil)
            onSave?()
        } catch {
            present(error)
        }
    }

    @objc private func resetApp() {
        let productName = store.load().productName
        let alert = NSAlert()
        alert.messageText = "\(productName)를 초기화할까?"
        alert.informativeText =
            "로컬 설정, onboarding 상태, Session ID 연결과 앱 연결 상태를 지워. Codex의 원격 session은 삭제하지 않아."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "취소")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performReset()
        }
    }

    private func performReset() {
        resetButton.isEnabled = false
        saveButton.isEnabled = false
        let generation = beginProbe()
        remoteClient.resetConnection { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.probeGeneration == generation else { return }
                self.resetButton.isEnabled = true
                self.saveButton.isEnabled = true
                switch result {
                case .success:
                    do {
                        try self.store.resetToDefaults()
                        self.stopProbe()
                        self.window?.orderOut(nil)
                        self.onReset?()
                    } catch {
                        self.present(error)
                    }
                case let .failure(error):
                    self.present(error)
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func cancel() {
        finishConnectionRecovery()
        stopProbe()
        displayedAppearanceMode = AppAppearanceMode.parse(
            store.load().appearanceMode
        )
        applyCanvasAppearance()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finishConnectionRecovery()
        stopProbe()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshLaunchAtLogin()
    }

    private func beginConnectionRecovery() {
        guard !connectionRecoveryInFlight else { return }
        connectionRecoveryInFlight = true
        onConnectionRecoveryWillBegin?()
    }

    private func finishConnectionRecovery() {
        guard connectionRecoveryInFlight else { return }
        connectionRecoveryInFlight = false
        onConnectionRecoveryDidEnd?()
    }

    @objc private func editRealtimePrompt() {
        let editor = RealtimePromptEditorController(localizedCopy: localizedCopy)
        editor.onApply = { [weak self] text in
            guard let self else { return }
            self.realtimePromptDraft = text
            self.updateRealtimePromptStatus()
            self.promptEditor = nil
        }
        editor.onClose = { [weak self] in
            self?.promptEditor = nil
        }
        promptEditor = editor
        editor.present(text: realtimePromptDraft, relativeTo: window)
    }

    private func updateRealtimePromptStatus() {
        realtimePromptStatus.stringValue =
            SettingsStore.normalizedRealtimeInstructions(realtimePromptDraft)
                == SettingsStore.defaultRealtimeInstructions
            ? localizedCopy.text("Default prompt", "기본 프롬프트")
            : localizedCopy.text("Custom prompt", "사용자 프롬프트")
    }

    private func populateAppLanguages() {
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
    }

    private func populateAppearances() {
        appearanceControl.removeAllItems()
        let entries: [(String, AppAppearanceMode)] = [
            (localizedCopy.text("System", "시스템 설정"), .system),
            (localizedCopy.text("Light", "라이트"), .light),
            (localizedCopy.text("Dark", "다크"), .dark),
        ]
        for (title, appearance) in entries {
            appearanceControl.addItem(withTitle: title)
            appearanceControl.lastItem?.representedObject = appearance.rawValue
        }
    }

    private func populateRealtimeVoices() {
        realtimeVoiceControl.removeAllItems()
        for voice in SettingsStore.supportedRealtimeVoices {
            let displayName = voice.prefix(1).uppercased() + voice.dropFirst()
            let title = voice == "marin" || voice == "cedar"
                ? localizedCopy.text(
                    "\(displayName) (Recommended)",
                    "\(displayName) (권장)"
                )
                : displayName
            realtimeVoiceControl.addItem(withTitle: title)
            realtimeVoiceControl.lastItem?.representedObject = voice
        }
    }

    private func selectRealtimeVoice(_ voice: String) {
        let normalized = SettingsStore.normalizedRealtimeVoice(voice)
        if let item = realtimeVoiceControl.itemArray.first(where: {
            $0.representedObject as? String == normalized
        }) {
            realtimeVoiceControl.select(item)
        } else {
            realtimeVoiceControl.selectItem(at: 0)
        }
    }

    private func selectAppLanguage(_ identifier: String) {
        let normalized = AppDisplayLanguage.parse(identifier).rawValue
        if let item = appLanguageControl.itemArray.first(where: {
            $0.representedObject as? String == normalized
        }) {
            appLanguageControl.select(item)
        } else {
            appLanguageControl.selectItem(at: 0)
        }
    }

    private func selectAppearance(_ identifier: String) {
        let normalized = AppAppearanceMode.parse(identifier).rawValue
        if let item = appearanceControl.itemArray.first(where: {
            $0.representedObject as? String == normalized
        }) {
            appearanceControl.select(item)
        } else {
            appearanceControl.selectItem(at: 0)
        }
    }

    private func populateLocales() {
        let locales = SFSpeechRecognizer.supportedLocales().sorted(by: {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        })

        localeControl.removeAllItems()
        localeControl.addItem(
            withTitle: localizedCopy.text(
                "System language",
                "시스템 언어"
            )
        )
        localeControl.lastItem?.representedObject = "system"
        for control in additionalLocaleControls {
            control.removeAllItems()
            control.addItem(
                withTitle: localizedCopy.text("Off", "사용 안 함")
            )
            control.lastItem?.representedObject = ""
        }

        for locale in locales {
            let title = locale.localizedString(forIdentifier: locale.identifier)
                ?? locale.identifier
            localeControl.addItem(withTitle: "\(title) (\(locale.identifier))")
            localeControl.lastItem?.representedObject = locale.identifier
            for control in additionalLocaleControls {
                control.addItem(withTitle: "\(title) (\(locale.identifier))")
                control.lastItem?.representedObject = locale.identifier
            }
        }
    }

    private func selectLocale(_ control: NSPopUpButton, identifier: String) {
        for item in control.itemArray
        where item.representedObject as? String == identifier {
            control.select(item)
            return
        }
        control.selectItem(at: 0)
    }

    private func card(
        icon: String,
        title: String,
        subtitle: String,
        accessory: NSView? = nil,
        views: [NSView]
    ) -> NSView {
        let container = SettingsCardView()

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: title
        )
        iconView.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        iconView.contentTintColor = .controlAccentColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let titleRow = rowStack([iconView, titleLabel, NSView()] + (accessory.map { [$0] } ?? []))
        let subtitleLabel = note(subtitle)
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleRow, subtitleLabel] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        return container
    }

    private func settingsRow(_ title: String, _ views: NSView...) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 116).isActive = true
        let stack = rowStack([label] + views)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return stack
    }

    private func fieldLabel(_ title: String, detail: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func rowStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        return stack
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func stopProbe() {
        probeGeneration &+= 1
    }

    private func beginProbe() -> Int {
        stopProbe()
        return probeGeneration
    }
}

private final class RealtimePromptEditorController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let localizedCopy: AppCopy
    var onApply: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(localizedCopy: AppCopy) {
        self.localizedCopy = localizedCopy
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedCopy.text(
            "Realtime prompt",
            "Realtime 프롬프트"
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(text: String, relativeTo parent: NSWindow?) {
        textView.string = text
        showWindow(nil)
        if let parent, let window {
            let origin = NSPoint(
                x: parent.frame.midX - window.frame.width / 2,
                y: parent.frame.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(
            labelWithString: localizedCopy.text(
                "Realtime voice prompt",
                "Realtime 음성 프롬프트"
            )
        )
        heading.font = .systemFont(ofSize: 20, weight: .bold)

        let explanation = NSTextField(
            wrappingLabelWithString: localizedCopy.text(
                "Set the assistant's tone, first greeting, and progress guidance before a Codex handoff.\nVoice Relay separately enforces which simple local requests can be answered directly.",
                "에이전트의 말투, 첫 인사와 Codex 전달 전 진행 안내를 정합니다.\n간단한 로컬 답변만 직접 처리하는 경계는 Voice Relay가 별도로 강제합니다."
            )
        )
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3

        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let defaultButton = NSButton(
            title: localizedCopy.text(
                "Restore Defaults",
                "기본값으로 복원"
            ),
            target: self,
            action: #selector(restoreDefault)
        )
        defaultButton.bezelStyle = .rounded
        let cancelButton = NSButton(
            title: localizedCopy.text("Cancel", "취소"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded
        let applyButton = NSButton(
            title: localizedCopy.text("Apply", "적용"),
            target: self,
            action: #selector(apply)
        )
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [defaultButton, NSView(), cancelButton, applyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 9

        let stack = NSStackView(views: [heading, explanation, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func restoreDefault() {
        textView.string = SettingsStore.defaultRealtimeInstructions
    }

    @objc private func cancel() {
        close()
    }

    @objc private func apply() {
        let prompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.utf8.count <= 16_000,
              !prompt.contains("\0") else {
            let alert = NSAlert()
            alert.messageText = localizedCopy.text(
                "The prompt could not be saved.",
                "프롬프트를 저장할 수 없습니다."
            )
            alert.informativeText = localizedCopy.text(
                "Enter non-empty plain text no larger than 16 KB.",
                "비어 있지 않은 16KB 이하 일반 텍스트로 입력하세요."
            )
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        onApply?(prompt)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
