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
                      You sign in on Instagram's own page, opened in the standard macOS \
                      web view — the same engine Safari uses. Your username and password \
                      go straight to Instagram. Glint cannot read them, and does not store \
                      them.
                      """)

                Point(symbol: "lock.laptopcomputer",
                      title: "The session stays on this Mac",
                      detail: """
                      macOS keeps the login cookie for Glint in ~/Library/WebKit and \
                      ~/Library/HTTPStorages, the same way it keeps Safari's. Glint has no \
                      account, no server and nowhere to send it.
                      """)

                Point(symbol: "arrow.left.arrow.right",
                      title: "It only ever talks to instagram.com",
                      detail: """
                      Glint makes the same two requests the website makes for itself — your \
                      inbox and your activity feed — and reads the numbers out of the \
                      replies. There is no analytics, no telemetry and no other destination.
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
                Text("Open source — you can read exactly what it sends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Know a friend messaged you, without opening Instagram.")
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
                .foregroundStyle(Accent.instagram.glow)
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

/// The same promise, restated above the sign-in page itself — the moment it
/// actually matters.
struct LoginBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Accent.instagram.glow)
            Text("This is Instagram's own sign-in page. Your password goes to Instagram, not to Glint — Glint only keeps the session cookie macOS stores for it on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}
