import AppKit
import SwiftUI
import UserNotifications

// MARK: - Definitions

/// What an achievement can look at when it is evaluated (on every refresh of today).
struct AchievementContext {
    let today: DayData
    /// Today's data from the previous refresh, to notice what changed since then.
    let previous: DayData?
    let now: Date
    let week: [WeekDay]
    /// Worked hours and productivity of past days, for streaks.
    let history: [String: DaySummary]
    let popoverOpensToday: Int
    /// Cigarette-sized pauses today, as counted on this Mac.
    var pausesToday = 0
    /// The day Filmo Time first ran: DeskTime may only have tracked part of it.
    let isFirstDay: Bool

    var calendar: Calendar { Calendar(identifier: .gregorian) }
    var hour: Int { calendar.component(.hour, from: now) }
    var minuteOfDay: Int { hour * 60 + calendar.component(.minute, from: now) }
    /// 1 = Sunday ... 7 = Saturday.
    var weekday: Int { calendar.component(.weekday, from: now) }
    var worked: Double { today.worked }
    var arrivedToday: Bool { today.arrivedDay == Fmt.ymd(now) }

    /// Share of the worked time spent in apps matching `keys`.
    func share(_ keys: [String]) -> Double {
        worked > 0 ? today.seconds(matching: keys) / worked : 0
    }
}

struct DaySummary: Codable {
    var worked: Double
    var productivity: Double
}

struct Achievement: Identifiable {
    let id: String
    let emoji: String
    let title: String
    let detail: String
    let check: (AchievementContext) -> Bool
}

private let hour: Double = 3600
/// Percentage achievements only count on a full day.
private let fullDay: Double = 7 * hour

enum AppKeys {
    static let claude = ["claude"]
    static let chatGPT = ["chatgpt", "chat.openai.com", "openai"]
    /// Claude and the other AI assistants and coding harnesses.
    static let ai = claude + chatGPT + ["claude.ai", "chatgpt.com", "opencode", "codex", "cursor", "windsurf",
                                        "copilot", "gemini", "perplexity", "deepseek", "grok", "mistral",
                                        "aider", "cline", "goose", "ollama", "lm studio", "lmstudio"]
    static let social = ["twitter", "x.com", "instagram", "facebook", "linkedin", "tiktok", "reddit",
                         "threads.net", "bsky.app", "mastodon"]
    static let mail = ["mail", "outlook", "spark", "superhuman"]
    static let meetings = ["zoom", "meet.google.com", "teams", "webex", "facetime", "around"]
    static let chat = ["chat.google.com", "whatsapp", "telegram", "discord", "signal"]
    static let code = ["terminal", "iterm", "xcode", "code", "cursor", "warp", "ghostty", "intellij",
                       "pycharm", "webstorm", "zed", "nova", "sublime"]
    static let office = ["docs.google.com", "sheets.google.com", "slides.google.com", "excel", "powerpoint",
                         "microsoft word", "numbers", "keynote"]
    static let video = ["youtube", "netflix", "twitch", "primevideo", "disneyplus", "hbomax", "max.com"]
    static let music = ["spotify", "music"]
    static let amazon = ["amazon.es", "amazon.com", "amazon.co.uk"]
    static let deskTime = ["desktime.com"]
    /// DeskTime reports Google Slides as docs.google.com, the same as Docs, so it cannot be told apart.
    static let presentations = ["powerpoint", "keynote", "slides.google.com", "pitch.com", "canva.com", "prezi.com"]
    /// From filmo.io/resources/competitors (Business Central left out: it is all of microsoft.com).
    static let competitors = ["rentman.io", "rentmanapp.com", "current-rms.com", "hirehop.com", "myhirehop.com",
                              "flexrentalsolutions.com", "booqable.com", "goodshuffle.com", "rentaltracker.com",
                              "lasso.io", "farmerswife.com", "odoo.com"]
}

