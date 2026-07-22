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
    // Access token from our own refresh, kept in memory only — never written
    // back to the keychain, so we can't clobber Claude Code's stored state.
    private var refreshedAccessToken: String?
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

    private func activeToken() -> String? {
        if credentials == nil || credentials!.isNearExpiry() {
            credentials = CredentialStore.discover()
            refreshedAccessToken = nil
        }
        return refreshedAccessToken ?? credentials?.accessToken
    }

    private func fetch(isRetryAfterAuthRecovery: Bool = false) {
        guard let token = activeToken() else {
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

    // Primary recovery: re-read the credential store (Claude Code refreshes
    // tokens itself and rewrites the keychain). Fallback: refresh the token
    // ourselves with the stored refresh token.
    private func recoverAuthThenRetry() {
        refreshedAccessToken = nil
        let previousToken = credentials?.accessToken
        credentials = CredentialStore.discover()
        if let creds = credentials, creds.accessToken != previousToken {
            fetch(isRetryAfterAuthRecovery: true)
            return
        }
        guard let refreshToken = credentials?.refreshToken else {
            state.phase = .authError
            backOffAndNotify()
            return
        }
        refreshAccessToken(refreshToken: refreshToken) { [weak self] newToken in
            guard let self else { return }
            if let newToken {
                self.refreshedAccessToken = newToken
                self.fetch(isRetryAfterAuthRecovery: true)
            } else {
                self.state.phase = .authError
                self.backOffAndNotify()
            }
        }
    }

    private func refreshAccessToken(refreshToken: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        session.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let token = json["access_token"] as? String else {
                    completion(nil)
                    return
                }
                completion(token)
            }
        }.resume()
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
