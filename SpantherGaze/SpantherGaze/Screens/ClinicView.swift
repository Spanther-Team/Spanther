import SwiftUI

/// The clinic (architecture proposal §1, "Picker and roles"): «Кто играет?» with the children's emblem tiles, and for
/// the child picked, «Начать занятие» (the probe, then a game). Face ID or the passcode opens the clinician's side:
/// adding children, courses, procedure marks, the course charts, the export and the parent PIN. The parent PIN opens
/// the parent's summary in plain words. A child sees only the tiles and the button.
struct ClinicView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ClinicContent(app: app, clinic: app.clinic)
    }
}

/// A sheet about one child.
private struct ChildSheet: Identifiable {
    let id: UUID
}

private struct ClinicContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var clinic: ClinicModel
    @State private var adding = false
    @State private var detail: ChildSheet?
    @State private var parentReport: ChildSheet?
    @State private var askPin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if clinic.unguarded {
                Text(L("На телефоне нет код-пароля: профили и графики открыты всем. Задайте код в настройках iPhone."))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.vermilion)
            }
            if let p = clinic.problem {
                Text(p).font(Atlas.caption).foregroundStyle(Atlas.vermilion)
            }
            tiles
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .sheet(isPresented: $adding) { AddChildSheet(clinic: clinic) }
        .sheet(item: $detail) { s in ChildDetailSheet(app: app, clinic: clinic, childID: s.id) }
        .sheet(item: $parentReport) { s in ParentSheet(clinic: clinic, childID: s.id) }
        .sheet(isPresented: $askPin) { PinSheet(clinic: clinic) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { app.route = .menu } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(Atlas.ink)
            .accessibilityLabel(L("В меню"))
            Text(L("Кто играет?")).font(Atlas.display(26)).foregroundStyle(Atlas.ink)
            Spacer()
            switch clinic.role {
            case .clinician?:
                roleLabel(L("Специалист"))
            case .parent?:
                roleLabel(L("Родитель"))
            case nil:
                Button { clinic.unlockClinician() } label: { Label(L("Специалист"), systemImage: "faceid") }
                    .buttonStyle(AtlasSecondaryButton())
                if clinic.hasParentPin {
                    Button { askPin = true } label: { Label(L("Родитель"), systemImage: "lock") }
                        .buttonStyle(AtlasSecondaryButton())
                }
            }
        }
    }

    private func roleLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Atlas.ink)
            Button { clinic.lock() } label: { Label(L("Закрыть"), systemImage: "lock.open") }
                .buttonStyle(AtlasSecondaryButton())
        }
    }

    private var tiles: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)], spacing: 12) {
                ForEach(Array(clinic.active.enumerated()), id: \.element.id) { k, r in
                    Button { app.pick(child: r.id) } label: { tile(r) }
                        .buttonStyle(.plain)
                        .selectedPop(r.id == clinic.playingID)
                        .kineticEntrance(order: k)
                        .accessibilityLabel(L("Играет {0}", r.child.tileName))
                }
                if clinic.role == .clinician {
                    Button { adding = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 30, weight: .semibold))
                            Text(L("Ребёнок")).font(Atlas.caption)
                        }
                        .foregroundStyle(Atlas.ink)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(CutPlate(cut: 14).fill(Atlas.paper.opacity(0.7)))
                        .overlay(CutPlate(cut: 14).strokeBorder(Atlas.ink.opacity(0.6),
                                                                style: StrokeStyle(lineWidth: Atlas.line, dash: [6, 4])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Добавить ребёнка"))
                }
            }
            if clinic.active.isEmpty {
                Text(clinic.role == .clinician ? L("Добавьте первого ребёнка: код центра, значок и прозвище.")
                                               : L("Пока здесь никого нет. Специалист добавит ребёнка после входа по Face ID."))
                    .font(Atlas.body)
                    .foregroundStyle(Atlas.inkSoft)
                    .padding(.top, 8)
            }
        }
    }

    private func tile(_ r: ChildRecord) -> some View {
        let picked = r.id == clinic.playingID
        return VStack(spacing: 8) {
            Image(systemName: ClinicText.emblem(r.child.emblem))
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Atlas.ink)
            Text(r.child.tileName).font(.system(size: 15, weight: picked ? .heavy : .semibold, design: .rounded))
                .foregroundStyle(Atlas.ink).lineLimit(1)
            if clinic.role != nil, r.child.nickname != nil {
                Text(r.child.code).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        // The one who plays now stands on a gold plate, lifted higher than the others.
        .background(InkSlab(shape: CutPlate(cut: 14), fill: picked ? Atlas.gold : Atlas.paper, depth: picked ? 6 : 4))
    }

    @ViewBuilder private var footer: some View {
        if let r = clinic.playing {
            HStack(spacing: 12) {
                Button { app.openProbe() } label: { Text(L("Начать занятие")) }
                    .buttonStyle(AtlasPrimaryButton())
                    .disabled(!(app.eyeTrackingSupported || app.autoplay == "probe"))
                if clinic.role == .clinician {
                    Button { detail = ChildSheet(id: r.id) } label: { Text(L("Профиль и графики")) }
                        .buttonStyle(AtlasSecondaryButton())
                }
                if clinic.role == .parent {
                    Button { parentReport = ChildSheet(id: r.id) } label: { Text(L("Как дела")) }
                        .buttonStyle(AtlasSecondaryButton())
                }
                Spacer()
                Text(courseLine(r)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
            if !app.eyeTrackingSupported {
                Text(L("Проба меряет взгляд: на этом iPhone нет трекинга лица.")).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
        }
    }

    private func courseLine(_ r: ChildRecord) -> String {
        guard let c = r.openCourse else { return L("Курс не начат: занятие пойдёт без номера") }
        let done = r.sessions(of: c.id).count
        return L("{0}: занятие {1} из {2}, {3}", c.title, done + 1, c.plannedSessions, ClinicText.place(c.runsAt))
    }
}

// MARK: Adding a child

private struct AddChildSheet: View {
    @ObservedObject var clinic: ClinicModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var nickname = ""
    @State private var birthYear = ""
    @State private var emblem = 0

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Код центра")) {
                    TextField(L("Например, А-017"), text: $code).textInputAutocapitalization(.characters)
                }
                Section(L("Прозвище на плитке (не имя)")) {
                    TextField(L("Например, Лиса"), text: $nickname)
                }
                Section(L("Год рождения")) {
                    TextField(L("Необязательно"), text: $birthYear).keyboardType(.numberPad)
                }
                Section(L("Значок")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(0..<Child.emblemCount, id: \.self) { i in
                            Button { emblem = i } label: {
                                Image(systemName: ClinicText.emblem(i))
                                    .font(.system(size: 26))
                                    .frame(width: 48, height: 48)
                                    .foregroundStyle(i == emblem ? Atlas.vermilion : Atlas.ink)
                                    .overlay(Circle().stroke(i == emblem ? Atlas.vermilion : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let p = clinic.problem { Text(p).foregroundStyle(Atlas.vermilion) }
            }
            .navigationTitle(L("Новый ребёнок"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Добавить")) {
                        let year = Int(birthYear.trimmingCharacters(in: .whitespaces))
                        if clinic.addChild(code: code, emblem: emblem, nickname: nickname, birthYear: year) != nil { dismiss() }
                    }
                }
            }
        }
    }
}

// MARK: The parent PIN

private struct PinSheet: View {
    @ObservedObject var clinic: ClinicModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        NavigationStack {
            Form {
                SecureField(L("PIN родителя"), text: $pin).keyboardType(.numberPad)
                if wrong { Text(L("Не тот PIN")).foregroundStyle(Atlas.vermilion) }
            }
            .navigationTitle(L("Для родителей"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Открыть")) {
                        if clinic.unlockParent(pin: pin) { dismiss() } else { wrong = true }
                    }
                }
            }
        }
    }
}

private struct ParentSheet: View {
    @ObservedObject var clinic: ClinicModel
    let childID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let r = clinic.record(childID), let c = r.openCourse ?? r.courses.last {
                    ParentSummary(data: CourseData(record: r, course: c)).padding(20)
                } else {
                    Text(L("Курс ещё не начат.")).font(Atlas.body).padding(20)
                }
            }
            .navigationTitle(clinic.record(childID)?.child.tileName ?? "")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } } }
        }
    }
}