let allAchievements: [Achievement] = [
    // Yours
    Achievement(id: "ai-addict", emoji: "🤖", title: "AI addict",
                detail: "Más del 80 % de una jornada completa en Claude (o similar). ¿Quién trabaja para quién?") {
        $0.worked >= fullDay && $0.share(AppKeys.ai) > 0.8
    },
    Achievement(id: "aguafiestas", emoji: "🍺", title: "Aguafiestas…",
                detail: "Usaste Claude (o similar) un primer viernes de mes después de las 19:00. Las cervezas no se beben solas.") { c in
        let firstFriday = c.weekday == 6 && c.calendar.component(.day, from: c.now) <= 7
        guard firstFriday, c.hour >= 19, let prev = c.previous else { return false }
        return c.today.seconds(matching: AppKeys.ai) > prev.seconds(matching: AppKeys.ai)
    },
    Achievement(id: "community-manager", emoji: "📱", title: "Community manager",
                detail: "Más de la mitad de una jornada completa en redes sociales. Seguro que era networking.") {
        $0.worked >= fullDay && $0.share(AppKeys.social) > 0.5
    },

    // Schedule
    Achievement(id: "madrugador", emoji: "🐓", title: "Madrugador",
                detail: "Empezaste antes de las 7:00. ¿Has dormido?") {
        !$0.isFirstDay && $0.arrivedToday && (minutes($0.today.arrived) ?? 9999) < 7 * 60
    },
    Achievement(id: "buho", emoji: "🦉", title: "Búho nocturno",
                detail: "En línea pasadas las 23:00. El código compila mejor de noche, dicen.") {
        $0.today.isOnline && $0.hour >= 23
    },
    Achievement(id: "entrada-triunfal", emoji: "🐌", title: "Entrada triunfal",
                detail: "Llegaste tres horas tarde o más. Lo importante es llegar.") {
        guard !$0.isFirstDay, $0.arrivedToday, let a = minutes($0.today.arrived), let s = minutes($0.today.workStarts) else { return false }
        return a - s >= 180
    },
    Achievement(id: "suizo", emoji: "⌚", title: "Puntualidad suiza",
                detail: "Empezaste a tu hora exacta, al minuto. Inquietante.") {
        guard !$0.isFirstDay, $0.arrivedToday, let a = minutes($0.today.arrived), let s = minutes($0.today.workStarts) else { return false }
        return a == s
    },
    Achievement(id: "quien-fuma", emoji: "🚬", title: "¿Quién fuma?",
                detail: "10 pausas o más de entre 10 y 20 minutos en un día. ¿Salimos un momento?") {
        $0.pausesToday >= 10
    },
    Achievement(id: "sin-casa", emoji: "🧟", title: "¿Tienes casa?",
                detail: "12 horas trabajadas en un día. Tu sofá te echa de menos.") {
        $0.worked >= 12 * hour
    },
    Achievement(id: "finde", emoji: "🏝️", title: "El finde es para débiles",
                detail: "Más de 4 horas trabajando en sábado o domingo.") {
        ($0.weekday == 1 || $0.weekday == 7) && $0.worked > 4 * hour
    },

    // Performance
    Achievement(id: "que-dia-es-hoy", emoji: "📅", title: "¿Qué día es hoy?",
                detail: "7 horas o más cada día de la semana, de lunes a domingo. Los días ya no tienen nombre.") {
        $0.week.count == 7 && $0.week.allSatisfy { $0.desktime >= fullDay }
    },
    Achievement(id: "francotirador", emoji: "🎯", title: "Francotirador",
                detail: "98 % de productividad en una jornada completa. Ni un disparo fallado.") {
        $0.worked >= fullDay && $0.today.productivity >= 98
    },
    Achievement(id: "eficacia-100", emoji: "💯", title: "Eficacia de manual",
                detail: "Llegaste al 100 % de eficacia. Filmo te mira con respeto.") {
        $0.today.efficiency >= 100
    },
    Achievement(id: "santo", emoji: "😇", title: "Santo varón",
                detail: "9 horas trabajadas y ni un minuto improductivo.") {
        $0.worked >= 9 * hour && $0.today.unproductiveTime < 60
    },
    Achievement(id: "lunes", emoji: "🦥", title: "Lunes, ¿eres tú?",
                detail: "Menos del 40 % de productividad en un lunes completo. Le pasa a cualquiera.") {
        $0.weekday == 2 && $0.worked >= fullDay && $0.today.productivity < 40
    },
    Achievement(id: "viernes-cohete", emoji: "🚀", title: "Viernes cohete",
                detail: "Un viernes de 10 horas al 90 % de productividad. ¿Y el afterwork?") {
        $0.weekday == 6 && $0.worked >= 10 * hour && $0.today.productivity >= 90
    },
    Achievement(id: "racha", emoji: "🔥", title: "En racha",
                detail: "10 jornadas completas seguidas por encima del 85 % de productividad.") {
        currentStreak($0) >= 10
    },
    Achievement(id: "maraton", emoji: "🏃", title: "Maratón",
                detail: "42,195 horas trabajadas en una semana, como los kilómetros de un maratón. Hidrátate.") {
        $0.week.reduce(0) { $0 + $1.desktime } >= 42.195 * hour
    },

    // Apps
    Achievement(id: "infiel", emoji: "💔", title: "Infiel",
                detail: "Más de media hora en Claude y en ChatGPT el mismo día. Claude lo sabe.") {
        $0.today.seconds(matching: AppKeys.claude) >= 30 * 60 && $0.today.seconds(matching: AppKeys.chatGPT) >= 30 * 60
    },
    Achievement(id: "inbox", emoji: "📬", title: "Inbox infinito",
                detail: "Más de 3 horas en el correo. Inbox cero algún día.") {
        $0.today.seconds(matching: AppKeys.mail) > 3 * hour
    },
    Achievement(id: "reunionitis", emoji: "🗣️", title: "Reunionitis",
                detail: "Más de 4 horas en videollamadas. Esto podría haber sido un email.") {
        $0.today.seconds(matching: AppKeys.meetings) > 4 * hour
    },
    Achievement(id: "chatero", emoji: "💬", title: "Chatero",
                detail: "Más de 3 horas en Google Chat, WhatsApp o Telegram. ¿Trabajas o chateas?") {
        $0.today.seconds(matching: AppKeys.chat) > 3 * hour
    },
    Achievement(id: "hacker", emoji: "💻", title: "Hacker de Hollywood",
                detail: "Más de 5 horas en el terminal o el editor. Estoy dentro.") {
        $0.today.seconds(matching: AppKeys.code) > 5 * hour
    },
    Achievement(id: "ofimatico", emoji: "📊", title: "Ofimático legendario",
                detail: "Más de 4 horas en documentos, hojas de cálculo o presentaciones. Esa fórmula no se arregla sola.") {
        $0.today.seconds(matching: AppKeys.office) > 4 * hour
    },
    Achievement(id: "capitulo", emoji: "📺", title: "Solo un capítulo más",
                detail: "Más de 2 horas en YouTube, Netflix o Twitch. Era un tutorial, seguro.") {
        $0.today.seconds(matching: AppKeys.video) > 2 * hour
    },
    Achievement(id: "dj", emoji: "🎧", title: "DJ de oficina",
                detail: "Más de 5 horas con Spotify o Música. Pon algo bueno.") {
        $0.today.seconds(matching: AppKeys.music) > 5 * hour
    },
    Achievement(id: "prime", emoji: "🛒", title: "Prime time",
                detail: "Más de una hora en Amazon en horario laboral. Era material de oficina.") {
        $0.today.seconds(matching: AppKeys.amazon) > hour
    },
    Achievement(id: "turista", emoji: "🧭", title: "TDAH",
                detail: "60 apps o webs distintas en un día. Concentración nivel ardilla.") {
        $0.today.apps.count >= 60
    },
    Achievement(id: "zen", emoji: "🧘", title: "Modo zen",
                detail: "Una jornada completa usando 4 apps como mucho. Paz interior.") {
        $0.worked >= fullDay && !$0.today.apps.isEmpty && $0.today.apps.count <= 4
    },

    Achievement(id: "weekly", emoji: "📽️", title: "Weekly time",
                detail: "Abriste una presentación un lunes entre las 9 y las 11. Que empiece el show.") { c in
        guard c.weekday == 2, (9 * 60..<11 * 60).contains(c.minuteOfDay), let prev = c.previous else { return false }
        return c.today.seconds(matching: AppKeys.presentations) > prev.seconds(matching: AppKeys.presentations)
    },
    Achievement(id: "en-serio", emoji: "🥂", title: "¿En serio?",
                detail: "Abriste Claude (o similar) en Nochevieja, entre las 23:00 y la 1:00. Las uvas no se comen solas.") { c in
        guard isNewYearsEve(c.now, c.calendar), let prev = c.previous else { return false }
        return c.today.seconds(matching: AppKeys.ai) > prev.seconds(matching: AppKeys.ai)
    },
    Achievement(id: "truco-o-tokens", emoji: "🎃", title: "¿Truco o tokens?",
                detail: "Abriste Claude (o similar) el día de Halloween. Hoy se piden caramelos, no prompts.") { c in
        isHalloween(c.now, c.calendar) && c.today.seconds(matching: AppKeys.ai) > 0
    },
    Achievement(id: "santa-claude", emoji: "🎅", title: "Santa Claude",
                detail: "Abriste Claude (o similar) el día de Navidad. Ni los elfos trabajan hoy.") { c in
        isChristmas(c.now, c.calendar) && c.today.seconds(matching: AppKeys.ai) > 0
    },
    Achievement(id: "plagiador", emoji: "🕵️", title: "Plagiador",
                detail: "Más de 10 minutos en webs de la competencia en un día. Lo llamaremos benchmarking.") {
        $0.today.seconds(matching: AppKeys.competitors) > 10 * 60
    },

    // Meta
    Achievement(id: "hola", emoji: "👋", title: "Hola, mundo",
                detail: "Abriste Filmo Time por primera vez. Empieza la caza de logros.") { _ in true },
    Achievement(id: "miron", emoji: "👀", title: "¿Cuánto queda?",
                detail: "Abriste el resumen 50 veces en un día. El tiempo no pasa más rápido por mirarlo.") {
        $0.popoverOpensToday >= 50
    },
    Achievement(id: "desktimeception", emoji: "🪞", title: "Inception",
                detail: "Más de media hora en el panel web mirando… tu propio tiempo.") {
        $0.today.seconds(matching: AppKeys.deskTime) > 30 * 60
    },
]

