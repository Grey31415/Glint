<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/glint_black.png">
  <source media="(prefers-color-scheme: light)" srcset="Assets/glint_white.png">
  <img src="Assets/glint_black.png" alt="Glint" width="190">
</picture>

**Stay in the loop without getting lost**

</div>

<p align="center">
  <img src="Assets/screenshot-dot.jpeg" width="46%" alt="A small glowing dot beside the notch showing two unread messages">
  &nbsp;
  <img src="Assets/screenshot-menu.jpeg" width="46%" alt="The dot unfolded into a glass menu listing who wrote and what they said">
</p>

A dot beside the notch that lights up when a friend messages you on Instagram.
Hover it to see who wrote and what they said. Click to open the conversation.

Built for people who deleted the app but still want to hear from friends.

---

## What the dot means

**Full colour** — a real message is waiting. **Grey** — only reactions or likes,
nothing that needs you. **Nothing** — you're clear.

Instagram counts a heart on something you already sent the same as a friend
asking you a question. Glint doesn't. Reactions get their own bucket and never
inflate the number.

Everything else is off by default and individually switchable: post likes, story
likes, comments, new followers, tags, message requests. Switch one on and it
joins the number on the dot and gets its own line in the menu.

The menu lists only what is still waiting on you. Read it anywhere — your phone,
the web — and the row disappears.

**Hidden mode** parks the dot inside the notch, where there are no pixels, so it
is genuinely invisible until you move the cursor there.

## Install

Download the `.dmg` and drag Glint to Applications.

It is ad-hoc signed rather than notarised, so the first launch is blocked:
**right-click → Open → Open**, once. Or `xattr -dr com.apple.quarantine
/Applications/Glint.app`.

```sh
git clone https://github.com/Grey31415/Glint.git
cd Glint
./Scripts/build_app.sh              # ./Glint.app
UNIVERSAL=1 ./Scripts/make_dmg.sh   # dist/Glint-<version>.dmg
```

macOS 14+. Sign in once, in-app.

## Using it

| | |
| --- | --- |
| Hover the dot | opens the menu |
| Click a row | opens that conversation |
| Click the dot | opens your inbox |
| Option-click | marks everything read |
| Right-click | status, settings, quit |

The overlay only takes clicks where something is drawn, so the menu bar
underneath keeps working. The menu bar item is optional — Spotlight-launching
Glint reopens Settings.

## Privacy

**Your password never goes through Glint.** You sign in on Instagram's own page
in the standard macOS web view, the same engine Safari uses.

**The session stays on this Mac.** macOS keeps the cookie in `~/Library/WebKit`
and `~/Library/HTTPStorages`, where it keeps Safari's. Glint has no account and
no server.

**It only talks to instagram.com** — the same two requests the website makes for
itself:

```
GET /api/v1/direct_v2/inbox/    your conversations
GET /api/v1/news/inbox/         your activity feed
```

No analytics, no telemetry, no other destination. Check for yourself with
`GLINT_DEBUG=1 /Applications/Glint.app/Contents/MacOS/Glint`.

**Settings → Sign out** erases the stored session. All of this is shown in the
app on first launch, before the sign-in field appears.

---

## How it works

**Reading Instagram.** There is no public unread API, so Glint keeps your
signed-in session loaded off-screen and runs the site's own requests from inside
its own page. A thread whose newest entry is `action_log` with `is_reaction_log`
is somebody reacting to a message you sent — a flag, not a heuristic, so it will
not rot. Activity is sorted by `notif_name`, which is how story likes stay
separate from post likes.

**Where the dot goes.** `NSScreen.auxiliaryTopLeftArea` and its twin describe the
menu bar either side of the camera housing; the gap between them is the notch.
Displays without one get a 200pt notch invented in the middle.

**The dot and the menu are one surface.** A single shape interpolates between
them, sharing a fixed anchor on the notch-side edge, so only width, height and
corner radius change and nothing travels. Real Liquid Glass on macOS 26
(`glassEffect(_:in:)`), with a material fallback below it.

**The colour field** is soft blobs, one per brand colour, each on its own pair of
summed sines with irrational frequency ratios — so it keeps rearranging rather
than looping. The canvas is sized for a four-digit capsule, because one matching
the current shape runs out from under the tile as soon as the number grows.

**Marking as read** is a local watermark; Instagram will not let anything be
marked read from outside. It is clamped to the real count, so reading the
messages properly releases it.

`GLINT_PROBE=1` dumps the taxonomy of both endpoints, `GLINT_DEBUG=1` logs every
payload. Both exist because guessing at Instagram's shapes is how you ship
something that silently never works.

## Limits

- The dot sits where the frontmost app draws its menus. Clicks pass through, but
  a long menu can overlap it — move it in Appearance, or use hidden mode.
- Instagram counts unread *conversations*, not individual messages.
- These are private endpoints and can change without warning.
- Rebuilding changes the ad-hoc signature, so macOS treats it as a new app.
