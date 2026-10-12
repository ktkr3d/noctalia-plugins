--!nonstrict

local PAGE_SIZE = 30
local CLIENT_NAME = "Noctalia"
local CLIENT_VERSION = "0.0.1"

local serverUrl = "http://192.168.1.2:8096"
local username = ""
local password = ""
local accessToken = nil
local userId = nil
local userName = nil
local sessionPath = nil
local sessionDataDir = nil
local sessionRestoreAttempted = false
local sessionWriteGeneration = 0

local libraries = {}
local items = {}
local navigation = {}
local totalItems = 0
local loading = false
local statusMessage = ""
local sessionWarning = ""
local errorMessage = ""
local requestGeneration = 0
local artworkDirectory = nil
local artworkPaths = {}
local artworkPending = {}
local artworkQueue = {}
local artworkDownloadsActive = 0
local MAX_ARTWORK_DOWNLOADS = 3

local render

local function safeCacheName(value)
    return tostring(value):gsub("[^%w_-]", "_")
end

local function artworkCachePath(itemId, tag)
    return artworkDirectory .. "/" .. safeCacheName(itemId) .. "-" .. safeCacheName(tag) .. ".jpg"
end

local function pumpArtworkQueue()
    while artworkDownloadsActive < MAX_ARTWORK_DOWNLOADS and #artworkQueue > 0 do
        local job = table.remove(artworkQueue, 1)
        if not artworkPaths[job.key] then
            artworkDownloadsActive += 1
            local accepted = noctalia.download(job.url, job.path, function(ok)
                artworkDownloadsActive -= 1
                artworkPending[job.key] = nil
                if ok then
                    artworkPaths[job.key] = job.path
                    render()
                else
                    noctalia.log("failed to download Jellyfin artwork for item " .. job.itemId)
                end
                pumpArtworkQueue()
            end)
            if not accepted then
                artworkDownloadsActive -= 1
                table.insert(artworkQueue, 1, job)
                break
            end
        end
    end
end

local function artworkPath(item)
    local tags = item.ImageTags
    local imageTag = type(tags) == "table" and tags.Primary or item.PrimaryImageTag
    if type(item.Id) ~= "string" or type(imageTag) ~= "string" or imageTag == "" then
        return nil
    end

    local cacheKey = item.Id .. ":" .. imageTag
    local existingPath = artworkPaths[cacheKey]
    if existingPath and noctalia.fileExists(existingPath) then
        return existingPath
    end

    if not artworkDirectory then
        local dataDir, err = noctalia.pluginDataDir()
        if not dataDir then
            noctalia.log("could not access plugin data directory for artwork: " .. tostring(err or "unknown error"))
            return nil
        end
        artworkDirectory = dataDir:gsub("/+$", "") .. "/artwork"
        local ok, mkdirError = noctalia.mkdirAll(artworkDirectory)
        if not ok then
            artworkDirectory = nil
            noctalia.log("could not create artwork cache directory: " .. tostring(mkdirError or "unknown error"))
            return nil
        end
    end

    local path = artworkCachePath(item.Id, imageTag)
    if noctalia.fileExists(path) then
        artworkPaths[cacheKey] = path
        return path
    end
    if not artworkPending[cacheKey] then
        artworkPending[cacheKey] = true
        local imageUrl = serverUrl .. "/Items/" .. noctalia.string.urlEncode(item.Id)
            .. "/Images/Primary?maxWidth=180&maxHeight=270&quality=80&tag="
            .. noctalia.string.urlEncode(imageTag)
            .. "&api_key=" .. noctalia.string.urlEncode(accessToken)
        table.insert(artworkQueue, {
            key = cacheKey,
            itemId = item.Id,
            path = path,
            url = imageUrl,
        })
        pumpArtworkQueue()
    end
    return nil
end