/// Full working days in a row above 85 % productivity, ending today.
/// Weekends never break it; today only counts once it is a full day.
func currentStreak(_ c: AchievementContext) -> Int {
    var streak = 0
    var day = c.calendar.startOfDay(for: c.now)
    for _ in 0..<40 {
        let isToday = c.calendar.isDate(day, inSameDayAs: c.now)
        if let s = c.history[Fmt.ymd(day)], s.worked >= fullDay {
            guard s.productivity > 85 else { break }
            streak += 1
        } else if !isToday, ![1, 7].contains(c.calendar.component(.weekday, from: day)) {
            break
        }
        day = c.calendar.date(byAdding: .day, value: -1, to: day)!
    }
    return streak
}

// MARK: - Progress

/// Productivity achievements are visible before unlocking, with how close you are.
/// The fraction is the most limiting requirement, so it never overstates progress.
let progressTrackers: [String: (AchievementContext) -> (fraction: Double, text: String)] = [
    "sin-casa": { c in
        (c.worked / (12 * hour), "\(Fmt.duration(c.worked)) de 12h hoy")
    },
    "francotirador": { c in
        (min(c.worked / fullDay, c.today.productivity / 98),
         "\(Fmt.duration(c.worked)) de 7h · \(Fmt.percent(c.today.productivity)) de 98 %")
    },
    "eficacia-100": { c in
        (c.today.efficiency / 100, "\(Fmt.percent(c.today.efficiency)) de eficacia hoy")
    },
    "santo": { c in
        c.today.unproductiveTime >= 60
            ? (0, "Hoy ya llevas \(Fmt.duration(c.today.unproductiveTime)) improductivos")
            : (c.worked / (9 * hour), "\(Fmt.duration(c.worked)) de 9h sin nada improductivo")
    },
    "viernes-cohete": { c in
        c.weekday != 6
            ? (0, "Solo cuenta los viernes")
            : (min(c.worked / (10 * hour), c.today.productivity / 90),
               "\(Fmt.duration(c.worked)) de 10h · \(Fmt.percent(c.today.productivity)) de 90 %")
    },
    "racha": { c in
        let n = currentStreak(c)
        return (Double(n) / 10, "\(n) de 10 días seguidos al 85 %")
    },
    "maraton": { c in
        let w = c.week.reduce(0) { $0 + $1.desktime }
        return (w / (42.195 * hour), "\(Fmt.duration(w)) de 42h 12m esta semana")
    },
]

