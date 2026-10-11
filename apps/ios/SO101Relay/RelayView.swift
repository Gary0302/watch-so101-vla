import SO101Link
import SwiftUI

struct RelayView: View {
    @EnvironmentObject var model: RelayModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Agent", value: agentText)
                    LabeledContent("Watch", value: model.watchReachable ? "reachable" : "not reachable")
                    LabeledContent("Mode", value: model.mode.rawValue)
                    LabeledContent("Epoch", value: "\(model.epoch)")
                    if let t = model.lastTranscript { LabeledContent("Last voice", value: t) }
                    if let h = model.lastHaptic { LabeledContent("Last event", value: h) }
                    if let n = model.notice { Text(n).foregroundStyle(.orange) }
                }
                Section("Agent") {
                    TextField("wss://host:8765", text: $model.agentURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Token (≥16 chars)", text: $model.token)
                    TextField("Cert SHA-256 pin (optional)", text: $model.pinnedCertSHA256)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                }
                .disabled(model.running)
                Section {
                    if model.running {
                        Button("Disconnect", role: .destructive) { model.stop() }
                    } else {
                        Button("Connect") { Task { await model.start() } }.disabled(!model.canStart)
                    }
                }
                Section {
                    Button(action: model.sendStop) {
                        Text("STOP / HOLD").font(.title2.bold()).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.agentState != .connected)
                } footer: {
                    Text("Software stop only. The physical E-stop on the robot is the real safety device.")
                }
            }
            .navigationTitle("SO101 Relay")
        }
    }

    private var agentText: String {
        switch model.agentState {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .idle: return "off"
        case .waitingToReconnect(let after): return String(format: "retry in %.1fs", after)
        }
    }
}
