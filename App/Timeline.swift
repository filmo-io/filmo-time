import SwiftUI

/// DeskTime gives the day's totals, not when each thing happened. The app notes those totals at
/// every refresh, and the day is read back from how they grew between one note and the next.
@MainActor
enum WorkTimeline {
    enum Kind: Int, CaseIterable {
        case productive, neutral, unproductive, inactive

        var name: String { ["Productivo", "Neutral", "Improductivo", "Inactivo"][rawValue] }
        var color: Color { [Theme.brand, Color.primary.opacity(0.3), Theme.red, Theme.orange][rawValue] }
    }

    /// Totals so far, in seconds, at `t` minutes after the midnight of the day you arrived.
    struct Sample: Codable {
        var t: Double
        var p: Double
        var n: Double
        var u: Double
    }

    /// A stretch of the day, in minutes after that same midnight, and the seconds of each kind in it.
    struct Column: Equatable {
        var from: Double
        var to: Double
        var p: Double
        var n: Double
        var u: Double
        /// A long stretch without notes (the app was not running): the amounts are right, but
        /// they are spread evenly because nobody saw when they happened.
        var loose = false

        var seconds: [Double] { [p, n, u] }
        /// Part of the stretch with activity, 0 to 1.
        var active: Double { min((p + n + u) / max((to - from) * 60, 1), 1) }
    }

    private static let url = KeyStore.fileURL.deletingLastPathComponent().appendingPathComponent("timeline.json")
    private static let keptDays = 21
    /// Notes come every five minutes; a gap longer than this, in seconds, has no real order inside.
    private static let looseAfter: Double = 12 * 60
    private static var days: [String: [Sample]] = {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) } ?? [:]
    }()

    static func record(_ d: DayData, now: Date = Date()) {
        guard let key = d.arrivedDay, d.arrived != nil, let t = elapsed(since: key, to: now) else { return }
        var list = days[key] ?? []
        if let last = list.last, t < last.t + 0.5 { return }
        list.append(Sample(t: t, p: d.productive, n: d.neutralTime, u: d.unproductiveTime))
        days[key] = list
        for old in days.keys.sorted().dropLast(keptDays) { days[old] = nil }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    private static func elapsed(since day: String, to now: Date) -> Double? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day).map { now.timeIntervalSince($0) / 60 }
    }

    static func samples(for d: DayData) -> [Sample] { d.arrivedDay.flatMap { days[$0] } ?? [] }

    /// A day's columns from its arrival until `to` minutes (or until it left), for the achievements.
    static func columns(for d: DayData, to: Double?, open: Bool) -> [Column] {
        guard let from = minutes(d.arrived), var end = to ?? minutes(d.left) else { return [] }
        if end < from { end += 1440 }
        guard end > from else { return [] }
        return columns(samples(for: d), totals: Sample(t: end, p: d.productive, n: d.neutralTime, u: d.unproductiveTime),
                       from: from, to: end, open: open)
    }

    /// The day in order: one column per gap between two notes (five minutes while the app is
    /// running), like DeskTime's own productivity bar. `open` leaves out the time after the last
    /// known total: it is still happening.
    static func columns(_ samples: [Sample], totals: Sample, from: Double, to: Double, open: Bool) -> [Column] {
        var out: [Column] = []
        func add(_ a: Sample, _ b: Sample) {
            let length = (b.t - a.t) * 60
            guard length > 30 else { return }
            let grown = [max(b.p - a.p, 0), max(b.n - a.n, 0), max(b.u - a.u, 0)]
            let scale = min(1, length / max(grown.reduce(0, +), 1))
            out.append(Column(from: a.t, to: b.t, p: grown[0] * scale, n: grown[1] * scale, u: grown[2] * scale,
                              loose: length > looseAfter))
        }
        var previous = Sample(t: from, p: 0, n: 0, u: 0)
        for s in samples.sorted(by: { $0.t < $1.t }) where s.t > from && s.t <= to {
            add(previous, s)
            previous = s
        }
        if !open || samples.isEmpty {
            add(previous, Sample(t: to, p: max(totals.p, previous.p), n: max(totals.n, previous.n), u: max(totals.u, previous.u)))
        }
        return out
    }

    /// A believable afternoon for the screenshots.
    static func demo(from: Double, to: Double) -> [Sample] {
        let pattern: [(Double, Double, Double)] = [(300, 0, 0), (300, 0, 0), (240, 60, 0), (300, 0, 0), (0, 0, 0), (0, 0, 0),
                                                   (300, 0, 0), (120, 0, 180), (300, 0, 0), (0, 300, 0), (300, 0, 0), (60, 0, 0)]
        var s = Sample(t: from, p: 0, n: 0, u: 0), out: [Sample] = []
        var i = 0
        while s.t + 5 <= to {
            let step = pattern[i % pattern.count]
            s = Sample(t: s.t + 5, p: s.p + step.0, n: s.n + step.1, u: s.u + step.2)
            out.append(s)
            i += 1
        }
        return out
    }
}

// MARK: - Reading the day

extension Array where Element == WorkTimeline.Column {
    /// A whole hour away from the keyboard between 15:00 and 17:00, having worked before and after it.
    var hadSiesta: Bool {
        let window = 900.0...1020.0
        var idle = 0.0, end = 0.0, found = false
        for c in self where c.to > window.lowerBound && c.from < window.upperBound {
            // A stretch nobody watched is not a nap.
            if c.loose || c.seconds.reduce(0, +) >= 10 { idle = 0; continue }
            idle += Swift.min(c.to, window.upperBound) - Swift.max(c.from, window.lowerBound)
            if idle >= 60 { found = true; end = c.to }
        }
        guard found else { return false }
        let worked = { (c: WorkTimeline.Column) in c.seconds.reduce(0, +) >= 60 }
        return contains { $0.to <= window.lowerBound && worked($0) } && contains { $0.from >= end && worked($0) }
    }

    /// Work blocks of about 25 minutes in a row, each followed by a short break. Four make a Pomodoro session.
    var pomodoros: Int {
        // Runs of work and rest, in minutes; anything in between, or unwatched, breaks the chain.
        var runs: [(work: Bool?, minutes: Double)] = []
        for c in self {
            let kind: Bool? = c.loose ? nil : c.active >= 0.6 ? true : c.active <= 0.15 ? false : nil
            if let last = runs.last, last.work == kind, kind != nil {
                runs[runs.count - 1].minutes += c.to - c.from
            } else {
                runs.append((kind, c.to - c.from))
            }
        }
        var best = 0, chain = 0
        for (i, r) in runs.enumerated() {
            guard r.work == true, (18...35).contains(r.minutes) else { if r.work != false { chain = 0 }; continue }
            let rested = i >= 2 && runs[i - 1].work == false && (3...12).contains(runs[i - 1].minutes) && runs[i - 2].work == true
            chain = rested && chain > 0 ? chain + 1 : 1
            best = Swift.max(best, chain)
        }
        return best
    }
}

extension Array where Element == WorkTimeline.Sample {
    /// Productivity around 13:00, 0 to 100, once at least an hour had been tracked by then.
    var middayProductivity: Double? {
        guard let s = filter({ (750...810).contains($0.t) }).min(by: { abs($0.t - 780) < abs($1.t - 780) }) else { return nil }
        let tracked = s.p + s.n + s.u
        return tracked >= 3600 ? s.p / tracked * 100 : nil
    }
}
