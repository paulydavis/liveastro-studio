import SwiftUI

/// A Form toggle row with a visible ⓘ info button next to the label. macOS `Form`
/// only attaches `.help()` tooltips to the switch control, not the label text, so
/// hovering the label showed nothing. A tap-to-reveal info button is an explicit,
/// discoverable affordance that doesn't depend on hover tracking.
///
/// Shared across the Setup sub-tab views (Capture, Display) — kept here as the
/// single copy so no destination file redeclares it.
func helpToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
    HStack(spacing: 6) {
        Text(title)
        InfoButton(text: help)
        Spacer()
        Toggle("", isOn: isOn).labelsHidden()
    }
}

/// Small ⓘ affordance that reveals its help text in a popover on tap (and, as a
/// bonus, a tooltip on hover — `.help()` works reliably on a Button control).
struct InfoButton: View {
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300)
        }
    }
}

struct HealthItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct WorkflowActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
