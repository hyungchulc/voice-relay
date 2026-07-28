import Cocoa
import Foundation

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }

    func openLoginItemsSettings() {
        openSettingsCalls += 1
    }
}

@main
struct PolicyTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var recoveryPolicy = AudioConfigurationRecoveryPolicy(
            quietWindow: 0.45
        )
        let startupChange = recoveryPolicy.registerChange(
            now: 10.0,
            recoveryNotBefore: 12.0
        )
        expect(
            startupChange.delay == 2.0,
            "audio startup recovery must wait for the settling barrier"
        )
        let laterChange = recoveryPolicy.registerChange(
            now: 11.8,
            recoveryNotBefore: 12.0
        )
        expect(
            laterChange.delay == 0.45,
            "the latest audio change must restart the trailing-edge quiet window"
        )
        expect(
            !recoveryPolicy.isCurrent(token: startupChange.token)
                && recoveryPolicy.isCurrent(token: laterChange.token),
            "only the newest audio configuration change may trigger recovery"
        )
        recoveryPolicy.invalidate()
        expect(
            !recoveryPolicy.isCurrent(token: laterChange.token),
            "teardown must invalidate pending audio recovery work"
        )

        let echoReference = (0..<4_800).map { index in
            Float(sin(Double(index) * 2 * .pi * 440 / 24_000)) * 0.20
        }
        var echoAdmission = RealtimeEchoAdmissionPolicy()
        echoAdmission.appendPlaybackReference(
            echoReference,
            startTime: 10
        )
        echoAdmission.markPlaybackActive(at: 10)
        let echoedInput = Array(echoReference.prefix(960)).map { $0 * 0.55 }
        let echoOnly = echoAdmission.filterCapture(
            echoedInput,
            startTime: 10.08,
            playbackActive: true
        )
        expect(
            echoOnly.classification == .echoOnly
                && echoOnly.samples.isEmpty
                && abs(echoOnly.correlation) >= 0.68,
            "rendered assistant audio must be removed from microphone capture"
        )
        expect(
            !echoAdmission.shouldForwardServerEvent(
                type: "input_audio_buffer.speech_started",
                playbackActive: true,
                now: 10.09
            )
                && !echoAdmission.shouldForwardServerEvent(
                    type: "conversation.item.input_audio_transcription.completed",
                    playbackActive: true,
                    now: 10.10
                ),
            "unadmitted playback echo must not become a server speech turn"
        )

        var bargeInAdmission = RealtimeEchoAdmissionPolicy()
        bargeInAdmission.appendPlaybackReference(
            echoReference,
            startTime: 20
        )
        bargeInAdmission.markPlaybackActive(at: 20)
        let humanOverlay = zip(
            echoedInput,
            (0..<echoedInput.count).map { index in
                Float(sin(Double(index) * 2 * .pi * 173 / 24_000)) * 0.08
            }
        ).map { $0 + $1 }
        let pendingBargeIn = bargeInAdmission.filterCapture(
            humanOverlay,
            startTime: 20.08,
            playbackActive: true
        )
        expect(
            !pendingBargeIn.samples.isEmpty
                && pendingBargeIn.classification == .uncertainSpeech
                && !bargeInAdmission.shouldForwardServerEvent(
                    type: "input_audio_buffer.speech_started",
                    playbackActive: true,
                    now: 20.09
                ),
            "one residual chunk over playback must pause before authorizing barge-in"
        )
        let pausedBargeIn = bargeInAdmission.filterCapture(
            humanOverlay,
            startTime: 20.12,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            pausedBargeIn.classification == .uncertainSpeech,
            "barge-in confirmation must start after playback actually pauses"
        )
        let decayedBargeIn = bargeInAdmission.filterCapture(
            humanOverlay,
            startTime: 20.30,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            decayedBargeIn.classification == .uncertainSpeech,
            "speaker echo decay time must not count as confirmed human speech"
        )
        let admittedBargeIn = bargeInAdmission.filterCapture(
            humanOverlay,
            startTime: 20.62,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            admittedBargeIn.classification == .residualSpeech,
            "speech must be admitted only after it continues through the confirmation window"
        )
        expect(
            !bargeInAdmission.shouldForwardServerEvent(
                type: "conversation.item.input_audio_transcription.completed",
                playbackActive: true,
                now: 20.63
            ),
            "the server turn rejected before local confirmation must stay quarantined through completion"
        )
        expect(
            bargeInAdmission.shouldForwardServerEvent(
                type: "input_audio_buffer.speech_started",
                playbackActive: true,
                now: 20.64
            )
                && bargeInAdmission.shouldForwardServerEvent(
                    type: "conversation.item.input_audio_transcription.completed",
                    playbackActive: true,
                    now: 20.65
                ),
            "confirmed speech must be admitted as a fresh server turn"
        )

        var uncertainAdmission = RealtimeEchoAdmissionPolicy()
        uncertainAdmission.appendPlaybackReference(
            echoReference,
            startTime: 25
        )
        uncertainAdmission.markPlaybackActive(at: 25)
        let decorrelatedSpeech = (0..<960).map { index in
            Float(sin(Double(index) * 2 * .pi * 173 / 24_000)) * 0.18
        }
        let uncertainFirst = uncertainAdmission.filterCapture(
            decorrelatedSpeech,
            startTime: 25.08,
            playbackActive: true
        )
        expect(
            uncertainFirst.classification == .uncertainSpeech
                && !uncertainAdmission.shouldForwardServerEvent(
                    type: "input_audio_buffer.speech_started",
                    playbackActive: true,
                    now: 25.09
                ),
            "one loud decorrelated playback-window chunk must not self-authorize barge-in"
        )
        var missingReferenceAdmission = RealtimeEchoAdmissionPolicy()
        missingReferenceAdmission.markPlaybackActive(at: 26)
        let missingReferenceNoise = missingReferenceAdmission.filterCapture(
            [Float](repeating: 0.001, count: 960),
            startTime: 26.04,
            playbackActive: true
        )
        expect(
            missingReferenceNoise.classification == .echoOnly
                && missingReferenceNoise.samples.isEmpty,
            "a playback window without a usable reference must fail closed for low-level audio"
        )
        let missingReferenceSpeech =
            missingReferenceAdmission.filterCapture(
                decorrelatedSpeech,
                startTime: 26.08,
                playbackActive: true
            )
        expect(
            missingReferenceSpeech.classification == .uncertainSpeech,
            "loud audio without a playback reference must still require sustained human confirmation"
        )
        let pausedSpeech = uncertainAdmission.filterCapture(
            decorrelatedSpeech,
            startTime: 25.12,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            pausedSpeech.classification == .uncertainSpeech,
            "pre-pause echo time must not count toward human speech confirmation"
        )
        let decayedSpeech = uncertainAdmission.filterCapture(
            decorrelatedSpeech,
            startTime: 25.30,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            decayedSpeech.classification == .uncertainSpeech,
            "post-pause echo decay must finish before human confirmation starts"
        )
        let confirmedSpeech = uncertainAdmission.filterCapture(
            decorrelatedSpeech,
            startTime: 25.62,
            playbackActive: true,
            playbackProvisionallyPaused: true
        )
        expect(
            confirmedSpeech.classification == .residualSpeech
                && uncertainAdmission.shouldForwardServerEvent(
                    type: "input_audio_buffer.speech_started",
                    playbackActive: true,
                    now: 25.63
                ),
            "speech that continues after provisional playback pause must preserve human barge-in"
        )
        var playbackTailAdmission = RealtimeEchoAdmissionPolicy()
        playbackTailAdmission.appendPlaybackReference(
            echoReference,
            startTime: 27
        )
        playbackTailAdmission.markPlaybackEnded(at: 27.2)
        let playbackTailEcho = playbackTailAdmission.filterCapture(
            Array(echoReference.prefix(960)),
            startTime: 27.3,
            playbackActive: false
        )
        expect(
            playbackTailEcho.classification == .echoOnly,
            "assistant audio that reaches the microphone after playback drains must stay inside the echo guard"
        )
        bargeInAdmission.reset()
        expect(
            bargeInAdmission.filterCapture(
                [0.2, -0.2, 0.1],
                startTime: 30,
                playbackActive: false
            ).classification == .noPlaybackReference,
            "ordinary microphone speech must pass when playback is inactive"
        )

        var audioAdmission = RealtimeAudioAdmissionPolicy()
        audioAdmission.register(
            responseID: "route-response",
            responseKind: "route_classifier"
        )
        expect(
            !audioAdmission.shouldAdmit(responseID: "route-response")
                && !audioAdmission.shouldAdmit(responseID: ""),
            "route-classifier audio must be rejected before native playback"
        )
        expect(
            audioAdmission.shouldReportSuppression(
                responseID: "route-response"
            )
                && !audioAdmission.shouldReportSuppression(
                    responseID: "route-response"
                ),
            "classifier audio diagnostics must be emitted once per response"
        )
        expect(
            audioAdmission.shouldAdmit(responseID: "codex-final"),
            "spoken final responses must remain eligible for native playback"
        )
        audioAdmission.finish(responseID: "route-response")
        expect(
            audioAdmission.shouldAdmit(responseID: "route-response"),
            "completed classifier responses must leave no stale audio suppression"
        )
        audioAdmission.register(
            responseID: "route-reset",
            responseKind: "route_classifier"
        )
        audioAdmission.reset()
        expect(
            audioAdmission.shouldAdmit(responseID: "route-reset"),
            "session reset must clear classifier audio suppression"
        )

        let notchedDisplay = DisplayGeometry(
            frame: NSRect(x: 0, y: 0, width: 2056, height: 1329),
            visibleFrame: NSRect(x: 0, y: 0, width: 2056, height: 1290),
            safeTopInset: 38,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 1291, width: 918, height: 38),
            auxiliaryTopRightArea: NSRect(x: 1138, y: 1291, width: 918, height: 38)
        )
        expect(
            notchedDisplay.resolvedAnchor(for: .automatic) == .notch,
            "Automatic must select the notch surface on a notched display"
        )
        expect(
            notchedDisplay.hardwareNotchWidth == 220,
            "auxiliary top areas must resolve the physical notch span"
        )
        let compactNotchWidth = notchedDisplay.compactWidth(for: .automatic)
        expect(
            compactNotchWidth == 260
                && compactNotchWidth - notchedDisplay.hardwareNotchWidth == 40,
            "compact notch layout must stay slim while preserving two indicator wings"
        )
        expect(
            notchedDisplay.activeWidth(for: .automatic) == 296,
            "active Notch width must scale modestly from the physical notch"
        )
        let expectedActiveHeight = ceil(
            NotchActivityGeometry.headerVerticalInsets
                + NotchActivityGeometry.notchBodyHeight(
                    safeTopInset: notchedDisplay.safeTopInset
                )
                + NotchActivityGeometry.labelLineHeight
                + NotchActivityGeometry.labelBottomPadding
        )
        expect(
            notchedDisplay.activeHeight(for: .automatic) == expectedActiveHeight
                && expectedActiveHeight > 58,
            "active Notch height must include notch, font, and safe padding"
        )
        let availableActivityLabelHeight =
            expectedActiveHeight
            - NotchActivityGeometry.headerVerticalInsets
            - NotchActivityGeometry.notchBodyHeight(
                safeTopInset: notchedDisplay.safeTopInset
            )
            - NotchActivityGeometry.labelBottomPadding
        expect(
            availableActivityLabelHeight
                >= NotchActivityGeometry.labelLineHeight,
            "localized activity labels must have a complete unclipped line box"
        )
        let activityFont = NotchActivityGeometry.font
        let activityLabels = [
            "Connecting", "Listening", "Checking", "Responding", "Finishing",
            "연결 중", "듣고 있음", "확인 중", "답변 중", "마무리 중", "Error", "오류",
        ]
        let widestActivityLabel = activityLabels.map {
            ($0 as NSString).size(withAttributes: [.font: activityFont]).width
        }.max() ?? 0
        let activityLabelCapacity =
            notchedDisplay.activeWidth(
                for: .automatic,
                activityLabelWidth: widestActivityLabel
            )
                - NotchActivityGeometry.horizontalPadding * 2
        expect(
            widestActivityLabel <= activityLabelCapacity,
            "every localized activity label must fit below the hardware notch"
        )
        let notchFrame = OverlayPlacement.frame(
            display: notchedDisplay,
            width: compactNotchWidth,
            height: notchedDisplay.compactHeight(for: .automatic),
            anchor: .automatic
        )
        expect(notchFrame.midX == notchedDisplay.frame.midX, "notch layout must be centered")
        expect(
            notchFrame.maxY == notchedDisplay.frame.maxY,
            "notch layout must attach to the physical top edge"
        )
        let indicatorBounds = CompactIndicatorGeometry.visualBounds(
            windowWidth: compactNotchWidth,
            notchWidth: notchedDisplay.hardwareNotchWidth
        )
        expect(
            indicatorBounds.lowerBound == 6,
            "typing dots must keep compact outer breathing room"
        )
        expect(
            indicatorBounds.upperBound
                == (compactNotchWidth - notchedDisplay.hardwareNotchWidth) / 2 - 1,
            "typing dots must remain one point outside the physical notch"
        )
        let activeFrame = OverlayPlacement.frame(
            display: notchedDisplay,
            width: notchedDisplay.activeWidth(
                for: .automatic,
                activityLabelWidth: widestActivityLabel
            ),
            height: notchedDisplay.activeHeight(for: .automatic),
            anchor: .automatic
        )
        expect(
            activeFrame.midX == notchFrame.midX
                && activeFrame.maxY == notchFrame.maxY,
            "active Notch growth must remain centered and top-attached"
        )
        expect(
            activeFrame.width == notchedDisplay.expandedWidth(for: .automatic),
            "hover and conversation surfaces must share one fixed expanded width"
        )
        expect(
            notchedDisplay.surfaceWidth(
                for: .automatic,
                answerVisible: false,
                activityVisible: true
            ) == 296
                && notchedDisplay.surfaceWidth(
                    for: .automatic,
                    answerVisible: true,
                    activityVisible: true
                ) == notchedDisplay.expandedWidth(for: .automatic),
            "active height must not accidentally select the expanded conversation width"
        )
        expect(
            notchedDisplay.expandedWidth(for: .automatic) == 296,
            "the answer surface must stay at the fixed hover width"
        )
        expect(
            notchedDisplay.activeWidth(
                for: .automatic,
                activityLabelWidth: 1_000
            ) == 296,
            "activity text must not widen the fixed notch"
        )
        expect(
            NotchAnswerGeometry.maximumSurfaceHeight(
                headerHeight: expectedActiveHeight
            ) == 277,
            "the answer surface must keep the previous 277-point height cap"
        )
        let idleNotch = NotchPresentation.resolve(
            phase: .dormantWake,
            answerVisible: false
        )
        let startingNotch = NotchPresentation.resolve(
            phase: .starting,
            answerVisible: false
        )
        let listeningNotch = NotchPresentation.resolve(
            phase: .listening,
            answerVisible: false
        )
        let listeningWithAnswer = NotchPresentation.resolve(
            phase: .listening,
            answerVisible: true
        )
        let listeningWithHover = NotchPresentation.resolve(
            phase: .listening,
            answerVisible: false,
            hovering: true
        )
        let thinkingNotch = NotchPresentation.resolve(
            phase: .thinking,
            answerVisible: false
        )
        let answerNotch = NotchPresentation.resolve(
            phase: .speaking,
            answerVisible: true
        )
        let hoveredAnswerNotch = NotchPresentation.resolve(
            phase: .speaking,
            answerVisible: true,
            hovering: true
        )
        expect(
            !idleNotch.headerExpanded
                && !idleNotch.answerExpanded
                && !idleNotch.indicatorAnimated
                && !idleNotch.indicatorUsesRing,
            "idle Notch must stay compact with a static three-dot cluster"
        )
        expect(
            !startingNotch.headerExpanded
                && startingNotch.indicatorAnimated
                && !startingNotch.indicatorUsesRing
                && !listeningNotch.headerExpanded
                && listeningNotch.indicatorAnimated
                && !listeningNotch.indicatorUsesRing,
            "connecting and listening must animate the compact three-dot cluster"
        )
        expect(
            listeningWithAnswer.headerExpanded
                && listeningWithAnswer.answerExpanded
                && listeningWithAnswer.indicatorAnimated,
            "hovered history must grow the notch before adding the answer surface"
        )
        expect(
            listeningWithHover.headerExpanded
                && !listeningWithHover.answerExpanded,
            "hover without history must grow only the pill header"
        )
        expect(
            listeningWithHover.showsHoverVoiceAction
                && !listeningNotch.showsHoverVoiceAction,
            "the notch Voice control must appear only on a header-only hover"
        )
        expect(
            thinkingNotch.headerExpanded
                && !thinkingNotch.answerExpanded
                && thinkingNotch.indicatorUsesRing
                && thinkingNotch.showsActivityLabel
                && !thinkingNotch.showsHoverVoiceAction,
            "post-speech work must modestly expand the Notch"
        )
        expect(
            answerNotch.headerExpanded
                && answerNotch.answerExpanded
                && answerNotch.indicatorAnimated
                && answerNotch.showsActivityLabel
                && !answerNotch.showsHoverVoiceAction
                && !hoveredAnswerNotch.showsHoverVoiceAction,
            "an expanded answer must keep only the footer actions"
        )
        let notchGradientLocations =
            NotchUnifiedSurfacePolicy.blackGradientLocations
        let notchGradientAlphas =
            NotchUnifiedSurfacePolicy.blackGradientAlphas
        expect(
            notchGradientLocations.count == notchGradientAlphas.count
                && notchGradientLocations.first == 0
                && notchGradientLocations.last == 1
                && notchGradientAlphas.first == 1
                && notchGradientAlphas.last == 0,
            "the unified notch overlay must yield to the low-opacity native glass"
        )
        expect(
            NotchUnifiedSurfacePolicy.nativeGlassOpacity == 0.10
                && NotchUnifiedSurfacePolicy.nativeGlassTintAlpha == 0,
            "zero-frost glass must keep a faint optical trace with no fill tint"
        )
        expect(
            notchGradientLocations == [0, 0.75, 1]
                && notchGradientAlphas == [1, 1, 0],
            "answer continuation must hold black through seventy-five percent before fading to clear glass"
        )
        expect(
            NotchUnifiedSurfacePolicy.cornerRadius(
                for: CGSize(width: 260, height: 39)
            ) == 24
                && NotchUnifiedSurfacePolicy.cornerRadius(
                    for: CGSize(width: 296, height: 69)
                ) == 24
                && NotchUnifiedSurfacePolicy.cornerRadius(
                    for: CGSize(width: 296, height: 220)
                ) == 24
                && NotchUnifiedSurfacePolicy.bottomCornerRadius == 24,
            "every notch state must use the measured macOS lower-corner radius"
        )
        expect(
            NotchActionIconPolicy.whiteAlpha == 1
                && NotchActionIconPolicy.shadowOpacity >= 0.85
                && NotchActionIconPolicy.shadowRadius >= 4
                && NotchActionIconPolicy.shadowOffset == .zero,
            "notch action symbols must stay pure white with a direct dark silhouette shadow"
        )
        expect(
            NotchAnswerGeometry.scrollerTerminalInset >= 6
                && NotchAnswerLifecyclePolicy.minimumReplyRetention >= 4,
            "answers must keep readable dwell time and unclipped scroller terminals"
        )
        let replyNow = Date(timeIntervalSince1970: 1_000)
        let replyDeadline =
            NotchAnswerLifecyclePolicy.retentionDeadline(now: replyNow)
        expect(
            replyDeadline.timeIntervalSince(replyNow) == 4
                && NotchAnswerLifecyclePolicy.collapseDelay(
                    requestedDelay: 0.25,
                    now: replyNow.addingTimeInterval(1),
                    retainUntil: replyDeadline
                ) == 3
                && NotchAnswerLifecyclePolicy.collapseDelay(
                    requestedDelay: 0.25,
                    now: replyNow.addingTimeInterval(5),
                    retainUntil: replyDeadline
                ) == 0.25,
            "reply retention must be measured from answer completion instead of timer rescheduling"
        )
        let midpointProgress = SurfaceMotionPolicy.animationProgress(
            elapsed: SurfaceMotionPolicy.maximumDuration / 2
        )
        let midpointHeight = SurfaceMotionPolicy.interpolatedValue(
            from: 100,
            to: 300,
            progress: midpointProgress
        )
        expect(
            SurfaceMotionPolicy.animationProgress(elapsed: 0) == 0
                && midpointProgress == 0.75
                && midpointHeight == 250
                && SurfaceMotionPolicy.animationProgress(
                    elapsed: SurfaceMotionPolicy.maximumDuration
                ) == 1
                && SurfaceMotionPolicy.maximumDuration == 0.28,
            "surface motion must follow one bounded curve and land exactly without a late snap"
        )
        let expandedIndicatorBounds = CompactIndicatorGeometry.visualBounds(
            windowWidth: 640,
            notchWidth: notchedDisplay.hardwareNotchWidth
        )
        expect(
            expandedIndicatorBounds.lowerBound == 196
                && expandedIndicatorBounds.upperBound == 209,
            "typing dots must stay attached to the hardware notch as the panel expands"
        )
        let quietOrbLevel = OrbAudioLevelPolicy.normalizedRMS([
            [Float](repeating: 0.000_2, count: 128)
        ])
        let speechOrbLevel = OrbAudioLevelPolicy.normalizedRMS([
            [Float](repeating: 0.12, count: 128)
        ])
        let loudOrbLevel = OrbAudioLevelPolicy.normalizedRMS([
            [Float](repeating: 0.6, count: 128)
        ])
        expect(
            quietOrbLevel == 0
                && speechOrbLevel > 0.45
                && loudOrbLevel > speechOrbLevel
                && loudOrbLevel <= 1,
            "Orb input levels must reject the noise floor and rise with real speech"
        )
        let attackedOrbLevel = OrbAudioLevelPolicy.smoothed(
            current: 0,
            target: 1
        )
        let releasedOrbLevel = OrbAudioLevelPolicy.smoothed(
            current: 1,
            target: 0
        )
        expect(
            abs(attackedOrbLevel - 0.60) < 0.000_001
                && abs(releasedOrbLevel - 0.82) < 0.000_001
                && abs(
                    OrbAudioLevelPolicy.scale(
                        for: 1,
                        reduceMotion: false
                    ) - 1.14
                ) < 0.000_001
                && OrbAudioLevelPolicy.scale(
                    for: 1,
                    reduceMotion: true
                ) == 1,
            "Orb audio scaling must attack quickly, release smoothly, and honor Reduce Motion"
        )
        let spectralAccents = VoiceOrbVisualPolicy.spectralAccents
        expect(
            spectralAccents.count == 7
                && spectralAccents.map(\.hue) == [
                    0.98, 0.08, 0.16, 0.35, 0.52, 0.65, 0.84,
                ]
                && Set(spectralAccents.map {
                    "\($0.center.x),\($0.center.y)"
                }).count == spectralAccents.count,
            "Orb artwork must retain seven fixed, distinct full-spectrum regions"
        )
        expect(
            VoiceOrbVisualPolicy.nativeGlassOpacity == 0.08
                && VoiceOrbVisualPolicy.fallbackMaterialOpacity == 0.06
                && VoiceOrbVisualPolicy.spectralSaturation == 0.98
                && VoiceOrbVisualPolicy.spectralCenterAlpha == 0.88
                && VoiceOrbVisualPolicy.spectralSecondaryAlpha == 0.24
                && VoiceOrbVisualPolicy.idleFlowOpacity == 0.34
                && VoiceOrbVisualPolicy.activeFlowOpacity == 0.50
                && VoiceOrbVisualPolicy.maximumFlowOpacity == 0.88
                && VoiceOrbVisualPolicy.flowDriftDurations.count == 3,
            "Orb glass must stay clear while its full-spectrum flow remains vivid and continuously layered"
        )
        let lightReply = OrbReplyAppearancePolicy.resolve(
            isDark: false
        )
        let darkReply = OrbReplyAppearancePolicy.resolve(
            isDark: true
        )
        let accessibleDarkReply = OrbReplyAppearancePolicy.resolve(
            isDark: true,
            reduceTransparency: true
        )
        expect(
            lightReply.tintWhite == 1
                && lightReply.textWhite < 0.1
                && lightReply.glassOpacity >= 0.65
                && lightReply.tintAlpha >= 0.35
                && lightReply.fallbackAlpha >= 0.45
                && lightReply.borderAlpha >= 0.24
                && darkReply.tintWhite == 0
                && darkReply.textWhite == 1
                && darkReply.glassOpacity > 0.3
                && accessibleDarkReply.fallbackAlpha > darkReply.fallbackAlpha,
            "Orb reply frost must stay visibly separated from busy Light backgrounds and remain readable in Dark and Reduce Transparency modes"
        )
        let orbVisibleFrame = NSRect(
            x: -1_920,
            y: 40,
            width: 1_920,
            height: 1_040
        )
        let orbReplyCases: [(NSRect, OrbReplyDirection)] = [
            (
                NSRect(x: -1_880, y: 900, width: 54, height: 54),
                .lowerRight
            ),
            (
                NSRect(x: -990, y: 900, width: 54, height: 54),
                .lowerCenter
            ),
            (
                NSRect(x: -90, y: 900, width: 54, height: 54),
                .lowerLeft
            ),
            (
                NSRect(x: -1_880, y: 80, width: 54, height: 54),
                .upperRight
            ),
            (
                NSRect(x: -990, y: 80, width: 54, height: 54),
                .upperCenter
            ),
            (
                NSRect(x: -90, y: 80, width: 54, height: 54),
                .upperLeft
            ),
        ]
        let orbReplyLayouts = orbReplyCases.map { orbFrame, direction in
            (
                OrbReplyPlacementPolicy.layout(
                    orbFrame: orbFrame,
                    requestedSize: NSSize(width: 520, height: 420),
                    visibleFrame: orbVisibleFrame
                ),
                direction
            )
        }
        expect(
            orbReplyLayouts.allSatisfy { layout, direction in
                layout.direction == direction
                    && layout.frame.width
                        <= OrbReplyPlacementPolicy.maximumWidth
                    && layout.frame.height
                        <= OrbReplyPlacementPolicy.maximumHeight
                    && orbVisibleFrame.insetBy(dx: 8, dy: 8)
                        .contains(layout.frame)
            }
                && Set(orbReplyLayouts.map(\.0.direction)).count == 6,
            "Orb replies must choose all six inward directions and stay inside negative-origin displays"
        )
        expect(
            !RealtimeHostEventPolicy.shouldAccept(
                type: "error",
                generation: 8,
                activeGeneration: nil,
                stoppingGenerations: [8]
            )
                && RealtimeHostEventPolicy.shouldAccept(
                    type: "terminal",
                    generation: 8,
                    activeGeneration: nil,
                    stoppingGenerations: [8]
                )
                && !RealtimeHostEventPolicy.shouldAccept(
                    type: "state",
                    generation: 7,
                    activeGeneration: 8,
                    stoppingGenerations: []
                ),
            "host event routing must suppress teardown errors, accept the matching terminal, and reject stale generations"
        )
        expect(
            WakeRecognitionBackendPolicy.usesModernAnalyzer(
                preferenceEnabled: true,
                platformSupportsAnalyzer: true,
                requestedLocaleCount: 3,
                availableLocaleCount: 3
            )
                && !WakeRecognitionBackendPolicy.usesModernAnalyzer(
                    preferenceEnabled: false,
                    platformSupportsAnalyzer: true,
                    requestedLocaleCount: 3,
                    availableLocaleCount: 3
                )
                && !WakeRecognitionBackendPolicy.usesModernAnalyzer(
                    preferenceEnabled: true,
                    platformSupportsAnalyzer: true,
                    requestedLocaleCount: 3,
                    availableLocaleCount: 2
                )
                && !WakeRecognitionBackendPolicy.usesModernAnalyzer(
                    preferenceEnabled: true,
                    platformSupportsAnalyzer: false,
                    requestedLocaleCount: 3,
                    availableLocaleCount: 3
                ),
            "SpeechAnalyzer must require the user preference, platform support, and every selected language asset"
        )

        let expandedFrame = OverlayPlacement.frame(
            display: notchedDisplay,
            width: notchedDisplay.expandedWidth(for: .automatic),
            height: 238,
            anchor: .automatic
        )
        expect(expandedFrame.maxY == notchFrame.maxY, "expanded layout must keep its top edge fixed")
        let plainDisplay = DisplayGeometry(
            frame: NSRect(x: 100, y: 200, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 100, y: 200, width: 1920, height: 1055),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        expect(
            plainDisplay.resolvedAnchor(for: .automatic) == .orb,
            "Automatic must select Orb on a display without a hardware notch"
        )
        let compactNotchedDisplay = DisplayGeometry(
            frame: NSRect(x: -1_800, y: 0, width: 1_800, height: 1_169),
            visibleFrame: NSRect(x: -1_800, y: 0, width: 1_800, height: 1_132),
            safeTopInset: 37,
            auxiliaryTopLeftArea: NSRect(
                x: -1_800,
                y: 1_132,
                width: 801,
                height: 37
            ),
            auxiliaryTopRightArea: NSRect(
                x: -801,
                y: 1_132,
                width: 801,
                height: 37
            )
        )
        expect(
            compactNotchedDisplay.resolvedAnchor(for: .automatic) == .notch
                && compactNotchedDisplay.hardwareNotchWidth == 198
                && compactNotchedDisplay.compactWidth(for: .automatic) == 238
                && OverlayPlacement.frame(
                    display: compactNotchedDisplay,
                    width: compactNotchedDisplay.compactWidth(for: .automatic),
                    height: compactNotchedDisplay.compactHeight(for: .automatic),
                    anchor: .automatic
                ).maxY == compactNotchedDisplay.frame.maxY,
            "notch geometry must remain top-attached on a second display origin and compact notch span"
        )
        let orbFrame = OverlayPlacement.frame(
            display: plainDisplay,
            width: plainDisplay.compactWidth(for: .automatic),
            height: plainDisplay.compactHeight(for: .automatic),
            anchor: .automatic
        )
        expect(
            orbFrame.midX == plainDisplay.visibleFrame.midX
                && orbFrame.maxY == plainDisplay.visibleFrame.maxY - 12,
            "Orb must use the selected display's visible-frame origin and top inset"
        )
        expect(
            OverlayAnchor.parse(nil) == .automatic
                && OverlayAnchor.parse("floating") == .orb,
            "fresh installs must use Automatic while legacy floating settings migrate to Orb"
        )
        expect(
            OverlayPlacement.topBandHeight(
                screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1118),
                visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1079),
                fallback: 22
            ) == 39,
            "a notched display must use its full reserved top band"
        )
        expect(
            OverlayPlacement.topBandHeight(
                screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                fallback: 22
            ) == 22,
            "a display without a reserved band must use the system status-bar fallback"
        )
        expect(
            RealtimeCredentialPolicy.canReuse(
                expiresAt: 140,
                now: 100
            ),
            "a prefetched Realtime credential needs a safe remaining lifetime"
        )
        expect(
            !RealtimeCredentialPolicy.canReuse(
                expiresAt: 129,
                now: 100
            ),
            "near-expiry Realtime credentials must never be reused"
        )
        expect(
            RealtimeCredentialPolicy.evictionDelay(
                expiresAt: 140,
                now: 100
            ) == 10,
            "a prefetched credential must be evicted when it stops being reusable"
        )
        var startupRetry = RealtimeStartupRetryState()
        startupRetry.begin(generation: 21)
        expect(
            startupRetry.registerTransportAttempt(
                generation: 21,
                isRetry: false
            ),
            "the initial Realtime transport attempt should register once"
        )
        expect(
            startupRetry.reserveRetry(generation: 21),
            "a pre-ready transport failure should reserve one retry"
        )
        expect(
            !startupRetry.reserveRetry(generation: 21),
            "simultaneous startup failures must not reserve duplicate retries"
        )
        expect(
            startupRetry.registerTransportAttempt(
                generation: 21,
                isRetry: true
            ),
            "the reserved retry should register as the second transport attempt"
        )
        expect(
            startupRetry.reserveRetry(generation: 21),
            "a second pre-ready failure should reserve one final recovery attempt"
        )
        expect(
            !startupRetry.reserveRetry(generation: 21),
            "the final recovery attempt must not be reserved twice"
        )
        expect(
            startupRetry.registerTransportAttempt(
                generation: 21,
                isRetry: true
            ),
            "the final reserved retry should register as the third transport attempt"
        )
        expect(
            !startupRetry.reserveRetry(generation: 21),
            "a third failure must stop at the bounded transport attempt limit"
        )
        startupRetry.begin(generation: 22)
        expect(
            !startupRetry.registerTransportAttempt(
                generation: 21,
                isRetry: false
            ),
            "late callbacks from an older generation must be rejected"
        )
        expect(
            startupRetry.registerTransportAttempt(
                generation: 22,
                isRetry: false
            ) && startupRetry.markListeningReady(generation: 22),
            "the current transport should become listening-ready"
        )
        expect(
            !startupRetry.reserveRetry(generation: 22),
            "an established Realtime session must never auto-retry"
        )
        startupRetry.cancel(generation: 22)
        expect(
            !startupRetry.reserveRetry(generation: 22),
            "stopping a session must reject later retry work"
        )

        let policy = PresencePolicy(
            idleThreshold: 1800,
            returnWindow: 4,
            greetingCooldown: 14400
        )
        let now = Date(timeIntervalSince1970: 10_000)
        expect(
            policy.isReturnCandidate(
                wasIdle: true,
                currentIdleSeconds: 1,
                lastGreetingAt: nil,
                now: now
            ),
            "fresh input after a long idle should be a return candidate"
        )
        expect(
            !policy.isReturnCandidate(
                wasIdle: false,
                currentIdleSeconds: 1,
                lastGreetingAt: nil,
                now: now
            ),
            "ordinary continuous input must not be a return candidate"
        )
        expect(
            !policy.isReturnCandidate(
                wasIdle: true,
                currentIdleSeconds: 1,
                lastGreetingAt: now.addingTimeInterval(-60),
                now: now
            ),
            "cooldown must suppress duplicate greetings"
        )

        expect(
            WakePhrasePolicy.match(
                "릴레이야",
                phrases: ["릴레이야"]
            ) == WakePhraseMatch(command: ""),
            "a user-defined Korean wake phrase should match"
        )
        expect(
            WakePhrasePolicy.match(
                "  릴레이 야, 오늘 일정 알려줘",
                phrases: ["릴레이야"]
            ) ==
                WakePhraseMatch(command: "오늘 일정 알려줘"),
            "wake command tail must be preserved exactly"
        )
        expect(
            WakePhrasePolicy.match(
                "오늘 릴레이야 일정 알려줘",
                phrases: ["릴레이야"]
            ) == nil,
            "wake phrase must be leading"
        )
        expect(
            WakePhrasePolicy.match(
                "릴레이야말로 좋은 이름이야",
                phrases: ["릴레이야"]
            ) == nil,
            "wake prefix inside a longer word must not match"
        )
        let configuredAriaPhrases = ["아리아야", "Hey Aria", "Aria"]
        expect(
            WakePhrasePolicy.match(
                "아리아야",
                phrases: configuredAriaPhrases
            ) == WakePhraseMatch(command: ""),
            "the first configured wake phrase must match"
        )
        expect(
            WakePhrasePolicy.match(
                "Hey Aria",
                phrases: configuredAriaPhrases
            ) == WakePhraseMatch(command: ""),
            "the second configured wake phrase must match"
        )
        expect(
            WakePhrasePolicy.match(
                "Aria",
                phrases: configuredAriaPhrases
            ) == WakePhraseMatch(command: ""),
            "the third configured wake phrase must match"
        )
        expect(
            WakePhrasePolicy.match(
                "Hey, Aria, check the weather",
                phrases: configuredAriaPhrases
            ) == WakePhraseMatch(command: "check the weather"),
            "dictation punctuation between wake words must be tolerated"
        )
        expect(
            WakePhrasePolicy.match(
                "아리아 야, 오늘 날씨",
                phrases: configuredAriaPhrases
            ) == WakePhraseMatch(command: "오늘 날씨"),
            "dictation spacing inside a wake phrase must be tolerated"
        )
        expect(
            WakePhrasePolicy.match(
                "area",
                phrases: configuredAriaPhrases
            ) == nil,
            "wake matching must not add unsafe homophone fuzziness"
        )
        expect(
            WakePhrasePolicy.match(
                "오늘 Aria",
                phrases: configuredAriaPhrases
            ) == nil,
            "configured wake phrases must remain leading"
        )
        let wakeOnlyMatch = WakePhraseMatch(command: "")
        let wakeCommandMatch = WakePhraseMatch(command: "들리니?")
        expect(
            WakePhraseCapturePolicy.activationDelay(
                for: wakeOnlyMatch,
                isFinal: false
            ) < WakePhraseCapturePolicy.activationDelay(
                for: wakeCommandMatch,
                isFinal: false
            ),
            "a name-only wake should acknowledge quickly while a command tail waits for a stable transcript"
        )
        expect(
            WakePhraseCapturePolicy.activationDelay(
                for: wakeCommandMatch,
                isFinal: true
            ) < WakePhraseCapturePolicy.activationDelay(
                for: wakeCommandMatch,
                isFinal: false
            ),
            "a finalized wake command should use only the arbitration grace"
        )
        expect(
            WakePhraseCapturePolicy.preferred(
                WakePhraseMatch(command: "오늘 일정 알려줘"),
                over: WakePhraseMatch(command: "오늘 일정")
            ),
            "wake capture must retain the longest stable command tail"
        )

        let disabledLoginService = FakeLaunchAtLoginService(
            status: .notRegistered
        )
        let launchManager = LaunchAtLoginManager(
            service: disabledLoginService
        )
        expect(
            (try? launchManager.setEnabled(true)) == .enabled
                && disabledLoginService.registerCalls == 1,
            "launch at login must register only when currently disabled"
        )
        _ = try? launchManager.setEnabled(true)
        expect(
            disabledLoginService.registerCalls == 1,
            "launch at login enable must be idempotent"
        )
        expect(
            (try? launchManager.setEnabled(false)) == .notRegistered
                && disabledLoginService.unregisterCalls == 1,
            "launch at login must unregister an enabled service"
        )
        let approvalService = FakeLaunchAtLoginService(
            status: .requiresApproval
        )
        let approvalManager = LaunchAtLoginManager(
            service: approvalService
        )
        _ = try? approvalManager.setEnabled(true)
        expect(
            approvalService.registerCalls == 0
                && approvalManager.status.isRegistered,
            "approval-required launch items must stay registered"
        )
        let missingLoginService = FakeLaunchAtLoginService(
            status: .notFound
        )
        let missingLoginManager = LaunchAtLoginManager(
            service: missingLoginService
        )
        expect(
            (try? missingLoginManager.setEnabled(true)) == .enabled
                && missingLoginService.registerCalls == 1,
            "a missing main-app BTM record must be registerable"
        )
        let failingLoginService = FakeLaunchAtLoginService(
            status: .notFound
        )
        failingLoginService.registerError = CocoaError(
            .fileNoSuchFile
        )
        let failingLoginManager = LaunchAtLoginManager(
            service: failingLoginService
        )
        expect(
            (try? failingLoginManager.setEnabled(true)) == nil
                && failingLoginService.registerCalls == 1
                && failingLoginManager.status == .notFound,
            "registration errors must propagate without inventing enabled state"
        )

        var voiceState = VoiceSurfaceReducer()
        let generation = voiceState.begin()
        expect(voiceState.phase == .starting, "begin should enter starting")
        expect(
            voiceState.begin() == generation,
            "duplicate hover starts must be idempotent while active"
        )
        expect(
            !voiceState.apply(generation: generation - 1, phase: .speaking),
            "stale generations must be rejected"
        )
        expect(
            voiceState.apply(generation: generation, phase: .listening),
            "current generation event should apply"
        )
        expect(
            !voiceState.apply(generation: generation, phase: .listening),
            "duplicate phase events must not trigger another surface render"
        )
        expect(
            voiceState.phase.isSessionActive,
            "listening must keep the Realtime session active"
        )
        expect(
            !voiceState.phase.blocksConversationCollapse,
            "listening must allow the conversation panel to collapse"
        )
        expect(
            voiceState.apply(generation: generation, phase: .speaking),
            "current generation should enter speaking"
        )
        expect(
            voiceState.phase.blocksConversationCollapse,
            "speaking must keep the visible reply expanded until audio finishes"
        )
        voiceState.requestStop()
        expect(voiceState.phase == .stopping, "stop should enter stopping")
        expect(
            !voiceState.phase.animatesNotchIndicator,
            "stopping must not animate another processing-dot cycle"
        )
        voiceState.finishStop()
        expect(voiceState.phase == .dormantWake, "terminal stop should resume wake state")

        var assistantOutput = AssistantOutputLifecycle()
        assistantOutput.reset(generation: generation)
        expect(
            assistantOutput.registerNativeFinal(
                generation: generation,
                responseID: "response-a"
            ),
            "a native final response must hold the expanded surface open"
        )
        expect(
            assistantOutput.registerNativeFinal(
                generation: generation,
                responseID: "response-b"
            ),
            "multiple native responses must be tracked independently"
        )
        expect(
            !assistantOutput.finishNativePlayback(
                generation: generation,
                responseID: "response-a"
            ) && assistantOutput.isActive,
            "one drained response must not release another response still playing"
        )
        expect(
            !assistantOutput.finishNativePlayback(
                generation: generation + 1,
                responseID: "response-b"
            ) && assistantOutput.isActive,
            "a stale generation must not release current assistant audio"
        )
        assistantOutput.beginLocalSpeech(generation: generation)
        expect(
            !assistantOutput.finishNativePlayback(
                generation: generation,
                responseID: "response-b"
            ) && assistantOutput.isActive,
            "local speech must continue blocking collapse after native playback drains"
        )
        expect(
            assistantOutput.finishLocalSpeech(generation: generation)
                && !assistantOutput.isActive,
            "the surface may collapse only after every output path finishes"
        )
        expect(
            WakeMonitoringResumePolicy.shouldStart(
                voiceSessionActive: false,
                externalAudioPlaying: false,
                assistantOutputActive: false
            ),
            "wake monitoring should resume only after voice and output are idle"
        )
        expect(
            !WakeMonitoringResumePolicy.shouldStart(
                voiceSessionActive: false,
                externalAudioPlaying: true,
                assistantOutputActive: false
            ),
            "wake monitoring must stay paused while external media is playing"
        )
        expect(
            !WakeMonitoringResumePolicy.shouldStart(
                voiceSessionActive: true,
                externalAudioPlaying: false,
                assistantOutputActive: false
            ),
            "wake monitoring must stay paused during an active voice session"
        )
        expect(
            !WakeMonitoringResumePolicy.shouldStart(
                voiceSessionActive: false,
                externalAudioPlaying: false,
                assistantOutputActive: true
            ),
            "wake monitoring must stay paused until assistant output finishes"
        )
        expect(
            WakeMonitoringResumePolicy.activationDelay >= 1.5,
            "wake monitoring must wait for the Realtime aggregate audio device to settle"
        )
        expect(
            WakeAnalyzerRetryPolicy.shouldRetry(
                stage: .audioEngineStart,
                priorAttempts: 0
            ),
            "a transient CoreAudio handoff failure should retry the modern analyzer once"
        )
        expect(
            !WakeAnalyzerRetryPolicy.shouldRetry(
                stage: .audioEngineStart,
                priorAttempts: 1
            ),
            "the modern analyzer retry must stay bounded"
        )
        expect(
            !WakeAnalyzerRetryPolicy.shouldRetry(
                stage: .analyzerPrepare,
                priorAttempts: 0
            ),
            "non-device analyzer failures should fall back without a blind retry"
        )

        var audioConfirmation = ExternalAudioOutputConfirmation()
        let browserAudio = ExternalAudioPlaybackSnapshot(
            processLabels: ["com.apple.Safari"]
        )
        expect(
            !audioConfirmation.observe(browserAudio),
            "one external output sample must not stop Voice"
        )
        expect(
            audioConfirmation.observe(browserAudio),
            "two sustained samples from the same output process must confirm media"
        )
        audioConfirmation.reset()
        expect(
            !audioConfirmation.observe(
                ExternalAudioPlaybackSnapshot(processLabels: ["short.sound"])
            ) && !audioConfirmation.observe(
                ExternalAudioPlaybackSnapshot(processLabels: [])
            ),
            "a transient output sample must reset instead of confirming media"
        )
        expect(
            !audioConfirmation.observe(
                ExternalAudioPlaybackSnapshot(processLabels: ["first.player"])
            ) && !audioConfirmation.observe(
                ExternalAudioPlaybackSnapshot(processLabels: ["second.player"])
            ),
            "different one-shot output processes must not combine into media"
        )
        expect(
            !ExternalMediaVoiceYieldPolicy.shouldStop(
                mediaConfirmed: false,
                finalPlaybackDrained: true,
                userActivityObserved: false,
                assistantFinalObserved: true,
                phase: .listening
            ),
            "ordinary wake sessions must stay open without confirmed media"
        )
        expect(
            ExternalMediaVoiceYieldPolicy.shouldStop(
                mediaConfirmed: true,
                finalPlaybackDrained: true,
                userActivityObserved: true,
                assistantFinalObserved: true,
                phase: .speaking
            ),
            "confirmed media should yield after final playback drains"
        )
        expect(
            ExternalMediaVoiceYieldPolicy.shouldStop(
                mediaConfirmed: true,
                finalPlaybackDrained: false,
                userActivityObserved: false,
                assistantFinalObserved: false,
                phase: .listening
            ),
            "confirmed media should release an otherwise idle microphone"
        )
        expect(
            !ExternalMediaVoiceYieldPolicy.shouldStop(
                mediaConfirmed: true,
                finalPlaybackDrained: false,
                userActivityObserved: true,
                assistantFinalObserved: false,
                phase: .listening
            ),
            "media detection must not interrupt an active user turn"
        )

        expect(
            SettingsStore.normalizedCodexReasoningEffort("ULTRA") == "ultra",
            "Codex effort normalization must preserve supported upper levels"
        )
        expect(
            SettingsStore.normalizedCodexSandbox("anything") == "inherit",
            "unknown sandbox values must inherit the effective Codex config"
        )
        expect(
            SettingsStore.normalizedCodexApprovalPolicy("anything") == "inherit",
            "unknown approval policies must inherit the effective Codex config"
        )
        expect(
            SettingsStore.supportedRealtimeVoices == [
                "marin",
                "cedar",
                "alloy",
                "ash",
                "ballad",
                "coral",
                "echo",
                "sage",
                "shimmer",
                "verse",
            ]
                && SettingsStore.normalizedRealtimeVoice(" CEDAR ") == "cedar"
                && SettingsStore.normalizedRealtimeVoice("unsupported") == "marin",
            "Realtime voice selection must expose the documented voices and reject unknown identifiers"
        )
        expect(
            SettingsStore.clampedReturnGreetingMinutes(30) == 30,
            "return greeting should preserve the 30-minute default"
        )
        expect(
            SettingsStore.clampedVoiceIdleTimeoutMinutes(0) == 1
                && SettingsStore.clampedVoiceIdleTimeoutMinutes(5) == 5
                && SettingsStore.clampedVoiceIdleTimeoutMinutes(90) == 60,
            "voice inactivity timeout must clamp to the supported 1 to 60 minute range"
        )
        expect(
            SettingsStore.resolvedSpeechLocaleIdentifier(
                "system",
                preferredLanguages: ["sv-SE", "en-SE"]
            ) == "sv-SE",
            "system speech language must resolve from the user's preferred language"
        )
        expect(
            SettingsStore.resolvedSpeechLocaleIdentifier(
                "ko-KR",
                preferredLanguages: ["sv-SE"]
            ) == "ko-KR",
            "a user-selected speech language must override the system language"
        )
        expect(
            AppDisplayLanguage.system.resolved(
                preferredLanguages: ["ko-KR", "en-US"]
            ) == .korean,
            "System UI language must resolve Korean from the preferred language"
        )
        expect(
            AppDisplayLanguage.system.resolved(
                preferredLanguages: ["sv-SE", "en-SE"]
            ) == .english,
            "unsupported System UI languages must use the English interface"
        )
        expect(
            AppDisplayLanguage.parse("ko").resolved(
                preferredLanguages: ["en-US"]
            ) == .korean,
            "an explicit Korean UI override must win over the System language"
        )
        let englishSystemCopy = AppCopy(
            preference: AppDisplayLanguage.system.rawValue,
            preferredLanguages: ["en-US", "ko-KR"]
        )
        expect(
            englishSystemCopy.text(
                "I couldn't complete that request. Please try again.",
                "그 요청만 처리하지 못했어. 다시 말해줘"
            ) == "I couldn't complete that request. Please try again.",
            "turn failures must follow the current System display language"
        )
        expect(
            ManualPairingCode.normalized("PB4F-9BR9") == "PB4F-9BR9"
                && ManualPairingCode.normalized("pb4f9br9") == "PB4F-9BR9"
                && ManualPairingCode.normalized("AA1A-1AA1")
                    == "AA1A-1AA1"
                && ManualPairingCode.normalized("short") == nil,
            "pairing codes must accept ChatGPT's XXXX-XXXX paste format and normalize compact input"
        )
        expect(
            AppAppearanceMode.parse("dark").resolvesDark(systemIsDark: false)
                && !AppAppearanceMode.parse("light").resolvesDark(systemIsDark: true)
                && AppAppearanceMode.system.resolvesDark(systemIsDark: true),
            "System, Light, and Dark appearance modes must resolve deterministically"
        )
        expect(
            SettingsStore.resolvedSpeechLocaleIdentifiers(
                ["ko-KR", ""],
                preferredLanguages: ["sv-SE"]
            ) == ["ko-KR"],
            "a disabled secondary language must not silently add the system recognizer"
        )
        expect(
            SettingsStore.resolvedSpeechLocaleIdentifiers(
                ["system", "ko-KR", "en-US", "sv-SE", "de-DE"],
                preferredLanguages: ["sv-SE"]
            ) == ["sv-SE", "ko-KR", "en-US", "de-DE"],
            "system primary plus up to three distinct additional languages must remain multilingual"
        )
        expect(
            SettingsStore.realtimeLanguageHint(
                "ko-KR",
                preferredLanguages: ["sv-SE"]
            ) == "ko",
            "Realtime transcription must receive an ISO-639-1 primary language hint"
        )
        expect(
            SettingsStore.normalizedAdditionalSpeechLocales(
                ["en-US", "sv-SE", "de-DE", "fr-FR"],
                primary: "ko-KR"
            ) == ["en-US", "sv-SE", "de-DE"],
            "settings must retain at most three additional recognition languages"
        )
        expect(
            WakePhrasePolicy.match("Relay, open my task")?.command == "open my task",
            "English Relay wake phrase should be supported"
        )
        expect(
            WakePhrasePolicy.match("Hey Relay 뭐해")?.command == "뭐해",
            "Hey Relay should support mixed-language commands"
        )
        expect(
            WakePhrasePolicy.match(
                "Computer, status",
                phrases: ["Computer"]
            )?.command == "status",
            "a user-defined wake phrase should preserve its command"
        )
        expect(
            WakePhrasePolicy.match(
                "A+B, status",
                phrases: ["A+B"]
            )?.command == "status",
            "wake phrases containing regex metacharacters must be matched literally"
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-relay-authority-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        expect(
            (try? SettingsStore.validatedCodexWorkspacePath("")) == nil,
            "Codex workspace must never fall back to the launch directory"
        )
        expect(
            (try? SettingsStore.validatedCodexWorkspacePath("relative/workspace")) == nil,
            "Codex workspace must be an absolute path"
        )
        expect(
            (try? SettingsStore.validatedCodexWorkspacePath(temporaryRoot.path))
                == temporaryRoot.standardizedFileURL.path,
            "an absolute existing Codex workspace should validate"
        )

        let defaultsSuite = "VoiceRelay.PolicyTests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: defaultsSuite)!
        isolatedDefaults.removePersistentDomain(forName: defaultsSuite)
        defer { isolatedDefaults.removePersistentDomain(forName: defaultsSuite) }
        let isolatedStore = SettingsStore(
            defaults: isolatedDefaults,
            threadBindingLockURL: temporaryRoot.appendingPathComponent("dedicated-thread.lock")
        )
        expect(
            !isolatedStore.codexAppConnectionCompleted,
            "a fresh install must not assume the Codex app Remote is paired"
        )
        expect(
            !isolatedStore.load().hoverStartsVoice,
            "hover must not start Voice on a fresh install"
        )
        expect(
            isolatedStore.load().overlayAnchor == .automatic
                && isolatedStore.load().voiceIdleTimeoutMinutes == 5
                && !isolatedStore.completedFirstVoiceGreeting,
            "fresh installs must default to Automatic display selection and a 5-minute idle timeout"
        )
        expect(
            isolatedStore.load().productName == "Voice Relay"
                && isolatedStore.load().assistantName == "Relay"
                && isolatedStore.load().appDisplayLanguage == "system"
                && isolatedStore.load().appearanceMode == "system"
                && isolatedStore.load().wakePhrases
                    == ["Relay", "Hey Relay"],
            "fresh installs must use the Voice Relay identity defaults"
        )
        expect(
            isolatedStore.load().codexWorkspacePath
                == SettingsStore.defaultCodexWorkspaceURL.path
                && isolatedStore.load().codexWorkspacePath
                    != FileManager.default.homeDirectoryForCurrentUser.path,
            "fresh installs must use an app-owned workspace instead of the user's home directory"
        )
        expect(
            isolatedStore.load().preferModernSpeechAnalyzer,
            "fresh installs must prefer the latest SpeechAnalyzer when the runtime can support every selected language"
        )
        isolatedDefaults.set(8, forKey: "voiceRelay.settings.schemaVersion")
        isolatedDefaults.set(true, forKey: "voiceRelay.voice.hoverStarts")
        expect(
            !isolatedStore.load().hoverStartsVoice,
            "older hover-to-start preferences must migrate to explicit activation"
        )
        isolatedStore.codexAppConnectionCompleted = true
        expect(
            isolatedStore.codexAppConnectionCompleted,
            "onboarding must persist only the completed app connection marker"
        )
        try! isolatedStore.setManagedCodexThreadID("thread-managed-by-voice-relay")
        expect(
            isolatedStore.load().codexThreadSource == "app",
            "an app-created Codex task should persist with app source"
        )
        try! isolatedStore.setManagedCodexThreadID("\n")
        expect(
            isolatedStore.load().codexThreadID.isEmpty,
            "clearing the managed task should force a new app-owned task"
        )
        var explicitSettings = AppSettings.defaults
        explicitSettings.codexWorkspacePath = temporaryRoot.path
        explicitSettings.codexThreadID = "11111111-1111-4111-8111-111111111111"
        explicitSettings.codexThreadSource = "user"
        explicitSettings.hoverStartsVoice = false
        explicitSettings.wakePhrases = ["Computer", "computer", "A+B"]
        explicitSettings.speechLocale = "ko-KR"
        explicitSettings.additionalSpeechLocales = ["en-US", "sv-SE", "de-DE"]
        explicitSettings.preferModernSpeechAnalyzer = false
        explicitSettings.voiceIdleTimeoutMinutes = 15
        explicitSettings.realtimeInstructions = "Use a short custom greeting."
        explicitSettings.productName = "  Orbit  "
        explicitSettings.assistantName = "  Nova  "
        explicitSettings.userDisplayName = "  John  "
        explicitSettings.appDisplayLanguage = "ko"
        explicitSettings.appearanceMode = "dark"
        try! isolatedStore.save(explicitSettings)
        let savedVoiceSettings = isolatedStore.load()
        expect(
            savedVoiceSettings.productName == "Orbit"
                && savedVoiceSettings.assistantName == "Nova"
                && savedVoiceSettings.userDisplayName == "John"
                && savedVoiceSettings.appDisplayLanguage == "ko"
                && savedVoiceSettings.appearanceMode == "dark",
            "product, user, assistant, UI language, and appearance settings must round-trip"
        )
        expect(
            savedVoiceSettings.wakePhrases == ["Computer", "A+B"],
            "wake phrases must be deduplicated while preserving user spelling"
        )
        expect(
            savedVoiceSettings.additionalSpeechLocales
                == ["en-US", "sv-SE", "de-DE"],
            "up to three additional speech-recognition languages must round-trip"
        )
        expect(
            !savedVoiceSettings.preferModernSpeechAnalyzer,
            "the user-facing SpeechAnalyzer preference must round-trip"
        )
        expect(
            savedVoiceSettings.voiceIdleTimeoutMinutes == 15,
            "the configurable voice inactivity timeout must round-trip"
        )
        expect(
            SettingsStore.defaultRealtimeInstructions.range(
                of: "[가-힣]",
                options: .regularExpression
            ) == nil,
            "the public default Realtime prompt must remain English-only"
        )
        expect(
            savedVoiceSettings.realtimeInstructions == "Use a short custom greeting.",
            "the user-editable Realtime prompt must round-trip"
        )
        expect(
            isolatedStore.load().codexThreadSource == "user",
            "an explicitly pasted task should persist with user source"
        )
        expect(
            isolatedStore.load().codexThreadID
                == "11111111-1111-4111-8111-111111111111",
            "Voice Relay must keep its dedicated task binding until the user or app changes it"
        )
        isolatedStore.onboardingCompleted = true
        isolatedStore.codexAppConnectionCompleted = true
        isolatedStore.completedFirstVoiceGreeting = true
        try! isolatedStore.resetToDefaults()
        expect(
            isolatedStore.load().codexThreadID.isEmpty,
            "Reset must clear the local task binding"
        )
        expect(
            isolatedStore.load().wakePhrases == SettingsStore.defaultWakePhrases
                && isolatedStore.load().additionalSpeechLocales.isEmpty
                && isolatedStore.load().preferModernSpeechAnalyzer
                && isolatedStore.load().voiceIdleTimeoutMinutes == 5,
            "Reset must restore wake phrases, the latest recognizer preference, languages, and the 5-minute idle timeout"
        )
        expect(
            isolatedStore.load().realtimeInstructions
                == SettingsStore.defaultRealtimeInstructions,
            "Reset must restore the default Realtime prompt"
        )
        expect(
            isolatedStore.load().productName == AppSettings.defaults.productName
                && isolatedStore.load().assistantName == AppSettings.defaults.assistantName,
            "Reset must restore the default product and assistant identities"
        )
        expect(
            !isolatedStore.onboardingCompleted
                && !isolatedStore.codexAppConnectionCompleted
                && !isolatedStore.completedFirstVoiceGreeting,
            "Reset must return the app to onboarding and unpaired local state"
        )

        let authorityRoot = temporaryRoot.appendingPathComponent(
            "public-authority-pack",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: authorityRoot,
            withIntermediateDirectories: true
        )
        for filename in SettingsStore.authorityPackFiles {
            let contents = "# \(filename)\nSynthetic public test guidance.\n"
            try! contents.write(
                to: authorityRoot.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }
        let authoritySuite = "VoiceRelay.AuthorityTests.\(UUID().uuidString)"
        let authorityDefaults = UserDefaults(suiteName: authoritySuite)!
        authorityDefaults.removePersistentDomain(forName: authoritySuite)
        defer {
            authorityDefaults.removePersistentDomain(forName: authoritySuite)
        }
        let authorityStore = SettingsStore(
            defaults: authorityDefaults,
            threadBindingLockURL:
                temporaryRoot.appendingPathComponent("authority-thread.lock")
        )
        expect(
            !authorityStore.load().includeAuthorityPack
                && authorityStore.load().authorityPackRoot.isEmpty
                && authorityStore.load().authorityPackFingerprint.isEmpty,
            "fresh installs must keep Authority Pack disabled and blank"
        )
        var authoritySettings = authorityStore.load()
        authoritySettings.codexWorkspacePath = temporaryRoot.path
        authoritySettings.includeAuthorityPack = true
        authoritySettings.authorityPackRoot = authorityRoot.path
        try! authorityStore.save(authoritySettings)
        let savedAuthority = authorityStore.load()
        expect(
            savedAuthority.authorityPackFingerprint.count == 64,
            "a valid Authority Pack must persist a SHA-256 content fingerprint"
        )
        let authoritySnapshot = try! AuthorityPackComposer.snapshot(
            from: authorityRoot.path
        )
        expect(
            authoritySnapshot.context.count == 1
                && authoritySnapshot.context[
                    AuthorityPackComposer.contextKey
                ]?["kind"] == "application",
            "Authority Pack must compose one deterministic rendered block"
        )
        let renderedAuthority = authoritySnapshot.context[
            AuthorityPackComposer.contextKey
        ]?["value"] ?? ""
        expect(
            renderedAuthority.components(
                separatedBy: "# Voice Relay Authority Pack"
            ).count == 2
                && renderedAuthority.contains("## AGENTS.md")
                && !renderedAuthority.contains("## AGENTS.md\n\n# AGENTS.md"),
            "Authority Pack Markdown must have one title and no duplicated file heading"
        )
        expect(
            authoritySnapshot.context.values.allSatisfy { entry in
                !(entry["value"] ?? "").contains(authorityRoot.path)
            },
            "Authority Pack context must never reveal the selected local path"
        )
        try! authorityStore.setManagedCodexThreadID(
            "22222222-2222-4222-8222-222222222222"
        )
        try! "# AGENTS.md\nChanged test guidance.\n".write(
            to: authorityRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        let changedManagedPack = authorityStore.load()
        try! authorityStore.save(changedManagedPack)
        expect(
            authorityStore.load().codexThreadID.isEmpty,
            "changing Authority Pack content must rotate an app-managed dedicated session"
        )
        var userSelectedSession = authorityStore.load()
        userSelectedSession.codexThreadID =
            "33333333-3333-4333-8333-333333333333"
        userSelectedSession.codexThreadSource = "user"
        try! authorityStore.save(userSelectedSession)
        try! "# SOUL.md\nChanged again.\n".write(
            to: authorityRoot.appendingPathComponent("SOUL.md"),
            atomically: true,
            encoding: .utf8
        )
        let changedUserPack = authorityStore.load()
        expect(
            (try? authorityStore.save(changedUserPack)) == nil,
            "changing Authority Pack content must require clearing a user-selected Session ID"
        )
        try! authorityStore.resetToDefaults()
        expect(
            !authorityStore.load().includeAuthorityPack
                && authorityStore.load().authorityPackRoot.isEmpty
                && authorityStore.load().authorityPackFingerprint.isEmpty
                && !authorityStore.load().includeAdditionalContextProviders
                && authorityStore.load().additionalContextProvidersRoot.isEmpty,
            "Reset must clear Authority Pack and Additional Context Provider state"
        )

        print("Voice Relay policy tests passed")
    }
}
