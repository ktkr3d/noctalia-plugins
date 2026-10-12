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
local queueLoading = false
local statusMessage = ""
local sessionWarning = ""
local errorMessage = ""
local requestGeneration = 0
local queueGeneration = 0
local artworkDirectory = nil
local artworkPaths = {}
local artworkPending = {}
local artworkQueue = {}
local artworkDownloadsActive = 0
local MAX_ARTWORK_DOWNLOADS = 3
local mpvSocketPath = nil
local mpvCommandGeneration = 0
local mpvPlayerAvailable = false
local mpvStarting = false
local mpvPaused = false
local mpvControlPending = false
local mpvPlaybackState = "stopped"

local render

local function isPlayableMedia(item)
    local mediaType = item.Type
    return mediaType == "Audio"
        or mediaType == "Movie"
        or mediaType == "Episode"
        or mediaType == "MusicVideo"
        or mediaType == "Video"
end

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
    if mpvPlayerAvailable then
        table.insert(content, ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = "mpv · " .. (mpvPaused and "Paused" or mpvPlaybackState),
                flexGrow = 1,
                color = "on_surface_variant",
            }),
            ui.button({
                text = mpvPaused and "Resume" or "Pause",
                enabled = mpvPlaybackState ~= "stopped" and not mpvControlPending and not mpvStarting,
                onClick = "onTogglePause",
            }),
            ui.button({
                text = "Stop",
                enabled = mpvPlaybackState ~= "stopped" and not mpvControlPending and not mpvStarting,
                onClick = "onStopPlayback",
            }),
            ui.button({
                text = "Next",
                enabled = mpvPlaybackState ~= "stopped" and not mpvControlPending and not mpvStarting,
                onClick = "onNextPlayback",
            }),
        }))
    end

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
            table.insert(content, ui.row({ gap = 8, align = "center" }, {
                ui.button({
                    text = queueLoading and "Preparing playlist..." or "Play all",
                    variant = "primary",
                    enabled = not loading and not queueLoading,
                    onClick = "onPlayAll",
                }),
                ui.button({
                    text = "Shuffle",
                    enabled = not loading and not queueLoading,
                    onClick = "onShuffle",
                }),
            }))
            if #items == 0 and not loading then
                table.insert(content, ui.label({ text = "This library is empty." }))
            end
            for _, item in ipairs(items) do
                local itemId = item.Id
                local isFolder = item.IsFolder == true
                local mediaType = item.Type
                local isAudio = mediaType == "Audio"
                local canPlay = isPlayableMedia(item)
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

local function prepareMpvIpc(callback)
    if not noctalia.commandExists("socat") then
        callback(false, "socat is not installed or is not available in Noctalia's PATH.")
        return
    end

    local _, pathError = getSessionPath()
    if pathError then
        callback(false, pathError)
        return
    end
    mpvSocketPath = sessionDataDir .. "/mpv.sock"

    if not noctalia.commandExists("chmod") then
        callback(false, "Cannot secure the mpv control socket because chmod is unavailable.")
        return
    end
    local accepted = noctalia.runAsync({ "chmod", "700", sessionDataDir }, function(result)
        if result.exitCode ~= 0 or result.timedOut then
            callback(false, "Could not secure the mpv control socket directory.")
            return
        end
        callback(true, nil)
    end)
    if not accepted then
        callback(false, "Could not start chmod to secure the mpv control socket directory.")
    end
end

local function removeMpvCommandFile(path)
    local removed, removeError = noctalia.removeFile(path)
    if not removed and noctalia.fileExists(path) then
        noctalia.log("could not remove temporary mpv command: " .. tostring(removeError or "unknown error"))
    end
end

