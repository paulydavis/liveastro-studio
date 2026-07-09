import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            Text(helpText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private var helpText: AttributedString {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8),
              let attr = try? AttributedString(markdown: md,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString("Help unavailable.") }
        return attr
    }
}
