import SwiftUI

/// A player's round badge: their colour with the first letter of their name.
struct AvatarDot: View {
    let avatar: Int
    let initial: String
    var size: CGFloat = 32

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.48, weight: .black, design: .rounded))
            .foregroundStyle(ProfilesModel.onColour(avatar))
            .frame(width: size, height: size)
            .background(Circle().fill(ProfilesModel.colour(avatar)))
            .overlay(Circle().stroke(Atlas.ink, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Who plays now, in the menu's header: the player's badge and name, or the clinic child's code when one was
/// picked on «Кто играет?». Opens the players.
struct ProfileChip: View {
    @ObservedObject var profiles: ProfilesModel
    @ObservedObject var clinic: ClinicModel
    let withName: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let c = clinic.playing {
                    Image(systemName: "cross.case")
                    if withName { Text(c.child.code).lineLimit(1) }
                } else if let p = profiles.active {
                    AvatarDot(avatar: p.avatar, initial: ProfilesModel.initial(p), size: 28)
                    if withName { Text(ProfilesModel.name(p)).lineLimit(1) }
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .atlasChip()
            .fixedSize()
        }
        .accessibilityLabel(clinic.playing.map { L("Играет {0}", $0.child.code) }
                            ?? L("Играет {0}", profiles.active.map(ProfilesModel.name) ?? ""))
        .accessibilityHint(L("Сменить игрока"))
    }
}

/// The players on this phone: pick who plays, add one, rename or recolour, delete one who is not playing. Picking
/// and adding change the calibration, so they happen once the sheet has closed (`onPick`, `onAdd`).
struct ProfilesSheet: View {
    @ObservedObject var profiles: ProfilesModel
    @ObservedObject var clinic: ClinicModel
    @ObservedObject var account: AccountModel
    let onPick: (UUID) -> Void
    let onAdd: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The player being edited, or a new one (`adding`).
    @State private var editing: UUID?
    @State private var adding = false
    @State private var draftName = ""
    @State private var draftAvatar = 0
    @State private var deleting: PlayerProfile?
    /// The account's page instead of the list.
    @State private var showAccount = AccountModel.debugStep != nil

    var body: some View {
        Group {
            if showAccount {
                AccountPanel(account: account, back: { showAccount = false }, done: { dismiss() })
            } else {
                players
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Atlas.paper.ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }

    private var players: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(L("Игроки")).font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                Spacer()
                Button { dismiss() } label: { Text(L("Готово")) }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 130)
            }
            if let c = clinic.playing {
                Text(L("Сейчас играет ребёнок клиники {0}. Выбери игрока, чтобы играть дома.", c.child.code))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(profiles.book.visible) { p in
                        if editing == p.id { editor(for: p) } else { row(p) }
                    }
                    if adding { editor(for: nil) } else { addButton }
                }
                .padding(.vertical, 4)
            }
            footer
        }
        .confirmationDialog(L("Удалить игрока?"), isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { p in
            Button(L("Удалить {0}", ProfilesModel.name(p)), role: .destructive) { onDelete(p.id) }
            Button(L("Отмена"), role: .cancel) {}
        } message: { _ in
            Text(account.session == nil ? L("Калибровка этого игрока тоже удалится.")
                 : L("Игрок удалится и из аккаунта, на всех телефонах. Его калибровка тоже удалится."))
        }
    }

    /// Where the players are kept, and the way to the account when the app has one.
    @ViewBuilder private var footer: some View {
        if account.backend == nil {
            Text(L("Игроки и их калибровка хранятся только на этом телефоне. У каждого игрока своя калибровка: игра просит новую через неделю или когда точность падает."))
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.session?.email ?? L("Без аккаунта: игроки только на этом телефоне"))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Atlas.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(account.session == nil
                         ? L("Войдите, чтобы игроки и их прогресс были на всех ваших телефонах. Калибровка у каждого игрока своя и всегда остаётся на этом телефоне.")
                         : AccountPanel.status(account.status))
                        .font(Atlas.caption)
                        .foregroundStyle(account.endedElsewhere ? Atlas.vermilion : Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { showAccount = true } label: { Text(account.session == nil ? L("Войти") : L("Аккаунт")) }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 150)
            }
        }
    }

    /// Deleting is done here: only a player who is not playing can be deleted, so the calibration does not change.
    private func onDelete(_ id: UUID) {
        profiles.remove(id)
        deleting = nil
    }

    private func playing(_ p: PlayerProfile) -> Bool { clinic.playing == nil && profiles.book.activeID == p.id }

    private func row(_ p: PlayerProfile) -> some View {
        let on = playing(p)
        return HStack(spacing: 12) {
            Button {
                onPick(p.id)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    AvatarDot(avatar: p.avatar, initial: ProfilesModel.initial(p), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProfilesModel.name(p)).font(.system(size: 17, weight: .heavy)).foregroundStyle(Atlas.ink)
                        Text(calibrationLine(p)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    }
                    Spacer(minLength: 8)
                    if on {
                        Text(L("играет"))
                            .font(Atlas.caption.weight(.heavy))
                            .foregroundStyle(Atlas.ink)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Slant(lean: 6).fill(Atlas.gold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? L("{0}, играет", ProfilesModel.name(p)) : L("Играть за {0}", ProfilesModel.name(p)))
            iconButton("pencil", L("Изменить {0}", ProfilesModel.name(p))) { startEditing(p) }
            if !on, profiles.book.visible.count > 1 {
                iconButton("trash", L("Удалить {0}", ProfilesModel.name(p))) { deleting = p }
            }
        }
        .padding(12)
        .background(InkSlab(shape: RoundedRectangle(cornerRadius: 14), fill: on ? Atlas.cream : Atlas.paperShade,
                            depth: on ? 4 : 2, line: on ? 3 : 2))
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Atlas.ink)
                .frame(width: 44, height: 44)
                .atlasChip()
        }
        .accessibilityLabel(label)
    }

    private func calibrationLine(_ p: PlayerProfile) -> String {
        guard let c = profiles.calibrations[p.id] else { return L("Калибровки ещё нет") }
        if c.poor { return L("Точность упала, нужна новая калибровка") }
        let when = c.madeAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Loc.locale))
        return L("Калибровка от {0}", when)
    }

    private var addButton: some View {
        Button {
            editing = nil
            draftName = ""
            draftAvatar = (0..<ProfileBook.avatarCount).first { i in !profiles.book.visible.contains { $0.avatar == i } } ?? 0
            adding = true
        } label: {
            Label(L("Добавить игрока"), systemImage: "plus")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Atlas.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(AtlasSecondaryButton())
    }

    private func startEditing(_ p: PlayerProfile) {
        adding = false
        draftName = ProfilesModel.name(p)
        draftAvatar = p.avatar
        editing = p.id
    }

    /// The name and colour of a player (`p`) or of a new one (nil).
    private func editor(for p: PlayerProfile?) -> some View {
        let initial = draftName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        return VStack(alignment: .leading, spacing: 10) {
            TextField(L("Имя"), text: $draftName)
                .font(.system(size: 17, weight: .semibold))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .atlasChip()
            HStack(spacing: 8) {
                ForEach(0..<ProfileBook.avatarCount, id: \.self) { i in
                    Button { draftAvatar = i } label: {
                        AvatarDot(avatar: i, initial: initial, size: 36)
                            .padding(3)
                            .overlay(Circle().stroke(i == draftAvatar ? Atlas.ink : .clear, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Цвет {0}", i + 1))
                    .accessibilityAddTraits(i == draftAvatar ? .isSelected : [])
                }
            }
            HStack(spacing: 12) {
                Button {
                    editing = nil
                    adding = false
                } label: { Text(L("Отмена")) }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 150)
                Button {
                    if let p {
                        profiles.edit(p.id, name: draftName, avatar: draftAvatar)
                        editing = nil
                    } else {
                        onAdd(draftName, draftAvatar)
                        dismiss()
                    }
                } label: { Text(p == nil ? L("Добавить") : L("Сохранить")) }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 170)
                    .disabled(ProfileBook.clean(name: draftName) == nil)
            }
        }
        .padding(12)
        .background(InkSlab(shape: RoundedRectangle(cornerRadius: 14), fill: Atlas.cream, depth: 4, line: 3))
    }
}
