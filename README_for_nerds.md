# Glint, for nerds

*a quieter way to keep up.*

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
  App/         panel, notch geometry, cursor tracking, windows
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

### The unread run inside a thread

The inbox is fetched with `thread_message_limit=10`, not 1. With one item per
thread a chat holding five unread messages arrived as a single preview line, so
the card could say who had written but never how much - two people writing one
line each and one person writing four looked identical.

Which of those items are unread comes from `last_seen_at`, keyed by user id:
`last_seen_at[viewer_id].timestamp` is the point you have read up to, in
microseconds like the items themselves. Anything newer than it and not sent by
you is waiting. Where the mark is missing the newest item alone stands in, which
is what the app showed before.

Verified with `GLINT_PROBE=1`, which reports per-thread item counts and the
marker: an unread thread came back with three items newer than the mark, every
read thread with none.

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

Activity stories also carry `args.profile_name` and `args.profile_id`, which is
who did it. The card groups on that: one row per correspondent, their
conversation and their likes and comments together, rather than a list of
conversations followed by a tally per category in which the same person could
appear twice. Only a one-to-one thread is matched by name - a group's title is
several usernames joined, and matching it would file one person's likes under
everybody. Counts Instagram badges without saying who is behind them keep a
per-category row, or the card and the dot would stop agreeing.

Counts are tallied from the unseen stories, so each equals exactly the rows
listed beneath it. When Instagram reports nothing new but is still badging a
category, Glint falls back to its aggregates; the branches are mutually
exclusive, so nothing double counts.

### Sending a reply

The only write Glint performs. It runs from a keypress, never on a timer, and
is never retried.

`/api/v1/direct_v2/threads/broadcast/text/` looks like the obvious endpoint and
is a dead end: it is the mobile private API, not a route the web session has.
Instagram answers an unrouted path with the app's own HTML and a **200**, so a
POST there fails while looking like it succeeded. Reads work because
`/api/v1/direct_v2/inbox/` genuinely is served to web.

The web client sends over Relay instead:

```
POST /api/graphql
fb_api_req_friendly_name = IGDirectTextSendMutation
doc_id                   = 26911679871773184
variables                = {"ig_thread_igid": "...", "offline_threading_id": "...",
                            "text": {"sensitive_string_value": "..."},
                            "send_attribution": "igd_web_chat_tab:in_thread", ...}
```

Three parts are derived rather than scraped, each checked against a captured
send:

- **The thread id.** The inbox hands back 128-bit ids and the mutation wants the
  low 64 bits. `340282366841710301244276024561196214941 % 2**64` is
  `17849543619127965`, exactly the id the real client sent for that thread. The
  high word is a constant, so this is a local conversion, not a lookup.
- **`jazoest`.** `"2"` followed by the sum of `fb_dtsg`'s character codes.
  Reproduces the captured value.
- **`av`**, the actor id, read out of the `rur` cookie.

`fb_dtsg` and `lsd` are minted per page load and pulled from the bundle payload.
Several shapes are tried and a miss is named in the error, because a missing
token is the likeliest way this stops working.

The Relay bundle parameters are left out on purpose. `__dyn`, `__csr`, `__hsdp`,
`__hblp`, `__spin_*` and the rest are revision and telemetry state rather than
part of the mutation, and the endpoint accepts the request without them.

**`doc_id` is the maintenance.** It is an opaque server id that rotates with
Instagram's releases, and when it does, sending fails. It lives in one constant
beside the friendly name. To recapture it: DevTools, filter on `graphql`, send a
message, and take the request whose friendly name contains `Send`. Note that
opening a thread also fires `useIGDMarkThreadAsReadMutation`, which is a
different mutation and carries no message text.

```sh
GLINT_DRY_RUN=1    # assemble and log the request, send nothing
GLINT_PROBE_SEND=1 # run the send path against the first thread on launch
```

### Where your answer goes

A sent reply stays on the card, indented under the message it answers, for five
minutes. Instagram does echo it back on the next poll, but only as the preview
line of a thread that has by then stopped waiting on you - so the row and the
evidence both disappear, and the send is confirmed by nothing at all. Glint
keeps its own copy of what it sent, in memory, and `cardThreads()` holds any
thread that has one.

The linger is short by design. The card is a list of things waiting on you, and
a conversation you have answered is finished; five minutes is long enough to
glance back and see what you wrote, short enough that the card does not silt up.
It is a setting - *Conversations, keep after replying* - and at zero the row
goes as soon as the send is confirmed. A dry run never records an answer -
claiming a send that never left the machine is worse than showing nothing.

Answering is remembered separately from the linger, because replying is not
reading: Instagram goes on calling the thread unread until the next poll catches
up, so without that memory a conversation you had dealt with would keep counting.
The remembered date is compared against the thread's newest item, which is what
brings the row back the moment they write again.

### Answering from the menu

