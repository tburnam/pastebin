import Combine
import Foundation

enum HistoryRetentionPeriod: Int, CaseIterable, Equatable, Identifiable {
    case days30
    case days60
    case days90
    case months6
    case year1
    case unlimited

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .days30:
            return "30d"
        case .days60:
            return "60d"
        case .days90:
            return "90d"
        case .months6:
            return "6m"
        case .year1:
            return "1yr"
        case .unlimited:
            return "Unlimited"
        }
    }

    var displayTitle: String {
        switch self {
        case .days30:
            return "30 days"
        case .days60:
            return "60 days"
        case .days90:
            return "90 days"
        case .months6:
            return "6 months"
        case .year1:
            return "1 year"
        case .unlimited:
            return "Unlimited"
        }
    }

    func cutoffDate(referenceDate: Date = Date()) -> Date? {
        let secondsPerDay: TimeInterval = 86_400
        let interval: TimeInterval?

        switch self {
        case .days30:
            interval = 30 * secondsPerDay
        case .days60:
            interval = 60 * secondsPerDay
        case .days90:
            interval = 90 * secondsPerDay
        case .months6:
            interval = 180 * secondsPerDay
        case .year1:
            interval = 365 * secondsPerDay
        case .unlimited:
            interval = nil
        }

        guard let interval else { return nil }
        return referenceDate.addingTimeInterval(-interval)
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published private(set) var retentionPeriod: HistoryRetentionPeriod

    var databasePath: String {
        guard let url = try? AppPaths.databaseURL() else {
            return "Unable to resolve database path"
        }
        return url.path
    }

    private let defaults = UserDefaults.standard
    private let retentionDefaultsKey = "pastebin.history.retention_period"

    private init() {
        if let savedValue = defaults.object(forKey: retentionDefaultsKey) as? Int,
           let savedPeriod = HistoryRetentionPeriod(rawValue: savedValue) {
            retentionPeriod = savedPeriod
        } else {
            retentionPeriod = .unlimited
        }
    }

    func updateRetentionPeriod(_ period: HistoryRetentionPeriod) {
        guard retentionPeriod != period else { return }
        retentionPeriod = period
        defaults.set(period.rawValue, forKey: retentionDefaultsKey)
    }
}
