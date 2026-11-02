import AppKit
import Charts
import ServiceManagement
import SwiftUI

import WidgetKit

// MARK: - Store

enum Tab: Hashable { case summary, apps, week, achievements }

@MainActor
final class Store: ObservableObject {
    @Published var date = Calendar.current.startOfDay(for: Date())
    @Published var tab: Tab = .summary
    @Published var day: DayData?
    /// Always today's data, whatever day the popover shows; drives the menu bar and the name.
    @Published var today: DayData?
    @Published var week: [WeekDay] = []
    @Published var loading = false
    @Published var error: String?
    @Published var lastUpdate: Date?
    @Published var hasKey = KeyStore.read() != nil
    /// Seconds since the last keyboard or mouse input; reading it needs no permission.
    @Published var idle: Double = 0

    let demo: Bool
    let achievements: Achievements
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var idleTimer: Timer?
    /// Keeps App Nap from stretching the timer of this window-less app.
    private var activity: NSObjectProtocol?
    /// Past days of the week never change, so each is fetched only once.
    private var knownDays: [String: WeekDay] = [:]

    init(demo: Bool) {
        self.demo = demo
        achievements = Achievements(persist: !demo && !isSnapshotRender)
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
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIdle() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // After a night asleep "today" has moved on.
                if !Calendar.current.isDateInToday(self.date) && self.lastUpdate.map(Calendar.current.isDateInToday) == false {
                    self.date = Calendar.current.startOfDay(for: Date())
                }
                await self.refresh()
            }
        }
    }

    func shift(_ days: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: days, to: date),
              d <= Date() else { return }
        date = d
        Task { await refresh() }
    }

    func goToday() {
        date = Calendar.current.startOfDay(for: Date())
        Task { await refresh() }
    }

    func open(_ d: Date) {
        date = d
        tab = .summary
        Task { await refresh() }
    }

    func refresh() async {
        if demo {
            day = Demo.day
            today = Demo.day
            week = Demo.week(around: date)
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
            achievements.evaluate(today: t, week: todayWeek)
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

    /// Roughly when DeskTime stops counting a computer nobody is using.
    static let idleThreshold: Double = 3 * 60

    private func pollIdle() {
        let wasPaused = paused
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if paused != wasPaused || paused { onChange?() }
    }

    /// DeskTime is not counting right now: no input for a while, or it reports being offline.
    var paused: Bool {
        guard !demo, let t = today, t.arrived != nil else { return false }
        return idle >= Self.idleThreshold || !t.isOnline
    }

    /// The idle stretch going on now that DeskTime's figures, which only run to its
    /// last update, do not include yet.
    var ongoingIdle: Double {
        guard let t = today, idle >= Self.idleThreshold else { return 0 }
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
                    IconButton(symbol: "chevron.left", help: "Día anterior", size: 16) { store.shift(-1) }
                    Text(Fmt.longDay(store.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    IconButton(symbol: "chevron.right", help: "Día siguiente", size: 16) { store.shift(1) }
                        .opacity(store.isToday ? 0.25 : 1)
                        .disabled(store.isToday)
                    if !store.isToday {
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

    private var tabBar: some View {
        HStack(spacing: 18) {
            ForEach([(Tab.summary, "Resumen"), (.apps, "Apps"), (.week, "Semana"), (.achievements, "Logros")], id: \.0) { tab, title in
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
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if let error = store.error, store.day == nil || !store.hasKey {
            ErrorCard(message: error, needsKey: !store.hasKey, openSettings: actions.openSettings)
                .padding(16)
        } else if let d = store.day {
            switch store.tab {
            case .summary: SummaryTab(day: d, store: store).padding(16).transition(.opacity)
            case .apps: AppsTab(day: d).transition(.opacity)
            case .week: WeekTab(store: store).padding(16).transition(.opacity)
            case .achievements: AchievementsTab(model: store.achievements).transition(.opacity)
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

            if let s = minutes(day.workStarts), let e = minutes(day.workEnds), e > s {
                WorkdayBar(day: day, start: s, end: e, isToday: store.isToday)
            }

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

struct WorkdayBar: View {
    let day: DayData
    let start: Double
    let end: Double
    let isToday: Bool

    var body: some View {
        let nowMin: Double = {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return Double(c.hour! * 60 + c.minute!)
        }()
        let from = minutes(day.arrived)
        let to: Double? = isToday && day.isOnline ? nowMin : minutes(day.left) ?? (isToday ? nowMin : nil)
        let lo = min(start, from ?? start), hi = max(end, to ?? end)
        let span = hi - lo

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label2(text: "Jornada")
                Spacer()
                Text("\(day.workStarts!) – \(day.workEnds!)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                let x = { (m: Double) in CGFloat((m - lo) / span) * g.size.width }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let f = from, let t = to, t > f {
                        Capsule().fill(Theme.brand).frame(width: max(x(t) - x(f), 4)).offset(x: x(f))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            HStack {
                Text(from != nil ? "Llegaste a las \(day.arrived!)" : "Sin actividad")
                Spacer()
                if isToday, nowMin < end {
                    Text("Quedan \(Fmt.duration((end - nowMin) * 60))")
                } else if let l = day.left, !(isToday && day.isOnline) {
                    Text("Saliste a las \(l)")
                }
            }
            .font(.system(size: 10))
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

struct WeekTab: View {
    @ObservedObject var store: Store
    @State private var hovered: Date?

    private var worked: [WeekDay] { store.week.filter { !$0.isFuture && $0.desktime > 0 } }

    var body: some View {
        if store.week.isEmpty {
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
        }
    }

    private var chart: some View {
        Chart(store.week) { d in
            BarMark(x: .value("Día", d.label), y: .value("Horas", d.productive / 3600))
                .foregroundStyle(Theme.brand.opacity(opacity(d)))
                .cornerRadius(3)
            // Stacked on top: the rest of the worked time (neutral and unproductive).
            BarMark(x: .value("Día", d.label), y: .value("Horas", max(d.desktime - d.productive, 0) / 3600))
                .foregroundStyle(Color.secondary.opacity(0.35 * opacity(d)))
                .cornerRadius(3)
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
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 10)) } }
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
        let focus = store.week.first { $0.date == hovered }
            ?? store.week.first { Calendar.current.isDate($0.date, inSameDayAs: store.date) }
        if let d = focus {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.longDay(d.date)).font(.system(size: 11, weight: .semibold))
                Text(d.isFuture ? "Todavía no ha llegado" : d.desktime == 0 ? "Sin actividad"
                     : "\(Fmt.duration(d.desktime)) trabajado · \(Fmt.duration(d.productive)) prod.")
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
        }
    }

    private func opacity(_ d: WeekDay) -> Double {
        if let h = hovered { return h == d.date ? 1 : 0.3 }
        return Calendar.current.isDate(d.date, inSameDayAs: store.date) ? 1 : 0.4
    }

    private func day(at p: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> WeekDay? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = p.x - geo[plot].origin.x
        guard let label: String = proxy.value(atX: x) else { return nil }
        return store.week.first { $0.label == label }
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
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                let p = min(CGFloat(Date().timeIntervalSince(start) / 0.4), 1)
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(2 - 2 * p, 2) / 2
                self.iconPhase = from + (to - from) * eased
                self.statusItem.button?.image = StatusIcon.image(phase: self.iconPhase)
                if p >= 1 { t.invalidate(); self.iconTimer = nil }
            }
        }
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
    func popoverDidClose(_ notification: Notification) {
        if settingsWindow == nil { NSApp.deactivate() }
    }
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
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
        let store = Store(demo: demo)
        if week { store.tab = .week }
        if CommandLine.arguments.contains("--apps") { store.tab = .apps }
        if CommandLine.arguments.contains("--logros") { store.tab = .achievements; store.achievements.loadDemo() }
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
