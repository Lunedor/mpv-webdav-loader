-- mpv-webdav-loader.lua
-- Interactive WebDAV browser for mpv.
--
-- Install:
--   Windows: %APPDATA%\mpv\scripts\mpv-webdav-loader.lua
--   Linux:   ~/.config/mpv/scripts/mpv-webdav-loader.lua
--
-- Config:
--   Create:
--   script-opts/mpv-webdav-loader.conf
--
--   url=https://webdav.example.com/
--   user=your-email@example.com
--   pass=your-password-or-token
--   key=ctrl+w
--   max_depth=6
--   extensions=mkv,mp4,avi,mov,webm,ts,m2ts,flv,wmv,mp3,flac,aac,ogg,m4a,wav,m3u8
--
-- Requirements:
--   curl.exe must be available on PATH on Windows.

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local scan_folder_and_open_browser
local scan_and_append

local o = {
    url = "",
    user = "",
    pass = "",
    key = "ctrl+w",
    max_depth = 6,
    extensions = "mkv,mp4,avi,mov,webm,ts,m2ts,flv,wmv,mp3,flac,aac,ogg,m4a,wav,m3u8",
}

options.read_options(o, "mpv-webdav-loader")


----------------------------------------------------------------------
-- General helpers
----------------------------------------------------------------------

local ext_set = {}

for extension in string.gmatch(o.extensions or "", "[^,]+") do
    extension = extension:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if extension ~= "" then
        ext_set[extension] = true
    end
end


local function osd(text, duration)
    mp.osd_message(text, duration or 4)
end


local function normalize_folder_url(url)
    if not url or url == "" then
        return nil
    end

    url = url:gsub("/+$", "")
    return url .. "/"
end


local function url_without_trailing_slash(url)
    return (url or ""):gsub("/+$", "")
end


local function same_url(a, b)
    return url_without_trailing_slash(a) == url_without_trailing_slash(b)
end


local function url_encode_component(value)
    return (value:gsub("[^%w%-%._%~]", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end


local function percent_decode(value)
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end


local function filename_from_url(url)
    local name = url:match("([^/]+)/?$") or url
    return percent_decode(name)
end


local function get_extension(path)
    local name = path:match("([^/]+)$") or ""
    local extension = name:match("%.([%w]+)$")
    return extension and extension:lower() or ""
end


local function inject_auth(url, user, pass)
    local scheme, rest = url:match("^(https?://)(.+)$")

    if not scheme then
        return url
    end

    local safe_user = url_encode_component(user or "")
    local safe_pass = url_encode_component(pass or "")

    return scheme .. safe_user .. ":" .. safe_pass .. "@" .. rest
end


local function url_join(base, href)
    if href:match("^https?://") then
        return href
    end

    local scheme, host = base:match("^(https?://)([^/]+)")

    if not scheme then
        return href
    end

    if href:sub(1, 1) ~= "/" then
        href = "/" .. href
    end

    return scheme .. host .. href
end


local function folder_parent(url)
    url = normalize_folder_url(url)

    if not url then
        return nil
    end

    local path_without_slash = url:gsub("/$", "")
    local parent = path_without_slash:match("^(https?://[^/]+/.+)/[^/]+$")

    if parent then
        return parent .. "/"
    end

    local scheme_host = path_without_slash:match("^(https?://[^/]+)")

    if scheme_host then
        return scheme_host .. "/"
    end

    return nil
end


----------------------------------------------------------------------
-- WebDAV XML and HTTP
----------------------------------------------------------------------

local function parse_multistatus(xml)
    local entries = {}

    for block in xml:gmatch("<[%w_%-]+:?response[^>]*>(.-)</[%w_%-]+:?response>") do
        local href = block:match("<[%w_%-]+:?href[^>]*>(.-)</[%w_%-]+:?href>")
        local is_dir = block:match("<[%w_%-]+:?collection[^>]*/?>") ~= nil

        if href then
            entries[#entries + 1] = {
                href = href,
                is_dir = is_dir,
            }
        end
    end

    return entries
end


local function propfind_async(url, callback)
    local args = {
        "curl.exe",
        "-s",
        "-L",
        "-X",
        "PROPFIND",
        "-H",
        "Depth: 1",
        "-u",
        o.user .. ":" .. o.pass,
        "-w",
        "\n___HTTP_STATUS___%{http_code}",
        url,
    }

    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result)
        if not success or not result then
            callback(
                false,
                nil,
                nil,
                "curl did not run. Is curl.exe available on PATH?"
            )
            return
        end

        if result.status ~= 0 then
            callback(
                false,
                nil,
                nil,
                "curl exit code "
                    .. tostring(result.status)
                    .. ": "
                    .. tostring(result.stderr or "")
            )
            return
        end

        local output = result.stdout or ""

        local body, http_code = output:match(
            "^(.-)\n___HTTP_STATUS___(%d+)%s*$"
        )

        if not body then
            body = output
        end

        callback(true, body, http_code, nil)
    end)
