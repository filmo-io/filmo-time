import AppKit
import SwiftUI

// MARK: - Model

struct OwnedCard: Codable {
    var count: Int
    var first: Date
    var arts: Set<Art> = [.base]
    var finishes: Set<Finish> = [.normal]
    /// The variant shown in the Filmedex.
    var shownArt: Art = .base
    var shownFinish: Finish = .normal

    init(count: Int, first: Date, finish: Finish = .normal) {
        self.count = count
        self.first = first
        finishes = [.normal, finish]
        shownFinish = finish
    }

    private enum CodingKeys: String, CodingKey { case count, first, arts, finishes, shownArt, shownFinish, holo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 1, 1)
        first = try c.decodeIfPresent(Date.self, forKey: .first) ?? Date()
        // Unknown names (finishes that were retired) are dropped rather than breaking the album.
        finishes = Set((try c.decodeIfPresent([String].self, forKey: .finishes) ?? ["normal"]).compactMap(Finish.init(rawValue:)))
        finishes.insert(.normal)
        arts = Set((try c.decodeIfPresent([String].self, forKey: .arts) ?? ["base"]).compactMap(Art.init(rawValue:)))
        arts.insert(.base)
        shownArt = (try c.decodeIfPresent(String.self, forKey: .shownArt)).flatMap(Art.init(rawValue:)) ?? .base
        shownFinish = (try c.decodeIfPresent(String.self, forKey: .shownFinish)).flatMap(Finish.init(rawValue:)) ?? .normal
        // Before variants there was only "holo".
        if try c.decodeIfPresent(Bool.self, forKey: .holo) == true {
            finishes.insert(.holo)
            if shownFinish == .normal { shownFinish = .holo }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encode(first, forKey: .first)
        try c.encode(arts, forKey: .arts)
        try c.encode(finishes, forKey: .finishes)
        try c.encode(shownArt, forKey: .shownArt)
        try c.encode(shownFinish, forKey: .shownFinish)
    }
}

/// A pack being opened, saved so it can be finished after leaving the app.
struct PendingOpening: Codable {
    struct Saved: Codable {
        var card: String
        var art: Art
        var finish: Finish
        var isNew: Bool
        var newArt: Art?
        var newFinish: Finish?
        var tokens: Int
    }
    var pack: String
    var pulls: [Saved]
    var completed: [String]
    var flipped: [Int] = []
    var torn = false
}

/// One card out of a pack, with what it did to the album.
struct Pull: Identifiable {
    let id = UUID()
    let card: CardDef
    /// How it is drawn when turned.
    let art: Art
    let finish: Finish
    let isNew: Bool
    var newArt: Art? = nil
    var newFinish: Finish? = nil
    var tokens = 0
}

@MainActor
final class Album: ObservableObject {
    struct State: Codable {
        var earned: [String: Double] = [:]
        var spent: Double = 0
        var cards: [String: OwnedCard] = [:]
        var tokens = 0
        /// Packs waiting to be opened for free.
        var packs: [String: Int] = [:]
        /// Days that already gave their full-day pack.
        var paidDays: [String] = []
        /// Achievements that already gave their pack.
        var rewarded: [String] = []
        /// Highest prestige tier already paid in Tokens, per achievement.
        var prestigePaid: [String: Int] = [:]
        var completed: [String] = []
        /// Packs in a row without an epic or legendary card.
        var pity = 0
        var since = ""
        var opened = 0
        /// The pack on screen, if the app was left before turning every card.
        var pending: PendingOpening?
        /// Cards new to the album that have not been looked at yet.
        var unseen: [String] = []
        /// Legendary pity: the legendaries you were expected to get since your last one (the sum of
        /// each card's base legendary chance). Cheap packs add almost nothing, so it can't be farmed.
        var legendDebt: Double = 0
        /// The short welcome to Cromos has been completed (and its pack given).
        var onboarded = false
        /// Coins from the days before the album existed have been counted.
        var backfilled = false
        /// Achievements and prestige held when the album started count as already paid: gifts are never retroactive.
        var baselined = false

        init() {}

