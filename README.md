<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/glint_black.png">
  <source media="(prefers-color-scheme: light)" srcset="Assets/glint_white.png">
  <img src="Assets/glint_black.png" alt="Glint" width="190">
</picture>

**a quieter way to keep up.**

### [⬇︎ Download Glint for Mac](https://github.com/Grey31415/Glint/releases/latest/download/Glint.dmg)

<sub>Free · macOS 14 or newer · Apple silicon and Intel</sub>

</div>

<p align="center">
  <img src="Assets/screenshot-dot.jpeg" width="46%" alt="A small glowing dot beside the notch showing two unread messages">
  &nbsp;
  <img src="Assets/screenshot-menu.jpeg" width="46%" alt="The dot unfolded into a menu listing who wrote and what they said">
</p>

## What is it?

A little dot next to the notch on your Mac. It lights up when someone messages
you on Instagram. Point at it and you can see who wrote and what they said -
without opening Instagram and losing twenty minutes.

Made for people who deleted the app but still want to hear from their friends.

## What the colours mean

| | |
| --- | --- |
| 🟣 **Colourful** | Someone actually wrote to you |
| ⚪️ **Grey** | Just likes or reactions - nothing that needs you |
| **Nothing there** | You're all caught up |

Instagram treats a heart on something you posted the same as a friend asking you
a question. Glint keeps them apart, so the number always means something.

You can also switch on likes, comments, new followers, tags and message
requests - each one separately, and all off to begin with.

## Installing

1. [**Download Glint**](https://github.com/Grey31415/Glint/releases/latest/download/Glint.dmg), open the file and drag Glint into your Applications folder.

2. Open Glint. macOS will say it *"could not verify that this app is free of
   malware"* - click **Done**. This is expected: Glint isn't registered with
   Apple's paid developer programme, so macOS doesn't recognise it.

3. Open **System Settings → Privacy & Security**, scroll down to **Security**.
   You'll see *"Glint was blocked to protect your Mac"* with an **Open Anyway**
   button. Click it and confirm with Touch ID or your password.

4. Open Glint again and click **Open**.

That's a one-time thing. After that it just launches.

<details>
<summary>Prefer one Terminal command instead of steps 2-4?</summary>

```sh
find /Applications/Glint.app -exec xattr -d com.apple.quarantine {} \; 2>/dev/null
```

This removes the "downloaded from the internet" mark, after which Glint opens
normally.

</details>

Then sign in to Instagram once, close the window, and you're done.

## Using it

| | |
| --- | --- |
| **Point at the dot** | See who messaged you |
| **Click the pen** | Reply without opening Instagram |
| **Click a name** | Opens that conversation |
| **Click the dot** | Opens your inbox |
| **⌥ Option-click** | Marks everything as read |
| **Right-click** | Settings and quit |

You can write back from the dot. Point at it, click the pen next to
whoever messaged you, type, and press return. Only conversations have a
pen. Likes, comments and new followers do not, because there is nothing
there to reply to.

Anything you've already read disappears from the list, so it only ever shows
what's actually waiting for you.

**Want it even quieter?** Turn on *Hidden mode* in Settings and the dot vanishes
inside the notch completely. Move your cursor there and it slides back out.

## Is this safe?

Short answer: yes, and you don't have to take my word for it.

- **Glint never sees your password.** You type it into Instagram's own login
  page, exactly like you would in Safari.
- **The session stays on this Mac.** Your login is a cookie, kept by macOS in
  Glint's sandbox container. Glint has no website, no account and no server to
  send it to. Be clear-eyed about what that container is, though: it is not
  sealed off from anything else you run. Any app running as you can read it,
  the same as a browser profile.
- **Glint adds no tracking.** No analytics, no telemetry, no dependencies — it
  has no networking code of its own at all, and every request comes from the web
  view. What it *does* do is host Instagram's real web page, so Instagram's
  usual ad and analytics resources load with it, exactly as they would in a
  browser tab. Glint neither adds to that nor can it strip it out.
- **It only sends what you type.** Replies go out when you press return, and
  never otherwise. Glint writes nothing to your account on its own.
- **You can undo it any time.** Settings → *Sign out* wipes the saved login off
  your Mac.

The app explains all of this when you first open it, before it asks you for
anything.

## Something not working?

Open Settings - it shows what Glint is doing and usually says what's wrong. If
Instagram signed you out, there's a button to sign back in.

---

<div align="center">

Made in Germany by **Greyson Wiesenack** &nbsp;·&nbsp; [MIT licensed](LICENSE)

<sub>Curious how it works under the hood? → <a href="README_for_nerds.md">README for nerds</a></sub>

</div>