render = function()
    local header = {
        ui.label({
            text = "Jellyfin Browser",
            fontSize = 18,
            fontWeight = "bold",
            flexGrow = 1,
        }),
    }

    if accessToken then
        if #navigation > 0 then
            table.insert(header, ui.button({
                glyph = "arrow-left",
                variant = "ghost",
                tooltip = "Back",
                onClick = "onBack",
            }))
        end
        table.insert(header, ui.button({
            glyph = "refresh",
            variant = "ghost",
            tooltip = "Refresh",
            enabled = not loading,
            onClick = "onRefresh",
        }))
        table.insert(header, ui.button({
            glyph = "logout",
            variant = "ghost",
            tooltip = "Sign out",
            onClick = "onLogout",
        }))
    end

    local content = {}
    if not accessToken then
        table.insert(content, ui.label({
            text = "Connect to your Jellyfin server",
            fontSize = 14,
            fontWeight = "medium",
        }))
        table.insert(content, ui.label({
            text = "Your password is not saved. A Jellyfin access token is stored locally for next time.",
            fontSize = 12,
            color = "on_surface_variant",
            maxLines = 2,
        }))
        table.insert(content, ui.input({
            key = "server-url",
            value = serverUrl,
            placeholder = "Server URL (for example http://192.168.1.2:8096)",
            onChange = "onServerUrlChanged",
        }))
        table.insert(content, ui.input({
            key = "username",
            value = username,
            placeholder = "Username",
            onChange = "onUsernameChanged",
        }))
        table.insert(content, ui.input({
            key = "password",
            value = password,
            placeholder = "Password",
            password = true,
            onChange = "onPasswordChanged",
            onSubmit = "onPasswordSubmitted",
        }))
        table.insert(content, ui.button({
            text = loading and "Signing in..." or "Sign in",
            variant = "primary",
            enabled = not loading,
            onClick = "onLogin",
        }))
    else
        local location = #navigation == 0 and "Libraries" or navigation[#navigation].Name
        table.insert(content, ui.label({
            text = "Signed in as " .. (userName or username) .. "  ·  " .. location,
            color = "on_surface_variant",
            maxLines = 1,
        }))

        if loading and #libraries == 0 and #items == 0 then
            table.insert(content, ui.label({ text = "Loading..." }))
        elseif #navigation == 0 then
            if #libraries == 0 and not loading then
                table.insert(content, ui.label({ text = "No libraries were found for this user." }))
            end
            for _, library in ipairs(libraries) do
                local libraryId = library.Id
                table.insert(content, ui.row({ gap = 8, align = "center" }, {
                    ui.label({
                        text = library.Name or "Untitled library",
                        flexGrow = 1,
                        maxLines = 1,
                    }),
                    ui.button({
                        text = "Browse",
                        onClick = function()
                            table.insert(navigation, library)
                            fetchItems(libraryId, false)
                        end,
                    }),
                }))
            end
        else
            if #items == 0 and not loading then
                table.insert(content, ui.label({ text = "This library is empty." }))
            end
            for _, item in ipairs(items) do
                local itemId = item.Id
                local isFolder = item.IsFolder == true
                local mediaType = item.Type
                local isAudio = mediaType == "Audio"
                local canPlay = isAudio
                    or mediaType == "Movie"
                    or mediaType == "Episode"
                    or mediaType == "MusicVideo"
                    or mediaType == "Video"
                local details = item.Type or "Item"
                if item.ProductionYear then
                    details = details .. " · " .. tostring(item.ProductionYear)
                end
                local posterPath = artworkPath(item)
                local children = {
                    posterPath and ui.image({
                        path = posterPath,
                        width = 72,
                        height = 108,
                        fit = "cover",
                        radius = 6,
                    }) or ui.box({
                        width = 72,
                        height = 108,
                        fill = "surface_variant",
                        radius = 6,
                    }),
                    ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
                        ui.label({
                            text = item.Name or "Untitled",
                            fontWeight = "medium",
                            maxLines = 1,
                        }),
                        ui.label({
                            text = details,
                            fontSize = 12,
                            color = "on_surface_variant",
                        }),
                    }),
                }
                if isFolder or canPlay then
                    table.insert(children, ui.button({
                        text = isFolder and "Open" or "Play",
                        onClick = function()
                            if isFolder then
                                table.insert(navigation, item)
                                fetchItems(itemId, false)
                            else
                                playInMpv(itemId, isAudio, item.Name)
                            end
                        end,
                    }))
                end
                table.insert(content, ui.column({ gap = 4, align = "stretch" }, {
                    ui.row({ gap = 8, align = "center" }, children),
                    item.Overview and item.Overview ~= "" and ui.label({
                        text = item.Overview,
                        fontSize = 12,
                        color = "on_surface_variant",
                        maxLines = 3,
                    }) or ui.spacer({ height = 0 }),
                }))
            end
            if loading then
                table.insert(content, ui.label({ text = "Loading..." }))
            elseif #items < totalItems then
                table.insert(content, ui.button({
                    text = "Load more",
                    onClick = "onLoadMore",
                }))
            end
        end
    end

    if errorMessage ~= "" then
        table.insert(content, ui.label({
            text = errorMessage,
            color = "error",
            maxLines = 3,
        }))
    elseif statusMessage ~= "" then
        table.insert(content, ui.label({
            text = statusMessage,
            color = "on_surface_variant",
        }))
    elseif sessionWarning ~= "" then
        table.insert(content, ui.label({
            text = sessionWarning,
            color = "on_surface_variant",
            maxLines = 3,
        }))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, header),
        ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, content),
    }))
