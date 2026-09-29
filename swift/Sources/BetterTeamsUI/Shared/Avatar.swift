// Avatar.swift — 28 pt person circles (UI-SPEC §6 shared row
// conventions). Real profile photo when the person has one (disk-cached,
// fetched in the background); initials otherwise. Groups use
// `person.2.fill`. Callers' presence/mute badges overlay this view, so
// they stay on top of the photo.
import OstMacCore
import SwiftUI

struct Avatar: View {
    let name: String
    var isGroup = false
    var diameter: CGFloat = 28
    /// The person, when the caller knows their id/email. Name-only
    /// avatars still get a photo once the directory knows the name.
    var person: ContactRef? = nil

    @Environment(\.windowModel) private var model

    var body: some View {
        if !isGroup, let photos = model?.app?.photos, !name.isEmpty {
            let ref = person ?? ContactRef(name: name)
            PhotoAvatar(ref: ref, slot: photos.slot(for: ref), photos: photos) { monogram }
                .frame(width: diameter, height: diameter)
                .accessibilityHidden(true)
        } else {
            monogram
                .frame(width: diameter, height: diameter)
                .accessibilityHidden(true)
        }
    }

    private var monogram: some View {
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
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "—" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Photo over the monogram. The slot is pre-filled from cache, so a
/// known photo is there on first render; a fetched one replaces the
/// initials in place (no blank frame in between).
private struct PhotoAvatar<Fallback: View>: View {
    let ref: ContactRef
    @ObservedObject var slot: PhotoSlot
    let photos: ProfilePhotoStore
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        ZStack {
            fallback()
            if let image = slot.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            }
        }
        .onAppear { photos.request(ref) }
        .onChange(of: ref) { _, next in photos.request(next) }
        .onDisappear { photos.cancel(ref) }
    }
}
