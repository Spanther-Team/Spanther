import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The app's side of the backend (backend/README.md): sign-in by email and password through Supabase Auth, and the
// account's players, progress and plays through its REST API (PostgREST). Plain HTTP and JSON, no Supabase SDK.
// The app holds only the project's public key; the rows of other accounts are closed by the database's row level
// security, whatever the app sends.

// MARK: Where the backend is

/// The Supabase project: where its sign-in and its tables answer, and its public (anon or publishable) key.
/// Never the service_role key.
public struct BackendConfig: Equatable, Sendable {
    public let authURL: URL
    public let restURL: URL
    public let apiKey: String

    /// From the Project URL (https://<ref>.supabase.co) and the public key; nil while either is not set yet.
    public init?(projectURL: String, apiKey: String) {
        var text = projectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        self.init(authURL: url.appendingPathComponent("auth/v1"), restURL: url.appendingPathComponent("rest/v1"),
                  apiKey: key)
    }

    /// Sign-in and tables at their own addresses (a local test stack without the Supabase gateway).
    public init(authURL: URL, restURL: URL, apiKey: String) {
        self.authURL = authURL
        self.restURL = restURL
        self.apiKey = apiKey
    }
}

// MARK: Transport

public struct BackendRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct BackendResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// Sends one request. Throws only when no answer came (`BackendError.Reason.offline`); an answer with an error
/// status is returned as it is.
public protocol BackendTransport: Sendable {
    func send(_ request: BackendRequest) async throws -> BackendResponse
}

/// The phone's own HTTP, with no cookies or cache on disk.
public struct URLSessionTransport: BackendTransport {
    private static let session = URLSession(configuration: .ephemeral)
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public func send(_ request: BackendRequest) async throws -> BackendResponse {
        var r = URLRequest(url: request.url, timeoutInterval: timeout)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        return try await withCheckedThrowingContinuation { done in
            Self.session.dataTask(with: r) { data, response, error in
                if let error {
                    done.resume(throwing: BackendError(.offline, message: error.localizedDescription))
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    done.resume(returning: BackendResponse(status: status, body: data ?? Data()))
                }
            }.resume()
        }
    }
}

// MARK: Errors

public struct BackendError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: String, Equatable, Sendable {
        /// No network, or no answer in time.
        case offline
        /// No such email with this password.
        case wrongPassword
        /// Signed up, but the code from the email was not entered yet.
        case emailNotConfirmed
        case emailTaken
        case weakPassword
        case invalidEmail
        /// A wrong or expired code from the email.
        case badCode
        /// The new password is the old one.
        case samePassword
        case tooManyRequests
        /// The email could not be sent (the project's mail is not set up for this address).
        case mailFailed
        /// The sign-in is gone: signed out elsewhere, or the account was deleted.
        case signedOut
        /// The sign-in token ran out: refresh it and try again.
        case tokenExpired
        /// The server refused this data (a check or an access rule): sending it again will not help.
        case rejected
        case server
    }

    public let reason: Reason
    public let status: Int
    /// The server's own code (`invalid_credentials`, `23514`, ...), for the log.
    public let code: String
    public let message: String

    public init(_ reason: Reason, status: Int = 0, code: String = "", message: String = "") {
        self.reason = reason
        self.status = status
        self.code = code
        self.message = message
    }

    public var description: String { "\(reason.rawValue) (\(status) \(code)): \(message)" }

    /// Reads an error answer of Supabase Auth or of PostgREST.
    static func from(_ r: BackendResponse, rest: Bool) -> BackendError {
        let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let code = json["error_code"] as? String ?? json["code"] as? String ?? json["error"] as? String ?? ""
        let message = json["msg"] as? String ?? json["message"] as? String ?? json["error_description"] as? String
            ?? String(decoding: r.body.prefix(300), as: UTF8.self)
        let text = message.lowercased()
        let reason: Reason
        switch code {
        case "invalid_credentials":
            reason = .wrongPassword
        case "invalid_grant":
            reason = text.contains("not confirmed") ? .emailNotConfirmed
                : text.contains("refresh token") ? .signedOut : .wrongPassword
        case "email_not_confirmed":
            reason = .emailNotConfirmed
        case "user_already_exists", "email_exists":
            reason = .emailTaken
        case "weak_password":
            reason = .weakPassword
        case "email_address_invalid":
            reason = .invalidEmail
        case "validation_failed":
            reason = text.contains("email") ? .invalidEmail : .rejected
        case "otp_expired":
            reason = .badCode
        case "same_password":
            reason = .samePassword
        case "over_email_send_rate_limit", "over_request_rate_limit":
            reason = .tooManyRequests
        case "email_address_not_authorized":
            reason = .mailFailed
        case "bad_jwt":
            reason = .tokenExpired
        case "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired",
             "user_not_found", "user_banned", "no_authorization":
            reason = .signedOut
        default:
            switch r.status {
            case 429: reason = .tooManyRequests
            case 401: reason = rest ? .tokenExpired : .signedOut
            case 500...: reason = text.contains("email") && text.contains("send") ? .mailFailed : .server
            case 0: reason = .offline
            default: reason = .rejected
            }
        }
        return BackendError(reason, status: r.status, code: code, message: message)
    }
}

