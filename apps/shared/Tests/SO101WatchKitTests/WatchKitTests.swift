import Foundation
import SO101Link
import SO101Protocol
import SO101Voice
import XCTest
@testable import SO101WatchKit

private func event(_ id: String, _ kind: HapticKind, created: Double, play: Bool = true, ttl: Int = 500) -> HapticEvent {
    HapticEvent(eventId: id, sessionId: "s", controlEpoch: 1, kind: kind, severity: "info", confidence: 1,
                ttlMs: ttl, display: kind.rawValue, createdMonoNs: Int64(created * 1e9), playHaptic: play,
                axis: nil, limitType: nil, transactionId: nil, evidence: [])
}

final class HapticSchedulerTests: XCTestCase {
    func testStyleMappingMatchesSpec() {
        XCTAssertEqual(HapticKind.limitHit.style, .directionUp)
        XCTAssertEqual(HapticKind.graspLikely.style, .success)
        XCTAssertEqual(HapticKind.calibrationFailed.style, .retry)
        XCTAssertEqual(HapticKind.vlaStarted.style, .start)
        XCTAssertEqual(HapticKind.connectionLost.style, .failure)
    }

    func testDedupAndUIOnlyEvents() {
        var s = HapticScheduler()
        XCTAssertEqual(s.receive(event("a", .limitHit, created: 10), now: 1000), .directionUp)
        XCTAssertNil(s.receive(event("a", .limitHit, created: 10), now: 1001))
        XCTAssertNil(s.receive(event("b", .nearLimit, created: 12, play: false), now: 1002))
    }

    func testStaleEventIsNotPlayed() {
        var s = HapticScheduler()
        _ = s.receive(event("a", .nearLimit, created: 10), now: 1000)  // establishes offset 990
        XCTAssertNil(s.receive(event("b", .fault, created: 11), now: 1001.8))  // arrived 800 ms late
    }

    func testGapQueuesHighestPriorityAndReleasesIt() {
        var s = HapticScheduler()
        XCTAssertEqual(s.receive(event("a", .limitHit, created: 10), now: 1000), .directionUp)
        XCTAssertNil(s.receive(event("b", .nearLimit, created: 10.05), now: 1000.05))
        XCTAssertNil(s.receive(event("c", .vlaFinished, created: 10.1), now: 1000.1))
        XCTAssertNil(s.tick(now: 1000.2))
        XCTAssertEqual(s.tick(now: 1000.31), .success)  // vlaFinished won the queue
        XCTAssertNil(s.tick(now: 1001))
    }
}

final class WatchControllerTests: XCTestCase {
    private func status(_ mode: Mode, epoch: Int) -> LinkFrame {
        let s = RobotStatus(sessionId: "s", controlEpoch: epoch, mode: mode, owner: .none, reason: "t",
                            robotHolding: true, vlaTaskId: nil)
        return .agent(try! ProtocolCoder.encode(s))
    }

    private func sentIntent(_ effects: [WatchEffect]) -> ControlIntent? {
        for case .send(.agent(let d)) in effects {
            if let i = try? ProtocolCoder.decode(ControlIntent.self, from: d) { return i }
        }
        return nil
    }

    private func linked() -> WatchController {
        let c = WatchController(sessionId: "s")
        c.onPhoneReachable(true)
        _ = c.onFrame(.phoneLink(connected: true), now: 0)
        return c
    }

    func testPrimaryLabelsFollowAgentMode() {
        let c = WatchController(sessionId: "s")
        XCTAssertFalse(c.ui.primaryEnabled)
        c.onPhoneReachable(true)
        _ = c.onFrame(status(.manual, epoch: 3), now: 0)
        XCTAssertEqual(c.ui.primaryLabel, "Calibrate & Talk")
        _ = c.onFrame(status(.vlaRunning, epoch: 8), now: 0)
        XCTAssertEqual(c.ui.primaryLabel, "Interrupt VLA")
        _ = c.onFrame(status(.awaitRecalibration, epoch: 9), now: 0)
        XCTAssertEqual(c.ui.primaryLabel, "Recalibrate to Take Over")
        _ = c.onFrame(status(.calibrating, epoch: 10), now: 0)
        XCTAssertFalse(c.ui.primaryEnabled)
    }

