# Thunderbird Dark Theme

A modern dark `userChrome.css`/`userContent.css` theme for Thunderbird's mail
and calendar views — spaces rail, folder pane, message list, reading pane,
today pane, status bar, calendar, tabs toolbar, address book, and settings.

## Requirements

- Thunderbird **ESR 128+** (the "Supernova" UI)
- **Linux**, native package or Flatpak

## Install

```sh
./install.sh
```

That's it in the common case — the script finds your Thunderbird profile
automatically (native or Flatpak, prompting if it finds more than one),
symlinks this theme's `chrome/` folder into it, sets the one required
`about:config` preference, and — if you're on Flatpak — grants the sandbox
read-only access to see this folder.

**Then fully quit Thunderbird (not just close the window — check your system
tray/dock) and relaunch it.** There's no hot reload; CSS only loads on start.

Run `./install.sh --help` for options (picking a specific profile, running
non-interactively, etc.).

## Changing the accent color

Everything in this theme is driven by three variables in `chrome/tokens.css`:

```css
--accent:       #34d399;              /* default: green */
--accent-soft:  rgba(52,211,153,.14);
--accent-ink:   #06231a;              /* text/icon color on accent fills */
```

Edit those three (there's also a commented block right below with ready-made
blue/purple/amber values) and restart Thunderbird — the whole UI recolors.

## Uninstall

```sh
./uninstall.sh
```

Removes the `chrome/` symlink (only if it points at this folder — a real
`chrome/` directory or a symlink elsewhere is always left alone), restores
any pre-install backup, and removes the preference this theme set. Run
`./uninstall.sh --help` for options.

## License

This theme's own CSS and icons are MIT-licensed — see `LICENSE`.

Bundles the [Inter](https://rsms.me/inter/) typeface; its own license is at
`chrome/fonts/Inter-4.1/LICENSE.txt`.
