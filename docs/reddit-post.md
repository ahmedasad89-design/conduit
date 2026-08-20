# r/MacOS post — ready to submit

**Do not post before Saturday.** r/MacOS Rule 7: promotional posts are allowed on
**Saturdays (UTC) only**. Anything else is removed.

- Next legal window: **Saturday 22 August 2026, UTC**
- In Dubai (UTC+4) that window runs **08:00 Sat → 04:00 Sun**
- Best slot for a US-heavy sub: **19:00–21:00 Dubai** (15:00–17:00 UTC, US morning)

Flair: **News** (that is what the other developer posts in the sub are using).

---

## Title

```
Conduit — a free, open-source macOS app that tells you why a USB drive is slow, not just how slow
```

Alternative, if the first feels long:

```
I built a macOS menu-bar app that explains why your USB drive is slow — negotiated link speed, UASP vs BOT, hubs in the path
```

---

## Body

```
Every disk speed test on the Mac hands you a number. None of them tell you what the number means.

A drive writing at 38 MB/s looks identical whether the cause is a cheap drive, a USB 2.0 port, a charge-only cable, a hub sharing bandwidth with four other things, or an enclosure that quietly fell back to bulk-only transport instead of UASP. Same number every time. Completely different fix every time.

Conduit reads the negotiated link speed, the transfer protocol and the hub chain out of the IORegistry and names which one it is:

> Capped at 480 Mb/s by a slower hop upstream. The drive itself negotiated faster than this — plug it straight into the Mac to get its full speed.

It also says that at the moment you plug the drive in, which is the only moment the information is still useful — before you start a forty-minute copy rather than after.

What it does:

- Live menu-bar meter: read/write MB/s, IOPS, per-operation latency, queue depth, errors and retries, plotted against the drive's actual link ceiling
- A speed test that disables the system cache, so the number describes the drive rather than your RAM. It reports two write figures — the rate the drive accepted data, and the rate once everything was committed to media. On a drive with a big buffer those differ, and only the second one is honest.
- Per-drive history, so a later run can tell you whether a drive is getting worse

A few implementation notes people here might find interesting:

- Three IORegistry properties claim to tell you the USB link speed, and two of them use *different enums*. On the same 5 Gb/s drive, `USBSpeed` reads 4 and `Device Speed` reads 3. Reading one with the other's table silently turns a 480 Mb/s device into a 1.5 Mb/s one. Conduit uses `UsbLinkSpeed`, which is a plain bits-per-second integer and needs no table at all.
- `F_NOCACHE` stops new data being cached but does not evict pages that are already resident. Measured on my internal SSD with a 768 MB file: written with F_NOCACHE it reads back at 2346 MB/s, written cached it reads back at 16955 MB/s. Write order matters more than read flags.
- Built and tested entirely on Command Line Tools — no Xcode. The macOS 26 SDK turned SwiftUI's `@State` into a macro backed by a plugin that only ships with Xcode, so the whole app avoids `@State`.

Free, MIT, no telemetry, no account, nothing to buy:
https://github.com/ahmedasad89-design/conduit

**Fair warning on install:** it is ad-hoc signed, not notarised (that costs $99/yr), so a downloaded copy is quarantined and macOS will refuse to open it. Either build from source in about thirty seconds, or run `xattr -dr com.apple.quarantine /Applications/Conduit.app` after moving it. I would rather say that plainly than have people hit a scary dialog.

The ask: this has been tested against exactly one USB drive on one Mac, which is not a sample size. If you have a Thunderbolt or USB4 NVMe enclosure, anything behind a dock or hub, a plain exFAT stick, a card reader or a spinning disk — I would really like to know what Conduit said about it and whether it was right. Cross-checks against Blackmagic or AmorphousDiskMark especially welcome; a wrong number is the worst bug this app can have.
```

---

## Before you hit submit

1. **Karma.** u/ahmedasad89 currently has 1 total karma and 0 comment karma. Reddit's
   spam filter treats a zero-history account posting a link as spam, and it may be
   removed regardless of the day. Spend a few minutes over the next two days leaving
   genuine comments in r/MacOS or r/macapps — ten or so is enough to clear most filters.
2. **Disclose authorship in a comment** as well as the post, which is standard etiquette
   and required in r/macapps.
3. **Be around for the first two hours** to answer questions. Reddit rewards a developer
   who replies; an unanswered thread dies.

## r/macapps — a separate, later route

Also a good venue but it cannot be done immediately. It requires 10 local karma earned in
that subreddit, post approval from the mods, its own promo template, and an `[OS]` prefix
for open-source projects. Self-promotion there is once per developer per 30 days, so it is
worth spending that slot after r/MacOS feedback has improved the app.
