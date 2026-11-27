import Foundation

/// The Supabase project the app signs in to (backend/README.md): its Project URL and its public key (anon or
/// publishable). Both are meant to ship inside the app; the rows of other accounts are closed by the database.
/// Never put the service_role key or the database password here.
///
/// Empty until the project exists: the app then shows no sign-in at all and works on the phone alone.
enum BackendSettings {
    static let projectURL = ""
    static let publicKey = ""

    static var config: BackendConfig? {
        if let c = BackendConfig(projectURL: projectURL, apiKey: publicKey) { return c }
        #if DEBUG
        // The CI screenshots of the sign-in screens (`-SpantherAccount signIn|code`) need an address; it answers
        // nothing.
        if AccountModel.debugStep != nil { return BackendConfig(projectURL: "https://example.invalid", apiKey: "ci") }
        #endif
        return nil
    }
}
