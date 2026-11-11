import Foundation
import ScreenpunkCore

/// Local diagnostic for a staging Debug run. The schema has no payload or free-text fields.
@MainActor enum RequestTimeline {
    enum Event: String, Encodable {
        case launch
        case preflightStart, preflightEnd
        case submitStart, submitEnd, submitAccepted
        case socketInitial, socketStatusChanged, socketDisconnected
        case httpStatusStart, httpStatusEnd
        case httpTransportStart, httpTransportEnd
        case reconcileStart, reconcileEnd
        case applyStart, applyEnd
        case acknowledgementStart, acknowledgementEnd
    }

    enum Operation: String, Encodable {
        case status, submit, reconcile, acknowledgement
    }

    private struct Entry: Encodable {
        let event: Event
        let requestID: UUID?
        let wallClockMilliseconds: Int64
        let elapsedMilliseconds: UInt64
        let httpStatus: Int?
        let operation: Operation?
    }

    static func record(_ event: Event, requestID: String? = nil, httpStatus: Int? = nil, operation: Operation? = nil) {
#if DEBUG
        guard CloudClient.originScope.canonicalOrigin == CloudOriginScope.legacyStagingOrigin,
              let session else { return }
        let id = requestID.flatMap(UUID.init(uuidString:))
        guard requestID == nil || id != nil else { return }
        session.append(event, requestID: id, httpStatus: httpStatus, operation: operation,
                       uptime: DispatchTime.now().uptimeNanoseconds, wallClock: Date())
#endif
    }

#if DEBUG
    private static let session: Session? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return Session(url: caches.appendingPathComponent("screenpunk-request-timeline.ndjson"),
                       uptime: DispatchTime.now().uptimeNanoseconds)
    }()

    final class Session {
        private static let limit = 256 * 1024
        private static let windowMilliseconds: UInt64 = 30 * 60 * 1_000
        private let start: UInt64
        private let file: FileHandle
        private let encoder = JSONEncoder()
        private var byteCount = 0
        private var requestStartedAt: UInt64?
        private var recordedLaunch = false
        private var recordedInitialSocket = false

        init?(url: URL, uptime: UInt64) {
            start = uptime
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: [.atomic, .completeFileProtection])
                file = try FileHandle(forWritingTo: url)
            } catch { return nil }
        }

        func append(_ event: Event, requestID: UUID?, httpStatus: Int?, operation: Operation? = nil, uptime: UInt64, wallClock: Date) {
            guard uptime >= start, byteCount < Self.limit else { return }
            if requestStartedAt == nil, event == .preflightStart { requestStartedAt = uptime }
            if let requestStartedAt {
                guard uptime >= requestStartedAt,
                      (uptime - requestStartedAt) / 1_000_000 < Self.windowMilliseconds else { return }
            } else {
                // Waiting for the user's first request must not consume its capture
                // window or fill the file with unrelated connection activity.
                switch event {
                case .launch where !recordedLaunch: recordedLaunch = true
                case .socketInitial where !recordedInitialSocket: recordedInitialSocket = true
                default: return
                }
            }
            let elapsed = (uptime - start) / 1_000_000
            let entry = Entry(event: event, requestID: requestStartedAt == nil ? nil : requestID,
                              wallClockMilliseconds: Int64(wallClock.timeIntervalSince1970 * 1_000),
                              elapsedMilliseconds: elapsed, httpStatus: httpStatus, operation: operation)
            guard var bytes = try? encoder.encode(entry), bytes.count + 1 <= Self.limit - byteCount else { return }
            bytes.append(0x0A)
            do {
                try file.write(contentsOf: bytes)
                byteCount += bytes.count
            } catch {
                // Disable this session after a write failure, including a partial write.
                byteCount = Self.limit
            }
        }
    }
#endif
}
