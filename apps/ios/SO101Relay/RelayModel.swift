// iPhone app state: owns the PhoneRelay (WCSession <-> agent WebSocket) and shows what it sees.
// The phone never decides robot state; it relays and transcribes.

import Foundation
import SO101Link
import SO101Protocol
import SO101Voice
import SwiftUI
import UIKit

@MainActor
final class RelayModel: ObservableObject {
    @AppStorage("agentURL") var agentURL = "wss://169.233.72.12:8765"
    @AppStorage("pinnedCertSHA256") var pinnedCertSHA256 = ""
    @Published var token = Keychain.get("gatewayToken") ?? ""

    @Published private(set) var agentState: AgentConnection.State = .idle
    @Published private(set) var watchReachable = false
    @Published private(set) var mode: Mode = .disconnected
    @Published private(set) var epoch = 0
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastHaptic: String?
    @Published private(set) var notice: String?
    @Published private(set) var running = false
    @Published private(set) var debugLines: [String] = []

    private var relay: PhoneRelay?
    private let sessionId = "phone-\(UUID().uuidString.prefix(8))"

    var canStart: Bool {
        URL(string: agentURL)?.scheme.map { ["ws", "wss"].contains($0) } == true && token.count >= 16
    }

    func start() async {
        guard canStart, let url = URL(string: agentURL) else { return }
        Keychain.set("gatewayToken", token)
        notice = nil
        guard let transcriber = AppleSpeechTranscriber() else {
            notice = "zh-TW speech recognition unavailable"
            return
        }
        let pin = pinnedCertSHA256.trimmingCharacters(in: .whitespaces)
        let agent = AgentConnection(config: .init(url: url, token: token, sessionId: sessionId,
                                                  pinnedCertSHA256: pin.isEmpty ? nil : pin))
        let relay = PhoneRelay(agent: agent, transcriber: transcriber)
        relay.onAgentState = { [weak self] s in Task { @MainActor in self?.agentState = s } }
        relay.onWatchReachable = { [weak self] r in Task { @MainActor in self?.watchReachable = r } }
        relay.onTranscript = { [weak self] t in Task { @MainActor in self?.lastTranscript = t.text ?? "(no speech)" } }
        agent.onMessage = { [weak self] msg in Task { @MainActor in self?.apply(msg) } }
        relay.trace.onChange = { [weak self, weak relay] in
            let lines = relay?.trace.lines ?? []
            Task { @MainActor in self?.debugLines = lines }
        }
        self.relay = relay
        relay.start()
        running = true
        UIApplication.shared.isIdleTimerDisabled = true  // v1: the phone app stays in the foreground
        // Don't hold the connection hostage to the permission prompt; without it, transcripts are null
        // and the agent rejects the task (fails closed).
        #if DEBUG
        if ProcessInfo.processInfo.environment["SO101_SKIP_PERMISSION_PROMPTS"] == "1" { return }
        #endif
        if !(await AppleSpeechTranscriber.requestAuthorization()) {
            notice = "Speech permission denied — voice tasks will be rejected"
        }
    }

    #if DEBUG
    /// Simulator testing: `SIMCTL_CHILD_SO101_AGENT_URL=... SIMCTL_CHILD_SO101_TOKEN=... xcrun simctl launch ...`
    func autoConnectFromEnvironment() async {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SO101_AGENT_URL"], let token = env["SO101_TOKEN"], !running else { return }
        agentURL = url
        self.token = token
        await start()
    }
    #endif

    func stop() {
        relay?.stop()
        relay = nil
        running = false
        agentState = .idle
        mode = .disconnected
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Emergency path from the phone too; uses the epoch the phone is showing.
    func sendStop() {
        _ = relay?.agent.sendIntent(.stop, source: "phone-stop-button")
    }

    private func apply(_ msg: FromAgent) {
        switch msg {
        case .status(let s):
            mode = s.mode
            epoch = s.controlEpoch
        case .haptic(let h):
            lastHaptic = h.display
        case .error(let e):
            notice = e.reason
        case .ack(let a) where a.result != .accepted && a.result != .duplicate:
            notice = "\(a.result.rawValue): \(a.reason)"
        default:
            break
        }
    }
}
