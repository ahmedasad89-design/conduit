# Show HN — ready to submit

No promo window, no karma gate, no waiting. Submit at https://news.ycombinator.com/submit

---

## Title

```
Show HN: Conduit – macOS USB speed meter that tells you why a drive is slow
```

75 characters. HN's limit is 80, and it truncates silently past that.

## URL

```
https://github.com/ahmedasad89-design/conduit
```

The repo, not the landing page. HN expects Show HN links to point at the thing itself, and a
claude.ai URL would read as marketing.

Leave the **text field empty.** A Show HN with both a URL and body text buries the body.
Post the text below as the first comment immediately after submitting — that is the
convention and it is what people actually read.

---

## First comment — post this right after submitting

```
I got tired of disk speed tests that hand you a number and stop there.

If an external drive writes at 38 MB/s, that could be a slow drive, a USB 2.0 port, a
charge-only cable, a hub sharing bandwidth with four other things, or an enclosure that
negotiated bulk-only transport instead of UASP. The number is identical in all five cases
and the fix is different in all five. So Conduit reads the negotiated link speed, the
transport and the hub chain out of the IORegistry and just tells you which one it is:
"Capped at 480 Mb/s by a slower hop upstream. The drive itself negotiated faster than this."

It's a menu-bar app: a passive meter that diffs IOBlockStorageDriver's Statistics counters
at 4 Hz (bytes, ops, service time, errors, retries — no root, no kext, no entitlements), and
an active speed test for when you want to provoke the drive rather than watch it.

Two things I found that might be useful to someone else poking at this:

1. Three IORegistry properties claim to tell you a USB device's link speed, and two of them
use different enums. On the same 5 Gb/s drive, UsbLinkSpeed reads 5000000000, USBSpeed reads
4, and Device Speed reads 3 — USBSpeed follows tIOUSBHostConnectionSpeed (Full=1, Low=2,
High=3) while Device Speed follows the older IOUSBFamily enum (Low=0, Full=1, High=2).
Decode one with the other's table and a 480 Mb/s device silently becomes 1.5 Mb/s. It's
plausible enough that you'd never notice. UsbLinkSpeed is a plain bits-per-second integer
and needs no table, so that's what it uses, with the enums only as fallbacks.

2. F_NOCACHE prevents new data being cached but does not evict pages that are already
resident, which makes benchmark phase order load-bearing. Same 768 MB file, same read code,
on the internal SSD: written with F_NOCACHE it reads back at 2346 MB/s, written without it
reads back at 16955 MB/s. The second number is the page cache, not the disk. Any benchmark
that writes its scratch file through the cache and then reads it back "uncached" is
reporting RAM. It also reports two write figures — the rate the drive accepted data, and the
rate once F_FULLFSYNC had committed it — because on a drive with a large buffer those differ
by a lot and only the second one is honest.

Built and tested entirely with Command Line Tools, no Xcode. That turned out to be harder
than expected: the macOS 26 SDK made SwiftUI's @State a macro backed by a compiler plugin
that only ships with Xcode, so the app avoids @State entirely. Swift Testing is present in
the CLT but on no default search path, so Package.swift has to spell out the macro plugin
directory and two rpaths or `swift test` builds fine and then dies in dlopen.

Caveats, because they're real:

- macOS 26 or later. I didn't want to maintain two code paths for the newer SwiftUI APIs.
- It is ad-hoc signed, not notarised, so a downloaded copy is quarantined and macOS refuses
to open it. Either build from source (about 30 seconds, and then there's no quarantine flag
at all) or run xattr -dr com.apple.quarantine on it. Notarising is $99/yr and this doesn't
have that.
- It has been tested against exactly one USB drive on one Mac, which is not a sample size.
Thunderbolt/USB4 enclosures report as PCI-Express rather than USB and I've never seen one.
The "capped by a slower hop upstream" warning has never fired on real hardware. The exFAT
path where F_FULLFSYNC gets refused has never executed.

That last point is the main reason I'm posting. If you have an odd enclosure, a dock, a card
reader or a spinning disk, I'd like to know what it said and whether it was right —
particularly if it disagrees with Blackmagic or AmorphousDiskMark. A wrong number is the
worst possible bug in something like this.

MIT, no telemetry, no account, nothing to buy.
```

---

## Timing

HN's Show HN traffic peaks **Tuesday–Thursday, 08:00–10:00 US Eastern**, which is
**16:00–18:00 Dubai**. Weekends and Friday afternoons are dead.

- Best slot: **Tuesday 25 August, ~17:00 Dubai** (09:00 ET)
- Acceptable: any weekday in that window
- Avoid: Friday and the weekend

If you'd rather not wait until Tuesday, Thursday afternoon ET still works — it is simply
past the peak.

## Before you submit

- **Do you have an HN account, and how old is it?** Show HN has no karma requirement, but
  brand-new accounts submitting links sometimes land in the spam queue. If the account is
  new, leave a few genuine comments first, same as the Reddit advice.
- **Be at your desk for the first 90 minutes.** HN ranking is heavily influenced by early
  comment velocity, and Show HN authors who answer questions do markedly better. This is
  more important than the exact posting time.
- **Do not ask for upvotes anywhere**, including on X. HN detects voting rings and will
  bury the post.
- Expect the first comment to be about the unsigned binary. The honest answer is already in
  the text above; don't get defensive about it.