local function sendMpvCommand(command, retries, callback)
    local contents, encodeError = noctalia.json.encode({ command = command })
    if not contents then
        callback(false, "Could not encode an mpv command: " .. tostring(encodeError or "JSON encoding failed"))
        return
    end

    prepareMpvIpc(function(ready, prepareError)
        if not ready then
            callback(false, prepareError)
            return
        end

        mpvCommandGeneration += 1
        local requestPath = sessionDataDir .. "/mpv-command-" .. tostring(mpvCommandGeneration) .. ".json"
        local written, writeError = noctalia.writeFile(requestPath, contents .. "\n")
        if not written then
            callback(false, "Could not prepare an mpv command: " .. tostring(writeError or "unknown error"))
            return
        end

        local chmodAccepted = noctalia.runAsync({ "chmod", "600", requestPath }, function(permissionResult)
            if permissionResult.exitCode ~= 0 or permissionResult.timedOut then
                removeMpvCommandFile(requestPath)
                callback(false, "Could not secure the mpv command file.")
                return
            end

            local script = 'attempt=0\nwhile [ "$attempt" -lt "$3" ]; do\n'
                .. '  if socat -T 1 - "UNIX-CONNECT:$2" < "$1" >/dev/null 2>&1; then exit 0; fi\n'
                .. '  attempt=$((attempt + 1))\n  sleep 0.1\ndone\nexit 1'
            local accepted = noctalia.runAsync({
                "sh",
                "-c",
                script,
                "jellyfin-browser",
                requestPath,
                mpvSocketPath,
                tostring(retries),
            }, function(result)
                removeMpvCommandFile(requestPath)
                if result.exitCode ~= 0 or result.timedOut then
                    callback(false, "Could not communicate with mpv through its control socket.")
                    return
                end
                callback(true, nil)
            end)
            if not accepted then
                removeMpvCommandFile(requestPath)
                callback(false, "Could not start socat to communicate with mpv.")
            end
        end)
        if not chmodAccepted then
            removeMpvCommandFile(requestPath)
            callback(false, "Could not start chmod to secure the mpv command.")
        end
    end)
end

local function playMpvCommand(command, onSuccess, onFailure)
    if mpvStarting then
        errorMessage = "mpv is starting. Please try again in a moment."
        if onFailure then
            onFailure(errorMessage)
        end
        render()
        return
    end

    mpvStarting = true
    sendMpvCommand(command, 3, function(sent)
        if sent then
            mpvStarting = false
            mpvPlayerAvailable = true
            mpvPaused = false
            mpvPlaybackState = "playing"
            onSuccess()
            render()
            return
        end

        mpvPlayerAvailable = false

        prepareMpvIpc(function(ready, prepareError)
            if not ready then
                mpvStarting = false
                errorMessage = prepareError
                if onFailure then
                    onFailure(prepareError)
                end
                render()
                return
            end

            if noctalia.fileExists(mpvSocketPath) then
                local removed, removeError = noctalia.removeFile(mpvSocketPath)
                if not removed then
                    mpvStarting = false
                    errorMessage = "Could not remove the stale mpv control socket: "
                        .. tostring(removeError or "unknown error")
                    if onFailure then
                        onFailure(errorMessage)
                    end
                    render()
                    return
                end
            end

            local started = noctalia.runAsync({
                "mpv",
                "--fs",
                "--idle=yes",
                "--input-ipc-server=" .. mpvSocketPath,
            })
            if not started then
                mpvStarting = false
                errorMessage = "Could not start mpv. Make sure it is installed."
                if onFailure then
                    onFailure(errorMessage)
                end
                render()
                return
            end

            sendMpvCommand(command, 30, function(commandSent, commandError)
                mpvStarting = false
                if not commandSent then
                    errorMessage = commandError
                    if onFailure then
                        onFailure(commandError)
                    end
                    render()
                    return
                end
                mpvPlayerAvailable = true
                mpvPaused = false
                mpvPlaybackState = "playing"
                onSuccess()
                render()
            end)
        end)
    end)
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
    playMpvCommand({ "loadfile", streamUrl, "replace" }, function()
        errorMessage = ""
        statusMessage = "Opening " .. (itemName or "media") .. " in mpv."
    end)
end

