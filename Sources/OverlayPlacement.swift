import Cocoa

enum OverlayAnchor: String, CaseIterable, Equatable {
    case automatic
    case notch
    case orb

    static func parse(_ value: String?) -> OverlayAnchor {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "notch":
            return .notch
        case "orb", "floating":
            return .orb
        case "automatic", "auto", nil, "":
            return .automatic
        default:
            return .automatic
        }
    }
}

enum CompactIndicatorGeometry {
    static let viewWidth: CGFloat = 20
    static let viewHeight: CGFloat = 22
    static let dotDiameter: CGFloat = 3
    static let dotSpacing: CGFloat = 2
    static let notchGap: CGFloat = 1

    static var dotContentWidth: CGFloat {
        dotDiameter * 3 + dotSpacing * 2
    }

    static func centerX(
        windowWidth: CGFloat,
        notchWidth: CGFloat
    ) -> CGFloat {
        let leftNotchEdge = max(0, (windowWidth - notchWidth) / 2)
        return leftNotchEdge - notchGap - dotContentWidth / 2
    }

    static func visualBounds(
        windowWidth: CGFloat,
        notchWidth: CGFloat
    ) -> ClosedRange<CGFloat> {
        let viewCenter = centerX(
            windowWidth: windowWidth,
            notchWidth: notchWidth
        )
        let viewLeading = viewCenter - viewWidth / 2
        let dotLeading = viewLeading + (viewWidth - dotContentWidth) / 2
        return dotLeading ... (dotLeading + dotContentWidth)
    }
}

enum NotchActivityGeometry {
    static let fontSize: CGFloat = 12
    static let horizontalPadding: CGFloat = 48
    static let minimumHorizontalGrowth: CGFloat = 36
    static let notchWidthGrowthRatio: CGFloat = 0.16
    static let headerVerticalInsets: CGFloat = 8
    static let fallbackNotchHeight: CGFloat = 28
    static let labelBottomPadding: CGFloat = 8

    static var font: NSFont {
        .systemFont(ofSize: fontSize, weight: .semibold)
    }

    static var labelLineHeight: CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func notchBodyHeight(safeTopInset: CGFloat) -> CGFloat {
        max(fallbackNotchHeight, safeTopInset)
    }

    static func labelTopInset(safeTopInset: CGFloat) -> CGFloat {
        notchBodyHeight(safeTopInset: safeTopInset)
    }
}

enum NotchAnswerGeometry {
    static let maximumBodyHeight: CGFloat = 220
    static let connectionOverlap: CGFloat = 12
    static let scrollerTerminalInset: CGFloat = 6

    static func maximumSurfaceHeight(headerHeight: CGFloat) -> CGFloat {
        headerHeight - connectionOverlap + maximumBodyHeight
    }
}

