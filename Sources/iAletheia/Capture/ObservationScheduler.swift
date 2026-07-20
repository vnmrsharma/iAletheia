import Foundation

final class ScreenChangeDetector {
    private var lastFingerprint: String?

    func score(for text: String, title: String?, url: String?) -> Double {
        let fingerprint = [title ?? "", url ?? "", String(text.prefix(500))].joined(separator: "|")
        defer { lastFingerprint = fingerprint }
        guard let lastFingerprint else { return 1.0 }
        if fingerprint == lastFingerprint { return 0.0 }
        let similarity = Double(commonPrefix(lastFingerprint, fingerprint).count) / Double(max(lastFingerprint.count, fingerprint.count))
        return max(0.05, 1.0 - similarity)
    }

    private func commonPrefix(_ a: String, _ b: String) -> Substring {
        let zipped = zip(a, b)
        var count = 0
        for (left, right) in zipped where left == right {
            count += 1
        }
        return a.prefix(count)
    }
}

final class ObservationScheduler {
    private let detector = ScreenChangeDetector()
    private var lastCaptureAt: Date?
    private var lastURL: String?
    private var lastApp: String?
    private var lastTitle: String?

    func events(manualTrigger: AsyncStream<ObservationTriggerEvent>) -> AsyncStream<ObservationTriggerEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await manual in manualTrigger {
                    continuation.yield(manual)
                }
            }
            let timerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    continuation.yield(.periodic)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                timerTask.cancel()
            }
        }
    }

    func shouldCapture(context: ActiveApplicationContext, browser: BrowserMetadata, changeScore: Double, manual: Bool) -> ObservationTriggerEvent? {
        if manual { return .manual(userInitiated: true) }
        if context.bundleID != lastApp {
            lastApp = context.bundleID
            return .appChanged
        }
        if context.windowTitle != lastTitle {
            lastTitle = context.windowTitle
            return .windowChanged
        }
        if browser.url != lastURL {
            lastURL = browser.url
            return .urlChanged
        }
        if changeScore > 0.35 {
            if let lastCaptureAt, Date().timeIntervalSince(lastCaptureAt) < AdmissionConfig.observationCooldownSeconds {
                return nil
            }
            lastCaptureAt = Date()
            return .periodic
        }
        return nil
    }
}
