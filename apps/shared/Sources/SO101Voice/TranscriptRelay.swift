// iPhone side: assembled clip -> speech-to-text -> voice.transcript for the agent.
//
// The phone only transcribes. Deciding what the words mean (allowlisted task,
// stop phrase, unknown) is the agent's TaskRouter, so there is one source of truth.

import Foundation
import SO101Protocol

public protocol Transcriber: Sendable {
    /// nil or empty = nothing usable was heard. Throwing counts the same as nil.
    func transcribe(_ clip: AssembledClip) async throws -> String?
}

public struct TranscriptRelay: Sendable {
    public let sessionId: String
    public let transcriber: Transcriber

    public init(sessionId: String, transcriber: Transcriber) {
        self.sessionId = sessionId
        self.transcriber = transcriber
    }

    public func transcript(for clip: AssembledClip) async -> VoiceTranscript {
        let raw = try? await transcriber.transcribe(clip)
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceTranscript(
            requestId: "v-\(clip.clipId)",
            sessionId: sessionId,
            controlEpoch: clip.epoch,  // the LISTENING epoch; a late transcript is ignored by the agent
            text: (text?.isEmpty ?? true) ? nil : text
        )
    }
}

/// Phrases the agent's TaskRouter knows. Fed to the recognizer as contextual
/// strings to bias it toward them; it does not restrict what can be heard.
public let defaultTaskPhrases = [
    "把紅色積木放進盒子", "紅色積木", "紅色方塊", "盒子", "停止", "暫停",
    "pick red cube", "put the red cube in the box", "stop", "hold",
]
