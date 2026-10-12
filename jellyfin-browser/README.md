# Jellyfin Browser

This plugin allows you to browse the Jellyfin server library and play media.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ktkr3d/jellyfin-browser` |
| Entries | Bar widget: `browser`; panel: `panel` |

## Requirements

Install `mpv`.

## Usage

Add the widget to your bar
Open the panel and connect your jellyfin server by URL, username and password.
Browse library and play media

To toggle or open the panel from a terminal or keybinding:

```sh
noctalia msg panel-toggle ktkr3d/jellyfin-browser:panel
```

Open a library or folder and select **Play all** to play its playable items
sequentially in mpv, or **Shuffle** to play them in a shuffled order. These
actions include all matching items in the current folder, including items on
pages that have not been loaded in the browser.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_label` | `bool` | `false` | Show plugin name. |

## Notes

#### Add plugin souce

```bash
noctalia msg plugins source add ktkr3d git https://github.com/ktkr3d/noctalia-plugins
```

#### Enable plugin

```bash
noctalia msg plugins enable ktkr3d/jellyfin-browser
```