        // Every field is optional when reading, so adding one never resets an album.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            earned = try c.decodeIfPresent([String: Double].self, forKey: .earned) ?? [:]
            spent = try c.decodeIfPresent(Double.self, forKey: .spent) ?? 0
            // Card by card: one damaged entry never costs the rest of the album.
            cards = (try? c.decodeIfPresent([String: Lenient<OwnedCard>].self, forKey: .cards))??
                .compactMapValues(\.value) ?? [:]
            tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            packs = try c.decodeIfPresent([String: Int].self, forKey: .packs) ?? [:]
            paidDays = try c.decodeIfPresent([String].self, forKey: .paidDays) ?? []
            rewarded = try c.decodeIfPresent([String].self, forKey: .rewarded) ?? []
            prestigePaid = try c.decodeIfPresent([String: Int].self, forKey: .prestigePaid) ?? [:]
            completed = try c.decodeIfPresent([String].self, forKey: .completed) ?? []
            pity = try c.decodeIfPresent(Int.self, forKey: .pity) ?? 0
            since = try c.decodeIfPresent(String.self, forKey: .since) ?? Fmt.ymd(Date())
            opened = try c.decodeIfPresent(Int.self, forKey: .opened) ?? 0
            pending = try? c.decodeIfPresent(PendingOpening.self, forKey: .pending)
            unseen = try c.decodeIfPresent([String].self, forKey: .unseen) ?? []
            legendDebt = try c.decodeIfPresent(Double.self, forKey: .legendDebt) ?? 0
            onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
            backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
            baselined = try c.decodeIfPresent(Bool.self, forKey: .baselined) ?? false
        }
    }

    @Published private(set) var state = State()
    /// The pack being opened, if any.
    @Published var opening: (pack: PackKind, pulls: [Pull], completed: [CardSet])?
    private var persist: Bool
    private static let url = KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("album.json")
    private static let legacy = KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("aquarium.json")

    static let coinsPerHour = 2.5
    /// Full days it takes to earn a free Taquilla pack.
    /// Full workdays (7 h or more) it takes to earn the free weekly Estreno.
    static let daysPerFreePack = 5
    static let fullDay: Double = 7 * 3600
    /// Chance a repeat brings an art variant you don't have yet.
    static let artChance = 0.5
    /// Chance a card you didn't have comes straight in a variant art (you keep the classic one too).
    static let newArtChance = 0.2
    static let prestigeTokens = 20

    init(persist: Bool) {
        self.persist = persist
        if persist, let data = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
            restorePending()
            return
        }
        if persist, FileManager.default.fileExists(atPath: Self.url.path) {
            // Unreadable album: keep a copy and never write over it; this run works in memory only.
            let backup = Self.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Self.url, to: backup)
            self.persist = false
            state.since = Fmt.ymd(Date())
            return
        }
        state.since = Fmt.ymd(Date())
        // Coins earned in the old aquarium carry over; what was spent on fish comes back.
        if persist, let data = try? Data(contentsOf: Self.legacy),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let earned = old["earned"] as? [String: Double] {
            state.earned = earned
        }
        state.packs["estreno"] = 1
        save()
    }

    // MARK: Economy

    var lifetime: Double { state.earned.values.reduce(0, +) }
    var balance: Int { Int((lifetime - state.spent).rounded(.down)) }
    func earnedToday(_ now: Date = Date()) -> Double { state.earned[Fmt.ymd(now)] ?? 0 }

    /// Achievements and prestige tiers, as an extra on every coin: with everything, double.
    @Published private(set) var achievementBonus: Double = 0
    /// Time worked today so far, to say how long until today's free pack.
    @Published private(set) var todaySeconds: Double = 0

    /// Whether today's free pack has already been earned.
    var dailyPackEarned: Bool { state.paidDays.contains(Fmt.ymd(Date())) }
    /// Full workdays still needed for the next free Seed pack.
    var daysToFreeSeed: Int { Self.daysPerFreePack - state.paidDays.count % Self.daysPerFreePack }

    /// Each achievement adds 1.5 % per tier (Bronze 1.5 %, Silver 3 %… Legend 9 %), up to double.
    /// One being prestiged adds nothing until it is earned again at the higher tier.
    static func bonus(tiers: [String: Int]) -> Double {
        min(tiers.values.reduce(0) { $0 + Double($1 + 1) * 0.015 }, 1)
    }

    /// Coins of a typical full day (8 h at 80 %), with the current achievement bonus.
    var typicalDay: Double { coins(seconds: 8 * 3600, productivity: 80) }

    /// "~1 día", "~4 días", "~1 semana", "~2 semanas" of work to afford a price.
    func workTime(for price: Int) -> String {
        let days = Double(price) / max(typicalDay, 1)
        if days <= 1.15 { return "~1 día" }
        if days < 4.5 { return "~\(Int(days.rounded())) días" }
        let weeks = days / 5
        if weeks < 1.5 { return "~1 semana" }
        return "~\(Int(weeks.rounded())) semanas"
    }

    func coins(seconds: Double, productivity: Double) -> Double {
        let hours = min(seconds / 3600, 8)
        return hours * Self.coinsPerHour * (1 + min(max(productivity, 0), 100) / 100) * (1 + achievementBonus)
    }

    /// Records the coins of today and of the week's past days, and the full-day packs.
    /// Applies the achievement bonus at once (today's coins are recounted on the next refresh).
    func updateBonus(tiers: [String: Int]) {
        let bonus = Self.bonus(tiers: tiers)
        if bonus != achievementBonus { achievementBonus = bonus }
    }

    func record(today: DayData?, week: [WeekDay], tiers: [String: Int], now: Date = Date()) {
        let bonus = Self.bonus(tiers: tiers)
        if bonus != achievementBonus { achievementBonus = bonus }
        var changed = false
        func count(_ key: String, seconds: Double, productivity: Double, isToday: Bool) {
            let value = coins(seconds: seconds, productivity: productivity)
            // Past days keep the value they were first counted with.
            // Past days keep their first value; today only ever goes up, so coins already spent stay covered.
            if let old = state.earned[key] {
                if isToday && value > old { state.earned[key] = value; changed = true }
            } else {
                state.earned[key] = value; changed = true
            }
            if seconds >= Self.fullDay, key >= state.since, !state.paidDays.contains(key) {
                state.paidDays.append(key)
                // Every full workday: the pack of the day. Every five: an Estreno.
                state.packs[dailyPack.id, default: 0] += 1
                if state.paidDays.count % Self.daysPerFreePack == 0 { state.packs["estreno", default: 0] += 1 }
                changed = true
            }
        }
        for d in week where !d.isFuture && d.desktime > 0 {
            count(Fmt.ymd(d.date), seconds: d.desktime, productivity: d.productivity,
                  isToday: Calendar.current.isDate(d.date, inSameDayAs: now))
        }
        if let today, today.arrivedDay == Fmt.ymd(now) {
            count(Fmt.ymd(now), seconds: today.desktime, productivity: today.productivity, isToday: true)
            if today.desktime != todaySeconds { todaySeconds = today.desktime }
        }
        if changed { save() }
    }

    /// A pack for every unlocked achievement and Tokens for every prestige tier reached.
    /// Chance of each pack (Taquilla, Estreno, Gala, Alfombra roja) as an achievement reward, by tier:
    /// the first unlock is Bronze, and every prestige tier recovered rolls again with better odds.
    static let rewardOdds: [[Double]] = [
        [50, 35, 12, 3],    // Bronce
        [30, 40, 22, 8],    // Plata
        [15, 40, 32, 13],   // Oro
        [5, 35, 40, 20],    // Platino
        [0, 25, 45, 30],    // Diamante
        [0, 10, 45, 45],    // Leyenda
    ]

    static func rewardPack(tier: Int) -> PackKind {
        let odds = rewardOdds[min(max(tier, 0), rewardOdds.count - 1)]
        var roll = Double.random(in: 0..<odds.reduce(0, +))
        for (i, o) in odds.enumerated() {
            if roll < o { return packKinds[i] }
            roll -= o
        }
        return packKinds[0]
    }

    /// A pack for every unlocked achievement and every prestige tier recovered, plus Tokens per tier.
    func reward(tiers: [String: Int]) {
        if !state.baselined {
            // A new album: what you already had gives nothing; you start with the pack of the day.
            state.baselined = true
            state.rewarded = Array(Set(state.rewarded).union(tiers.keys))
            state.prestigePaid.merge(tiers) { max($0, $1) }
            state.packs[dailyPack.id, default: 0] += 1
            save()
            return
        }
        var changed = false
        for (id, tier) in tiers {
            if !state.rewarded.contains(id) {
                state.rewarded.append(id)
                state.packs[Self.rewardPack(tier: 0).id, default: 0] += 1
                changed = true
            }
            let paid = state.prestigePaid[id] ?? 0
            if tier > paid {
                for t in paid + 1...tier {
                    state.tokens += t * Self.prestigeTokens
                    state.packs[Self.rewardPack(tier: t).id, default: 0] += 1
                }
                state.prestigePaid[id] = tier
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: Packs

    var freePacks: Int { state.packs.values.reduce(0, +) }
    func free(_ p: PackKind) -> Int { state.packs[p.id] ?? 0 }
    func canBuy(_ p: PackKind) -> Bool { balance >= p.price }

    /// Epic chance gained by bad luck, taken from the common one.
    var pityBonus: Double { Double(min(state.pity, 20)) }

    func buy(_ p: PackKind) {
        guard canBuy(p) else { return }
        state.spent += Double(p.price)
        open(p)
    }

    func openFree(_ p: PackKind) {
        guard free(p) > 0 else { return }
        state.packs[p.id] = free(p) - 1
        if state.packs[p.id] == 0 { state.packs[p.id] = nil }
        open(p)
    }

    /// Legendary pity, in expected legendaries without one: from `softPity` the legendary chance
    /// grows (up to ×4 at `hardPity`); at `hardPity` the next card is legendary.
    static let softPity = 1.5
    static let hardPity = 2.5

    /// Odds for one card of a pack, after the epic streak bonus and the legendary pity.
    func odds(for p: PackKind) -> [Double] {
        var odds = p.odds
        let epicBonus = min(pityBonus, odds[0])
        odds[0] -= epicBonus
        odds[2] += epicBonus
        let debt = state.legendDebt
        if debt > Self.softPity {
            let ramp = min((debt - Self.softPity) / (Self.hardPity - Self.softPity), 1)
            let extra = min(odds[3] * 3 * ramp, odds[0])
            odds[0] -= extra
            odds[3] += extra
        }
        return odds
    }

    /// Draws one card and keeps the legendary pity up to date.
    private func draw(_ p: PackKind) -> (CardDef, Finish) {
        var rarity = Rarity.common
        if state.legendDebt >= Self.hardPity && pyramidAllows(.legendary) {
            rarity = .legendary
        } else {
            let odds = odds(for: p)
            var roll = Double.random(in: 0..<odds.reduce(0, +))
            for (i, o) in odds.enumerated() {
                if roll < o { rarity = Rarity(rawValue: i)!; break }
                roll -= o
            }
        }
        // Pyramid: you can never be further along in a rarity than in the one below it.
        let rolled = rarity
        while let below = Rarity(rawValue: rarity.rawValue - 1), !pyramidAllows(rarity) { rarity = below }
        // Only the pack's own legendary chance counts, never the boosted one; a legendary held back
        // by the pyramid keeps the pity charged.
        if rarity == .legendary { state.legendDebt = 0 }
        else if rolled != .legendary { state.legendDebt += p.odds[3] / p.odds.reduce(0, +) }
        let pool = allCards.filter { $0.rarity == rarity }
        var card = pool.randomElement()!
        // Duplicate protection below legendary: from the third copy, a card you're missing instead.
        if rarity < .legendary, (state.cards[card.id]?.count ?? 0) >= Self.protectedCopies,
           let missing = pool.filter({ state.cards[$0.id] == nil }).randomElement() {
            card = missing
        }
        return (card, Finish.roll())
    }

    /// Copies of a common, rare or epic card you can get before repeats turn into missing cards.
    static let protectedCopies = 2

    /// Share of the album you hold in a rarity.
    func share(_ r: Rarity) -> Double {
        let pool = allCards.filter { $0.rarity == r }
        return Double(pool.filter { state.cards[$0.id] != nil }.count) / Double(max(pool.count, 1))
    }

    /// Whether one more card of a rarity keeps it no further along than the rarity below it.
    private func fits(_ r: Rarity, over below: Rarity) -> Bool {
        let total = Double(max(allCards.filter { $0.rarity == r }.count, 1))
        return share(r) + 1 / total <= share(below) + 0.05
    }

    private func open(_ p: PackKind) {
        let before = Set(completedSets.map(\.id))
        // Cards are added in draw order, then laid out at random: every back looks the same.
        // One card at a time, so each draw sees the cards before it (pyramid, duplicate protection).
        var drawn: [Pull] = []
        for _ in 0..<p.count {
            let (card, finish) = draw(p)
            drawn.append(add(card, finish: finish))
        }
        let pulls = drawn.shuffled()
        state.pity = pulls.contains { $0.card.rarity >= .epic } ? 0 : state.pity + 1
        state.opened += 1
        let done = completeSets(before: before)
        save()
        state.unseen.append(contentsOf: pulls.filter(\.isNew).map(\.card.id).filter { !state.unseen.contains($0) })
        state.pending = PendingOpening(
            pack: p.id,
            pulls: pulls.map { .init(card: $0.card.id, art: $0.art, finish: $0.finish, isNew: $0.isNew,
                                     newArt: $0.newArt, newFinish: $0.newFinish, tokens: $0.tokens) },
            completed: done.map(\.id))
        save()
        opening = (p, pulls, done)
    }

    private func add(_ card: CardDef, finish: Finish) -> Pull {
        guard var owned = state.cards[card.id] else {
            var fresh = OwnedCard(count: 1, first: Date(), finish: finish)
            var art = Art.base
            if Double.random(in: 0..<1) < Self.newArtChance, let a = randomMissingArt(card, fresh) {
                fresh.arts.insert(a)
                fresh.shownArt = a
                art = a
            }
            state.cards[card.id] = fresh
            return Pull(card: card, art: art, finish: finish, isNew: true, newArt: art == .base ? nil : art)
        }
        owned.count += 1
        defer { state.cards[card.id] = owned }
        // A finish you don't have yet is unlocked, and shown if it is better.
        if finish != .normal && !owned.finishes.contains(finish) {
            owned.finishes.insert(finish)
            if finish > owned.shownFinish { owned.shownFinish = finish }
            return Pull(card: card, art: owned.shownArt, finish: finish, isNew: false, newFinish: finish)
        }
        // A repeated holo or gold always pays, and well; a plain repeat pays only if it brings no variant.
        var newArt: Art?
        if Double.random(in: 0..<1) < Self.artChance, let art = randomMissingArt(card, owned) {
            owned.arts.insert(art)
            newArt = art
            if finish == .normal { return Pull(card: card, art: art, finish: owned.shownFinish, isNew: false, newArt: art) }
        }
        let tokens = card.rarity.tokens * finish.tokenFactor
        state.tokens += tokens
        return Pull(card: card, art: newArt ?? owned.shownArt, finish: finish, isNew: false, newArt: newArt, tokens: tokens)
    }

    private func randomMissingArt(_ card: CardDef, _ owned: OwnedCard) -> Art? {
        let missing = card.arts.filter { !owned.arts.contains($0) }
        var roll = Double.random(in: 0..<max(missing.reduce(0) { $0 + $1.weight }, 0.001))
        for a in missing {
            if roll < a.weight { return a }
            roll -= a.weight
        }
        return missing.last
    }

    /// Tokens for an art variant of a card you have, at random.
    func variantCost(_ c: CardDef) -> Int { c.rarity.craftCost / 2 }

    func canCraftVariant(_ c: CardDef) -> Bool {
        guard let o = owned(c) else { return false }
        return state.tokens >= variantCost(c) && c.arts.contains { !o.arts.contains($0) }
    }

    func craftVariant(_ c: CardDef) {
        guard canCraftVariant(c), var o = owned(c), let art = randomMissingArt(c, o) else { return }
        state.tokens -= variantCost(c)
        o.arts.insert(art)
        o.shownArt = art
        state.cards[c.id] = o
        save()
    }

    func show(_ c: CardDef, art: Art? = nil, finish: Finish? = nil) {
        guard var o = owned(c) else { return }
        if let art, o.arts.contains(art) { o.shownArt = art }
        if let finish, o.finishes.contains(finish) { o.shownFinish = finish }
        state.cards[c.id] = o
        save()
    }

    var completedSets: [CardSet] { cardSets.filter { s in s.cards.allSatisfy { state.cards[$0.id] != nil } } }

    /// A Gala pack for every page finished for the first time.
    private func completeSets(before: Set<String>) -> [CardSet] {
        let new = completedSets.filter { !before.contains($0.id) && !state.completed.contains($0.id) }
        for s in new {
            state.completed.append(s.id)
            state.packs["gala", default: 0] += 1
        }
        return new
    }

    // MARK: Pending pack

    private func restorePending() {
        guard let p = state.pending else { return }
        let pulls = p.pulls.compactMap { s -> Pull? in
            guard let card = allCards.first(where: { $0.id == s.card }) else { return nil }
            return Pull(card: card, art: s.art, finish: s.finish, isNew: s.isNew, newArt: s.newArt, newFinish: s.newFinish, tokens: s.tokens)
        }
        guard !pulls.isEmpty else { state.pending = nil; return }
        // A card retired from the catalogue shifts the order: start the turning over.
        if pulls.count != p.pulls.count { state.pending?.flipped = [] }
        opening = (pack(p.pack), pulls, cardSets.filter { p.completed.contains($0.id) })
    }

    var pendingFlipped: Set<Int> { Set(state.pending?.flipped ?? []) }
    var pendingTorn: Bool { state.pending?.torn ?? false }

    func savePending(flipped: Set<Int>, torn: Bool) {
        guard let p = state.pending else { return }
        if flipped.count >= (opening?.pulls.count ?? p.pulls.count) {
            // Every card is turned: the pack is done, even if "Hecho" is never pressed.
            state.pending = nil
        } else {
            state.pending?.flipped = flipped.sorted()
            state.pending?.torn = torn
        }
        save()
    }

    /// When the album comes back on screen, a finished pack is no longer shown.
    func dropFinishedOpening() {
        if opening != nil && state.pending == nil { opening = nil }
    }

    func finishOpening() {
        state.pending = nil
        opening = nil
        save()
    }

    func isUnseen(_ c: CardDef) -> Bool { state.unseen.contains(c.id) }

    func markSeen(_ c: CardDef) {
        guard let i = state.unseen.firstIndex(of: c.id) else { return }
        state.unseen.remove(at: i)
        save()
    }

    // MARK: Cards

    func owned(_ c: CardDef) -> OwnedCard? { state.cards[c.id] }
    /// Cards still hidden in a category at a rarity.
    func missing(set: String, rarity: Rarity) -> [CardDef] {
        allCards.filter { $0.set == set && $0.rarity == rarity && owned($0) == nil }
    }

    func canCraft(set: String, rarity: Rarity) -> Bool {
        // Crafting is free of the pyramid: Tokens come from repeats, so it pays for itself.
        state.tokens >= rarity.craftCost && !missing(set: set, rarity: rarity).isEmpty
    }

    /// Whether one more card of this rarity fits the pyramid (crafting follows the same rule as packs).
    /// A complete rarity always fits: its repeats are just Tokens.
    func pyramidAllows(_ r: Rarity) -> Bool {
        guard let below = Rarity(rawValue: r.rawValue - 1) else { return true }
        if allCards.allSatisfy({ $0.rarity != r || state.cards[$0.id] != nil }) { return true }
        return fits(r, over: below)
    }

    /// A random card you don't have, of that category and rarity.
    func craft(set: String, rarity: Rarity) -> CardDef? {
        guard canCraft(set: set, rarity: rarity), let c = missing(set: set, rarity: rarity).randomElement() else { return nil }
        let before = Set(completedSets.map(\.id))
        state.tokens -= rarity.craftCost
        state.cards[c.id] = OwnedCard(count: 1, first: Date())
        if !state.unseen.contains(c.id) { state.unseen.append(c.id) }
        _ = completeSets(before: before)
        save()
        return c
    }

    /// Everyone starts with the coins earned since Filmo Time came out.
    static let backfillStart = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29))!

    /// Counts the coins of past days (never their free packs) and remembers it was done.
    func backfill(_ days: [WeekDay], tiers: [String: Int]) {
        guard !state.backfilled else { return }
        record(today: nil, week: days, tiers: tiers)
        state.backfilled = true
        save()
    }

    /// Finishing the welcome gives one Serie A pack, once.
    static let onboardingPack = "gala"

    func finishOnboarding() {
        guard !state.onboarded else { return }
        state.onboarded = true
        state.packs[Self.onboardingPack, default: 0] += 1
        save()
    }

    func loadDemo() {
        var s = State()
        s.onboarded = true
        s.backfilled = true
        s.earned = ["demo": 2380, Fmt.ymd(Date()): 64]
        s.spent = 0
        for (id, holo) in [("padrino", false), ("titanic", true), ("toy-story", false), ("shrek", false), ("casablanca", false),
                           ("matrix", false), ("origen", false), ("interstellar", false), ("alien", false),
                           ("ocho-apellidos", false), ("campeones", false), ("torrente", false), ("orfanato", false),
                           ("hollywood", false), ("goya", false), ("friends", false), ("black-mirror", false), ("f-mbs", false), ("f-arri", true), ("f-netflix", false), ("f-toboggan", false), ("f-efd-studios", false), ("f-the-core", false), ("f-bcn360", false), ("f-kodak", false), ("f-epc", false)] {
            s.cards[id] = OwnedCard(count: id == "shrek" ? 3 : 1, first: Date(), finish: holo ? .holo : .normal)
        }
        s.cards["padrino"]?.arts = [.base, .alt, .scene]
        s.cards["padrino"]?.shownArt = .base
        s.cards["padrino"]?.finishes = [.normal, .gold]
        s.cards["padrino"]?.shownFinish = .gold
        s.cards["matrix"]?.arts = [.base, .alt]
        s.tokens = 38
        s.packs = ["taquilla": 1, "estreno": 1]
        s.pity = 3
        s.since = Fmt.ymd(Date())
        state = s
    }

    // MARK: Self-test hooks

    /// Test only: replaces the state and grants packs.
    func testReset(_ s: State = State()) { state = s; opening = nil }
    func testGrant(_ id: String, _ n: Int) { state.packs[id, default: 0] += n }
    func testEarn(_ coins: Double) { state.earned["test", default: 0] += coins }
    static func testDecode(_ json: String) -> State? { try? JSONDecoder().decode(State.self, from: Data(json.utf8)) }
    func testRestore(_ s: State) { state = s; restorePending() }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

// MARK: - Images

/// Downloads each card's image once and keeps it next to the other app data.
/// All reading, decoding and image work happens off the main thread; downloads are limited,
/// retried on rate limits, de-duplicated, and kept in a bounded memory cache.
@MainActor
enum Posters {
    private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()
    /// Recent failures, so a missing image isn't asked for again and again.
    private static var failedAt: [String: Date] = [:]
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Background colour that came with a logo, when it had one.
    private static var logoBackground: [String: NSColor] = [:]
    /// White logos, which need another ink on light backgrounds such as gold.
    private static var lightLogos: Set<String> = []

    static func background(_ c: CardDef) -> NSColor? { logoBackground[c.id] }
    static func isLightLogo(_ c: CardDef) -> Bool { lightLogos.contains(c.id) }

    private static var dir: URL { KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("posters", isDirectory: true) }
    private static func key(_ c: CardDef, _ a: Art) -> String { a == .base ? c.id : "\(c.id)-\(a.rawValue)" }
    /// A variant's file carries a tag of its source, so a replaced art is downloaded again instead of read stale.
    private static func file(_ c: CardDef, _ a: Art) -> URL {
        guard a != .base else { return dir.appendingPathComponent("\(key(c, a)).jpg") }
        let tag = c.imageURL(a).deletingPathExtension().lastPathComponent.suffix(8)
        return dir.appendingPathComponent("\(key(c, a))-\(tag).jpg")
    }

    private static func remember(_ i: NSImage, _ k: String) {
        let px = i.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? Int(i.size.width * i.size.height)
        memory.setObject(i, forKey: k as NSString, cost: max(px, 1) * 4)
    }

    /// Only what is already in memory: never touches the disk or the network on the main thread.
    /// Snapshots, which render synchronously, read the disk directly.
    static func cached(_ c: CardDef, _ a: Art = .base) -> NSImage? {
        let k = key(c, a)
        if let i = memory.object(forKey: k as NSString) { return i }
        let source = c.imageURL(a)
        guard isSnapshotRender, let p = Prepared.from(file: source.isFileURL ? source : file(c, a), logo: c.isLogo) else { return nil }
        apply(p, c, k)
        return p.image
    }

    private static func apply(_ p: Prepared, _ c: CardDef, _ k: String) {
        if let bg = p.background { logoBackground[c.id] = bg }
        if p.light { lightLogos.insert(c.id) }
        remember(p.image, k)
    }

    static func load(_ c: CardDef, _ a: Art = .base) async -> NSImage? {
        let k = key(c, a)
        if let i = memory.object(forKey: k as NSString) { return i }
        if let f = failedAt[k], Date().timeIntervalSince(f) < 600 { return nil }
        if let t = inFlight[k] { return await t.value }
        let t = Task { await fetch(c, a, k) }
        inFlight[k] = t
        let i = await t.value
        inFlight[k] = nil
        if i == nil { failedAt[k] = Date() }
        return i
    }

    private static func fetch(_ c: CardDef, _ a: Art, _ k: String) async -> NSImage? {
        let target = file(c, a), logo = c.isLogo
        // Logos come with the app: read them straight from the bundle.
        let source = c.imageURL(a)
        if source.isFileURL {
            guard let p = await Task.detached(priority: .userInitiated, operation: { Prepared.from(file: source, logo: logo) }).value else { return nil }
            apply(p, c, k)
            return p.image
        }
        if let p = await Task.detached(priority: .userInitiated, operation: { Prepared.from(file: target, logo: logo) }).value {
            apply(p, c, k)
            return p.image
        }
        var request = URLRequest(url: c.imageURL(a), timeoutInterval: 20)
        // Wikimedia asks automated clients to name themselves.
        request.setValue("FilmoTime/1.0 (macOS menu bar app)", forHTTPHeaderField: "User-Agent")
        await DownloadGate.shared.enter()
        defer { Task { await DownloadGate.shared.leave() } }
        for attempt in 0..<3 {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000); continue
            }
            if status == 200 {
                let d = data
                let p = await Task.detached(priority: .userInitiated, operation: { () -> Prepared? in
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard let p = Prepared.from(data: d, logo: logo) else { return nil }
                    try? d.write(to: target, options: .atomic)
                    // The file this art had before its name carried the tag.
                    if a != .base { try? FileManager.default.removeItem(at: target.deletingLastPathComponent().appendingPathComponent("\(k).jpg")) }
                    return p
                }).value
                guard let p else { return nil }
                apply(p, c, k)
                return p.image
            }
            // Rate limits and server hiccups: wait and try again; anything else is final.
            guard status == 429 || status >= 500 else { return nil }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
        }
        return nil
    }

    /// The art with its background turned to gold, from memory only.
    static func cachedGold(_ c: CardDef, _ a: Art) -> NSImage? {
        memory.object(forKey: (key(c, a) + "-gold") as NSString)
    }

    /// Reviewed posters get a gold cut-out (or a hand-made one), computed off the main thread.
    static func loadGold(_ c: CardDef, _ a: Art) async -> NSImage? {
        let k = key(c, a) + "-gold"
        if let i = memory.object(forKey: k as NSString) { return i }
        guard a == .base else { return nil }
        if let s = customGold[c.id], let url = URL(string: s),
           let (data, _) = try? await URLSession.shared.data(from: url), let i = NSImage(data: data) {
            remember(i, k)
            return i
        }
        guard goldCutouts.contains(c.id), let src = await load(c, a) else { return nil }
        let id = c.id
        let i = await Task.detached(priority: .utility) { ArtEffects.goldBackground(src, id: id) }.value
        if let i { remember(i, k) }
        return i
    }

    /// The art toned for gold leaf, from memory only; snapshots, which render synchronously, tone it on the spot.
    static func cachedGilt(_ c: CardDef, _ a: Art) -> NSImage? {
        let k = key(c, a) + "-gilt"
        if let i = memory.object(forKey: k as NSString) { return i }
        guard isSnapshotRender, let src = cached(c, a), let i = GoldTone.toned(src) else { return nil }
        remember(i, k)
        return i
    }

    /// Tones the art for gold leaf once, off the main thread.
    static func loadGilt(_ c: CardDef, _ a: Art) async -> NSImage? {
        let k = key(c, a) + "-gilt"
        if let i = memory.object(forKey: k as NSString) { return i }
        guard let src = await load(c, a) else { return nil }
        let i = await Task.detached(priority: .userInitiated) { GoldTone.toned(src) }.value
        if let i { remember(i, k) }
        return i
    }

    /// Snapshots render synchronously, so their images must be on disk first.
    static func prefetchForSnapshot(arts: Bool = false) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        for c in allCards where !c.art.isDrawn && !c.isLogo {
            for a in (arts ? c.arts : [.base]) where !FileManager.default.fileExists(atPath: file(c, a).path) {
                group.enter()
                let target = file(c, a)
                var r = URLRequest(url: c.imageURL(a))
                r.setValue("FilmoTime/1.0 (macOS menu bar app)", forHTTPHeaderField: "User-Agent")
                URLSession.shared.dataTask(with: r) { data, response, _ in
                    if let data, (response as? HTTPURLResponse)?.statusCode == 200 { try? data.write(to: target, options: .atomic) }
                    group.leave()
                }.resume()
            }
        }
        while group.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

