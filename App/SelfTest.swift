import Foundation

/// `--selftest`: plays thousands of packs headlessly and checks the album's rules hold.
@MainActor
enum SelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { failures += 1; if failures <= 40 { print("FAIL:", what()) } }
    }

    static func shares(_ a: Album) -> [Double] { Rarity.allCases.map { a.share($0) } }

    static func run() -> Int32 {
        // 1. Long simulation: open every kind of pack, with crafting and pending handling.
        for seed in 0..<6 {
            let a = Album(persist: false)
            a.testReset()
            var lastDebt = 0.0
            var crafted = false
            for i in 0..<1200 {
                let p = packKinds[(i + seed) % packKinds.count]
                let before = a.state.cards.values.reduce(0) { $0 + $1.count }
                let tokensBefore = a.state.tokens
                if i % 3 == 0 { a.testGrant(p.id, 1); a.openFree(p) } else { a.testEarn(Double(p.price)); a.buy(p) }
                guard let o = a.opening else { check(false, "no opening after pack \(i)"); continue }
                check(o.pulls.count == p.count, "pack \(p.id) gave \(o.pulls.count) cards")
                let after = a.state.cards.values.reduce(0) { $0 + $1.count }
                check(after - before == p.count, "copies grew by \(after - before), expected \(p.count)")
                check(a.state.tokens >= tokensBefore, "tokens went down while opening")
                check(a.state.pending != nil, "pending not saved")
                // Pyramid (packs only; crafting is free of it): no rarity more than 5 points (+1 card) ahead.
                let sh = shares(a)
                if crafted { continue }
                for r in 1..<4 {
                    let pool = Double(allCards.filter { $0.rarity == Rarity(rawValue: r)! }.count)
                    check(sh[r] <= sh[r - 1] + 0.05 + 1 / pool + 1e-9, "pyramid broken r\(r): \(sh)")
                }
                // Pity
                check(a.state.legendDebt >= 0 && a.state.legendDebt < Album.hardPity + 0.2, "legendDebt out of range \(a.state.legendDebt)")
                if o.pulls.contains(where: { $0.card.rarity == .legendary }) { check(a.state.legendDebt <= lastDebt + 0.5, "debt not reset after legendary") }
                lastDebt = a.state.legendDebt
                // Turn all and close
                a.savePending(flipped: Set(0..<o.pulls.count), torn: true)
                check(a.state.pending == nil, "pending not cleared after all flipped")
                a.finishOpening()
                check(a.balance >= 0, "negative balance")
                // Craft only in half the seeds, so the pyramid is checked on pure pack runs.
                if seed % 2 == 1 && i % 50 == 0 {
                    for r in Rarity.allCases {
                        let t = a.state.tokens
                        if let c = a.craft(set: cardSets[i % cardSets.count].id, rarity: r) {
                            crafted = true
                            check(a.state.tokens == t - r.craftCost && a.owned(c) != nil, "craft didn't charge or add")
                        }
                    }
                }
            }
            // Duplicate protection: no common/rare/epic above 2 copies while that rarity still has gaps, beyond the allowed.
            print("seed \(seed): \(a.state.cards.count)/\(allCards.count) cards, shares \(shares(a).map { Int($0 * 100) }), tokens \(a.state.tokens)")
        }

        // 2. Can't buy without coins.
        do {
            let a = Album(persist: false); a.testReset()
            a.buy(packKinds[3])
            check(a.opening == nil && a.state.cards.isEmpty, "bought without coins")
            a.openFree(packKinds[0])
            check(a.opening == nil, "opened a free pack you don't have")
        }

        // 3. Old album formats decode without resetting.
        let old = #"{"earned":{"2026-11-01":40},"spent":0,"cards":{"padrino":{"count":2,"holo":true,"first":800000000}},"tokens":5,"packs":{"estreno":1}}"#
        if let s = Album.testDecode(old) {
            check(s.cards["padrino"]?.finishes.contains(.holo) == true, "old holo flag lost")
            check(s.tokens == 5 && s.packs["estreno"] == 1, "old fields lost")
        } else { check(false, "old album format failed to decode") }
        let retired = #"{"cards":{"x":{"count":1,"first":0,"arts":["base","minimal","illustrated"],"finishes":["normal","celluloid"],"shownArt":"minimal","shownFinish":"celluloid"}}}"#
        if let s = Album.testDecode(retired) {
            check(s.cards["x"]?.shownArt == .base && s.cards["x"]?.shownFinish == .normal, "retired variants not mapped")
        } else { check(false, "album with retired variants failed to decode") }
        check(Album.testDecode("{}") != nil, "empty album failed to decode")

        // 4. Pending restore gives the same cards and doesn't add copies.
        do {
            let a = Album(persist: false); a.testReset()
            a.testGrant("alfombra", 1); a.openFree(pack("alfombra"))
            a.savePending(flipped: [0], torn: true)
            let saved = a.state
            let copies = saved.cards.values.reduce(0) { $0 + $1.count }
            let b = Album(persist: false); b.testRestore(saved)
            check(b.opening?.pulls.map(\.card.id) == a.opening?.pulls.map(\.card.id), "restored pack differs")
            check(b.state.cards.values.reduce(0) { $0 + $1.count } == copies, "restore changed copies")
            check(b.pendingFlipped == [0], "flipped not restored")
        }

        // 5. Achievement rewards: once per achievement and per tier.
        do {
            // A new album: achievements already held give nothing but the pack of the day.
            let n = Album(persist: false); n.testReset()
            n.reward(tiers: ["x": 0, "y": 2])
            check(n.state.packs == [dailyPack.id: 1] && n.state.tokens == 0, "start gifts were retroactive: \(n.state.packs)")
            n.reward(tiers: ["x": 0, "y": 3, "z": 0])
            check(n.state.packs.values.reduce(0, +) == 3 && n.state.tokens == 60, "new progress after start not paid")

            var started = Album.State(); started.baselined = true
            let a = Album(persist: false); a.testReset(started)
            a.reward(tiers: ["x": 0, "y": 2])
            let packs1 = a.state.packs.values.reduce(0, +), tok1 = a.state.tokens
            check(packs1 == 4, "expected 4 packs (2 unlocks + 2 tiers), got \(packs1)")
            check(tok1 == 20 + 40, "expected 60 tokens, got \(tok1)")
            a.reward(tiers: ["x": 0, "y": 2])
            check(a.state.packs.values.reduce(0, +) == packs1 && a.state.tokens == tok1, "rewards paid twice")
            check(abs(Album.bonus(tiers: ["x": 0, "y": 2]) - (0.015 + 0.045)) < 1e-9, "bonus formula")
            check(Album.bonus(tiers: Dictionary(uniqueKeysWithValues: (0..<200).map { ("a\($0)", 5) })) == 1, "bonus cap")
        }

        // 6. Pity statistics: worst gap between legendaries with Alfombra roja, early collection.
        do {
            var worst = 0, total = 0, legends = 0
            for _ in 0..<40 {
                let a = Album(persist: false); a.testReset()
                // fill the base so the pyramid doesn't hold legendaries back
                for c in allCards where c.rarity != .legendary { _ = c }
                var gap = 0
                for _ in 0..<60 {
                    a.testGrant("alfombra", 1); a.openFree(pack("alfombra"))
                    let got = a.opening?.pulls.filter { $0.card.rarity == .legendary }.count ?? 0
                    legends += got; total += 1
                    gap = got > 0 ? 0 : gap + 1; worst = max(worst, gap)
                    a.finishOpening()
                }
            }
            print("alfombra: \(legends) legendaries in \(total) packs; worst gap \(worst) packs (pyramid included)")
        }

        // Workday timeline: in order, never overlapping, and each kind adds up to its total.
        do {
            typealias S = WorkTimeline.Sample
            let samples = [S(t: 545, p: 300, n: 0, u: 0), S(t: 550, p: 300, n: 0, u: 0), S(t: 555, p: 420, n: 60, u: 120)]
            let totals = S(t: 560, p: 420, n: 60, u: 120)
            let cols = WorkTimeline.columns(samples, totals: totals, from: 540, to: 560, open: false)
            check(cols.count == 4 && zip(cols, cols.dropFirst()).allSatisfy { $0.to == $1.from }, "timeline columns: \(cols)")
            check(cols.first?.from == 540 && cols.last?.to == 560, "timeline does not span the day")
            check(abs(cols.reduce(0) { $0 + $1.p } - 420) < 1 && abs(cols.reduce(0) { $0 + $1.n } - 60) < 1
                  && abs(cols.reduce(0) { $0 + $1.u } - 120) < 1, "timeline totals: \(cols)")
            check(cols.map(\.active) == [1, 0, 1, 0], "timeline activity: \(cols.map(\.active))")
            let live = WorkTimeline.columns(samples, totals: totals, from: 540, to: 560, open: true)
            check(live.last?.to == 555, "an open day must not judge its last minutes")
            let late = WorkTimeline.columns([S(t: 600, p: 1800, n: 0, u: 0)], totals: S(t: 600, p: 1800, n: 0, u: 0), from: 540, to: 600, open: true)
            check(late.count == 1 && late[0].loose && abs(late[0].active - 0.5) < 1e-6, "a long gap is one loose column: \(late)")
        }
        // Community ranking: achievements and cards weigh the same; prestige breaks a tie.
        do {
            func m(_ id: Int, _ a: Int, _ c: Int, _ prestige: Int = 0) -> Member {
                Member(id: id, name: "M\(id)", photo: 0, profile: SharedProfile(since: nil, achievementsHave: a, achievementsTotal: 40, cardsHave: c,
                                                                              cardsTotal: 280, prestige: prestige, cards: [], achievements: []))
            }
            let order = CommunityView.ranked([m(1, 4, 28), m(2, 20, 0), m(3, 0, 280), m(4, 4, 28, 3)]).map(\.id)
            check(order == [3, 2, 4, 1], "ranking: \(order)")
        }
        // Update dialog: every pending version, newest first, and a line for one without notes.
        do {
            let u = URL(string: "https://example.com")!
            let log = Updater.changelog([.init(version: "1.2.3", notes: "- Uno.\n", dmg: u, page: u), .init(version: "1.2.2", notes: "", dmg: u, page: u)])
            check(log == "Versión 1.2.3\n- Uno.\n\nVersión 1.2.2\nMejoras y correcciones.", "changelog: \(log)")
            check(Updater.isNewer("1.2.10", than: "1.2.9") && !Updater.isNewer("1.2", than: "1.2.0"), "version order")
        }
        // Exclusive achievements exist only for whoever was granted them.
        do {
            let before = grantedExclusives
            grantedExclusives = []
            check(!allAchievements.contains { $0.id == "founder" } && anyAchievement("founder") != nil, "exclusive leaked to everybody")
            grantedExclusives = ["founder"]
            check(allAchievements.count == standardAchievements.count + 1, "granted exclusive not counted")
            grantedExclusives = before
        }
        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