// MARK: The sign-in

/// A signed-in adult's tokens. Kept by the app in the Keychain, never in a plain file.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// By the phone's clock: the token's lifetime from when it came, so a wrong phone clock does not matter.
    public var expiresAt: Date
    public var userID: UUID
    public var email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }

    /// True a minute before the token runs out.
    public func expired(at now: Date) -> Bool { now.addingTimeInterval(60) >= expiresAt }
}

public enum SignUpResult: Equatable, Sendable {
    /// The code is in the email; `Backend.confirmSignUp` finishes.
    case codeSent
    /// The project does not ask to confirm emails: signed in at once.
    case signedIn(AuthSession)
}

/// The adult's account as the app sees it (accounts in the database).
public struct AccountRow: Decodable, Equatable, Sendable {
    public var id: UUID
    public var email: String?
    public var language: String
    public var role: String
    public var premiumUntil: Date?

    public init(id: UUID, email: String?, language: String, role: String, premiumUntil: Date?) {
        self.id = id
        self.email = email
        self.language = language
        self.role = role
        self.premiumUntil = premiumUntil
    }

    public var isAdmin: Bool { role == "admin" }
    public func premium(at now: Date) -> Bool { premiumUntil.map { $0 > now } ?? false }

    enum CodingKeys: String, CodingKey { case id, email, language, role, premiumUntil = "premium_until" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "ru"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        premiumUntil = try c.decodeIfPresent(String.self, forKey: .premiumUntil).flatMap(BackendDate.date)
    }
}

// MARK: Calls

/// Every call the app makes to the backend. Each data call takes the signed-in session; `SessionKeeper` keeps one
/// fresh.
public struct Backend: Sendable {
    public let config: BackendConfig
    let transport: BackendTransport

