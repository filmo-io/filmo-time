import AppKit
import Charts
import ServiceManagement
import SwiftUI

import WidgetKit

// MARK: - Store

enum Tab: Hashable { case summary, apps, achievements, album, profile }

/// What the summary shows: one day, its week, or any range of days.
enum Period: Equatable { case day, week, range(Date, Date) }

@MainActor
final class Store: ObservableObject {
    @Published var date = Calendar.current.startOfDay(for: Date())
    @Published var tab: Tab = .summary
    @Published var day: DayData?
    /// Always today's data, whatever day the popover shows; drives the menu bar and the name.
    @Published var today: DayData?
    @Published var week: [WeekDay] = []
    @Published var period: Period = .day
    /// Days of the chosen range, once loaded.
    @Published var rangeDays: [WeekDay] = []
    /// The range couldn't be loaded; the period view offers to try again.
    @Published var rangeFailed = false

    func retryRange() { Task { await loadRange() } }
    @Published var loading = false
    @Published var error: String?
    @Published var lastUpdate: Date?
    @Published var hasKey = KeyStore.read() != nil
    /// Seconds since the last keyboard or mouse input; reading it needs no permission.
    @Published var idle: Double = 0

    let demo: Bool
    let achievements: Achievements
    let album: Album
    let profile: Profile
    let community: Community
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var idleTimer: Timer?
    private var resumedAt = Date.distantPast
    private var lastInput: Date?
    private var lastFetch = Date.distantPast
    private var currentDay = Fmt.ymd(Date())
    private var resumeRefresh: Task<Void, Never>?
    /// Keeps App Nap from stretching the timer of this window-less app.
    private var activity: NSObjectProtocol?
    /// Past days of the week never change, so each is fetched only once.
    private var knownDays: [String: WeekDay] = [:]

