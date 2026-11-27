import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GazeCore

// The app's sign-in and sync (GazeCore Backend, SessionKeeper, ProfileSync) against a real Supabase Auth, PostgREST
// and mailbox: backend/test/e2e.sh runs it next to them in Docker. The first check that fails stops the run.

let env = ProcessInfo.processInfo.environment
let authURL = URL(string: env["AUTH_URL"] ?? "http://gotrue:9999")!
let restURL = URL(string: env["REST_URL"] ?? "http://rest:3000")!
let mailURL = URL(string: env["MAIL_URL"] ?? "http://mailpit:8025")!
let net = URLSessionTransport(timeout: 15)
let backend = Backend(config: BackendConfig(authURL: authURL, restURL: restURL, apiKey: "local-anon-key"),
                      transport: net)

struct Failed: Error, CustomStringConvertible { let description: String }

func check(_ ok: Bool, _ what: String) throws {
    guard ok else { throw Failed(description: what) }
    print("ok   \(what)")
}

func expect(_ reason: BackendError.Reason, _ what: String, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let e as BackendError {
        try check(e.reason == reason, "\(what): \(e.reason.rawValue) (\(e.status) \(e.code))")
        return
    }
    throw Failed(description: "\(what): no error")
}

func get(_ url: URL, token: String? = nil) async throws -> (status: Int, json: Any?) {
    var headers = ["apikey": "local-anon-key"]
    if let token { headers["Authorization"] = "Bearer \(token)" }
    let r = try await net.send(BackendRequest(method: "GET", url: url, headers: headers))
    return (r.status, try? JSONSerialization.jsonObject(with: r.body))
}

func waitFor(_ url: URL) async throws {
    for _ in 0..<90 {
        if let r = try? await get(url), r.status < 500 { return }
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    throw Failed(description: "\(url) did not answer")
}

// MARK: The mailbox

func mails(to email: String) async throws -> [[String: Any]] {
    var c = URLComponents(url: mailURL.appendingPathComponent("api/v1/search"), resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "query", value: "to:\(email)")]
    let r = try await get(c.url!)
    return (r.json as? [String: Any])?["messages"] as? [[String: Any]] ?? []
}