end


----------------------------------------------------------------------
-- Browser state
----------------------------------------------------------------------

local browser = {
    open = false,
    mode = "files",

    files = {},
    folders = {},

    cursor = 1,

    -- These are keyed by URL, not by array index.
    selected = {},
    added = {},

    scan_errors = {},

    current_folder_url = nil,
    root_url = nil,
    history = {},

    search_query = "",
    searching = false,

    loading = false,
}


local function browser_current_list()
    if browser.mode == "files" then
        return browser.files
    end

    local combined = {}

    for _, folder in ipairs(browser.folders) do
        combined[#combined + 1] = folder
    end

    for _, file in ipairs(browser.files) do
        combined[#combined + 1] = file
    end

    return combined
end


local function browser_filtered_indices(list)
    local indices = {}

    if browser.search_query == "" then
        for index = 1, #list do
            indices[#indices + 1] = index
        end

        return indices
    end

    local query = browser.search_query:lower()

    for index, item in ipairs(list) do
        local name = filename_from_url(item):lower()

        if name:find(query, 1, true) then
            indices[#indices + 1] = index
        end
    end

    return indices
end


local function is_folder_url(url)
    for _, folder in ipairs(browser.folders) do
        if same_url(folder, url) then
            return true
        end
    end

    return false
end


local function is_file_url(url)
    for _, file in ipairs(browser.files) do
        if file == url then
            return true
        end
    end

    return false
end


local function has_selected_files()
    for url, selected in pairs(browser.selected) do
        if selected and is_file_url(url) then
            return true
        end
    end

    return false
end


local function clear_selection()
    browser.selected = {}
end


local function browser_item_status(item)
    if browser.mode == "folders" and is_folder_url(item) then
        return "[D]"
    end

    if browser.added[item] then
        return "[a]"
    end

    if browser.selected[item] then
        return "[x]"
    end

    return "[ ]"
end


----------------------------------------------------------------------
-- Browser rendering
----------------------------------------------------------------------

local function browser_render()
    if not browser.open then
        return
    end

    local list = browser_current_list()
    local filtered_indices = browser_filtered_indices(list)

    local total = #list
    local shown = #filtered_indices

    local mode_label = browser.mode == "files" and "files" or "folders"
    local enter_action = browser.mode == "files"
        and "play"
        or "open folder"

    local lines = {}

    lines[#lines + 1] = string.format(
        "Mode: %s | Enter: %s | Shift+Enter: add",
        mode_label,
        enter_action
    )

    lines[#lines + 1] =
        "↑/↓ move | Space select | a add selected | ← back"

    lines[#lines + 1] =
        "Alt+m mode | Alt+s search | r rescan | Esc close"

    if browser.current_folder_url then
        lines[#lines + 1] =
            "Folder: " .. filename_from_url(browser.current_folder_url)
    end

    if browser.searching or browser.search_query ~= "" then
        lines[#lines + 1] = string.format(
            "Search: %s (%d / %d)",
            browser.search_query,
            shown,
            total
        )
    else
        lines[#lines + 1] = string.format("Total: %d items", total)
    end

    lines[#lines + 1] = ""

    if shown == 0 then
        lines[#lines + 1] = "(no matches)"
        mp.osd_message(table.concat(lines, "\n"), 86400)
        return
    end

    if browser.cursor > shown then
        browser.cursor = shown
    end

    if browser.cursor < 1 then
        browser.cursor = 1
    end

    local visible_start = math.max(1, browser.cursor - 10)
    local visible_end = math.min(shown, visible_start + 20)

    for visible_index = visible_start, visible_end do
        local original_index = filtered_indices[visible_index]
        local item = list[original_index]

        local prefix = visible_index == browser.cursor
            and "▶ "
            or "  "

        local status = browser_item_status(item)
        local display_name = filename_from_url(item)

        lines[#lines + 1] =
            prefix .. status .. " " .. display_name
    end

    if #browser.scan_errors > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] =
            "Scan errors: " .. tostring(#browser.scan_errors)
    end

    mp.osd_message(table.concat(lines, "\n"), 86400)
end


----------------------------------------------------------------------
-- Browser actions
----------------------------------------------------------------------

local function browser_unbind_keys()
    local names = {
        "webdav-browser-up",
        "webdav-browser-down",
        "webdav-browser-page-up",
        "webdav-browser-page-down",
        "webdav-browser-home",
        "webdav-browser-end",
        "webdav-browser-play",
        "webdav-browser-add",
        "webdav-browser-select",
        "webdav-browser-add-selected",
        "webdav-browser-rescan",
        "webdav-browser-close",
        "webdav-browser-toggle-mode",
        "webdav-browser-search",
        "webdav-browser-search-cancel",
        "webdav-browser-search-backspace",
        "webdav-browser-search-clear",
        "webdav-browser-back",
    }

    for _, name in ipairs(names) do
        mp.remove_key_binding(name)
    end

    local letters = "abcdefghijklmnopqrstuvwxyz0123456789-_. "

    for index = 1, #letters do
        local character = letters:sub(index, index)

        mp.remove_key_binding(
            "webdav-browser-search-char-" .. character
        )
    end
end


local function browser_close()
    browser.open = false
    browser.loading = false

    browser.files = {}
    browser.folders = {}
    browser.selected = {}
    browser.added = {}
    browser.scan_errors = {}

    browser.search_query = ""
    browser.searching = false

    browser_unbind_keys()
    mp.osd_message("")
end


local function browser_move(delta)
    local list = browser_current_list()
    local filtered_indices = browser_filtered_indices(list)

    if #filtered_indices == 0 then
        return
    end

    browser.cursor = browser.cursor + delta

    if browser.cursor < 1 then
        browser.cursor = #filtered_indices
    elseif browser.cursor > #filtered_indices then
        browser.cursor = 1
    end

    browser_render()
end


local function browser_play_or_open()
    local list = browser_current_list()
    local filtered_indices = browser_filtered_indices(list)

    if #filtered_indices == 0 then
        return
    end

    local item = list[filtered_indices[browser.cursor]]

    if not item then
        return
    end

    if browser.mode == "folders" and is_folder_url(item) then
        scan_folder_and_open_browser(item)
        return
    end

    local playable = inject_auth(item, o.user, o.pass)

    browser_close()
    mp.commandv("loadfile", playable, "replace")
end


local function append_file(url)
    if not url or not is_file_url(url) then
        return false
    end

    if browser.added[url] then
        return false
    end

    local playable = inject_auth(url, o.user, o.pass)

    mp.commandv("loadfile", playable, "append")
    browser.added[url] = true

    return true
end


local function browser_add_selected()
    local count = 0

    for url, selected in pairs(browser.selected) do
        if selected and append_file(url) then
            count = count + 1
        end
    end

    clear_selection()

    if count > 0 then
        osd(("Added %d selected file(s)."):format(count), 3)
    else
        osd("No new selected files to add.", 2)
    end

    browser_render()
end


local function browser_add_current_or_selected()
    local list = browser_current_list()
    local filtered_indices = browser_filtered_indices(list)

    if #filtered_indices == 0 then
        return
    end

    local item = list[filtered_indices[browser.cursor]]

    if not item then
        return
    end

    if browser.mode == "folders" and is_folder_url(item) then
        scan_folder_and_open_browser(item)
        return
    end

    if has_selected_files() then
        browser_add_selected()
        return
    end

    if append_file(item) then
        osd("Added: " .. filename_from_url(item), 2)
    else
        osd("Already added: " .. filename_from_url(item), 2)
    end

    browser_render()
end


local function browser_toggle_selected()
    local list = browser_current_list()
    local filtered_indices = browser_filtered_indices(list)

    if #filtered_indices == 0 then
        return
    end

    local item = list[filtered_indices[browser.cursor]]

    if not item or is_folder_url(item) then
        return
    end

    browser.selected[item] = not browser.selected[item]

    if not browser.selected[item] then
        browser.selected[item] = nil
    end

    browser_render()
end


----------------------------------------------------------------------
-- Search
----------------------------------------------------------------------

local function browser_start_search()
    browser.searching = true
    browser.search_query = ""
    browser.cursor = 1
    browser_render()
end


local function browser_search_append(character)
    if not browser.searching then
        return
    end

    browser.search_query = browser.search_query .. character
    browser.cursor = 1
    browser_render()
end


local function browser_search_backspace()
    if not browser.searching then
        return
    end

    if browser.search_query == "" then
        return
    end

    browser.search_query =
        browser.search_query:sub(1, -2)

    browser.cursor = 1
    browser_render()
end


local function browser_search_clear()
    if not browser.searching then
        return
    end

    browser.search_query = ""
    browser.cursor = 1
    browser_render()
end


local function browser_search_confirm()
    if not browser.searching then
        return
    end

    browser.searching = false
    browser.cursor = 1
    browser_render()
end


local function browser_search_cancel()
    if not browser.searching then
        return
    end

    browser.searching = false
    browser.search_query = ""
    browser.cursor = 1
    browser_render()
end


----------------------------------------------------------------------
-- Folder navigation
----------------------------------------------------------------------

local function browser_back()
    if browser.searching then
        browser_search_cancel()
        return
    end

    if not browser.open or browser.loading then
        return
    end

    local previous = table.remove(browser.history)

    if previous then
        scan_folder_and_open_browser(previous, true)
        return
    end

    local parent = folder_parent(browser.current_folder_url)

    if parent
        and not same_url(parent, browser.current_folder_url)
        and not same_url(parent, browser.root_url)
    then
        scan_folder_and_open_browser(parent, true)
        return
    end

    osd("Already at the WebDAV root.", 2)
end


----------------------------------------------------------------------
-- Key bindings
----------------------------------------------------------------------

local function browser_bind_keys()
    browser_unbind_keys()

    mp.add_forced_key_binding("UP", "webdav-browser-up", function()
        if not browser.searching then
            browser_move(-1)
        end
    end)

    mp.add_forced_key_binding("DOWN", "webdav-browser-down", function()
        if not browser.searching then
            browser_move(1)
        end
    end)

    mp.add_forced_key_binding("PGUP", "webdav-browser-page-up", function()
        if not browser.searching then
            browser_move(-10)
        end
    end)

    mp.add_forced_key_binding("PGDWN", "webdav-browser-page-down", function()
        if not browser.searching then
            browser_move(10)
        end
    end)

    mp.add_forced_key_binding("HOME", "webdav-browser-home", function()
        if not browser.searching then
            browser.cursor = 1
            browser_render()
        end
    end)

    mp.add_forced_key_binding("END", "webdav-browser-end", function()
        if browser.searching then
            return
        end

        local list = browser_current_list()
        local filtered = browser_filtered_indices(list)

        browser.cursor = math.max(1, #filtered)
        browser_render()
    end)

    mp.add_forced_key_binding("ENTER", "webdav-browser-play", function()
        if browser.searching then
            browser_search_confirm()
        else
            browser_play_or_open()
        end
    end)

    mp.add_forced_key_binding(
        "SHIFT+ENTER",
        "webdav-browser-add",
        browser_add_current_or_selected
    )

    mp.add_forced_key_binding(
        "SPACE",
        "webdav-browser-select",
        browser_toggle_selected
    )

    mp.add_forced_key_binding(
        "a",
        "webdav-browser-add-selected",
        browser_add_selected
    )

    mp.add_forced_key_binding("BACKSPACE", "webdav-browser-back", browser_back)
    mp.add_forced_key_binding("LEFT", "webdav-browser-back", browser_back)

    mp.add_forced_key_binding("r", "webdav-browser-rescan", function()
        if browser.loading then
            return
        end

        if browser.mode == "folders" then
            scan_folder_and_open_browser(
                browser.current_folder_url,
                true
            )
        else
            scan_and_append(true)
        end
    end)

    mp.add_forced_key_binding("ESC", "webdav-browser-close", function()
        if browser.searching then
            browser_search_cancel()
        else
            browser_close()
        end
    end)

    mp.add_forced_key_binding(
        "ALT+m",
        "webdav-browser-toggle-mode",
        function()
            if browser.searching or browser.loading then
                return
            end

            if browser.mode == "files" then
                browser.mode = "folders"

                scan_folder_and_open_browser(
                    browser.current_folder_url
                        or normalize_folder_url(o.url),
                    true
                )
            else
                browser.mode = "files"
                scan_and_append(true)
            end
        end
    )

    mp.add_forced_key_binding(
        "ALT+s",
        "webdav-browser-search",
        function()
            if browser.open then
                browser_start_search()
            end
        end
    )

    local letters = "abcdefghijklmnopqrstuvwxyz0123456789-_. "

    for index = 1, #letters do
        local character = letters:sub(index, index)

        mp.add_forced_key_binding(
            character,
            "webdav-browser-search-char-" .. character,
            function()
                if browser.searching then
                    browser_search_append(character)
                end
            end
        )
    end

    mp.add_forced_key_binding(
        "BS",
        "webdav-browser-search-backspace",
        browser_search_backspace
    )

    mp.add_forced_key_binding(
        "CTRL+BS",
        "webdav-browser-search-clear",
        browser_search_clear
    )
end


----------------------------------------------------------------------
-- Folder scan
----------------------------------------------------------------------

local function scan_folder_only(url, callback)
    propfind_async(url, function(ok, xml, http_code, err)
        if not ok then
            callback(false, nil, nil, err)
            return
        end

        if http_code and http_code ~= "207" then
            callback(false, nil, nil, "HTTP " .. http_code)
            return
        end

        if not xml or xml == "" then
            callback(false, nil, nil, "empty response")
            return
        end

        local entries = parse_multistatus(xml)
        local files = {}
        local folders = {}

        local base_path =
            url:gsub("^https?://[^/]+", "")

        local base_norm =
            base_path:gsub("/+$", "")

        for _, entry in ipairs(entries) do
            local full = url_join(url, entry.href)

            local this_path =
                full:gsub("^https?://[^/]+", "")

            local this_norm =
                this_path:gsub("/+$", "")

            if this_norm ~= base_norm then
                if entry.is_dir then
                    full = normalize_folder_url(full)
                    folders[#folders + 1] = full
                else
                    local extension = get_extension(full)

                    if next(ext_set) == nil or ext_set[extension] then
                        files[#files + 1] = full
                    end
                end
            end
        end

        callback(true, files, folders, nil)
    end)
end


scan_folder_and_open_browser = function(folder_url, from_history)
    folder_url = normalize_folder_url(folder_url)

    if not folder_url then
        osd("Invalid folder URL.", 4)
        return
    end

    if o.pass == "" or o.user == "your-email@example.com" then
        osd(
            "Set 'user' and 'pass' in script-opts/mpv-webdav-loader.conf",
            6
        )
        return
    end

    if browser.open
        and browser.current_folder_url
        and not from_history
        and not same_url(
            browser.current_folder_url,
            folder_url
        )
    then
        browser.history[#browser.history + 1] =
            browser.current_folder_url
    end

    browser.loading = true
    osd("Scanning folder: " .. folder_url .. " ...", 4)

    scan_folder_only(folder_url, function(ok, files, folders, err)
        browser.loading = false

        if not ok then
            osd("Folder scan error: " .. tostring(err), 7)
            msg.error("Folder scan error: " .. tostring(err))
            return
        end

        table.sort(files, function(a, b)
            return filename_from_url(a):lower()
                < filename_from_url(b):lower()
        end)

        table.sort(folders, function(a, b)
            return filename_from_url(a):lower()
                < filename_from_url(b):lower()
        end)

        browser.files = files
        browser.folders = folders
        browser.current_folder_url = folder_url
        browser.root_url = browser.root_url or folder_url
        browser.mode = "folders"
        browser.cursor = 1
        browser.scan_errors = {}
        browser.search_query = ""
        browser.searching = false
        browser.open = true

        -- Important:
        -- Do not clear browser.selected or browser.added here.
        -- They are keyed by URL and remain valid across folders and modes.

        browser_bind_keys()
        browser_render()

        msg.info(
            ("Folder scan done: %d files, %d folders")
                :format(#files, #folders)
        )
    end)
end


----------------------------------------------------------------------
-- Recursive file scan
----------------------------------------------------------------------

local scanning = false

local function crawl(url, depth, collected, pending, errors, final_callback)
    pending.count = pending.count + 1

    propfind_async(url, function(ok, xml, http_code, err)
        pending.count = pending.count - 1

        if not ok then
            errors[#errors + 1] =
                url .. " -> " .. tostring(err)

        elseif http_code and http_code ~= "207" then
            errors[#errors + 1] =
                url .. " -> HTTP " .. tostring(http_code)

        elseif xml then
            local entries = parse_multistatus(xml)

            local base_path =
                url:gsub("^https?://[^/]+", "")

            local base_norm =
                base_path:gsub("/+$", "")

            for _, entry in ipairs(entries) do
                local full = url_join(url, entry.href)

                local this_path =
                    full:gsub("^https?://[^/]+", "")

                local this_norm =
                    this_path:gsub("/+$", "")

                if this_norm ~= base_norm then
                    if entry.is_dir then
                        if depth < tonumber(o.max_depth) then
                            crawl(
                                normalize_folder_url(full),
                                depth + 1,
                                collected,
                                pending,
                                errors,
                                final_callback
                            )
                        end
                    else
                        local extension = get_extension(full)

                        if next(ext_set) == nil
                            or ext_set[extension]
                        then
                            collected[#collected + 1] = full
                        end
                    end
                end
            end
        end

        if pending.count == 0 then
            final_callback(collected, errors)
        end
    end)
end


scan_and_append = function(preserve_state)
    if scanning then
        osd("WebDAV scan already running.", 3)
        return
    end

    if o.pass == "" or o.user == "your-email@example.com" then
        osd(
            "Set 'user' and 'pass' in script-opts/mpv-webdav-loader.conf",
            6
        )
        return
    end

    scanning = true
    browser.loading = true

    osd("Scanning WebDAV: " .. o.url .. " ...", 4)

    local root = normalize_folder_url(o.url)
    local collected = {}
    local pending = { count = 0 }
    local errors = {}

    crawl(
        root,
        0,
        collected,
        pending,
        errors,
        function(files, scan_errors)
            scanning = false
            browser.loading = false

            if #files == 0 then
                local text = "No media files found."

                if #scan_errors > 0 then
                    text = text .. " Error: " .. scan_errors[1]
                end

                osd(text, 7)
                msg.error(text)

                for _, scan_error in ipairs(scan_errors) do
                    msg.error(scan_error)
                end

                return
            end

            table.sort(files, function(a, b)
                return filename_from_url(a):lower()
                    < filename_from_url(b):lower()
            end)

            browser.files = files
            browser.folders = {}
            browser.current_folder_url = root
            browser.root_url = root
            browser.mode = "files"
            browser.cursor = 1
            browser.scan_errors = scan_errors or {}
            browser.search_query = ""
            browser.searching = false
            browser.open = true

            if not preserve_state then
                browser.selected = {}
                browser.added = {}
                browser.history = {}
            end

            browser_bind_keys()
            browser_render()

            msg.info(
                ("Found %d files from %s")
                    :format(#files, root)
            )
        end
    )
end


----------------------------------------------------------------------
-- Script entry points
----------------------------------------------------------------------

mp.add_key_binding(o.key, "webdav-scan-append", function()
    scan_and_append(false)
end)

mp.register_script_message("rescan", function()
    scan_and_append(false)
end)

msg.info(
    "mpv-webdav-loader loaded. Press '" .. o.key .. "' to open WebDAV browser."
)