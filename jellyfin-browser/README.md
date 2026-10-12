# Noctalia Plugins

## Plugins

- Jellyfin browser

## Setup plugin Source

```bash
noctalia msg plugins source add dev path ~repos/noctalia-plugins
```

or

1. Open Noctalia settings
   Super + Z
2. Plugins > Sources
3. Add Source
4. Select Git
    - Source ID : ktr3d
    - Location : https://github.com/ktkr3d/noctalia-plugins
5. Add Source

## Install plugin

```bash
noctalia msg plugins enable ktkr3d/jellyfin-browser
```

or

1. Open Noctalia settings
   Super + Z
2. Plugins > Plugins
3. Browse plugins
4. Search plugin
5. Select plugin
6. **toggle** enable plugin

## Setup widget

1. Open Noctalia settings
   Super + Z
2. Bar: default > Widget List
3. Add widget
4. Select widget

## Use

- jellyfin-browser
    ```bash
    noctalia msg panel-toggle ktkr3d/jellyfin-browser:panel
    ```
    or use panel widget