// MARK: - Live triggers

/// The Mac telling us you switched to an app, the moment it happens.
struct LiveEvent {
    let appName: String
    let now: Date

    var calendar: Calendar { Calendar(identifier: .gregorian) }
    var weekday: Int { calendar.component(.weekday, from: now) }
    var minuteOfDay: Int { calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) }
    var isFirstFridayOfMonth: Bool { weekday == 6 && calendar.component(.day, from: now) <= 7 }

    func appMatches(_ keys: [String]) -> Bool {
        let n = appName.lowercased()
        return keys.contains { !$0.contains(".") && n.contains($0) }
    }
}

/// Achievements about a moment rather than a daily total unlock as soon as macOS
/// reports the app switch, instead of waiting for DeskTime's next numbers.
let liveTriggers: [String: (LiveEvent) -> Bool] = [
    "weekly": { $0.weekday == 2 && (9 * 60..<11 * 60).contains($0.minuteOfDay) && $0.appMatches(AppKeys.presentations) },
    "aguafiestas": { $0.isFirstFridayOfMonth && $0.minuteOfDay >= 19 * 60 && $0.appMatches(AppKeys.ai) },
    "en-serio": { isNewYearsEve($0.now, $0.calendar) && $0.appMatches(AppKeys.ai) },
    "truco-o-tokens": { isHalloween($0.now, $0.calendar) && $0.appMatches(AppKeys.ai) },
    "santa-claude": { isChristmas($0.now, $0.calendar) && $0.appMatches(AppKeys.ai) },
    "buho": { $0.minuteOfDay >= 23 * 60 },
    "madrugador": { (5 * 60..<7 * 60).contains($0.minuteOfDay) },
]

/// Achievements a past day proves in its own way. Every other one is judged by its usual
/// check on that day's data. Weekly time, Aguafiestas and ¿En serio? never pass there: they
/// need the time of day an app was opened, and DeskTime only gives each day's totals.
let pastDayChecks: [String: (DayData) -> Bool] = [
    "buho": { (minutes($0.left) ?? 0) >= 23 * 60 },
    "hola": { _ in false },
]

func isHalloween(_ date: Date, _ calendar: Calendar) -> Bool {
    let d = calendar.dateComponents([.month, .day], from: date)
    return d.month == 10 && d.day == 31
}

func isChristmas(_ date: Date, _ calendar: Calendar) -> Bool {
    let d = calendar.dateComponents([.month, .day], from: date)
    return d.month == 12 && d.day == 25
}

