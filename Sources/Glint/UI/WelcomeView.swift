import SwiftUI

/// Shown once, before anything is connected.
///
/// Glint asks you to sign in to Instagram, which is a large thing to ask. This
/// screen exists so that nobody has to take it on trust: it says plainly what
/// happens to the password, where the session is kept, and what Glint talks to.
struct WelcomeView: View {
    let onConnect: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 14) {
                Point(symbol: "hand.raised.fill",
                      title: "Glint never sees your password",
                      detail: """
                      You sign in on Instagram's own page. It opens in the standard macOS \
                      web view, the same engine Safari uses. Your username and password go \
                      straight to Instagram. Glint cannot read them and does not store them.
                      """)

                Point(symbol: "lock.laptopcomputer",
                      title: "The session stays on this Mac",
                      detail: """
                      macOS keeps the login cookie for Glint in ~/Library/WebKit and \
                      ~/Library/HTTPStorages, the same way it keeps Safari's. Glint has no \
                      account and no server. There is nowhere to send it. Those files are \
                      not locked away, though: any app you run as yourself can read them, \
                      the same as a browser profile.
                      """)

                Point(symbol: "arrow.left.arrow.right",
                      title: "Glint adds no tracking of its own",
                      detail: """
                      It makes the same two requests the website makes for itself, your \
                      inbox and your activity feed, and reads the numbers out of the \
                      replies. No analytics, no telemetry, and the one thing it ever sends \
                      is a reply you typed. It does load Instagram's real page to do this, \
                      so Instagram's own ad and analytics resources load with it, exactly \
                      as they would in a browser tab.
                      """)

                Point(symbol: "xmark.circle",
                      title: "You can disconnect whenever you like",
                      detail: """
                      Settings → Sign out erases the stored session from this Mac. Revoking \
                      Glint from Instagram → Settings → Login activity works too.
                      """)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)

            Spacer(minLength: 18)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made in Germany by Greyson Wiesenack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Open source. You can read exactly what it sends.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Not now", action: onLater)
                Button("Connect Instagram", action: onConnect)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Glint").font(.system(size: 26, weight: .semibold))
                Text("a quieter way to keep up.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
    }
}

private struct Point: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Accent.current.glow)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What the sign-in window is actually showing, as it changes.
///
/// The banner used to be a fixed sentence asserting that the page below it was
/// Instagram's. Nothing checked that, so it would have gone on saying so over
/// whatever had been loaded. Reading the committed host instead means the
/// banner can contradict itself, which is the only version of it worth having.
@MainActor
final class LoginBannerModel: ObservableObject {
    /// Host of the page currently in the window. Nil before the first load.
    @Published private(set) var host: String?
    /// Host of a navigation that was refused, until something else loads.
    @Published private(set) var blocked: String?

    func show(host: String?) {
        self.host = host
        blocked = nil
    }

    func show(blocked: String) {
        self.blocked = blocked
    }
}

/// Says whose page this is, above the sign-in page itself - the moment it
/// actually matters.
struct LoginBanner: View {
    @ObservedObject var model: LoginBannerModel

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMid)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private var symbol: String {
        if model.blocked != nil { return "exclamationmark.triangle.fill" }
        return model.host == nil ? "hourglass" : "lock.fill"
    }

    private var tint: Color {
        if model.blocked != nil { return Palette.warning }
        return model.host == nil ? Palette.textLo : Accent.current.glow
    }

    /// The host, verbatim. `Text` takes the plain-string overload here rather
    /// than `LocalizedStringKey`, so nothing in a host name is ever parsed.
    private var headline: String {
        if let blocked = model.blocked { return "Blocked: \(blocked)" }
        return model.host ?? "Loading Instagram's sign-in page"
    }

    private var detail: String {
        if model.blocked != nil {
            return "Glint refused to open that page. Signing in only ever happens on Instagram's own pages - nothing was loaded here."
        }
        guard model.host != nil else {
            return "Nothing has loaded yet."
        }
        return "Your password goes to this page, not to Glint. Glint only keeps the session cookie macOS stores for it on this Mac."
    }
}
