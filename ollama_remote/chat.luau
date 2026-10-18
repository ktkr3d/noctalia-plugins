--!nonstrict
local DEFAULT_URL = "http://192.168.11.2:11434"
local DEFAULT_MODEL = "qwen3.5:4b"

local settings = {
    url = DEFAULT_URL,
    model = DEFAULT_MODEL
}
local settings_path
local settings_error
local models = {}
local messages = {}
local draft_message = ""
local status = "待機中"
local loading_models = false
local sending = false
local message_input_key = 0
local render

local function save_settings()
    if not settings_path then
        settings_error = "設定ファイルの保存先が利用できません"
        return
    end

    local ok, err = noctalia.writeFile(settings_path, noctalia.json.encode(settings))
    if not ok then
        settings_error = "設定を保存できません: " .. tostring(err)
    else
        settings_error = nil
    end
end

local function load_settings()
    local data_dir, dir_error = noctalia.pluginDataDir()
    if not data_dir then
        settings_error = "設定ディレクトリを利用できません: " .. tostring(dir_error)
        return
    end

    settings_path = data_dir .. "/settings.json"
    local raw, read_error = noctalia.readFile(settings_path)
    if not raw then
        local ok, write_error = noctalia.writeFile(settings_path, noctalia.json.encode(settings))
        if not ok then
            settings_error = "設定を初期化できません: " .. tostring(write_error or read_error)
        end
        return
    end

    local ok, saved = pcall(noctalia.json.decode, raw)
    if not ok or type(saved) ~= "table" then
        settings_error = "保存済み設定を読み込めません: " .. tostring(saved)
        return
    end
    if type(saved.url) == "string" and saved.url ~= "" then
        settings.url = saved.url
    end
    if type(saved.model) == "string" and saved.model ~= "" then
        settings.model = saved.model
    end
end

local function base_url()
    return settings.url:gsub("/+$", "")
end

local function fetch_models()
    if loading_models then
        return
    end
    if settings.url == "" then
        status = "URLを入力してください"
        render()
        return
    end

    loading_models = true
    status = "モデル一覧を取得中..."
    render()
    local accepted = noctalia.http({
        method = "GET",
        url = base_url() .. "/api/tags",
        headers = { "Accept: application/json" }
    }, function(response)
        loading_models = false
        if not response.ok then
            status = "モデル一覧を取得できません (HTTP " .. tostring(response.status) .. ")"
            render()
            return
        end

        local ok, data = pcall(noctalia.json.decode, response.body)
        if not ok or type(data) ~= "table" or type(data.models) ~= "table" then
            status = "モデル一覧の応答を解析できません"
            render()
            return
        end

        models = {}
        for _, model in ipairs(data.models) do
            if type(model) == "table" and type(model.name) == "string" then
                table.insert(models, model.name)
            end
        end
        if #models == 0 then
            status = "利用可能なモデルがありません"
        else
            local selected_model_found = false
            for _, model in ipairs(models) do
                if model == settings.model then
                    selected_model_found = true
                    break
                end
            end
            if not selected_model_found then
                settings.model = models[1]
                save_settings()
            end
            status = "接続しました"
        end
        render()
    end)

    if not accepted then
        loading_models = false
        status = "モデル一覧のリクエストを開始できませんでした"
        render()
    end
end

local function send_message(text)
    if sending or text == "" then
        return
    end
    if settings.url == "" or settings.model == "" then
        status = "URLとモデルを設定してください"
        render()
        return
    end

    table.insert(messages, { role = "user", content = text })
    draft_message = ""
    message_input_key += 1
    sending = true
    status = "応答を生成中..."
    render()

    local accepted = noctalia.http({
        method = "POST",
        url = base_url() .. "/api/chat",
        headers = { "Content-Type: application/json", "Accept: application/json" },
        body = noctalia.json.encode({
            model = settings.model,
            messages = messages,
            stream = false
        })
    }, function(response)
        sending = false
        if not response.ok then
            status = "チャットに失敗しました (HTTP " .. tostring(response.status) .. ")"
            render()
            return
        end

        local ok, data = pcall(noctalia.json.decode, response.body)
        if not ok or type(data) ~= "table"
            or type(data.message) ~= "table"
            or type(data.message.content) ~= "string" then
            status = "チャット応答を解析できません"
            render()
            return
        end
        if data.message.content:match("^%s*$") then
            status = "Ollamaから空の応答が返されました"
            render()
            return
        end

        table.insert(messages, { role = "assistant", content = data.message.content })
        status = "完了"
        render()
    end)

    if not accepted then
        sending = false
        status = "チャットのリクエストを開始できませんでした"
        render()
    end
end

render = function()
    local model_index = 0
    for index, model in ipairs(models) do
        if model == settings.model then
            model_index = index - 1
            break
        end
    end

    local conversation = {}
    for _, message in ipairs(messages) do
        table.insert(conversation, ui.column({ gap = 4 }, {
            ui.label({
                text = message.role == "user" and "あなた" or "Ollama",
                color = message.role == "user" and "primary" or "secondary",
                fontWeight = "medium"
            }),
            ui.label({ text = message.content })
        }))
    end
    if #conversation == 0 then
        table.insert(conversation, ui.label({
            text = "メッセージを入力してチャットを開始してください。",
            color = "on_surface_variant"
        }))
    end

    local children = {
        ui.label({ text = "Ollama Remote Chat", fontSize = 18, fontWeight = "bold" }),
        ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "ollama-url",
                value = settings.url,
                placeholder = "http://host:11434",
                flexGrow = 1,
                onSubmit = "onUrlSubmit"
            }),
            ui.button({
                text = loading_models and "接続中..." or "接続",
                enabled = not loading_models,
                onClick = "onFetchModels"
            })
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = "モデル" }),
            ui.select({
                options = models,
                selectedIndex = model_index,
                placeholder = "接続してモデルを取得",
                enabled = #models > 0 and not sending,
                flexGrow = 1,
                onChange = "onModelChanged"
            })
        }),
        ui.label({ text = status, color = "on_surface_variant" })
    }

    if settings_error then
        table.insert(children, ui.label({
            text = settings_error,
            color = "error"
        }))
    end

    table.insert(children, ui.separator({}))
    table.insert(children, ui.scroll({
        flexGrow = 1,
        gap = 12,
        stickToBottom = true
    }, conversation))
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.input({
            key = "ollama-message-" .. tostring(message_input_key),
            placeholder = "メッセージを入力...",
            enabled = not sending,
            flexGrow = 1,
            onChange = "onMessageChanged",
            onSubmit = "onMessageSubmit"
        }),
        ui.button({
            text = sending and "送信中..." or "送信",
            enabled = not sending,
            variant = "primary",
            onClick = "onSendClicked"
        })
    }))

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_context)
    render()
    fetch_models()
end

function onUrlSubmit(value)
    settings.url = value:gsub("^%s+", ""):gsub("%s+$", "")
    save_settings()
    fetch_models()
end

function onFetchModels()
    fetch_models()
end

function onModelChanged(index, _text)
    local selected = models[(tonumber(index) or -1) + 1]
    if selected then
        settings.model = selected
        save_settings()
        render()
    end
end

function onMessageSubmit(value)
    send_message(value)
end

function onMessageChanged(value)
    draft_message = value
end

function onSendClicked()
    send_message(draft_message)
end

load_settings()