/// At most a few image downloads at once, so nobody hits a site's rate limit.
actor DownloadGate {
    static let shared = DownloadGate()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let limit = 6

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if let next = waiting.first { waiting.removeFirst(); next.resume() } else { running = max(running - 1, 0) }
    }
}

/// A decoded image ready for a card: scaled down to card size, and for logos trimmed and analysed.
struct Prepared: @unchecked Sendable {
    let image: NSImage
    let background: NSColor?
    let light: Bool

    static func from(file: URL, logo: Bool) -> Prepared? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return from(data: data, logo: logo)
    }

    static func from(data: Data, logo: Bool) -> Prepared? {
        guard let img = downsampled(data) else { return nil }
        guard logo else { return Prepared(image: img, background: nil, light: false) }
        let (trimmed, bg) = ArtEffects.trimLogo(img)
        return Prepared(image: trimmed, background: bg, light: bg == nil && ArtEffects.isLightLogo(trimmed))
    }

    /// At most 900 px on the long side; vector logos (SVG) are drawn at a crisp fixed size.
    private static func downsampled(_ data: Data) -> NSImage? {
        let maxPx = 900
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPx,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let scale = 600 / max(img.size.width, img.size.height)
        let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return img }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

extension CardDef {
    var isLogo: Bool { if case .logo = art { true } else { false } }
}

// MARK: - Card views

struct CardImage: View {
    let card: CardDef
    var art: Art = .base
    var fit = false
    var gold = false
    @State private var image: NSImage?
    @State private var failed = false
    /// Inside gold leaf the art is shown toned, so dark or saturated art still reads in gold.
    @Environment(\.gilded) private var gilded
    @State private var gilt: NSImage?

    init(card: CardDef, art: Art = .base, fit: Bool = false, gold: Bool = false) {
        self.card = card
        self.art = art
        self.fit = fit
        self.gold = gold
        _image = State(initialValue: gold ? (Posters.cachedGold(card, art) ?? Posters.cached(card, art)) : Posters.cached(card, art))
    }

    var body: some View {
        let shown = gilded ? (gilt ?? Posters.cachedGilt(card, art) ?? image) : image
        ZStack {
            if let image = shown {
                if fit { Image(nsImage: image).resizable().scaledToFit() } else { Image(nsImage: image).resizable().scaledToFill() }
            } else if fit {
                // A logo that could not be loaded: its name as a wordmark.
                Text(card.title).font(.system(size: 30, weight: .black)).minimumScaleFactor(0.2).lineLimit(2)
                    .multilineTextAlignment(.center).opacity(failed ? 1 : 0.4)
            } else {
                Rectangle().fill(LinearGradient(colors: card.rarity.colors.map { $0.opacity(0.35) },
                                                startPoint: .top, endPoint: .bottom))
                if !failed { ProgressView().controlSize(.mini) }
            }
        }
        .task(id: "\(card.id)-\(art.rawValue)-\(gilded)") {
            gilt = nil
            if gilded, let g = await Posters.loadGilt(card, art) { gilt = g }
        }
        .task(id: "\(card.id)-\(art.rawValue)-\(gold)") {
            // The same view can be asked for another art (or gold): always fetch the one asked for.
            let wanted = gold ? (Posters.cachedGold(card, art) ?? Posters.cached(card, art)) : Posters.cached(card, art)
            if let wanted { image = wanted } else { image = nil; failed = false }
            if gold, let g = await Posters.loadGold(card, art) { image = g; return }
            if image == nil || gold == false {
                if let i = await Posters.load(card, art) { image = i } else if image == nil { failed = true }
            }
        }
    }
}

/// The front of a card: the poster, or the photo with its caption, framed in its rarity.
struct CardFace: View {
    let card: CardDef
    var art: Art = .base
    var finish: Finish = .normal
    var width: CGFloat

    private var height: CGFloat { width * 1.5 }
    private var radius: CGFloat { width * 0.07 }

