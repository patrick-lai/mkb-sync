import XCTest
@testable import MKBCore

final class LayoutTests: XCTestCase {
    let laptop = DeviceGeometry(id: "a", displays: [VRect(x: 0, y: 0, width: 1440, height: 900)])
    let desktop = DeviceGeometry(id: "b", displays: [
        VRect(x: 0, y: 0, width: 2560, height: 1440),
        VRect(x: -1920, y: 0, width: 1920, height: 1080),
    ])

    func testAutoPlacementIsDeterministicLeftToRight() {
        let d = VirtualDesktop(devices: [desktop, laptop], layout: SpaceLayout())
        XCTAssertEqual(d.origins["a"], VPoint(0, 0))
        XCTAssertEqual(d.origins["b"], VPoint(1440, 0))
        // Device b's leftmost display starts right at a's right edge.
        XCTAssertEqual(d.virtualBounds("b"), VRect(x: 1440, y: 0, width: 4480, height: 1440))
    }

    func testStoredOriginsWinAndNewDevicesAppendToTheRight() {
        let layout = SpaceLayout(origins: ["b": VPoint(-4480, 100)], version: 3, author: "x")
        let d = VirtualDesktop(devices: [desktop, laptop], layout: layout)
        XCTAssertEqual(d.origins["b"], VPoint(-4480, 100))
        XCTAssertEqual(d.origins["a"], VPoint(0, 100))
    }

    func testCoordinateConversionRoundTrips() {
        let d = VirtualDesktop(devices: [desktop, laptop], layout: SpaceLayout())
        let local = VPoint(-100, 50) // on b's secondary display
        let v = d.toVirtual(local, from: "b")
        XCTAssertEqual(v, VPoint(1440 + 1820, 50))
        XCTAssertEqual(d.toLocal(v, on: "b"), local)
        XCTAssertEqual(d.device(at: v), "b")
    }

    func testClampPicksNearestDisplay() {
        let d = VirtualDesktop(devices: [desktop], layout: SpaceLayout())
        // Below the shorter secondary display (height 1080) on b.
        let p = d.clamp(VPoint(100, 1200), to: "b")
        XCTAssertEqual(p, VPoint(100, 1079))
    }

    func testLayoutSupersedes() {
        let a = SpaceLayout(version: 2, author: "a")
        let b = SpaceLayout(version: 2, author: "b")
        let c = SpaceLayout(version: 3, author: "a")
        XCTAssertTrue(b.supersedes(a))
        XCTAssertFalse(a.supersedes(b))
        XCTAssertTrue(c.supersedes(b))
    }

    func testPinnedLayoutBumpsVersion() {
        let d = VirtualDesktop(devices: [desktop, laptop], layout: SpaceLayout(version: 4, author: "z"))
        let pinned = d.pinnedLayout(base: SpaceLayout(version: 4, author: "z"), overrides: ["a": VPoint(5, 5)], author: "me")
        XCTAssertEqual(pinned.version, 5)
        XCTAssertEqual(pinned.author, "me")
        XCTAssertEqual(pinned.origins["a"], VPoint(5, 5))
        XCTAssertEqual(pinned.origins["b"], VPoint(1440, 0))
    }

    func testSnapAttachesToNeighbourEdge() {
        let fixed = VRect(x: 0, y: 0, width: 1000, height: 800)
        let moving = VRect(x: 1020, y: 30, width: 500, height: 400)
        let snapped = LayoutMath.snap(moving, others: [fixed], threshold: 40)
        XCTAssertEqual(snapped.minX, 1000)
        XCTAssertEqual(snapped.minY, 0)
        XCTAssertTrue(LayoutMath.isAdjacent(snapped, to: [fixed]))
    }

    func testSnapResolvesOverlap() {
        let fixed = VRect(x: 0, y: 0, width: 1000, height: 800)
        let moving = VRect(x: 900, y: 300, width: 500, height: 400)
        let snapped = LayoutMath.snap(moving, others: [fixed], threshold: 10)
        XCTAssertFalse(snapped.intersects(fixed))
        XCTAssertEqual(snapped.minX, 1000)
    }

    func testAdjacency() {
        let a = VRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(LayoutMath.isAdjacent(VRect(x: 100, y: 50, width: 10, height: 10), to: [a]))
        XCTAssertTrue(LayoutMath.isAdjacent(VRect(x: 20, y: 100, width: 10, height: 10), to: [a]))
        XCTAssertFalse(LayoutMath.isAdjacent(VRect(x: 300, y: 0, width: 10, height: 10), to: [a]))
        XCTAssertFalse(LayoutMath.isAdjacent(VRect(x: 100, y: 200, width: 10, height: 10), to: [a]))
    }
}