local function finishQueue(generation, message, isError)
    if generation ~= queueGeneration then
        return
    end
    queueLoading = false
    if isError then
        errorMessage = message
    else
        errorMessage = ""
        statusMessage = message
    end
    render()
end

local function removePlaybackPlaylist(path)
    local ok, err = noctalia.removeFile(path)
    if not ok and noctalia.fileExists(path) then
        noctalia.log("could not remove temporary Jellyfin playback playlist: " .. tostring(err or "unknown error"))
    end
end

local function launchMpvPlaylist(entries, shuffle, generation)
    if #entries == 0 then
        finishQueue(generation, "No playable items were found in this list.", true)
        return
    end
    if not noctalia.commandExists("mpv") then
        finishQueue(generation, "mpv is not installed or is not available in Noctalia's PATH.", true)
        return
    end

    local path, pathError = getSessionPath()
    if not path then
        finishQueue(generation, pathError, true)
        return
    end
    if not noctalia.commandExists("chmod") then
        finishQueue(generation, "Cannot create a private playback playlist because chmod is unavailable.", true)
        return
    end

    local playlistPath = sessionDataDir .. "/playback-" .. tostring(generation) .. ".m3u"
    local playlist = "#EXTM3U\n"
    for _, entry in ipairs(entries) do
        local endpoint = entry.isAudio and "/Audio/" or "/Videos/"
        local streamUrl = serverUrl .. endpoint .. noctalia.string.urlEncode(entry.id)
            .. "/stream?static=true&api_key=" .. noctalia.string.urlEncode(accessToken)
        playlist ..= streamUrl .. "\n"
    end

    local accepted = noctalia.runAsync({ "chmod", "700", sessionDataDir }, function(result)
        if generation ~= queueGeneration then
            return
        end
        if result.exitCode ~= 0 or result.timedOut then
            finishQueue(generation, "Could not secure the playback playlist directory.", true)
            return
        end

        local ok, writeError = noctalia.writeFile(playlistPath, playlist)
        if not ok then
            finishQueue(
                generation,
                "Could not create the playback playlist: " .. tostring(writeError or "unknown error"),
                true
            )
            return
        end

        local chmodAccepted = noctalia.runAsync({ "chmod", "600", playlistPath }, function(permissionResult)
            if generation ~= queueGeneration then
                removePlaybackPlaylist(playlistPath)
                return
            end
            if permissionResult.exitCode ~= 0 or permissionResult.timedOut then
                removePlaybackPlaylist(playlistPath)
                finishQueue(generation, "Could not secure the playback playlist.", true)
                return
            end

            local function finishPlaylist()
                removePlaybackPlaylist(playlistPath)
                finishQueue(
                    generation,
                    (shuffle and "Shuffling " or "Playing ")
                        .. tostring(#entries) .. " items in mpv.",
                    false
                )
            end
            playMpvCommand({ "loadlist", playlistPath, "replace" }, function()
                if not shuffle then
                    finishPlaylist()
                    return
                end
                sendMpvCommand({ "playlist-shuffle" }, 3, function(shuffled, shuffleError)
                    if not shuffled then
                        removePlaybackPlaylist(playlistPath)
                        finishQueue(generation, shuffleError, true)
                        return
                    end
                    finishPlaylist()
                end)
            end, function(playbackError)
                removePlaybackPlaylist(playlistPath)
                finishQueue(generation, playbackError, true)
            end)
        end)
        if not chmodAccepted then
            removePlaybackPlaylist(playlistPath)
            finishQueue(generation, "Could not start chmod to secure the playback playlist.", true)
        end
    end)

    if not accepted then
        finishQueue(generation, "Could not start chmod to secure the playback playlist directory.", true)
    end
end

local function playLibraryItems(shuffle)
    if not accessToken or #navigation == 0 or loading or queueLoading then
        return
    end

    if not noctalia.commandExists("mpv") then
        errorMessage = "mpv is not installed or is not available in Noctalia's PATH."
        render()
        return
    end
    if not noctalia.commandExists("socat") then
        errorMessage = "socat is not installed or is not available in Noctalia's PATH."
        render()
        return
    end

    queueGeneration += 1
    local generation = queueGeneration
    local parentId = navigation[#navigation].Id
    local startIndex = 0
    local totalCount = nil
    local entries = {}
    queueLoading = true
    errorMessage = ""
    statusMessage = ""
    render()

    local function fetchNextPage()
        if generation ~= queueGeneration then
            return
        end

        local query = "?ParentId=" .. noctalia.string.urlEncode(parentId)
            .. "&Recursive=true&SortBy=SortName&SortOrder=Ascending"
            .. "&StartIndex=" .. tostring(startIndex)
            .. "&Limit=" .. tostring(PAGE_SIZE)
            .. "&Fields=Overview,ProductionYear,ImageTags"
        local accepted = noctalia.http({
            url = serverUrl .. "/Users/" .. noctalia.string.urlEncode(userId) .. "/Items" .. query,
            headers = requestHeaders(),
        }, function(response)
            if generation ~= queueGeneration then
                return
            end

            local data, err = decodeResponse(
                response,
                200,
                "preparing a playback playlist (/Users/{userId}/Items)",
                "Your Jellyfin session expired. Please sign in again."
            )
            if not data then
                if response.status == 401 then
                    sessionWriteGeneration += 1
                    accessToken = nil
                    userId = nil
                    userName = nil
                    password = ""
                    sessionWarning = ""
                    local _, removeError = clearSavedSession()
                    if removeError then
                        err ..= " " .. removeError
                    end
                end
                finishQueue(generation, err, true)
                return
            end
            if type(data.Items) ~= "table" then
                finishQueue(generation, "The server response did not contain library items.", true)
                return
            end

            if startIndex == 0 then
                totalCount = tonumber(data.TotalRecordCount)
            end
            for _, item in ipairs(data.Items) do
                if type(item) == "table" and isPlayableMedia(item) and type(item.Id) == "string" then
                    table.insert(entries, {
                        id = item.Id,
                        isAudio = item.Type == "Audio",
                    })
                end
            end

            startIndex += #data.Items
            local hasMore = #data.Items > 0
                and ((totalCount and startIndex < totalCount) or (not totalCount and #data.Items == PAGE_SIZE))
            if hasMore then
                fetchNextPage()
            else
                launchMpvPlaylist(entries, shuffle, generation)
            end
        end)

        if not accepted then
            finishQueue(generation, "Could not start a request to the Jellyfin server.", true)
        end
    end

    fetchNextPage()
end

function onPlayAll()
    playLibraryItems(false)
end

function onShuffle()
    playLibraryItems(true)
end

local function controlMpv(command, onSuccess)
    if not mpvPlayerAvailable or mpvControlPending or mpvStarting then
        return
    end

    mpvControlPending = true
    render()
    sendMpvCommand(command, 3, function(sent, sendError)
        mpvControlPending = false
        if not sent then
            mpvPlayerAvailable = false
            errorMessage = sendError
        else
            onSuccess()
        end
        render()
    end)
end

function onTogglePause()
    local pause = not mpvPaused
    controlMpv({ "set_property", "pause", pause }, function()
        mpvPaused = pause
        statusMessage = pause and "Playback paused." or "Playback resumed."
        errorMessage = ""
    end)
end

function onStopPlayback()
    controlMpv({ "stop" }, function()
        mpvPaused = false
        mpvPlaybackState = "stopped"
        statusMessage = "Playback stopped."
        errorMessage = ""
    end)
end

function onNextPlayback()
    controlMpv({ "playlist-next" }, function()
        mpvPaused = false
        mpvPlaybackState = "playing"
        statusMessage = "Playing the next item."
        errorMessage = ""
    end)
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
    queueGeneration += 1
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
    queueLoading = false
    errorMessage = ""
    statusMessage = ""
    sessionWarning = ""
    local _, removeError = clearSavedSession()
    if removeError then
        errorMessage = removeError
    end
    render()
end