/// 31 December from 23:00 to 1 January at 1:00.
func isNewYearsEve(_ date: Date, _ calendar: Calendar) -> Bool {
    let d = calendar.dateComponents([.month, .day, .hour], from: date)
    return (d.month == 12 && d.day == 31 && d.hour == 23) || (d.month == 1 && d.day == 1 && d.hour == 0)
}

extension DayData {
    /// Seconds in apps whose name matches any key. Keys with a dot are domains
    /// (exact or subdomain match); other keys match anywhere in the name.
    func seconds(matching keys: [String]) -> Double {
        apps.filter { app in
            let n = app.name.lowercased()
            return keys.contains { k in k.contains(".") ? (n == k || n.hasSuffix("." + k)) : n.contains(k) }
        }
        .reduce(0) { $0 + $1.seconds }
    }
}

// MARK: - Progress

@MainActor
final class Achievements: ObservableObject {
    struct State: Codable {
        var unlocked: [String: Date] = [:]
        var seen: Set<String> = []
        var history: [String: DaySummary] = [:]
        var opensDay = ""
        var opens = 0
        var firstDay: String?
        var pausesDay: String?
        var pauses: Int?
        var migration: Int?
        /// Past days already judged by `reviewPastDays`, as "yyyy-MM-dd".
        var reviewedDays: [String]?
        /// Version and day of the last complete review.
        var reviewVersion: String?
        var reviewDay: String?
        /// Prestige tier reached per achievement (0, Bronze, when missing).
        var tiers: [String: Int]?
        /// Achievements being earned again for the next tier, with the day that started.
        var chasing: [String: String]?
    }

    @Published private(set) var state = State()
    /// Latest evaluation context, for the progress of visible achievements.
    @Published private(set) var lastContext: AchievementContext?
    private let persist: Bool
    private var previousToday: DayData?
    /// Day `previousToday` was fetched on; yesterday's data must never be judged as today's.
    private var previousTodayDay = ""
    private var previousWeek: [WeekDay] = []
    private static let url = KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("achievements.json")

    init(persist: Bool) {
        self.persist = persist
        if persist, let data = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
        migrate()
    }

    /// One-off fixes to saved progress, applied once per install.
    private func migrate() {
        guard persist else { return }
        if (state.migration ?? 0) < 1 {
            // 1.1.5 and earlier judged yesterday's arrival as today's when the summary
            // was opened before the first refresh; arrival unlocks may be wrong.
            for id in ["entrada-triunfal", "madrugador", "suizo"] {
                state.unlocked[id] = nil
                state.seen.remove(id)
            }
            state.migration = 1
            save()
        }
    }

    var unseenCount: Int { state.unlocked.keys.filter { !state.seen.contains($0) }.count }

    func markAllSeen() {
        guard unseenCount > 0 else { return }
        state.seen.formUnion(state.unlocked.keys)
        save()
    }

    func popoverOpened() {
        let today = Fmt.ymd(Date())
        if state.opensDay != today { state.opensDay = today; state.opens = 0 }
        state.opens += 1
        save()
        if let t = previousToday, previousTodayDay == today { evaluate(today: t, week: previousWeek) }
    }

    /// A stretch without input just ended. DeskTime only gives daily totals, so these
    /// pauses can only be counted here, while the app runs.
    func pauseEnded(lasting seconds: Double, now: Date = Date()) {
        guard (10 * 60...20 * 60).contains(seconds) else { return }
        let today = Fmt.ymd(now)
        state.pauses = state.pausesDay == today ? (state.pauses ?? 0) + 1 : 1
        state.pausesDay = today
        save()
        if let t = previousToday, previousTodayDay == today { evaluate(today: t, week: previousWeek) }
    }

    /// Called with today's data on every refresh.
    func evaluate(today: DayData, week: [WeekDay]) {
        for d in week where !d.isFuture && d.desktime > 0 {
            state.history[Fmt.ymd(d.date)] = DaySummary(worked: d.desktime, productivity: d.productivity)
        }
        state.history[Fmt.ymd(Date())] = DaySummary(worked: today.worked, productivity: today.productivity)

        if state.firstDay == nil { state.firstDay = Fmt.ymd(Date()) }
        let ctx = AchievementContext(
            today: today, previous: previousTodayDay == Fmt.ymd(Date()) ? previousToday : nil, now: Date(), week: week, history: state.history,
            popoverOpensToday: state.opensDay == Fmt.ymd(Date()) ? state.opens : 0,
            pausesToday: state.pausesDay == Fmt.ymd(Date()) ? state.pauses ?? 0 : 0,
            isFirstDay: state.firstDay == Fmt.ymd(Date()))
        previousToday = today
        previousTodayDay = Fmt.ymd(Date())
        previousWeek = week
        lastContext = ctx
        unlock(allAchievements.filter { state.unlocked[$0.id] == nil && $0.check(ctx) })
        promote(chasedEarned(ctx, day: Fmt.ymd(Date()), past: nil))
    }

