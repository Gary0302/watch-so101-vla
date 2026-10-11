// Watch-side voice window logic (SPEC §5.3), kept free of AVFoundation so it is unit-testable.
//
// Recording is driven by the agent's robot.status, not by the tap itself:
// Double Tap -> agent calibrates -> mode LISTENING -> we record. If the mode
// leaves LISTENING (STOP, timeout, fault), the clip is thrown away; audio from
// one epoch is never sent as if it belonged to another.

import Foundation
import SO101Protocol

public enum VoiceCommand: Equatable, Sendable {
    case startRecording(clipId: String, maxDuration: TimeInterval)
    case stopRecording  // finish early; the recorder will report the clip
    case discard  // stop and delete, send nothing
    case send([VoiceChunk])
}

public struct VoiceSession: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case recording(clipId: String, epoch: Int)
        case finishing(clipId: String, epoch: Int)
    }

    public static let format = "aac-16k-mono"
    public var maxDuration: TimeInterval
    public private(set) var state: State = .idle
    private var lastEpochRecorded: Int?

    public init(maxDuration: TimeInterval = 5) {
        self.maxDuration = maxDuration
    }

    public mutating func onStatus(mode: Mode, epoch: Int) -> [VoiceCommand] {
        switch state {
        case .idle:
            // One clip per LISTENING window, even if the same status is relayed twice.
            guard mode == .listening, lastEpochRecorded != epoch else { return [] }
            let clipId = "clip-\(epoch)-\(UUID().uuidString.prefix(8))"
            state = .recording(clipId: clipId, epoch: epoch)
            lastEpochRecorded = epoch
            return [.startRecording(clipId: clipId, maxDuration: maxDuration)]
        case .recording(_, let e), .finishing(_, let e):
            if mode == .listening && epoch == e { return [] }
            state = .idle
            return [.discard]
        }
    }

    /// Primary button while listening ("Finish Voice").
    public mutating func onUserFinish() -> [VoiceCommand] {
        guard case .recording(let id, let e) = state else { return [] }
        state = .finishing(clipId: id, epoch: e)
        return [.stopRecording]
    }

    /// Recorder delivered the clip (max duration reached or stopped early). nil = recording failed.
    public mutating func onRecordingFinished(clipId: String, audio: Data?) -> [VoiceCommand] {
        switch state {
        case .recording(let id, let e) where id == clipId, .finishing(let id, let e) where id == clipId:
            state = .idle
            guard let audio, !audio.isEmpty else { return [] }  // agent's listen timeout handles it
            return [.send(VoiceChunk.split(clipId: clipId, epoch: e, format: Self.format, audio: audio))]
        default:
            return []  // a clip from a window we already abandoned
        }
    }
}