    var body: some View {
        Group {
            if finish == .gold {
                // Gold: the whole card is stamped in gold leaf.
                GoldLeaf(width: width) { face(width) }
            } else if inGold {
                face(width)
            } else {
                face(width)
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(card.rarity.gradient, lineWidth: max(width * 0.03, 1.5)))
            }
        }
        .frame(width: width, height: height)
    }

    /// Inside a gold frame: no rarity border, and reviewed posters keep their subject over gold.
    var inGold = false

    private func face(_ width: CGFloat) -> some View {
        ZStack {
            if case .drawn(let symbol, let colors) = card.art {
                DrawnFace(card: card, symbol: symbol, colors: colors, width: width)
            } else if case .logo(let bg) = card.art {
                LogoFace(card: card, bg: bg, width: width)
            } else if case .brand(let colors) = card.art {
                BrandFace(card: card, colors: colors, width: width)
            } else if art == .scene {
                SceneFace(card: card, finish: finish, width: width)
            } else if card.isPhoto {
                VStack(spacing: 0) {
                    CardImage(card: card, art: art)
                        .frame(width: width, height: height * 0.66).clipped()
                    VStack(spacing: width * 0.02) {
                        Text(card.title)
                            .font(.system(size: max(width * 0.085, 6), weight: .bold, design: .serif))
                            .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                        Text(card.yearText)
                            .font(.system(size: max(width * 0.07, 5), weight: .medium).monospacedDigit())
                            .opacity(0.7)
                    }
                    .foregroundStyle(hex(0x2A2418))
                    .padding(.horizontal, width * 0.06)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [hex(0xF4EEDF), hex(0xE2D8C0)], startPoint: .top, endPoint: .bottom))
                }
            } else {
                CardImage(card: card, art: art, gold: inGold && art == .base && goldCutouts.contains(card.id))
                    .frame(width: width, height: width * 1.5).clipped()
            }
            FinishOverlay(finish: finish, width: width)
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.07))
    }
}

/// Gold finish: the whole card stamped in gold leaf, with a mirror rim and a hallmark.
struct GoldLeaf<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let r = width * 0.07
        ZStack {
            // The art in black and white, then inked in gold: lights turn to gold, shadows to bronze.
            content().environment(\.gilded, true).saturation(0).contrast(1.35).brightness(0.06)
            LinearGradient(stops: [.init(color: hex(0xFFF0A8), location: 0), .init(color: hex(0xF6C544), location: 0.38),
                                   .init(color: hex(0xE3A21C), location: 0.7), .init(color: hex(0xF8D568), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.multiply)
            hex(0x3A2203).blendMode(.lighten)
            GoldShine()
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: r))
        .overlay(RoundedRectangle(cornerRadius: r)
            .strokeBorder(LinearGradient(colors: polishedGold, startPoint: .topLeading, endPoint: .bottomTrailing),
                          lineWidth: max(width * 0.022, 1.5)))
        .overlay(RoundedRectangle(cornerRadius: r * 0.66)
            .strokeBorder(hex(0xFFEEAA).opacity(0.75), lineWidth: max(width * 0.005, 0.5))
            .padding(width * 0.034))
        .overlay(alignment: .bottom) {
            if width >= 100 {
                Text("DORADA").font(.system(size: width * 0.032, weight: .heavy)).tracking(width * 0.01)
                    .foregroundStyle(hex(0x3D2503))
                    .padding(.horizontal, width * 0.035).padding(.vertical, width * 0.012)
                    .background(Capsule().fill(LinearGradient(colors: Array(polishedGold[1...5]), startPoint: .leading, endPoint: .trailing)))
                    .overlay(Capsule().strokeBorder(hex(0x5A3A06), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
                    .padding(.bottom, width * 0.055)
            }
        }
        .frame(width: width, height: width * 1.5)
    }
}

private struct GildedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Inside gold leaf: images show their gold-toned version.
    var gilded: Bool {
        get { self[GildedKey.self] }
        set { self[GildedKey.self] = newValue }
    }
}

/// Tones art for gold leaf. Gold multiplies a grey version of the art, so dark art, and red or blue art
/// (whose luma is low), came out as a brown slab. Dark art now counts its brightest channel too, and gets
/// its own levels: the white point at its highlights (gain capped, so a black poster's noise stays black)
/// and the midtones lifted when the whole image is still dark. Light art is left untouched, and art in
/// between gets a share of both, so nothing jumps at a threshold.
enum GoldTone {
    static func toned(_ img: NSImage) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let n = w * h
        // Rec. 709 luma on the encoded values: the grey SwiftUI's desaturation gives.
        var luma = [Double](repeating: 0, count: n), peak = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            peak[i] = max(r, g, b)
            sum += luma[i]
        }
        let t = need(meanLuma: sum / Double(n) / 255)
        guard t > 0 else { return img }
        var grey = [UInt8](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let v = UInt8(min(luma[i] + t * 0.5 * (peak[i] - luma[i]), 255).rounded())
            grey[i] = v
            hist[Int(v)] += 1
        }
        let map = levels(hist, count: n)
        for i in 0..<n {
            let v = luma[i] + t * (Double(map[Int(grey[i])]) - luma[i])
            let out = UInt8(min(max(v, 0), 255).rounded() * Double(px[i * 4 + 3]) / 255)
            px[i * 4] = out; px[i * 4 + 1] = out; px[i * 4 + 2] = out
        }
        guard let result = ctx.makeImage() else { return nil }
        return NSImage(cgImage: result, size: img.size)
    }

    /// How much an image needs toning, from its mean luma: fully at 0.25 or below, not at all from 0.45.
    static func need(meanLuma: Double) -> Double {
        min(max((0.45 - meanLuma) / 0.2, 0), 1)
    }

    /// The tone curve for one image, from the histogram of its grey.
    static func levels(_ hist: [Int], count: Int) -> [UInt8] {
        func percentile(_ p: Double) -> Double {
            var seen = 0
            for (v, k) in hist.enumerated() {
                seen += k
                if Double(seen) > Double(count) * p { return Double(v) / 255 }
            }
            return 1
        }
        // Black point only trims a raised floor, so light art never darkens; white point at the highlights.
        let lo = min(percentile(0.01), 0.06)
        let hi = max(percentile(0.99), lo + 0.4)
        let stretch = { (v: Double) in min(max((v - lo) / (hi - lo), 0), 1) }
        var mean = 0.0
        for (v, k) in hist.enumerated() { mean += stretch(Double(v) / 255) * Double(k) }
        mean /= Double(max(count, 1))
        // Lift the midtones of dark art toward a mean of 0.35, with gamma at most 0.6.
        let gamma = mean > 0.01 && mean < 0.35 ? max(log(0.35) / log(mean), 0.6) : 1
        return (0..<256).map { UInt8((pow(stretch(Double($0) / 255), gamma) * 255).rounded()) }
    }
}

/// The shine of gold leaf: foil grain, a bright band and gold dust that move with the tilt.
struct GoldShine: View {
    @ObservedObject private var visibility = PopoverVisibility.shared
    @Environment(\.holoTilt) private var tilt

    var body: some View {
        Group {
            if let tilt {
                GoldLayers(tilt: tilt)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: isSnapshotRender || !visibility.visible)) { t in
                    let s = isSnapshotRender ? 0.9 : t.date.timeIntervalSinceReferenceDate
                    GoldLayers(tilt: CGPoint(x: sin(s * 0.8) * 0.85, y: cos(s * 0.6) * 0.5))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GoldLayers: View {
    let tilt: CGPoint

    var body: some View {
        ZStack {
            // Foil grain: fine light and dark lines across the leaf.
            Canvas { ctx, size in
                let step = max(size.width / 34, 1.6)
                var x = -size.height
                var k = 0
                while x < size.width + size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x + size.height * 0.62, y: size.height))
                    ctx.stroke(line, with: .color(k % 2 == 0 ? .white.opacity(0.5) : hex(0x3C1E00).opacity(0.35)),
                               lineWidth: max(step * 0.2, 0.4))
                    x += step
                    k += 1
                }
            }
            .blendMode(.overlay)
            .opacity(0.5)
            // The bright band that crosses the gold as the card leans.
            LinearGradient(stops: [.init(color: .clear, location: 0.34), .init(color: hex(0xFFD978).opacity(0.35), location: 0.44),
                                   .init(color: hex(0xFFF6D8).opacity(0.8), location: 0.5), .init(color: hex(0xFFD978).opacity(0.35), location: 0.56),
                                   .init(color: .clear, location: 0.66)],
                           startPoint: UnitPoint(x: -0.6 - tilt.x * 0.9, y: -0.3 - tilt.y * 0.6),
                           endPoint: UnitPoint(x: 1.6 - tilt.x * 0.9, y: 1.3 - tilt.y * 0.6))
                .blendMode(.plusLighter)
                .opacity(0.55)
            // Gold dust that lights up at different angles.
            Canvas { ctx, size in
                let count = min(Int(size.width * size.height / 70), 380)
                var seed: UInt64 = 0xD1B54A32D192ED03
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                let dot = max(size.width / 200, 0.45)
                for _ in 0..<count {
                    let px = next() * size.width, py = next() * size.height, phase = next() * 12
                    let glow = sin(phase + tilt.x * 4 + tilt.y * 3)
                    guard glow > 0.78 else { continue }
                    let r = dot * (0.7 + (glow - 0.78) * 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                             with: .color(hex(0xFFF6D0).opacity(Double(glow - 0.78) * 3.5)))
                }
            }
            .blendMode(.plusLighter)
        }
    }
}

/// A polished gold surface.
struct PolishedGold: View {
    var body: some View {
        LinearGradient(colors: polishedGold, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Gold finish on cards drawn in the app: the background itself turns gold.
let goldColors: [UInt32] = [0xF6D77A, 0x9C6B12]

/// A moment with no free image: its symbol on a gradient, with the caption.
private struct DrawnFace: View {
    let card: CardDef
    let symbol: String
    let colors: [UInt32]
    let width: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: colors.map(hex), startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.35), .clear], center: .init(x: 0.5, y: 0.32),
                           startRadius: 0, endRadius: width * 0.6)
            VStack(spacing: width * 0.05) {
                Image(systemName: symbol).font(.system(size: width * 0.34, weight: .semibold))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(height: width * 0.62)
                Text(card.title)
                    .font(.system(size: max(width * 0.085, 6), weight: .bold, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                Text(card.yearText).font(.system(size: max(width * 0.07, 5), weight: .medium).monospacedDigit()).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, width * 0.07)
        }
    }
}

/// A company with its logo on its brand colour, signed by Filmo.
private struct LogoFace: View {
    let card: CardDef
    let bg: UInt32
    var gold = false
    let width: CGFloat
    @State private var image: NSImage?

    init(card: CardDef, bg: UInt32, gold: Bool = false, width: CGFloat) {
        self.card = card
        self.bg = bg
        self.gold = gold
        self.width = width
        _image = State(initialValue: Posters.cached(card))
    }

    var body: some View {
        // A logo that brought its own background lends it to the card, so no box shows.
        let base = gold ? hex(0xE8C25A) : (Posters.background(card).map { Color(nsColor: $0) } ?? hex(bg))
        ZStack {
            if gold { PolishedGold() } else { base }
            RadialGradient(colors: [.white.opacity(0.14), .clear], center: .init(x: 0.5, y: 0.32),
                           startRadius: 0, endRadius: width * 0.7)
            VStack(spacing: 0) {
                Group {
                    if let image, gold, Posters.isLightLogo(card) {
                        // On gold, a light logo sits on a dark bronze plate so it always reads.
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .padding(width * 0.05)
                            .background(RoundedRectangle(cornerRadius: width * 0.04)
                                .fill(LinearGradient(colors: [hex(0x3A2606), hex(0x1C1203)], startPoint: .top, endPoint: .bottom)))
                            .overlay(RoundedRectangle(cornerRadius: width * 0.04)
                                .strokeBorder(LinearGradient(colors: polishedGold, startPoint: .topLeading, endPoint: .bottomTrailing),
                                              lineWidth: max(width * 0.012, 1)))
                    } else if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Monogram(title: card.title, width: width)
                    }
                }
                // Very wide wordmarks may use the full width.
                .frame(width: width * (wide ? 0.9 : 0.78), height: width * 0.52)
                .frame(maxHeight: .infinity)
                VStack(spacing: width * 0.025) {
                    Text(card.title)
                        .font(.system(size: max(width * 0.08, 6), weight: .bold))
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                    Text(card.by)
                        .font(.system(size: max(width * 0.058, 5), weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(2).opacity(0.75)
                    FilmoSignature(width: width).padding(.top, width * 0.02)
                }
                .padding(.bottom, width * 0.07)
            }
            .foregroundStyle(base.isLight ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, width * 0.05)
            .padding(.top, width * 0.06)
        }
        .task(id: card.id) { if image == nil { image = await Posters.load(card) } }
    }

    private var wide: Bool {
        guard let image, image.size.height > 0 else { return false }
        return image.size.width / image.size.height > 3.5
    }
}

/// Initials in a ring, for companies with no logo to show.
private struct Monogram: View {
    let title: String
    let width: CGFloat