    private var reviewing = false

    /// Days a review looks back, so a new install or update catches up on what was earned.
    static let reviewDays = 30

    /// Gives each person the achievements their past days earned, even if the app was
    /// closed or out of date then. Runs once a day, which only needs yesterday's data, and
    /// after every update, which judges the whole period again because the rules may have
    /// changed. A failed fetch is retried on the next refresh.
    func reviewPastDays(now: Date = Date(), version: String = AppInfo.version, fetch: (Date) async throws -> DayData) async {
        let today = Fmt.ymd(now)
        guard !reviewing, state.reviewVersion != version || state.reviewDay != today else { return }
        reviewing = true
        defer { reviewing = false }
        var reviewed = Set(state.reviewVersion == version ? state.reviewedDays ?? [] : [])

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let dates = (1...Self.reviewDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }

        // Everything first: a day's week and streak depend on the days around it.
        var days: [(date: Date, data: DayData)] = []
        var complete = true
        for date in dates where !reviewed.contains(Fmt.ymd(date)) {
            guard let data = try? await fetch(date) else { complete = false; continue }
            days.append((date, data))
            reviewed.insert(Fmt.ymd(date))
            if data.worked > 0 {
                state.history[Fmt.ymd(date)] = DaySummary(worked: data.worked, productivity: data.productivity)
            }
        }

        var earned: [(Achievement, Date)] = []
        for (date, data) in days {
            let ctx = pastContext(date, data, calendar)
            for a in allAchievements where state.unlocked[a.id] == nil && !earned.contains(where: { $0.0.id == a.id }) {
                if pastDayChecks[a.id]?(data) ?? a.check(ctx) { earned.append((a, date)) }
            }
        }

        for (a, date) in earned { state.unlocked[a.id] = date }
        var promoted: [Achievement] = []
        for (date, data) in days {
            let list = chasedEarned(pastContext(date, data, calendar), day: Fmt.ymd(date), past: data)
            promote(list, notifying: false)
            promoted += list
        }
        state.reviewedDays = reviewed.filter { d in dates.contains { Fmt.ymd($0) == d } }.sorted()
        state.reviewVersion = version
        if complete { state.reviewDay = today }
        save()
        // A long catch-up is one notification, not a wall of them.
        if earned.count > 3 {
            notifySummary(earned.count)
        } else {
            earned.forEach { notify($0.0) }
        }
        promoted.forEach { notifyTier($0) }
    }

    /// What the checks would have seen on a past day.
    private func pastContext(_ date: Date, _ data: DayData, _ calendar: Calendar) -> AchievementContext {
        let day = Fmt.ymd(date)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let week = (0..<7).map { i -> WeekDay in
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            let s = d <= date ? state.history[Fmt.ymd(d)] : nil
            return WeekDay(date: d, desktime: s?.worked ?? 0, productivity: s?.productivity ?? 0)
        }
        // The first day DeskTime or this app ran may only be part of a day.
        let isFirst = day == state.firstDay || !state.history.keys.contains { $0 < day }
        return AchievementContext(
            today: data, previous: nil, now: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date,
            week: week, history: state.history, popoverOpensToday: 0, isFirstDay: isFirst)
    }

    private var observer: NSObjectProtocol?

