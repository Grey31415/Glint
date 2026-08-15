# Notifly

A colour dot that lives beside the notch and tells you when someone has messaged
you. Built for the case where you deleted the Instagram app but still want to
know a DM landed — the same number the browser tab shows, without the browser.

Hover it and the cluster magnifies the way the Dock does, growing *downwards*
out of the notch.

- **Quiet** — a small muted circle, doing nothing.
- **Unread** — a capsule carrying the number, filled with soft colour blobs
  wandering behind the mask, under a breathing bloom in the service's colour.
- **Hover** — dock-style magnification; the capsule opens up to show the service
  mark. No panel, no backdrop — the tiles just lift.
- **New message** — a ring pulses outward from the dot.

Instagram ships first. WhatsApp and iMessage are built in, and adding a fourth
service is one file.

---

## Requirements

macOS 14 or later, Xcode command line tools. Apple silicon or Intel.

## Build

```sh
./Scripts/build_app.sh          # produces ./Notifly.app
open Notifly.app
```

```sh
CONFIG=debug ./Scripts/build_app.sh   # faster build
UNIVERSAL=1  ./Scripts/build_app.sh   # arm64 + x86_64
INSTALL=1    ./Scripts/build_app.sh   # also copy to /Applications
```

The `.app` bundle is not optional: WebKit refuses to give an unbundled binary a
persistent website data store, and without one the logins would not survive a
relaunch. `swift run` will start, but every session would be forgotten.

The bundle is ad-hoc signed, so its signature changes on every build. macOS ties
Full Disk Access to that signature, which means **iMessage needs re-authorising
after a rebuild**. The web sources are unaffected.

## First run

Settings opens automatically. Enable what you want and sign in:

| Source | How it reads the count | What it needs |
| --- | --- | --- |
| Instagram | Signed-in `instagram.com` session kept loaded in the background | Sign in once, in-app |
| WhatsApp | `web.whatsapp.com` session, or the desktop app's Dock badge | QR scan, or Accessibility |
| iMessage | `~/Library/Messages/chat.db`, read-only | Full Disk Access |

Nothing leaves the machine. The sessions are ordinary WebKit sessions stored in
`~/Library/WebKit/com.grey31415.Notifly/`, and the Messages database is only ever
opened read-only.

## Using it

- **Click** a dot to open that service — its Mac app if one is installed,
  otherwise the web version. If it is blocked on something — signed out, missing
  a permission — clicking runs the fix instead.
- **Option-click** to mark that service as read.
- **Right-click** for status, mark-as-read, refresh, settings, quit.
- The menu bar item does the same. It can be switched off, but it reappears by
  itself whenever no dots are on screen, so there is always a way back to
  Settings.

The overlay only accepts clicks while the cursor is actually over a dot;
the rest of the time it is transparent to the mouse, so the menu bar underneath
keeps working normally.

### Marking as read

Neither Instagram nor WhatsApp will let anything be marked read from outside
without opening the conversation, so this is a local watermark rather than a real
read receipt: Notifly remembers what the count was and shows only what has
arrived since. If the real count later drops — because the messages were read for
real — the watermark drops with it, so the next message still lights the dot.
**Undo Mark as Read** brings the hidden ones back.

---

## How it works

### Where the dots go