    private var initials: String {
        let words = title.split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(title.prefix(2))
        return String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: max(width * 0.02, 1))
            Circle().fill(.white.opacity(0.08)).padding(width * 0.03)
            Text(initials).font(.system(size: width * 0.17, weight: .black)).tracking(1)
        }
        .frame(width: width * 0.42, height: width * 0.42)
    }
}

/// The small "FILMO" signature at the foot of company cards.
private struct FilmoSignature: View {
    let width: CGFloat
    var body: some View {
        HStack(spacing: width * 0.03) {
            FilmoF().frame(width: width * 0.07, height: width * 0.075)
            Text("FILMO").font(.system(size: max(width * 0.055, 4.5), weight: .heavy)).tracking(1)
        }
        .opacity(0.6)
    }
}

extension Color {
    /// Whether dark text reads better on this colour.
    var isLight: Bool {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62
    }
}

/// A company of the industry: its name as a wordmark, signed by Filmo.
private struct BrandFace: View {
    let card: CardDef
    let colors: [UInt32]
    let width: CGFloat

    var body: some View {
        let base = hex(colors.first ?? 0x2C2C2E)
        ZStack {
            LinearGradient(colors: colors.map(hex), startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.12), .clear], center: .init(x: 0.5, y: 0.32),
                           startRadius: 0, endRadius: width * 0.7)
            VStack(spacing: 0) {
                Monogram(title: card.title, width: width).frame(maxHeight: .infinity)
                VStack(spacing: width * 0.025) {
                    Text(card.title)
                        .font(.system(size: max(width * 0.08, 6), weight: .bold))
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                    Text(card.by)
                        .font(.system(size: max(width * 0.058, 5), weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(2).opacity(0.75)
                    FilmoSignature(width: width).padding(.top, width * 0.02)
                }
                .padding(.bottom, width * 0.07)
            }
            .foregroundStyle(base.isLight ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, width * 0.07)
            .padding(.top, width * 0.06)
        }
    }
}

private struct HoloTiltKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
extension EnvironmentValues {
    /// Where the light falls on a holographic card, from -1 to 1 on each axis. Nil: it drifts on its own.
    var holoTilt: CGPoint? {
        get { self[HoloTiltKey.self] }
        set { self[HoloTiltKey.self] = newValue }
    }
}

/// The foil of a holographic card: rainbow bands, glitter and a glare that move with the tilt.
struct HoloShine: View {
    @ObservedObject private var visibility = PopoverVisibility.shared
    @Environment(\.holoTilt) private var tilt

    var body: some View {
        Group {
            if let tilt {
                HoloLayers(tilt: tilt)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: isSnapshotRender || !visibility.visible)) { t in
                    let s = isSnapshotRender ? 0.9 : t.date.timeIntervalSinceReferenceDate
                    HoloLayers(tilt: CGPoint(x: sin(s * 0.9) * 0.8, y: cos(s * 0.65) * 0.5))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct HoloLayers: View {
    let tilt: CGPoint

    private static let rainbow: [Color] = {
        let hues: [Color] = [hex(0xFF5FA2), hex(0xFFD86B), hex(0x7DFFB2), hex(0x5CC8FF), hex(0xA77BFF)]
        return Array(repeating: hues + [hex(0xFF5FA2)], count: 3).flatMap { $0 }
    }()

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // Rainbow bands that slide across the card as it tilts.
                LinearGradient(colors: Self.rainbow,
                               startPoint: UnitPoint(x: -0.9 + tilt.x * 0.7, y: -0.6 + tilt.y * 0.5),
                               endPoint: UnitPoint(x: 1.9 + tilt.x * 0.7, y: 1.6 + tilt.y * 0.5))
                    .blendMode(.overlay)
                    .opacity(0.6)
                LinearGradient(colors: Self.rainbow,
                               startPoint: UnitPoint(x: -0.9 + tilt.x * 0.7, y: -0.6 + tilt.y * 0.5),
                               endPoint: UnitPoint(x: 1.9 + tilt.x * 0.7, y: 1.6 + tilt.y * 0.5))
                    .blendMode(.colorDodge)
                    .opacity(0.12)
                // Diagonal foil lines, like the grain of a printed hologram.
                Canvas { ctx, size in
                    let step = max(size.width / 14, 3)
                    var x = -size.height + CGFloat(tilt.x) * step
                    while x < size.width + size.height {
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x + size.height * 0.6, y: size.height))
                        ctx.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: max(step * 0.25, 0.6))
                        x += step
                    }
                }
                .blendMode(.overlay)
                // Glitter: tiny sparks that light up at different angles.
                Canvas { ctx, size in
                    let count = min(Int(size.width * size.height / 90), 320)
                    var seed: UInt64 = 0x9E3779B97F4A7C15
                    func next() -> CGFloat {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                    }
                    let dot = max(size.width / 220, 0.45)
                    for _ in 0..<count {
                        let px = next() * size.width, py = next() * size.height, phase = next() * 12
                        let glow = sin(phase + tilt.x * 4 + tilt.y * 3)
                        guard glow > 0.8 else { continue }
                        let r = dot * (0.7 + (glow - 0.8) * 3)
                        ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(Double(glow - 0.8) * 3)))
                    }
                }
                .blendMode(.plusLighter)
                // The glare of the light, opposite to where the card leans.
                RadialGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .clear],
                               center: UnitPoint(x: 0.5 - tilt.x * 0.55, y: 0.45 - tilt.y * 0.55),
                               startRadius: 0, endRadius: max(w, h) * 0.65)
                    .blendMode(.overlay)
            }
        }
    }
}

/// Holographic cards lean toward the pointer, and their foil follows it.
struct HoloHoverTilt: ViewModifier {
    let enabled: Bool
    var maxAngle: Double = 14
    @State private var tilt: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.holoTilt, tilt)
                .background(GeometryReader { g in
                    Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
                })
                .rotation3DEffect(.degrees((tilt?.y ?? 0) * maxAngle), axis: (1, 0, 0), perspective: 0.6)
                .rotation3DEffect(.degrees(-(tilt?.x ?? 0) * maxAngle), axis: (0, 1, 0), perspective: 0.6)
                .animation(.easeOut(duration: 0.18), value: tilt)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p) where size.width > 0:
                        tilt = CGPoint(x: min(max(p.x / size.width * 2 - 1, -1), 1),
                                       y: min(max(p.y / size.height * 2 - 1, -1), 1))
                    default:
                        tilt = nil
                    }
                }
        } else {
            content
        }
    }
}

/// The first time in Cromos: three short pages, and a Serie A pack for finishing them.
struct CromosWelcome: View {
    /// Coins earned so far, counted back to Filmo Time's launch; nil while they are being counted.
    let coins: Int?
    let done: () -> Void
    @State private var page = 0

