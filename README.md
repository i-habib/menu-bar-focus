# Focus

A small menu bar app for macOS. One idea: every day you name the one or two things
that actually matter, and then you can't quietly forget them.

## What it does

- **4am day boundary.** The first time you use your Mac after 4am, a full-screen
  screen you can't dismiss asks for your top 1–2 priorities and a start time for each.
  No text, no continue.
- **Lives in the menu bar.** The next priority and its time sit up there all day.
  While a session is running it shows a live timer instead.
- **Nudges.** 30 minutes before the start time, at the start time, and 30 and 60
  minutes after, the screen is taken over for 5 seconds with the task in big letters.
  Buttons: *I'm on it* / *Done* / *Dismiss*.
- **Sessions.** Marking something "I'm working on it" starts a timer that runs until
  you pause it or mark it finished. Only one can run at a time.
- **Nudges stop** once a task is marked working or done — the guilt is only for
  things you haven't touched.
- **Stats.** Days planned, completion rate, on-time starts, session count, total
  focused time, plus the last 30 days of history.

## Build

Requires the Xcode command line tools (`xcode-select --install`). No other dependencies.

```sh
./build.sh --install
```

That compiles `Focus.app`, copies it to `/Applications`, and launches it. Without
`--install` it just builds into `./build`.

Then open the menu bar icon and turn on **Open at login** — the app has to be running
for any of this to work.

## Data

Everything is one JSON file at `~/.focus/state.json`: every day, every priority,
every session's start and end. Nothing leaves your machine.

## Notes

- The setup screen sits above the menu bar and the Dock and pulls focus back to
  itself every second. It's stubborn by design, but it isn't a kernel-level lock —
  quitting the app still works if you really want out.
- Times before 4am count as belonging to the previous day, so a priority scheduled
  for 01:00 fires tonight, not this morning.
