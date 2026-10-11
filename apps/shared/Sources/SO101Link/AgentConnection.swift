// iPhone -> Local Robot Agent link over WSS (SPEC §3, §9).
//
// * Bearer-token auth on the handshake.
// * Motion is latest-only with at most one send in flight.
// * Control intents are resent until ACKed (IntentTracker).
// * Reconnects with backoff. While disconnected nothing is queued for later:
//   the agent has already gone to HOLD on its own watchdog.
//
// All state lives on one serial queue; callbacks are delivered on `callbackQueue`.

import CryptoKit
import Foundation
import SO101Protocol

public final class AgentConnection: NSObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case waitingToReconnect(after: TimeInterval)
    }

    public struct Config: Sendable {
        public var url: URL
        public var token: String
        public var sessionId: String
        /// SHA-256 (hex) of the gateway's self-signed leaf certificate. When set, that exact
        /// certificate is trusted and nothing else; no profile install, no ATS exception.
        public var pinnedCertSHA256: String?

        public init(url: URL, token: String, sessionId: String, pinnedCertSHA256: String? = nil) {
            self.url = url
            self.token = token
            self.sessionId = sessionId
            self.pinnedCertSHA256 = pinnedCertSHA256?.lowercased().replacingOccurrences(of: ":", with: "")
        }
    }

    public var onState: ((State) -> Void)?
    public var onError: ((String) -> Void)?
    public var onMessage: ((FromAgent) -> Void)?
    public var onIntentOutcome: ((IntentTracker.Outcome) -> Void)?
    /// Raw agent JSON, for relaying status/haptics to the Watch unchanged.
    public var onRawMessage: ((Data) -> Void)?

    public let config: Config
    private let queue = DispatchQueue(label: "so101.agent-connection")
    private let callbackQueue: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var state: State = .idle
    private var wanted = false
    private var backoff: TimeInterval = 0.5
    private var motion = LatestOnly<Data>()
    private var motionInFlight = false
    private let intents = IntentTracker()
    private var timer: DispatchSourceTimer?
    /// Latest control_epoch seen in robot.status / control.ack.
    private(set) public var epoch = 0
    private(set) public var mode: Mode = .disconnected

    public init(config: Config, callbackQueue: DispatchQueue = .main) {
        self.config = config
        self.callbackQueue = callbackQueue
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(pin: config.pinnedCertSHA256),
                             delegateQueue: nil)
    }

    // MARK: public API (thread-safe)

    public func start() {
        queue.async {
            self.wanted = true
            self.connect()
            self.startTimer()
        }
    }

    public func stop() {
        queue.async {
            self.wanted = false
            self.timer?.cancel()
            self.timer = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.set(.idle)
        }
    }

    /// Already-encoded agent JSON from the Watch (watch.motion). Latest-only.
    public func relayMotion(_ json: Data) {
        queue.async {
            self.motion.put(json)
            self.pumpMotion()
        }
    }

    /// Already-encoded agent JSON that must not be dropped silently (lifecycle, transcript).
    public func relayReliable(_ json: Data) {
        queue.async { self.send(json) }
    }

    public func send<T: TypedMessage>(_ message: T) {
        guard let data = try? ProtocolCoder.encode(message) else { return }
        relayReliable(data)
    }

    /// A control intent built on the Watch. Its epoch is the one the Watch UI showed when the
    /// user tapped, never re-stamped here: a tap meant for VLA_RUNNING must not become a
    /// take-over just because the phone has already heard about AWAIT_RECALIBRATION.
    public func relayIntent(_ json: Data) {
        queue.async {
            guard let msg = try? ProtocolCoder.decode(ControlIntent.self, from: json) else { return }
            self.intents.track(msg, now: Date())
            self.send(json)
        }
    }

    /// Phone-originated intent (e.g. the phone's own STOP button), stamped with the latest epoch.
    @discardableResult
    public func sendIntent(_ intent: Intent, source: String) -> String {
        queue.sync {
            let msg = intents.make(intent, sessionId: config.sessionId, epoch: epoch, source: source, now: Date())
            if let data = try? ProtocolCoder.encode(msg) { send(data) }
            return msg.requestId
        }
    }

    // MARK: internals (on `queue`)

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        callbackQueue.async { self.onState?(s) }
    }

    private func connect() {
        guard wanted, task == nil else { return }
        var req = URLRequest(url: config.url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        let t = session.webSocketTask(with: req)
        task = t
        motionInFlight = false
        set(.connecting)
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard t === self.task else { return }
                switch result {
                case .failure(let error):
                    self.report(error, response: t.response)
                    self.dropConnection()
                case .success(let message):
                    if self.state != .connected {
                        self.set(.connected)
                        self.backoff = 0.5
                    }
                    switch message {
                    case .string(let s): self.handle(Data(s.utf8))
                    case .data(let d): self.handle(d)
                    @unknown default: break
                    }
                    self.receive(on: t)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? ProtocolCoder.decodeFromAgent(data) else { return }
        switch msg {
        case .status(let s):
            epoch = s.controlEpoch
            mode = s.mode
        case .ack(let a):
            epoch = max(epoch, a.controlEpoch)
            mode = a.mode
            if let outcome = intents.receive(a) {
                callbackQueue.async { self.onIntentOutcome?(outcome) }
            }
        default:
            break
        }
        callbackQueue.async {
            self.onRawMessage?(data)
            self.onMessage?(msg)
        }
    }

    private func send(_ data: Data) {
        guard let t = task else { return }
        t.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] err in
            guard let self, err != nil else { return }
            self.queue.async { if t === self.task { self.dropConnection() } }
        }
    }

    private func pumpMotion() {
        guard !motionInFlight, let t = task, state == .connected, let next = motion.take() else { return }
        motionInFlight = true
        t.send(.string(String(decoding: next, as: UTF8.self))) { [weak self] err in
            guard let self else { return }
            self.queue.async {
                guard t === self.task else { return }
                self.motionInFlight = false
                if err != nil { self.dropConnection() } else { self.pumpMotion() }
            }
        }
    }

    /// Why the socket failed, for the debug trail: "connecting…" forever tells you nothing.
    private func report(_ error: Error, response: URLResponse?) {
        let e = error as NSError
        var text = "\(e.domain) \(e.code): \(e.localizedDescription)"
        if let http = response as? HTTPURLResponse { text = "HTTP \(http.statusCode) (token?) · " + text }
        if e.code == NSURLErrorCancelled, config.pinnedCertSHA256 != nil { text += " (cert pin mismatch?)" }
        if e.code == NSURLErrorTimedOut || e.code == NSURLErrorCannotConnectToHost {
            text += " (Local Network permission / same Wi-Fi?)"
        }
        callbackQueue.async { self.onError?(text) }
    }

    private func dropConnection() {
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        mode = .disconnected
        guard wanted else { return set(.idle) }
        let delay = backoff
        backoff = min(backoff * 2, 4)
        set(.waitingToReconnect(after: delay))
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let (resend, outcomes) = self.intents.tick(now: Date())
            for intent in resend {
                if let d = try? ProtocolCoder.encode(intent) { self.send(d) }
            }
            for o in outcomes { self.callbackQueue.async { self.onIntentOutcome?(o) } }
        }
        t.resume()
        timer = t
    }
}

/// Server-trust handling: pinned leaf certificate if configured, otherwise the system default.
final class PinningDelegate: NSObject, URLSessionDelegate {
    let pin: String?

    init(pin: String?) {
        self.pin = pin
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let pin else {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
