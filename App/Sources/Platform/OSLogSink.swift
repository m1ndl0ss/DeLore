import DeLoreCore
import Foundation
import os

/// Unified-logging sink. Messages arrive already redacted, and are still marked private so
/// they never appear in sysdiagnoses or device logs pulled by someone else.
struct OSLogSink: LogSink {
    private let subsystem: String

    init(subsystem: String) {
        self.subsystem = subsystem
    }

    func write(level: LogLevel, category: String, message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info: logger.info("\(message, privacy: .private)")
        case .warning: logger.warning("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
    }
}

extension AppLogger {
    /// Release builds only keep warnings and errors; debug detail is compiled in but dropped.
    static func make(subsystem: String) -> AppLogger {
        #if DEBUG
        let minimum = LogLevel.debug
        #else
        let minimum = LogLevel.warning
        #endif
        return AppLogger(category: "app", sink: OSLogSink(subsystem: subsystem), minimumLevel: minimum)
    }
}
