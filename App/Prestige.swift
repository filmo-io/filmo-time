import SwiftUI

// MARK: - Achievement prestige
//
// Only achievements about hours or days have tiers. Unlocked, they are Bronze;
// prestiging one sets the next tier as a goal, which asks for a bit more (half
// an hour, an hour, two more days…) on a later day.

enum PrestigeTier: Int, CaseIterable {
    case bronze, silver, gold, platinum, diamond, legend

    var name: String {
        switch self {
        case .bronze: "Bronce"
        case .silver: "Plata"
        case .gold: "Oro"
        case .platinum: "Platino"
        case .diamond: "Diamante"
        case .legend: "Leyenda"
        }
    }

    var colors: [Color] {
        switch self {
        case .bronze: [hex(0xD08A4E), hex(0x8C5320)]
        case .silver: [hex(0xE3E6EA), hex(0x8F969E)]
        case .gold: [hex(0xF7D774), hex(0xC2900F)]
        case .platinum: [hex(0xD9F1F4), hex(0x7FB3BC)]
        case .diamond: [hex(0x9DE3FF), hex(0x3B82F6)]
        case .legend: [hex(0xFF9F43), hex(0xB05CFF)]
        }
    }

    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var next: PrestigeTier? { PrestigeTier(rawValue: rawValue + 1) }
}

/// Productivity achievements with a bar that rises every tier.
struct PrestigeRule {
    /// What each tier adds, for the row.
    let step: String
    let check: (AchievementContext, Int) -> Bool
    let progress: (AchievementContext, Int) -> (fraction: Double, text: String)
}

private let hour: Double = 3600
private let fullDay: Double = 7 * hour