    /// Listens for app switches to unlock moment-based achievements right away.
    func startLive() {
        guard persist, observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let event = LiveEvent(appName: app?.localizedName ?? "", now: Date())
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func handle(_ event: LiveEvent) {
        unlock(allAchievements.filter { a in
            state.unlocked[a.id] == nil && (liveTriggers[a.id]?(event) ?? false)
        })
    }

    // MARK: Prestige

    func tier(_ id: String) -> PrestigeTier {
        guard hasTiers(id) else { return .bronze }
        return PrestigeTier(rawValue: state.tiers?[id] ?? 0) ?? .bronze
    }

    /// Only hour and day achievements have tiers.
    func hasTiers(_ id: String) -> Bool { prestigeRules[id] != nil }

    /// Unlocked achievements and their tier, for the album rewards.
    var tierMap: [String: Int] {
        Dictionary(uniqueKeysWithValues: state.unlocked.keys.map { ($0, tier($0).rawValue) })
    }

    /// Achievements that count for the coin bonus: one being prestiged is lost until it is earned again.
    var activeTierMap: [String: Int] { tierMap.filter { !isChasing($0.key) } }

    var prestigeTotal: Int { state.unlocked.keys.reduce(0) { $0 + tier($1).rawValue } }

    func isChasing(_ id: String) -> Bool { state.chasing?[id] != nil }

    func canPrestige(_ id: String) -> Bool {
        state.unlocked[id] != nil && prestigeRules[id] != nil && !isChasing(id) && tier(id).next != nil
    }

    /// Sets the next tier as the goal: the achievement has to be earned again on a later day.
    func prestige(_ id: String) {
        guard canPrestige(id) else { return }
        var c = state.chasing ?? [:]
        c[id] = Fmt.ymd(Date())
        state.chasing = c
        save()
    }

    /// How the chase for the next tier is going.
    func chaseStatus(_ a: Achievement) -> (next: PrestigeTier, fraction: Double?, text: String)? {
        guard let start = state.chasing?[a.id], let next = tier(a.id).next, let rule = prestigeRules[a.id] else { return nil }
        let later = start == Fmt.ymd(Date()) ? " · cuenta desde mañana" : ""
        guard let ctx = lastContext else { return (next, 0, "Esperando datos de hoy…") }
        let p = rule.progress(ctx, next.rawValue)
        return (next, min(max(p.fraction, 0), 0.99), p.text + later)
    }

    /// Chased achievements earned again on a day after their chase began.
    private func chasedEarned(_ ctx: AchievementContext, day: String, past: DayData?) -> [Achievement] {
        allAchievements.filter { a in
            guard let start = state.chasing?[a.id], day > start, let next = tier(a.id).next,
                  let rule = prestigeRules[a.id] else { return false }
            return rule.check(ctx, next.rawValue)
        }
    }

    private func promote(_ list: [Achievement], notifying: Bool = true) {
        guard !list.isEmpty else { return }
        var tiers = state.tiers ?? [:], chasing = state.chasing ?? [:]
        for a in list {
            tiers[a.id] = min((tiers[a.id] ?? 0) + 1, PrestigeTier.legend.rawValue)
            chasing[a.id] = nil
            state.seen.remove(a.id)
        }
        state.tiers = tiers
        state.chasing = chasing
        save()
        if notifying { list.forEach { notifyTier($0) } }
    }

    private func unlock(_ fresh: [Achievement]) {
        for a in fresh { state.unlocked[a.id] = Date() }
        save()
        for a in fresh { notify(a) }
    }

    /// Unlocks a sample set, for screenshots in demo mode.
    func loadDemo() {
        // Only productivity ones: the screenshot must not give away hidden achievements.
        let ids = ["eficacia-100", "sin-casa"]
        for (i, id) in ids.enumerated() { state.unlocked[id] = Date().addingTimeInterval(Double(-i) * 86400) }
        state.seen = Set(ids.dropFirst(2))
        state.tiers = ["sin-casa": 2]
        state.chasing = ["sin-casa": Fmt.ymd(Date().addingTimeInterval(-86400))]
        lastContext = AchievementContext(today: Demo.day, previous: nil, now: Date(), week: Demo.week(around: Date()),
                                         history: [:], popoverOpensToday: 0, isFirstDay: false)
    }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    private func notify(_ a: Achievement) {
        guard persist else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "🏆 Logro desbloqueado"
            content.subtitle = "\(a.emoji) \(a.title)"
            content.body = a.detail
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "achievement-\(a.id)", content: content, trigger: nil))
        }
    }

    private func notifyTier(_ a: Achievement) {
        guard persist else { return }
        let tier = tier(a.id)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "🏅 Logro recuperado con más nivel"
            content.subtitle = "\(a.emoji) \(a.title)"
            content.body = "Lo has vuelto a conseguir con un reto mayor. Tienes Tokens nuevos en el álbum."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "achievement-\(a.id)-\(tier.rawValue)", content: content, trigger: nil))
        }
    }

    private func notifySummary(_ count: Int) {
        guard persist else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "🏆 \(count) logros desbloqueados"
            content.body = "Te los habías ganado estos días. Míralos en la pestaña Logros."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "achievement-summary", content: content, trigger: nil))
        }
    }
}

// MARK: - Tab

struct AchievementsTab: View {
    @ObservedObject var model: Achievements

