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

final class NieuweFunctiesTests: XCTestCase {

    func testWekkerVolgendeKeerWerkdagen() {
        // Maandag 23 nov 2026 07:30 → wekker 07:00 werkdagen → dinsdag 24 nov 07:00
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 23; c.hour = 7; c.minute = 30
        let now = Calendar.current.date(from: c)!
        let a = AlarmItem(minutes: 7 * 60, enabled: true, days: [2, 3, 4, 5, 6])
        let next = a.next(after: now)!
        XCTAssertEqual(Calendar.current.component(.day, from: next), 24)
        XCTAssertEqual(Calendar.current.component(.hour, from: next), 7)
        XCTAssertEqual(a.daysText, "Werkdagen")
    }

    func testWekkerWeekendSlaatWerkdagenOver() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 23; c.hour = 12   // maandag
        let now = Calendar.current.date(from: c)!
        let a = AlarmItem(minutes: 9 * 60, enabled: true, days: [1, 7])
        XCTAssertEqual(Calendar.current.component(.weekday, from: a.next(after: now)!), 7)   // zaterdag
    }

    func testUitgeschakeldeWekker() {
        XCTAssertNil(AlarmItem(minutes: 420, enabled: false).next())
    }

    func testPauzesTellenNietMee() {
        let s = SleepSession(start: Date(timeIntervalSince1970: 0))
        s.end = Date(timeIntervalSince1970: 8 * 3600)
        s.pausesRaw = [3600, 3600 + 1800]          // 30 min pauze
        XCTAssertEqual(s.pausedSeconds, 1800, accuracy: 0.1)
        XCTAssertEqual(s.sleepDuration, 8 * 3600 - 1800, accuracy: 0.1)
    }

    func testNachtTitelOverMiddernacht() {
        var a = DateComponents(); a.year = 2026; a.month = 11; a.day = 22; a.hour = 23
        var b = DateComponents(); b.year = 2026; b.month = 11; b.day = 23; b.hour = 6
        let s = SleepSession(start: Calendar.current.date(from: a)!)
        s.end = Calendar.current.date(from: b)!
        XCTAssertTrue(s.nightTitle.contains("→"), s.nightTitle)
    }

    func testHeartbeatRoundTrip() throws {
        let hb = Heartbeat(sample: .init(position: .back, confidence: 0.9, gravity: .init(x: 0, y: 0, z: -1), at: .now),
                           movement: 1.2, heartRate: 58)
        guard case .heartbeat(let back) = try WatchMessage.decode(WatchMessage.heartbeat(hb).encoded()) else { return XCTFail() }
        XCTAssertEqual(back.sample.position, .back)
        XCTAssertEqual(back.heartRate, 58)
    }

    func testCommandRoundTrip() throws {
        guard case .request(.pause(let m)) = try WatchMessage.decode(WatchMessage.request(.pause(minutes: 30)).encoded())
        else { return XCTFail() }
        XCTAssertEqual(m, 30)
    }
}
