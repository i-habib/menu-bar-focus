# Focus

A small macOS menu bar app for consistency. Two ideas, both from *Atomic Habits*:
you can't improve what you don't measure, and the streak itself is the motivation.

## What it does

**Habit tracking.** Keep a list of habits. Once a day the app asks how each one went,
with three honest options:

- **Didn't** — no credit
- **5 min+** — you showed up (this is the one that matters)
- **1 hr deep** — an undistracted hour

The check-in pops up at your chosen hour (default 21:00). If a day slips by unlogged,
it asks about it the next morning instead of silently losing it.

**Live sessions.** Start a session on any habit from the menu and the menu bar becomes a
running clock (`▶ Deep work 42:15`). It ends three ways:

- **You end it** — *End session* in the menu.
- **You get distracted** — 15 continuous seconds on anything you marked as time wasted
  kills it, and the recorded time is backdated to the moment you switched away, not to
  when you noticed. A quick glance is forgiven; sinking into it isn't.
- **You walk away** — 10 minutes without keyboard or mouse ends it, trimmed back to when
  you stopped.

Each ending shows a small HUD with what got logged. Sessions under 10 seconds are
discarded as misclicks, and a session left running by a crash is dropped rather than
credited.

Recorded time then **pre-answers the check-in**: an hour or more preselects *1 hr deep*,
five minutes or more preselects *5 min+*. You can always override it — the tracker is a
memory aid, not a judge.

**The chart.** A GitHub-style contribution grid, ~6 months at a glance, shaded by how
much of the day's possible credit you earned. Plus current streak, longest streak,
per-habit totals, completion rate and recorded time. Session stats too: how many you
recorded, total and average and longest length, how many died to a distraction, and how
many you walked away from.

**The time wasted bar.** Always in the menu bar: a small bar that fills green → orange
→ red against a daily budget you set, with the minutes next to it and your streak.
Nothing is a time waster until you say so — open the menu while you're in the offending
app and click **Mark "TikTok" as time wasted**. In Safari, Chrome, Brave or Arc it marks
the *website* instead of the whole browser, so `youtube.com` counts and `docs.google.com`
doesn't. Remove any of them from the *Time wasters* submenu.

Time only accrues while the app is genuinely in front and you've touched the keyboard or
mouse in the last minute — walking away doesn't count against you.

## Build

Needs the Xcode command line tools (`xcode-select --install`). No other dependencies.

```sh
./build.sh --install
```

Compiles `Focus.app`, installs it to `/Applications` and launches it. Without
`--install` it just builds into `./build`.

Then open the menu bar item and turn on **Open at login**.

The first time you focus a browser, macOS asks for permission to control it — that's the
tab-address read for site-level tracking. Deny it and everything still works; browsers
just get tracked as one app instead of per-site.

## Data

One JSON file at `~/.focus/habits.json`: your habits, every day's marks, every recorded
session with its start, end and why it ended, per-source wasted seconds, and your settings. Nothing leaves your machine, and nothing is recorded
about apps or sites you haven't explicitly marked.

## Notes

- The day rolls over at 4am, so a 1am session still counts as the previous day.
- Renaming a habit starts its history fresh; the old name keeps its past entries.
- Waste time is buffered in memory and written to disk every 30 seconds, so the tracker
  isn't hammering your SSD every two seconds.
