import Foundation

struct Credentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let subscriptionType: String?
    // Full decoded oauth dict, preserved so persist() round-trips unknown fields
    // (scopes, rateLimitTier, refreshTokenExpiresAt, …) without dropping them.
    var raw: [String: Any] = [:]

    // 15-minute margin: proactive refresh happens well before real expiry.
    func isNearExpiry(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 900
    }
}

enum CredentialStore {
    // Uses /usr/bin/security (stable Apple code signature) instead of linking
    // Security.framework: the keychain ACL prompt is attributed to the calling
    // binary's signature, and ours changes on every ad-hoc rebuild. With the
    // CLI, one "Always Allow" survives rebuilds.
    static func discover() -> Credentials? {
        let keychainQueries: [[String]] = [
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            ["find-generic-password", "-s", "Claude Code", "-w"],
        ]
        for args in keychainQueries {
            if let blob = runSecurity(args), let creds = parse(blob) { return creds }
        }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL),
           let blob = String(data: data, encoding: .utf8),
           let creds = parse(blob) {
            return creds
        }
        return nil
    }

    private static func runSecurity(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }

    private static func parse(_ blob: String) -> Credentials? {
        guard let data = blob.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            return nil
        }
        var expiresAt: Date?
        if let raw = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            // Stored as epoch milliseconds; guard against a seconds-based value.
            expiresAt = Date(timeIntervalSince1970: raw < 1e12 ? raw : raw / 1000)
        }
        return Credentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            raw: oauth
        )
    }

    // Write rotated credentials back to the same keychain item (same schema),
    // so the stored refresh token is never left invalid after a rotation.
    // Uses `security -i` with the command fed over STDIN so the secret never
    // appears in a process argument list.
    @discardableResult
    static func persist(_ creds: Credentials) -> Bool {
        guard !creds.raw.isEmpty,
              let blobData = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": creds.raw]),
              let blob = String(data: blobData, encoding: .utf8),
              !blob.contains("'") else {
            return false
        }
        let account = keychainAccount() ?? NSUserName()
        let command = "add-generic-password -U -s 'Claude Code-credentials' -a '\(account)' -w '\(blob)'\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        stdin.fileHandleForWriting.write(command.data(using: .utf8)!)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // The existing item's account attribute (needed to update the same item).
    private static func keychainAccount() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }
        // Line looks like:     "acct"<blob>="seongjun"
        for line in output.components(separatedBy: "\n") where line.contains("\"acct\"") {
            if let range = line.range(of: "=\"") {
                return String(line[range.upperBound...].dropLast(line.hasSuffix("\"") ? 1 : 0))
            }
        }
        return nil
    }

    // Path to the CLI bundled with the Claude desktop app (highest version wins),
    // used only for the "not signed in" setup instructions.
    static func bundledCLIPath() -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-vm")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return nil
        }
        let best = versions
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            .last
        guard let best else { return nil }
        let path = base.appendingPathComponent("\(best)/claude").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