    func testDoubleTapCarriesTheEpochOnScreenAndBlocksUntilAck() throws {
        let c = linked()
        _ = c.onFrame(status(.vlaRunning, epoch: 8), now: 0)
        let intent = try XCTUnwrap(sentIntent(c.onPrimaryAction(now: 1)))
        XCTAssertEqual(intent.intent, .doubleTap)
        XCTAssertEqual(intent.controlEpoch, 8)
        XCTAssertTrue(c.ui.pending)
        XCTAssertTrue(c.onPrimaryAction(now: 1.1).isEmpty)  // no double send while pending

        let ack = ControlAck(requestId: intent.requestId, result: .accepted, reason: "OK", mode: .vlaCancelling, controlEpoch: 9)
        _ = c.onFrame(.agent(try ProtocolCoder.encode(ack)), now: 1.2)
        XCTAssertFalse(c.ui.pending)
    }

    func testNewerStatusResolvesPendingEvenIfAckIsLost() throws {
        let c = linked()
        _ = c.onFrame(status(.hold, epoch: 2), now: 0)
        _ = try XCTUnwrap(sentIntent(c.onPrimaryAction(now: 1)))
        XCTAssertTrue(c.ui.pending)
        _ = c.onFrame(status(.hold, epoch: 2), now: 1.1)  // heartbeat replay: same epoch, still pending
        XCTAssertTrue(c.ui.pending)
        _ = c.onFrame(status(.calibrating, epoch: 3), now: 1.2)
        XCTAssertFalse(c.ui.pending)
        XCTAssertNil(c.ui.notice)
    }

    func testPendingTimesOutWithNotice() {
        let c = linked()
        _ = c.onFrame(status(.hold, epoch: 2), now: 0)
        _ = c.onPrimaryAction(now: 1)
        _ = c.tick(now: 4.5)
        XCTAssertFalse(c.ui.pending)
        XCTAssertEqual(c.ui.notice, "No response from robot")
        XCTAssertTrue(c.ui.primaryEnabled)
    }

    func testListeningStartsRecordingAndPrimaryFinishesIt() {
        let c = linked()
        let effects = c.onFrame(status(.listening, epoch: 5), now: 0)
        guard case .voice(.startRecording(let id, _))? = effects.first else { return XCTFail("no recording") }
        XCTAssertEqual(c.ui.primaryLabel, "Finish Voice")
        XCTAssertEqual(c.onPrimaryAction(now: 1), [.voice(.stopRecording)])  // local, no intent sent
        let sent = c.onRecordingFinished(clipId: id, audio: Data(repeating: 1, count: 50_000))
        XCTAssertEqual(sent.count, 2)
        for case .send(.voiceChunk(let d)) in sent { XCTAssertEqual(try VoiceChunk.decode(d).epoch, 5) }
    }

    func testStopAlwaysAvailableEvenWhenPrimaryIsDisabled() throws {
        let c = linked()
        _ = c.onFrame(status(.calibrating, epoch: 4), now: 0)
        XCTAssertFalse(c.ui.primaryEnabled)
        XCTAssertEqual(try XCTUnwrap(sentIntent(c.onStop(now: 1))).intent, .stop)
    }

    func testMotionIsRateLimitedAndStampedWithEpoch() {
        let c = linked()
        _ = c.onFrame(status(.manual, epoch: 7), now: 0)
        var sent: [WatchMotion] = []
        for i in 0..<50 {  // 1 s of 50 Hz samples
            for case .send(.agent(let d)) in c.onMotion(quaternionWxyz: [1, 0, 0, 0], gyroRadS: [0, 0, 0],
                                                         gravityG: [0, 0, -1], sampleTime: Double(i) / 50) {
                sent.append(try! ProtocolCoder.decode(WatchMotion.self, from: d))
            }
        }
        XCTAssertTrue((19...21).contains(sent.count), "\(sent.count)")
        XCTAssertTrue(sent.allSatisfy { $0.controlEpoch == 7 })
    }

    func testGoingInactiveTellsAgentAndDropsRecording() {
        let c = linked()
        _ = c.onFrame(status(.listening, epoch: 5), now: 0)
        let effects = c.onLifecycle(active: false)
        XCTAssertTrue(effects.contains(.voice(.discard)))
        let lifecycle = effects.compactMap { e -> WatchLifecycle? in
            guard case .send(.agent(let d)) = e else { return nil }
            return try? ProtocolCoder.decode(WatchLifecycle.self, from: d)
        }
        XCTAssertEqual(lifecycle.first?.state, .inactive)
    }
}