    public init(config: BackendConfig, transport: BackendTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    // MARK: Sign-in (Supabase Auth)

    /// A new account. `language` (ru, kk, en) picks the language of the emails with codes.
    public func signUp(email: String, password: String, language: String) async throws -> SignUpResult {
        let body: [String: Any] = ["email": Self.clean(email), "password": password, "data": ["lang": language]]
        let json = try await auth("POST", "signup", body)
        if json["access_token"] != nil { return .signedIn(try Self.session(json)) }
        // An email already confirmed: Auth answers with a stand-in user without identities, and sends nothing.
        let user = json["user"] as? [String: Any] ?? json
        if let identities = user["identities"] as? [Any], identities.isEmpty {
            throw BackendError(.emailTaken, status: 200, code: "user_already_exists", message: "email taken")
        }
        return .codeSent
    }

    /// The code from the sign-up email.
    public func confirmSignUp(email: String, code: String) async throws -> AuthSession {
        try Self.session(await auth("POST", "verify", ["type": "email", "email": Self.clean(email),
                                                       "token": Self.digits(code)]))
    }

    public func resendSignUpCode(email: String) async throws {
        _ = try await auth("POST", "resend", ["type": "signup", "email": Self.clean(email)])
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try Self.session(await auth("POST", "token", ["email": Self.clean(email), "password": password],
                                    query: [("grant_type", "password")]))
    }

    public func refresh(_ s: AuthSession) async throws -> AuthSession {
        try Self.session(await auth("POST", "token", ["refresh_token": s.refreshToken],
                                    query: [("grant_type", "refresh_token")]))
    }

    /// Sends a code for a new password. Auth answers the same whether or not the email has an account.
    public func sendPasswordCode(email: String) async throws {
        _ = try await auth("POST", "recover", ["email": Self.clean(email)])
    }

    /// The code from the password email signs in; `setPassword` then sets the new one.
    public func confirmPasswordCode(email: String, code: String) async throws -> AuthSession {
        try Self.session(await auth("POST", "verify", ["type": "recovery", "email": Self.clean(email),
                                                       "token": Self.digits(code)]))
    }

    public func setPassword(_ password: String, _ s: AuthSession) async throws {
        _ = try await auth("PUT", "user", ["password": password], token: s.accessToken)
    }

    /// The language of later emails with codes.
    public func setEmailLanguage(_ language: String, _ s: AuthSession) async throws {
        _ = try await auth("PUT", "user", ["data": ["lang": language]], token: s.accessToken)
    }

    /// Ends this phone's sign-in on the server too. Best effort: the phone forgets the tokens either way.
    public func signOut(_ s: AuthSession) async {
        _ = try? await auth("POST", "logout", [:], query: [("scope", "local")], token: s.accessToken)
    }

    // MARK: Data (PostgREST)

    public func account(_ s: AuthSession) async throws -> AccountRow {
        let data = try await rest("GET", "accounts", query: [("select", "id,email,language,role,premium_until"),
                                                            ("id", "eq.\(s.userID.uuidString.lowercased())")],
                                  session: s)
        guard let row = try Self.decoder.decode([AccountRow].self, from: data).first else {
            throw BackendError(.signedOut, status: 200, message: "no account")
        }
        return row
    }

    public func setLanguage(_ language: String, _ s: AuthSession) async throws {
        _ = try await rest("PATCH", "accounts", query: [("id", "eq.\(s.userID.uuidString.lowercased())")],
                           body: try JSONSerialization.data(withJSONObject: ["language": language]),
                           prefer: "return=minimal", session: s)
    }

    /// Every player of the account, the deleted ones too (as tombstones).
    public func pullProfiles(_ s: AuthSession) async throws -> [PlayerProfile] {
        let data = try await rest("GET", "profiles", query: [("select", ProfileRow.columns), ("order", "created_at.asc")],
                                  session: s)
        return try Self.decoder.decode([ProfileRow].self, from: data).map(\.profile)
    }

    /// Adds or updates players; the database merges each with its copy (backend/README.md).
    public func push(_ rows: [ProfileRow], _ s: AuthSession) async throws {
        guard !rows.isEmpty else { return }
        _ = try await rest("POST", "profiles", query: [("on_conflict", "id")], body: try Self.encoder.encode(rows),
                           prefer: "resolution=merge-duplicates,return=minimal", session: s)
    }

    /// Adds plays; one sent before (the same id) is left as it is.
    public func push(_ rows: [PlayRow], _ s: AuthSession) async throws {
        guard !rows.isEmpty else { return }
        _ = try await rest("POST", "plays", query: [("on_conflict", "id")], body: try Self.encoder.encode(rows),
                           prefer: "resolution=ignore-duplicates,return=minimal", session: s)
    }

    /// Deletes the signed-in account at once, with its players and plays (delete_my_account in the database).
    public func deleteAccount(_ s: AuthSession) async throws {
        _ = try await rest("POST", "rpc/delete_my_account", body: Data("{}".utf8), session: s)
    }

    // MARK: Plumbing

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder = JSONDecoder()

    static func clean(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    static func digits(_ code: String) -> String { String(code.filter(\.isASCII).filter(\.isNumber)) }

    private func auth(_ method: String, _ path: String, _ body: [String: Any], query: [(String, String)] = [],
                      token: String? = nil) async throws -> [String: Any] {
        var headers = ["apikey": config.apiKey, "Content-Type": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let r = try await send(BackendRequest(method: method, url: Self.url(config.authURL, path, query),
                                              headers: headers,
                                              body: try JSONSerialization.data(withJSONObject: body)))
        guard (200..<300).contains(r.status) else { throw BackendError.from(r, rest: false) }
        guard !r.body.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    private func rest(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
                      prefer: String? = nil, session: AuthSession) async throws -> Data {
        var headers = ["apikey": config.apiKey, "Authorization": "Bearer \(session.accessToken)",
                       "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let prefer { headers["Prefer"] = prefer }
        let r = try await send(BackendRequest(method: method, url: Self.url(config.restURL, path, query),
                                              headers: headers, body: body))
        guard (200..<300).contains(r.status) else { throw BackendError.from(r, rest: true) }
        return r.body
    }

    private func send(_ request: BackendRequest) async throws -> BackendResponse {
        do {
            return try await transport.send(request)
        } catch let e as BackendError {
            throw e
        } catch {
            throw BackendError(.offline, message: "\(error)")
        }
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,*")

    static func url(_ base: URL, _ path: String, _ query: [(String, String)]) -> URL {
        var url = base
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        guard !query.isEmpty else { return url }
        let q = query.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value)"
        }.joined(separator: "&")
        return URL(string: url.absoluteString + "?" + q) ?? url
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    static func session(_ json: [String: Any]) throws -> AuthSession {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let user = json["user"] as? [String: Any], let id = (user["id"] as? String).flatMap(UUID.init) else {
            throw BackendError(.server, status: 200, message: "no session in the answer")
        }
        let lifetime = number(json["expires_in"]) ?? 3600
        return AuthSession(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime),
                           userID: id, email: user["email"] as? String ?? "")
    }
}

// MARK: Keeping the session fresh

/// Holds the signed-in session for the data calls: refreshes it before it runs out, and once more when the server
/// says it ran out. A refresh the server refuses signs out (`saved(nil)`); no network keeps the session.
public actor SessionKeeper {
    public let backend: Backend
    public private(set) var session: AuthSession?
    private let saved: @Sendable (AuthSession?) -> Void
    private var refreshing: Task<AuthSession, Error>?
    private let now: @Sendable () -> Date

    public init(backend: Backend, session: AuthSession?, now: @escaping @Sendable () -> Date = { Date() },
                saved: @escaping @Sendable (AuthSession?) -> Void) {
        self.backend = backend
        self.session = session
        self.now = now
        self.saved = saved
    }

    public func set(_ s: AuthSession?) {
        refreshing = nil
        session = s
        saved(s)
    }

    /// Runs a call with a fresh session.
    public func call<T: Sendable>(_ f: @Sendable (Backend, AuthSession) async throws -> T) async throws -> T {
        var s = try await fresh()
        do {
            return try await f(backend, s)
        } catch let e as BackendError where e.reason == .tokenExpired {
            s = try await refresh(s)
            do {
                return try await f(backend, s)
            } catch let e as BackendError where e.reason == .tokenExpired {
                set(nil)
                throw BackendError(.signedOut, status: e.status, code: e.code, message: e.message)
            }
        } catch let e as BackendError where e.reason == .signedOut {
            set(nil)
            throw e
        }
    }

    private func fresh() async throws -> AuthSession {
        guard let s = session else { throw BackendError(.signedOut, message: "not signed in") }
        return s.expired(at: now()) ? try await refresh(s) : s
    }

    private func refresh(_ old: AuthSession) async throws -> AuthSession {
        if let refreshing { return try await refreshing.value }
        let backend = backend
        let task = Task { try await backend.refresh(old) }
        refreshing = task
        do {
            let s = try await task.value
            if refreshing == task { refreshing = nil }
            if session?.refreshToken == old.refreshToken { set(s) }
            return s
        } catch let e as BackendError {
            if refreshing == task { refreshing = nil }
            if e.reason == .signedOut || e.reason == .wrongPassword || e.reason == .rejected {
                set(nil)
                throw BackendError(.signedOut, status: e.status, code: e.code, message: e.message)
            }
            throw e
        }
    }
}

// MARK: Dates

/// Times as the backend keeps them: whole seconds in UTC out ("2026-11-27T09:00:00Z"); in, any ISO 8601 or
/// Postgres form ("2026-11-27 09:00:00.123456+00", "...+05:00").
public enum BackendDate {
    public static func whole(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970).rounded(.down))
    }

    public static func string(_ d: Date) -> String {
        let t = Int((d.timeIntervalSince1970).rounded(.down))
        let days = Int((Double(t) / 86400).rounded(.down))
        let rest = t - days * 86400
        let (y, m, day) = civil(days)
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let year = String(repeating: "0", count: max(0, 4 - String(y).count)) + String(y)
        return "\(year)-\(two(m))-\(two(day))T\(two(rest / 3600)):\(two(rest / 60 % 60)):\(two(rest % 60))Z"
    }

    public static func date(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ at: Int, _ len: Int) -> Int? {
            guard at >= 0, at + len <= u.count else { return nil }
            var v = 0
            for c in u[at..<(at + len)] {
                guard (48...57).contains(c) else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard u.count >= 19, let y = num(0, 4), u[4] == 45, let mo = num(5, 2), u[7] == 45, let d = num(8, 2),
              u[10] == 84 || u[10] == 116 || u[10] == 32, let h = num(11, 2), u[13] == 58, let mi = num(14, 2),
              u[16] == 58, let se = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi),
              (0...60).contains(se) else { return nil }
        var i = 19
        var fraction = 0.0
        if i < u.count, u[i] == 46 {
            i += 1
            var scale = 0.1
            let start = i
            while i < u.count, (48...57).contains(u[i]) {
                fraction += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        var offset = 0
        if i < u.count {
            if u[i] == 90 || u[i] == 122 {
                i += 1
            } else if u[i] == 43 || u[i] == 45 {
                let sign = u[i] == 45 ? -1 : 1
                guard let oh = num(i + 1, 2) else { return nil }
                i += 3
                var om = 0
                if i < u.count, u[i] == 58 { i += 1 }
                if let m = num(i, 2) {
                    om = m
                    i += 2
                }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        guard i == u.count else { return nil }
        let seconds = days(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 of a date in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
    static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
