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
    }

    private var detachedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Display detached \u{2197}").foregroundStyle(.secondary)
            Text("Close the detached window to re-embed it here.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
}