macOS reports the usable menu bar strips either side of the camera housing as
`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. The gap between them
*is* the notch, so the cluster anchors to `notchRect.minX`. Displays without a
notch get a 200pt one invented in the middle of the menu bar, which keeps the
app looking deliberate on an external monitor.

The panel sits at window level 25 — one above the menu bar — and joins all
Spaces, so it stays put over full-screen apps.

### The colour field

The lit interior is a square canvas of soft radial blobs, one per brand colour,
each following its own pair of summed sines. The frequency ratios are irrational,
so no blob repeats its own path and no two fall back into step — the fill keeps
rearranging instead of cycling.

The canvas is a **square sized for a four-digit capsule**, not for the tile it
sits in. A fill matching the current shape runs out from under the tile as soon
as the number gets longer, and a rotating one leaves the corners bare.

Two things were tuned by rendering them and looking: blobs are small enough, and
roam far enough, that the ones painted first are not permanently buried by the
ones painted last — otherwise two of Instagram's five colours would never
surface. Additive blending was the obvious alternative and is wrong here, since
overlaps blow out to white and every brand ends up pink. WhatsApp's greens are
ordered dark-to-light for the same reason: unlike Instagram's, they do not share
a luminance, so leading with the dark ones leaves a black hole.

Lit dots redraw at 30fps. Quiet ones are static, so the cost only exists while
something is actually waiting for you.

### The magnification

`DockMagnifier` reduces the Dock's behaviour to its two essentials: items under
the cursor grow, and their neighbours are displaced to make room. Distances are
measured against *rest* positions rather than displaced ones, so the layout
cannot chase its own tail. The falloff is a raised cosine — 1 under the cursor,
0 at the influence radius, flat at both ends, so nothing visibly pops as a dot
enters or leaves the field.

It is a pure function, and the window controller runs the exact same layout the
view renders in order to decide where clicks are accepted. The clickable region
is by construction the region that is drawn.

Cursor position is polled rather than observed, because a window with
`ignoresMouseEvents = true` stops receiving mouse-moved events — and that flag
is on most of the time so the menu bar stays usable. The poll idles at 8 Hz and
steps up to 100 Hz once the cursor is near.

### Reading the counts

Instagram and WhatsApp have no public unread-count API. Notifly keeps the page
you are already logged into loaded in an off-screen `WKWebView` and reads the
number from it — in decreasing order of reliability: the `(n)` the site puts in
the tab title, then any `aria-label` spelling out "n unread", then the red badge
next to the direct-messages link.

Changes are pushed instantly by a `MutationObserver`; a Swift-side timer also
drives the extractor, because WebKit throttles a page's own timers when the view
is off-screen.

When a site changes its markup, the fix is a few lines of JavaScript rather than
a new build: **Settings → Sources → Custom extractor**. It takes a function
expression returning `{ status, count, method }`. Settings shows which method
produced the current number, so a silently broken scraper is distinguishable
from a genuinely quiet inbox.

iMessage is simpler — a read-only SQLite query against `chat.db`, counting
inbound unread messages newer than a configurable cutoff so one forgotten thread
from years ago cannot permanently pin the badge.

---

## Adding another service

The UI, window and layout layers know nothing about specific services. To add
one — Telegram, Slack, Discord, Signal:

**If it has a web app**, add a `WebRecipe` in `Providers/WebRecipes.swift` with
its URL and an extractor, then a case in `SourceKind`:

```swift
static let telegram = WebRecipe(
    kind: .telegram,
    descriptor: SourceDescriptor(id: "telegram", name: "Telegram",
                                 glyph: .symbol("paperplane.fill"),
                                 // colours are blended as drifting blobs; base
                                 // fills the gaps, glow is the outer bloom
                                 accent: Accent(colors: [...], base: ..., glow: ...),
                                 // clicking prefers the app, falling back to
                                 // the URL; use nil to always open the browser
                                 openURL: URL(string: "https://web.telegram.org/"),
                                 openBundleID: "ru.keepcoder.Telegram"),
    trackingURL: URL(string: "https://web.telegram.org/a/")!,
    loginURL: URL(string: "https://web.telegram.org/a/")!,
    defaultExtractor: telegramExtractor)
```

**If it is a Mac app that badges its Dock icon**, a `DockRecipe` is the whole
job — `DockBadgeSource` reads the badge off any tile via the accessibility API:

```swift
static let slackDock = DockRecipe(
    descriptor: SourceDescriptor(id: "slack", name: "Slack", ...),
    tileTitles: ["Slack"])
```

**Anything else** conforms to `NotificationSource` — five methods and a
`SourceDescriptor`. Register it in `SourceFactory.make` and it appears in
Settings, in the cluster, and in the menu automatically.

## Layout

```
Sources/Notifly/
  Core/        SourceState, NotificationSource, NotificationHub, Preferences
  Providers/   WebSource (+ recipes), MessagesSource, DockBadgeSource
  App/         panel, notch geometry, cursor tracking, status item, windows
  UI/          magnification maths, the dot, the cluster, theme, settings
```

## Known limits

- The dots sit in the strip where the frontmost app draws its menus. Clicks pass
  through, but a long menu will overlap them. Move them with **Appearance →
  Distance from notch**, or park them on the right of the notch instead.
- WhatsApp Web can be picky about non-Safari browsers. Notifly presents a Safari
  user agent; if it still refuses, use the Dock badge mode instead.
- Rebuilding invalidates the ad-hoc signature and therefore Full Disk Access.
- Instagram counts conversations with unread messages, not individual messages —
  that is what the site itself reports.
- Setting **Maximum scale** to 1× disables magnification entirely; that is the
  slider's left end, not a bug.
