import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// What you chose to show on your profile: three achievements, three cards and a photo.
@MainActor
final class Profile: ObservableObject {
    nonisolated static let slots = 3

    struct State: Codable {
        var achievements: [String?] = Array(repeating: nil, count: Profile.slots)
        var cards: [String?] = Array(repeating: nil, count: Profile.slots)
    }

    @Published private(set) var state = State()
    @Published private(set) var photo: NSImage?
    /// The stored copy, as it is sent to the community.
    var photoData: Data? { photo == nil ? nil : try? Data(contentsOf: Self.photoURL) }

    /// "29 de octubre de 2026" from "2026-10-29".
    nonisolated static func longDay(_ ymd: String) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd).map { $0.formatted(.dateTime.day().month(.wide).year().locale(Fmt.es)) }
    }
    private let persist: Bool
    private static let dir = KeyStore.fileURL.deletingLastPathComponent()
    private static let url = dir.appendingPathComponent("profile.json")
    private static let photoURL = dir.appendingPathComponent("profile.jpg")

    init(persist: Bool = true) {
        self.persist = persist
        guard persist else { return }
        if let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(State.self, from: d) {
            state.achievements = Self.padded(s.achievements)
            state.cards = Self.padded(s.cards)
        }
        photo = NSImage(contentsOf: Self.photoURL)
    }

    private static func padded(_ a: [String?]) -> [String?] {
        Array((a + Array(repeating: nil, count: slots)).prefix(slots))
    }

    /// The three shown: your choices that still hold, and the best of the rest in the empty places.
    static func fill(_ chosen: [String?], ranked: [String]) -> [String?] {
        var out = padded(chosen).map { id in id.flatMap { ranked.contains($0) ? $0 : nil } }
        var seen = Set<String>()
        for i in out.indices { if let id = out[i], !seen.insert(id).inserted { out[i] = nil } }
        var rest = ranked.filter { !seen.contains($0) }[...]
        for i in out.indices where out[i] == nil { out[i] = rest.popFirst() }
        return out
    }

    /// Puts `id` in a place; if it was already shown, the two trade places.
    private static func place(_ id: String, at slot: Int, in shown: [String?]) -> [String?] {
        var out = shown
        if let old = out.firstIndex(of: id) { out[old] = out[slot] }
        out[slot] = id
        return out
    }

    func setAchievement(_ id: String, slot: Int, shown: [String?]) {
        state.achievements = Self.place(id, at: slot, in: shown)
        save()
    }

    func setCard(_ id: String, slot: Int, shown: [String?]) {
        state.cards = Self.place(id, at: slot, in: shown)
        save()
    }

    /// Keeps a small square copy; the original file is never touched.
    func setPhoto(_ image: NSImage) {
        guard let square = Self.square(image, side: 256) else { return }
        photo = square
        guard persist, let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpg.write(to: Self.photoURL, options: .atomic)
    }

    func removePhoto() {
        photo = nil
        if persist { try? FileManager.default.removeItem(at: Self.photoURL) }
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Elige tu foto de perfil"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        setPhoto(image)
    }

    private static func square(_ image: NSImage, side: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - s) / 2, y: (cg.height - s) / 2, width: s, height: s)
        guard let cut = cg.cropping(to: crop),
              let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
    }

    private func save() {
        guard persist, let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

// MARK: - Tab

struct ProfileTab: View {
    @ObservedObject var profile: Profile
    @ObservedObject var achievements: Achievements
    @ObservedObject var album: Album
    @ObservedObject var community: Community
    let name: String
    @State private var inCommunity = ProfileTab.snapshotCommunity
    nonisolated(unsafe) static var snapshotCommunity = false

    @State private var pickingAchievement: Int?
    @State private var pickingCard: Int?
    @State private var dropping = false

    /// Yours, best first: higher tier, then newer. One you prestiged and are earning again
    /// still counts here, at the tier you reached.
    private var earned: [Achievement] { Self.earned(achievements) }
    private var owned: [CardDef] { Self.owned(album) }

    static func earned(_ achievements: Achievements) -> [Achievement] {
        allAchievements
            .filter { achievements.state.unlocked[$0.id] != nil }
            .sorted { a, b in
                let ta = achievements.tier(a.id).rawValue, tb = achievements.tier(b.id).rawValue
                return ta != tb ? ta > tb : achievements.state.unlocked[a.id]! > achievements.state.unlocked[b.id]!
            }
    }

    /// Your cards, best first: finish, then rarity, then the ones you have had longest.
    static func owned(_ album: Album) -> [CardDef] {
        allCards
            .filter { album.state.cards[$0.id] != nil }
            .sorted { a, b in
                let oa = album.state.cards[a.id]!, ob = album.state.cards[b.id]!
                let fa = oa.finishes.max() ?? .normal, fb = ob.finishes.max() ?? .normal
                if fa != fb { return fa > fb }
                if a.rarity != b.rarity { return a.rarity > b.rarity }
                return oa.first < ob.first
            }
    }

    var body: some View {
        let earned = earned, owned = owned
        let shownAchievements = Profile.fill(profile.state.achievements, ranked: earned.map(\.id))
        let shownCards = Profile.fill(profile.state.cards, ranked: owned.map(\.id))

        let page = VStack(alignment: .leading, spacing: 12) {
                header
                HStack(spacing: 8) {
                    ProfileStat(title: "Logros", have: earned.count, of: allAchievements.count)
                    ProfileStat(title: "Cromos", have: owned.count, of: allCards.count)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label2(text: "Cromos destacados")
                    Vitrine {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(0..<Profile.slots, id: \.self) { i in
                                let c = shownCards[i].flatMap { id in owned.first { $0.id == id } }
                                Button { pickingCard = i } label: {
                                    Group {
                                        if let c, let o = album.state.cards[c.id] {
                                            CardFace(card: c, art: o.shownArt, finish: o.shownFinish, width: Self.cardWidth)
                                                .modifier(HoloHoverTilt(enabled: o.shownFinish != .normal, maxAngle: 14))
                                                .shadow(color: .black.opacity(0.55), radius: 6, y: 5)
                                        } else {
                                            EmptySlot(radius: Self.cardWidth * 0.07, onDark: true)
                                                .frame(width: Self.cardWidth, height: Self.cardWidth * 1.5)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .disabled(owned.isEmpty)
                                .help(c.map { "\($0.title) · clic para cambiarlo" } ?? "Aún no tienes cromos que destacar")
                                .popover(isPresented: Binding(get: { pickingCard == i }, set: { if !$0 { pickingCard = nil } })) {
                                    CardPicker(current: c?.id, state: { album.state.cards[$0] }) {
                                        profile.setCard($0, slot: i, shown: shownCards)
                                        pickingCard = nil
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label2(text: "Logros destacados")
                    Vitrine {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<Profile.slots, id: \.self) { i in
                                let a = shownAchievements[i].flatMap { id in earned.first { $0.id == id } }
                                Button { pickingAchievement = i } label: {
                                    AchievementBadge(achievement: a,
                                                     tier: a.flatMap { achievements.hasTiers($0.id) ? achievements.tier($0.id) : nil })
                                }
                                .buttonStyle(.plain)
                                .disabled(earned.isEmpty)
                                .help(a?.detail ?? "Aún no tienes logros que destacar")
                                .popover(isPresented: Binding(get: { pickingAchievement == i }, set: { if !$0 { pickingAchievement = nil } })) {
                                    AchievementPicker(earned: earned, current: a?.id, tier: { achievements.hasTiers($0) ? achievements.tier($0) : nil }) {
                                        profile.setAchievement($0, slot: i, shown: shownAchievements)
                                        pickingAchievement = nil
                                    }
                                }
                            }
                        }
                    }
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)

        let shared = SharedProfile.make(profile: profile, achievements: achievements, album: album)
        Group {
            if inCommunity {
                CommunityView(community: community, achievements: achievements) {
                    withAnimation(.smooth(duration: 0.2)) { inCommunity = false }
                }
            } else if isSnapshotRender {
                // Snapshots cannot scroll.
                page
            } else {
                ScrollView(showsIndicators: false) { page }
            }
        }
        // What you show reaches your colleagues as soon as you change it.
        .task(id: shared) { await community.sync(shared, photo: profile.photoData) }
        .onChange(of: profile.photo) { _, _ in Task { await community.sync(shared, photo: profile.photoData) } }
    }

    static let cardWidth: CGFloat = 80

    private var since: String? { achievements.state.firstDay.flatMap(Profile.longDay) }

    private var header: some View {
        HStack(spacing: 12) {
            Button { profile.choosePhoto() } label: {
                Avatar(photo: profile.photo, name: name, size: 56)
                    .overlay(Circle().strokeBorder(dropping ? Theme.brand : Color.primary.opacity(0.1), lineWidth: dropping ? 2 : 1))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.onBrand)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.brand))
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    }
            }
            .buttonStyle(.plain)
            .modifier(PhotoActions(profile: profile, dropping: $dropping))
            .help("Cambia tu foto: elige una imagen o arrástrala aquí. Clic derecho para quitarla")

            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "Tu perfil" : name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if let since {
                    Text("Miembro desde el \(since)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                }
                if achievements.prestigeTotal > 0 {
                    Text("\(achievements.prestigeTotal) de prestigio").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            CornerButton(symbol: "person.2.fill", help: "Ver la comunidad") {
                withAnimation(.smooth(duration: 0.2)) { inCommunity = true }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pieces

/// Right click and drag and drop for the photo; neither can be drawn in a snapshot.
private struct PhotoActions: ViewModifier {
    let profile: Profile
    @Binding var dropping: Bool

    func body(content: Content) -> some View {
        if isSnapshotRender {
            content
        } else {
            content
                .contextMenu {
                    Button("Elegir foto…") { profile.choosePhoto() }
                    if profile.photo != nil { Button("Quitar foto") { profile.removePhoto() } }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: NSImage.self) { object, _ in
                        guard let image = object as? NSImage else { return }
                        Task { @MainActor in profile.setPhoto(image) }
                    }
                    return true
                }
        }
    }
}

struct Avatar: View {
    let photo: NSImage?
    let name: String
    let size: CGFloat

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "" : String(parts).uppercased()
    }

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                    } else {
                        Text(initials).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}

struct ProfileStat: View {
    let title: String
    let have: Int
    let of: Int

    var body: some View {
        let share = of > 0 ? Double(have) / Double(of) : 0
        VStack(alignment: .leading, spacing: 5) {
            Label2(text: title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int((share * 100).rounded())) %").font(.system(size: 17, weight: .semibold).monospacedDigit())
                Text("\(have) de \(of)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if have > 0 { Capsule().fill(Theme.brand).frame(width: max(g.size.width * share, 4)) }
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct EmptySlot: View {
    let radius: CGFloat
    var onDark = false
    var plus = true
    var body: some View {
        let ink = onDark ? Color.white : Color.primary
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(ink.opacity(onDark ? 0.3 : 0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay { if plus { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.4)) } }
            .contentShape(Rectangle())
    }
}

/// A display case: dark felt, a spotlight over each place and a glass shelf underneath.
struct Vitrine<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content()
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [hex(0x23262D), hex(0x0E0F12)], startPoint: .top, endPoint: .bottom)
                    HStack(spacing: 0) {
                        ForEach(0..<Profile.slots, id: \.self) { _ in
                            EllipticalGradient(colors: [.white.opacity(0.2), .white.opacity(0.05), .clear],
                                               center: .top, startRadiusFraction: 0, endRadiusFraction: 0.95)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // The shelf: a lit glass edge and its thickness.
                    VStack(spacing: 0) {
                        Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(height: 1)
                        LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 9)
                    }
                }
            }
            // Glass in front: a slanted glare.
            .overlay {
                LinearGradient(stops: [.init(color: .white.opacity(0.1), location: 0), .init(color: .white.opacity(0.03), location: 0.32),
                                       .init(color: .clear, location: 0.33)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                        lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

struct AchievementBadge: View {
    let achievement: Achievement?
    let tier: PrestigeTier?
    /// Somebody else's hidden achievement: shown sealed.
    var secret = false
    var plus = true

    var body: some View {
        VStack(spacing: 6) {
            if achievement != nil, secret {
                Image(systemName: "lock.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text("Logro oculto").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .frame(height: 26, alignment: .top)
            } else if let achievement {
                Text(achievement.emoji)
                    .font(.system(size: 24))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                                             center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 34)))
                    .overlay {
                        Circle().strokeBorder(tier?.gradient ?? LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.15)],
                                                                                startPoint: .top, endPoint: .bottom),
                                              lineWidth: tier == nil ? 1 : 2.5)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 4)
                Text(achievement.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            } else {
                EmptySlot(radius: 23, onDark: true, plus: plus).frame(width: 46, height: 46)
                Text("Vacío").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).frame(height: 26, alignment: .top)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct AchievementPicker: View {
    let earned: [Achievement]
    let current: String?
    let tier: (String) -> PrestigeTier?
    let pick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(earned) { a in
                    Button { pick(a.id) } label: {
                        HStack(spacing: 8) {
                            Text(a.emoji).font(.system(size: 15))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .overlay { if let t = tier(a.id) { Circle().strokeBorder(t.gradient, lineWidth: 1.5) } }
                            Text(a.title).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            if a.id == current { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 240)
        .frame(maxHeight: 280)
    }
}

/// Your cards laid out like the album, to choose one.
private struct CardPicker: View {
    let current: String?
    let state: (String) -> OwnedCard?
    let pick: (String) -> Void

    var body: some View {
        ScrollView {
            CardCatalog(scope: "picker", only: { state($0.id) != nil }, owned: { state($0.id) != nil }) { c in
                Button { pick(c.id) } label: {
                    CardFace(card: c, art: state(c.id)?.shownArt ?? .base, finish: state(c.id)?.shownFinish ?? .normal, width: 54)
                        .overlay {
                            if c.id == current {
                                RoundedRectangle(cornerRadius: 54 * 0.07).fill(.black.opacity(0.45))
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(c.title)
            }
            .padding(12)
        }
        .frame(width: 5 * 54 + 4 * 9 + 24)
        .frame(maxHeight: 340)
    }
}
