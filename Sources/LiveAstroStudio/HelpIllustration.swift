import SwiftUI

struct HelpIllustration {
    let resource: String
    let accessibilityDescription: String
    let steps: [String]
    var image: NSImage? {
        Bundle.module.url(forResource: resource, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    static func forTopic(_ title: String) -> HelpIllustration? {
        switch title {
        case "Quick Start":
            return Self(resource: "help-source",
                accessibilityDescription: "Capture example showing the Source selector, Choose folder button, Filename prefix and calibration overview.",
                steps: ["Source: choose Raw subs for individual light exposures, or Stacker output for an external stack.",
                        "Choose: select the folder where new files actually appear. /Example/Capture/Lights is only an example path.",
                        "Filename prefix: match your filenames, or leave empty. Light_ is an example, not a required value."])
        case "Calibration":
            return Self(resource: "help-calibration",
                accessibilityDescription: "Expanded calibration controls with Add darks, Add bias, Flats and Dark-flats folder choices, and the optional light-offset checkbox left off.",
                steps: ["Open Configure calibration in Capture to reach these controls. Add darks and Add bias populate the reusable library.",
                        "Choose the session's Flats and optional Dark-flats folders. None means no folder selected in this example.",
                        "The light-offset option is not a general dust fix. Read its explanation before enabling it; verify actual calibration in the session log."])
        case "Display Adjustments":
            return Self(resource: "help-display",
                accessibilityDescription: "Idle Display screen: Currently live above Your edit on the left, adjustment sliders on the right, Revert and Apply below. Image panes are empty because no session is running.",
                steps: ["Currently live is the delivered broadcast; Your edit is an approximate pending preview. The empty panes here are an idle example, not a failed capture.",
                        "Adjust the controls, then Apply to commit or Revert to discard pending changes. The buttons are disabled here because there is no pending edit.",
                        "These settings affect the display, not the saved linear master. Values pictured are examples, not a prescription for every target."])
        case "Session Outputs":
            return Self(resource: "help-outputs",
                accessibilityDescription: "Setup footer showing Session outputs with Folder, Master, Replay and More outputs. Folder and Master are disabled in this replay-only example.",
                steps: ["After End Session finishes, use Folder, Master or Replay to open the available result.",
                        "More outputs holds the summary, CSV and support shortcuts when available.",
                        "A disabled button means that output is unavailable. This replay-only example has no session folder or master attached."])
        default: return nil
        }
    }
}

struct HelpIllustrationView: View {
    let illustration: HelpIllustration
    @State private var enlarged = false
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("Screenshot guide — v3.6.9 example", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let image = illustration.image {
                    Button { enlarged = true } label: {
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(illustration.accessibilityDescription + " Open larger screenshot.")
                    .help("Open larger screenshot")
                    Text("Click the image to enlarge. Example settings; your session may differ.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Screenshot unavailable. The instructions below still apply.").foregroundStyle(.secondary)
                }
                ForEach(Array(illustration.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(SetupStyle.accent)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.vertical, 10)
        }
        .sheet(isPresented: $enlarged) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("v3.6.9 — example controls").font(.headline)
                    Spacer()
                    Button("Done") { enlarged = false }.keyboardShortcut(.cancelAction)
                }
                if let image = illustration.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(illustration.accessibilityDescription)
                }
                Text(illustration.accessibilityDescription).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 920)
        }
    }
}
