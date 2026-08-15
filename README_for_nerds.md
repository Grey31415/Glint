# Glint, for nerds

The bits the [main README](README.md) deliberately leaves out.

## Build

```sh
git clone https://github.com/Grey31415/Glint.git
cd Glint
./Scripts/build_app.sh              # ./Glint.app
CONFIG=debug ./Scripts/build_app.sh # faster build
UNIVERSAL=1 ./Scripts/make_dmg.sh   # dist/Glint-<version>.dmg, arm64 + x86_64
INSTALL=1 ./Scripts/build_app.sh    # also copies to /Applications
```

SwiftPM executable, no Xcode project. macOS 14 deployment target, Swift 5
language mode.

A `.app` bundle is not optional: WebKit refuses to give an unbundled binary a
persistent website data store, so `swift run` starts but forgets the login on
every launch.

The bundle is ad-hoc signed, which is why Gatekeeper complains and why every
rebuild looks like a new app to macOS. Fixing it properly needs a paid Apple
Developer account and notarisation; there is no way around it from this side.

Two things about that worth knowing, both of which caught out the install
instructions here:

- macOS 15 **removed** the Control-click → Open bypass. The only route without
  Terminal is System Settings → Privacy & Security → **Open Anyway**, which
  appears after the first blocked launch.
- `xattr -dr` no longer exists - the `-r` flag was dropped. Recursive clearing is
  `find <app> -exec xattr -d com.apple.quarantine {} \;`, and it has to be
  recursive because the executable inside the bundle is quarantined separately
  from the bundle itself.

```
Sources/Glint/
  Core/        InstagramFeed (model), GlintModel (counts, watermarks), Preferences
  Providers/   InstagramSource (session + polling), InstagramScript (the JS)
  App/         panel, notch geometry, cursor tracking, status item, windows
  UI/          morphing surface, dot, menu, colour field, geometry, theme
```

## Reading Instagram

There is no public unread-count API. Instagram's own web client calls these, so
Glint keeps a signed-in session loaded in an off-screen `WKWebView` and issues
the same requests *from inside that page* - the cookies come along, and the
result is exactly what the site would show you.

```
GET /api/v1/direct_v2/inbox/?limit=25&thread_message_limit=1
GET /api/v1/news/inbox/
```

Both need `x-ig-app-id: 936619743392459`, the public web client's id.

### Reactions vs messages

A thread whose newest entry is `item_type: "action_log"` with
`action_log.is_reaction_log == true` is somebody reacting to a message **you**
sent. That is an explicit flag rather than a text heuristic, so it does not rot
when copy changes. `is_sent_by_viewer` corroborates it, cross-checked against the
thread's own `viewer_id` because it is absent on some item shapes - notably
entries arriving via `last_permanent_item` rather than `items[0]`.

Everything else - `text`, `media`, `voice_media`, `clip`, `media_share`,
`story_share` - counts as a real message.

### Sorting the activity feed

Every notification carries a `notif_name`: an exact, locale-independent key.

| `notif_name` | bucket |
| --- | --- |
| `post_like`, `comment_like` | likes |
| `user_followed` | followers |
| `comment` | comments |
| `mentioned_comment` | tags & mentions |
| `ig_approve_from_another_device` | security (ignored) |

Order matters when matching: `comment_like` contains "comment", and
`mentioned_comment` contains both. Rendered text is only a fallback for names not
seen before.

`story_like` is deliberately mapped to `other` and never counted. It was briefly
its own category, but Instagram's `counts` object exposes no key for it - the
number had to be derived from the unseen story list alone, which disagreed with
the aggregates in the other direction and could not be made to add up. Story
likes arrive constantly and mean little, so dropping them beats reporting them
wrongly.

Counts are tallied from the unseen stories, so each equals exactly the rows
listed beneath it. When Instagram reports nothing new but is still badging a
category, Glint falls back to its aggregates; the branches are mutually
exclusive, so nothing double counts.

### Marking as read

