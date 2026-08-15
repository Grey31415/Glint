# Glint

A colour dot beside the notch that tells you when a friend has actually written
to you — and, on hover, who and what they said.

Built for the case where you deleted the Instagram app but still want to stay in
touch. The goal is not to surface Instagram faster. It is to make it easy **not**
to open Instagram and still not miss a friend.

```
        ┌──────────────────────────────┐
   ●3 ──│  3 waiting                   │
        │  2 messages · 1 reaction     │
        ├──────────────────────────────┤
        │  (D) Denis            2m     │
        │      Alte schiffe und so     │
        │  (B) Beniamin M       14m    │
        │      Reacted 😂 to your msg  │
        ├──────────────────────────────┤
        │  ♥ Likes                 3   │
        │  ＋ New followers         1   │
        └──────────────────────────────┘
```

---

## The idea

A notification badge is only useful if you can trust it. Instagram's cannot be
trusted, because it counts a heart tapped on something you already sent the same
as a friend asking you a question.

So Glint splits them, and says so in two places:

- **The dot burns full Instagram colour only when a real message is waiting.**
  If everything waiting is reactions and likes, it drains to grey. You can tell
  whether anything needs you without opening anything at all.
- **The card lists the split explicitly** — "2 messages · 1 reaction" — and
  renders reactions dimmed and italic, so they never masquerade as a reply.

Every other category — likes, comments, follows, tags, message requests — is off
by default and individually switchable. Turn them on and they are added into the
one number on the dot and listed separately in the card.

## Hidden mode

The notch is a hole in the display: a region with no pixels. Hidden mode parks
the dot *inside* it, so it is genuinely invisible rather than merely small. Move
the cursor into the notch and it slides out.

For when you would rather not know.

---

## Install

Download the `.dmg`, drag Glint to Applications.

The build is ad-hoc signed rather than notarised, so the first launch is
blocked. **Right-click Glint → Open → Open** — once only. Or:

```sh
xattr -dr com.apple.quarantine /Applications/Glint.app
```

### Build it yourself

```sh
./Scripts/build_app.sh              # ./Glint.app
./Scripts/make_dmg.sh               # dist/Glint-<version>.dmg
UNIVERSAL=1 ./Scripts/make_dmg.sh   # arm64 + x86_64
```

macOS 14+. A bundle is not optional: WebKit refuses to give an unbundled binary
a persistent data store, and the login would not survive a relaunch.

## First run

Settings opens automatically. Sign in once, in-app. That session is an ordinary
WebKit session stored under `~/Library/WebKit/com.grey31415.Glint/`.

- **Hover** the dot for the card. **Click** a row to open that conversation.
- **Click** the dot to open your inbox; **option-click** to mark everything read.
- **Right-click** for the menu. The menu bar item does the same, and reappears
  by itself whenever the dot is invisible, so there is always a way back.

---

## How it works

### Reading Instagram

Instagram has no public unread API, but its own web client calls
`/api/v1/direct_v2/inbox/` and `/api/v1/news/inbox/`. Glint keeps your
signed-in session loaded off-screen and issues the same requests *from inside
that page*, so the cookies come along and the result is exactly what the site
would show you. Nothing leaves the machine.

The response shapes in `InstagramScript.swift` were verified against a live
account rather than assumed — `GLINT_PROBE=1` dumps the structure of both
endpoints, and `GLINT_DEBUG=1` logs every payload plus a survey of the live
DOM. That harness exists because the previous version's WhatsApp support was
written against guessed selectors and silently never worked.

### Telling a reaction from a message

The direct API marks it explicitly. A thread whose newest entry is
`item_type: "action_log"` with `action_log.is_reaction_log == true` is somebody
reacting to a message **you** sent — it carries no information and is counted in
its own bucket. `is_sent_by_viewer` backs this up. Everything else — text,
photos, voice notes, shared posts — is a real message.

This is a flag, not a heuristic, so it does not rot when the markup changes.

### Where the dot goes

macOS reports the usable menu bar strips either side of the camera housing as
`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; the gap between them
*is* the notch. Displays without one get a 200pt notch invented in the middle of
the menu bar, so the app still looks deliberate on an external monitor.

The panel floats at window level 25 — one above the menu bar — joins all Spaces,
and accepts clicks **only** where something is actually drawn, so the menu bar
underneath keeps working. Cursor position is polled rather than observed,
because a window with `ignoresMouseEvents` stops receiving mouse-moved events,
and that flag is on most of the time.

### One surface, not two

The dot and the menu are the same object. Rather than a dot that vanishes and a
panel that appears, there is a single shape whose rectangle and corner radius
interpolate between the two: the dot's own top and notch-side borders do not
move at all, and its edges stretch into the menu's edges while the contents
cross-fade inside it. `MorphMetrics` owns those two endpoints, so the view that
draws the surface and the controller that hit-tests it derive the same rectangle
from the same numbers.

The surface is real Liquid Glass — `glassEffect(_:in:)` from SwiftUICore, tinted
by the accent — on macOS 26, falling back to a material-and-tint approximation
on 14 and 15. The dot's colour does not disappear when the menu opens; it spreads
into the glass as a bloom anchored where the dot was, so the panel still reads as
having grown out of it.

The menu opens on the dot, stays while the cursor is anywhere on the surface, and
closes the instant it is on neither. There is no dismissal timer, because none is
needed: the surface grows *out of* the dot, so the pointer never crosses dead
space to reach it. It closes against the menu's measured height rather than a
reserved maximum, so dropping past its real bottom edge dismisses it immediately.

### The colour field

The lit interior is a square canvas of soft radial blobs, one per brand colour,
each following its own pair of summed sines. The frequency ratios are irrational,
so no blob repeats its path and no two fall back into step — it keeps
rearranging instead of cycling.

The canvas is sized for a **four-digit capsule**, not for the tile it sits in: a
fill matching the current shape runs out from under the tile as soon as the
number gets longer, and a rotating one leaves the corners bare.

Blob radius and drift were tuned by rendering and comparing, because colours
painted first are otherwise permanently buried by the ones painted last — two of
Instagram's five would never have surfaced. Additive blending was the obvious
alternative and is wrong: overlaps blow out to white and every brand ends up
pink.

Lit dots redraw at 30fps; quiet ones are static, so the cost only exists while
something is actually waiting.

### Marking as read

Instagram will not let anything be marked read from outside without opening the
conversation, so this is a local watermark, not a read receipt: Glint
remembers the count and shows only what arrives after. It is clamped to the real
count, so reading the messages for real releases it — it cannot silently mute
you forever. **Undo Mark as Read** brings hidden ones back.

---

## Layout

```
Sources/Glint/
  Core/        InstagramFeed (model), GlintModel (counts, watermarks), Preferences
  Providers/   InstagramSource (session + polling), InstagramScript (the JS)
  App/         panel, notch geometry, cursor tracking, status item, windows
  UI/          dot, hover card, colour field, geometry, theme, settings
```

## Known limits

- The dot sits where the frontmost app draws its menus. Clicks pass through, but
  a long menu will overlap it — move it with **Appearance → Distance from
  notch**, or use hidden mode.
- Instagram counts unread *conversations*, not individual messages. That is what
  the site itself reports.
- These are private endpoints. They can change without warning; when they do the
  probe above is how you find out what changed.
- Rebuilding changes the ad-hoc signature, so macOS treats it as a new app.
