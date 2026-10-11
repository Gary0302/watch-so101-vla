// Watch -> iPhone voice clip transport over WCSession.sendMessageData (SPEC §5.3).
//
// A clip is a few seconds of AAC audio, split into chunks small enough for one
// message each. The phone reassembles and ACKs every chunk. This channel is
// never used for motion or safety; a lost clip just means "no transcript", and
// the agent's listen timeout takes it from there.

import Foundation

public struct VoiceChunk: Codable, Equatable, Sendable {
    public static let maxPayload = 32 * 1024
    public static let maxChunks = 64

    public var clipId: String
    /// Supervisor epoch of the LISTENING window this clip belongs to.
    public var epoch: Int
    public var format: String
    public var index: Int
    public var count: Int
    public var data: Data

    public init(clipId: String, epoch: Int, format: String, index: Int, count: Int, data: Data) {
        self.clipId = clipId
        self.epoch = epoch
        self.format = format
        self.index = index
        self.count = count
        self.data = data
    }

    public func encoded() throws -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary  // carries Data natively, no base64 inflation
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> VoiceChunk {
        try PropertyListDecoder().decode(VoiceChunk.self, from: data)
    }

    public static func split(clipId: String, epoch: Int, format: String, audio: Data,
                             maxPayload: Int = VoiceChunk.maxPayload) -> [VoiceChunk] {
        let parts = stride(from: 0, to: max(audio.count, 1), by: maxPayload).map {
            audio.subdata(in: $0..<min($0 + maxPayload, audio.count))
        }
        return parts.enumerated().map {
            VoiceChunk(clipId: clipId, epoch: epoch, format: format, index: $0.offset, count: parts.count, data: $0.element)
        }
    }
}

public struct VoiceChunkAck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case stored, complete, duplicate, rejected }
    public var clipId: String
    public var index: Int
    public var status: Status
    public var reason: String?

    public func encoded() throws -> Data { try PropertyListEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> VoiceChunkAck {
        try PropertyListDecoder().decode(VoiceChunkAck.self, from: data)
    }
}

public struct AssembledClip: Equatable, Sendable {
    public var clipId: String
    public var epoch: Int
    public var format: String
    public var audio: Data
}

/// Phone-side reassembly. Not thread-safe; call from one queue (the WCSession delegate queue).
public final class ClipAssembler {
    private struct Partial {
        let epoch: Int
        let format: String
        let count: Int
        var parts: [Int: Data]
        let started: Date
    }

    public var maxClipBytes = 1 << 20
    public let timeout: TimeInterval
    private let now: () -> Date
    private var partials: [String: Partial] = [:]
    private var completed: [String] = []  // recent ids, bounded

    public init(timeout: TimeInterval = 10, now: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.now = now
    }

    public func receive(_ c: VoiceChunk) -> (VoiceChunkAck, AssembledClip?) {
        expire()
        func ack(_ s: VoiceChunkAck.Status, _ reason: String? = nil) -> VoiceChunkAck {
            VoiceChunkAck(clipId: c.clipId, index: c.index, status: s, reason: reason)
        }
        if completed.contains(c.clipId) { return (ack(.duplicate), nil) }
        guard (1...VoiceChunk.maxChunks).contains(c.count), (0..<c.count).contains(c.index),
              c.data.count <= VoiceChunk.maxPayload else {
            return (ack(.rejected, "bad_framing"), nil)
        }
        var p = partials[c.clipId] ?? Partial(epoch: c.epoch, format: c.format, count: c.count, parts: [:], started: now())
        guard p.epoch == c.epoch, p.format == c.format, p.count == c.count else {
            return (ack(.rejected, "inconsistent_chunk"), nil)
        }
        if p.parts[c.index] != nil { return (ack(.duplicate), nil) }
        p.parts[c.index] = c.data
        guard p.parts.values.reduce(0, { $0 + $1.count }) <= maxClipBytes else {
            partials[c.clipId] = nil
            return (ack(.rejected, "too_large"), nil)
        }
        guard p.parts.count == p.count else {
            partials[c.clipId] = p
            return (ack(.stored), nil)
        }
        partials[c.clipId] = nil
        completed.append(c.clipId)
        if completed.count > 32 { completed.removeFirst() }
        let audio = (0..<p.count).reduce(into: Data()) { $0.append(p.parts[$1]!) }
        return (ack(.complete), AssembledClip(clipId: c.clipId, epoch: p.epoch, format: p.format, audio: audio))
    }

    public var pendingClipCount: Int { partials.count }

    private func expire() {
        let t = now()
        partials = partials.filter { t.timeIntervalSince($0.value.started) <= timeout }
    }
}