end

local function cleanServerUrl(value)
    local cleaned = noctalia.string.trim(value):gsub("/+$", "")
    if not cleaned:match("^https?://[^%s]+$") then
        return nil
    end
    return cleaned
end

local function getSessionPath()
    if sessionPath then
        return sessionPath, nil
    end

    local dataDir, err = noctalia.pluginDataDir()
    if not dataDir then
        return nil, "Could not open the plugin data directory: " .. tostring(err or "unknown error")
    end
    sessionDataDir = dataDir:gsub("/+$", "")
    sessionPath = sessionDataDir .. "/session.json"
    return sessionPath, nil
end

local function saveSession(onComplete)
    local path, pathError = getSessionPath()
    if not path then
        onComplete(false, pathError)
        return
    end

    local contents, encodeError = noctalia.json.encode({
        serverUrl = serverUrl,
        username = username,
        accessToken = accessToken,
        userId = userId,
        userName = userName,
    })
    if not contents then
        onComplete(false, "Could not encode the saved session: " .. tostring(encodeError or "unknown error"))
        return
    end

    if not noctalia.commandExists("chmod") then
        onComplete(false, "Cannot save the session securely because chmod is unavailable.")
        return
    end

    sessionWriteGeneration += 1
    local generation = sessionWriteGeneration
    local accepted = noctalia.runAsync({ "chmod", "700", sessionDataDir }, function(result)
        if generation ~= sessionWriteGeneration then
            return
        end
        if result.exitCode ~= 0 or result.timedOut then
            onComplete(false, "Could not restrict access to the plugin data directory.")
            return
        end

        local ok, writeError = noctalia.writeFile(path, contents)
        if not ok then
            onComplete(false, "Could not save the session: " .. tostring(writeError or "unknown error"))
            return
        end

        local chmodAccepted = noctalia.runAsync({ "chmod", "600", path }, function(permissionResult)
            if generation ~= sessionWriteGeneration then
                return
            end
            if permissionResult.exitCode ~= 0 or permissionResult.timedOut then
                onComplete(false, "Session saved in a private directory, but file permissions could not be restricted.")
                return
            end
            onComplete(true, nil)
        end)
        if not chmodAccepted then
            onComplete(false, "Session saved in a private directory, but file permissions could not be restricted.")
        end
    end)

    if not accepted then
        onComplete(false, "Could not start chmod to secure the saved session.")
    end
end

local function clearSavedSession()
    local path, pathError = getSessionPath()
    if not path then
        return false, pathError
    end
    if not noctalia.fileExists(path) then
        return true, nil
    end

    local ok, removeError = noctalia.removeFile(path)
    if not ok then
        return false, "Could not remove the saved session: " .. tostring(removeError or "unknown error")
    end
    return true, nil
end

local function restoreSession()
    local path, pathError = getSessionPath()
    if not path then
        errorMessage = pathError
        return
    end
    if not noctalia.fileExists(path) then
        return
    end

    local contents, readError = noctalia.readFile(path)
    if not contents then
        errorMessage = "Could not read the saved session: " .. tostring(readError or "unknown error")
        return
    end

    local saved, decodeError = noctalia.json.decode(contents)
    if type(saved) ~= "table" then
        errorMessage = "Could not read the saved session: " .. tostring(decodeError or "invalid session data")
        return
    end
    if type(saved.serverUrl) ~= "string"
        or type(saved.username) ~= "string"
        or type(saved.accessToken) ~= "string"
        or type(saved.userId) ~= "string" then
        errorMessage = "The saved session is incomplete. Please sign in again."
        local _, removeError = clearSavedSession()
        if removeError then
            errorMessage ..= " " .. removeError
        end
        return
    end

    serverUrl = saved.serverUrl
    username = saved.username
    accessToken = saved.accessToken
    userId = saved.userId
    userName = type(saved.userName) == "string" and saved.userName or username
    statusMessage = "Restoring your Jellyfin session..."
end