    init(demo: Bool) {
        self.demo = demo
        achievements = Achievements(persist: !demo && !isSnapshotRender)
        album = Album(persist: !demo && !isSnapshotRender)
        profile = Profile(persist: !demo && !isSnapshotRender)
        community = Community(enabled: !demo && !isSnapshotRender)
        if demo { hasKey = true }
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    func start() {
        achievements.startLive()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Keep menu bar time current")
        Task { await refresh() }
        // One rhythm for everything: menu bar, popover and widget.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let idleTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIdle() }
        }
        RunLoop.main.add(idleTimer, forMode: .common)
        self.idleTimer = idleTimer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumed()
            }
        }
    }

    /// A new day is a new workday: the popover moves on to it, whatever day it was showing.
    /// Yesterday's data goes with it, so it is never shown under today's date.
    func followNewDay(now: Date = Date()) {
        let current = Fmt.ymd(now)
        guard current != currentDay else { return }
        currentDay = current
        date = Calendar.current.startOfDay(for: now)
        day = nil
        week = []
    }

    func shift(_ days: Int) {
        let cal = Calendar.current
        if case .range(let a, let b) = period {
            let n = Fmt.dates(from: a, to: b).count * days
            guard let na = cal.date(byAdding: .day, value: n, to: a), let nb = cal.date(byAdding: .day, value: n, to: b),
                  na <= Date() else { return }
            selectRange(na, min(nb, Date()))
            return
        }
        guard let d = cal.date(byAdding: .day, value: period == .week ? days * 7 : days, to: date) else { return }
        if period == .week, d > Date(), !Fmt.weekDates(around: d).contains(where: { cal.isDateInToday($0) }) { return }
        if period == .day, d > Date() { return }
        date = min(d, cal.startOfDay(for: Date()))
        Task { await refresh() }
    }

    /// Whether there is a later day, week or range to move to.
    var canGoForward: Bool {
        switch period {
        case .day: !isToday
        case .week: !Fmt.weekDates(around: date).contains { Calendar.current.isDateInToday($0) }
        case .range(_, let b): !Calendar.current.isDateInToday(b) && b < Date()
        }
    }

    var isNow: Bool { period == .day && isToday }

    var periodTitle: String {
        switch period {
        case .day: Fmt.longDay(date)
        case .week: "Semana del \(Fmt.shortDay(Fmt.weekDates(around: date)[0]))"
        case .range(let a, let b): "\(Fmt.shortDay(a)) – \(Fmt.shortDay(b))"
        }
    }

    func goToday() {
        period = .day
        date = Calendar.current.startOfDay(for: Date())
        Task { await refresh() }
    }

    func open(_ d: Date) {
        period = .day
        date = d
        tab = .summary
        Task { await refresh() }
    }

    func selectDay(_ d: Date) {
        period = .day
        date = Calendar.current.startOfDay(for: min(d, Date()))
        Task { await refresh() }
    }

    func selectWeek(of d: Date) {
        period = .week
        date = Calendar.current.startOfDay(for: min(d, Date()))
        Task { await refresh() }
    }

    /// Up to three months, ending no later than today.
    func selectRange(_ a: Date, _ b: Date) {
        let dates = Fmt.dates(from: a, to: min(max(a, b), Date())).suffix(92)
        guard let first = dates.first, let last = dates.last else { return }
        period = .range(first, last)
        rangeDays = []
        Task { await loadRange() }
    }

    /// Counting the coins of past days is under way.
    private var backfilling = false

    private func loadRange() async {
        guard case .range(let a, let b) = period else { return }
        let dates = Fmt.dates(from: a, to: b)
        if demo { rangeDays = Demo.days(dates); return }
        guard let key = KeyStore.read() else { return }
        rangeFailed = false
        do {
            let r = try await DeskTimeAPI(key: key).days(dates, today: today, known: knownDays)
            remember(r)
            if period == .range(a, b) { rangeDays = r }
        } catch {
            if period == .range(a, b) { rangeFailed = true }
        }
    }

    func refresh() async {
        followNewDay()
        if demo {
            day = Demo.day
            today = Demo.day
            week = Demo.week(around: date)
            album.record(today: Demo.day, week: week, tiers: achievements.activeTierMap)
            await loadRange()
            lastUpdate = Date()
            onChange?()
            return
        }
        guard let key = KeyStore.read() else {
            hasKey = false
            error = APIError.noKey.localizedDescription
            onChange?()
            return
        }
        hasKey = true
        lastFetch = Date()
        loading = true
        defer { loading = false; onChange?() }
        let api = DeskTimeAPI(key: key)
        let requested = date
        do {
            // Today is the single source for the menu bar, the popover and the widget.
            let todayJSON = try await api.get("employee", date: Date())
            let t = DayData.parse(todayJSON)
            let todayWeek = try await api.week(around: Date(), today: t, known: knownDays)
            remember(todayWeek)
            today = t
            WorkTimeline.record(t)
            achievements.evaluate(today: t, week: todayWeek)
            album.record(today: t, week: todayWeek, tiers: achievements.activeTierMap)
            album.reward(tiers: achievements.tierMap)
            // Everybody shows up in the community, whether or not they open their profile.
            let shared = SharedProfile.make(profile: profile, achievements: achievements, album: album)
            Task {
                await community.sync(shared, photo: profile.photoData)
                if let grants = community.grants { achievements.grant(grants) }
            }
            if !album.state.backfilled && !backfilling && !isSnapshotRender {
                backfilling = true
                Task {
                    defer { backfilling = false }
                    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
                    guard yesterday >= Album.backfillStart else { album.backfill([], tiers: achievements.activeTierMap); return }
                    if let past = try? await api.days(Fmt.dates(from: Album.backfillStart, to: yesterday), today: t, known: knownDays) {
                        remember(past)
                        album.backfill(past, tiers: achievements.activeTierMap)
                    }
                }
            }
            if !isSnapshotRender {
                Task { await achievements.reviewPastDays { DayData.parse(try await api.get("employee", date: $0)) } }
            }
            if Snapshot.save(day: todayJSON, week: todayWeek) {
                WidgetCenter.shared.reloadAllTimelines()
            }

            if Calendar.current.isDateInToday(requested) {
                day = t
                week = todayWeek
            } else {
                async let dayJSON = api.get("employee", date: requested)
                async let otherWeek = api.week(around: requested, today: t, known: knownDays)
                let (j, w) = try await (dayJSON, otherWeek)
                remember(w)
                guard requested == date else { return }
                day = DayData.parse(j)
                week = w
            }
            error = nil
            lastUpdate = Date()
            await loadRange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remember(_ days: [WeekDay]) {
        for d in days where !d.isFuture && !Calendar.current.isDateInToday(d.date) {
            knownDays[Fmt.ymd(d.date)] = d
        }
    }

    /// Productive-time average of the other worked days this week.
    var weekAverageExcludingSelected: Double? {
        let others = week.filter { !$0.isFuture && $0.desktime > 0 && !Calendar.current.isDate($0.date, inSameDayAs: date) }
        guard !others.isEmpty else { return nil }
        return others.reduce(0) { $0 + $1.productive } / Double(others.count)
    }

    var menuBarTitle: String {
        guard let d = today else { return hasKey ? "…" : AppInfo.name }
        if paused { return "\(Fmt.duration(d.worked)) · \(Fmt.duration(inactiveToday)) inactivo" }
        return "\(Fmt.duration(d.worked)) · \(Fmt.duration(d.productive)) prod."
    }

    private func pollIdle() {
        let wasPaused = paused, wasIdle = idle >= PauseRules.idleThreshold
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        // Gap between two inputs, which also spans a Mac put to sleep during the pause.
        let input = Date().addingTimeInterval(-idle)
        if let lastInput, today?.arrivedDay == Fmt.ymd(Date()) {
            achievements.pauseEnded(lasting: input.timeIntervalSince(lastInput))
        }
        lastInput = input
        if wasIdle && idle < PauseRules.idleThreshold {
            resumed()
        } else if paused, idle < PauseRules.idleThreshold,
                  Date().timeIntervalSince(lastFetch) >= PauseRules.offlineRefresh {
            Task { await refresh() }
        }
        if paused != wasPaused || paused { onChange?() }
    }

    /// Back at the computer: the pause ends now, and DeskTime is asked again right away
    /// and once more when it has had time to report you online.
    private func resumed() {
        resumedAt = Date()
        Task { await refresh() }
        resumeRefresh?.cancel()
        resumeRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PauseRules.resumeGrace - 30))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// DeskTime is not counting right now: no input for a while, or it reports being offline.
    var paused: Bool {
        guard !demo, let t = today, t.arrived != nil else { return false }
        return isDeskTimePaused(idle: idle, online: t.isOnline, sinceResume: Date().timeIntervalSince(resumedAt))
    }

    /// The idle stretch going on now that DeskTime's figures, which only run to its
    /// last update, do not include yet.
    var ongoingIdle: Double {
        guard let t = today, idle >= PauseRules.idleThreshold else { return 0 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = Double(c.hour! * 60 + c.minute!)
        let sinceUpdate = max(now - (minutes(t.left) ?? now), 0) * 60
        return wholeMinutes(min(idle, sinceUpdate))
    }

    var inactiveToday: Double { (today?.inactive ?? 0) + ongoingIdle }
}

// MARK: - Views

struct Actions {
    var openSettings: () -> Void = {}
    var checkUpdates: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var launchesAtLogin: () -> Bool = { false }
}

/// ImageRenderer cannot draw ScrollView contents, so snapshots lay lists out flat.
@MainActor var isSnapshotRender = false

/// Popover shown from the menu bar: fixed size, three tabs, Filmo black and white.
struct WidgetView: View {
    @ObservedObject var store: Store
    var actions = Actions()
    var snapshot = false
    @Namespace private var tabUnderline

    static let width: CGFloat = 340
    static let contentHeight: CGFloat = 345

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            tabBar.padding(.horizontal, 16)
            Divider().opacity(0.6)
            content
                .frame(width: Self.width, height: Self.contentHeight, alignment: .top)
                .animation(.smooth(duration: 0.25), value: store.tab)
            Divider().opacity(0.6)
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .background {
            // In the popover the popover itself provides the material.
            if snapshot { RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)) }
        }
    }

    // Header: brand, date navigation and actions.

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            BrandMark(height: 18).foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    let name = store.today?.name ?? store.day?.name ?? ""
                    Text(name.isEmpty ? AppInfo.name : name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let t = store.today {
                        Circle().fill(t.isOnline ? Theme.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                            .help(t.isOnline ? "En línea" : "Desconectado")
                    }
                }
                HStack(spacing: 2) {
                    IconButton(symbol: "chevron.left", help: "Anterior", size: 16) { store.shift(-1) }
                    // In the summary the date is also the way to choose another day, week or range.
                    if store.tab == .summary {
                        PeriodMenu(store: store, title: store.periodTitle)
                    } else {
                        Text(store.periodTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    IconButton(symbol: "chevron.right", help: "Siguiente", size: 16) { store.shift(1) }
                        .opacity(store.canGoForward ? 1 : 0.25)
                        .disabled(!store.canGoForward)
                    if !store.isNow {
                        Button("Hoy") { store.goToday() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.brand))
                            .foregroundStyle(Theme.onBrand)
                            .padding(.leading, 4)
                    }
                }
                .padding(.leading, -4)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.clockwise", help: "Actualizar", spinning: store.loading) {
                Task { await store.refresh() }
            }
            if snapshot {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            } else {
            Menu {
                Section("\(AppInfo.name) \(AppInfo.version)") {
                    Button("Novedades de esta versión…") { NSWorkspace.shared.open(AppInfo.changelogURL) }
                }
                Button("Ver panel completo") { NSWorkspace.shared.open(URL(string: "https://desktime.com/app/my")!) }
                Button("Configurar API key…", action: actions.openSettings)
                Button("Buscar actualizaciones…", action: actions.checkUpdates)
                Toggle("Abrir al iniciar sesión", isOn: Binding(get: actions.launchesAtLogin, set: { _ in actions.toggleLogin() }))
                Divider()
                Button("Salir") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            }
        }
    }

    /// The sections share the whole width, evenly apart.
    private var tabBar: some View {
        HStack(spacing: 0) {
            let tabs: [(Tab, String)] = [(.summary, "Resumen"), (.apps, "Apps"), (.achievements, "Logros"), (.album, "Cromos"), (.profile, "Perfil")]
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, item in
                let (tab, title) = item
                if i > 0 { Spacer(minLength: 4) }
                Button {
                    withAnimation(.smooth(duration: 0.25)) { store.tab = tab }
                } label: {
                    VStack(spacing: 6) {
                        Group {
                            if tab == .achievements {
                                AchievementsTabTitle(model: store.achievements, selected: store.tab == tab)
                            } else {
                                Text(title)
                            }
                        }
                            .font(.system(size: 12, weight: store.tab == tab ? .semibold : .regular))
                            .foregroundStyle(store.tab == tab ? Color.primary : Color.secondary)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 2)
                            if store.tab == tab {
                                Capsule().fill(Theme.brand).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: tabUnderline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = store.error, store.day == nil || !store.hasKey {
            ErrorCard(message: error, needsKey: !store.hasKey, openSettings: actions.openSettings)
                .padding(16)
        } else if let d = store.day {
            switch store.tab {
            case .summary:
                if store.period == .day {
                    SummaryTab(day: d, store: store).padding(16).transition(.opacity)
                } else {
                    PeriodTab(store: store).padding(16).transition(.opacity)
                }
            case .apps: AppsTab(day: d).transition(.opacity)
            case .achievements: AchievementsTab(model: store.achievements).transition(.opacity)
            case .album: AlbumTab(model: store.album, achievements: store.achievements).transition(.opacity)
            case .profile:
                ProfileTab(profile: store.profile, achievements: store.achievements, album: store.album, community: store.community,
                           name: store.today?.name ?? d.name).transition(.opacity)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let t = store.lastUpdate {
                Text(store.demo ? "Datos de ejemplo" : "Actualizado a las \(Fmt.time(t))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: "https://desktime.com/app/my")!)
            } label: {
                HStack(spacing: 3) { Text("Ver panel completo"); Image(systemName: "arrow.up.right").imageScale(.small) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.brand)
        }
        .font(.system(size: 11))
    }
}

struct WidgetBackground: View {
    var snapshot: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor))
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var spinning = false
    var size: CGFloat = 24
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct Label2: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct MonoRing: View {
    let value: Double
    let title: String
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(value / 100, 0.001), 1))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: value)
                Text(Fmt.percent(value))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 50, height: 50)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label2(text: title)
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Summary

struct SummaryTab: View {
    let day: DayData
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(text: "Tiempo trabajado")
                    Text(Fmt.duration(day.worked))
                        .font(.system(size: 38, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    HStack(spacing: 6) {
                        Text("\(Fmt.duration(day.productive)) productivo")
                        if let avg = store.weekAverageExcludingSelected, avg > 0 {
                            let delta = day.productive - avg
                            Text("\(delta >= 0 ? "▲" : "▼") \(Fmt.duration(abs(delta)))")
                                .help("Comparado con tu media de esta semana")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                MonoRing(value: day.productivity, title: "Productividad")
                    .help("Parte de tu tiempo frente al ordenador que fue productiva")
                MonoRing(value: day.efficiency, title: "Eficacia")
                    .help("Tiempo productivo comparado con tu jornada objetivo")
            }

            WorkBreakdown(day: day)
                .help("Todo el tiempo con actividad en el ordenador, según el tipo de app")

            let online = day.isOnline && store.isToday
            let paused = store.paused && store.isToday
            HStack(spacing: 8) {
                Stat(title: "Llegada", value: day.arrived ?? "—", color: day.late ? Theme.red : .primary)
                Stat(title: "Salida", value: paused ? "En pausa" : online ? "En línea" : (day.left ?? "—"))
                Stat(title: "En el trabajo", value: Fmt.duration(day.atWork + (store.isToday ? store.ongoingIdle : 0)))
                Stat(title: "Inactivo", value: Fmt.duration(store.isToday ? store.inactiveToday : day.inactive))
                    .help("Tiempo en el trabajo que DeskTime no contó: pausas, descansos y ratos sin actividad")
            }

            WorkdayBar(day: day, isToday: store.isToday, demo: store.demo)

            Spacer(minLength: 0)

            if let tip = Insights.make(day: day, isToday: store.isToday).first {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tip.icon).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(tip.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

/// The workday runs from the arrival until nine hours later, whatever happened in between.
struct WorkdayBar: View {
    let day: DayData
    let isToday: Bool
    var demo = false
    static let length: Double = 9 * 60
    @State private var hovered: WorkTimeline.Column?

    var body: some View {
        let nowMin: Double = {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return Double(c.hour! * 60 + c.minute!)
        }()
        let from = minutes(day.arrived)
        let end = from.map { $0 + Self.length }
        let open = isToday && day.isOnline
        // A day that runs past midnight keeps counting forward.
        let to: Double? = from.flatMap { f in
            let t = open ? nowMin : minutes(day.left) ?? (isToday ? nowMin : nil)
            return t.map { $0 < f ? $0 + 1440 : $0 }
        }
        let span = max(Self.length, (to ?? 0) - (from ?? 0))
        let clock = { (m: Double) in String(format: "%02d:%02d", Int(m) / 60 % 24, Int(m) % 60) }
        let columns: [WorkTimeline.Column] = {
            guard let from, let to, to > from else { return [] }
            let samples = demo ? WorkTimeline.demo(from: from, to: to) : WorkTimeline.samples(for: day)
            let totals = demo ? samples.last ?? .init(t: to, p: 0, n: 0, u: 0)
                              : WorkTimeline.Sample(t: to, p: day.productive, n: day.neutralTime, u: day.unproductiveTime)
            return WorkTimeline.columns(samples, totals: totals, from: from, to: to, open: open)
        }()
        let kinds = Array(WorkTimeline.Kind.allCases.prefix(3))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label2(text: "Jornada")
                Spacer()
                if let from, let end {
                    let status: String = {
                        if isToday, let to, to < end { return " · quedan \(Fmt.duration((end - to) * 60))" }
                        if let l = day.left, !open { return " · saliste a las \(l)" }
                        if let to, to >= end { return " · completa" }
                        return ""
                    }()
                    Text("\(clock(from)) – \(clock(end))\(status)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                let lo = from ?? 0
                Canvas { ctx, size in
                    let base = size.height - 3
                    // The nine hours, with the part already gone a little darker.
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: base + 1, width: size.width, height: 2), cornerRadius: 1),
                             with: .color(Color.primary.opacity(0.08)))
                    if let to {
                        ctx.fill(Path(roundedRect: CGRect(x: 0, y: base + 1, width: CGFloat((to - lo) / span) * size.width, height: 2), cornerRadius: 1),
                                 with: .color(Color.primary.opacity(0.22)))
                    }
                    for c in columns {
                        let x = CGFloat((c.from - lo) / span) * size.width
                        let w = max(CGFloat((c.to - c.from) / span) * size.width - (c.loose ? 0 : 0.6), 0.6)
                        let total = c.seconds.reduce(0, +)
                        guard total > 0 else { continue }
                        // No detail for this stretch: a row of faint ticks instead of made-up columns.
                        if c.loose {
                            var tick = x
                            while tick < x + w - 1 {
                                ctx.fill(Path(CGRect(x: tick, y: base - 5, width: 1, height: 5)), with: .color(Color.primary.opacity(0.22)))
                                tick += 3
                            }
                            continue
                        }
                        var y = base
                        for (kind, seconds) in zip(kinds, c.seconds) where seconds > 0 {
                            let h = max(CGFloat(c.active * seconds / total) * base, 0.5)
                            y -= h
                            ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(kind.color.opacity(c.loose ? 0.4 : 1)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        let m = lo + Double(p.x / g.size.width) * span
                        hovered = columns.first { m >= $0.from && m < $0.to }
                    } else {
                        hovered = nil
                    }
                }
            }
            .frame(height: 26)
            HStack(spacing: 8) {
                if let h = hovered {
                    let parts = zip(kinds, h.seconds).filter { $0.1 >= 30 }.map { "\(Fmt.duration($0.1)) \($0.0.name.lowercased())" }
                    Text("\(clock(h.from)) – \(clock(h.to)) · " + (parts.isEmpty ? "inactivo" : parts.joined(separator: " · "))
                         + (h.loose ? " · sin detalle: la app no estaba registrando" : ""))
                        .monospacedDigit()
                } else if from != nil {
                    ForEach(kinds, id: \.rawValue) { k in
                        HStack(spacing: 3) {
                            Circle().fill(k.color).frame(width: 5, height: 5)
                            Text(k.name)
                        }
                    }
                    Text("· los huecos son tiempo inactivo").foregroundStyle(.tertiary)
                } else {
                    Text("Sin actividad")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: Apps

struct AppsTab: View {
    let day: DayData
    @State private var kind: AppKind = .productive

    var body: some View {
        let apps = day.apps(kind)
        let maxSec = apps.first?.seconds ?? 1
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(AppKind.allCases) { k in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { kind = k }
                    } label: {
                        VStack(spacing: 1) {
                            Text(k.title).font(.system(size: 10))
                            Text(Fmt.duration(day.total(k))).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(kind == k ? Theme.onBrand : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(kind == k ? Theme.brand : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            if apps.isEmpty {
                Text("No se han recogido datos")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSnapshotRender {
                VStack(spacing: 10) {
                    ForEach(apps.prefix(6)) { a in AppRow(app: a, fraction: a.seconds / maxSec) }
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(apps) { a in AppRow(app: a, fraction: a.seconds / maxSec) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct AppRow: View {
    let app: AppUsage
    let fraction: Double
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: app.isWeb ? "globe" : "app")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(app.name).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(Fmt.duration(app.seconds))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(hover ? .primary : .secondary)
            }
            GeometryReader { g in
                Capsule().fill(Theme.brand.opacity(hover ? 0.9 : 0.55))
                    .frame(width: max(g.size.width * fraction, 3))
            }
            .frame(height: 3)
            .padding(.leading, 20)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: Week

/// The period picker at the top right of the summary.
struct PeriodMenu: View {
    @ObservedObject var store: Store
    /// Shown instead of the short name of the period, as plain text with a chevron.
    var title: String? = nil
    @State private var picking: Picking?
    @State private var day = Date()
    @State private var from = Date()
    @State private var to = Date()
    /// Snapshot only: draw the options as if the menu were open.
    nonisolated(unsafe) static var snapshotOpen = false

    enum Picking: Int, Identifiable { case day, range; var id: Int { rawValue } }

    private var cal: Calendar { Calendar.current }
    private var yesterday: Date { cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))! }

    private var label: String {
        switch store.period {
        case .day: store.isToday ? "Hoy" : cal.isDate(store.date, inSameDayAs: yesterday) ? "Ayer" : Fmt.shortDay(store.date)
        case .week: "Semana"
        case .range: "Rango"
        }
    }

    var body: some View {
        Group {
            if isSnapshotRender {
                pill.overlay(alignment: .topTrailing) {
                    if Self.snapshotOpen { options.offset(y: 24).fixedSize() }
                }
            } else {
                Menu {
                    Button("Hoy") { store.selectDay(Date()) }
                    Button("Ayer") { store.selectDay(yesterday) }
                    Button("Elegir día…") { day = store.date; picking = .day }
                    Divider()
                    Button("Esta semana") { store.selectWeek(of: Date()) }
                    Button("Semana pasada") { store.selectWeek(of: cal.date(byAdding: .day, value: -7, to: Date())!) }
                    Button("Rango…") {
                        if case .range(let a, let b) = store.period { from = a; to = b } else {
                            from = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: Date()))!; to = Date()
                        }
                        picking = .range
                    }
                } label: { pill }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: title == nil, vertical: true)
                    .popover(item: $picking, arrowEdge: .bottom) { p in
                        switch p {
                        case .day: dayPicker
                        case .range: rangePicker
                        }
                    }
            }
        }
    }

    @ViewBuilder private var pill: some View {
        if let title {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11)).contentTransition(.opacity)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        } else {
            capsule
        }
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .foregroundStyle(.primary)
        .fixedSize()
    }

    /// The menu as drawn in snapshots.
    private var options: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(["Hoy", "Ayer", "Elegir día…", "—", "Esta semana", "Semana pasada", "Rango…"], id: \.self) { o in
                if o == "—" { Divider() } else { Text(o).font(.system(size: 12)) }
            }
        }
        .padding(8)
        .frame(width: 130, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 6))
    }

    private var dayPicker: some View {
        VStack(alignment: .trailing, spacing: 8) {
            DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            Button("Ver día") { store.selectDay(day); picking = nil }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .environment(\.locale, Locale(identifier: "es_ES"))
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach([("7 días", 6), ("30 días", 29), ("90 días", 89)], id: \.1) { title, back in
                    Button(title) {
                        from = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date()))!; to = Date()
                    }
                }
                Button("Este mes") {
                    from = cal.dateInterval(of: .month, for: Date())!.start; to = Date()
                }
            }
            .controlSize(.small)
            HStack(spacing: 10) {
                DatePicker("Desde", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("Hasta", selection: $to, in: from...Date(), displayedComponents: .date)
            }
            .datePickerStyle(.field)
            HStack {
                Text("Máximo 3 meses").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Ver rango") { store.selectRange(from, to); picking = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .environment(\.locale, Locale(identifier: "es_ES"))
    }
}

/// Totals and a bar per day for a week or any range.
struct PeriodTab: View {
    @ObservedObject var store: Store
    @State private var hovered: Date?

    private var days: [WeekDay] { store.period == .week ? store.week : store.rangeDays }
    private var worked: [WeekDay] { days.filter { !$0.isFuture && $0.desktime > 0 } }
    private var cal: Calendar { Calendar.current }

    var body: some View {
        if days.isEmpty && store.rangeFailed && store.period != .week {
            VStack(spacing: 8) {
                Text("No se han podido cargar estos días.").font(.system(size: 12))
                Button("Reintentar") { store.retryRange() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if days.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                totals
                chart
                detail
            }
        }
    }

    private var totals: some View {
        let total = worked.reduce(0) { $0 + $1.productive }
        let desk = worked.reduce(0) { $0 + $1.desktime }
        // Weighted by DeskTime time, so it matches DeskTime's own daily figure.
        let prod = desk > 0 ? worked.reduce(0) { $0 + $1.productivity * $1.desktime } / desk : 0
        return HStack(spacing: 8) {
            Stat(title: "Trabajado", value: Fmt.duration(desk))
            Stat(title: "Productivo", value: Fmt.duration(total))
            Stat(title: "Productividad", value: Fmt.percent(prod))
            Stat(title: "Media al día", value: worked.isEmpty ? "—" : Fmt.duration(desk / Double(worked.count)))
                .help("Media de los \(worked.count) días con actividad")
        }
    }

    private var chart: some View {
        Chart(days) { d in
            BarMark(x: .value("Día", d.date, unit: .day), y: .value("Horas", d.productive / 3600))
                .foregroundStyle(Theme.brand.opacity(opacity(d)))
                .cornerRadius(days.count > 31 ? 1 : 3)
            // Stacked on top: the rest of the worked time (neutral and unproductive).
            BarMark(x: .value("Día", d.date, unit: .day), y: .value("Horas", max(d.desktime - d.productive, 0) / 3600))
                .foregroundStyle(Color.secondary.opacity(0.35 * opacity(d)))
                .cornerRadius(days.count > 31 ? 1 : 3)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let h = v.as(Double.self) {
                        Text(h > 0 && h < 1 ? "\(Int((h * 60).rounded()))m" : h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            if days.count <= 7 {
                AxisMarks(values: .stride(by: .day)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) { Text(Fmt.weekdayShort(d)).font(.system(size: 10)) }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) { Text(Fmt.shortDay(d)).font(.system(size: 9)) }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = day(at: p, proxy: proxy, geo: geo)?.date
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { p in
                        if let d = day(at: p, proxy: proxy, geo: geo), !d.isFuture { store.open(d.date) }
                    }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var detail: some View {
        let focus = days.first { $0.date == hovered }
            ?? (store.period == .week ? days.first { cal.isDate($0.date, inSameDayAs: store.date) } : nil)
        if let d = focus {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.longDay(d.date)).font(.system(size: 11, weight: .semibold))
                Text(d.isFuture ? "Todavía no ha llegado" : d.desktime == 0 ? "Sin actividad"
                     : "\(Fmt.duration(d.desktime)) · \(Fmt.duration(d.productive)) prod.")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !d.isFuture {
                    Button("Ver día") { store.open(d.date) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
            }
        } else {
            Text("Pasa por encima de un día para verlo; haz clic para abrirlo.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func opacity(_ d: WeekDay) -> Double {
        if let h = hovered { return cal.isDate(h, inSameDayAs: d.date) ? 1 : 0.3 }
        if store.period == .week { return cal.isDate(d.date, inSameDayAs: store.date) ? 1 : 0.4 }
        return 0.85
    }

    private func day(at p: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> WeekDay? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = p.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return days.first { cal.isDate($0.date, inSameDayAs: date) }
    }
}

struct ErrorCard: View {
    let message: String
    let needsKey: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: needsKey ? "key.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(needsKey ? Theme.brand : Theme.orange)
                if needsKey {
                    Text("Genera una en DeskTime → API y pégala aquí. Se guarda en un archivo que solo puede leer tu usuario.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button(needsKey ? "Configurar API key…" : "Revisar API key…", action: openSettings)
                    .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Settings

struct SettingsView: View {
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @State private var key = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API key de DeskTime").font(.headline)
            Text("En DeskTime abre **API** (enlace al pie de cualquier página), pulsa el botón para generar la clave y pégala aquí. Se guarda en un archivo que solo puede leer tu usuario.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Pega tu API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(status.hasPrefix("✓") ? Theme.green : Theme.red)
            }
            HStack {
                Button("Abrir página de API") { NSWorkspace.shared.open(URL(string: "https://desktime.com/app/api")!) }
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button(testing ? "Comprobando…" : "Guardar") { Task { await test() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let j = try await DeskTimeAPI(key: k).get("employee/basic", date: Date())
            status = "✓ Conectado como \(j["name"] as? String ?? "tú")"
            onSave(k)
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - App shell

/// Lives in the menu bar: left click opens the summary in a popover,
/// right click shows the app menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store: Store
    let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    init(demo: Bool) {
        store = Store(demo: demo)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildPopover()
        buildStatusItem()
        store.onChange = { [weak self] in self?.updateStatusItem() }
        store.start()
        if !store.hasKey { openSettings() }
        if let i = CommandLine.arguments.firstIndex(of: "--install-dmg"), i + 1 < CommandLine.arguments.count {
            // Exercises the update install from a local DMG.
            Task { await updater.install(from: URL(fileURLWithPath: CommandLine.arguments[i + 1]), fallbackPage: nil) }
        } else if !store.demo {
            updater.start()
        }
    }

    private func buildPopover() {
        let actions = Actions(
            openSettings: { [weak self] in self?.openSettings() },
            checkUpdates: { [weak self] in self?.menuCheckUpdates() },
            toggleLogin: { [weak self] in self?.toggleLogin() },
            launchesAtLogin: { SMAppService.mainApp.status == .enabled })
        let host = NSHostingController(rootView: WidgetView(store: store, actions: actions))
        // The popover follows the content size, so switching tabs resizes it smoothly.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = StatusIcon.image(phase: 0)
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.title = " " + store.menuBarTitle
        statusItem?.button?.toolTip = store.paused ? "DeskTime en pausa" : nil
        setIcon(paused: store.paused)
    }

    private var iconPhase: CGFloat = 0
    private var iconPaused = false
    private var iconTimer: Timer?

    /// Morphs the bars of the F into a pause sign and back.
    private func setIcon(paused: Bool) {
        guard paused != iconPaused else { return }
        iconPaused = paused
        iconTimer?.invalidate()
        let from = iconPhase, to: CGFloat = paused ? 1 : 0, start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                let p = min(CGFloat(Date().timeIntervalSince(start) / 0.4), 1)
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(2 - 2 * p, 2) / 2
                self.iconPhase = from + (to - from) * eased
                self.statusItem.button?.image = StatusIcon.image(phase: self.iconPhase)
                if p >= 1 { t.invalidate(); self.iconTimer = nil }
            }
        }
        // Common modes: the animation must not freeze while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.followNewDay()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            store.achievements.popoverOpened()
            popover.contentViewController?.view.window?.makeKey()
            if store.isToday { Task { await store.refresh() } }
        }
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector, _ key: String = "", state: Bool? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let state { i.state = state ? .on : .off }
            m.addItem(i)
        }
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        m.addItem(version)
        item("Novedades de esta versión…", #selector(openChangelog))
        m.addItem(.separator())
        item("Mostrar resumen", #selector(menuShow))
        item("Actualizar", #selector(menuRefresh), "r")
        m.addItem(.separator())
        item("Ver panel completo", #selector(openDeskTime), "o")
        item("Configurar API key…", #selector(menuSettings), ",")
        item("Buscar actualizaciones…", #selector(menuCheckUpdates))
        item("Abrir al iniciar sesión", #selector(menuToggleLogin), state: SMAppService.mainApp.status == .enabled)
        m.addItem(.separator())
        item("Salir", #selector(quit), "q")
        return m
    }

    @objc private func menuShow() { togglePopover() }
    @objc private func menuRefresh() { Task { await store.refresh() } }
    @objc private func openDeskTime() { NSWorkspace.shared.open(URL(string: "https://desktime.com/app/my")!) }
    @objc private func menuSettings() { openSettings() }
    @objc private func openChangelog() { NSWorkspace.shared.open(AppInfo.changelogURL) }
    @objc private func menuCheckUpdates() {
        popover.performClose(nil)
        Task { await updater.check(userInitiated: true) }
    }
    @objc private func menuToggleLogin() { toggleLogin() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "No se pudo cambiar el inicio automático"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            onSave: { [weak self] key in
                guard let self else { return }
                KeyStore.save(key)
                self.store.hasKey = true
                Task {
                    await self.store.refresh()
                    try? await Task.sleep(for: .seconds(0.8))
                    self.settingsWindow?.close()
                }
            },
            onCancel: { [weak self] in self?.settingsWindow?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = AppInfo.name
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
            NSApp.deactivate()
        }
    }

    /// Hands focus back to the previous app; while this app stays active the
    /// system keeps an auto-hiding menu bar on screen.
    func popoverWillShow(_ notification: Notification) {
        PopoverVisibility.shared.visible = true
    }

    func popoverDidClose(_ notification: Notification) {
        PopoverVisibility.shared.visible = false
        store.album.dropFinishedOpening()
        if settingsWindow == nil { NSApp.deactivate() }
    }
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            let code = MainActor.assumeIsolated { SelfTest.run() }
            exit(code)
        }
        let args = CommandLine.arguments
        let demo = args.contains("--demo")

        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { snapshot(to: args[i + 1], demo: demo, week: args.contains("--week"), dark: args.contains("--dark")) }
            return
        }

        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate(demo: demo) }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Renders the widget to a PNG; used to check the layout without a screen.
    @MainActor
    static func snapshot(to path: String, demo: Bool, week: Bool, dark: Bool) {
        isSnapshotRender = true
        if let i = CommandLine.arguments.firstIndex(of: "--oro-pares"), i + 1 < CommandLine.arguments.count {
            // For each poster or photo card: original | gold cut-out | gold frame, to review them one by one.
            let dir = CommandLine.arguments[i + 1]
            Posters.prefetchForSnapshot()
            for c in allCards where !c.art.isDrawn {
                if case .logo = c.art { continue }
                guard let img = Posters.cached(c), let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff),
                      let cg = CIContext().createCGImage(ci, from: ci.extent) else { continue }
                let ctx = CIContext()
                let cut = ArtEffects.goldCutout(ci, cg, force: true).flatMap { ctx.createCGImage($0, from: ci.extent) }
                let auto = ArtEffects.goldCutout(ci, cg) != nil
                let frame = ctx.createCGImage(ArtEffects.goldFrame(ci), from: ci.extent)
                let w = 240.0, h = 360.0
                let out = NSImage(size: NSSize(width: w * 3 + 40, height: h + 30))
                out.lockFocus()
                NSColor.darkGray.setFill(); NSRect(origin: .zero, size: out.size).fill()
                img.draw(in: NSRect(x: 10, y: 10, width: w, height: h))
                if let cut { NSImage(cgImage: cut, size: img.size).draw(in: NSRect(x: 20 + w, y: 10, width: w, height: h)) }
                if let frame { NSImage(cgImage: frame, size: img.size).draw(in: NSRect(x: 30 + w * 2, y: 10, width: w, height: h)) }
                ("\(c.id) · original | recorte\(auto ? "" : " (auto: no)") | marco" as NSString).draw(at: NSPoint(x: 10, y: h + 12),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.yellow])
                out.unlockFocus()
                if let t = out.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? jpg.write(to: URL(fileURLWithPath: "\(dir)/\(c.id).jpg"))
                }
            }
            print("done"); exit(0)
        }
        if CommandLine.arguments.contains("--info") {
            let album = Album(persist: false); album.loadDemo()
            let dark = CommandLine.arguments.contains("--dark")
            let view = OddsSheet(model: album).padding(16).frame(width: 360)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            print("wrote \(path)"); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--rejilla"), i + 1 < CommandLine.arguments.count {
            // Every card of a category, as the app draws it, to review them at a glance.
            let set = CommandLine.arguments[i + 1]
            Posters.prefetchForSnapshot()
            let artArg = CommandLine.arguments.firstIndex(of: "--arte").map { CommandLine.arguments[$0 + 1] }
            let gridArt = artArg.flatMap(Art.init(rawValue:)) ?? .base
            let finishArg = CommandLine.arguments.firstIndex(of: "--acabado").map { CommandLine.arguments[$0 + 1] }
            let gridFinish = finishArg.flatMap(Finish.init(rawValue:)) ?? .normal
            let from = CommandLine.arguments.firstIndex(of: "--desde").map { Int(CommandLine.arguments[$0 + 1]) ?? 0 } ?? 0
            let cards = Array(allCards.filter { $0.set == set }.dropFirst(from).prefix(40))
            let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 8), count: 10), spacing: 8) {
                ForEach(cards) { c in
                    VStack(spacing: 2) {
                        CardFace(card: c, art: gridArt, finish: gridFinish, width: 110)
                        Text(c.id).font(.system(size: 8)).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
            .padding(10).background(Color.gray.opacity(0.25)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view); r.scale = 1.5
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            print("wrote \(path)"); exit(0)
        }
        let store = Store(demo: demo)
        if week { store.period = .week }
        if CommandLine.arguments.contains("--rango") {
            let today = Calendar.current.startOfDay(for: Date())
            store.period = .range(Calendar.current.date(byAdding: .day, value: -29, to: today)!, today)
        }
        if CommandLine.arguments.contains("--menu-periodo") { PeriodMenu.snapshotOpen = true }
        if CommandLine.arguments.contains("--apps") { store.tab = .apps }
        if CommandLine.arguments.contains("--logros") { store.tab = .achievements; store.achievements.loadDemo() }
        if CommandLine.arguments.contains("--comunidad") {
            ProfileTab.snapshotCommunity = true
            store.community.loadDemo()
            if let i = CommandLine.arguments.firstIndex(of: "--miembro"), i + 1 < CommandLine.arguments.count {
                CommunityView.snapshotMember = Int(CommandLine.arguments[i + 1]) ?? 0
            }
        }
        if CommandLine.arguments.contains("--perfil") {
            store.tab = .profile
            store.album.loadDemo(); store.achievements.loadDemo()
            Posters.prefetchForSnapshot(arts: true)
        }
        if CommandLine.arguments.contains("--album") {
            store.tab = .album
            store.album.loadDemo(); store.achievements.loadDemo()
            Posters.prefetchForSnapshot(arts: true)
            func arg(_ name: String) -> String? {
                guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
                return CommandLine.arguments[i + 1]
            }
            if let s = arg("--section") { AlbumTab.snapshotSection = s }
            if let d = arg("--carta") { AlbumTab.snapshotDetail = d }
            if CommandLine.arguments.contains("--bienvenida") { AlbumTab.snapshotOnboarding = true }
            if let p = arg("--abrir") {
                PackOpening.snapshotStage = arg("--paso") ?? ""
                switch PackOpening.snapshotStage {
                case "girada", "variante": PackOpening.snapshotFlipped = [0, 1, 2]
                case "resumen": PackOpening.snapshotFlipped = Set(0..<pack(p).count)
                default: break
                }
                store.album.openFree(pack(p))
                if store.album.opening == nil { store.album.buy(pack(p)) }
            }
        }
        Task { @MainActor in
            await store.refresh()
            let view = WidgetView(store: store, snapshot: true)
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            } else {
                print("render failed")
            }
            if let e = store.error { print("error: \(e)") }
            exit(0)
        }
        RunLoop.main.run()
    }
}

// MARK: - Menu bar icon

/// The Filmo F in the menu bar, and the pause sign its three bars become while
/// DeskTime is not counting. Coordinates follow filmo-simbolo.svg (80 × 84).
enum StatusIcon {
    typealias Quad = [CGPoint]

    private static let f: [Quad] = [
        [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 72, y: 26), CGPoint(x: 0, y: 26)],
        [CGPoint(x: 0, y: 29), CGPoint(x: 58, y: 29), CGPoint(x: 50, y: 55), CGPoint(x: 0, y: 55)],
        [CGPoint(x: 0, y: 58), CGPoint(x: 30, y: 58), CGPoint(x: 22, y: 84), CGPoint(x: 0, y: 84)],
    ]
    /// The F with its bars cut short.
    private static let stub: [Quad] = [
        [CGPoint(x: 0, y: 0), CGPoint(x: 34, y: 0), CGPoint(x: 26, y: 26), CGPoint(x: 0, y: 26)],
        [CGPoint(x: 0, y: 29), CGPoint(x: 34, y: 29), CGPoint(x: 26, y: 55), CGPoint(x: 0, y: 55)],
        [CGPoint(x: 0, y: 58), CGPoint(x: 34, y: 58), CGPoint(x: 26, y: 84), CGPoint(x: 0, y: 84)],
    ]
    /// The stubs in place along the pause bars: top and bottom on the left, the middle on the right.
    private static let placed: [Quad] = [
        [CGPoint(x: 14, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 35.7, y: 26), CGPoint(x: 9.7, y: 26)],
        [CGPoint(x: 49.2, y: 29), CGPoint(x: 75.2, y: 29), CGPoint(x: 70.8, y: 55), CGPoint(x: 44.8, y: 55)],
        [CGPoint(x: 4.3, y: 58), CGPoint(x: 30.3, y: 58), CGPoint(x: 26, y: 84), CGPoint(x: 0, y: 84)],
    ]
    /// Two slanted bars; the top and bottom stubs stretch into the left one.
    private static let pause: [Quad] = {
        let left = [CGPoint(x: 14, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 26, y: 84), CGPoint(x: 0, y: 84)]
        let right = [CGPoint(x: 54, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 66, y: 84), CGPoint(x: 40, y: 84)]
        return [left, right, left]
    }()
    private static let keyframes = [f, stub, placed, pause]

    private static let size = NSSize(width: 15, height: 16)

    static func image(phase: CGFloat) -> NSImage {
        if phase <= 0, let png = AppInfo.symbol?.copy() as? NSImage {
            png.size = size
            return png
        }
        let img = NSImage(size: size, flipped: true) { rect in
            let s = min(rect.width / 80, rect.height / 84)
            let path = NSBezierPath()
            // The bars shrink, move into place, then stretch upright.
            let steps = CGFloat(keyframes.count - 1)
            let k = min(Int(phase * steps), keyframes.count - 2)
            let t = phase * steps - CGFloat(k)
            for (a, b) in zip(keyframes[k], keyframes[k + 1]) {
                for i in 0..<4 {
                    let p = CGPoint(x: (a[i].x + (b[i].x - a[i].x) * t) * s,
                                    y: (a[i].y + (b[i].y - a[i].y) * t) * s)
                    i == 0 ? path.move(to: p) : path.line(to: p)
                }
                path.close()
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = phase >= 1 ? "DeskTime en pausa" : AppInfo.name
        return img
    }
}
