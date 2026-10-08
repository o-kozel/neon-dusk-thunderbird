# Neon Dusk

## Overview

Neon Dusk is a modern dark theme for [Mozilla Thunderbird](https://www.thunderbird.net/),
the free email client. It changes how Thunderbird looks, not how it works. The design
is inspired by modern mail apps like Outlook, Superhuman, and Notion Mail.

The theme is a set of CSS files (`userChrome.css` and `userContent.css`). This is
Thunderbird's own, supported way to change its appearance — the theme does not modify
Thunderbird itself, so it is safe to install and easy to remove.

### What the theme changes

The theme restyles almost every part of the Thunderbird window:

* **Title bar and search field** — new logo, redesigned search bar, window controls.
* **Tab bar** — rounded active tabs with an accent-colored icon.
* **Spaces rail** — the vertical icon bar on the left (Mail, Calendar, Contacts,
  Tasks, Chat, Settings).
* **Folder pane** — folder list, unread counts, "New message" button.
* **Message list** — email rows, avatars, unread indicators, quick filters.
* **Reading pane** — message header, toolbar, body text, attachments.
* **Today pane** — the events and tasks panel next to your inbox.
* **Status bar** — connection status and sync progress at the bottom.
* **Calendar** — sidebar, mini-month, main calendar grid, event cards, toolbar.
* **Address book (Contacts)** and **Settings pages** — restyled to match the rest of
  the theme.

Everything uses one accent color (green by default). You can switch it to blue,
purple, or amber by editing three values in one file — no need to touch anything else.

> A few Thunderbird features are built with older technology that CSS cannot fully
> restyle (for example, some tree lists and shadow-DOM components), so a handful of
> small visual differences from the original design remain by necessity.

### Requirements

* Thunderbird **ESR 128+** (the "Supernova" UI)
* **Linux** — native package or Flatpak

## Fresh install guide

Follow these steps on a Thunderbird you just installed (an existing install works the
same way).

### 1. Get the theme

```Shell
git clone https://github.com/o-kozel/neon-dusk-thunderbird.git
cd neon-dusk-thunderbird/assets
```

### 2. Run the installer

```Shell
./install.sh
```

This script automatically:

* finds your Thunderbird profile (native install or Flatpak — it asks if it finds
  more than one)
* links the theme's `chrome/` folder into your profile
* turns on the one setting Thunderbird needs to load custom CSS
  (`toolkit.legacyUserProfileCustomizations.stylesheets`)
* on Flatpak, grants Thunderbird's sandbox permission to read this folder

Useful options:

```Shell
./install.sh --profile /path/to/profile   # pick a specific profile
./install.sh --yes                        # don't ask, pick the default profile
./install.sh --help                       # see all options
```

### 3. Restart Thunderbird completely

Close Thunderbird fully — not just the window. On Linux, check your system tray;
some setups keep Thunderbird running in the background. Then open it again.

There is no "hot reload" for this kind of theme — Thunderbird only loads
`userChrome.css` when it starts.

### 4. (Optional) Change the accent color

Open `chrome/tokens.css` and edit these three lines:

```CSS
--accent:       #34d399;              /* default: green */
--accent-soft:  rgba(52,211,153,.14);
--accent-ink:   #06231a;              /* text/icon color on accent fills */
```

Ready-made blue, purple, and amber values are commented out just below them. Restart
Thunderbird to see the new color.

### Uninstall

```Shell
./uninstall.sh
```

This removes the theme's link (only if it points to this folder), restores any
backup the installer made, and removes the preference it set. Run
`./uninstall.sh --help` for options.
