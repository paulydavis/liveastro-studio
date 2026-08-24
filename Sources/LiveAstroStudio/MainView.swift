import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.selectedTab) {
                    ForEach(AppModel.MainTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer()
                Button {
                    model.nightVisionOn.toggle()
                    model.applyNightVision()
                } label: {
                    Image(systemName: model.nightVisionOn ? "moon.fill" : "moon")
                        .foregroundStyle(model.nightVisionOn ? Color.red : Color.primary)
                }
                .help("Red night-vision screen tint (whole display) — for dark-adapted viewing at the scope. Fine-tune brightness under Setup ▸ Night vision.")
                if model.selectedTab == .live {
                    Button { openWindow(id: "broadcast"); model.isDetached = true } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }.help("Detach the display into its own window (for OBS capture / second monitor)")
                     .disabled(model.isDetached)
                }
            }.padding(8)
            Divider()
            switch model.selectedTab {
            case .live:  model.isDetached ? AnyView(detachedPlaceholder) : AnyView(BroadcastView(configuresWindow: false))
            case .setup: AnyView(ControlView())
            case .help:  AnyView(HelpView())
            }
        }
        .onAppear {
            // Wires BroadcastDeps.openBroadcastWindow (AppModel can't touch
            // SwiftUI's openWindow action itself) to the same path the Detach
            // button uses below.
            model.openBroadcastWindowHandler = { openWindow(id: "broadcast") }
        }
    }

    private var detachedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Display detached \u{2197}").foregroundStyle(.secondary)
            Text("Close the detached window to re-embed it here.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
}
