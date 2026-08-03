import CoreGraphics

public struct PhysicalNotchGeometry: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let centerX: CGFloat

    public init?(
        safeAreaTop: CGFloat,
        auxiliaryLeftMaxX: CGFloat?,
        auxiliaryRightMinX: CGFloat?
    ) {
        guard safeAreaTop > 0,
              let auxiliaryLeftMaxX,
              let auxiliaryRightMinX,
              auxiliaryRightMinX > auxiliaryLeftMaxX else {
            return nil
        }

        self.width = auxiliaryRightMinX - auxiliaryLeftMaxX
        self.height = safeAreaTop
        self.centerX = (auxiliaryLeftMaxX + auxiliaryRightMinX) / 2
    }
}

public struct IslandDisplayGeometry: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let centerX: CGFloat
    public let scaleHeight: CGFloat

    public init(notch: PhysicalNotchGeometry) {
        width = notch.width + 4
        height = notch.height + 3
        centerX = notch.centerX
        scaleHeight = notch.height
    }

    public init(fallbackFrame: CGRect) {
        width = 189
        height = 35
        centerX = fallbackFrame.midX
        scaleHeight = 32
    }
}

public enum ScreenTargetResolver {
    public static func index(
        screenMode: String,
        screenFrames: [CGRect],
        pointerLocation: CGPoint
    ) -> Int? {
        guard !screenFrames.isEmpty else {
            return nil
        }

        if screenMode == "active" {
            return screenFrames.firstIndex { $0.contains(pointerLocation) } ?? 0
        }

        if let selectedIndex = Int(screenMode), selectedIndex > 0,
           screenFrames.indices.contains(selectedIndex - 1) {
            return selectedIndex - 1
        }

        return 0
    }
}
