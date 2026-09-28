// Avatar.swift — 28 pt monogram circles (UI-SPEC §6 shared row
// conventions; G6: no photo FFI yet). Groups use `person.2.fill`.
import SwiftUI

struct Avatar: View {
    let name: String
    var isGroup = false
    var diameter: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Palette.avatarFill(for: name))
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(AppFont.monogram(diameter * 0.9))
                    .foregroundStyle(Palette.avatarText)
            } else {
                Text(Self.initials(name))
                    .font(AppFont.monogram(diameter))
                    .foregroundStyle(Palette.avatarText)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "—" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
