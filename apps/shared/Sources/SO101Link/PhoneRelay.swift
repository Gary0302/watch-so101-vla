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
            if ProtocolCoder.messageType(of: json) == RobotStatus.messageType {
                stateLock.withLock { self.lastStatus = json }
            }
            toWatch(.agent(json))
        }
        agent.onState = { [weak self] state in
            guard let self else { return }
            stateLock.withLock {
                self.agentConnected = state == .connected
                if !self.agentConnected { self.lastStatus = nil }
            }
            toWatch(.phoneLink(connected: state == .connected))
            onAgentState?(state)
        }
    }

    public func start() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        agent.start()
    }

    public func stop() {
        agent.stop()
    }

    /// Link state + latest status, for a watch that just became reachable.
    private func resyncWatch() {
        let (connected, status) = stateLock.withLock { (agentConnected, lastStatus) }
        toWatch(.phoneLink(connected: connected))
        if connected, let status { toWatch(.agent(status)) }
    }

    private func reportReachability(_ session: WCSession) {
        let reachable = session.isReachable
        if reachable { resyncWatch() }
        DispatchQueue.main.async { self.onWatchReachable?(reachable) }
    }

    private func toWatch(_ frame: LinkFrame) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessageData(frame.encoded(), replyHandler: nil, errorHandler: nil)
    }

    private func perform(_ actions: [PhoneAction], reply: ((Data) -> Void)?) {
        var replied = false
        for action in actions {
            switch action {
            case .relayMotion(let d): agent.relayMotion(d)
            case .relayIntent(let d): agent.relayIntent(d)
            case .relayReliable(let d): agent.relayReliable(d)
            case .replyToWatch(let frame):
                if let reply, !replied { reply(frame.encoded()); replied = true } else { toWatch(frame) }
            case .transcribe(let clip):
                Task {
                    let t = await transcripts.transcript(for: clip)
                    agent.send(t)
                    await MainActor.run { self.onTranscript?(t) }
                }
            case .drop:
                break
            }
        }
        if let reply, !replied { reply(Data()) }  // the watch asked for a reply; never leave it hanging
    }

    // MARK: WCSessionDelegate

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        queue.async { self.perform(self.router.fromWatch(messageData), reply: nil) }
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                        replyHandler: @escaping (Data) -> Void) {
        queue.async { self.perform(self.router.fromWatch(messageData), reply: replyHandler) }
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        reportReachability(session)
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
