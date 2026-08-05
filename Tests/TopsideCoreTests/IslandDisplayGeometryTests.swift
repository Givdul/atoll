import CoreGraphics
import XCTest
@testable import TopsideCore

final class IslandDisplayGeometryTests: XCTestCase {
    func testPhysicalNotchUsesNativeSafeAreaAndAuxiliaryGap() throws {
        let notch = try XCTUnwrap(PhysicalNotchGeometry(
            safeAreaTop: 32,
            auxiliaryLeftMaxX: 663,
            auxiliaryRightMinX: 848
        ))
        let geometry = IslandDisplayGeometry(notch: notch)

        XCTAssertEqual(notch.width, 185)
        XCTAssertEqual(notch.height, 32)
        XCTAssertEqual(notch.centerX, 755.5)
        XCTAssertEqual(geometry.provenance, .physical)
        XCTAssertEqual(geometry.width, 185)
        XCTAssertEqual(geometry.height, 32)
        XCTAssertEqual(geometry.centerX, 755.5)
    }

    func testFallbackDisplayGeometryIsCenteredAndStable() {
        let geometry = IslandDisplayGeometry(fallbackFrame: CGRect(x: 100, y: 20, width: 500, height: 300))

        XCTAssertEqual(geometry.provenance, .virtual)
        XCTAssertEqual(geometry.width, 185)
        XCTAssertEqual(geometry.height, 32)
        XCTAssertEqual(geometry.centerX, 350)
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
