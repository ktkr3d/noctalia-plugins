--!nonstrict

local showLabel = noctalia.getConfig("show_label") == true

local function render()
    barWidget.setGlyph("device-tv")
    barWidget.setText(showLabel and "Jellyfin" or "")
    barWidget.setTooltip("Open Jellyfin Browser")
end

function onClick()
    noctalia.togglePanel("ktkr3d/jellyfin-browser:panel")
end

function update()
    noctalia.setUpdateInterval(1000)
    render()
end