    private struct Page { let title: String; let text: String }
    private let pages = [
        Page(title: "Trabaja y gana filmo-coins", text: "Tus horas de trabajo se convierten en filmo-coins. Cada jornada de 7 h te regala además un sobre."),
        Page(title: "Abre sobres", text: "Los cromos salen boca abajo: pasa el ratón para ver el brillo de su rareza y haz clic para darles la vuelta."),
        Page(title: "Completa la Filmedex", text: "Películas, series, industria y Filmo. Las repetidas te dan Tokens para fabricar los que te falten."),
    ]

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [hex(0x1E1E24).opacity(0.94), hex(0x0C0C0F).opacity(0.97)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                illustration.frame(height: 110)
                VStack(spacing: 6) {
                    Text(pages[page].title).font(.system(size: 17, weight: .bold))
                    Text(pages[page].text).font(.system(size: 12)).multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    if page == 0 {
                        VStack(spacing: 4) {
                            Text("Contando lo que has trabajado desde el 29 de octubre, llevas:")
                                .font(.system(size: 12)).multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                if let coins {
                                    Text("\(coins)").font(.system(size: 20, weight: .bold).monospacedDigit())
                                        .contentTransition(.numericText())
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                CoinIcon(size: 18)
                            }
                            .foregroundStyle(hex(0xFFD98A))
                        }
                        .padding(.top, 6)
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .padding(.horizontal, 28)
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == page ? 0.9 : 0.3)).frame(width: i == page ? 16 : 6, height: 6)
                    }
                }
                Button {
                    if page < pages.count - 1 { withAnimation(.smooth(duration: 0.3)) { page += 1 } } else { done() }
                } label: {
                    HStack(spacing: 8) {
                        if page == pages.count - 1 {
                            PackArt(pack: pack(Album.onboardingPack), width: 16)
                            Text("Empezar · te regalamos un sobre \(pack(Album.onboardingPack).name)")
                        } else {
                            Text("Siguiente")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(page == pages.count - 1 ? Theme.green : Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28).padding(.top, 6)
            }
            .padding(.bottom, 70)
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var illustration: some View {
        switch page {
        case 0:
            ZStack {
                RadialGradient(colors: [hex(0xFFD36B).opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 75)
                    .frame(width: 220, height: 220)
                CoinIcon(size: 64)
            }
        case 1:
            HStack(spacing: -14) {
                ForEach(Array(Rarity.allCases.enumerated()), id: \.offset) { i, r in
                    CardBack(width: 52, glow: r)
                        .rotationEffect(.degrees(Double(i - 1) * 7 - 3))
                        .offset(y: abs(Double(i) - 1.5) * 6)
                }
            }
        default:
            HStack(spacing: -16) {
                ForEach(Array(["padrino", "breaking-bad", "f-arri"].enumerated()), id: \.offset) { i, id in
                    if let c = allCards.first(where: { $0.id == id }) {
                        CardFace(card: c, finish: i == 1 ? .holo : .normal, width: 66)
                            .rotationEffect(.degrees(Double(i - 1) * 9))
                            .offset(y: i == 1 ? -6 : 4)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                            .zIndex(i == 1 ? 1 : 0)
                    }
                }
            }
        }
    }
}

/// The back of a card. All backs look the same; `glow` lights the edge in a rarity's colour.
struct CardBack: View {
    let width: CGFloat
    var glow: Rarity? = nil

    var body: some View {
        let radius = width * 0.07
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [hex(0x1B1B1F), hex(0x0B0B0C)],
                                                                      startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: radius * 0.6).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .padding(width * 0.06)
            FilmoF().fill(.white.opacity(0.9)).frame(width: width * 0.32, height: width * 0.34)
            if let glow {
                RoundedRectangle(cornerRadius: radius).strokeBorder(glow.gradient, lineWidth: max(width * 0.035, 2))
            } else {
                RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
        }
        .frame(width: width, height: width * 1.5)
        .shadow(color: glow.map { $0.colors[0].opacity(0.95) } ?? .black.opacity(0.3), radius: glow == nil ? 3 : width * 0.16)
        .shadow(color: glow.map { $0.colors[1].opacity(0.6) } ?? .clear, radius: glow == nil ? 0 : width * 0.3)
    }
}

/// A foil pack with its name.
struct PackArt: View {
    let pack: PackKind
    let width: CGFloat

    var body: some View {
        let h = width * 1.4
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.08)
                .fill(LinearGradient(colors: pack.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            // Crimped ends.
            VStack {
                Rectangle().fill(.white.opacity(0.25)).frame(height: h * 0.06)
                Spacer()
                Rectangle().fill(.black.opacity(0.18)).frame(height: h * 0.06)
            }
            LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.35), .white.opacity(0.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: h * 0.04) {
                FilmoF().fill(.white).frame(width: width * 0.26, height: width * 0.28)
                Text(pack.name.uppercased())
                    .font(.system(size: max(width * 0.12, 6), weight: .heavy))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, width * 0.06)
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.08))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

// MARK: - Tab

struct AlbumTab: View {
    @ObservedObject var model: Album
    @ObservedObject var achievements: Achievements
    @State private var section = Section(rawValue: AlbumTab.snapshotSection) ?? .packs
    @AppStorage("dexOnlyOwned") private var onlyOwned = false
    @State private var detail: CardDef?
    @Namespace private var underline
    /// Snapshot only.
    nonisolated(unsafe) static var snapshotSection = ""
    nonisolated(unsafe) static var snapshotDetail = ""
    nonisolated(unsafe) static var snapshotOnboarding = false

    enum Section: String, CaseIterable { case packs = "Sobres", album = "Filmedex" }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 8)
                sectionBar
                Divider().opacity(0.6).padding(.horizontal, -16)
                Group {
                    if isSnapshotRender {
                        sectionContent.padding(.top, 8)
                    } else {
                        ScrollView { sectionContent.padding(.vertical, 8) }.scrollIndicators(.never)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            if let d = detail ?? allCards.first(where: { $0.id == Self.snapshotDetail }) {
                CardDetail(card: d, model: model, reveal: { c in withAnimation(.smooth(duration: 0.3)) { detail = c } }) {
                    withAnimation(.smooth(duration: 0.2)) { detail = nil }
                }
                    .transition(.opacity)
            }
            if let o = model.opening {
                PackOpening(pack: o.pack, pulls: o.pulls, completed: o.completed, owned: { model.owned($0) },
                            initialFlipped: model.pendingFlipped, initialTorn: model.pendingTorn,
                            saveProgress: { model.savePending(flipped: $0, torn: $1) }) {
                    withAnimation(.smooth(duration: 0.25)) { model.finishOpening() }
                }
                .transition(.opacity)
            }
            if (!model.state.onboarded || Self.snapshotOnboarding) && model.opening == nil {
                CromosWelcome(coins: model.state.backfilled ? Int(model.state.earned.values.reduce(0, +)) : nil) {
                    withAnimation(.smooth(duration: 0.3)) { model.finishOnboarding() }
                }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.dropFinishedOpening()
            sync()
        }
        .onChange(of: achievements.tierMap) { sync() }
        .onChange(of: achievements.activeTierMap) { sync() }
    }

    private func sync() {
        guard !isSnapshotRender else { return }
        model.reward(tiers: achievements.tierMap)
        model.updateBonus(tiers: achievements.activeTierMap)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            CoinIcon(size: 18)
            Text("\(model.balance)").font(.system(size: 22, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text("filmo-coins").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(Int(model.earnedToday())) hoy" + (model.achievementBonus > 0 ? " · logros +\(Int((model.achievementBonus * 100).rounded())) %" : ""))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                HStack(spacing: 3) {
                    TokenIcon(size: 10)
                    Text("\(model.state.tokens) Tokens").font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sectionBar: some View {
        HStack(spacing: 12) {
            ForEach(Section.allCases, id: \.self) { s in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { section = s }
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 3) {
                            Text(s.rawValue)
                            if s == .album {
                                Text("\(model.state.cards.count)/\(allCards.count)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 11, weight: section == s ? .semibold : .regular))
                        .foregroundStyle(section == s ? Color.primary : Color.secondary)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 2)
                            if section == s {
                                Capsule().fill(Theme.brand).frame(height: 2).matchedGeometryEffect(id: "section", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            OddsInfoButton(model: model).padding(.bottom, 7)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .packs: packs
        case .album: album
        }
    }

    // MARK: Packs

    private var packs: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([dailyPack] + packKinds) { p in
                HStack(spacing: 10) {
                    PackArt(pack: p, width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name.hasPrefix("Sobre") ? p.name : "Sobre \(p.name)").font(.system(size: 12, weight: .medium))
                        Text(p.id == dailyPack.id ? "1 cromo gratis por cada jornada de 7 h"
                             : "\(p.count) cromos · legendaria \(percent(p.odds[3]))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) {
                        if model.free(p) > 0 {
                            Button { model.openFree(p) } label: {
                                Text(model.free(p) > 1 ? "Abrir · \(model.free(p))" : "Abrir")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .frame(minWidth: 62)
                                    .background(Capsule().fill(Theme.green))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        } else if p.id == dailyPack.id {
                            Text(model.dailyPackEarned ? "Abierto" : "En curso")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .frame(minWidth: 62)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        } else {
                            CoinButton(price: p.price, enabled: model.canBuy(p)) { model.buy(p) }
                        }
                        if let left = freeLeft(p) {
                            Text(left).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                tip("sun.max", "Cada jornada de 7 h te da el sobre del día, y cada \(Album.daysPerFreePack) jornadas un sobre Seed.")
                tip("trophy", "Cada logro nuevo te da un sobre al azar.")
                tip("rosette", "Cada nivel de prestigio recuperado te da otro sobre, con más opciones de que sea bueno, y Tokens.")
                if model.state.pity > 0 {
                    tip("dice", "Racha sin épicas: +\(Int(model.pityBonus)) % de épica en el próximo sobre.")
                }
            }
            .padding(.top, 4)
        }
    }

    /// Under a free pack's button: how long until the next one.
    private func freeLeft(_ p: PackKind) -> String? {
        if p.id == dailyPack.id {
            guard model.free(p) == 0 else { return nil }
            if model.dailyPackEarned { return "otro mañana" }
            let left = max(Album.fullDay - model.todaySeconds, 60)
            let h = Int(left) / 3600, m = Int(left) % 3600 / 60
            return h > 0 ? "faltan \(h) h \(m) min" : "faltan \(m) min"
        }
        if p.id == "estreno" {
            let n = model.daysToFreeSeed
            return n == 1 ? "gratis en 1 jornada" : "gratis en \(n) jornadas"
        }
        return nil
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // MARK: Album

    /// Every card, by category and then by rarity, best first.
    private var album: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button { withAnimation(.smooth(duration: 0.2)) { onlyOwned.toggle() } } label: {
                HStack(spacing: 3) {
                    Image(systemName: onlyOwned ? "checkmark.circle.fill" : "circle").font(.system(size: 9))
                    Text("Solo los que tengo").font(.system(size: 10))
                }
                .foregroundStyle(onlyOwned ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Oculta los huecos de los cromos que aún no tienes")
            CardCatalog(scope: "dex", only: onlyOwned && !isSnapshotRender ? { model.owned($0) != nil } : nil,
                        owned: { model.owned($0) != nil }) { c in
                Button { withAnimation(.smooth(duration: 0.2)) { detail = c } } label: { slot(c) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.owned(c) != nil ? c.title : "Cromo oculto, \(c.rarity.name.lowercased())")
            }
        }
    }

    @ViewBuilder private func slot(_ c: CardDef) -> some View {
        if let o = model.owned(c) {
            CardFace(card: c, art: o.shownArt, finish: o.shownFinish, width: 54)
                .modifier(HoloHoverTilt(enabled: o.shownFinish != .normal, maxAngle: 16))
                .overlay(alignment: .topLeading) {
                    if model.isUnseen(c) {
                        Text("NUEVO").font(.system(size: 7, weight: .heavy)).tracking(0.5)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.green)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .padding(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if o.count > 1 {
                        Text("×\(o.count)").font(.system(size: 8, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.black.opacity(0.7))).foregroundStyle(.white)
                            .padding(4)
                    }
                }
        } else {
            MissingSlot(card: c, width: 54, craftable: model.canCraft(set: c.set, rarity: c.rarity))
        }
    }

    // MARK: Help

}

/// Which parts of a catalogue are folded away; remembered between openings.
@MainActor
final class CatalogFolds: ObservableObject {
    static let shared = CatalogFolds()
    private static let key = "catalogFolds"
    @Published private(set) var folded = Set(UserDefaults.standard.stringArray(forKey: CatalogFolds.key) ?? [])

    func toggle(_ id: String) {
        if folded.remove(id) == nil { folded.insert(id) }
        UserDefaults.standard.set(folded.sorted(), forKey: Self.key)
    }
}

/// Cards by category and then by rarity, best first; categories and rarities fold away.
struct CardCatalog<Slot: View>: View {
    /// Keeps the folds of each place it is used apart.
    let scope: String
    /// Lists only these; the album lists every card, gaps included.
    var only: ((CardDef) -> Bool)? = nil
    let owned: (CardDef) -> Bool
    var width: CGFloat = 54
    @ViewBuilder let slot: (CardDef) -> Slot
    @ObservedObject private var folds = CatalogFolds.shared

    private func isFolded(_ id: String) -> Bool { !isSnapshotRender && folds.folded.contains("\(scope)/\(id)") }

    private func header<Label: View>(_ id: String, @ViewBuilder label: () -> Label) -> some View {
        Button { withAnimation(.smooth(duration: 0.2)) { folds.toggle("\(scope)/\(id)") } } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isFolded(id) ? 0 : 90))
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolded(id) ? "Mostrar" : "Ocultar")
    }

    private func tally(_ cards: [CardDef]) -> String {
        only == nil ? "\(cards.filter(owned).count)/\(cards.count)" : "\(cards.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(cardSets) { s in
                let listed = s.cards.filter { only?($0) ?? true }
                if !listed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        header(s.id) {
                            Image(systemName: s.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(s.name).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if only == nil, listed.allSatisfy(owned) {
                                Label("Completa", systemImage: "checkmark.seal.fill").font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.green)
                            } else {
                                Text(tally(listed)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if !isFolded(s.id) {
                            ForEach(Rarity.allCases.reversed(), id: \.self) { r in
                                let cards = listed.filter { $0.rarity == r }
                                if !cards.isEmpty {
                                    let id = "\(s.id)/\(r.rawValue)"
                                    header(id) {
                                        Capsule().fill(r.gradient).frame(width: 14, height: 4)
                                        Text(r.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                        Text(tally(cards)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                                        Spacer()
                                    }
                                    .padding(.top, 2)
                                    if !isFolded(id) {
                                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 9), count: 5),
                                                  alignment: .leading, spacing: 10) {
                                            ForEach(cards) { c in slot(c) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A gap in the album: the rarity frame and the title, greyed out.
private struct MissingSlot: View {
    let card: CardDef
    let width: CGFloat
    let craftable: Bool

    var body: some View {
        let r = width * 0.07
        ZStack {
            RoundedRectangle(cornerRadius: r).fill(Color.secondary.opacity(0.08))
            RoundedRectangle(cornerRadius: r).strokeBorder(card.rarity.gradient.opacity(0.45),
                                                          style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            Text("?").font(.system(size: width * 0.32, weight: .bold, design: .serif)).foregroundStyle(.tertiary)
            if craftable {
                TokenIcon(size: 12).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: width, height: width * 1.5)
    }
}

/// A gold token with a T.
struct TokenIcon: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [hex(0xFFE58F), hex(0xE09A1E)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(hex(0xA86A0C), lineWidth: max(size * 0.07, 0.6))
            Text("T").font(.system(size: size * 0.6, weight: .black, design: .rounded)).foregroundStyle(hex(0x7A4B05))
        }
        .frame(width: size, height: size)
    }
}

private struct CoinButton: View {
    let price: Int
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                CoinIcon(size: 11)
                Text("\(price)").font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3)
            .frame(minWidth: 62)
            .background(Capsule().fill(enabled ? Theme.brand : Color.secondary.opacity(0.15)))
            .foregroundStyle(enabled ? Theme.onBrand : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Detail

private struct CardDetail: View {
    let card: CardDef
    @ObservedObject var model: Album
    let reveal: (CardDef) -> Void
    let close: () -> Void

    private var setName: String { cardSets.first { $0.id == card.set }?.name ?? "" }

    var body: some View {
        let owned = model.owned(card)
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.88)).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let owned {
                            CardShowcase(card: card, owned: owned, width: 104)
                                .onAppear { model.markSeen(card) }
                        } else {
                            MissingSlot(card: card, width: 96, craftable: false)
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        }
                    }
                    info(owned)
                }
                if let owned { variants(owned) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain).padding(8)
            }
            .padding(10)
        }
    }

    private func info(_ owned: OwnedCard?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(owned == nil ? "Cromo oculto" : card.title).font(.system(size: 13, weight: .bold))
                .fixedSize(horizontal: false, vertical: true).padding(.trailing, 18)
            Text(owned == nil ? setName : [card.yearText, card.by].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(card.rarity.name.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(card.rarity.gradient))
                .foregroundStyle(.black.opacity(0.7))
            if let owned {
                if let q = card.quote {
                    Text("«\(q)»").font(.system(size: 11, weight: .semibold, design: .serif)).italic()
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                Text(card.trivia).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                if owned.count > 1 {
                    Text("Tienes \(owned.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                if !card.credit.isEmpty {
                    Text(card.credit).font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let can = model.canCraft(set: card.set, rarity: card.rarity)
                let left = model.missing(set: card.set, rarity: card.rarity).count
                Text("No sabrás cuál es hasta que te salga. Con Tokens puedes fabricar una \(card.rarity.name.lowercased()) de \(setName) al azar entre las \(left) que te faltan.")
                    .font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                tokenButton("Fabricar", cost: card.rarity.craftCost, enabled: can) {
                    if let c = model.craft(set: card.set, rarity: card.rarity) { reveal(c) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card's arts and finishes: the ones you have can be shown, the rest stay hidden.
    private func variants(_ owned: OwnedCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Arte").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(card.arts.filter(owned.arts.contains).count)/\(card.arts.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                if card.arts.contains(where: { !owned.arts.contains($0) }) {
                    tokenButton("Variante", cost: model.variantCost(card), enabled: model.canCraftVariant(card)) {
                        model.craftVariant(card)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(card.arts, id: \.self) { a in
                    let has = owned.arts.contains(a)
                    Button { model.show(card, art: a) } label: {
                        Group {
                            if has {
                                CardFace(card: card, art: a, finish: .normal, width: 34)
                            } else {
                                MissingSlot(card: card, width: 34, craftable: false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(owned.shownArt == a ? Theme.brand : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!has)
                    .help(has ? a.name : "Variante oculta")
                }
            }
            HStack(spacing: 5) {
                Text("Acabado").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Finish.allCases, id: \.self) { f in
                    let has = owned.finishes.contains(f)
                    Button { model.show(card, finish: f) } label: {
                        Text(has ? f.name : "?")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(owned.shownFinish == f ? Theme.brand : Color.secondary.opacity(has ? 0.15 : 0.07)))
                            .foregroundStyle(owned.shownFinish == f ? Theme.onBrand : has ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!has)
                }
            }
        }
    }

    private func tokenButton(_ title: String, cost: Int, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                TokenIcon(size: 10)
                Text("\(title) · \(cost)").font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(enabled ? Theme.brand : Color.secondary.opacity(0.15)))
            .foregroundStyle(enabled ? Theme.onBrand : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Tienes \(model.state.tokens) Tokens")
    }
}

// MARK: - Opening a pack

/// All the cards come out face down and alike; hovering one lights its edge in its
/// rarity's colour, and clicking turns it.
struct PackOpening: View {
    let pack: PackKind
    let pulls: [Pull]
    let completed: [CardSet]
    var owned: (CardDef) -> OwnedCard? = { _ in nil }
    var initialFlipped: Set<Int> = []
    var initialTorn = false
    var saveProgress: (Set<Int>, Bool) -> Void = { _, _ in }
    let done: () -> Void
    /// A turned card opened in its showcase.
    @State private var inspecting: Pull?

    @State private var torn = PackOpening.snapshotStage != ""
    @State private var flipped: Set<Int> = PackOpening.snapshotFlipped
    @State private var hovered: Int? = PackOpening.snapshotStage == "carta" ? 0 : nil
    @State private var wiggle = false
    /// The legendary card on stage, while the curtain show plays.
    @State private var stage: Int? = PackOpening.snapshotStage.hasPrefix("telon") ? 0 : nil
    @State private var curtainOpen = PackOpening.snapshotStage == "telon"
    @State private var stageFlipped = PackOpening.snapshotStage == "telon"
    /// Snapshot only: "", "carta", "girada", "resumen", "telon-cerrado" or "telon".
    nonisolated(unsafe) static var snapshotStage = ""
    nonisolated(unsafe) static var snapshotFlipped: Set<Int> = []

    private let width: CGFloat = 80
    private var allFlipped: Bool { flipped.count >= pulls.count }
    /// Three on top and the rest below, like a hand laid on the table.
    private var rows: [[Int]] {
        let top = min(3, pulls.count)
        return [Array(0..<top), Array(top..<pulls.count)].filter { !$0.isEmpty }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if !torn {
                sealed
            } else {
                VStack(spacing: 12) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 12) {
                            ForEach(rows[r], id: \.self) { i in card(i) }
                        }
                    }
                    footer.frame(height: 40)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if let p = inspecting {
                ZStack {
                    Rectangle().fill(.black.opacity(0.75)).onTapGesture { withAnimation(.smooth(duration: 0.2)) { inspecting = nil } }
                    VStack(spacing: 10) {
                        CardShowcase(card: p.card,
                                     owned: owned(p.card) ?? OwnedCard(count: 1, first: Date(), finish: p.finish),
                                     width: 140, art: p.art, finish: p.finish)
                        Text(p.card.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        Text("Toca fuera para volver").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .transition(.opacity)
            }
            if let i = stage ?? (PackOpening.snapshotStage.hasPrefix("telon") ? bestIndex : nil) {
                LegendaryReveal(pull: pulls[i], curtainOpen: curtainOpen, flipped: stageFlipped)
                    .onTapGesture {
                        guard stageFlipped else { return }
                        withAnimation(.smooth(duration: 0.35)) { stage = nil; curtainOpen = false; stageFlipped = false }
                    }
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            if !initialFlipped.isEmpty { flipped.formUnion(initialFlipped) }
            if initialTorn { torn = true }
        }
        .onChange(of: flipped) { saveProgress(flipped, torn) }
        .onChange(of: torn) { saveProgress(flipped, torn) }
    }

    private var bestIndex: Int { pulls.indices.max { pulls[$0].card.rarity < pulls[$1].card.rarity } ?? 0 }

    /// Curtain down, curtain up, then the card turns under the spotlight.
    private func playLegendary(_ i: Int) {
        // One curtain at a time: a second tap or "Ver todas" while it plays does nothing.
        guard stage == nil, !flipped.contains(i) else { return }
        withAnimation(.easeIn(duration: 0.3)) { stage = i }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 1.3)) { curtainOpen = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.spring(duration: 0.9, bounce: 0.25)) { stageFlipped = true }
            flipped.insert(i)
        }
    }

    private var sealed: some View {
        VStack(spacing: 14) {
            PackArt(pack: pack, width: 110)
                .rotationEffect(.degrees(wiggle ? 2.5 : -2.5))
                .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: wiggle)
                .onAppear { wiggle = true }
            Text("Toca para abrir").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
        .onTapGesture { withAnimation(.spring(duration: 0.45, bounce: 0.25)) { torn = true } }
    }

    /// The pull in a slot; snapshots can force two variant arts to review how they are announced.
    private func pull(_ i: Int) -> Pull {
        guard PackOpening.snapshotStage == "variante", i < 2, let c = allCards.first(where: { $0.id == "padrino" }) else { return pulls[i] }
        return Pull(card: c, art: i == 0 ? .alt : .scene, finish: .normal, isNew: i == 0, newArt: i == 0 ? .alt : .scene)
    }

    private func card(_ i: Int) -> some View {
        let p = pull(i)
        let isUp = flipped.contains(i)
        return ZStack {
            if isUp, let a = p.newArt { ArtBurst(art: a, width: width) }
            CardBack(width: width, glow: hovered == i && !isUp ? p.card.rarity : nil)
                .opacity(isUp ? 0 : 1)
            CardFace(card: p.card, art: p.art, finish: p.finish, width: width)
                .modifier(HoloHoverTilt(enabled: isUp && p.finish != .normal))
                .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                .opacity(isUp ? 1 : 0)
                .overlay(alignment: .top) {
                    if isUp, let a = p.newArt {
                        ArtRibbon(art: a)
                            .frame(maxWidth: width + 14)
                            .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                            .offset(y: -8)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if isUp {
                        Group {
                            if p.tokens > 0 {
                                // A plain repeat: say so, and show it turning into Tokens.
                                HStack(spacing: 4) {
                                    Text("REPETIDA").font(.system(size: 7.5, weight: .heavy)).tracking(0.5).opacity(0.75)
                                    Image(systemName: "arrow.right").font(.system(size: 7, weight: .bold)).opacity(0.6)
                                    TokenIcon(size: 11)
                                    Text("+\(p.tokens)").font(.system(size: 10, weight: .heavy).monospacedDigit())
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.85)))
                                .overlay(Capsule().strokeBorder(hex(0xE09A1E).opacity(0.8), lineWidth: 1))
                            } else {
                                Text(badge(p))
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(p.isNew ? Theme.green : Color.purple))
                            }
                        }
                        .foregroundStyle(.white)
                        .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                        .offset(y: 9)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
        }
        .rotation3DEffect(.degrees(isUp ? 180 : 0), axis: (0, 1, 0), perspective: 0.5)
        .scaleEffect(hovered == i && !isUp ? 1.06 : 1)
        .shadow(color: isUp && p.finish == .gold ? hex(0xFFCD5A).opacity(0.95)
                : isUp && p.newArt != nil ? ArtRibbon.colors(p.newArt!)[0].opacity(0.85)
                : isUp && p.card.rarity >= .epic ? p.card.rarity.colors[0].opacity(0.7) : .clear, radius: 10)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { inside in hovered = inside ? i : (hovered == i ? nil : hovered) }
        .onTapGesture {
            guard !isUp else {
                withAnimation(.smooth(duration: 0.25)) { inspecting = p }
                return
            }
            if p.card.rarity == .legendary { playLegendary(i); return }
            withAnimation(.spring(duration: 0.55, bounce: 0.2)) { _ = flipped.insert(i) }
        }
    }

    private func badge(_ p: Pull) -> String {
        if p.isNew { return p.finish == .normal ? "¡Nueva!" : "¡Nueva · \(p.finish.name.lowercased())!" }
        if let f = p.newFinish { return "¡\(f.name)!" }
        if p.newArt != nil { return "¡Variante!" }
        return "+\(p.tokens) Tokens"
    }

    @ViewBuilder private var footer: some View {
        if allFlipped {
            let new = pulls.filter(\.isNew).count
            let tokens = pulls.reduce(0) { $0 + $1.tokens }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(new == 0 ? "Ninguna nueva" : new == 1 ? "1 nueva" : "\(new) nuevas")
                        .font(.system(size: 12, weight: .semibold))
                    if let s = completed.first {
                        Text("¡\(s.name) completa! Sobre Serie A de regalo.").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.green)
                    } else if tokens > 0 {
                        HStack(spacing: 3) { TokenIcon(size: 10); Text("+\(tokens) Tokens") }.font(.system(size: 10))
                    }
                }
                .foregroundStyle(.white)
                Button(action: done) {
                    Text("Hecho").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .background(Capsule().fill(.white)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            .transition(.opacity)
        } else {
            Button {
                let left = pulls.indices.filter { !flipped.contains($0) }
                let plain = left.filter { pulls[$0].card.rarity != .legendary }
                // Every card turns at once; a legendary still gets its curtain right after.
                withAnimation(.spring(duration: 0.6, bounce: 0.2)) { flipped.formUnion(plain) }
                if let l = left.first(where: { pulls[$0].card.rarity == .legendary }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { playLegendary(l) }
                }
            } label: {
                Text("Ver todas").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Variant art reveal

/// The label a variant art wears when it comes out of a pack.
private struct ArtRibbon: View {
    let art: Art

    static func colors(_ a: Art) -> [Color] { a == .scene ? [hex(0xFFB42E), hex(0xFF6A00)] : [hex(0xFF4F9A), hex(0x4FB8FF)] }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: art == .scene ? "film.fill" : "paintpalette.fill").font(.system(size: 7, weight: .bold))
            Text(art == .scene ? "ESCENA MÍTICA" : "ALTERNATIVO")
                .font(.system(size: 7, weight: .heavy)).tracking(0.5).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(LinearGradient(colors: Self.colors(art), startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 0.8))
        .shadow(color: Self.colors(art)[0].opacity(0.9), radius: 5)
    }
}

/// Rings and sparks that burst from a card when it turns out to be a variant art.
private struct ArtBurst: View {
    let art: Art
    let width: CGFloat
    @State private var out = false

    var body: some View {
        let colors = ArtRibbon.colors(art)
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                RoundedRectangle(cornerRadius: width * 0.07)
                    .strokeBorder(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
                    .scaleEffect(out ? 1.3 + Double(k) * 0.22 : 1.04)
                    .opacity(out ? 0 : 0.95)
                    .animation(.easeOut(duration: 1.0).delay(Double(k) * 0.16), value: out)
            }
            ForEach(0..<10, id: \.self) { k in
                let a = Double(k) / 10 * 2 * .pi + 0.3
                Image(systemName: "sparkle").font(.system(size: k % 2 == 0 ? 10 : 7, weight: .bold))
                    .foregroundStyle(k % 3 == 0 ? .white : colors[k % 2])
                    .offset(x: cos(a) * width * (out ? 0.95 : 0.45), y: sin(a) * width * (out ? 1.2 : 0.7))
                    .scaleEffect(out ? 0.2 : 1.2)
                    .opacity(out ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).delay(0.04 * Double(k % 4)), value: out)
            }
        }
        .frame(width: width, height: width * 1.5)
        .allowsHitTesting(false)
        .onAppear { if !isSnapshotRender { out = true } }
    }
}

// MARK: - Legendary reveal

/// A red velvet curtain over the whole pack that parts to show a legendary card,
/// which turns over under a spotlight with golden rays behind it.
private struct LegendaryReveal: View {
    let pull: Pull
    let curtainOpen: Bool
    let flipped: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Rectangle().fill(.black)
                // Spotlight and rays behind the card.
                RadialGradient(colors: [hex(0xFFE7A0).opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: h * 0.55)
                Rays().opacity(flipped ? 1 : 0.35).frame(width: w, height: h)
                ZStack {
                    CardBack(width: 150, glow: .legendary).opacity(flipped ? 0 : 1)
                    CardFace(card: pull.card, art: pull.art, finish: pull.finish, width: 150)
                        .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                        .opacity(flipped ? 1 : 0)
                }
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0), perspective: 0.45)
                .scaleEffect(curtainOpen ? 1 : 0.85)
                .shadow(color: hex(0xFFD36B).opacity(flipped ? 0.9 : 0.4), radius: 26)
                VStack(spacing: 4) {
                    Spacer()
                    Text("¡LEGENDARIA!").font(.system(size: 20, weight: .black)).tracking(2)
                        .foregroundStyle(Rarity.legendary.gradient)
                    Text(pull.isNew ? "Nueva en tu Filmedex" : "Toca para seguir")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
                .padding(.bottom, 18)
                .opacity(flipped ? 1 : 0)
                // The curtain: two velvet halves that slide away, and a pelmet that stays.
                HStack(spacing: 0) {
                    Velvet().frame(width: w / 2 + 1, height: h).offset(x: curtainOpen ? -w / 2 - 10 : 0)
                    Velvet(mirrored: true).frame(width: w / 2 + 1, height: h).offset(x: curtainOpen ? w / 2 + 10 : 0)
                }
                VStack {
                    Pelmet().frame(height: 26)
                    Spacer()
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }
}

/// One half of the curtain: folds of red velvet, darker towards the edges.
private struct Velvet: View {
    var mirrored = false
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { _ in
                LinearGradient(colors: [hex(0x4A0710), hex(0xB3162B), hex(0xE0344A), hex(0xB3162B), hex(0x4A0710)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: mirrored ? .leading : .trailing) {
            // The edge where both halves meet catches the light.
            LinearGradient(colors: [hex(0xFF6F7F).opacity(0.35), .clear], startPoint: mirrored ? .leading : .trailing,
                           endPoint: mirrored ? .trailing : .leading).frame(width: 14)
        }
        .shadow(color: .black.opacity(0.6), radius: 8)
    }
}

/// The valance across the top, with a gold trim.
private struct Pelmet: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [hex(0x5E0A15), hex(0x8E1222)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(LinearGradient(colors: [hex(0xFFE08A), hex(0xB8860B)], startPoint: .top, endPoint: .bottom))
                .frame(height: 3)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }
}

/// Golden rays turning slowly behind the card.
private struct Rays: View {
    @ObservedObject private var visibility = PopoverVisibility.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isSnapshotRender || !visibility.visible)) { t in
            AngularGradient(gradient: Gradient(colors: (0..<24).map { $0 % 2 == 0 ? hex(0xFFD36B).opacity(0.42) : .clear }),
                            center: .center)
                .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate * 8))
                .mask(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 10, endRadius: 220))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Famous scene

/// A famous scene as a film frame: the whole still, uncropped, on black with sprocket holes,
/// and what is said in it underneath.
struct SceneFace: View {
    let card: CardDef
    var finish: Finish = .normal
    let width: CGFloat

    var body: some View {
        let frameH = width * 9 / 16
        ZStack {
            Rectangle().fill(LinearGradient(colors: [hex(0x141416), hex(0x050506)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: width * 0.05) {
                Text("ESCENA MÍTICA").font(.system(size: max(width * 0.05, 4.5), weight: .heavy)).tracking(1.2)
                    .foregroundStyle(finish == .gold ? hex(0xF0C75E) : .white.opacity(0.55))
                    .padding(.top, width * 0.09)
                VStack(spacing: 0) {
                    sprockets
                    CardImage(card: card, art: .scene)
                        .frame(width: width, height: frameH).clipped()
                    sprockets
                }
                if let line = card.extras.sceneLine {
                    // A quote is said as in the film, with the Spanish underneath like a subtitle.
                    let original = sceneOriginals[card.id]
                    VStack(spacing: width * 0.025) {
                        Text(original.map { "«\($0)»" } ?? line)
                            .font(.system(size: max(width * 0.08, 6), weight: .semibold, design: .serif))
                            .italic(line.hasPrefix("«"))
                            .multilineTextAlignment(.center).lineLimit(original == nil ? 4 : 3).minimumScaleFactor(0.6)
                            .foregroundStyle(.white)
                        if original != nil {
                            Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "«»")))
                                .font(.system(size: max(width * 0.052, 4.5))).italic()
                                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, width * 0.08)
                }
                Spacer(minLength: 0)
                Text(card.title.uppercased()).font(.system(size: max(width * 0.05, 4.5), weight: .bold)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, width * 0.08)
                    .padding(.bottom, width * 0.08)
            }
        }
        .frame(width: width, height: width * 1.5)
    }

    /// A strip of film perforations above and below the frame.
    private var sprockets: some View {
        HStack(spacing: width * 0.035) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: width * 0.008).fill(.white.opacity(0.22))
                    .frame(width: width * 0.045, height: width * 0.03)
            }
        }
        .frame(width: width, height: width * 0.06)
        .clipped()
    }
}

// MARK: - Showcase

/// The card in a lit glass case: drag to turn it, click to flip it over. The back says when it was found.
struct CardShowcase: View {
    @ObservedObject private var visibility = PopoverVisibility.shared
    let card: CardDef
    let owned: OwnedCard
    let width: CGFloat
    /// The exact variant to show (the card you clicked); defaults to the one shown in the Filmedex.
    var art: Art? = nil
    var finish: Finish? = nil
    @State private var angle: Double = 0
    @State private var drag: CGSize = .zero

    private var turned: Double { angle + drag.width * 0.9 }
    private var showsBack: Bool {
        let a = (turned.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return a > 90 && a < 270
    }

    var body: some View {
        ZStack {
            // The case: a dark niche with a spotlight and a glass sheen.
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [hex(0x1E1E24), hex(0x0C0C0F)], startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.05),
                           startRadius: 0, endRadius: width * 1.1)
            Ellipse().fill(.black.opacity(0.5)).frame(width: width * 0.8, height: width * 0.1).blur(radius: 6)
                .offset(y: width * 0.82)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: isSnapshotRender || drag != .zero || !visibility.visible)) { t in
                let sway = drag == .zero ? sin(t.date.timeIntervalSinceReferenceDate * 0.8) * 6 : 0
                ZStack {
                    CardFace(card: card, art: art ?? owned.shownArt, finish: finish ?? owned.shownFinish, width: width)
                        .opacity(showsBack ? 0 : 1)
                    CardReverse(card: card, owned: owned, width: width, art: art, finish: finish)
                        .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                        .opacity(showsBack ? 1 : 0)
                }
                .environment(\.holoTilt, CGPoint(x: min(max(sin((turned + sway) * .pi / 180) * 2.5, -1), 1),
                                                  y: max(min(-drag.height * 0.25, 18), -18) / 18))
                .rotation3DEffect(.degrees(turned + sway), axis: (0, 1, 0), perspective: 0.45)
                .rotation3DEffect(.degrees(max(min(-drag.height * 0.25, 18), -18)), axis: (1, 0, 0), perspective: 0.45)
                .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
            }
            LinearGradient(colors: [.white.opacity(0.07), .clear, .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .frame(width: width * 1.3, height: width * 1.85)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                let total = angle + v.translation.width * 0.9
                withAnimation(.spring(duration: 0.6, bounce: 0.25)) {
                    angle = (total / 180).rounded() * 180
                    drag = .zero
                }
            })
        .onTapGesture { withAnimation(.spring(duration: 0.7, bounce: 0.2)) { angle += 180 } }
        .help("Arrastra para girarlo; haz clic para darle la vuelta")
    }
}

/// The back of a card in the showcase: when it was found and what you have of it.
struct CardReverse: View {
    let card: CardDef
    let owned: OwnedCard
    let width: CGFloat
    var art: Art? = nil
    var finish: Finish? = nil

    private var found: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d 'de' MMMM 'de' yyyy"
        return f.string(from: owned.first)
    }

    var body: some View {
        let r = width * 0.07
        ZStack {
            RoundedRectangle(cornerRadius: r).fill(LinearGradient(colors: [hex(0x1B1B1F), hex(0x0B0B0C)], startPoint: .top, endPoint: .bottom))
            FilmoF().fill(.white.opacity(0.05)).frame(width: width * 0.7, height: width * 0.74)
            VStack(alignment: .leading, spacing: width * 0.035) {
                Text(card.title.uppercased()).font(.system(size: max(width * 0.075, 6), weight: .heavy)).lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(card.rarity.name.uppercased()).font(.system(size: max(width * 0.05, 4.5), weight: .heavy)).tracking(1)
                    .foregroundStyle(card.rarity.gradient)
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                row("Conseguida", found)
                row("Copias", "\(owned.count)")
                row("Arte", (art ?? owned.shownArt).name)
                row("Acabado", (finish ?? owned.shownFinish).name)
                Spacer(minLength: 0)
                if let q = card.quote {
                    Text("«\(q)»").font(.system(size: max(width * 0.06, 5), design: .serif)).italic().opacity(0.8)
                        .lineLimit(4).minimumScaleFactor(0.7)
                }
                HStack(spacing: width * 0.03) {
                    FilmoF().fill(.white).frame(width: width * 0.07, height: width * 0.075)
                    Text("FILMEDEX").font(.system(size: max(width * 0.05, 4.5), weight: .heavy)).tracking(1)
                }
                .opacity(0.5)
            }
            .foregroundStyle(.white)
            .padding(width * 0.09)
            RoundedRectangle(cornerRadius: r).strokeBorder(card.rarity.gradient, lineWidth: max(width * 0.03, 1.5))
        }
        .frame(width: width, height: width * 1.5)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased()).font(.system(size: max(width * 0.042, 4), weight: .bold)).tracking(0.5).opacity(0.5)
            Text(value).font(.system(size: max(width * 0.06, 5), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Odds

/// The (i) button: every pack's odds, how coins, Tokens and achievements work, and credits.
private struct OddsInfoButton: View {
    @ObservedObject var model: Album
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cómo funcionan los cromos")
        .help("Cómo funcionan los cromos")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView { OddsSheet(model: model).padding(16) }
                .frame(width: 360)
                .frame(maxHeight: 480)
        }
    }
}

struct OddsSheet: View {
    @ObservedObject var model: Album

    private let nameW: CGFloat = 104, priceW: CGFloat = 38, pctW: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probabilidades por cromo").font(.system(size: 13, weight: .bold))
            table
            Text("Tiempo aproximado ahorrando con una jornada normal (~\(Int(model.typicalDay.rounded())) filmo-coins al día).")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            line("Gratis", "Un sobre al día por jornada de 7 h y un Seed cada 5.")
            line("Acabados", "Holográfica 5 %, dorada 0,3 %.")
            line("Variantes", "1 de cada 5 cromos nuevos con variantes sale ya en arte alternativo o escena mítica; una repetida la desbloquea la mitad de las veces.")
            line("Repetidas", "Si no traen variante, dan Tokens para fabricar el cromo que te falte: más cuanto más rara. Una holográfica repetida vale ×4 y una dorada ×25, siempre.")
            line("Pirámide", "Las rarezas altas llegan cuando tienes la base: nunca vas más avanzado en una rareza que en la de debajo.")
            VStack(alignment: .leading, spacing: 6) {
                line("Garantía de legendaria", "Si llevas mala racha, la siguiente acaba siendo segura.")
                let g = min(model.state.legendDebt / Album.hardPity, 1)
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule().fill(Rarity.legendary.gradient).frame(width: max(geo.size.width * g, g > 0 ? 6 : 0))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(g * 100)) %").font(.system(size: 10, weight: .semibold).monospacedDigit()).frame(width: 34, alignment: .trailing)
                }
            }
            line("Logros", "Suben lo que ganas y te regalan sobres.")
            Divider()
            Text("Pósters: TMDB. Este producto usa la API de TMDB pero no está respaldado ni certificado por TMDB. Fotos: Wikimedia Commons.")
                .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var table: some View {
        VStack(spacing: 6) {
            legend
            HStack(spacing: 0) {
                Text("Sobre").frame(width: nameW, alignment: .leading)
                Text("Precio").frame(width: priceW, alignment: .trailing)
                ForEach(Rarity.allCases, id: \.self) { r in
                    Circle().fill(r.gradient).frame(width: 8, height: 8).frame(width: pctW, alignment: .trailing).help(r.name)
                }
            }
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(packKinds) { p in
                let total = p.odds.reduce(0, +)
                Divider().opacity(0.5)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text("\(p.count) cromos · \(model.workTime(for: p.price))").font(.system(size: 9)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: nameW, alignment: .leading)
                    Text("\(p.price)").frame(width: priceW, alignment: .trailing)
                    ForEach(0..<4, id: \.self) { i in
                        Text(percent(p.odds[i] / total * 100)).frame(width: pctW, alignment: .trailing)
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Rarity.allCases, id: \.self) { r in
                HStack(spacing: 4) { Circle().fill(r.gradient).frame(width: 7, height: 7); Text(r.name) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private func line(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Decodes a value or nothing, so one bad entry doesn't fail the whole collection.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Whether the popover is on screen; animations pause while it's hidden.
@MainActor
final class PopoverVisibility: ObservableObject {
    static let shared = PopoverVisibility()
    @Published var visible = true
}