Return sends and Shift-Return breaks the line, or the other way round -
*Composing, Return key*. Only the inverted mode is intercepted with
`onKeyPress`; left alone, a vertical `TextField` already does the messaging
idiom, and handling that case would be reimplementing what works.

Drafts live in `GlintModel`, not in the composer's own state, which is what
makes both of them possible: the menu closes when the cursor leaves it, so an
unsent sentence used to die with the view, and the invisible copy that measures
the menu can only report the right height if it lays out the same text as the
real field. Memory first, `UserDefaults` on a 1.5 second delay - this runs on
every keystroke.

### Marking as read

Instagram will not let anything be marked read from outside without opening the
conversation, so this is a local watermark, not a read receipt: remember the
count, show only what arrives after. It is clamped to the real count, so reading
the messages properly releases it - it cannot silently mute you forever.

### Knowing it still works

An app whose entire surface is one dot cannot fail quietly. Every failure short
of signing out used to keep the last good counts on screen and write the reason
into `diagnostics`, which is only visible with Settings open - a dot that has
been wrong for an hour looked exactly like a dot that is right.

Two things say otherwise now. `NWPathMonitor` watches the machine's own
connectivity and puts the feed into `.offline` directly, rather than waiting for
three failed polls and a backoff to infer it; polls are skipped while there is
no route, and the network coming back clears the failure count and refreshes at
once. And `isStale` - no successful poll in three intervals, floored at ninety
seconds - puts a line at the foot of the menu saying when the last one was. Both
stay quiet while things are current.

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

**Hidden mode** parks the dot at `notchRect.midX`, a region of the display with
no pixels, so it is genuinely invisible rather than merely small.

### Why hidden mode does not follow Do Not Disturb

It should. Glint cannot read your Focus, and the reason is worth writing down
so nobody spends another afternoon rediscovering it.

`INFocusStatusCenter` is the public API and it works exactly as documented, on
apps that are allowed to call it. Calling `requestAuthorization` needs the
`com.apple.developer.focus-status` entitlement, which only a provisioning
profile from a paid Apple Developer account can carry.

Three things were confirmed here rather than assumed:

- **Without the entitlement, TCC does not deny the request. It kills the
  process.** `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, SIGABRT, on launch.
  `NSFocusStatusUsageDescription` in the bundle is necessary and nowhere near
  sufficient.
- **An ad-hoc signature cannot carry the entitlement either.** A binary
  claiming it does not launch at all, with no output and no crash report.
- **Reading the status without authorisation is not merely unauthorised, it is
  blind.** With Do Not Disturb switched on, `focusStatus.isFocused` returns
  `false` rather than `nil`, which is indistinguishable from no Focus being on.
  There is no quiet fallback where it half works.

Glint also never appears under System Settings, Privacy & Security, Focus.
That list is built from apps that have legally requested access, and the
request dies before TCC records anything, so there is no row to switch on and
no way to add one by hand.

Two routes exist if this is ever worth revisiting. `SetFocusFilterIntent`
inverts the direction: macOS pushes to the app rather than the app reading, so
it may not need the entitlement, but it does nothing until the user configures
Glint per Focus in System Settings, which rules it out as a default. Or read
`~/Library/DoNotDisturb/DB/Assertions.json` directly, which works without a
developer account and needs Full Disk Access, an absurd thing to demand for one
boolean.

The honest fix is the paid account, which is the same thing that would let the
app be notarised.

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

Magnification is the exception, and it pins the *opposite* edge: the outer end
of the resting dot. Growing from the notch-side anchor instead is the obvious
reading of the rule above and looks wrong - every point of magnification shoves
the dot out along the menu bar, so approaching it makes it lunge away from the
notch before the menu has opened. Pinning the far edge sends the growth towards
the housing, which is where the dot is about to go anyway. It is not the
centring that caused the trouble: both edges are still fixed points, one per
phase, and the view holds this rectangle at rest size for as long as the menu is
open, so the magnify spring is never in flight at the same time as the morph.

The other thing that travels is the dot itself, and only on its way out. As
the menu takes over it slides *towards* the notch - right when it is docked on
the left, left when it is docked on the right - and the surface's clip on the
notch-side edge eats it, so it ducks behind the camera housing instead of
dissolving on the spot while the surface sweeps out the other way. This does not
reopen the failure above: it is a single quantity driven by the morph's own `t`,
not two separately animated ones that have to cancel.

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

The same colour field doubles as the bloom in the open menu, which is why
*Colour glow in the menu* cannot simply switch it off: draining it would drain
the dot as well, since the fill is what makes a dot a dot. Off instead holds the
field at dot size and fades it on the dot's own curve, so the colour ducks behind
the notch with it and the menu is glass. The accent wash on the glass goes with
it, or the switch would look half-applied.

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

## Licence

[MIT](LICENSE). Do what you like with it.
