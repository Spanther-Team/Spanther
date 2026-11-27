import XCTest
@testable import GazeCore

/// The sign-in and sync client against a stand-in for Supabase that keeps the database's rules
/// (backend/supabase/migrations). The real thing is checked by backend/test/e2e.sh.
final class BackendTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_770_000)  // 2026-11-27 09:00 UTC

    // MARK: Times

    func testTimesGoOutInWholeSecondsOfUTC() {
        XCTAssertEqual(BackendDate.string(Date(timeIntervalSince1970: 1_800_000_000.9)), "2027-01-15T08:00:00Z")
        XCTAssertEqual(BackendDate.string(Date(timeIntervalSince1970: -1)), "1969-12-31T23:59:59Z")
        XCTAssertEqual(BackendDate.string(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(BackendDate.string(Date(timeIntervalSince1970: 951_782_400)), "2000-02-29T00:00:00Z")
        XCTAssertEqual(BackendDate.string(Date(timeIntervalSince1970: 4_102_444_800)), "2100-01-01T00:00:00Z")
        XCTAssertEqual(BackendDate.whole(Date(timeIntervalSince1970: 10.7)).timeIntervalSince1970, 10)
    }

    func testTimesComeInInEveryFormTheDatabaseWrites() {
        func t(_ s: String) -> Double? { BackendDate.date(s)?.timeIntervalSince1970 }
        XCTAssertEqual(t("2026-11-27T09:00:00Z"), 1_795_770_000)
        XCTAssertEqual(t("2026-11-27T09:00:00+00:00"), 1_795_770_000)
        XCTAssertEqual(t("2026-11-27 09:00:00+00"), 1_795_770_000)
        XCTAssertEqual(t("2026-11-27T09:00:00"), 1_795_770_000)
        XCTAssertEqual(t("2026-11-27 14:00:00.123456+05")!, 1_795_770_000.123456, accuracy: 1e-6)
        XCTAssertEqual(t("2026-11-27T09:00:00.5-03:30"), 1_795_782_600.5)
        for bad in ["", "2026-11-27", "2026-13-01T00:00:00Z", "2026-11-27T09:00:00.Z", "2026-11-27T09:00:00+5",
                    "2026-11-27T09:00:00Zjunk", "yesterday"] {
            XCTAssertNil(BackendDate.date(bad), bad)
        }
        for s in [-86_401.0, 0, 951_782_400, 1_795_770_000, 4_102_444_800] {
            let d = Date(timeIntervalSince1970: s)
            XCTAssertEqual(BackendDate.date(BackendDate.string(d)), d)
        }
    }

    // MARK: Errors

    func testServerErrorsReadAsReasons() {
        func reason(_ status: Int, _ json: String, rest: Bool = false) -> BackendError.Reason {
            BackendError.from(BackendResponse(status: status, body: Data(json.utf8)), rest: rest).reason
        }
        XCTAssertEqual(reason(400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#),
                       .wrongPassword)
        XCTAssertEqual(reason(400, #"{"code":"email_not_confirmed","message":"Email not confirmed"}"#), .emailNotConfirmed)
        XCTAssertEqual(reason(400, #"{"error":"invalid_grant","error_description":"Email not confirmed"}"#),
                       .emailNotConfirmed)
        XCTAssertEqual(reason(400, #"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Not Found"}"#),
                       .signedOut)
        XCTAssertEqual(reason(422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#),
                       .emailTaken)
        XCTAssertEqual(reason(422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 8"}"#),
                       .weakPassword)
        XCTAssertEqual(reason(403, #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#),
                       .badCode)
        XCTAssertEqual(reason(429, #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"rate limit"}"#),
                       .tooManyRequests)
        XCTAssertEqual(reason(400, #"{"code":400,"error_code":"email_address_not_authorized","msg":"no"}"#), .mailFailed)
        XCTAssertEqual(reason(500, #"{"code":500,"msg":"Error sending confirmation email"}"#), .mailFailed)
        XCTAssertEqual(reason(401, #"{"code":"PGRST301","message":"JWT expired"}"#, rest: true), .tokenExpired)
        XCTAssertEqual(reason(403, #"{"code":"42501","message":"new row violates row-level security policy"}"#, rest: true),
                       .rejected)
        XCTAssertEqual(reason(400, #"{"code":"23514","message":"violates check constraint"}"#, rest: true), .rejected)
        XCTAssertEqual(reason(502, "<html>Bad gateway</html>", rest: true), .server)
    }

    // MARK: Sign-in

    func testSignUpWaitsForTheCodeFromTheEmailThenSignsIn() async throws {
        let server = FakeSupabase()
        let b = server.backend
        let result = try await b.signUp(email: " Mira@Test.kz ", password: "longenough", language: "kk")
        XCTAssertEqual(result, .codeSent)
        XCTAssertEqual(server.lastBody("/auth/v1/signup")?["email"] as? String, "mira@test.kz")
        XCTAssertEqual((server.lastBody("/auth/v1/signup")?["data"] as? [String: Any])?["lang"] as? String, "kk")
        await XCTAssertThrowsReason(.emailNotConfirmed) { _ = try await b.signIn(email: "mira@test.kz", password: "longenough") }
        await XCTAssertThrowsReason(.badCode) { _ = try await b.confirmSignUp(email: "mira@test.kz", code: "000000") }
        let s = try await b.confirmSignUp(email: "mira@test.kz", code: " 12 34 56")
        XCTAssertEqual(s.email, "mira@test.kz")
        XCTAssertEqual(s.userID, server.userID("mira@test.kz"))
        XCTAssertGreaterThan(s.expiresAt, Date().addingTimeInterval(3000))
        XCTAssertEqual(server.requests.last?.headers["apikey"], "public-key")
        XCTAssertNil(server.requests.first?.headers["Authorization"], "no sign-in token before signing in")
    }

    func testSignUpOnATakenEmailSaysSo() async throws {
        let server = FakeSupabase()
        _ = try await server.signedIn("a@test")
        await XCTAssertThrowsReason(.emailTaken) {
            _ = try await server.backend.signUp(email: "a@test", password: "longenough", language: "ru")
        }
        await XCTAssertThrowsReason(.weakPassword) {
            _ = try await server.backend.signUp(email: "b@test", password: "short", language: "ru")
        }
    }

    func testSignUpWithoutEmailConfirmationSignsInAtOnce() async throws {
        let server = FakeSupabase()
        server.autoconfirm = true
        guard case .signedIn(let s) = try await server.backend.signUp(email: "a@test", password: "longenough",
                                                                      language: "ru") else {
            return XCTFail("signed in at once")
        }
        XCTAssertEqual(s.userID, server.userID("a@test"))
    }

    func testAForgottenPasswordIsReplacedWithTheCodeFromTheEmail() async throws {
        let server = FakeSupabase()
        _ = try await server.signedIn("a@test")
        let b = server.backend
        await XCTAssertThrowsReason(.wrongPassword) { _ = try await b.signIn(email: "a@test", password: "forgotten") }
        try await b.sendPasswordCode(email: "a@test")
        let s = try await b.confirmPasswordCode(email: "a@test", code: server.code("a@test")!)
        try await b.setPassword("brand-new-one", s)
        _ = try await b.signIn(email: "a@test", password: "brand-new-one")
    }

    func testOfflineIsOffline() async {
        let server = FakeSupabase()
        server.offline = true
        await XCTAssertThrowsReason(.offline) { _ = try await server.backend.signIn(email: "a@test", password: "x") }
    }

    // MARK: Keeping the session

    func testARunOutTokenIsRefreshedOnceAndTheCallRepeated() async throws {
        let server = FakeSupabase()
        let s = try await server.signedIn("a@test")
        let saved = Saved()
        let keeper = SessionKeeper(backend: server.backend, session: s, saved: { saved.value = $0 })
        server.expireTokens()
        let account = try await keeper.call { b, s in try await b.account(s) }
        XCTAssertEqual(account.id, s.userID)
        let now = await keeper.session
        XCTAssertNotEqual(now?.accessToken, s.accessToken)
        XCTAssertEqual(saved.value?.accessToken, now?.accessToken, "the new tokens are kept")
        XCTAssertEqual(server.count("/auth/v1/token"), 2, "one sign-in, one refresh")
    }

    func testATokenAboutToRunOutIsRefreshedBeforeTheCall() async throws {
        let server = FakeSupabase()
        var s = try await server.signedIn("a@test")
        s.expiresAt = Date().addingTimeInterval(30)
        let keeper = SessionKeeper(backend: server.backend, session: s, saved: { _ in })
        _ = try await keeper.call { b, s in try await b.account(s) }
        XCTAssertEqual(server.count("/rest/v1/accounts"), 1, "no failed call first")
        XCTAssertEqual(server.count("/auth/v1/token"), 2)
    }

    func testARefusedRefreshSignsOut() async throws {
        let server = FakeSupabase()
        let s = try await server.signedIn("a@test")
        let saved = Saved()
        saved.value = s
        let keeper = SessionKeeper(backend: server.backend, session: s, saved: { saved.value = $0 })
        server.expireTokens()
        server.forgetRefreshTokens()
        await XCTAssertThrowsReason(.signedOut) { _ = try await keeper.call { b, s in try await b.account(s) } }
        let left = await keeper.session
        XCTAssertNil(left)
        XCTAssertNil(saved.value)
    }

    func testNoNetworkKeepsTheSession() async throws {
        let server = FakeSupabase()
        let s = try await server.signedIn("a@test")
        let keeper = SessionKeeper(backend: server.backend, session: s, saved: { _ in })
        server.offline = true
        await XCTAssertThrowsReason(.offline) { _ = try await keeper.call { b, s in try await b.account(s) } }
        let left = await keeper.session
        XCTAssertEqual(left, s)
    }

    // MARK: Rows

    func testAPlayerRowHasEveryKeyAndFitsTheDatabase() throws {
        var p = PlayerProfile(name: String(repeating: "👨‍👩‍👧‍👦", count: 12), avatar: 99, birthYear: 1066,
                              progress: ["winkbeat.hardOpen": "1"], createdAt: t0.addingTimeInterval(0.7))
        p.updatedAt = t0.addingTimeInterval(5.9)
        let row = ProfileRow(p)
        XCTAssertLessThanOrEqual(row.name.unicodeScalars.count, 64)
        XCTAssertEqual(row.avatar, 15)
        XCTAssertNil(row.birthYear)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Backend.encoder.encode(row)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "name", "avatar", "birth_year", "progress", "created_at", "updated_at",
                                        "deleted_at"])
        XCTAssertTrue(json["deleted_at"] is NSNull)
        XCTAssertEqual(json["created_at"] as? String, "2026-11-27T09:00:00Z")
        XCTAssertEqual(json["updated_at"] as? String, "2026-11-27T09:00:05Z")
        XCTAssertEqual(json["id"] as? String, p.id.uuidString.lowercased())
    }

    func testAPlayerRowFromTheDatabaseReads() throws {
        let json = #"""
        [{"id":"C0000000-0000-4000-8000-000000000001","name":"Мира","avatar":3,"birth_year":2018,
          "progress":{"winkbeat.hardOpen":"1","typed.by.hand":7,"flag":true,"nested":{"a":1}},
          "created_at":"2026-11-27T09:00:00+00:00","updated_at":"2026-11-27 09:00:05.25+00",
          "deleted_at":null,"account_id":"a0000000-0000-4000-8000-000000000001",
          "server_updated_at":"2026-11-27T09:01:00.123456+00:00"}]
        """#
        let rows = try Backend.decoder.decode([ProfileRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        let p = rows[0].profile
        XCTAssertEqual(p.name, "Мира")
        XCTAssertEqual(p.birthYear, 2018)
        XCTAssertEqual(p.progress, ["winkbeat.hardOpen": "1", "typed.by.hand": "7", "flag": "1"])
        XCTAssertEqual(p.createdAt, t0)
        XCTAssertEqual(p.updatedAt.timeIntervalSince1970, t0.timeIntervalSince1970 + 5.25)
        XCTAssertNil(p.deletedAt)
    }

    func testPlaysFromSummariesFitTheDatabase() throws {
        let who = UUID()
        var m = SessionSummary(id: UUID().uuidString, childCode: "", game: .meteors, start: t0, durationSec: 120,
                               byEye: true, calibrationErrorCm: 1)
        m.meteors = 40
        m.burned = 30
        m.maxLevel = 6
        let meteors = try XCTUnwrap(PlayRow(m, profileID: who, build: "1.0.4 (10)"))
        XCTAssertEqual(meteors.game, "meteors")
        XCTAssertEqual(meteors.difficulty, "level-6")
        XCTAssertEqual(meteors.hits, 30)
        XCTAssertEqual(meteors.misses, 10)
        XCTAssertEqual(meteors.accuracy, 0.75)
        XCTAssertEqual(meteors.profileID, who)

        var r = SessionSummary(id: UUID().uuidString, childCode: "", game: .rhythm, start: t0, durationSec: 60,
                               byEye: false, calibrationErrorCm: nil)
        r.rhythmLevel = "easy"
        r.accuracy = 1.4
        r.notes = 20
        r.hits = 25
        let rhythm = try XCTUnwrap(PlayRow(r, profileID: who, build: nil))
        XCTAssertEqual(rhythm.accuracy, 1, "the share of targets hit stays within 0...1")
        XCTAssertEqual(rhythm.misses, 0)
        XCTAssertNil(PlayRow(SessionSummary(id: "not-a-uuid", childCode: "", game: .pursuit, start: t0, durationSec: 1,
                                            byEye: true, calibrationErrorCm: nil), profileID: who, build: nil))
        let odd = PlayRow(profileID: who, game: "Wink Beat!", byEye: true, startedAt: t0, durationSec: -.infinity,
                          accuracy: .nan, hits: -3)
        XCTAssertEqual(odd.game, "winkbeat")
        XCTAssertEqual(odd.durationSec, 0)
        XCTAssertNil(odd.accuracy)
        XCTAssertEqual(odd.hits, 0)
    }

    func testThePlayQueueKeepsEachPlayOnceAndTheNewestPastItsLimit() {
        var q = PlayQueue()
        let a = UUID(), b = UUID()
        let first = PlayRow(profileID: a, game: "meteors", byEye: true, startedAt: t0, durationSec: 1)
        q.add(first)
        q.add(first)
        XCTAssertEqual(q.rows.count, 1)
        for i in 0..<PlayQueue.limit {
            q.add(PlayRow(profileID: i % 2 == 0 ? a : b, game: "meteors", byEye: true, startedAt: t0, durationSec: 1))
        }
        XCTAssertEqual(q.rows.count, PlayQueue.limit)
        XCTAssertFalse(q.rows.contains(first), "the oldest gave way")
        XCTAssertEqual(q.ready(for: [b]).count, PlayQueue.limit / 2)
        q.remove(Set(q.ready(for: [b]).map(\.id)))
        XCTAssertEqual(q.players, [a])
    }

    // MARK: Merging the account's copies

    func testTheNewerChangeWinsAndProgressKeysFromBothStay() {
        var book = ProfileBook()
        let mine = book.add(name: "Мира", now: t0)!
        book.setProgress("winkbeat.hardOpen", "1", now: t0.addingTimeInterval(10))
        var theirs = mine
        theirs.name = "Мирочка"
        theirs.progress = ["winkbeat.lastDifficulty": "normal"]
        theirs.updatedAt = t0.addingTimeInterval(20)
        XCTAssertTrue(book.merge([theirs]))
        XCTAssertEqual(book.active?.name, "Мирочка")
        XCTAssertEqual(book.active?.progress, ["winkbeat.hardOpen": "1", "winkbeat.lastDifficulty": "normal"])

        var older = theirs
        older.name = "Старая"
        older.progress = ["winkbeat.lastDifficulty": "easy", "meteors.seen": "1"]
        older.updatedAt = t0.addingTimeInterval(5)
        book.merge([older])
        XCTAssertEqual(book.active?.name, "Мирочка", "an older copy does not undo a newer name")
        XCTAssertEqual(book.active?.progress["winkbeat.lastDifficulty"], "normal")
        XCTAssertEqual(book.active?.progress["meteors.seen"], "1", "its keys still count")
        XCTAssertFalse(book.merge([older]), "the same copy again changes nothing")
    }

    func testOnATieOfWholeSecondsTheAccountsCopyWins() {
        var book = ProfileBook()
        let mine = book.add(name: "Мира", now: t0)!
        book.edit(mine.id, name: "Мира 2", now: t0.addingTimeInterval(10.8))
        var theirs = mine
        theirs.name = "Мира 3"
        theirs.updatedAt = t0.addingTimeInterval(10)
        book.merge([theirs])
        XCTAssertEqual(book.active?.name, "Мира 3", "both phones end on one name")
    }

    func testADeletedPlayerStaysDeletedAndAnotherPlays() {
        var book = ProfileBook()
        let a = book.add(name: "А", now: t0)!
        let b = book.add(name: "Б", now: t0.addingTimeInterval(1))!
        XCTAssertEqual(book.activeID, b.id)
        var gone = b
        gone.deletedAt = t0.addingTimeInterval(30)
        gone.updatedAt = t0.addingTimeInterval(30)
        book.merge([gone])
        XCTAssertEqual(book.visible.map(\.id), [a.id])
        XCTAssertEqual(book.activeID, a.id)
        var back = b
        back.updatedAt = t0.addingTimeInterval(60)
        book.merge([back])
        XCTAssertEqual(book.visible.map(\.id), [a.id], "a newer copy does not bring a deleted player back")
    }

    func testPlayersNewToThePhoneJoinInTheOrderTheyWereMade() {
        var book = ProfileBook()
        let here = book.add(name: "Здесь", now: t0.addingTimeInterval(100))!
        let old = PlayerProfile(name: "Старший", avatar: 1, createdAt: t0)
        let later = PlayerProfile(name: "Позже", avatar: 2, createdAt: t0.addingTimeInterval(200))
        book.merge([later, old])
        XCTAssertEqual(book.visible.map(\.name), ["Старший", "Здесь", "Позже"])
        XCTAssertEqual(book.activeID, here.id, "the one playing still plays")
    }

    // MARK: Steps of a sync

    func testAFreshPhonesUntouchedPlayerGivesWayToTheAccountsPlayers() {
        let account = UUID()
        var fresh = ProfileBook()
        let placeholder = fresh.add(name: "Игрок 1", now: t0)!
        fresh.setProgress(ProfileBook.defaultNameKey, "1", now: t0)
        fresh.setProgress("sessions.code", "", now: t0)
        let mira = PlayerProfile(name: "Мира", avatar: 1, createdAt: t0.addingTimeInterval(-1000))
        var state = ProfileSyncState()
        let gone = ProfileSync.takeIn([mira], account: account, book: &fresh, state: &state, played: [])
        XCTAssertEqual(gone, [placeholder.id])
        XCTAssertEqual(fresh.visible.map(\.name), ["Мира"])
        XCTAssertEqual(fresh.activeID, mira.id)
        XCTAssertEqual(state, ProfileSyncState(accountID: account, synced: [mira.id]))
        XCTAssertTrue(ProfileSync.toSend(fresh, server: [mira]).isEmpty)
    }

    func testAPlayerWithAnythingOfTheirOwnJoinsTheAccount() {
        let mira = PlayerProfile(name: "Мира", avatar: 1, createdAt: t0)
        func book(_ edit: (inout ProfileBook, UUID) -> Void) -> ProfileBook {
            var b = ProfileBook()
            let p = b.add(name: "Игрок 1", now: t0)!
            b.setProgress(ProfileBook.defaultNameKey, "1", now: t0)
            edit(&b, p.id)
            return b
        }
        let named = book { b, id in b.edit(id, name: "Тимур", now: t0); b.setProgress(ProfileBook.defaultNameKey, "0", now: t0) }
        let progressed = book { b, _ in b.setProgress("winkbeat.hardOpen", "1", now: t0) }
        let played = book { _, _ in }
        for (b, plays) in [(named, false), (progressed, false), (played, true)] {
            var b = b
            var state = ProfileSyncState()
            let id = b.visible[0].id
            let gone = ProfileSync.takeIn([mira], account: UUID(), book: &b, state: &state,
                                          played: plays ? [id] : [])
            XCTAssertTrue(gone.isEmpty)
            XCTAssertEqual(b.visible.count, 2)
            XCTAssertEqual(ProfileSync.toSend(b, server: [mira]).map(\.id), [id])
        }
        var alone = book { _, _ in }
        var state = ProfileSyncState()
        XCTAssertTrue(ProfileSync.takeIn([], account: UUID(), book: &alone, state: &state, played: []).isEmpty,
                      "an empty account takes the first player")
        XCTAssertEqual(ProfileSync.toSend(alone, server: []).count, 1)
    }

    func testAnotherAccountsPlayersLeaveThePhoneAndItsOwnStay() {
        let first = UUID(), second = UUID()
        var book = ProfileBook()
        let mira = book.add(name: "Мира", now: t0)!
        var state = ProfileSyncState()
        _ = ProfileSync.takeIn([], account: first, book: &book, state: &state, played: [])
        ProfileSync.sent(ProfileSync.toSend(book, server: []), state: &state)
        XCTAssertEqual(state.synced, [mira.id])
        // Signed out; a player made since then is the phone's own.
        let timur = book.add(name: "Тимур", now: t0.addingTimeInterval(10))!
        let aru = PlayerProfile(name: "Ару", avatar: 2, createdAt: t0.addingTimeInterval(-50))
        let gone = ProfileSync.takeIn([aru], account: second, book: &book, state: &state, played: [])
        XCTAssertEqual(gone, [mira.id])
        XCTAssertEqual(book.visible.map(\.name), ["Ару", "Тимур"])
        XCTAssertEqual(state, ProfileSyncState(accountID: second, synced: [aru.id]))
        XCTAssertEqual(ProfileSync.toSend(book, server: [aru]).map(\.id), [timur.id])
    }

    func testOnlyChangedPlayersAreSentAndNeverAPlayerDeletedBeforeReachingTheAccount() {
        var book = ProfileBook()
        let a = book.add(name: "А", now: t0)!
        let b = book.add(name: "Б", now: t0)!
        _ = book.add(name: "В", now: t0)
        let c = book.visible[2]
        book.remove(c.id, now: t0.addingTimeInterval(1))
        let server = [book.profile(a.id)!, book.profile(b.id)!]
        XCTAssertTrue(ProfileSync.toSend(book, server: server).isEmpty)
        book.setProgress("winkbeat.hardOpen", "1", of: b.id, now: t0.addingTimeInterval(2))
        XCTAssertEqual(ProfileSync.toSend(book, server: server).map(\.id), [b.id])
    }

    func testARefusedRowDoesNotHoldTheOthersBack() async throws {
        var pushes: [[Int]] = []
        let result = try await ProfileSync.send([1, 2, 3]) { rows in
            pushes.append(rows)
            if rows.contains(2) { throw BackendError(.rejected, status: 400, code: "23514") }
        }
        XCTAssertEqual(result.sent, [1, 3])
        XCTAssertEqual(result.refused, [2])
        XCTAssertEqual(pushes, [[1, 2, 3], [1], [2], [3]])
        do {
            _ = try await ProfileSync.send([1, 2]) { _ in throw BackendError(.offline) }
            XCTFail("no network is not a refusal")
        } catch let e as BackendError {
            XCTAssertEqual(e.reason, .offline)
        }
    }

    // MARK: Two phones, one account

    func testTwoPhonesOfOneAccountEndWithTheSamePlayers() async throws {
        let server = FakeSupabase()
        let session = try await server.signedIn("a@test")
        var phone1 = Phone(), phone2 = Phone()
        let mira = phone1.book.add(name: "Мира", now: t0)!
        phone1.book.setProgress("winkbeat.hardOpen", "1", now: t0)
        phone1.plays.add(PlayRow(profileID: mira.id, game: "winkbeat", difficulty: "normal", byEye: true,
                                 startedAt: t0, durationSec: 90, score: 18_200, accuracy: 0.86))
        try await phone1.sync(server.backend, session)
        XCTAssertEqual(server.playCount, 1)
        XCTAssertTrue(phone1.plays.rows.isEmpty, "a sent play leaves the queue")

        // The second phone starts with its own untouched first player, then signs in.
        let placeholder = phone2.book.add(name: "Игрок 1", now: t0.addingTimeInterval(500))!
        phone2.book.setProgress(ProfileBook.defaultNameKey, "1", now: t0.addingTimeInterval(500))
        try await phone2.sync(server.backend, session)
        XCTAssertEqual(phone2.book.visible.map(\.name), ["Мира"])
        XCTAssertFalse(server.has(placeholder.id), "the placeholder never reached the account")

        // Both change Мира while apart: one renames her later, the other opens a level earlier.
        phone2.book.edit(mira.id, name: "Мирочка", now: t0.addingTimeInterval(2000))
        phone1.book.setProgress("winkbeat.lastDifficulty", "hard", of: mira.id, now: t0.addingTimeInterval(1000))
        let timur = phone1.book.add(name: "Тимур", now: t0.addingTimeInterval(1100))!
        try await phone2.sync(server.backend, session)
        try await phone1.sync(server.backend, session)
        try await phone2.sync(server.backend, session)
        XCTAssertEqual(phone1.rows, phone2.rows)
        XCTAssertEqual(phone1.rows, server.rows(of: session.userID))
        XCTAssertEqual(phone1.book.profile(mira.id)?.name, "Мирочка")
        XCTAssertEqual(phone1.book.profile(mira.id)?.progress["winkbeat.lastDifficulty"], "hard")
        XCTAssertEqual(phone1.book.profile(mira.id)?.progress["winkbeat.hardOpen"], "1")
        XCTAssertNotNil(phone2.book.profile(timur.id))

        // A deletion on one phone reaches the other, and another sync sends nothing.
        phone2.book.remove(timur.id, now: t0.addingTimeInterval(3000))
        try await phone2.sync(server.backend, session)
        try await phone1.sync(server.backend, session)
        XCTAssertNil(phone1.book.profile(timur.id))
        let before = server.count("/rest/v1/profiles", method: "POST")
        try await phone1.sync(server.backend, session)
        try await phone2.sync(server.backend, session)
        XCTAssertEqual(server.count("/rest/v1/profiles", method: "POST"), before, "nothing left to send")
    }

    func testAnotherAccountsPlayerIsRefusedAndTheRestGo() async throws {
        let server = FakeSupabase()
        let a = try await server.signedIn("a@test")
        let b = try await server.signedIn("b@test")
        var phoneA = Phone()
        let mira = phoneA.book.add(name: "Мира", now: t0)!
        try await phoneA.sync(server.backend, a)
        // B somehow has a copy of A's player (the same id) and a player of their own.
        var phoneB = Phone()
        phoneB.book.merge([mira])
        let own = phoneB.book.add(name: "Свой", now: t0.addingTimeInterval(1))!
        try await phoneB.sync(server.backend, b)
        XCTAssertEqual(server.rows(of: b.userID).map(\.id), [own.id])
        XCTAssertEqual(server.rows(of: a.userID).map(\.name), ["Мира"], "A's player stays A's")
    }

    func testDeletingTheAccountTakesItsPlayersAndPlays() async throws {
        let server = FakeSupabase()
        let s = try await server.signedIn("a@test")
        var phone = Phone()
        let mira = phone.book.add(name: "Мира", now: t0)!
        phone.plays.add(PlayRow(profileID: mira.id, game: "meteors", byEye: true, startedAt: t0, durationSec: 60))
        try await phone.sync(server.backend, s)
        try await server.backend.deleteAccount(s)
        XCTAssertTrue(server.rows(of: s.userID).isEmpty)
        XCTAssertEqual(server.playCount, 0)
        await XCTAssertThrowsReason(.wrongPassword) {
            _ = try await server.backend.signIn(email: "a@test", password: FakeSupabase.password)
        }
    }
}

// MARK: Helpers

/// One phone: its players, what it knows of the sync, and its plays waiting.
private struct Phone {
    var book = ProfileBook()
    var state = ProfileSyncState()
    var plays = PlayQueue()

    var rows: [ProfileRow] { book.profiles.map(ProfileRow.init).sorted { $0.id.uuidString < $1.id.uuidString } }

    /// The steps the app takes (AccountModel.sync).
    mutating func sync(_ b: Backend, _ s: AuthSession) async throws {
        let account = try await b.account(s)
        let server = try await b.pullProfiles(s)
        _ = ProfileSync.takeIn(server, account: account.id, book: &book, state: &state, played: plays.players)
        let rows = ProfileSync.toSend(book, server: server)
        let sent = try await ProfileSync.send(rows) { try await b.push($0, s) }
        ProfileSync.sent(sent.sent, state: &state)
        let ready = plays.ready(for: state.synced)
        let played = try await ProfileSync.send(ready) { try await b.push($0, s) }
        plays.remove(Set((played.sent + played.refused).map(\.id)))
    }
}

private final class Saved: @unchecked Sendable {
    var value: AuthSession?
}

private func XCTAssertThrowsReason(_ reason: BackendError.Reason, file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(reason)", file: file, line: line)
    } catch let e as BackendError {
        XCTAssertEqual(e.reason, reason, "\(e)", file: file, line: line)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

/// A stand-in for Supabase: Auth with codes in emails, and the tables with the database's rules
/// (row level security by account, the profiles merge, plays added once).
private final class FakeSupabase: BackendTransport, @unchecked Sendable {
    static let password = "correct-horse"

    var offline = false
    var autoconfirm = false
    private let lock = NSLock()
    private var users: [String: (id: UUID, password: String, confirmed: Bool)] = [:]
    private var codes: [String: String] = [:]
    private var access: [String: UUID] = [:]
    private var refresh: [String: UUID] = [:]
    private var expired: Set<String> = []
    private var profiles: [UUID: (account: UUID, row: ProfileRow)] = [:]
    private var plays: [UUID: (account: UUID, row: PlayRow)] = [:]
    private(set) var requests: [BackendRequest] = []
    private var issued = 0

    var backend: Backend {
        Backend(config: BackendConfig(projectURL: "https://test.supabase.co", apiKey: "public-key")!, transport: self)
    }

    func signedIn(_ email: String) async throws -> AuthSession {
        _ = try await backend.signUp(email: email, password: Self.password, language: "ru")
        _ = try await backend.confirmSignUp(email: email, code: code(email)!)
        return try await backend.signIn(email: email, password: Self.password)
    }

    func userID(_ email: String) -> UUID? { locked { users[email]?.id } }
    func code(_ email: String) -> String? { locked { codes[email] } }
    func expireTokens() { locked { expired.formUnion(access.keys) } }
    func forgetRefreshTokens() { locked { refresh = [:] } }
    func has(_ id: UUID) -> Bool { locked { profiles[id] != nil } }
    var playCount: Int { locked { plays.count } }
    func rows(of account: UUID) -> [ProfileRow] {
        locked { profiles.values.filter { $0.account == account }.map { $0.row }.sorted { $0.id.uuidString < $1.id.uuidString } }
    }
    func count(_ path: String, method: String? = nil) -> Int {
        locked { requests.filter { $0.url.path == path && (method == nil || $0.method == method) }.count }
    }
    func lastBody(_ path: String) -> [String: Any]? {
        locked {
            requests.last { $0.url.path == path }?.body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        if offline { throw NoNetwork() }
        return locked { handle(request) }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private func handle(_ r: BackendRequest) -> BackendResponse {
        requests.append(r)
        let body = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let query = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let token = r.headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) }
        let user = token.flatMap { expired.contains($0) ? nil : access[$0] }
        let email = (body["email"] as? String) ?? ""
        switch (r.method, r.url.path) {
        case ("POST", "/auth/v1/signup"):
            let password = body["password"] as? String ?? ""
            guard password.count >= 8 else { return error(422, "weak_password") }
            if let u = users[email], u.confirmed { return json(200, ["id": UUID().uuidString, "identities": []]) }
            let id = users[email]?.id ?? UUID()
            users[email] = (id, password, autoconfirm)
            if autoconfirm { return json(200, session(id, email)) }
            codes[email] = "123456"
            return json(200, ["id": id.uuidString, "identities": [["provider": "email"]]])
        case ("POST", "/auth/v1/verify"):
            guard let u = users[email], let code = codes[email], body["token"] as? String == code else {
                return error(403, "otp_expired")
            }
            codes[email] = nil
            users[email]?.confirmed = true
            return json(200, session(u.id, email))
        case ("POST", "/auth/v1/resend"), ("POST", "/auth/v1/recover"):
            if users[email] != nil { codes[email] = "654321" }
            return json(200, [:])
        case ("POST", "/auth/v1/token") where q("grant_type") == "password":
            guard let u = users[email], u.password == body["password"] as? String else {
                return error(400, "invalid_credentials")
            }
            guard u.confirmed else { return error(400, "email_not_confirmed") }
            return json(200, session(u.id, email))
        case ("POST", "/auth/v1/token") where q("grant_type") == "refresh_token":
            guard let old = body["refresh_token"] as? String, let id = refresh.removeValue(forKey: old),
                  let email = users.first(where: { $0.value.id == id })?.key else {
                return error(400, "refresh_token_not_found")
            }
            return json(200, session(id, email))
        case ("PUT", "/auth/v1/user"):
            guard let id = user, let email = users.first(where: { $0.value.id == id })?.key else {
                return error(403, "bad_jwt")
            }
            if let p = body["password"] as? String { users[email]?.password = p }
            return json(200, ["id": id.uuidString])
        case ("POST", "/auth/v1/logout"):
            return BackendResponse(status: 204)
        default:
            break
        }
        guard r.url.path.hasPrefix("/rest/v1/") else { return error(404, "not_found") }
        guard let me = user else { return BackendResponse(status: 401, body: Data(#"{"code":"PGRST301","message":"JWT expired"}"#.utf8)) }
        let rows = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
        switch (r.method, r.url.path) {
        case ("GET", "/rest/v1/accounts"):
            let email = users.first { $0.value.id == me }?.key
            return json(200, [["id": me.uuidString.lowercased(), "email": email.map { $0 as Any } ?? NSNull(), "language": "ru",
                               "role": "user", "premium_until": NSNull()]])
        case ("GET", "/rest/v1/profiles"):
            let mine = profiles.values.filter { $0.account == me }.map { $0.row }.sorted { $0.createdAt < $1.createdAt }
            return BackendResponse(status: 200, body: try! Backend.encoder.encode(mine))
        case ("POST", "/rest/v1/profiles"):
            XCTAssertEqual(Set(rows.map { Set($0.keys) }).count, 1, "every row has the same keys")
            let incoming = try! Backend.decoder.decode([ProfileRow].self, from: r.body!)
            var next = profiles
            for row in incoming {
                guard (1...64).contains(row.name.unicodeScalars.count) else { return error(400, "23514") }
                if let old = next[row.id] {
                    guard old.account == me else { return error(403, "42501") }
                    if let merged = Self.merge(old: old.row, new: row) { next[row.id] = (me, merged) }
                } else {
                    next[row.id] = (me, row)
                }
            }
            profiles = next
            return BackendResponse(status: 201)
        case ("POST", "/rest/v1/plays"):
            let incoming = try! Backend.decoder.decode([PlayRow].self, from: r.body!)
            var next = plays
            for row in incoming {
                guard profiles[row.profileID]?.account == me else { return error(403, "42501") }
                if next[row.id] == nil { next[row.id] = (me, row) }
            }
            plays = next
            return BackendResponse(status: 201)
        case ("POST", "/rest/v1/rpc/delete_my_account"):
            users = users.filter { $0.value.id != me }
            profiles = profiles.filter { $0.value.account != me }
            plays = plays.filter { $0.value.account != me }
            access = access.filter { $0.value != me }
            return BackendResponse(status: 204)
        default:
            return error(404, "PGRST125")
        }
    }

    /// The database's profiles_merge trigger.
    static func merge(old: ProfileRow, new: ProfileRow) -> ProfileRow? {
        var n = new
        n.createdAt = old.createdAt
        if new.updatedAt < old.updatedAt {
            n.name = old.name
            n.avatar = old.avatar
            n.birthYear = old.birthYear
            n.progress = new.progress.merging(old.progress) { _, o in o }
            n.updatedAt = old.updatedAt
        } else {
            n.progress = old.progress.merging(new.progress) { _, x in x }
        }
        n.deletedAt = old.deletedAt ?? new.deletedAt
        return n == old ? nil : n
    }

    private func session(_ id: UUID, _ email: String) -> [String: Any] {
        issued += 1
        let a = "access-\(issued)", r = "refresh-\(issued)"
        access[a] = id
        refresh[r] = id
        return ["access_token": a, "refresh_token": r, "expires_in": 3600, "token_type": "bearer",
                "user": ["id": id.uuidString.lowercased(), "email": email]]
    }

    private func json(_ status: Int, _ object: Any) -> BackendResponse {
        BackendResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func error(_ status: Int, _ code: String) -> BackendResponse {
        let postgres = code.allSatisfy(\.isNumber) || code.hasPrefix("PGRST")
        let object: [String: Any] = postgres ? ["code": code, "message": code]
            : ["code": status, "error_code": code, "msg": code]
        return json(status, object)
    }
}

private struct NoNetwork: Error {}
