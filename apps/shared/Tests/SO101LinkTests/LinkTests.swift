import Foundation
import SO101Protocol
import SO101Voice
import XCTest
@testable import SO101Link

final class LinkFrameTests: XCTestCase {
    func testRoundTrip() {
        for f in [LinkFrame.agent(Data("{}".utf8)), .voiceChunk(Data([1, 2])), .voiceAck(Data([3])),
                  .phoneLink(connected: true), .phoneLink(connected: false)] {
            XCTAssertEqual(LinkFrame.decode(f.encoded()), f)
        }
        XCTAssertNil(LinkFrame.decode(Data()))
        XCTAssertNil(LinkFrame.decode(Data([0x09, 1])))
    }
}

final class IntentTrackerTests: XCTestCase {
    func testResendsUntilAckedThenStops() {
        let t = IntentTracker(resendInterval: 0.3, giveUpAfter: 3)
        let start = Date(timeIntervalSince1970: 100)
        let msg = t.make(.doubleTap, sessionId: "s", epoch: 4, source: "x", now: start)
        XCTAssertTrue(t.tick(now: start.addingTimeInterval(0.1)).resend.isEmpty)
        XCTAssertEqual(t.tick(now: start.addingTimeInterval(0.35)).resend, [msg])  // same request_id + epoch
        let ack = ControlAck(requestId: msg.requestId, result: .accepted, reason: "OK", mode: .calibrating, controlEpoch: 5)
        XCTAssertEqual(t.receive(ack), .acked(ack))
        XCTAssertNil(t.receive(ack))
        XCTAssertTrue(t.tick(now: start.addingTimeInterval(1)).resend.isEmpty)
    }

    func testGivesUpVisibly() {
        let t = IntentTracker(resendInterval: 0.3, giveUpAfter: 3)
        let start = Date(timeIntervalSince1970: 0)
        let msg = t.make(.stop, sessionId: "s", epoch: 1, source: "x", now: start)
        XCTAssertEqual(t.tick(now: start.addingTimeInterval(3.1)).outcomes, [.gaveUp(msg)])
        XCTAssertTrue(t.pending.isEmpty)
    }

    func testLatestOnlyKeepsNewest() {
        var slot = LatestOnly<Int>()
        slot.put(1); slot.put(2); slot.put(3)
        XCTAssertEqual(slot.take(), 3)
        XCTAssertNil(slot.take())
        XCTAssertEqual(slot.dropped, 2)
    }
}

final class PhoneRouterTests: XCTestCase {
    private func json<T: TypedMessage>(_ m: T) throws -> Data { try ProtocolCoder.encode(m) }

    func testRoutesWatchMessages() throws {
        let r = PhoneRouter()
        let motion = try json(WatchMotion(sessionId: "s", seq: 1, sampleMonoNs: 1, quaternionWxyz: [1, 0, 0, 0],
                                          gyroRadS: [0, 0, 0], gravityG: [0, 0, -1], controlEpoch: 3))
        XCTAssertEqual(r.fromWatch(LinkFrame.agent(motion).encoded()), [.relayMotion(motion)])
        let intent = try json(ControlIntent(requestId: "w-1", sessionId: "s", controlEpoch: 3, intent: .doubleTap, source: "w"))
        XCTAssertEqual(r.fromWatch(LinkFrame.agent(intent).encoded()), [.relayIntent(intent)])
        let life = try json(WatchLifecycle(sessionId: "s", seq: 2, state: .inactive))
        XCTAssertEqual(r.fromWatch(LinkFrame.agent(life).encoded()), [.relayReliable(life)])
    }

    func testWatchCannotImpersonateAgentOrSendTranscripts() throws {
        let r = PhoneRouter()
        let fake = Data(#"{"protocol_version":1,"type":"voice.transcript","request_id":"v","session_id":"s","control_epoch":1,"text":"x"}"#.utf8)
        guard case .drop = r.fromWatch(LinkFrame.agent(fake).encoded()).first else { return XCTFail() }
        guard case .drop = r.fromWatch(Data([0x42])).first else { return XCTFail() }
    }

    func testVoiceChunksAreAckedAndAssembled() throws {
        let r = PhoneRouter()
        let chunks = VoiceChunk.split(clipId: "c", epoch: 9, format: "aac", audio: Data(repeating: 7, count: 40_000))
        var clips: [AssembledClip] = []
        for c in chunks {
            let actions = r.fromWatch(LinkFrame.voiceChunk(try c.encoded()).encoded())
            guard case .replyToWatch(.voiceAck)? = actions.first else { return XCTFail("chunk not acked") }
            for case .transcribe(let clip) in actions { clips.append(clip) }
        }
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.epoch, 9)
        XCTAssertEqual(clips.first?.audio.count, 40_000)
    }
}

