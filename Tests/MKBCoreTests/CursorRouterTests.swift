import XCTest
@testable import MKBCore

final class CursorRouterTests: XCTestCase {
    // a (local, 1440x900) | b (1920x1080) | c (1280x800), all top-aligned.
    func makeRouter() -> CursorRouter {
        let devices = [
            DeviceGeometry(id: "a", displays: [VRect(x: 0, y: 0, width: 1440, height: 900)]),
            DeviceGeometry(id: "b", displays: [VRect(x: 0, y: 0, width: 1920, height: 1080)]),
            DeviceGeometry(id: "c", displays: [VRect(x: 0, y: 0, width: 1280, height: 800)]),
        ]
        return CursorRouter(localID: "a", desktop: VirtualDesktop(devices: devices, layout: SpaceLayout()))
    }

    func testNoHandoffAwayFromEdge() {
        let r = makeRouter()
        XCTAssertEqual(r.localMove(location: VPoint(700, 400), delta: VPoint(30, 0)), .none)
        XCTAssertFalse(r.isRemote)
    }

    func testNoHandoffAtEdgeWithoutNeighbour() {
        let r = makeRouter()
        XCTAssertEqual(r.localMove(location: VPoint(0, 400), delta: VPoint(-10, 0)), .none)
        XCTAssertEqual(r.localMove(location: VPoint(700, 0), delta: VPoint(0, -10)), .none)
    }

    func testEnterRightNeighbour() {
        let r = makeRouter()
        let action = r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0))
        XCTAssertEqual(action, .enter(device: "b", at: VPoint(4, 400)))
        XCTAssertTrue(r.isRemote)
        XCTAssertEqual(r.lastLocalExit, VPoint(1439, 400))
    }

    func testRemoteMoveTransferAndReturn() {
        let r = makeRouter()
        _ = r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0))
        XCTAssertEqual(r.remoteMove(delta: VPoint(100, 10)), .move(device: "b", to: VPoint(104, 410)))
        // Run right across b into c.
        XCTAssertEqual(r.remoteMove(delta: VPoint(1820, 0)), .transfer(from: "b", to: "c", at: VPoint(4, 410)))
        // Back left across b, then into a.
        XCTAssertEqual(r.remoteMove(delta: VPoint(-10, 0)), .transfer(from: "c", to: "b", at: VPoint(1914, 410)))
        XCTAssertEqual(r.remoteMove(delta: VPoint(-1915, 0)), .returnLocal(at: VPoint(1439, 410)))
        XCTAssertFalse(r.isRemote)
    }

    func testRemoteClampsAtOuterEdges() {
        let r = makeRouter()
        _ = r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0))
        XCTAssertEqual(r.remoteMove(delta: VPoint(0, 5000)), .move(device: "b", to: VPoint(4, 1079)))
        XCTAssertEqual(r.remoteMove(delta: VPoint(0, 50)), .none)
    }

    func testReturningBelowShorterLocalScreenClamps() {
        let r = makeRouter()
        _ = r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0))
        _ = r.remoteMove(delta: VPoint(0, 600)) // y = 1000, below a's 900 height
        // Pushing left at y=1000 cannot enter a (no display there) so it stays clamped on b.
        XCTAssertEqual(r.remoteMove(delta: VPoint(-50, 0)), .move(device: "b", to: VPoint(0, 1000)))
        XCTAssertTrue(r.isRemote)
    }

    func testBlockedDeviceIsSkipped() {
        let r = makeRouter()
        r.isBlocked = { $0 == "b" }
        XCTAssertEqual(r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0)), .none)
        XCTAssertFalse(r.isRemote)
    }

    func testForceLocalReturnsToExitPoint() {
        let r = makeRouter()
        _ = r.localMove(location: VPoint(1439, 300), delta: VPoint(5, 0))
        _ = r.remoteMove(delta: VPoint(500, 0))
        XCTAssertEqual(r.forceLocal(), .returnLocal(at: VPoint(1439, 300)))
        XCTAssertFalse(r.isRemote)
        XCTAssertEqual(r.forceLocal(), .none)
    }

    func testDeviceVanishingReturnsLocal() {
        let r = makeRouter()
        _ = r.localMove(location: VPoint(1439, 300), delta: VPoint(5, 0))
        let remaining = VirtualDesktop(devices: [DeviceGeometry(id: "a", displays: [VRect(x: 0, y: 0, width: 1440, height: 900)])], layout: SpaceLayout())
        XCTAssertEqual(r.update(desktop: remaining), .returnLocal(at: VPoint(1439, 300)))
    }

    func testSmallGapIsJumped() {
        let devices = [
            DeviceGeometry(id: "a", displays: [VRect(x: 0, y: 0, width: 1440, height: 900)]),
            DeviceGeometry(id: "b", displays: [VRect(x: 0, y: 0, width: 1920, height: 1080)]),
        ]
        let layout = SpaceLayout(origins: ["a": VPoint(0, 0), "b": VPoint(1445, 0)])
        let r = CursorRouter(localID: "a", desktop: VirtualDesktop(devices: devices, layout: layout))
        XCTAssertEqual(r.localMove(location: VPoint(1439, 100), delta: VPoint(2, 0)), .enter(device: "b", at: VPoint(0, 100)))
    }

    func testVerticalNeighbour() {
        let devices = [
            DeviceGeometry(id: "a", displays: [VRect(x: 0, y: 0, width: 1440, height: 900)]),
            DeviceGeometry(id: "b", displays: [VRect(x: 0, y: 0, width: 1920, height: 1080)]),
        ]
        let layout = SpaceLayout(origins: ["a": VPoint(0, 1080), "b": VPoint(0, 0)])
        let r = CursorRouter(localID: "a", desktop: VirtualDesktop(devices: devices, layout: layout))
        XCTAssertEqual(r.localMove(location: VPoint(200, 0), delta: VPoint(0, -4)), .enter(device: "b", at: VPoint(200, 1076)))
    }

    func testTransitionsLockedKeepsCursorOnActiveDevice() {
        let r = makeRouter()
        r.transitionsLocked = true
        XCTAssertEqual(r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0)), .none)
        r.transitionsLocked = false
        _ = r.localMove(location: VPoint(1439, 400), delta: VPoint(5, 0))
        r.transitionsLocked = true
        // A big jerk back towards a would normally return home; locked, it clamps on b.
        XCTAssertEqual(r.remoteMove(delta: VPoint(-720, 0)), .move(device: "b", to: VPoint(0, 400)))
        XCTAssertTrue(r.isRemote)
        r.transitionsLocked = false
        XCTAssertEqual(r.remoteMove(delta: VPoint(-5, 0)), .returnLocal(at: VPoint(1435, 400)))
    }
}
