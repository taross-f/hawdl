import Foundation

/// Which language the menu bar UI draws itself in.
///
/// Deliberately *not* `.strings` files in `.lproj` directories, which is the
/// idiomatic answer. The `.app` bundle here is assembled by hand in five
/// places — the release workflow, the Homebrew formula, and three sets of
/// instructions people follow by hand — and resources are exactly what a
/// hand-written copy step drops. A missing `.lproj` is invisible until
/// somebody notices the wrong language, and this app has already shipped two
/// bugs whose only symptom was "nothing happened, silently". Strings compiled
/// into the binary cannot be lost that way.
///
/// The cost is the per-app override under System Settings -> General ->
/// Language & Region -> Applications, which only lists apps that declare their
/// localizations. `defaults write <bundle id> AppleLanguages -array ja` still
/// works, because that is what `Locale.preferredLanguages` reads.
public enum UILanguage: String, Sendable, CaseIterable {
    case japanese
    case english

    /// Resolved from the user's ordered language list, as System Settings ->
    /// General -> Language & Region sets it.
    ///
    /// Only the first entry is consulted. Somebody whose primary language is
    /// German and whose second is Japanese wants German; this app has no
    /// German, and English serves them better than Japanese would.
    public static func resolve(preferredLanguages: [String]) -> UILanguage {
        guard let tag = preferredLanguages.first else { return .english }
        // Compare the parsed language subtag, so every Japanese variant lands
        // here: "ja", "ja-JP", "ja-Jpan-JP". A `hasPrefix("ja")` test would be
        // wrong — "jam", "jav" and "jbo" are Jamaican Creole, Javanese and
        // Lojban, and none of them are Japanese.
        return Locale(identifier: tag).language.languageCode?.identifier == "ja"
            ? .japanese
            : .english
    }

    /// Read once. Changing the system language needs a relaunch to take effect
    /// in a properly localized app too, so re-reading it on every menu draw
    /// would only buy a UI that changes under the user mid-session.
    public static let current = resolve(preferredLanguages: Locale.preferredLanguages)
}
