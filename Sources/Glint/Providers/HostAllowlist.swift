import Foundation

/// Decides whether a URL belongs to a set of domains Glint trusts.
///
/// This replaces `host.contains("instagram.com")`, which was the test in three
/// places and is not a host check at all: `instagram.com.attacker.net` contains
/// the string, and so does `myinstagram.com`. A registrable-domain match either
/// is the domain or is a genuine subdomain of it, with the dot present.
enum HostAllowlist {
    /// Everywhere the background view is ever allowed to be. It loads one page,
    /// the inbox, and has no reason to leave instagram.com.
    static let instagram: Set<String> = ["instagram.com"]

    /// Signing in additionally crosses into Meta's shared account surface:
    /// linked-Facebook login and the checkpoint flows live over there, and
    /// refusing them would break sign-in for the accounts that use them.
    static let signIn: Set<String> = ["instagram.com", "facebook.com", "meta.com"]

    /// True when `url` is an https page on one of `domains`.
    ///
    /// Insisting on https costs nothing - Instagram serves nothing over plain
    /// http - and it means a `file://` URL, which carries no host, cannot pass
    /// by having an empty one. `about:blank` fails here too, which is the right
    /// answer everywhere this is called: a blank view has not loaded Instagram.
    static func allows(_ url: URL?, _ domains: Set<String>) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
