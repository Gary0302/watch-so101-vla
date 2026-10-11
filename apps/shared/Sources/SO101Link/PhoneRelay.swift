// iPhone glue: WCSession <-> PhoneRouter <-> AgentConnection, plus STT for voice clips.
// The app must stay in the foreground during a session (SPEC §3, v1 requirement).

#if os(iOS)
import Foundation
import SO101Protocol
import SO101Voice
import WatchConnectivity

public final class PhoneRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    public let agent: AgentConnection
    public let router = PhoneRouter()
    private let transcripts: TranscriptRelay
    private let session: WCSession
    private let queue = DispatchQueue(label: "so101.phone-relay")
    private let stateLock = NSLock()
    private var agentConnected = false
    private var lastStatus: Data?  // replayed when the watch (re)appears, so it never shows a stale mode
    private var lastAck: (json: Data, at: Date)?  // re-sent with the heartbeat: a lost ack looks like "no response"
    private var heartbeat: DispatchSourceTimer?
    private var motionIn = 0
    private var motionSince = Date()

    /// Link traffic for the on-screen debug panel (motion is summarized as a rate).
    public let trace = LinkTrace()

    public var onTranscript: ((VoiceTranscript) -> Void)?
    public var onWatchReachable: ((Bool) -> Void)?
    public var onAgentState: ((AgentConnection.State) -> Void)?

    public init(agent: AgentConnection, transcriber: Transcriber, session: WCSession = .default) {
        self.agent = agent
        self.transcripts = TranscriptRelay(sessionId: agent.config.sessionId, transcriber: transcriber)
        self.session = session
        super.init()
        agent.onRawMessage = { [weak self] json in
            guard let self else { return }
            let isStatus = ProtocolCoder.messageType(of: json) == RobotStatus.messageType
            if isStatus { stateLock.withLock { self.lastStatus = json } }
            if ProtocolCoder.messageType(of: json) == ControlAck.messageType {
                stateLock.withLock { self.lastAck = (json, Date()) }
            }
            trace.add("agent→ \(LinkFrame.summarize(agentJSON: json))")
            toWatch(.agent(json))
            if isStatus { publishContext() }
        }
        agent.onError = { [weak self] text in self?.trace.add("agent FAIL \(text)") }
        agent.onState = { [weak self] state in
            guard let self else { return }
            stateLock.withLock {
                self.agentConnected = state == .connected
                if !self.agentConnected { self.lastStatus = nil }
            }
            trace.add("agent link \(state)")
            toWatch(.phoneLink(connected: state == .connected))
            publishContext()
            onAgentState?(state)
        }
    }

    public func start() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        agent.start()
        // Messages to the watch are dropped while it is unreachable; re-send link + status
        // every 2 s so a missed transition never leaves the watch showing stale state.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.resyncWatch(quiet: true) }
        t.resume()
        heartbeat = t
    }

    public func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        agent.stop()
    }

    /// Link state + latest status, for a watch that just became reachable.
    private func resyncWatch(quiet: Bool = false) {
        let (connected, status, ack) = stateLock.withLock { (agentConnected, lastStatus, lastAck) }
        toWatch(.phoneLink(connected: connected), quiet: quiet)
        if connected, let status { toWatch(.agent(status), quiet: quiet) }
        if connected, let ack, Date().timeIntervalSince(ack.at) < 5 { toWatch(.agent(ack.json), quiet: quiet) }
    }

    /// Latest link + status as WCSession application context: delivered even if the watch app
    /// is not running right now, and read by the watch on launch.
    private func publishContext() {
        guard session.activationState == .activated else { return }
        let (connected, status) = stateLock.withLock { (agentConnected, lastStatus) }
        var ctx: [String: Any] = ["agentConnected": connected]
        if connected, let status { ctx["status"] = status }
        do { try session.updateApplicationContext(ctx) } catch { trace.add("context FAIL \(error.localizedDescription)") }
    }

    private func reportReachability(_ session: WCSession) {
        let reachable = session.isReachable
        trace.add("watch \(reachable ? "reachable" : "UNREACHABLE")")
        if reachable { resyncWatch() }
        DispatchQueue.main.async { self.onWatchReachable?(reachable) }
    }

    private func toWatch(_ frame: LinkFrame, quiet: Bool = false) {
        // Try even when isReachable reads false (wrist down + workout); a real failure is reported.
        guard session.activationState == .activated else {
            if !quiet { trace.add("→watch dropped (session not active): \(frame.summary)") }
            return
        }
        session.sendMessageData(frame.encoded(), replyHandler: nil) { [weak self] error in
            if !quiet { self?.trace.add("→watch FAIL \(frame.summary): \(error.localizedDescription)") }
        }
    }

    private func traceFromWatch(_ raw: Data) {
        guard let frame = LinkFrame.decode(raw) else { return trace.add("watch→ bad frame") }
        if case .agent(let d) = frame, ProtocolCoder.messageType(of: d) == WatchMotion.messageType {
            motionIn += 1
            let dt = Date().timeIntervalSince(motionSince)
            if dt >= 5 {
                trace.add(String(format: "watch→ motion %.1f Hz", Double(motionIn) / dt))
                motionIn = 0
                motionSince = Date()
            }
            return
        }
        if case .voiceChunk = frame { return }  // dozens per clip; the transcript line is enough
        trace.add("watch→ \(frame.summary)")
    }

    private func perform(_ actions: [PhoneAction], reply: ((Data) -> Void)?) {
        var replied = false
        for action in actions {
            switch action {
            case .relayMotion(let d): agent.relayMotion(d)
            case .relayIntent(let d): agent.relayIntent(d)
            case .relayReliable(let d):
                agent.relayReliable(d)
                // The watch announces itself on launch / activation: give it the current state.
                if ProtocolCoder.messageType(of: d) == WatchLifecycle.messageType { resyncWatch() }
            case .replyToWatch(let frame):
                if let reply, !replied { reply(frame.encoded()); replied = true } else { toWatch(frame) }
            case .transcribe(let clip):
                Task {
                    let t = await transcripts.transcript(for: clip)
                    trace.add("transcript: \(t.text ?? "(none)")")
                    agent.send(t)
                    await MainActor.run { self.onTranscript?(t) }
                }
            case .drop(let reason):
                trace.add("dropped from watch: \(reason)")
            }
        }
        if let reply, !replied { reply(Data()) }  // the watch asked for a reply; never leave it hanging
    }

    // MARK: WCSessionDelegate

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        queue.async {
            self.traceFromWatch(messageData)
            self.perform(self.router.fromWatch(messageData), reply: nil)
        }
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                        replyHandler: @escaping (Data) -> Void) {
        queue.async {
            self.traceFromWatch(messageData)
            self.perform(self.router.fromWatch(messageData), reply: replyHandler)
        }
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        reportReachability(session)
        publishContext()
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        reportReachability(session)
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()  // switching paired watches
    }
}
#endif
