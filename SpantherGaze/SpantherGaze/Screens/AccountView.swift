import SwiftUI

/// The adult's account, inside the players sheet: sign in, create an account (a code comes by email), a new
/// password by a code; once signed in, the account, its sync, signing out and deleting it. Landscape: the words on
/// the left, the fields on the right, so the keyboard leaves the field in sight.
struct AccountPanel: View {
    @ObservedObject var account: AccountModel
    let back: () -> Void
    let done: () -> Void

    enum Step: String { case signIn, signUp, code, forgot, reset }
    private enum Field: Hashable { case email, password, code }

    @State private var step: Step
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    /// What went wrong, in red; `note` is what happened, in ink.
    @State private var problem: String?
    @State private var note: String?
    @State private var resendAt = Date.distantPast
    @State private var recovery: AuthSession?
    @State private var deleting = false
    @FocusState private var focus: Field?

    init(account: AccountModel, back: @escaping () -> Void, done: @escaping () -> Void) {
        self.account = account
        self.back = back
        self.done = done
        let debug = AccountModel.debugStep.flatMap(Step.init)
        _step = State(initialValue: debug ?? .signIn)
        if debug == .code || debug == .reset {
            _email = State(initialValue: "mira@example.com")
            _note = State(initialValue: L("Код отправлен на {0}. Введите 6 цифр из письма.", "mira@example.com"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: back) {
                    Label(L("Игроки"), systemImage: "chevron.left")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Atlas.ink)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: done) { Text(L("Готово")) }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 130)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(Atlas.display(26)).foregroundStyle(Atlas.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 250, alignment: .leading)
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if let s = account.session { signedIn(s) } else { form }
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                    }
                    .onChange(of: focus) { f in
                        guard let f else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(f, anchor: .center) }
                    }
                }
            }
        }
        .confirmationDialog(L("Удалить аккаунт?"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L("Удалить аккаунт навсегда"), role: .destructive) { run { try await account.deleteAccount() } }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Игроки, их прогресс и итоги игр удалятся из аккаунта сразу и навсегда. На этом телефоне игроки останутся."))
        }
        .onChange(of: account.signedIn) { on in
            if on {
                password = ""
                code = ""
                problem = nil
                note = nil
                recovery = nil
            }
        }
    }

    // MARK: Words

    private var title: String {
        if account.session != nil { return L("Аккаунт") }
        switch step {
        case .signIn: return L("Вход")
        case .signUp: return L("Новый аккаунт")
        case .code: return L("Код из письма")
        case .forgot, .reset: return L("Новый пароль")
        }
    }

    private var explanation: String {
        if account.session != nil {
            return L("Имена игроков, их прогресс и итоги игр хранятся в аккаунте и есть на каждом телефоне, где вы вошли. Калибровка, камера и записи занятий остаются только на этом телефоне.")
        }
        switch step {
        case .signIn, .signUp:
            return L("Аккаунт нужен, чтобы игроки и их прогресс были на всех ваших телефонах. Без него всё работает на этом телефоне. Калибровка и камера никогда не уходят с телефона.")
        case .code:
            return L("Письмо может прийти через минуту. Проверьте папку «Спам», если его нет.")
        case .forgot, .reset:
            return L("Пришлём код на почту аккаунта. После нового пароля на других телефонах нужно будет войти заново.")
        }
    }

    // MARK: Signed out

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.endedElsewhere, step == .signIn {
                line(L("Вход на этом телефоне закончился: пароль сменили или аккаунт удалили. Войдите снова."), Atlas.ink)
            }
            if let note { line(note, Atlas.ink) }
            switch step {
            case .signIn:
                emailField
                passwordField(L("Пароль"), new: false)
                primary(L("Войти"), enabled: validEmail && !password.isEmpty) { try await signIn() }
                secondary(L("Создать аккаунт")) { go(.signUp) }
                textButton(L("Забыли пароль?")) { go(.forgot) }
            case .signUp:
                emailField
                passwordField(L("Пароль, не меньше 8 знаков"), new: true)
                primary(L("Создать аккаунт"), enabled: validEmail && password.count >= 8) { try await signUp() }
                secondary(L("У меня уже есть аккаунт")) { go(.signIn) }
            case .code:
                codeField
                primary(L("Подтвердить"), enabled: validCode) {
                    try await account.confirmSignUp(email: email, code: code)
                }
                resendButton { try await account.resendCode(email: email) }
                textButton(L("Другая почта")) { go(.signUp) }
            case .forgot:
                emailField
                primary(L("Прислать код"), enabled: validEmail) {
                    try await account.sendPasswordCode(email: email)
                    resendAt = Date().addingTimeInterval(60)
                    note = L("Если у этой почты есть аккаунт, на неё пришёл код.")
                    step = .reset
                }
                secondary(L("Назад ко входу")) { go(.signIn) }
            case .reset:
                codeField
                passwordField(L("Новый пароль, не меньше 8 знаков"), new: true)
                primary(L("Сохранить пароль"), enabled: validCode && password.count >= 8) {
                    if recovery == nil { recovery = try await account.confirmPasswordCode(email: email, code: code) }
                    if let r = recovery { try await account.setNewPassword(password, recovery: r) }
                }
                resendButton { try await account.sendPasswordCode(email: email) }
            }
            if let problem { line(problem, Atlas.vermilion) }
        }
    }

    private func signIn() async throws {
        do {
            try await account.signIn(email: email, password: password)
        } catch let e as BackendError where e.reason == .emailNotConfirmed {
            // Signed up, the code never typed: a new one goes, and the code screen asks for it.
            step = .code
            code = ""
            do {
                try await account.resendCode(email: email)
                resendAt = Date().addingTimeInterval(60)
                note = L("Почта ещё не подтверждена. Мы отправили новый код на {0}.", Self.clean(email))
            } catch {
                note = L("Почта ещё не подтверждена. Введите код из письма.")
            }
        }
    }

    private func signUp() async throws {
        if try await account.signUp(email: email, password: password) { return }
        step = .code
        code = ""
        resendAt = Date().addingTimeInterval(60)
        note = L("Код отправлен на {0}. Введите 6 цифр из письма.", Self.clean(email))
    }

    private func go(_ s: Step) {
        step = s
        problem = nil
        note = nil
        code = ""
        recovery = nil
        if s != .signIn, s != .signUp { password = "" }
    }

    // MARK: Signed in

    private func signedIn(_ s: AuthSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.email).font(.system(size: 18, weight: .heavy)).foregroundStyle(Atlas.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    if account.account?.isAdmin == true { badge(L("Админ"), Atlas.gold) }
                    if let until = account.account?.premiumUntil, until > Date() {
                        badge(L("Премиум до {0}", until.formatted(.dateTime.day().month(.abbreviated).year()
                            .locale(Loc.locale))), Atlas.sky)
                    }
                }
                Text(Self.status(account.status)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InkSlab(shape: RoundedRectangle(cornerRadius: 14), fill: Atlas.cream, depth: 3, line: 2))
            Button { account.syncSoon(after: 0) } label: { Text(L("Синхронизировать сейчас")) }
                .buttonStyle(AtlasSecondaryButton())
                .disabled(account.status == .syncing)
            Button { run { await account.signOut() } } label: { Text(L("Выйти")) }
                .buttonStyle(AtlasSecondaryButton())
                .disabled(busy)
            textButton(L("Удалить аккаунт"), colour: Atlas.vermilion) { deleting = true }
            if let problem { line(problem, Atlas.vermilion) }
        }
    }

    // MARK: Pieces

    private var emailField: some View {
        TextField(L("Почта"), text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focus = step == .forgot ? nil : .password }
            .focused($focus, equals: .email)
            .modifier(FieldLook())
            .id(Field.email)
    }

    private func passwordField(_ prompt: String, new: Bool) -> some View {
        SecureField(prompt, text: $password)
            .textContentType(new ? .newPassword : .password)
            .submitLabel(.done)
            .focused($focus, equals: .password)
            .modifier(FieldLook())
            .id(Field.password)
    }

    private var codeField: some View {
        TextField(L("Код из письма"), text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(10)) }))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focus, equals: .code)
            .modifier(FieldLook())
            .id(Field.code)
    }

    private func primary(_ title: String, enabled: Bool, action: @escaping () async throws -> Void) -> some View {
        Button { run(action) } label: {
            if busy { ProgressView().tint(Atlas.ink) } else { Text(title) }
        }
        .buttonStyle(AtlasPrimaryButton())
        .disabled(!enabled || busy)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(AtlasSecondaryButton())
            .disabled(busy)
    }

    private func textButton(_ title: String, colour: Color = Atlas.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(colour).underline()
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// Asks for the code again, a minute after the last one (Supabase sends one a minute to an address).
    private func resendButton(_ send: @escaping () async throws -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = Int(resendAt.timeIntervalSince(context.date).rounded(.up))
            textButton(wait > 0 ? L("Прислать код ещё раз через {0} с", wait) : L("Прислать код ещё раз")) {
                run {
                    try await send()
                    resendAt = Date().addingTimeInterval(60)
                    note = L("Новый код отправлен на {0}.", Self.clean(email))
                }
            }
            .disabled(wait > 0 || busy)
        }
    }

    private func badge(_ text: String, _ fill: Color) -> some View {
        Text(text)
            .font(Atlas.caption.weight(.heavy))
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Slant(lean: 6).fill(fill))
    }

    private func line(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Runs one step: the buttons wait, and a refusal shows in words.
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        problem = nil
        Task { @MainActor in
            do {
                try await action()
            } catch let e as BackendError {
                problem = Self.words(e.reason)
            } catch {
                problem = Self.words(.server)
            }
            busy = false
        }
    }

    private var validEmail: Bool {
        let e = Self.clean(email)
        guard let at = e.firstIndex(of: "@"), at > e.startIndex else { return false }
        let domain = e[e.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !e.contains(" ")
    }

    private var validCode: Bool { (6...10).contains(code.count) }

    static func clean(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    // MARK: Shared words

    static func words(_ reason: BackendError.Reason) -> String {
        switch reason {
        case .wrongPassword: return L("Неверная почта или пароль.")
        case .emailNotConfirmed: return L("Почта ещё не подтверждена. Введите код из письма.")
        case .emailTaken: return L("Эта почта уже зарегистрирована. Войдите или восстановите пароль.")
        case .weakPassword: return L("Пароль слишком простой: нужно не меньше 8 знаков.")
        case .invalidEmail: return L("Проверьте адрес почты.")
        case .badCode: return L("Код не подошёл или устарел. Запросите новый.")
        case .samePassword: return L("Это прежний пароль.")
        case .tooManyRequests: return L("Слишком часто. Подождите минуту и попробуйте снова.")
        case .mailFailed: return L("Не удалось отправить письмо. Попробуйте позже.")
        case .offline: return L("Нет связи с сервером. Проверьте интернет.")
        case .signedOut, .tokenExpired: return L("Вход закончился. Войдите снова.")
        case .rejected, .server: return L("Что-то пошло не так. Попробуйте ещё раз.")
        }
    }

    static func status(_ s: AccountModel.SyncStatus) -> String {
        switch s {
        case .idle: return L("Ещё не синхронизировано")
        case .syncing: return L("Синхронизация…")
        case .synced(let at): return L("Синхронизировано в {0}", at.formatted(.dateTime.hour().minute().locale(Loc.locale)))
        case .offline: return L("Нет сети: отправим, когда появится")
        case .failed: return L("Не удалось синхронизировать, попробуем позже")
        }
    }
}

/// A text field in the sheet's look.
private struct FieldLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .atlasChip()
    }
}
