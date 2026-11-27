import Foundation
import Security

/// The adult's account on this phone: sign-in by email and password (Supabase Auth through GazeCore `Backend`) and
/// the sync of the players, their progress and their plays (GazeCore `ProfileSync`). Calibrations, camera frames
/// and session files never leave the phone, and the clinic's children never go. Signing in is optional: without
/// it everything works on the phone alone. Main thread.
final class AccountModel: ObservableObject {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case synced(Date)
        /// No network: what changed goes with the next sync.
        case offline
        case failed
    }

    /// Nil while the Supabase project is not set (`BackendSettings`): the app then shows no sign-in.
    let backend: Backend?
    @Published private(set) var session: AuthSession?
    @Published private(set) var account: AccountRow?
    @Published private(set) var status: SyncStatus = .idle
    /// The server ended this phone's sign-in: the password changed on another phone, or the account was deleted.
    @Published var endedElsewhere = false

    /// Who plays changed in a sync: the one playing was deleted on another phone, or a fresh phone's first player
    /// gave way to the account's players.
    var onActiveChanged: (() -> Void)?

    private let profiles: ProfilesModel
    private let store: ProfileStore?
    private var keeper: SessionKeeper?
    /// Bumped with every sign-in and sign-out, so a late answer for an old sign-in changes nothing.
    private var generation = 0
    private var state: ProfileSyncState
    private var plays: PlayQueue
    private var running = false
    private var again = false
    private var soon: Task<Void, Never>?

    private static let installedKey = "account.installed"

    /// `-SpantherAccount signIn|signUp|code|forgot|reset` (Debug): the players sheet opens on that sign-in screen,
    /// for the CI screenshots.
    static let debugStep: String? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SpantherAccount"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }()

    init(profiles: ProfilesModel) {
        self.profiles = profiles
        backend = BackendSettings.config.map { Backend(config: $0) }
        let store = ProfileStore.defaultRoot.map { ProfileStore(root: $0) }
        self.store = store
        state = store?.loadSyncState() ?? ProfileSyncState()
        plays = store?.loadPlays() ?? PlayQueue()
        // The Keychain outlives the app: a fresh install starts signed out.
        let d = UserDefaults.standard
        if !d.bool(forKey: Self.installedKey) {
            KeychainSession.save(nil)
            d.set(true, forKey: Self.installedKey)
        }
        if backend != nil, Self.debugStep == nil, let s = KeychainSession.load() { use(s) }
        profiles.onChange = { [weak self] in self?.syncSoon() }
    }

    var signedIn: Bool { session != nil }

    // MARK: Signing in

    /// A new account. False: the code is in the email (`confirmSignUp`); true: signed in at once (the project does
    /// not confirm emails).
    @MainActor
    func signUp(email: String, password: String) async throws -> Bool {
        switch try await api().signUp(email: email, password: password, language: Loc.language.rawValue) {
        case .codeSent:
            return false
        case .signedIn(let s):
            use(s)
            return true
        }
    }

    @MainActor
    func confirmSignUp(email: String, code: String) async throws {
        use(try await api().confirmSignUp(email: email, code: code))
    }

    @MainActor
    func resendCode(email: String) async throws {
        try await api().resendSignUpCode(email: email)
    }

    @MainActor
    func signIn(email: String, password: String) async throws {
        use(try await api().signIn(email: email, password: password))
    }

    @MainActor
    func sendPasswordCode(email: String) async throws {
        try await api().sendPasswordCode(email: email)
    }

    /// The code from the password email: a sign-in to set the new password with (`setNewPassword`).
    @MainActor
    func confirmPasswordCode(email: String, code: String) async throws -> AuthSession {
        try await api().confirmPasswordCode(email: email, code: code)
    }

    /// Sets the new password and signs in. Signing in elsewhere ends: those phones ask for the new password.
    @MainActor
    func setNewPassword(_ password: String, recovery: AuthSession) async throws {
        do {
            try await api().setPassword(password, recovery)
        } catch let e as BackendError where e.reason == .samePassword {
            // The old one again: it is the password now either way.
        }
        use(recovery)
    }

    /// Signs out on this phone; its players stay here. Another account signed in later does not get them: they
    /// leave the phone and come back with this account.
    @MainActor
    func signOut() async {
        if let keeper { try? await keeper.call { b, s in await b.signOut(s) } }
        drop(endedElsewhere: false)
    }

    /// Deletes the account at once, with its players, progress and plays on the server. The players on this phone
    /// stay as the phone's own.
    @MainActor
    func deleteAccount() async throws {
        guard let keeper else { throw BackendError(.signedOut) }
        try await keeper.call { b, s in try await b.deleteAccount(s) }
        drop(endedElsewhere: false)
        state = ProfileSyncState()
        save()
    }

    private func api() throws -> Backend {
        guard let backend else { throw BackendError(.server, message: "no backend set") }
        return backend
    }

    private func use(_ s: AuthSession) {
        guard let backend else { return }
        generation += 1
        let g = generation
        keeper = SessionKeeper(backend: backend, session: s, saved: { [weak self] s in
            DispatchQueue.main.async { self?.kept(s, generation: g) }
        })
        session = s
        account = nil
        endedElsewhere = false
        KeychainSession.save(s)
        syncSoon(after: 0)
    }

    /// The keeper refreshed the tokens (`s`), or the server refused them (nil).
    private func kept(_ s: AuthSession?, generation g: Int) {
        guard g == generation, session != nil else { return }
        if let s {
            session = s
            KeychainSession.save(s)
        } else {
            drop(endedElsewhere: true)
        }
    }

    private func drop(endedElsewhere: Bool) {
        generation += 1
        soon?.cancel()
        keeper = nil
        session = nil
        account = nil
        status = .idle
        KeychainSession.save(nil)
        self.endedElsewhere = endedElsewhere
    }

    // MARK: Sync

    /// A play of a player (never of a clinic child) to send to the account; it waits on the phone until then.
    func queue(_ row: PlayRow) {
        guard backend != nil else { return }
        plays.add(row)
        try? store?.save(plays)
        syncSoon()
    }

    /// Syncs a moment from now; changes in the meantime go with the same sync.
    func syncSoon(after seconds: Double = 2) {
        guard keeper != nil else { return }
        soon?.cancel()
        soon = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    @MainActor
    private func sync() async {
        guard let keeper else { return }
        if running {
            again = true
            return
        }
        running = true
        status = .syncing
        repeat {
            again = false
            do {
                try await syncOnce(keeper)
                if self.keeper === keeper { status = .synced(Date()) }
            } catch let e as BackendError {
                if self.keeper === keeper { status = e.reason == .offline ? .offline : e.reason == .signedOut ? .idle : .failed }
                again = false
            } catch {
                if self.keeper === keeper { status = .failed }
                again = false
            }
        } while again && self.keeper === keeper
        running = false
    }

    /// One sync (the steps of GazeCore ProfileSync): the account's players in, the players it lacks out, then the
    /// plays waiting.
    @MainActor
    private func syncOnce(_ keeper: SessionKeeper) async throws {
        let account = try await keeper.call { b, s in try await b.account(s) }
        guard self.keeper === keeper else { return }
        self.account = account
        let server = try await keeper.call { b, s in try await b.pullProfiles(s) }
        guard self.keeper === keeper else { return }
        let before = profiles.book.activeID
        let rows = profiles.takeIn(server, account: account.id, state: &state, played: plays.players)
        save()
        if profiles.book.activeID != before { onActiveChanged?() }
        let sent = try await ProfileSync.send(rows) { batch in try await keeper.call { b, s in try await b.push(batch, s) } }
        guard self.keeper === keeper else { return }
        ProfileSync.sent(sent.sent, state: &state)
        save()
        let ready = plays.ready(for: state.synced)
        let played = try await ProfileSync.send(ready) { batch in try await keeper.call { b, s in try await b.push(batch, s) } }
        guard self.keeper === keeper else { return }
        plays.remove(Set((played.sent + played.refused).map(\.id)))
        save()
        let language = Loc.language.rawValue
        if account.language != language, ["ru", "kk", "en"].contains(language) {
            try? await keeper.call { b, s in
                try await b.setLanguage(language, s)
                try await b.setEmailLanguage(language, s)
            }
        }
    }

    private func save() {
        try? store?.save(state)
        try? store?.save(plays)
    }
}

/// The signed-in session in the Keychain, on this phone only.
enum KeychainSession {
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "spanther.account",
                                              kSecAttrAccount as String: "session"]

    static func load() -> AuthSession? {
        var q = item
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ s: AuthSession?) {
        SecItemDelete(item as CFDictionary)
        guard let s, let data = try? JSONEncoder().encode(s) else { return }
        var q = item
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
