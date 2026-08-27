import SwiftUI
import LiveAstroCore

struct StatsView: View {
    @Bindable var model: AppModel

    private var accepted: Int { model.subFrames.filter { $0.outcome != .rejected }.count }
    private var rejected: Int { model.subFrames.filter { $0.outcome == .rejected }.count }
    private var meanWeight: Float {
        let stacked = model.subFrames.filter { $0.outcome == .stacked }
        guard !stacked.isEmpty else { return 0 }
        return stacked.map(\.weight).reduce(0, +) / Float(stacked.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            rollup
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.subFrames.reversed(), id: \.index) { row($0) }   // newest first
                }
            }
            Divider()
            footer
        }
    }

    private var rollup: some View {
        HStack(spacing: 16) {
            stat("Accepted", "\(accepted)")
            stat("Rejected", "\(rejected)")
            stat("Flagged", "\(model.flaggedCount)")
            stat("Mean weight", String(format: "%.2f", meanWeight))
            Spacer()
            StarCountSparkline(values: model.subFrames.map { $0.starCount })
                .frame(width: 120, height: 28)
        }
        .padding(10)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func row(_ r: SubFrameRecord) -> some View {
        HStack {
            Text("#\(r.index)").frame(width: 48, alignment: .leading).monospacedDigit()
            Text("★\(r.starCount)").frame(width: 60, alignment: .leading).monospacedDigit()
            Text(String(format: "σ%.2f", r.backgroundSigma)).frame(width: 64, alignment: .leading).monospacedDigit()
            Text(String(format: "×%.2f", r.weight)).frame(width: 56, alignment: .leading).monospacedDigit()
            statusBadge(r)
            Spacer()
            if r.outcome != .rejected {
                Toggle("Reject", isOn: Binding(
                    get: { r.rejectedByUser },
                    set: { _ in model.toggleReject(index: r.index) }))
                    .toggleStyle(.button).controlSize(.small)
                    .disabled(model.isRestacking)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(r.rejectedByUser ? Color.red.opacity(0.12) : .clear)
        .opacity(r.outcome == .rejected ? 0.5 : 1)
    }

    private func statusBadge(_ r: SubFrameRecord) -> some View {
        let (text, color): (String, Color) = switch r.outcome {
            case .reference: ("ref", .blue)
            case .stacked:   ("stacked", .green)
            case .rejected:  ("rejected", .orange)
        }
        return Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }

    private var footer: some View {
        HStack {
            if model.isRestacking { ProgressView().controlSize(.small); Text("Re-stacking…").foregroundStyle(.secondary) }
            else { Text(model.flaggedCount == 0 ? "No subs flagged" : "\(model.flaggedCount) flagged").foregroundStyle(.secondary) }
            Spacer()
            Button("Re-stack without flagged") { model.restackWithoutFlagged() }
                .disabled(model.flaggedCount == 0 || model.isRestacking)
        }
        .padding(10)
    }
}

/// Minimal inline sparkline of per-sub star counts so a cloud band / focus drift reads at a glance.
private struct StarCountSparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let maxV = values.max(), maxV > 0 {
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat(v) / CGFloat(maxV))
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }.stroke(.secondary, lineWidth: 1)
            }
        }
    }
}
