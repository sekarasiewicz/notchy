# Notchy

A macOS menu bar manager for notched MacBooks. Keeps status icons from
disappearing under the notch, and folds groups of them away behind a divider
you can open like a folder.

**Status: early work in progress.** Works on macOS 26 Tahoe and macOS 27 (tested on 27.2, notched MacBook display).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/sekarasiewicz/notchy/main/install.sh | bash
```

Or from a clone: `./install.sh`. Copies `dist/Notchy.zip` to `/Applications`, strips the quarantine flag (the build is ad-hoc signed) and launches the app. Grant Accessibility access on first run.

Rebuild the bundled binary with `scripts/build-release.sh`.

## What it does today

- Detects status icons that macOS has pushed off screen or under the notch
  (on macOS 27: folded behind the system's own `«` arrow).
- Adds a `‹` divider to the menu bar. Everything to its left can be folded
  away with one click, or automatically when icons run out of room.
- Shows folded icons in a panel, with their real glyphs. Clicking one
  temporarily expands the section, clicks the icon, and folds it back once
  its menu closes.

## Planned

- Named folders (several dividers), like folders in a browser bookmark bar.
- Remembering which icon belongs to which folder across launches.
- Onboarding for permissions.

## Requirements

- macOS 26.0 or later
- Accessibility permission (required, used to identify icon owners and to
  move them)
- Screen Recording permission (optional, used to show icon glyphs in the panel)

## Build

Open `Notchy.xcodeproj` in Xcode 26 or later and run. Not sandboxed, not App Store
compatible: it relies on private window server calls and synthesised events.

## How it works

On macOS 26 every status item window belongs to Control Center, so the app
matches window server windows to each app's `AXExtrasMenuBar` items by
position to learn who owns what. Hiding uses the classic spacer trick (a
status item stretched to 10 000 pt). Moving and clicking other apps' icons
synthesises the ⌘-drag a user would do, relayed through per-process event
taps. Much of this approach is borrowed from [Ice](https://github.com/jordanbaird/Ice).

### macOS 27

macOS 27 draws the whole menu bar in one `MenuBarAgent` window, so there are
no per-item windows to list or to aim events at. On 27 Notchy instead:

- reads items from MenuBarAgent's accessibility window: one slot per item,
  with its frame and the pid of the app behind it;
- still folds with the spacer, but at a chosen width. A spacer too wide to
  fit takes everything on its left out of the bar; a slot wider than half the
  screen is discarded by the system and hides nothing;
- clicks and ⌘-drags with ordinary pointer events, so the pointer visits the
  menu bar for a moment and is put back.

Not covered on 27 yet: displays without a notch and multi-display setups are
untested, and an icon the system itself has folded behind `«` cannot be
opened from the panel.

## License

MIT
