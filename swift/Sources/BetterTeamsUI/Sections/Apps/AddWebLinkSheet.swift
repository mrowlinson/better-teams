// AddWebLinkSheet.swift — Add Web Link… (UI-SPEC §7.2 list toolbar):
// URL, name and symbol; Cancel + Add, trailing. The new link is selected
// in the library.
import SwiftUI

struct AddWebLinkSheet: View {
    let library: AppsLibrary
    @State private var url = ""
    @State private var name = ""
    @State private var symbol = Self.symbols[0].symbol
    @State private var invalid = false
    @Environment(\.windowModel) private var model

    /// The symbol choices (the link's rail and library glyph).
    static let symbols: [(title: String, symbol: String)] = [
        ("Link", "link"), ("Globe", "globe"), ("Document", "doc.text"), ("Chart", "chart.bar"),
        ("Calendar", "calendar"), ("Checklist", "checklist"), ("Book", "book"), ("Folder", "folder"),
        ("Star", "star"), ("Lightning", "bolt"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Web Link").font(.headline)
            Form {
                TextField("URL", text: $url, prompt: prompt("https://contoso.sharepoint.com/…"))
                TextField("Name", text: $name, prompt: prompt("Optional"))
                Picker("Symbol", selection: $symbol) {
                    ForEach(Self.symbols, id: \.symbol) { s in
                        Label(s.title, systemImage: s.symbol).tag(s.symbol)
                    }
                }
            }
            // A real Spacer: the error label is optional, and an empty
            // view emits no flexible space (the buttons sat leading).
            HStack(spacing: 8) {
                if invalid {
                    Label("Enter a web address.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func prompt(_ s: String) -> Text {
        Text(s).foregroundStyle(Color(nsColor: .placeholderTextColor))
    }

    private func add() {
        guard let app = library.addWebLink(name: name, url: url, symbol: symbol) else {
            invalid = true
            return
        }
        model?.dismissSheet()
        model?.navigator?.select(SectionSelection([app.id]), in: .apps)
    }
}
