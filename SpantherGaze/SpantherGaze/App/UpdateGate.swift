import SwiftUI

/// Closes the app while the App Store has a newer version than the one installed: the player sees one screen
/// with a button to the App Store and nothing else, until the update is installed.
///
/// The newest version comes from the App Store lookup (itunes.apple.com/lookup by bundle id). It is checked on
/// launch and each time the app comes back to the front. The last version seen there is kept, so going offline
/// does not open a phone that already knows it is behind. A failed lookup never blocks on its own.
///
/// Debug builds (Xcode runs, the CI simulator bot) never check, so they are not locked out by a newer release.
@MainActor
final class UpdateGate: ObservableObject {
    static let appStoreID = "6832000600"

    /// The App Store version the installed one is behind, or nil while the app may be used.
    @Published private(set) var requiredVersion: String?

    private let storedKey = "UpdateGate.latestStoreVersion"
    private var checking = false

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        #if !DEBUG
        if let stored = UserDefaults.standard.string(forKey: storedKey) {
            apply(storeVersion: stored)
        }
        #endif
    }

    func check() {
        #if !DEBUG
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            if let version = await Self.fetchStoreVersion() {
                UserDefaults.standard.set(version, forKey: storedKey)
                apply(storeVersion: version)
            }
        }
        #endif
    }

    func openAppStore() {
        let urls = ["itms-apps://apps.apple.com/app/id\(Self.appStoreID)", "https://apps.apple.com/app/id\(Self.appStoreID)"]
        guard let first = URL(string: urls[0]), let fallback = URL(string: urls[1]) else { return }
        UIApplication.shared.open(first) { ok in
            if !ok { UIApplication.shared.open(fallback) }
        }
    }

    private func apply(storeVersion: String) {
        requiredVersion = Self.isNewer(storeVersion, than: installedVersion) ? storeVersion : nil
    }

    /// "1.0.10" is newer than "1.0.9"; missing parts count as 0 ("1.1" == "1.1.0").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The lookup answers per storefront: first the phone's region, then the default (US) one.
    private nonisolated static func fetchStoreVersion() async -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        var countries: [String?] = []
        if let region = Locale.current.regionCode?.lowercased() { countries.append(region) }
        countries.append(nil)
        for country in countries {
            var parts = URLComponents(string: "https://itunes.apple.com/lookup")
            var query = [URLQueryItem(name: "bundleId", value: bundleID),
                         URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            if let country { query.append(URLQueryItem(name: "country", value: country)) }
            parts?.queryItems = query
            guard let url = parts?.url else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "GET"
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let version = results.first?["version"] as? String
            else { continue }
            return version
        }
        return nil
    }
}

/// The only screen while an update is required.
struct UpdateRequiredView: View {
    @EnvironmentObject var gate: UpdateGate
    let version: String

    var body: some View {
        ZStack {
            SunlitBackdrop().ignoresSafeArea()
            VStack(spacing: 18) {
                Text("SPANTHER")
                    .font(Atlas.wordmark(24))
                    .foregroundStyle(Atlas.ink)
                Text(L("Нужно обновить приложение"))
                    .font(Atlas.title)
                    .foregroundStyle(Atlas.ink)
                Text(L("В App Store вышла версия {0}. Эта версия ({1}) больше не запускается: обнови приложение, чтобы продолжить.", version, gate.installedVersion))
                    .font(Atlas.body)
                    .foregroundStyle(Atlas.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    gate.openAppStore()
                } label: {
                    Text(L("Обновить в App Store")).padding(.horizontal, 28)
                }
                .buttonStyle(AtlasPrimaryButton())
                .fixedSize()
                .padding(.top, 6)
            }
            .padding(32)
        }
        .preferredColorScheme(.light)
    }
}
