import XCTest
@testable import MKBCore

final class PolicyTests: XCTestCase {
    let me = UCInfo(enabled: true, accountTag: "acct1")
    let sameAccount = UCInfo(enabled: true, accountTag: "acct1")
    let otherAccount = UCInfo(enabled: true, accountTag: "acct2")
    let ucOff = UCInfo(enabled: false, accountTag: "acct1")

    func testNativePair() {
        XCTAssertTrue(UniversalControlPolicy.isNativePair(me, sameAccount))
        XCTAssertFalse(UniversalControlPolicy.isNativePair(me, otherAccount))
        XCTAssertFalse(UniversalControlPolicy.isNativePair(me, ucOff))
        XCTAssertFalse(UniversalControlPolicy.isNativePair(UCInfo(enabled: true), UCInfo(enabled: true)))
    }

    func testMayEnter() {
        XCTAssertFalse(UniversalControlPolicy.mayEnter(local: me, peer: sameAccount, mode: .automatic))
        XCTAssertTrue(UniversalControlPolicy.mayEnter(local: me, peer: otherAccount, mode: .automatic))
        XCTAssertTrue(UniversalControlPolicy.mayEnter(local: me, peer: sameAccount, mode: .ignore))
        var busy = otherAccount
        busy.drivenByUC = true
        XCTAssertFalse(UniversalControlPolicy.mayEnter(local: me, peer: busy, mode: .automatic))
    }

    func testSuspend() {
        var driven = me
        driven.drivenByUC = true
        XCTAssertTrue(UniversalControlPolicy.shouldSuspend(local: driven, peers: [], mode: .automatic))
        XCTAssertFalse(UniversalControlPolicy.shouldSuspend(local: driven, peers: [], mode: .ignore))

        var peerDriven = sameAccount
        peerDriven.drivenByUC = true
        XCTAssertTrue(UniversalControlPolicy.shouldSuspend(local: me, peers: [peerDriven], mode: .automatic))

        var strangerDriven = otherAccount
        strangerDriven.drivenByUC = true
        XCTAssertFalse(UniversalControlPolicy.shouldSuspend(local: me, peers: [strangerDriven], mode: .automatic))
    }

    func testPressedInputsRelease() {
        var p = PressedInputs()
        p.apply(.flagsChanged(code: 0x37, flags: ModifierMask.command))
        p.apply(.key(code: 0x00, down: true, flags: ModifierMask.command, isRepeat: false))
        p.apply(.mouseButton(button: 0, down: true, position: .zero, clickCount: 1))
        XCTAssertFalse(p.isEmpty)
        let rel = p.releaseEvents(at: VPoint(1, 1))
        XCTAssertEqual(rel, [
            .mouseButton(button: 0, down: false, position: VPoint(1, 1), clickCount: 1),
            .key(code: 0x00, down: false, flags: 0, isRepeat: false),
            .flagsChanged(code: 0x37, flags: 0),
        ])
        for e in rel { p.apply(e) }
        XCTAssertTrue(p.isEmpty)
    }

    func testSpaceGrouping() {
        let s = SpaceSummary.group([("Office", "B"), ("office", "A"), ("Home", "C"), ("  ", "D"), ("Office", "A")])
        XCTAssertEqual(s.map(\.name), ["Home", "Office"])
        XCTAssertEqual(s[1].memberNames, ["A", "B"])
    }
}
