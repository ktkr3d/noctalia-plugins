--!nonstrict
local showLabel = noctalia.getConfig("show_label") == true

local function render()
    barWidget.setGlyph("message")
    barWidget.setText(showLabel and "Ollama" or "")
    barWidget.setTooltip("Open Ollama Remote Chat")
end

function onClick()
    noctalia.togglePanel("ktkr3d/ollama_remote:chat")
end

function update()
    noctalia.setUpdateInterval(1000)
    render()
end
