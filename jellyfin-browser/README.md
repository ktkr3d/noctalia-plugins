# Noctalia Plugins

## Plugins

- Jellyfin browser

## Add plugin Source

```bash
noctalia msg plugins source add ktkr3d git https://github.com/ktkr3d/noctalia-plugins
```

or

1. Open Noctalia settings (Super + Z)
2. Plugins > Sources
3. Add Source
4. Select Git
    - Source ID : ktr3d
    - Location : https://github.com/ktkr3d/noctalia-plugins
5. Add Source

## Enable plugin

```bash
noctalia msg plugins enable ktkr3d/jellyfin-browser
```

or

1. Open Noctalia settings (Super + Z)
2. Plugins > Plugins
3. **toggle** enable plugin

## Setup widget

1. Open Noctalia settings (Super + Z)
2. Bar: default > Widget List
3. Add widget
4. Select widget

## How to use

```bash
noctalia msg panel-toggle ktkr3d/jellyfin-browser:panel
```

or use panel widget

Open a library or folder and select **Play all** to play its playable items
sequentially in mpv, or **Shuffle** to play them in a shuffled order. These
actions include all matching items in the current folder, including items on
pages that have not been loaded in the browser.