/// End-to-end against the real Python gateway (MockRobot). Opt-in:
///   SO101_E2E=1 swift test --filter AgentConnectionE2ETests
final class AgentConnectionE2ETests: XCTestCase {
    private var gateway: Process?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SO101_E2E"] == "1", "set SO101_E2E=1")
    }

    override func tearDown() {
        gateway?.terminate()
        gateway?.waitUntilExit()
    }

    private func startGateway(port: Int, token: String, tls: (cert: String, key: String)? = nil) throws {
        let robotDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("robot")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["uv", "run", "--quiet", "python", "-m", "so101_watch.gateway",
                       "--mock", "--host", "127.0.0.1", "--port", "\(port)"]
            + (tls.map { ["--cert", $0.cert, "--key", $0.key] } ?? ["--allow-insecure"])
        p.currentDirectoryURL = robotDir
        var env = ProcessInfo.processInfo.environment
        env["SO101_GATEWAY_TOKEN"] = token
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        try p.run()
        gateway = p
    }

    /// Self-signed cert + its SHA-256 fingerprint, via the openssl CLI.
    private func makeCert() throws -> (cert: String, key: String, sha256: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("so101-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cert = dir.appendingPathComponent("cert.pem").path, key = dir.appendingPathComponent("key.pem").path
        func run(_ args: [String]) throws -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = args
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=so101-e2e",
                     "-keyout", key, "-out", cert])
        let fp = try run(["x509", "-in", cert, "-noout", "-fingerprint", "-sha256"])
        let hex = fp.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (cert, key, hex)
    }

    func testPinnedTLSAcceptsRightCertAndRejectsWrongPin() throws {
        let token = "e2e-token-0123456789"
        let port = 18766
        let c = try makeCert()
        try startGateway(port: port, token: token, tls: (c.cert, c.key))
        let url = URL(string: "wss://127.0.0.1:\(port)")!

        let wrong = AgentConnection(config: .init(url: url, token: token, sessionId: "s", pinnedCertSHA256: String(repeating: "0", count: 64)),
                                    callbackQueue: DispatchQueue(label: "wrong"))
        var wrongConnected = false
        wrong.onState = { if $0 == .connected { wrongConnected = true } }
        let right = AgentConnection(config: .init(url: url, token: token, sessionId: "s", pinnedCertSHA256: c.sha256),
                                    callbackQueue: DispatchQueue(label: "right"))
        let got = expectation(description: "status over pinned TLS")
        right.onMessage = { msg in if case .status = msg { got.fulfill(); right.onMessage = nil } }
        right.start()
        wait(for: [got], timeout: 15)
        right.stop()
        Thread.sleep(forTimeInterval: 0.3)  // gateway allows one controller at a time

        wrong.start()
        Thread.sleep(forTimeInterval: 2)
        wrong.stop()
        XCTAssertFalse(wrongConnected, "connected despite a wrong certificate pin")
    }

    func testDoubleTapCalibrateToManualOverRealSocket() throws {
        let token = "e2e-token-0123456789"
        let port = 18765
        try startGateway(port: port, token: token)

        let conn = AgentConnection(config: .init(url: URL(string: "ws://127.0.0.1:\(port)")!, token: token, sessionId: "s-e2e"),
                                   callbackQueue: DispatchQueue(label: "e2e"))
        let lock = NSLock()
        var modes: [Mode] = []
        var acks: [ControlAck] = []
        conn.onMessage = { msg in
            lock.lock(); defer { lock.unlock() }
            if case .status(let s) = msg { modes.append(s.mode) }
            if case .ack(let a) = msg { acks.append(a) }
        }
        func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                lock.lock(); let ok = cond(); lock.unlock()
                if ok { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        // Gateway takes a moment to boot; AgentConnection reconnects on its own.
        conn.start()
        XCTAssertTrue(waitFor(15) { modes.contains(.hold) }, "never saw HOLD")

        conn.sendIntent(.doubleTap, source: "e2e")
        XCTAssertTrue(waitFor(3) { acks.contains { $0.result == .accepted } })
        XCTAssertTrue(waitFor(3) { modes.contains(.calibrating) })

        // A still, palm-down wrist at ~30 Hz until MANUAL.
        var seq = 0
        let ok = waitFor(5) {
            seq += 1
            let m = WatchMotion(sessionId: "s-e2e", seq: seq, sampleMonoNs: Int64(seq) * 33_000_000,
                                quaternionWxyz: [1, 0, 0, 0], gyroRadS: [0, 0, 0], gravityG: [0, 0, -1],
                                controlEpoch: conn.epoch)
            conn.relayMotion(try! ProtocolCoder.encode(m))
            return modes.contains(.manual)
        }
        XCTAssertTrue(ok, "never reached MANUAL; modes=\(modes)")
        conn.stop()
    }
}
