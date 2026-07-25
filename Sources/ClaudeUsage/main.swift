import AppKit
import Foundation

// `ClaudeUsage --dump`: run credential discovery + one fetch, print the parsed
// snapshot to stdout, exit. For debugging without launching the UI.
// `ClaudeUsage --verify-persist`: read creds, write them back to the keychain
// unchanged, re-read, confirm the tokens survived. Verifies the write-back that
// keeps the token perpetually fresh.
if CommandLine.arguments.contains("--verify-persist") {
    guard let creds = CredentialStore.discover() else {
        print("FAIL: no credentials to test"); exit(1)
    }
    print("before: fields \(creds.raw.keys.sorted())")
    let ok = CredentialStore.persist(creds)
    print("persist() returned: \(ok)")
    guard let after = CredentialStore.discover() else {
        print("FAIL: credentials missing after write-back"); exit(2)
    }
    let preserved = after.accessToken == creds.accessToken
        && after.refreshToken == creds.refreshToken
    print("re-read: tokens preserved = \(preserved), fields \(after.raw.keys.sorted())")
    exit(ok && preserved ? 0 : 3)
}

if CommandLine.arguments.contains("--dump") {
    guard let creds = CredentialStore.discover() else {
        print("credentials: NOT FOUND")
        print("bundled CLI: \(CredentialStore.bundledCLIPath() ?? "not found")")
        exit(1)
    }
    print("credentials: found (subscription: \(creds.subscriptionType ?? "?"), " +
          "expires: \(creds.expiresAt.map { "\($0)" } ?? "?"))")

    let fetcher = UsageFetcher()
    fetcher.onUpdate = { state in
        switch state.phase {
        case .ok:
            for bucket in state.snapshot?.buckets ?? [] {
                let reset = bucket.resetsAt.map { " resets in \(UsageDecoder.countdown(to: $0))" } ?? ""
                print(String(format: "%-22s %5.1f%% used, %d%% left%@",
                             (bucket.label as NSString).utf8String!,
                             bucket.utilization, bucket.remainingPercent, reset))
            }
            exit(0)
        case .notSignedIn:
            print("phase: not signed in")
            exit(1)
        case .authError:
            print("phase: auth error (token expired and refresh failed)")
            exit(1)
        case .rateLimited(let retryAt):
            print("phase: rate limited until \(retryAt)")
            exit(1)
        case .networkError(let message):
            print("phase: network error — \(message)")
            exit(1)
        }
    }
    fetcher.start()
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