    var body: some View {
        // Prestiging an achievement takes it away until its harder goal is met.
        let unlocked = allAchievements
            .filter { model.state.unlocked[$0.id] != nil && !model.isChasing($0.id) }
            .sorted { model.state.unlocked[$0.id]! > model.state.unlocked[$1.id]! }
        let inProgress: [(Achievement, Double, String, PrestigeTier?)] = allAchievements
            .compactMap { a in
                if let c = model.chaseStatus(a) { return (a, c.fraction ?? 0, c.text, c.next) }
                guard model.state.unlocked[a.id] == nil, let tracker = progressTrackers[a.id] else { return nil }
                guard let ctx = model.lastContext else { return (a, 0, "Esperando datos de hoy…", nil) }
                let p = tracker(ctx)
                return (a, min(max(p.fraction, 0), 0.99), p.text, nil)
            }
            // The ones you prestiged first: they were yours.
            .sorted { (x: (Achievement, Double, String, PrestigeTier?), y: (Achievement, Double, String, PrestigeTier?)) -> Bool in
                if (x.3 != nil) != (y.3 != nil) { return x.3 != nil }
                return x.1 > y.1
            }
        let hiddenCount = allAchievements.count - unlocked.count - inProgress.count

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(unlocked.count)").font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text("de \(allAchievements.count) logros").font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.prestigeTotal > 0 {
                        Text("· \(model.prestigeTotal) de prestigio").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(hiddenCount) ocultos").font(.system(size: 11)).foregroundStyle(.secondary)
                    PrestigeInfoButton().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.brand)
                            .frame(width: max(g.size.width * Double(unlocked.count) / Double(allAchievements.count), 4))
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            // Snapshots cannot scroll: show one screenful.
            let shown = isSnapshotRender ? Array(unlocked.prefix(2)) : unlocked
            let progress = isSnapshotRender ? Array(inProgress.prefix(3)) : inProgress
            let hidden = isSnapshotRender ? 0 : hiddenCount
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { a in
                    AchievementRow(achievement: a, date: model.state.unlocked[a.id], isNew: !model.state.seen.contains(a.id),
                                   tier: model.hasTiers(a.id) ? model.tier(a.id) : nil,
                                   onPrestige: model.canPrestige(a.id) ? { withAnimation { model.prestige(a.id) } } : nil)
                }
                if !progress.isEmpty {
                    SectionLabel(text: "En progreso").padding(.top, 6)
                    ForEach(progress, id: \.0.id) { a, fraction, text, goal in
                        ProgressRow(achievement: a, fraction: fraction, text: text, goal: goal)
                    }
                }
                if hidden > 0 {
                    SectionLabel(text: "Ocultos").padding(.top, 6)
                    ForEach(0..<hidden, id: \.self) { _ in LockedRow() }
                }
            }
            .padding(.horizontal, 12)
            if isSnapshotRender {
                rows
            } else {
                ScrollView { rows.padding(.bottom, 12) }.scrollIndicators(.never)
            }
        }
        // Opening the tab counts as having seen the new ones.
        .onDisappear { model.markAllSeen() }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }
}

/// A productivity achievement not unlocked yet: greyed out, with its progress.
struct ProgressRow: View {
    let achievement: Achievement
    let fraction: Double
    let text: String
    /// The tier being chased again, drawn as the ring's colour.
    var goal: PrestigeTier? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(achievement.emoji)
                .font(.system(size: 18))
                .grayscale(1)
                .opacity(0.45)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.04)))
                .overlay { if let goal { Circle().strokeBorder(goal.gradient, lineWidth: 2) } }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(achievement.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.secondary).frame(width: max(g.size.width * fraction, 3))
                    }
                }
                .frame(height: 3)
                Text(text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .help(achievement.detail)
    }
}

struct AchievementRow: View {
    let achievement: Achievement
    let date: Date?
    let isNew: Bool
    var tier: PrestigeTier? = nil
    var onPrestige: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(achievement.emoji)
                .font(.system(size: 18))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .overlay { if let tier { Circle().strokeBorder(tier.gradient, lineWidth: 2) } }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(achievement.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if isNew { Circle().fill(Theme.brand).frame(width: 5, height: 5) }
                }
                Text(achievement.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                if let date {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).locale(Fmt.es)))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let onPrestige, tier?.next != nil {
                    Button(action: onPrestige) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Prestigiar")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .help("Lo pierdes hasta superar un reto mayor: " + (prestigeRules[achievement.id]?.step ?? "") + ".")
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(isNew ? 0.06 : 0)))
        .contentShape(Rectangle())
        .help(achievement.detail)
    }
}

struct LockedRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 30, height: 30)
                .background(Circle().strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            VStack(alignment: .leading, spacing: 1) {
                Text("???").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                Text("Logro oculto").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }
}

/// Tab title with a dot while there are unseen achievements.
struct AchievementsTabTitle: View {
    @ObservedObject var model: Achievements
    let selected: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text("Logros")
            if model.unseenCount > 0 {
                Text("\(model.unseenCount)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.brand))
                    .foregroundStyle(Theme.onBrand)
            }
        }
    }
}

/// (i) in Logros: what prestige is, in a few lines.
private struct PrestigeInfoButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Qué es prestigiar")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prestigiar").font(.system(size: 13, weight: .bold))
                Text("Algunos logros se pueden subir de nivel: Bronce, Plata, Oro, Platino, Diamante y Leyenda.")
                tip("arrow.up.circle", "Al prestigiar, el logro se pierde hasta que superas un reto mayor.")
                tip("percent", "Cada nivel suma más filmo-coins a lo que ganas.")
                tip("gift", "Al recuperarlo te llevas un sobre de cromos y Tokens. Cuanto más alto el nivel, mejor sobre.")
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 280)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
            Text(text)
        }
    }
}
