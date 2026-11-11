import AppKit
import CryptoKit
import SwiftUI

// MARK: - What is shared

/// The part of a profile that colleagues see. The name is not here: the server takes it from DeskTime.
struct SharedProfile: Codable, Equatable {
    struct Card: Codable, Equatable {
        var id: String
        var art: Art
        var finish: Finish
    }

    struct Badge: Codable, Equatable {
        var id: String
        var tier: Int?
    }

    var since: String?
    var achievementsHave: Int
    var achievementsTotal: Int
    var cardsHave: Int
    var cardsTotal: Int
    var prestige: Int
    var cards: [Card?]
    var achievements: [Badge?]

    @MainActor
    static func make(profile: Profile, achievements: Achievements, album: Album) -> SharedProfile {
        let earned = ProfileTab.earned(achievements), owned = ProfileTab.owned(album)
        return SharedProfile(
            since: achievements.state.firstDay,
            achievementsHave: earned.count, achievementsTotal: allAchievements.count,
            cardsHave: owned.count, cardsTotal: allCards.count,
            prestige: achievements.prestigeTotal,
            cards: Profile.fill(profile.state.cards, ranked: owned.map(\.id)).map { id in
                id.flatMap { id in album.state.cards[id].map { Card(id: id, art: $0.shownArt, finish: $0.shownFinish) } }
            },
            achievements: Profile.fill(profile.state.achievements, ranked: earned.map(\.id)).map { id in
                id.map { Badge(id: $0, tier: achievements.hasTiers($0) ? achievements.tier($0).rawValue : nil) }
            })
    }
}

struct Member: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    /// Grows with every new photo; 0 when there is none.
    let photo: Int
    let profile: SharedProfile

    private enum Keys: String, CodingKey { case id, name, photo }

    init(id: Int, name: String, photo: Int, profile: SharedProfile) {
        self.id = id; self.name = name; self.photo = photo; self.profile = profile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        photo = try c.decodeIfPresent(Int.self, forKey: .photo) ?? 0
        profile = try SharedProfile(from: decoder)
    }
}

// MARK: - Client

/// Talks to the community server. The DeskTime key is sent once, to prove you are a colleague;
/// after that the app uses a token of its own.
@MainActor
final class Community: ObservableObject {
    static let base = URL(string: "https://filmo-time.195-35-25-71.sslip.io")!

    @Published private(set) var members: [Member] = []
    @Published private(set) var me: Int?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var photos: [Int: NSImage] = [:]

    private struct Saved: Codable {
        var token: String
        var id: Int
        /// What the server already has, so nothing is sent twice.
        var pushed: SharedProfile?
        var photoHash: String?
    }

    private struct Failure: Error { let status: Int }

