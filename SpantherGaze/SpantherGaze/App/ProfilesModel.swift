import Foundation
import SwiftUI

/// The players on this phone (GazeCore `ProfileBook`, kept by `ProfileStore` in Application Support/profiles) for
/// the screens, and each player's kept calibration. Plain files on the phone: nothing here leaves it (the backend
/// sync, when it comes, sends profiles and progress, never a calibration). Main thread.
final class ProfilesModel: ObservableObject {
    @Published private(set) var book: ProfileBook
    /// When each player's kept calibration was made, and whether play found it poor (for the list).
    @Published private(set) var calibrations: [UUID: (madeAt: Date, poor: Bool)] = [:]

    private let store: ProfileStore?

    /// The colours a player can pick, in `PlayerProfile.avatar` order.
    static let colours: [Color] = [Atlas.sky, Atlas.emerald, Atlas.gold, Atlas.vermilion, Atlas.energy, Atlas.ink,
                                   Atlas.grassPale, Atlas.skyPale]

    static func colour(_ avatar: Int) -> Color { colours[min(max(avatar, 0), colours.count - 1)] }
    /// Ink on the pale colours, cream on the strong ones.
    static func onColour(_ avatar: Int) -> Color { [2, 4, 6, 7].contains(avatar) ? Atlas.ink : Atlas.cream }

    /// The first letter of the name, for the avatar.
    static func initial(_ p: PlayerProfile) -> String { p.name.first.map { String($0).uppercased() } ?? "?" }

    init() {
        store = ProfileStore.defaultRoot.map { ProfileStore(root: $0) }
        var b = store?.loadBook() ?? ProfileBook()
        let first = b.profiles.isEmpty
        if b.ensureOne(defaultName: L("Игрок {0}", 1), now: Date()) {
            if first { Self.bringOldProgress(into: &b) }
            try? store?.save(b)
        }
        book = b
        reloadCalibrations()
    }

    var active: PlayerProfile? { book.active }

    // MARK: Players

    @discardableResult
    func add(name: String, avatar: Int? = nil) -> PlayerProfile? {
        var made: PlayerProfile?
        change { made = $0.add(name: name, avatar: avatar, now: Date()) }
        return made
    }

    @discardableResult
    func edit(_ id: UUID, name: String? = nil, avatar: Int? = nil) -> Bool {
        var ok = false
        change { ok = $0.edit(id, name: name, avatar: avatar, now: Date()) }
        return ok
    }

    func activate(_ id: UUID) { change { $0.activate(id) } }

    /// Deletes a player and their calibration at once; the book keeps a tombstone for the sync.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        var ok = false
        change { ok = $0.remove(id, now: Date()) }
        if ok {
            store?.removeCalibration(id)
            reloadCalibrations()
        }
        return ok
    }

    func progress(_ key: String) -> String? { book.progress(key) }
    func setProgress(_ key: String, _ value: String?) { change { $0.setProgress(key, value, now: Date()) } }

    private func change(_ edit: (inout ProfileBook) -> Void) {
        var b = book
        edit(&b)
        guard b != book else { return }
        book = b
        try? store?.save(b)
    }

    // MARK: Calibrations

    func calibration(_ id: UUID) -> ProfileCalibration? { store?.loadCalibration(id) }

    func keep(_ c: ProfileCalibration) {
        try? store?.save(c)
        reloadCalibrations()
    }

    /// Play found the player's calibration poor: the next eye mode, in this launch or the next, calibrates again.
    func markPoor(_ id: UUID, _ reason: CalibrationHealth.Reason) {
        guard var c = calibration(id), c.poor == nil else { return }
        c.poor = reason
        keep(c)
    }

    private func reloadCalibrations() {
        var all: [UUID: (madeAt: Date, poor: Bool)] = [:]
        for p in book.visible {
            if let c = store?.loadCalibration(p.id) { all[p.id] = (c.stored.madeAt, c.poor != nil) }
        }
        calibrations = all
    }

    // MARK: From before profiles

    /// Wink Beat's progress was kept for the phone before profiles: the first player takes it.
    private static func bringOldProgress(into b: inout ProfileBook) {
        let d = UserDefaults.standard
        if let last = d.string(forKey: "winkbeat.lastDifficulty") { b.setProgress(WinkBeatProgress.lastKey, last, now: Date()) }
        if d.bool(forKey: "winkbeat.hardOpen") { b.setProgress(WinkBeatProgress.hardKey, "1", now: Date()) }
    }
}