/// Tier 0 is exactly the achievement's own rule.
let prestigeRules: [String: PrestigeRule] = [
    "sin-casa": PrestigeRule(step: "+1 h por nivel", check: { c, n in
        c.worked >= (12 + 1.0 * Double(n)) * hour
    }, progress: { c, n in
        let need = (12 + 1.0 * Double(n)) * hour
        return (c.worked / need, "\(Fmt.duration(c.worked)) de \(Fmt.duration(need)) hoy")
    }),
    "francotirador": PrestigeRule(step: "+1 h por nivel", check: { c, n in
        c.worked >= fullDay + 1.0 * Double(n) * hour && c.today.productivity >= 98
    }, progress: { c, n in
        let need = fullDay + 1.0 * Double(n) * hour
        return (min(c.worked / need, c.today.productivity / 98),
                "\(Fmt.duration(c.worked)) de \(Fmt.duration(need)) · \(Fmt.percent(c.today.productivity)) de 98 %")
    }),
    "santo": PrestigeRule(step: "+1 h por nivel", check: { c, n in
        c.worked >= (9 + 1.0 * Double(n)) * hour && c.today.unproductiveTime < 60
    }, progress: { c, n in
        let need = (9 + 1.0 * Double(n)) * hour
        return c.today.unproductiveTime >= 60
            ? (0, "Hoy ya llevas \(Fmt.duration(c.today.unproductiveTime)) improductivos")
            : (c.worked / need, "\(Fmt.duration(c.worked)) de \(Fmt.duration(need)) sin nada improductivo")
    }),
    "viernes-cohete": PrestigeRule(step: "+1 h por nivel", check: { c, n in
        c.weekday == 6 && c.worked >= (10 + 1.0 * Double(n)) * hour && c.today.productivity >= 90
    }, progress: { c, n in
        let need = (10 + 1.0 * Double(n)) * hour
        return c.weekday != 6
            ? (0, "Solo cuenta los viernes")
            : (min(c.worked / need, c.today.productivity / 90),
               "\(Fmt.duration(c.worked)) de \(Fmt.duration(need)) · \(Fmt.percent(c.today.productivity)) de 90 %")
    }),
    "racha": PrestigeRule(step: "+4 días por nivel", check: { c, n in
        currentStreak(c) >= 10 + 4 * n
    }, progress: { c, n in
        let s = currentStreak(c), need = 10 + 4 * n
        return (Double(s) / Double(need), "\(s) de \(need) días seguidos al 85 %")
    }),
    "maraton": PrestigeRule(step: "+2 h por nivel", check: { c, n in
        c.week.reduce(0) { $0 + $1.desktime } >= (42.195 + 2 * Double(n)) * hour
    }, progress: { c, n in
        let w = c.week.reduce(0) { $0 + $1.desktime }, need = (42.195 + 2 * Double(n)) * hour
        return (w / need, "\(Fmt.duration(w)) de \(Fmt.duration(need)) esta semana")
    }),
    "que-dia-es-hoy": PrestigeRule(step: "+1 h al día por nivel", check: { c, n in
        c.week.count == 7 && c.week.allSatisfy { $0.desktime >= fullDay + 1.0 * Double(n) * hour }
    }, progress: { c, n in
        let need = fullDay + 1.0 * Double(n) * hour
        let ok = c.week.filter { $0.desktime >= need }.count
        return (Double(ok) / 7, "\(ok) de 7 días con \(Fmt.duration(need)) esta semana")
    }),
    "finde": PrestigeRule(step: "+2 h por nivel", check: { c, n in
        (c.weekday == 1 || c.weekday == 7) && c.worked > (4 + 2 * Double(n)) * hour
    }, progress: { c, n in
        let need = (4 + 2 * Double(n)) * hour
        return c.weekday != 1 && c.weekday != 7
            ? (0, "Solo cuenta en sábado o domingo")
            : (c.worked / need, "\(Fmt.duration(c.worked)) de \(Fmt.duration(need)) hoy")
    }),
    "entrada-triunfal": PrestigeRule(step: "+1 h de retraso por nivel", check: { c, n in
        guard !c.isFirstDay, c.arrivedToday, let a = minutes(c.today.arrived), let s = minutes(c.today.workStarts) else { return false }
        return a - s >= 180 + 60 * Double(n)
    }, progress: { c, n in
        let need = 180 + 60 * Double(n)
        guard c.arrivedToday, let a = minutes(c.today.arrived), let s = minutes(c.today.workStarts) else { return (0, "Hoy aún no has llegado") }
        return (max(a - s, 0) / need, "\(Fmt.duration(max(a - s, 0) * 60)) tarde de \(Fmt.duration(need * 60))")
    }),
    "infiel": PrestigeRule(step: "+30 min en cada uno por nivel", check: { c, n in
        let need = (30 + 30 * Double(n)) * 60
        return c.today.seconds(matching: AppKeys.claude) >= need && c.today.seconds(matching: AppKeys.chatGPT) >= need
    }, progress: { c, n in
        let need = (30 + 30 * Double(n)) * 60
        let a = c.today.seconds(matching: AppKeys.claude), b = c.today.seconds(matching: AppKeys.chatGPT)
        return (min(a, b) / need, "Claude \(Fmt.duration(a)) · ChatGPT \(Fmt.duration(b)) de \(Fmt.duration(need))")
    }),
    "inbox": appRule(AppKeys.mail, base: 3 * hour, step: hour, label: "en el correo"),
    "reunionitis": appRule(AppKeys.meetings, base: 4 * hour, step: hour, label: "en videollamadas"),
    "chatero": appRule(AppKeys.chat, base: 3 * hour, step: hour, label: "chateando"),
    "hacker": appRule(AppKeys.code, base: 3 * hour, step: hour, label: "en el terminal o el editor"),
    "ofimatico": appRule(AppKeys.office, base: hour, step: hour, label: "en documentos"),
    "capitulo": appRule(AppKeys.video, base: hour, step: 30 * 60, label: "en vídeo"),
    "dj": appRule(AppKeys.music, base: 30 * 60, step: 30 * 60, label: "con música"),
    "prime": appRule(AppKeys.amazon, base: hour, step: 30 * 60, label: "en Amazon"),
    "plagiador": appRule(AppKeys.competitors, base: 10 * 60, step: 10 * 60, label: "en la competencia"),
    "desktimeception": appRule(AppKeys.deskTime, base: 30 * 60, step: 20 * 60, label: "en el panel web"),
]

/// Time spent in some apps in a day, above a bar that rises every tier.
private func appRule(_ keys: [String], base: Double, step: Double, label: String) -> PrestigeRule {
    PrestigeRule(step: "+\(Fmt.duration(step).replacingOccurrences(of: "m", with: " min").replacingOccurrences(of: "h", with: " h")) por nivel",
                 check: { c, n in c.today.seconds(matching: keys) > base + step * Double(n) },
                 progress: { c, n in
                     let t = c.today.seconds(matching: keys), need = base + step * Double(n)
                     return (t / need, "\(Fmt.duration(t)) de \(Fmt.duration(need)) \(label) hoy")
                 })
}

/// Ring and label of an achievement's tier.
struct TierBadge: View {
    let tier: PrestigeTier
    var body: some View {
        Text(tier.name)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tier == .silver || tier == .platinum ? Color.black.opacity(0.7) : .white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(tier.gradient))
    }
}