    private let enabled: Bool
    private var saved: Saved?
    private var busy = false
    private var photoVersions: [Int: Int] = [:]
    private static let url = KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("community.json")

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        saved = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        me = saved?.id
    }

    private func store() {
        guard let saved, let d = try? JSONEncoder().encode(saved) else { return }
        try? d.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, type: String? = nil, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 20
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(status: status) }
        return data
    }

    private func register() async throws {
        guard let key = KeyStore.read() else { throw Failure(status: 401) }
        struct Reply: Decodable { let token: String; let id: Int }
        let r = try JSONDecoder().decode(Reply.self, from: try await send("POST", "v1/register", headers: ["X-DeskTime-Key": key]))
        saved = Saved(token: r.token, id: r.id)
        me = r.id
        store()
    }

    /// A call as you. A token the server no longer knows is replaced once.
    private func authed(_ method: String, _ path: String, body: Data? = nil, type: String? = nil) async throws -> Data {
        if saved == nil { try await register() }
        do {
            return try await send(method, path, body: body, type: type, headers: ["Authorization": "Bearer \(saved?.token ?? "")"])
        } catch let f as Failure where f.status == 401 {
            try await register()
            return try await send(method, path, body: body, type: type, headers: ["Authorization": "Bearer \(saved?.token ?? "")"])
        }
    }

    /// Sends your profile and photo when they are not what the server already has.
    func sync(_ profile: SharedProfile, photo: Data?) async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if saved?.pushed != profile {
                _ = try await authed("PUT", "v1/profile", body: try JSONEncoder().encode(profile), type: "application/json")
                saved?.pushed = profile
                store()
            }
            let hash = photo.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            if saved?.photoHash != hash {
                if let photo {
                    _ = try await authed("PUT", "v1/photo", body: photo, type: "image/jpeg")
                } else {
                    _ = try await authed("DELETE", "v1/photo")
                }
                saved?.photoHash = hash
                store()
            }
        } catch {
            // Tried again on the next refresh; the community is never in the way of the rest.
        }
    }

    func refresh() async {
        guard enabled else { return }
        loading = true
        defer { loading = false }
        do {
            struct Reply: Decodable { let me: Int; let profiles: [Member] }
            let r = try JSONDecoder().decode(Reply.self, from: try await authed("GET", "v1/profiles"))
            members = r.profiles
            me = r.me
            error = nil
            for m in r.profiles where m.photo > 0 && photoVersions[m.id] != m.photo {
                if let d = try? await authed("GET", "v1/photo/\(m.id)"), let image = NSImage(data: d) {
                    photos[m.id] = image
                    photoVersions[m.id] = m.photo
                }
            }
            for m in r.profiles where m.photo == 0 { photos[m.id] = nil }
        } catch let f as Failure where f.status == 403 || f.status == 401 {
            error = "Tu API key de DeskTime no es de una cuenta de Filmo."
        } catch {
            self.error = "No se ha podido conectar con la comunidad."
        }
    }

    /// A few made-up colleagues for the screenshots.
    func loadDemo() {
        func p(_ a: Int, _ c: Int, _ prestige: Int, _ cards: [(String, Art, Finish)], _ badges: [(String, Int?)]) -> SharedProfile {
            SharedProfile(since: "2026-10-29", achievementsHave: a, achievementsTotal: allAchievements.count, cardsHave: c,
                          cardsTotal: allCards.count, prestige: prestige,
                          cards: cards.map { .init(id: $0.0, art: $0.1, finish: $0.2) }, achievements: badges.map { .init(id: $0.0, tier: $0.1) })
        }
        members = [
            Member(id: 1, name: "Tu nombre", photo: 0, profile: p(1, 26, 2, [("padrino", .base, .gold), ("f-arri", .base, .holo), ("titanic", .base, .holo)], [("sin-casa", 2), ("eficacia-100", nil)])),
            Member(id: 2, name: "Ada Ejemplo", photo: 0, profile: p(9, 71, 5, [("matrix", .base, .holo), ("toy-story", .base, .normal), ("alien", .base, .normal)], [("eficacia-100", nil)])),
            Member(id: 3, name: "Bruno Muestra", photo: 0, profile: p(4, 38, 0, [("shrek", .base, .normal), ("origen", .base, .normal), ("casablanca", .base, .normal)], [("sin-casa", 1)])),
            Member(id: 4, name: "Carla Demo", photo: 0, profile: p(14, 120, 9, [("interstellar", .base, .gold), ("padrino", .base, .normal), ("matrix", .base, .normal)], [("eficacia-100", nil), ("sin-casa", 3)])),
        ]
        me = 1
    }
}

// MARK: - Views

struct CommunityView: View {
    @ObservedObject var community: Community
    @ObservedObject var achievements: Achievements
    let back: () -> Void
    @State private var selected: Member?
    nonisolated(unsafe) static var snapshotMember = 0

    var body: some View {
        let open = selected ?? community.members.first { $0.id == Self.snapshotMember }
        Group {
            if let m = open {
                MemberPage(member: m, photo: community.photos[m.id], achievements: achievements) {
                    withAnimation(.smooth(duration: 0.2)) { selected = nil }
                }
            } else {
                list
            }
        }
        .task { await community.refresh() }
    }

