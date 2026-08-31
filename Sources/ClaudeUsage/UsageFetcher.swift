import Foundation

enum FetchPhase: Equatable {
    case ok
    case notSignedIn
    case authError
    case rateLimited(retryAt: Date)
    case networkError(String)
}

struct AppState {
    var snapshot: Snapshot?
    var phase: FetchPhase = .notSignedIn

    var isStale: Bool { snapshot?.isStale() ?? false }
}

final class UsageFetcher {
    static let baseInterval: TimeInterval = 90
    static let maxInterval: TimeInterval = 900

    private(set) var state = AppState()
    var onUpdate: ((AppState) -> Void)?

    private var credentials: Credentials?
    private var currentInterval: TimeInterval = UsageFetcher.baseInterval
    private var timer: Timer?
    private var lastFetchAt: Date?
    private var inFlight = false
    private let session = URLSession(configuration: .ephemeral)
    private let userAgent: String

    init() {
        let version = CredentialStore.bundledCLIPath()
            .flatMap { $0.components(separatedBy: "/claude-code-vm/").last?.components(separatedBy: "/").first }
            ?? "2.1.209"
        userAgent = "claude-code/\(version) (external, cli)"
        state.snapshot = SnapshotCache.load()
    }

    func start() {
        fetch()
    }

    // Menu-open refresh, throttled so reopening the menu can't hammer the API.
    func refreshIfDue(minimumGap: TimeInterval = 10) {
        guard !inFlight else { return }
        if let last = lastFetchAt, Date().timeIntervalSince(last) < minimumGap { return }
        fetch()
    }

    func refreshNow() {
        guard !inFlight else { return }
        fetch()
    }

    private func scheduleNext(after interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetch()
        }
        t.tolerance = min(15, interval / 6)
        timer = t
    }

    // The widget can't refresh the token itself (that endpoint hard-rate-limits
    // this credential). Instead it re-reads the Keychain, and when the token is
    // missing / expired / near expiry it KICKS the `relogin` LaunchAgent, which
    // re-logs-in via the desktop session. The widget only polls while the Mac is
    // awake — exactly when `auth login` completes quickly — so this is event-
    // driven off real expiry rather than a blind timer. Kicks are throttled.
    private func ensureFreshToken(_ completion: @escaping (String?) -> Void) {
        if credentials == nil || credentials!.isNearExpiry() {
            credentials = CredentialStore.discover()   // relogin may have just refreshed it
        }
        if credentials == nil || credentials!.isNearExpiry() {
            kickReloginIfDue()
        }
        completion(credentials?.accessToken)
    }

    // Ask launchd to run the relogin job now, with -k so a STUCK/hung login is
    // force-restarted (a wedged relogin job otherwise blocks every future run —
    // that once froze the widget on stale data for days). The relogin script has
    // its own 90s timeout, so -k rarely interrupts a healthy login. Fire-and-
    // forget — the fresh token lands in the Keychain and a later poll picks it up.
    private var lastReloginKickAt: Date?
    private func kickReloginIfDue(minimumGap: TimeInterval = 300) {
        if let last = lastReloginKickAt, Date().timeIntervalSince(last) < minimumGap { return }
        lastReloginKickAt = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/com.seongjun.claudeusage.relogin"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    private func fetch(isRetryAfterAuthRecovery: Bool = false) {
        ensureFreshToken { [weak self] token in
            self?.fetchUsage(token: token, isRetryAfterAuthRecovery: isRetryAfterAuthRecovery)
        }
    }

    private func fetchUsage(token: String?, isRetryAfterAuthRecovery: Bool) {
        guard let token else {
            state.phase = .notSignedIn
            notifyAndSchedule(after: currentInterval)
            return
        }
        inFlight = true
        lastFetchAt = Date()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(data: data, response: response, error: error,
                                     isRetryAfterAuthRecovery: isRetryAfterAuthRecovery)
            }
        }.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?,
                                isRetryAfterAuthRecovery: Bool) {
        inFlight = false

        if let error {
            state.phase = .networkError(error.localizedDescription)
            backOffAndNotify()
            return
        }
        guard let http = response as? HTTPURLResponse else {
            state.phase = .networkError("No response")
            backOffAndNotify()
            return
        }

        switch http.statusCode {
        case 200:
            let buckets = UsageDecoder.decode(data ?? Data())
            if buckets.isEmpty {
                state.phase = .networkError("Unexpected response format")
                backOffAndNotify()
                return
            }
            let snapshot = Snapshot(buckets: buckets, fetchedAt: Date())
            state.snapshot = snapshot
            state.phase = .ok
            SnapshotCache.save(snapshot)
            currentInterval = Self.baseInterval
            notifyAndSchedule(after: currentInterval)

        case 401, 403:
            if isRetryAfterAuthRecovery {
                state.phase = .authError
                backOffAndNotify()
            } else {
                recoverAuthThenRetry()
            }

        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            let wait = max(retryAfter ?? nextBackoffInterval(), 60)
            currentInterval = min(wait, Self.maxInterval)
            state.phase = .rateLimited(retryAt: Date().addingTimeInterval(currentInterval))
            notifyAndSchedule(after: currentInterval)

        default:
            state.phase = .networkError("HTTP \(http.statusCode)")
            backOffAndNotify()
        }
    }

    // After a 401 the stored token is stale. Re-read the Keychain (the relogin
    // agent may have just written a fresh one) and retry once; otherwise kick a
    // relogin and surface auth-error while the widget keeps showing cached data.
    private func recoverAuthThenRetry() {
        let previousToken = credentials?.accessToken
        credentials = CredentialStore.discover()
        if let creds = credentials, creds.accessToken != previousToken {
            fetch(isRetryAfterAuthRecovery: true)   // a newer token appeared in the Keychain
            return
        }
        kickReloginIfDue()
        state.phase = .authError
        backOffAndNotify()
    }

    private func nextBackoffInterval() -> TimeInterval {
        min(currentInterval * 2, Self.maxInterval)
    }

    private func backOffAndNotify() {
        currentInterval = nextBackoffInterval()
        notifyAndSchedule(after: currentInterval)
    }

    private func notifyAndSchedule(after interval: TimeInterval) {
        onUpdate?(state)
        scheduleNext(after: interval)
    }
}