/// Waits for a new email to `email` after `before` of them, checks it speaks `phrase`, and reads its code.
func code(to email: String, after before: Int, saying phrase: String) async throws -> String {
    for _ in 0..<30 {
        let all = try await mails(to: email)
        if all.count > before, let id = all.first?["ID"] as? String {
            let m = try await get(mailURL.appendingPathComponent("api/v1/message/\(id)"))
            let html = (m.json as? [String: Any])?["HTML"] as? String ?? ""
            try check(html.contains(phrase), "the email to \(email) says «\(phrase)»")
            let digits = Array(html)
            for i in 0..<max(0, digits.count - 5) where (i..<i + 6).allSatisfy({ digits[$0].isASCII && digits[$0].isNumber })
                && (i == 0 || !digits[i - 1].isNumber) && (i + 6 == digits.count || !digits[i + 6].isNumber) {
                return String(digits[i..<i + 6])
            }
            throw Failed(description: "no code in the email to \(email)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw Failed(description: "no email to \(email)")
}

// MARK: A phone

/// One phone's players, sync state and plays waiting, synced the way the app's AccountModel does.
struct Phone {
    var book = ProfileBook()
    var state = ProfileSyncState()
    var plays = PlayQueue()

    var rows: [ProfileRow] { book.profiles.map(ProfileRow.init).sorted { $0.id.uuidString < $1.id.uuidString } }

    @discardableResult
    mutating func sync(_ keeper: SessionKeeper) async throws -> (refusedPlayers: Int, refusedPlays: Int) {
        let account = try await keeper.call { b, s in try await b.account(s) }
        let server = try await keeper.call { b, s in try await b.pullProfiles(s) }
        _ = ProfileSync.takeIn(server, account: account.id, book: &book, state: &state, played: plays.players)
        let rows = ProfileSync.toSend(book, server: server)
        let sent = try await ProfileSync.send(rows) { batch in try await keeper.call { b, s in try await b.push(batch, s) } }
        ProfileSync.sent(sent.sent, state: &state)
        let ready = plays.ready(for: state.synced)
        let played = try await ProfileSync.send(ready) { batch in try await keeper.call { b, s in try await b.push(batch, s) } }
        plays.remove(Set((played.sent + played.refused).map(\.id)))
        return (sent.refused.count, played.refused.count)
    }
}

func keeper(_ s: AuthSession) -> SessionKeeper { SessionKeeper(backend: backend, session: s, saved: { _ in }) }

// MARK: The run

func run() async throws {
    try await waitFor(authURL.appendingPathComponent("health"))
    try await waitFor(restURL)
    let t0 = Date(timeIntervalSince1970: 1_795_770_000)
    let a = "aziz@e2e.example.com", b = "alnur@e2e.example.com"

    // Sign-up: the code comes in the email, in the language picked.
    try check(try await backend.signUp(email: a, password: "first-password", language: "kk") == .codeSent,
              "sign-up waits for the code")
    let code1 = try await code(to: a, after: 0, saying: "поштаны растау")
    await expectQuietly(.emailNotConfirmed, "signing in before the code") {
        _ = try await backend.signIn(email: a, password: "first-password")
    }
    try await expect(.badCode, "a wrong code") {
        _ = try await backend.confirmSignUp(email: a, code: code1 == "000000" ? "111111" : "000000")
    }
    let a1 = try await backend.confirmSignUp(email: a, code: code1)
    try check(a1.email == a && !a1.refreshToken.isEmpty, "the code signs in")
    try await expect(.emailTaken, "signing up again on the same email") {
        _ = try await backend.signUp(email: a, password: "another-password", language: "ru")
    }
    try await expect(.weakPassword, "a short password") {
        _ = try await backend.signUp(email: "short@e2e.example.com", password: "1234", language: "ru")
    }
    try await expect(.invalidEmail, "an email that is not one") {
        _ = try await backend.signUp(email: "not an email", password: "long-enough-1", language: "ru")
    }

    // The account row: made by the trigger, with the email copied; the owner sets the language.
    let k1 = keeper(a1)
    var account = try await k1.call { b, s in try await b.account(s) }
    try check(account.id == a1.userID && account.email == a && account.role == "user" && !account.isAdmin
              && account.premiumUntil == nil, "the account has the email, role user, no premium")
    try await k1.call { b, s in try await b.setLanguage("kk", s) }
    account = try await k1.call { b, s in try await b.account(s) }
    try check(account.language == "kk", "the owner sets the language")

    // Phone 1 sends its player and a play.
    var phone1 = Phone()
    let mira = phone1.book.add(name: "Мира", now: t0)!
    phone1.book.setProgress("winkbeat.hardOpen", "1", now: t0)
    let play = PlayRow(profileID: mira.id, game: "winkbeat", difficulty: "normal", byEye: true, startedAt: t0,
                       durationSec: 92.5, score: 18_200, accuracy: 0.86, hits: 43, misses: 7, build: "1.0.4 (10)")
    phone1.plays.add(play)
    try await phone1.sync(k1)
    var pulled = try await k1.call { b, s in try await b.pullProfiles(s) }
    try check(pulled.map(ProfileRow.init) == phone1.rows, "the account holds phone 1's player as it is")
    try check(phone1.plays.rows.isEmpty, "the sent play left the queue")
    phone1.plays.add(PlayRow(id: play.id, profileID: mira.id, game: "winkbeat", byEye: true, startedAt: t0,
                             durationSec: 1))
    try await phone1.sync(k1)
    let token = try await k1.call { _, s in s.accessToken }
    let plays = try await get(restURL.appendingPathComponent("plays"), token: token).json as? [[String: Any]]
    try check(plays?.count == 1, "the same play sent twice is kept once")
    try check((plays?.first?["score"] as? Int) == 18_200 && (plays?.first?["duration_sec"] as? Double) == 92.5,
              "and not changed")

    // Phone 2 starts with its own untouched first player, then signs in with the password.
    let a2 = try await backend.signIn(email: a, password: "first-password")
    let k2 = keeper(a2)
    var phone2 = Phone()
    let placeholder = phone2.book.add(name: "Игрок 1", now: t0.addingTimeInterval(500))!
    phone2.book.setProgress(ProfileBook.defaultNameKey, "1", now: t0.addingTimeInterval(500))
    try await phone2.sync(k2)
    try check(phone2.book.visible.map(\.name) == ["Мира"] && phone2.book.activeID == mira.id,
              "phone 2 gets Мира and drops its untouched first player")
    pulled = try await k2.call { b, s in try await b.pullProfiles(s) }
    try check(!pulled.contains { $0.id == placeholder.id }, "the untouched player never reached the account")

    // Both change Мира while apart; a newer name and an older opened level both stay.
    phone2.book.edit(mira.id, name: "Мирочка", now: t0.addingTimeInterval(2000))
    phone1.book.setProgress("winkbeat.lastDifficulty", "hard", of: mira.id, now: t0.addingTimeInterval(1000))
    let timur = phone1.book.add(name: "Тимур", now: t0.addingTimeInterval(1100))!
    try await phone2.sync(k2)
    try await phone1.sync(k1)
    try await phone2.sync(k2)
    pulled = try await k1.call { b, s in try await b.pullProfiles(s) }
    try check(phone1.rows == phone2.rows && phone1.rows == pulled.map(ProfileRow.init).sorted { $0.id.uuidString < $1.id.uuidString },
              "both phones and the account end with the same players")
    let merged = phone1.book.profile(mira.id)
    try check(merged?.name == "Мирочка" && merged?.progress["winkbeat.lastDifficulty"] == "hard"
              && merged?.progress["winkbeat.hardOpen"] == "1", "the newer name won and every progress key stayed")
    phone2.book.remove(timur.id, now: t0.addingTimeInterval(3000))
    try await phone2.sync(k2)
    try await phone1.sync(k1)
    try check(phone1.book.profile(timur.id) == nil, "a player deleted on phone 2 is gone from phone 1")

    // Another adult sees nothing of A, cannot take A's player, and keeps their own.
    try check(try await backend.signUp(email: b, password: "second-adult", language: "en") == .codeSent,
              "B signs up")
    let codeB = try await code(to: b, after: 0, saying: "confirm your email")
    let kb = keeper(try await backend.confirmSignUp(email: b, code: codeB))
    pulled = try await kb.call { b, s in try await b.pullProfiles(s) }
    try check(pulled.isEmpty, "B sees no players of A")
    var phoneB = Phone()
    phoneB.book.merge([mira])
    let own = phoneB.book.add(name: "Own", now: t0.addingTimeInterval(10))!
    phoneB.plays.add(PlayRow(profileID: mira.id, game: "meteors", byEye: true, startedAt: t0, durationSec: 10))
    let refused = try await phoneB.sync(kb)
    pulled = try await kb.call { b, s in try await b.pullProfiles(s) }
    try check(refused.refusedPlayers == 1 && pulled.map(\.id) == [own.id], "B's copy of A's player is refused, B's own goes")
    try check(refused.refusedPlays == 0 && phoneB.plays.rows.count == 1,
              "a play of a player not in B's account waits on the phone")
    pulled = try await k1.call { b, s in try await b.pullProfiles(s) }
    try check(pulled.first { $0.id == mira.id }?.name == "Мирочка", "A's player stays A's")

    // A forgotten password: a code in the email, then a new password.
    let before = try await mails(to: a).count
    try await backend.sendPasswordCode(email: a)
    let resetCode = try await code(to: a, after: before, saying: "құпиясөзді қалпына келтіру")
    let reset = try await backend.confirmPasswordCode(email: a, code: resetCode)
    try await backend.setPassword("third-password", reset)
    try await expect(.samePassword, "the same password again") { try await backend.setPassword("third-password", reset) }
    try await expect(.wrongPassword, "the old password") { _ = try await backend.signIn(email: a, password: "first-password") }
    let a3 = try await backend.signIn(email: a, password: "third-password")
    try check(a3.userID == a1.userID, "the new password signs in")
    try await backend.sendPasswordCode(email: "nobody@e2e.example.com")
    print("ok   a code for an email without an account answers the same")

    // Tokens: a refreshed session works; a refused refresh signs out; a token the server refuses is refreshed once.
    let refreshed = try await backend.refresh(a3)
    try check(refreshed.refreshToken != a3.refreshToken, "a refresh gives new tokens")
    _ = try await backend.account(refreshed)
    var forged = refreshed
    forged.accessToken = String(forged.accessToken.dropLast(4)) + (forged.accessToken.hasSuffix("AAAA") ? "BBBB" : "AAAA")
    forged.expiresAt = .distantFuture
    var latest = keeper(forged)
    _ = try await latest.call { b, s in try await b.account(s) }
    let afterForged = await latest.session
    try check(afterForged?.refreshToken != forged.refreshToken, "a refused token is refreshed and the call repeated")
    // A new password ends the other phones' sign-ins: phone 2 signs in again.
    try await expect(.signedOut, "phone 2 after the password changed on another phone") {
        _ = try await k2.call { b, s in try await b.account(s) }
    }
    let k2again = keeper(try await backend.signIn(email: a, password: "third-password"))
    // Signing out as the app does: with a fresh token, so the server ends that sign-in too.
    let out = try await k2again.call { _, s in s }
    try await k2again.call { b, s in await b.signOut(s) }
    try await expect(.signedOut, "phone 2's tokens after it signed out") { _ = try await backend.refresh(out) }
    let k2gone = SessionKeeper(backend: backend, session: AuthSession(accessToken: "x", refreshToken: out.refreshToken,
                                                                      expiresAt: .distantPast, userID: out.userID,
                                                                      email: out.email), saved: { _ in })
    try await expect(.signedOut, "a keeper whose refresh is refused") { _ = try await k2gone.call { b, s in try await b.account(s) } }
    let leftover = await k2gone.session
    try check(leftover == nil, "and it forgets the session")

    if let wait = env["EXPIRY_WAIT"].flatMap(Double.init), wait > 0 {
        print("..   waiting \(Int(wait)) s for the tokens to run out")
        var stale = await latest.session!
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        stale.expiresAt = .distantFuture
        latest = keeper(stale)
        _ = try await latest.call { b, s in try await b.account(s) }
        var s4 = await latest.session!
        try check(s4.refreshToken != stale.refreshToken, "an expired token on the tables is refreshed and the call repeated")
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        s4.expiresAt = .distantFuture
        latest = keeper(s4)
        try await latest.call { b, s in try await b.setEmailLanguage("kk", s) }
        let s5 = await latest.session
        try check(s5?.refreshToken != s4.refreshToken, "an expired token on the sign-in is refreshed too")
    }

    // An unconfirmed sign-up asks for the code again.
    try check(try await backend.signUp(email: "late@e2e.example.com", password: "late-but-long", language: "ru")
              == .codeSent, "a third adult signs up")
    _ = try await code(to: "late@e2e.example.com", after: 0, saying: "подтверждение почты")
    try await expect(.tooManyRequests, "asking for the code again at once") {
        try await backend.resendSignUpCode(email: "late@e2e.example.com")
    }
    try await Task.sleep(nanoseconds: 2_000_000_000)  // e2e.sh sets the wait between emails to 1 s; Supabase, 60 s
    try await backend.resendSignUpCode(email: "late@e2e.example.com")
    let late = try await code(to: "late@e2e.example.com", after: 1, saying: "подтверждение почты")
    _ = try await backend.confirmSignUp(email: "late@e2e.example.com", code: late)
    print("ok   a resent code confirms")

    // Deleting the account from the app takes it, its players and plays; the other adult stays.
    try await latest.call { b, s in try await b.deleteAccount(s) }
    try await expect(.wrongPassword, "signing in to the deleted account") {
        _ = try await backend.signIn(email: a, password: "third-password")
    }
    try await expect(.signedOut, "the deleted account's refresh") { _ = try await backend.refresh(refreshed) }
    pulled = try await kb.call { b, s in try await b.pullProfiles(s) }
    try check(pulled.map(\.id) == [own.id], "the other adult's players stay")
}

/// Like `expect`, for a step whose exact refusal differs between Auth versions: any refusal passes, a success
/// fails.
func expectQuietly(_ reason: BackendError.Reason, _ what: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        print("FAIL \(what): no error")
        exit(1)
    } catch let e as BackendError {
        print(e.reason == reason ? "ok   \(what): \(e.reason.rawValue)" : "ok?  \(what): \(e)")
    } catch {
        print("FAIL \(what): \(error)")
        exit(1)
    }
}

do {
    try await run()
    print("backend e2e passed")
} catch {
    print("FAIL \(error)")
    exit(1)
}