    private var list: some View {
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(community.members) { m in
                Button { withAnimation(.smooth(duration: 0.2)) { selected = m } } label: {
                    HStack(spacing: 10) {
                        Avatar(photo: community.photos[m.id], name: m.name, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(m.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                if m.id == community.me {
                                    Text("TÚ").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                                }
                            }
                            Text("\(Self.percent(m.profile.achievementsHave, m.profile.achievementsTotal)) logros · \(Self.percent(m.profile.cardsHave, m.profile.cardsTotal)) cromos"
                                 + (m.profile.prestige > 0 ? " · \(m.profile.prestige) de prestigio" : ""))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Comunidad").font(.system(size: 16, weight: .semibold))
                if !community.members.isEmpty {
                    Text("\(community.members.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                CornerButton(symbol: "person.crop.circle", help: "Volver a mi perfil", action: back)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            if community.members.isEmpty {
                VStack(spacing: 6) {
                    if community.loading { ProgressView().controlSize(.small) }
                    Text(community.error ?? (community.loading ? "Buscando a tus compañeros…" : "Aún no hay nadie por aquí."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else if isSnapshotRender {
                rows.padding(.horizontal, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) { rows.padding(.horizontal, 10).padding(.bottom, 10) }
            }
        }
    }

    static func percent(_ have: Int, _ of: Int) -> String { "\(of > 0 ? Int((Double(have) / Double(of) * 100).rounded()) : 0) %" }
}

/// The small round button at the top right that switches between your profile and the community.
struct CornerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A colleague's profile: what they chose to show, to look at only.
struct MemberPage: View {
    let member: Member
    let photo: NSImage?
    @ObservedObject var achievements: Achievements
    let back: () -> Void

    var body: some View {
        let p = member.profile
        let page = VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(photo: photo, name: member.name, size: 56)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if let since = p.since.flatMap(Profile.longDay) {
                        Text("Miembro desde el \(since)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if p.prestige > 0 {
                        Text("\(p.prestige) de prestigio").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                CornerButton(symbol: "chevron.left", help: "Volver a la comunidad", action: back)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            HStack(spacing: 8) {
                ProfileStat(title: "Logros", have: p.achievementsHave, of: p.achievementsTotal)
                ProfileStat(title: "Cromos", have: p.cardsHave, of: p.cardsTotal)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label2(text: "Cromos destacados")
                Vitrine {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<Profile.slots, id: \.self) { i in
                            let shown = i < p.cards.count ? p.cards[i] : nil
                            Group {
                                if let shown, let c = allCards.first(where: { $0.id == shown.id }) {
                                    CardFace(card: c, art: shown.art, finish: shown.finish, width: ProfileTab.cardWidth)
                                        .modifier(HoloHoverTilt(enabled: shown.finish != .normal, maxAngle: 14))
                                        .shadow(color: .black.opacity(0.55), radius: 6, y: 5)
                                        .help(c.title)
                                } else {
                                    EmptySlot(radius: ProfileTab.cardWidth * 0.07, onDark: true, plus: false)
                                        .frame(width: ProfileTab.cardWidth, height: ProfileTab.cardWidth * 1.5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label2(text: "Logros destacados")
                Vitrine {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<Profile.slots, id: \.self) { i in
                            let shown = i < p.achievements.count ? p.achievements[i] : nil
                            let a = shown.flatMap { s in allAchievements.first { $0.id == s.id } }
                            // A hidden achievement stays a secret for whoever has not earned it.
                            let secret = a.map { achievements.state.unlocked[$0.id] == nil && progressTrackers[$0.id] == nil } ?? false
                            AchievementBadge(achievement: a, tier: shown?.tier.flatMap(PrestigeTier.init(rawValue:)), secret: secret, plus: false)
                                .help(secret ? "Aún no lo has descubierto" : a?.detail ?? "")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)

        if isSnapshotRender { page } else { ScrollView(showsIndicators: false) { page } }
    }
}
