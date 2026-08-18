// Credential lookup + vendor fetches. Tokens are read at fetch time and never
// stored or logged (same contract as dashboard.py).
import Foundation
import Security
import SQLite3

enum Providers {

    // MARK: - HTTP

    private static func request(_ req: URLRequest) async throws -> Data {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw FetchError.network(String(describing: type(of: error)))
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FetchError.auth("HTTP \(http.statusCode)")
            }
            throw FetchError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func getJSON(_ url: String, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await request(req)
    }

    private static func postJSON(_ url: String, headers: [String: String], body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await request(req)
    }

    // MARK: - Claude

    static func readClaudeToken() throws -> String {
        // Read via /usr/bin/security, NOT SecItemCopyMatching: Claude Code
        // writes this item through the security tool, so the item's ACL
        // trusts it — the raw Keychain API from our (foreign) app triggers
        // the password dialog on every poll, twice with "Always Allow"
        // (the ACL edit itself needs authorization). dashboard.py has polled
        // this way for weeks without a single prompt.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch {
            throw FetchError.auth("security tool failed to run")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else {
            throw FetchError.auth("keychain item missing")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else {
            throw FetchError.auth("keychain item malformed")
        }
        return tok
    }

    static func fetchClaude() async throws -> [String: Limit] {
        let tok = try readClaudeToken()
        let data = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                                     headers: ["Authorization": "Bearer \(tok)",
                                               "anthropic-beta": "oauth-2025-04-20"])
        return try parseClaude(data)
    }

    // MARK: - Codex

    static func readCodexCreds(path: URL? = nil) throws -> (token: String, account: String) {
        let url = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw FetchError.auth("auth.json missing")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let acct = tokens["account_id"] as? String, !acct.isEmpty else {
            throw FetchError.auth("auth.json missing access_token or account_id")
        }
        return (token, acct)
    }

    static func fetchCodex() async throws -> [String: Limit] {
        let (tok, acct) = try readCodexCreds()
        let data = try await getJSON("https://chatgpt.com/backend-api/codex/usage",
                                     headers: ["Authorization": "Bearer \(tok)",
                                               "chatgpt-account-id": acct,
                                               "User-Agent": "codex-cli"])
        return try parseCodex(data)
    }

    // MARK: - Cursor

