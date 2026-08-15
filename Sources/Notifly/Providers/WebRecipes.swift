import Foundation

/// Everything that differs between one web-backed source and another.
///
/// The extractor is a JavaScript *function expression* evaluated in the page.
/// It must return `{status, count, method}` where status is one of
/// `ok` / `auth` / `unknown` / `error`. Keeping the service-specific knowledge
/// in a string here means a markup change upstream is a one-line fix — and the
/// user can override it from Settings without rebuilding.
struct WebRecipe {
    let kind: SourceKind
    let descriptor: SourceDescriptor
    /// Page kept loaded in the background and scraped.
    let trackingURL: URL
    /// Page the sign-in window opens.
    let loginURL: URL
    let defaultExtractor: String
}

extension WebRecipe {
    static let instagram = WebRecipe(
        kind: .instagram,
        descriptor: SourceDescriptor(
            id: SourceKind.instagram.rawValue,
            name: "Instagram",
            glyph: .instagram,
            accent: .instagram,
            openURL: URL(string: "https://www.instagram.com/direct/inbox/"),
            openBundleID: nil
        ),
        trackingURL: URL(string: "https://www.instagram.com/direct/inbox/")!,
        loginURL: URL(string: "https://www.instagram.com/accounts/login/")!,
        defaultExtractor: instagramExtractor
    )

    static let whatsapp = WebRecipe(
        kind: .whatsapp,
        descriptor: SourceDescriptor(
            id: SourceKind.whatsapp.rawValue,
            name: "WhatsApp",
            glyph: .whatsapp,
            accent: .whatsapp,
            openURL: URL(string: "https://web.whatsapp.com/"),
            openBundleID: "net.whatsapp.WhatsApp"
        ),
        trackingURL: URL(string: "https://web.whatsapp.com/")!,
        loginURL: URL(string: "https://web.whatsapp.com/")!,
        defaultExtractor: whatsappExtractor
    )
}

// MARK: - Extractors

/// Instagram, in decreasing order of reliability:
/// 1. the tab title, which Instagram prefixes with `(n)`;
/// 2. any `aria-label` that spells out "n unread";
/// 3. a red pill sitting next to the Direct entry point.
private let instagramExtractor = #"""
function () {
  var href = location.href;
  // "onetap" is the save-your-login interstitial: the session is already valid,
  // so this is not a sign-in prompt and must not be reported as one.
  if (/\/accounts\/onetap/.test(href)) return { status: "unknown", method: "onetap" };
  if (/\/accounts\/(login|signup)/.test(href)) return { status: "auth" };
  if (document.querySelector('input[name="password"]')) return { status: "auth" };

  var m = document.title.match(/^\((\d+)\+?\)/);
  if (m) return { status: "ok", count: parseInt(m[1], 10), method: "title" };

  var total = 0, hit = false;
  var labelled = document.querySelectorAll("[aria-label]");
  for (var i = 0; i < labelled.length; i++) {
    var um = (labelled[i].getAttribute("aria-label") || "").match(/(\d+)\s+unread/i);
    if (um) { total += parseInt(um[1], 10); hit = true; }
  }
  if (hit) return { status: "ok", count: total, method: "aria" };

  var link = document.querySelector('a[href^="/direct/"], a[href*="/direct/inbox"]');
  if (!link) {
    var icon = document.querySelector('svg[aria-label="Messenger"], svg[aria-label="Direct"]');
    if (icon && icon.closest) link = icon.closest("a") || icon.parentElement;
  }
  if (link) {
    var scope = (link.closest && link.closest("div")) || link;
    var nodes = scope.querySelectorAll("span, div");
    for (var j = 0; j < nodes.length; j++) {
      var n = nodes[j];
      if (n.children.length) continue;
      var txt = (n.textContent || "").trim();
      if (!/^\d{1,3}\+?$/.test(txt)) continue;
      var probe = n;
      for (var k = 0; k < 3 && probe; k++) {
        var c = (window.getComputedStyle(probe).backgroundColor || "")
                  .match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
        if (c && (c[4] === undefined || parseFloat(c[4]) > 0.2)) {
          var r = +c[1], g = +c[2], b = +c[3];
          if (r > 140 && r - g > 45 && r - b > 45) {
            return { status: "ok", count: parseInt(txt, 10), method: "badge" };
          }
        }
        probe = probe.parentElement;
      }
    }
  }

  if (document.querySelector('a[href^="/direct/"], svg[aria-label="Home"], nav')) {
    return { status: "ok", count: 0, method: "quiet" };
  }
  return { status: "unknown" };
}
"""#

/// WhatsApp Web is friendlier: the title carries the count, and the chat list
/// items spell out "n unread messages" for screen readers.
private let whatsappExtractor = #"""
function () {
  var m = document.title.match(/^\((\d+)\+?\)/);
  if (m) return { status: "ok", count: parseInt(m[1], 10), method: "title" };

  var pane = document.querySelector("#pane-side");
  if (!pane) {
    if (document.querySelector('canvas[aria-label*="Scan"], div[data-testid="qrcode"], [data-ref]')) {
      return { status: "auth" };
    }
    return { status: "unknown" };
  }

  var total = 0, hit = false;
  var labelled = pane.querySelectorAll("[aria-label]");
  for (var i = 0; i < labelled.length; i++) {
    var um = (labelled[i].getAttribute("aria-label") || "").match(/(\d+)\s+unread/i);
    if (um) { total += parseInt(um[1], 10); hit = true; }
  }
  return { status: "ok", count: hit ? total : 0, method: hit ? "aria" : "quiet" };
}
"""#

/// Wraps an extractor so it reports changes immediately (MutationObserver) and
/// can also be driven from Swift, which keeps the poll honest even when WebKit
/// throttles timers in an off-screen view.
func notiflyBootstrapScript(sourceID: String, extractor: String) -> String {
    """
    (function () {
      if (window.__notifly) { window.__notifly.tick(); return; }
      var SOURCE = "\(sourceID)";
      var extract = \(extractor);
      var lastKey = null, lastPost = 0;

      function post(p) {
        try {
          p.source = SOURCE;
          p.href = location.href;
          window.webkit.messageHandlers.notifly.postMessage(p);
          lastPost = Date.now();
        } catch (e) {}
      }

      function tick() {
        var r;
        try { r = extract() || { status: "unknown" }; }
        catch (e) { r = { status: "error", detail: String((e && e.message) || e) }; }
        var key = JSON.stringify(r);
        // Re-post unchanged values every 30s so Swift can tell "steady" from "dead".
        if (key !== lastKey || Date.now() - lastPost > 30000) { lastKey = key; post(r); }
      }

      window.__notifly = { tick: tick };

      try {
        var pending = null;
        new MutationObserver(function () {
          clearTimeout(pending);
          pending = setTimeout(tick, 350);
        }).observe(document.documentElement, {
          subtree: true, childList: true, characterData: true,
          attributes: true, attributeFilter: ["aria-label", "title", "data-icon", "class"]
        });
      } catch (e) {}

      setInterval(tick, 4000);
      tick();
      setTimeout(tick, 1500);
      setTimeout(tick, 5000);
    })();
    """
}