local function serverErrorMessage(body)
    local data = noctalia.json.decode(body)
    if type(data) ~= "table" then
        return nil
    end

    local message = data.Message or data.message or data.Error or data.error
    if type(message) ~= "string" then
        return nil
    end

    message = message:gsub("[%c]", " ")
    if #message > 240 then
        message = message:sub(1, 240) .. "..."
    end
    return message
end

local function decodeResponse(response, expectedStatus, operation, unauthorizedMessage)
    if not response.ok then
        return nil, "Could not reach Jellyfin while " .. operation .. "."
    end
    if response.status ~= expectedStatus then
        if response.status == 401 then
            return nil, unauthorizedMessage or "Authentication failed. Check your username and password."
        end
        local message = serverErrorMessage(response.body)
        local details = message and (": " .. message) or ""
        return nil, "Jellyfin " .. operation .. " returned HTTP " .. tostring(response.status) .. details .. "."
    end

    local data, decodeError = noctalia.json.decode(response.body)
    if data == nil then
        return nil, "Could not read the Jellyfin response: " .. tostring(decodeError or "invalid JSON")
    end
    return data, nil
end

local function requestHeaders()
    return {
        "X-Emby-Token: " .. accessToken,
        "Authorization: MediaBrowser Client=\"" .. CLIENT_NAME
            .. "\", Device=\"Noctalia\", DeviceId=\"ktkr3d-jellyfin-browser\", Version=\""
            .. CLIENT_VERSION .. "\", Token=\"" .. accessToken .. "\"",
    }
end

function fetchViews()
    if not accessToken then
        return
    end

    requestGeneration += 1
    local generation = requestGeneration
    loading = true
    errorMessage = ""
    statusMessage = ""
    render()

    local accepted = noctalia.http({
        url = serverUrl .. "/Users/" .. noctalia.string.urlEncode(userId) .. "/Views",
        headers = requestHeaders(),
    }, function(response)
        if generation ~= requestGeneration then
            return
        end
        loading = false
        local data, err = decodeResponse(
            response,
            200,
            "loading libraries (/Users/{userId}/Views)",
            "Your Jellyfin session expired. Please sign in again."
        )
        if not data then
            errorMessage = err
            if response.status == 401 then
                sessionWriteGeneration += 1
                accessToken = nil
                userId = nil
                userName = nil
                password = ""
                sessionWarning = ""
                local _, removeError = clearSavedSession()
                if removeError then
                    errorMessage ..= " " .. removeError
                end
            end
        elseif type(data.Items) ~= "table" then
            errorMessage = "The server response did not contain a library list."
        else
            libraries = data.Items
            items = {}
            navigation = {}
            totalItems = 0
        end
        render()
    end)

    if not accepted then
        loading = false
        errorMessage = "Could not start a request to the Jellyfin server."
        render()
    end
end

function fetchItems(parentId, append)
    if not accessToken then
        return
    end

    requestGeneration += 1
    local generation = requestGeneration
    local startIndex = append and #items or 0
    loading = true
    errorMessage = ""
    statusMessage = ""
    if not append then
        items = {}
        totalItems = 0
    end
    render()

    local query = "?ParentId=" .. noctalia.string.urlEncode(parentId)
        .. "&Recursive=true&SortBy=SortName&SortOrder=Ascending"
        .. "&StartIndex=" .. tostring(startIndex)
        .. "&Limit=" .. tostring(PAGE_SIZE)
        .. "&Fields=Overview,ProductionYear,ImageTags"
    local accepted = noctalia.http({
        url = serverUrl .. "/Users/" .. noctalia.string.urlEncode(userId) .. "/Items" .. query,
        headers = requestHeaders(),
    }, function(response)
        if generation ~= requestGeneration then
            return
        end
        loading = false
        local data, err = decodeResponse(
            response,
            200,
            "loading library items (/Users/{userId}/Items)",
            "Your Jellyfin session expired. Please sign in again."
        )
        if not data then
            errorMessage = err
            if response.status == 401 then
                sessionWriteGeneration += 1
                accessToken = nil
                userId = nil
                userName = nil
                password = ""
                sessionWarning = ""
                local _, removeError = clearSavedSession()
                if removeError then
                    errorMessage ..= " " .. removeError
                end
            end
        elseif type(data.Items) ~= "table" then
            errorMessage = "The server response did not contain library items."
        else
            if append then
                for _, item in ipairs(data.Items) do
                    table.insert(items, item)
                end
            else
                items = data.Items
            end
            totalItems = tonumber(data.TotalRecordCount) or #items
        end
        render()
    end)

    if not accepted then
        loading = false
        errorMessage = "Could not start a request to the Jellyfin server."
        render()
    end