struct DisplayGeometry: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
    let safeTopInset: CGFloat
    let auxiliaryTopLeftArea: NSRect?
    let auxiliaryTopRightArea: NSRect?

    init(
        frame: NSRect,
        visibleFrame: NSRect,
        safeTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTopInset = safeTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen?) {
        let fallbackFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let screen else {
            self.init(
                frame: fallbackFrame,
                visibleFrame: fallbackFrame,
                safeTopInset: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
            return
        }
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    static func preferredScreen(for preference: OverlayAnchor) -> NSScreen? {
        let screens = NSScreen.screens
        if preference != .orb,
           screens.count == 1,
           let onlyScreen = screens.first,
           DisplayGeometry(screen: onlyScreen).hasHardwareNotch {
            return onlyScreen
        }
        return NSScreen.main ?? screens.first
    }

    var hardwareNotchSpan: ClosedRange<CGFloat>? {
        guard safeTopInset > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              right.minX > left.maxX else {
            return nil
        }
        return left.maxX ... right.minX
    }

    var hasHardwareNotch: Bool {
        hardwareNotchSpan != nil
    }

    var hardwareNotchWidth: CGFloat {
        guard let span = hardwareNotchSpan else { return 0 }
        return span.upperBound - span.lowerBound
    }

    func resolvedAnchor(for preference: OverlayAnchor) -> OverlayAnchor {
        switch preference {
        case .automatic:
            return hasHardwareNotch ? .notch : .orb
        case .notch:
            return .notch
        case .orb:
            return .orb
        }
    }

    func compactWidth(for anchor: OverlayAnchor) -> CGFloat {
        switch resolvedAnchor(for: anchor) {
        case .orb:
            return 54
        case .notch:
            let physicalWidth = hasHardwareNotch ? hardwareNotchWidth : 210
            let desired = max(220, physicalWidth + 40)
            return min(desired, max(220, frame.width - 80))
        case .automatic:
            return 54
        }
    }

    func activeWidth(
        for anchor: OverlayAnchor,
        activityLabelWidth _: CGFloat = 0
    ) -> CGFloat {
        switch resolvedAnchor(for: anchor) {
        case .notch:
            let compact = compactWidth(for: anchor)
            let physicalWidth = hasHardwareNotch ? hardwareNotchWidth : 210
            let balancedGrowth = max(
                NotchActivityGeometry.minimumHorizontalGrowth,
                ceil(physicalWidth * NotchActivityGeometry.notchWidthGrowthRatio)
            )
            let active = compact + balancedGrowth
            return min(active, max(compact, frame.width - 80))
        case .orb, .automatic:
            return compactWidth(for: anchor)
        }
    }

    func activeHeight(for anchor: OverlayAnchor) -> CGFloat {
        switch resolvedAnchor(for: anchor) {
        case .notch:
            return ceil(max(
                compactHeight(for: anchor) + 20,
                NotchActivityGeometry.headerVerticalInsets
                    + NotchActivityGeometry.notchBodyHeight(
                        safeTopInset: safeTopInset
                    )
                    + NotchActivityGeometry.labelLineHeight
                    + NotchActivityGeometry.labelBottomPadding
            ))
        case .orb, .automatic:
            return compactHeight(for: anchor)
        }
    }

    func compactHeight(for anchor: OverlayAnchor) -> CGFloat {
        switch resolvedAnchor(for: anchor) {
        case .orb:
            return 54
        case .notch:
            return OverlayPlacement.topBandHeight(
                screenFrame: frame,
                visibleFrame: visibleFrame,
                fallback: NSStatusBar.system.thickness
            )
        case .automatic:
            return 54
        }
    }

    func expandedWidth(for anchor: OverlayAnchor) -> CGFloat {
        switch resolvedAnchor(for: anchor) {
        case .orb:
            return min(max(frame.width * 0.34, 480), 600)
        case .notch:
            return activeWidth(for: anchor)
        case .automatic:
            return min(max(frame.width * 0.34, 480), 600)
        }
    }

    func surfaceWidth(
        for anchor: OverlayAnchor,
        answerVisible: Bool,
        activityVisible: Bool,
        activityLabelWidth: CGFloat = 0
    ) -> CGFloat {
        if answerVisible {
            return expandedWidth(for: anchor)
        }
        if activityVisible {
            return activeWidth(
                for: anchor,
                activityLabelWidth: activityLabelWidth
            )
        }
        return compactWidth(for: anchor)
    }

}

struct OverlayPlacement {
    static func topBandHeight(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        fallback: CGFloat
    ) -> CGFloat {
        let reservedHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        return max(reservedHeight, fallback)
    }

    static func frame(
        display: DisplayGeometry,
        width: CGFloat,
        height: CGFloat,
        anchor: OverlayAnchor,
        savedTopLeft: NSPoint? = nil
    ) -> NSRect {
        let resolved = display.resolvedAnchor(for: anchor)
        switch resolved {
        case .notch:
            return NSRect(
                x: display.frame.midX - width / 2,
                y: display.frame.maxY - height,
                width: width,
                height: height
            )
        case .orb:
            if let savedTopLeft {
                let minX = max(
                    display.visibleFrame.minX + 8,
                    min(savedTopLeft.x, display.visibleFrame.maxX - width - 8)
                )
                let maxY = max(
                    display.visibleFrame.minY + height + 8,
                    min(savedTopLeft.y, display.visibleFrame.maxY - 8)
                )
                return NSRect(x: minX, y: maxY - height, width: width, height: height)
            }
            return NSRect(
                x: display.visibleFrame.midX - width / 2,
                y: display.visibleFrame.maxY - height - 12,
                width: width,
                height: height
            )
        case .automatic:
            return .zero
        }
    }
}
