import Foundation
import WebKit

/// Bridges WebKit's `@objc` navigation delegate onto the main actor, and keeps
/// the web view on the hosts it was built for.
///
/// WebKit already calls these on the main thread; `assumeIsolated` states that.
///
/// Both of Glint's web views carry a live Instagram session, so where they are
/// allowed to go is a security question rather than a routing one: the polling
/// view runs Glint's scripts against whatever is loaded, and the sign-in window
/// is where a password gets typed. Neither had a policy method before this.
final class NavigationBridge: NSObject, WKNavigationDelegate {
    private let allowed: Set<String>
    private let onCommitted: @MainActor (URL?) -> Void
    private let onFinished: @MainActor (URL?) -> Void
    private let onFailed: @MainActor (Error) -> Void
    private let onBlocked: @MainActor (URL) -> Void

    init(allowed: Set<String>,
         onCommitted: @escaping @MainActor (URL?) -> Void = { _ in },
         onFinished: @escaping @MainActor (URL?) -> Void = { _ in },
         onFailed: @escaping @MainActor (Error) -> Void = { _ in },
         onBlocked: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.allowed = allowed
        self.onCommitted = onCommitted
        self.onFinished = onFinished
        self.onFailed = onFailed
        self.onBlocked = onBlocked
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the main frame is pinned. Sign-in legitimately pulls in
        // sub-frames Glint cannot enumerate in advance - Meta's CAPTCHA vendor
        // among them - and cancelling those breaks the flow while protecting
        // nothing: a sub-frame cannot repaint the window around it.
        //
        // A nil target frame means the page asked for a new window. That is
        // already inert, because neither view sets a `WKUIDelegate` and WebKit
        // has nowhere to open one.
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        let url = navigationAction.request.url

        // The empty page a fresh web view sits on. No origin to vet, nothing
        // displayed, and refusing it would strand the view before its first
        // real load.
        if url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        guard HostAllowlist.allows(url, allowed) else {
            decisionHandler(.cancel)
            if let url { MainActor.assumeIsolated { onBlocked(url) } }
            return
        }
        decisionHandler(.allow)
    }

    /// The moment the new page takes over the view, rather than the moment it
    /// finishes loading. Anything showing the user which origin they are
    /// looking at has to change here, or it describes the previous page for as
    /// long as the new one takes to load.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { onCommitted(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { onFinished(url) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { onFailed(error) }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        MainActor.assumeIsolated { onFailed(error) }
    }
}