// MARK: The clinician's view of one child

private struct ChildDetailSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var clinic: ClinicModel
    let childID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var courseTitle = L("Курс 1")
    @State private var planned = 30
    @State private var place = Session.Place.clinic
    @State private var procedureKind = Procedure.Kind.tms
    @State private var procedureDate = Date()
    @State private var procedureLabel = ""
    @State private var parentPin = ""
    @State private var exported: [URL] = []
    @State private var confirmArchive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let r = clinic.record(childID) {
                    VStack(alignment: .leading, spacing: 18) {
                        identity(r)
                        course(r)
                        if let c = r.openCourse ?? r.courses.last { charts(r, c) }
                        sessions(r)
                        parentPinRow
                    }
                    .padding(20)
                }
            }
            .navigationTitle(clinic.record(childID)?.child.code ?? "")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } } }
            .confirmationDialog(L("Убрать ребёнка в архив? Записи и графики останутся."), isPresented: $confirmArchive,
                                titleVisibility: .visible) {
                Button(L("В архив"), role: .destructive) {
                    clinic.archive(child: childID)
                    dismiss()
                }
            }
        }
    }

    private func identity(_ r: ChildRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ClinicText.emblem(r.child.emblem)).font(.system(size: 34)).foregroundStyle(Atlas.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.child.tileName).font(Atlas.title).foregroundStyle(Atlas.ink)
                Text([r.child.code, r.child.birthYear.map { L("{0} г. р.", $0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
            Spacer()
            Button(L("В архив")) { confirmArchive = true }.foregroundStyle(Atlas.vermilion)
        }
    }

    @ViewBuilder private func course(_ r: ChildRecord) -> some View {
        if let c = r.openCourse {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("{0}: занятий {1} из {2}, {3}", c.title, r.sessions(of: c.id).count, c.plannedSessions, ClinicText.place(c.runsAt)))
                    .font(Atlas.title).foregroundStyle(Atlas.ink)
                HStack {
                    Picker(L("Процедура"), selection: $procedureKind) {
                        ForEach(Procedure.Kind.allCases, id: \.self) { k in Text(ClinicText.procedure(k)).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    DatePicker("", selection: $procedureDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                }
                HStack {
                    TextField(L("Название аппарата, если нужно (например, BrainsWay)"), text: $procedureLabel)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Отметить процедуру")) {
                        clinic.markProcedure(child: r.id, course: c.id, kind: procedureKind, date: procedureDate, label: procedureLabel)
                        procedureLabel = ""
                    }
                    .buttonStyle(AtlasSecondaryButton())
                }
                Button(L("Закрыть курс")) { clinic.closeCourse(child: r.id, course: c.id) }
                    .foregroundStyle(Atlas.inkSoft)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Новый курс")).font(Atlas.title).foregroundStyle(Atlas.ink)
                HStack {
                    TextField(L("Название"), text: $courseTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Stepper(L("Занятий: {0}", planned), value: $planned, in: 5...60)
                    Picker(L("Где"), selection: $place) {
                        Text(L("В центре")).tag(Session.Place.clinic)
                        Text(L("Дома")).tag(Session.Place.home)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                HStack {
                    Button("25") { planned = 25 }.buttonStyle(AtlasSecondaryButton())
                    Button("30") { planned = 30 }.buttonStyle(AtlasSecondaryButton())
                    Button(L("Начать курс")) { clinic.startCourse(child: r.id, title: courseTitle, planned: planned, place: place) }
                        .buttonStyle(AtlasPrimaryButton())
                }
            }
        }
    }

    private func charts(_ r: ChildRecord, _ c: Course) -> some View {
        let data = CourseData(record: r, course: c)
        var sems: [ProbeMetric: Double] = [:]
        for m in ProbeMetric.charted { sems[m] = CourseData.sem(m, records: clinic.records) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Графики курса «{0}»", c.title)).font(Atlas.title).foregroundStyle(Atlas.ink)
                Spacer()
                Button {
                    // The files for the center stay in Russian, whatever the interface's language.
                    exported = Loc.inRussian { ClinicExport.files(data, sems: sems, store: clinic.store) }
                } label: { Label(L("Подготовить выгрузку"), systemImage: "doc.richtext") }
                    .buttonStyle(AtlasSecondaryButton())
                if !exported.isEmpty {
                    ShareLink(items: exported) { Label(L("Отправить PDF, таблицу и ZIP"), systemImage: "square.and.arrow.up") }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ProbeMetric.charted, id: \.self) { m in MetricChart(data: data, metric: m, sem: sems[m]) }
            }
            CourseCard(data: data, sems: sems)
        }
    }

    private func sessions(_ r: ChildRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Занятия")).font(Atlas.title).foregroundStyle(Atlas.ink)
            ForEach(r.sessions.reversed()) { s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.number.map { "№ \($0)" } ?? "—").monospacedDigit().frame(width: 44, alignment: .leading)
                    Text(ClinicText.date.string(from: s.start)).frame(width: 110, alignment: .leading)
                    if let m = s.probe?.metrics {
                        Text(ClinicText.headline.map { ClinicText.value($0, m[$0.rawValue]) }.joined(separator: " · "))
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(s.probe == nil ? L("без пробы") : (s.onChart ? L("на графике") : L("вне графика")))
                        .foregroundStyle(s.onChart ? Atlas.ink : Atlas.inkSoft)
                    if !s.tags.isEmpty { Text(s.tags.joined(separator: ", ")).foregroundStyle(Atlas.inkSoft) }
                    Menu {
                        ForEach([L("после ТМС"), L("после лазера"), L("после нейрофидбека"), L("сонный"), L("болеет")], id: \.self) { tag in
                            Button(tag) { clinic.tagSession(child: r.id, session: s.id, tags: s.tags + [tag], note: s.note) }
                        }
                        Button(L("Снять теги")) { clinic.tagSession(child: r.id, session: s.id, tags: [], note: s.note) }
                        Button(L("Аннулировать (ошибка, не тот ребёнок)"), role: .destructive) {
                            clinic.voidSession(child: r.id, session: s.id, reason: L("аннулировано специалистом"))
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 32) }
                }
                .font(Atlas.caption)
                .foregroundStyle(Atlas.ink)
            }
            if r.sessions.isEmpty { Text(L("Занятий пока нет.")).font(Atlas.caption).foregroundStyle(Atlas.inkSoft) }
        }
    }

    private var parentPinRow: some View {
        HStack {
            Text(clinic.hasParentPin ? L("PIN родителя задан") : L("PIN родителя не задан")).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            SecureField(L("Новый PIN, 4–8 цифр"), text: $parentPin).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Button(L("Сохранить PIN")) {
                if clinic.setParentPin(parentPin) { parentPin = "" }
            }
            .disabled(!ClinicModel.validPin(parentPin))
        }
    }
}
