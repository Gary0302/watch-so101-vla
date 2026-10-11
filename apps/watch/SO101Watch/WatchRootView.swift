import SO101Protocol
import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    Circle().fill(linkColor).frame(width: 8, height: 8)
                    Text(model.ui.mode.rawValue).font(.caption2.monospaced()).accessibilityIdentifier("mode")
                    Spacer()
                    Text("e\(model.ui.epoch)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    if model.recording { Image(systemName: "mic.fill").foregroundStyle(.red) }
                }
                // Visible button that is also the Double Tap target (SPEC §5.1).
                Button(action: model.primaryAction) {
                    Text(model.ui.pending ? "…" : model.ui.primaryLabel)
                        .font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.ui.primaryEnabled)
                .handGestureShortcut(.primaryAction)
                .accessibilityIdentifier("primary")

                Button(action: model.stop) {
                    Text("STOP").font(.headline.bold()).frame(maxWidth: .infinity)
                }
                .tint(.red)
                .accessibilityIdentifier("stop")
                .disabled(!model.ui.phoneLinked)

                if let n = model.ui.notice {
                    Text(n).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                } else if let h = model.ui.lastHaptic {
                    Text(h).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                // Debug trail (scroll down with the Digital Crown). Newest first.
                Divider().padding(.top, 8)
                Text("phone \(model.ui.phoneLinked ? "ok" : "—") · agent \(model.ui.agentLinked ? "ok" : "—")")
                    .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                ForEach(Array(model.debugLines.prefix(30).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9).monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(line.contains("FAIL") || line.contains("dropped") ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var linkColor: Color {
        if !model.ui.phoneLinked { return .gray }
        return model.ui.agentLinked ? .green : .yellow
    }
}
