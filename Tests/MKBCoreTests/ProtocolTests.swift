import XCTest
@testable import MKBCore

final class ProtocolTests: XCTestCase {
    let samples: [Message] = [
        .hello(Hello(id: "id-1", name: "Studio", model: "Mac14,13", appVersion: "0.1.0",
                     displays: [VRect(x: 0, y: 0, width: 2560, height: 1440)],
                     layout: SpaceLayout(origins: ["id-1": VPoint(1, 2)], version: 7, author: "id-1"),
                     status: PeerStatus(uc: UCInfo(enabled: true, accountTag: "abc", drivenByUC: false), controlling: "x"))),
        .displays([VRect(x: -1920, y: 0, width: 1920, height: 1080)]),
        .layout(SpaceLayout(origins: ["a": VPoint(0, 0)], version: 1, author: "a")),
        .status(PeerStatus(uc: UCInfo(enabled: false), controlledBy: "y")),
        .enter(VPoint(12.5, 99)),
        .leave,
        .takeover(.universalControl),
        .input(.mouseMove(position: VPoint(10, 20), delta: VPoint(-3, 4))),
        .input(.mouseButton(button: 2, down: true, position: VPoint(5, 6), clickCount: 2)),
        .input(.scroll(ScrollEvent(lineDX: 1, lineDY: -2, pointDX: 3, pointDY: -40, fixedDX: 0.5, fixedDY: -4.25, continuous: true, phase: 2, momentumPhase: 1))),
        .input(.key(code: 0x24, down: true, flags: 0x10_0000, isRepeat: true)),
        .input(.flagsChanged(code: 0x37, flags: 0x10_0000)),
        .input(.systemDefined(subtype: 8, data1: 0x10_0A00, data2: -1, flags: 0)),
        .clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("hello ✨".utf8)),
                    ClipboardItem(type: "public.png", data: Data([0, 1, 2, 255]))]),
        .ping,
        .pong,
    ]

    func testRoundTripEveryMessage() throws {
        for m in samples {
            var dec = FrameDecoder()
            let out = try dec.append(m.encodedFrame())
            XCTAssertEqual(out, [m])
        }
    }

    func testStreamedByteByByte() throws {
        var stream = Data()
        for m in samples { stream.append(m.encodedFrame()) }
        var dec = FrameDecoder()
        var out: [Message] = []
        for b in stream { out += try dec.append(Data([b])) }
        XCTAssertEqual(out, samples)
    }

    func testChunkedStream() throws {
        var stream = Data()
        for _ in 0..<50 { for m in samples { stream.append(m.encodedFrame()) } }
        var dec = FrameDecoder()
        var out: [Message] = []
        var i = 0
        while i < stream.count {
            let n = min(777, stream.count - i)
            out += try dec.append(stream.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(out.count, samples.count * 50)
        XCTAssertEqual(Array(out.suffix(samples.count)), samples)
    }

    func testRejectsOversizedFrame() {
        var dec = FrameDecoder()
        XCTAssertThrowsError(try dec.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testRejectsUnknownType() {
        var dec = FrameDecoder()
        XCTAssertThrowsError(try dec.append(Data([0, 0, 0, 1, 0xEE])))
    }

    func testRejectsTruncatedPayload() {
        var dec = FrameDecoder()
        // enter needs 16 payload bytes, give 2.
        XCTAssertThrowsError(try dec.append(Data([0, 0, 0, 3, 5, 0, 0])))
    }
}
