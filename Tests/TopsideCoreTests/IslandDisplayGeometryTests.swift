import CoreGraphics
import XCTest
@testable import TopsideCore

final class IslandDisplayGeometryTests: XCTestCase {
    func testPhysicalNotchUsesNativeSafeAreaAndAuxiliaryGap() {
        let notch = PhysicalNotchGeometry(
            safeAreaTop: 32,
            auxiliaryLeftMaxX: 663,
            auxiliaryRightMinX: 848
        )

        XCTAssertEqual(notch?.width, 185)
        XCTAssertEqual(notch?.height, 32)
        XCTAssertEqual(notch?.centerX, 755.5)
    }

    func testPhysicalNotchRejectsMenuBarOnlyGeometry() {
        XCTAssertNil(PhysicalNotchGeometry(
            safeAreaTop: 0,
            auxiliaryLeftMaxX: nil,
            auxiliaryRightMinX: nil
        ))
        XCTAssertNil(PhysicalNotchGeometry(
            safeAreaTop: 32,
            auxiliaryLeftMaxX: 700,
            auxiliaryRightMinX: nil
        ))
        XCTAssertNil(PhysicalNotchGeometry(
            safeAreaTop: 32,
            auxiliaryLeftMaxX: 848,
            auxiliaryRightMinX: 663
        ))
    }

    func testScreenTargetResolverUsesPrimarySelectedAndFallbackScreens() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100)
        ]

        XCTAssertEqual(ScreenTargetResolver.index(screenMode: "primary", screenFrames: frames, pointerLocation: .zero), 0)
        XCTAssertEqual(ScreenTargetResolver.index(screenMode: "2", screenFrames: frames, pointerLocation: .zero), 1)
        XCTAssertEqual(ScreenTargetResolver.index(screenMode: "3", screenFrames: frames, pointerLocation: .zero), 0)
        XCTAssertEqual(ScreenTargetResolver.index(screenMode: String(Int.min), screenFrames: frames, pointerLocation: .zero), 0)
    }

    func testActiveScreenTargetFollowsPointerAndSurvivesDisconnect() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100)
        ]

        XCTAssertEqual(ScreenTargetResolver.index(
            screenMode: "active",
            screenFrames: frames,
            pointerLocation: CGPoint(x: 150, y: 50)
        ), 1)
        XCTAssertEqual(ScreenTargetResolver.index(
            screenMode: "active",
            screenFrames: [frames[0]],
            pointerLocation: CGPoint(x: 150, y: 50)
        ), 0)
        XCTAssertNil(ScreenTargetResolver.index(screenMode: "active", screenFrames: [], pointerLocation: .zero))
    }
}
