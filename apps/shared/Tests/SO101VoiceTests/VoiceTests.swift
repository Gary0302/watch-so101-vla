import Foundation
import SO101Protocol
import XCTest
@testable import SO101Voice

final class ClipTransportTests: XCTestCase {
    func testSplitAndReassembleOutOfOrderWithDuplicates() throws {
        let audio = Data((0..<100_000).map { UInt8($0 % 251) })
        let chunks = VoiceChunk.split(clipId: "c1", epoch: 7, format: "aac", audio: audio)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.data.count <= VoiceChunk.maxPayload })

        let a = ClipAssembler()
        var clip: AssembledClip?
        for c in [chunks[2], chunks[0], chunks[0], chunks[3], chunks[1]] {
            let wire = try VoiceChunk.decode(c.encoded())  // through the actual encoding
            let (ack, done) = a.receive(wire)
            XCTAssertNotEqual(ack.status, .rejected)
            if let done { clip = done }
        }
        XCTAssertEqual(clip?.audio, audio)
        XCTAssertEqual(clip?.epoch, 7)
        XCTAssertEqual(a.receive(chunks[0]).0.status, .duplicate)  // after completion
        XCTAssertEqual(a.pendingClipCount, 0)
    }

    func testRejectsBadOrInconsistentFraming() {
        let a = ClipAssembler()
        XCTAssertEqual(a.receive(VoiceChunk(clipId: "x", epoch: 1, format: "aac", index: 3, count: 2, data: Data())).0.status, .rejected)
        XCTAssertEqual(a.receive(VoiceChunk(clipId: "x", epoch: 1, format: "aac", index: 0, count: 999, data: Data())).0.status, .rejected)
        _ = a.receive(VoiceChunk(clipId: "y", epoch: 1, format: "aac", index: 0, count: 2, data: Data([1])))
        let (ack, _) = a.receive(VoiceChunk(clipId: "y", epoch: 2, format: "aac", index: 1, count: 2, data: Data([2])))
        XCTAssertEqual(ack.status, .rejected)
        XCTAssertEqual(ack.reason, "inconsistent_chunk")
    }

    func testIncompleteClipExpires() {
        var t = Date(timeIntervalSince1970: 0)
        let a = ClipAssembler(timeout: 10, now: { t })
        _ = a.receive(VoiceChunk(clipId: "z", epoch: 1, format: "aac", index: 0, count: 2, data: Data([1])))
        XCTAssertEqual(a.pendingClipCount, 1)
        t = t.addingTimeInterval(11)
        _ = a.receive(VoiceChunk(clipId: "other", epoch: 1, format: "aac", index: 0, count: 2, data: Data([1])))
        XCTAssertEqual(a.pendingClipCount, 1)  // "z" expired, only "other" remains
    }

    func testAckRoundTrips() throws {
        let ack = VoiceChunkAck(clipId: "c", index: 1, status: .stored, reason: nil)
        XCTAssertEqual(try VoiceChunkAck.decode(ack.encoded()), ack)
    }
}

final class VoiceSessionTests: XCTestCase {
    func testListeningStartsOneRecordingPerEpoch() {
        var s = VoiceSession()
        XCTAssertEqual(s.onStatus(mode: .calibrating, epoch: 4), [])
        guard case .startRecording(let id, let dur)? = s.onStatus(mode: .listening, epoch: 5).first else {
            return XCTFail("should start recording")
        }
        XCTAssertEqual(dur, 5)
        XCTAssertEqual(s.onStatus(mode: .listening, epoch: 5), [])  // relayed twice
        let cmds = s.onRecordingFinished(clipId: id, audio: Data(repeating: 1, count: 10))
        guard case .send(let chunks)? = cmds.first else { return XCTFail("should send") }
        XCTAssertEqual(chunks.first?.epoch, 5)
        XCTAssertEqual(s.onStatus(mode: .listening, epoch: 5), [])  // same window: no second clip
    }

    func testLeavingListeningDiscardsAndLateClipIsDropped() {
        var s = VoiceSession()
        guard case .startRecording(let id, _)? = s.onStatus(mode: .listening, epoch: 5).first else {
            return XCTFail()
        }
        XCTAssertEqual(s.onStatus(mode: .hold, epoch: 6), [.discard])  // user hit STOP
        XCTAssertEqual(s.onRecordingFinished(clipId: id, audio: Data([1, 2, 3])), [])
        XCTAssertEqual(s.state, .idle)
    }

    func testFinishEarlyThenDeliver() {
        var s = VoiceSession()
        guard case .startRecording(let id, _)? = s.onStatus(mode: .listening, epoch: 9).first else {
            return XCTFail()
        }
        XCTAssertEqual(s.onUserFinish(), [.stopRecording])
        XCTAssertEqual(s.onUserFinish(), [])
        XCTAssertEqual(s.onRecordingFinished(clipId: id, audio: Data()).count, 0)  // empty clip: send nothing
        XCTAssertEqual(s.state, .idle)
    }
}

final class TranscriptRelayTests: XCTestCase {
    struct Fixed: Transcriber {
        let result: Result<String?, Error>
        func transcribe(_ clip: AssembledClip) async throws -> String? { try result.get() }
    }

    struct Boom: Error {}

    private let clip = AssembledClip(clipId: "c9", epoch: 12, format: "aac", audio: Data([1]))

    func testTranscriptCarriesListeningEpoch() async {
        let t = await TranscriptRelay(sessionId: "s", transcriber: Fixed(result: .success(" 把紅色積木放進盒子 \n"))).transcript(for: clip)
        XCTAssertEqual(t, VoiceTranscript(requestId: "v-c9", sessionId: "s", controlEpoch: 12, text: "把紅色積木放進盒子"))
    }

    func testEmptyOrFailedRecognitionBecomesNull() async {
        for r: Result<String?, Error> in [.success("   "), .success(nil), .failure(Boom())] {
            let t = await TranscriptRelay(sessionId: "s", transcriber: Fixed(result: r)).transcript(for: clip)
            XCTAssertNil(t.text)
        }
    }
}
