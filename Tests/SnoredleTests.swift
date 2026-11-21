import XCTest
@testable import Snoredle

final class SnoredleTests: XCTestCase {

    func testDefaultProfileClassifiesBack() {
        let (pos, _) = CalibrationProfile.default.classify(Vector3(x: 0.1, y: 0.05, z: -0.98))
        XCTAssertEqual(pos, .back)
    }

    func testCalibratedProfileUsesNearestVector() {
        var p = CalibrationProfile()
        p.vectors = [.back: .init(x: 0, y: 0.3, z: -0.95), .left: .init(x: 0.9, y: 0.2, z: 0.3),
                     .right: .init(x: -0.9, y: 0.2, z: 0.3), .stomach: .init(x: 0, y: 0.2, z: 0.97)]
        XCTAssertEqual(p.classify(.init(x: 0.85, y: 0.25, z: 0.35)).0, .left)
    }

    func testUprightDetection() {
        XCTAssertEqual(CalibrationProfile.default.classify(.init(x: 0, y: -0.99, z: 0.1)).0, .upright)
    }

    func testScore() {
        XCTAssertEqual(SnoreAnalysis.score(light: 0, loud: 0, epic: 0, hours: 8), 0)
        XCTAssertEqual(SnoreAnalysis.score(light: 40, loud: 20, epic: 0, hours: 8), 15)
    }

    func testBluetoothHeartRateParsing() {
        XCTAssertEqual(BluetoothHeartRateProvider.parse(Data([0x00, 62])), 62)          // 8-bit
        XCTAssertEqual(BluetoothHeartRateProvider.parse(Data([0x01, 0x2C, 0x01])), 300)  // 16-bit
    }

    func testMessageRoundTrip() throws {
        let m = WatchMessage.positionSample(.init(position: .left, confidence: 0.8,
                                                  gravity: .init(x: 1, y: 0, z: 0), at: Date(timeIntervalSince1970: 0)))
        guard case .positionSample(let p) = try WatchMessage.decode(m.encoded()) else { return XCTFail() }
        XCTAssertEqual(p.position, .left)
    }
}