    static let cursorDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    static func readCursorSession(dbPath: URL? = nil) throws -> (uid: String, token: String) {
        let path = (dbPath ?? cursorDB).path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FetchError.auth("cursor state.vscdb unreadable")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw FetchError.auth("cursor state.vscdb unreadable")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) else {
            throw FetchError.auth("cursor access token missing")
        }
        let tok = String(cString: cstr).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // uid comes from the JWT's sub claim ("provider|user_xxx").
        let parts = tok.split(separator: ".")
        guard parts.count >= 2, let claims = decodeBase64URLJSON(String(parts[1])),
              let sub = claims["sub"] as? String,
              let uid = sub.split(separator: "|").last.map(String.init), !uid.isEmpty else {
            throw FetchError.auth("cursor token is not a decodable JWT")
        }
        return (uid, tok)
    }

    private static func decodeBase64URLJSON(_ s: String) -> [String: Any]? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Gemini

    // gemini-cli's public OAuth client (shipped in its open source), used only
    // to refresh the user's own token from ~/.gemini/oauth_creds.json.
    private static let geminiClientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private static let geminiClientSecret = "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"

    static func readGeminiCreds() throws -> (refreshToken: String, projectID: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        guard let creds = (try? JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("oauth_creds.json")))) as? [String: Any],
              let refresh = creds["refresh_token"] as? String, !refresh.isEmpty else {
            throw FetchError.auth("gemini oauth_creds.json missing")
        }
        // projects.json maps workspace path -> project id; quota is per user,
        // so any project id works.
        guard let obj = (try? JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("projects.json")))) as? [String: Any],
              let projects = obj["projects"] as? [String: String],
              let pid = projects.values.first, !pid.isEmpty else {
            throw FetchError.auth("gemini projects.json missing — run gemini once")
        }
        return (refresh, pid)
    }

    private static func refreshGeminiToken(_ refreshToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: geminiClientID),
            URLQueryItem(name: "client_secret", value: geminiClientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        req.httpBody = comps.percentEncodedQuery.map { Data($0.utf8) }
        let data = try await request(req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tok = obj["access_token"] as? String, !tok.isEmpty else {
            throw FetchError.auth("gemini token refresh failed")
        }
        return tok
    }

    static func fetchGemini() async throws -> [String: Limit] {
        let (refresh, pid) = try readGeminiCreds()
        let tok = try await refreshGeminiToken(refresh)
        let data = try await postJSON("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
                                      headers: ["Authorization": "Bearer \(tok)"],
                                      body: ["project": pid])
        return try parseGemini(data)
    }

    // MARK: - Copilot

    static func readCopilotToken(path: URL? = nil) throws -> String {
        // apps.json maps host -> {oauth_token, ...}; quota is per user, any works.
        let url = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/github-copilot/apps.json")
        guard let data = try? Data(contentsOf: url),
              let apps = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.auth("copilot apps.json missing — sign into Copilot once")
        }
        for case let entry as [String: Any] in apps.values {
            if let tok = entry["oauth_token"] as? String, !tok.isEmpty { return tok }
        }
        throw FetchError.auth("copilot token missing — sign into Copilot once")
    }

    static func fetchCopilot() async throws -> [String: Limit] {
        let tok = try readCopilotToken()
        let data = try await getJSON("https://api.github.com/copilot_internal/user",
                                     headers: ["Authorization": "token \(tok)",
                                               "Editor-Version": "vscode/1.0",
                                               "User-Agent": "usage-dashboard"])
        return try parseCopilot(data)
    }

    // MARK: - Antigravity

    // Antigravity's quota lives behind its own signed-in creds, reachable only
    // through the bundled language server's local Connect-RPC port (see
    // docs/antigravity-usage-research.md). Ports and CSRF tokens change every
    // app launch, and a token from one PID can validate against another PID's
    // port — so discover both fresh each poll and cross-probe. `ps -x` (no -a)
    // lists only this user's processes, so a rogue language server owned by
    // another local user can't lure us into posting a real token to its port.
    private static let antigravityRPC =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    private static func runLines(_ path: String, _ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    static func discoverAntigravityServers() throws -> (ports: [Int], tokens: [String]) {
        var pids: [String] = [], tokens: [String] = []
        for line in runLines("/bin/ps", ["-xo", "pid=,args="])
        where line.contains("language_server_macos") {
            let parts = line.split(separator: " ").map(String.init)
            guard let pid = parts.first else { continue }
            pids.append(pid)
            if let i = parts.firstIndex(of: "--csrf_token"), i + 1 < parts.count {
                tokens.append(parts[i + 1])
            }
        }
        guard !pids.isEmpty else { throw FetchError.auth("antigravity not running") }
        var ports = Set<Int>()
        for pid in pids {
            for line in runLines("/usr/sbin/lsof",
                                 ["-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN"])
            where line.contains("LISTEN") {
                let fields = line.split(separator: " ")
                guard fields.count >= 2,
                      let port = fields[fields.count - 2].split(separator: ":").last
                          .flatMap({ Int($0) }) else { continue }
                ports.insert(port)
            }
        }
        guard !ports.isEmpty else { throw FetchError.auth("antigravity not running") }
        return (ports.sorted(), tokens)
    }

    static func fetchAntigravity() async throws -> [String: Limit] {
        let (ports, tokens) = try discoverAntigravityServers()
        var lastError = FetchError.auth("antigravity: no server answered")
        for port in ports {
            for token in tokens + [nil] {  // nil: the agy CLI server takes no token
                var headers = ["Connect-Protocol-Version": "1"]
                if let token { headers["X-Codeium-Csrf-Token"] = token }
                do {
                    let data = try await postJSON("http://127.0.0.1:\(port)\(antigravityRPC)",
                                                  headers: headers, body: [:])
                    return try parseAntigravity(data)
                } catch let err as FetchError {
                    lastError = err
                }
            }
        }
        throw lastError
    }

    static func fetchCursor() async throws -> [String: Limit] {
        let (uid, tok) = try readCursorSession()
        let data = try await postJSON("https://cursor.com/api/dashboard/get-current-period-usage",
                                      headers: ["Cookie": "WorkosCursorSessionToken=\(uid)%3A%3A\(tok)",
                                                "Origin": "https://cursor.com",
                                                "User-Agent": "Mozilla/5.0"],
                                      body: [:])
        return try parseCursor(data)
    }
}