Instagram will not let anything be marked read from outside without opening the
conversation, so this is a local watermark, not a read receipt: remember the
count, show only what arrives after. It is clamped to the real count, so reading
the messages properly releases it - it cannot silently mute you forever.

## Where the dot goes

`NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` describe the usable
menu bar strips either side of the camera housing, so the gap between them *is*
the notch. Displays without one get a 200pt notch invented in the middle of the
menu bar.

The panel floats at window level 25 - one above the menu bar - joins all Spaces,
and accepts clicks **only** where something is drawn, so the menu bar underneath
keeps working.

Cursor position is polled rather than observed, because a window with
`ignoresMouseEvents = true` stops receiving mouse-moved events, and that flag is
on most of the time. The poll idles at 8 Hz and steps up to 100 Hz near the dot.

**Hidden mode** parks the dot at `notchRect.midX` - a region of the display with
no pixels - so it is genuinely invisible rather than merely small.

## One surface, not two

The dot and the menu are the same object: a single shape whose rectangle and
corner radius interpolate between them, contents cross-fading inside.

Both endpoints share a fixed anchor on the notch-side edge, so **only width,
height and corner radius change** and nothing travels horizontally. This was
learned the hard way. Two earlier versions produced a dot that appeared to fly in
from the far corner when closing:

1. The rectangle was derived from the dot's *centre*, making the pinned edge
   depend on magnification - and magnification animates on a different spring
   from the morph, so the two disagreed mid-flight.
2. Contents were positioned as `rect.minX + (rect.width - contentWidth)`, two
   separately animated quantities that only cancel while both ease on the same
   curve. They are now pinned by layout alignment, so there is no arithmetic
   left to break.

The menu also freezes the geometry it opened at - the feed refreshes on a timer,
and arriving rows would otherwise resize it under the cursor.

It opens on the dot, stays while the cursor is anywhere on the surface, and
closes immediately otherwise. No dismissal timer is needed: the surface grows
*out of* the dot, so the pointer never crosses dead space.

## Looks

Real Liquid Glass on macOS 26 via SwiftUICore's `glassEffect(_:in:)`, tinted by
the accent, with a material-and-tint fallback for 14 and 15.

The colour field is soft radial blobs, one per brand colour, each following its
own pair of summed sines with irrational frequency ratios - so no blob repeats
its path and no two fall back into step. It keeps rearranging instead of cycling.

The canvas is a square sized for a **four-digit capsule**, not for the tile it
sits in: a fill matching the current shape runs out from under the tile as soon
as the number gets longer, and a rotating one leaves the corners bare.

Blob radius, drift and opacity were tuned by rendering variants and comparing
them, because colours painted first are otherwise permanently buried by the ones
painted last - two of Instagram's five would never have surfaced. Additive
blending was the obvious alternative and is wrong: overlaps blow out to white and
every brand ends up pink. WhatsApp's greens, back when it had them, were ordered
dark-to-light for the same reason.

Lit dots redraw at 30fps; quiet ones are static.

## Debugging

```sh
GLINT_DEBUG=1  /Applications/Glint.app/Contents/MacOS/Glint   # every payload + DOM survey
GLINT_PROBE=1  /Applications/Glint.app/Contents/MacOS/Glint   # taxonomy of both endpoints
GLINT_UA="..." /Applications/Glint.app/Contents/MacOS/Glint   # override the user agent
GLINT_TRACE_MORPH=1 ...                                        # morph geometry each frame
```

These exist because guessing at Instagram's response shapes is how you ship
something that silently never works - which is exactly what happened to an
earlier WhatsApp provider, written against selectors that were never checked
against a live account. Everything above was read off real data instead.

`GLINT_DEBUG=1` is also how you verify the privacy claim: it logs every request
and reply the app makes.

## Limits

- The dot sits where the frontmost app draws its menus. Clicks pass through, but
  a long menu can overlap it - move it in Appearance, or use hidden mode.
- Instagram counts unread *conversations*, not individual messages.
- These are private endpoints. They can change without warning; the probe above
  is how you find out what changed.
- Rebuilding changes the ad-hoc signature, so macOS treats it as a new app.