end

function playInMpv(itemId, isAudio, itemName)
    if not noctalia.commandExists("mpv") then
        errorMessage = "mpv is not installed or is not available in Noctalia's PATH."
        render()
        return
    end

    local endpoint = isAudio and "/Audio/" or "/Videos/"
    local streamUrl = serverUrl .. endpoint .. noctalia.string.urlEncode(itemId)
        .. "/stream?static=true&api_key=" .. noctalia.string.urlEncode(accessToken)
    local accepted = noctalia.runAsync({ "mpv", "--fs", streamUrl })
    if not accepted then
        errorMessage = "Could not start mpv. Make sure it is installed."
    else
        errorMessage = ""
        statusMessage = "Opening " .. (itemName or "media") .. " in mpv."
    end
    render()
end

function onOpen()
    if not sessionRestoreAttempted then
        sessionRestoreAttempted = true
        restoreSession()
    end
    if accessToken then
        fetchViews()
    else
        render()
    end
end

function onServerUrlChanged(value)
    serverUrl = value
end

function onUsernameChanged(value)
    username = value
end

function onPasswordChanged(value)
    password = value
end

function onPasswordSubmitted(value)
    password = value
    onLogin()
end

function onLogin()
    local cleanedUrl = cleanServerUrl(serverUrl)
    username = noctalia.string.trim(username)
    if not cleanedUrl then
        errorMessage = "Enter a valid server URL beginning with http:// or https://."
        render()
        return
    end
    if username == "" or password == "" then
        errorMessage = "Enter your Jellyfin username and password."
        render()
        return
    end

    serverUrl = cleanedUrl
    requestGeneration += 1
    local generation = requestGeneration
    loading = true
    errorMessage = ""
    statusMessage = ""
    render()

    local body, encodeError = noctalia.json.encode({
        Username = username,
        Pw = password,
    })
    if not body then
        loading = false
        errorMessage = "Could not prepare the sign-in request: " .. tostring(encodeError or "JSON encoding failed")
        render()
        return
    end

    local authorization = "MediaBrowser Client=\"" .. CLIENT_NAME
        .. "\", Device=\"Noctalia\", DeviceId=\"ktkr3d-jellyfin-browser\", Version=\""
        .. CLIENT_VERSION .. "\""
    local accepted = noctalia.http({
        url = serverUrl .. "/Users/AuthenticateByName",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "Authorization: " .. authorization,
        },
        body = body,
    }, function(response)
        if generation ~= requestGeneration then
            return
        end
        loading = false
        local data, err = decodeResponse(response, 200, "signing in (/Users/AuthenticateByName)")
        if not data then
            errorMessage = err
        elseif type(data.AccessToken) ~= "string" or type(data.User) ~= "table"
            or type(data.User.Id) ~= "string" then
            errorMessage = "Jellyfin's sign-in response was missing the user or access token."
        else
            accessToken = data.AccessToken
            userId = data.User.Id
            userName = data.User.Name or username
            password = ""
            statusMessage = ""
            sessionWarning = "Saving session..."
            saveSession(function(saved, saveError)
                sessionWarning = saved and "" or saveError
                render()
            end)
            fetchViews()
            return
        end
        render()
    end)

    if not accepted then
        loading = false
        errorMessage = "Could not start a request to the Jellyfin server."
        render()
    end
end

function onRefresh()
    if #navigation == 0 then
        fetchViews()
    else
        fetchItems(navigation[#navigation].Id, false)
    end
end

function onBack()
    if #navigation == 0 then
        return
    end
    table.remove(navigation)
    if #navigation == 0 then
        fetchViews()
    else
        fetchItems(navigation[#navigation].Id, false)
    end
end

function onLoadMore()
    if #navigation > 0 and not loading then
        fetchItems(navigation[#navigation].Id, true)
    end
end

function onLogout()
    requestGeneration += 1
    sessionWriteGeneration += 1
    accessToken = nil
    userId = nil
    userName = nil
    password = ""
    libraries = {}
    items = {}
    navigation = {}
    totalItems = 0
    loading = false
    errorMessage = ""
    statusMessage = ""
    sessionWarning = ""
    local _, removeError = clearSavedSession()
    if removeError then
        errorMessage = removeError
    end
    render()
end
