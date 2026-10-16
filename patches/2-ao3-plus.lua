-- Ao3 Plus for KOReader detailed lists and Bookshelf.
--
-- Install this file in KOReader's patches directory and the PNGs in its
-- sibling icons directory. Bookshelf integration uses its public placeholder
-- and custom-token APIs, plus a guarded top-panel tap hook.

local source = debug.getinfo(1, "S").source
local patch_dir = source:sub(1, 1) == "@"
    and source:sub(2):match("^(.*)/[^/]+$") or "."
local asset_dir = patch_dir .. "/../icons/"

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local BD = require("ui/bidi")
local DocSettings = require("docsettings")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local logger = require("logger")
local MAX_TAGS = 15
local MAX_TAGS_LIMIT = 50
local LIST_TEXT_MARGIN = Screen:scaleBySize(4)
local MIN_TEXT_WIDTH = Screen:scaleBySize(20)
local ROW_TOP_PADDING = Screen:scaleBySize(10)
local ROW_BOTTOM_PADDING = Screen:scaleBySize(4)
local ROW_RIGHT_INSET = Screen:scaleBySize(18)
local LIST_ICON_DP = 25
local PANEL_ICON_DP = 40
local CACHE_PRUNE_KEY = "_ao3_plus_last_cache_prune"
local CACHE_PRUNE_INTERVAL = 30 * 24 * 60 * 60
local METADATA_CACHE_PRUNE_KEY = "_ao3_plus_last_metadata_cache_prune"

local RATING = {
    ["general audiences"] = "rating-general-audience",
    ["teen and up audiences"] = "rating-teen",
    ["mature"] = "rating-mature",
    ["explicit"] = "rating-explicit",
    ["not rated"] = "rating-notrated",
}

local CATEGORY = {
    ["f/m"] = "category-het",
    ["m/f"] = "category-het",
    ["het"] = "category-het",
    ["m/m"] = "category-slash",
    ["slash"] = "category-slash",
    ["f/f"] = "category-femslash",
    ["femslash"] = "category-femslash",
    ["gen"] = "category-gen",
    ["multi"] = "category-multi",
    ["other"] = "category-other",
    ["none"] = "category-none",
}

local COMPLETE_YES = {
    yes = true, complete = true, completed = true,
    ["complete work"] = true, finished = true,
}

local COMPLETE_NO = {
    no = true, ["in progress"] = true, ["in-progress"] = true,
    incomplete = true, ["work in progress"] = true, wip = true,
    ongoing = true, hiatus = true,
}

-- AO3 metadata helpers

-- BookInfoManager exposes tags in the same order in which Ao3 writes them:
-- wrapper/rating, fandom, then category and warning tags.
local function normalize(value)
    if type(value) ~= "string" then return nil end
    local normalized = value:lower():match("^%s*(.-)%s*$")
    normalized = normalized:gsub("^archive warnings?:%s*", "")
    normalized = normalized:gsub("^warnings?:%s*", "")
    normalized = normalized:gsub("^rating:%s*", "")
    normalized = normalized:gsub("^category:%s*", "")
    normalized = normalized:gsub("^complete:%s*", "")
    normalized = normalized:gsub("^completion status:%s*", "")
    normalized = normalized:gsub("^status:%s*", "")
    return normalized
end

local function collect_tags(book)
    local tags = {}
    if type(book) ~= "table" then return tags end

    local function append(source)
        if type(source) == "string" then
            for tag in source:gmatch("[^,\n]+") do
                tags[#tags + 1] = tag:match("^%s*(.-)%s*$")
            end
        elseif type(source) == "table" then
            for _, tag in ipairs(source) do
                if type(tag) == "string" then
                    tags[#tags + 1] = tag:match("^%s*(.-)%s*$")
                end
            end
        end
    end

    append(book.genres)
    append(book.keywords)
    return tags
end

local function fandom_from_tags(tags)
    local index = 1
    local first = normalize(tags[index])
    if first == "fanworks" then
        index = index + 1
    elseif not RATING[first] then
        return nil, nil
    end
    if RATING[normalize(tags[index])] then
        index = index + 1
    end
    return tags[index], index
end

local function metadata_tags_for_book(book)
    -- Bookshelf splits pipe-separated genres before handing them to
    -- placeholders and tokens. Read the original BookInfoManager record when
    -- possible so a multilingual fandom such as "A | B | C" remains one tag.
    local filepath = type(book) == "table" and book.filepath
    if type(filepath) == "string" then
        local ok_manager, manager = pcall(require, "bookinfomanager")
        if ok_manager and manager then
            local ok_info, info = pcall(
                manager.getBookInfo, manager, filepath, false)
            if ok_info and type(info) == "table" then
                local tags = collect_tags(info)
                if fandom_from_tags(tags) then return tags end
            elseif not ok_info then
                logger.warn("[ao3 plus] fandom metadata read failed:",
                    filepath, info)
            end
        elseif not ok_manager then
            logger.warn("[ao3 plus] BookInfoManager unavailable:", manager)
        end
    end
    return collect_tags(book)
end

local function fandom_for_book(book)
    return (fandom_from_tags(metadata_tags_for_book(book)))
end

local function is_archive_warning(value)
    return value and (value:find("archive warnings", 1, true)
        or value == "graphic depictions of violence"
        or value == "major character death"
        or value == "rape/non-con"
        or value == "underage")
end

-- Reduces a raw Ao3 subject list to the tags actually worth a row.
--
-- Ao3 exports its subjects in a fixed order: the "Fanworks" wrapper, the
-- rating, the fandom, the relationship category, then the freeform tags.
-- Everything up to and including the fandom is already on screen as badges
-- and the fandom line, and the category is a badge too, so all of it is
-- dropped. The archive warnings collapse to a single entry which then takes
-- the first slot outright rather than being inserted, so the line keeps
-- exactly the length the tag limit asked for.
local function filtered_tags(tags, limit)
    local _, fandom_index = fandom_from_tags(tags)
    fandom_index = fandom_index or 1
    local kept, warning = {}, nil
    for index = fandom_index + 1, #tags do
        local value = normalize(tags[index])
        if CATEGORY[value] then
            -- Omit Ao3 relationship category tags; a badge shows them.
        elseif is_archive_warning(value) then
            warning = warning or tags[index]
        elseif not limit or #kept < limit then
            kept[#kept + 1] = tags[index]
        end
    end
    if warning then
        kept[1] = warning
    end
    return kept
end

local function fit_tag_text(tags, limit, max_height, measure)
    for count = math.min(#tags, limit), 0, -1 do
        local text = table.concat(tags, ", ", 1, count)
        local hidden = #tags - count
        if hidden > 0 then
            local more = string.format(_("+%d more"), hidden)
            text = count > 0 and (text .. ", " .. more) or more
        end
        local height = measure(text)
        if height <= max_height then
            return text, height
        end
    end
end

local function completion_from_chapter_text(text)
    if type(text) ~= "string" then return nil end
    local have, total = text:lower():match(
        "chapters:%s*(%d+)%s*/%s*([%d%?]+)")
    if not have then return nil end
    if total == "?" or tonumber(have) ~= tonumber(total) then
        return "complete-no"
    end
    return "complete-yes"
end

local function completion_from_status_text(book)
    local text = type(book) == "table" and book.description
    if type(text) ~= "string" then return nil end
    local normalized_text = text:lower()
    if normalized_text:match("status:%s*completed") then
        return "complete-yes"
    end
    if normalized_text:match("status:%s*in%-progress") then
        return "complete-no"
    end
    return nil
end

local status_store
local metadata_store

-- Completion and metadata cache

-- The status cache is kept separate for compatibility with earlier Ao3 Plus
-- releases. The metadata cache carries the richer word/chapter fields used by
-- the list row and Bookshelf tokens; both stores are pruned by file path.
local function prune_cache_store(store, force, prune_key)
    if type(store) ~= "table" or type(store.data) ~= "table" then
        return nil
    end
    local now = os.time()
    prune_key = prune_key or CACHE_PRUNE_KEY
    local last_pruned = store:readSetting(prune_key)
    if not force and type(last_pruned) == "number"
            and last_pruned > now - CACHE_PRUNE_INTERVAL then
        return 0
    end

    local removed = 0
    for filepath, verdict in pairs(store.data) do
        local is_metadata = type(verdict) == "table"
            and (type(verdict.chapters) == "string"
                or type(verdict.wordcount) == "string"
                or verdict.status == "yes"
                or verdict.status == "no"
                or verdict.status == "none")
        if filepath ~= prune_key
                and (verdict == "yes" or verdict == "no" or verdict == "none"
                    or is_metadata)
                and type(filepath) == "string"
                and lfs.attributes(filepath, "mode") ~= "file" then
            store:delSetting(filepath)
            removed = removed + 1
        end
    end
    store:saveSetting(prune_key, now)
    local ok, err = pcall(function() store:flush() end)
    if not ok then
        logger.warn("[ao3 plus] cache cleanup failed:", err)
        return nil
    end
    if removed > 0 then
        logger.info("[ao3 plus] removed", removed,
            "stale cache entries")
    end
    return removed
end

local function get_status_store()
    if status_store ~= nil then return status_store end
    local ok, store = pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        return LuaSettings:open(
            DataStorage:getSettingsDir() .. "/bookshelf_ao3_status_v2.lua")
    end)
    status_store = ok and store or false
    if status_store then
        prune_cache_store(status_store, false)
    end
    return status_store
end

local function get_metadata_store()
    if metadata_store ~= nil then return metadata_store end
    local ok, store = pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        return LuaSettings:open(
            DataStorage:getSettingsDir() .. "/ao3_plus_metadata_v1.lua")
    end)
    metadata_store = ok and store or false
    if metadata_store then
        prune_cache_store(metadata_store, false, METADATA_CACHE_PRUNE_KEY)
    end
    return metadata_store
end

local function clean_cache_stores()
    local store = get_status_store()
    if not store then return nil end
    local removed = prune_cache_store(store, true) or 0
    local metadata = get_metadata_store()
    if metadata then
        removed = removed
            + (prune_cache_store(metadata, true, METADATA_CACHE_PRUNE_KEY) or 0)
    end
    return removed
end

local function save_metadata_cache(store, filepath, metadata)
    if not store then return end
    store:saveSetting(filepath, metadata)
    local ok, err = pcall(function() store:flush() end)
    if not ok then
        logger.warn("[ao3 plus] metadata cache save failed:", err)
    end
end

local function save_status_cache(store, filepath, status)
    if not store then return end
    store:saveSetting(filepath, status)
    local ok, err = pcall(function() store:flush() end)
    if not ok then
        logger.warn("[ao3 plus] completion cache save failed:", err)
    end
end

local function empty_metadata()
    return {
        status = "none",
        chapters = nil,
        wordcount = nil,
    }
end

local function scan_epub_metadata(filepath)
    -- Ao3 normally places these fields in the first HTML chapter pages. A
    -- short bounded scan avoids reading an entire EPUB on every list refresh,
    -- while still handling downloads with a cover or front matter first.
    local reader
    local ok, result = pcall(function()
        local Archiver = require("ffi/archiver")
        reader = Archiver.Reader:new()
        if not reader:open(filepath) then
            logger.warn("[ao3 plus] could not open EPUB metadata:", filepath)
            return empty_metadata()
        end
        local names = {}
        for entry in reader:iterate() do
            if entry.path and entry.path:lower():match("%.x?html?$") then
                names[#names + 1] = entry.path
            end
        end
        table.sort(names)
        local metadata = empty_metadata()
        for i = 1, math.min(#names, 4) do
            local page = reader:extractToMemory(names[i])
            if page then
                local have, total = page:match(
                    "Chapters:%s*(%d+)%s*/%s*([%d%?]+)")
                if have then
                    metadata.chapters = have .. "/" .. total
                    metadata.status =
                        total ~= "?" and tonumber(have) == tonumber(total)
                        and "yes" or "no"
                end
                local words = page:match("Words:%s*([%d,]+)")
                if words then
                    metadata.wordcount = words
                end
                if metadata.chapters and metadata.wordcount then
                    break
                end
            end
        end
        return metadata
    end)
    if reader then
        local close_ok, close_err = pcall(reader.close, reader)
        if not close_ok then
            logger.warn("[ao3 plus] EPUB metadata close failed:", close_err)
        end
    end
    if not ok then
        logger.warn("[ao3 plus] EPUB metadata scan failed:", filepath, result)
        return empty_metadata()
    end
    return result
end

local function scan_and_cache_metadata(filepath)
    -- Completion badges and Bookshelf tokens need the same EPUB fields.
    -- Populate both stores from one archive scan so whichever path runs first
    -- prevents the other from reopening the EPUB.
    local metadata = scan_epub_metadata(filepath)
    save_metadata_cache(get_metadata_store(), filepath, metadata)
    save_status_cache(get_status_store(), filepath, metadata.status)
    return metadata
end

local function completion_from_file(book, filepath_override)
    local filepath = filepath_override
        or (type(book) == "table" and book.filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end
    local store = get_status_store()
    local cached = store and store:readSetting(filepath)
    if cached == nil then
        local metadata_store_ref = get_metadata_store()
        local metadata = metadata_store_ref
            and metadata_store_ref:readSetting(filepath)
        if type(metadata) ~= "table" then
            metadata = scan_and_cache_metadata(filepath)
        else
            save_status_cache(store, filepath, metadata.status)
        end
        cached = metadata.status
    end
    if cached == "yes" then return "complete-yes" end
    if cached == "no" then return "complete-no" end
    return nil
end

local function metadata_from_file(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end
    local store = get_metadata_store()
    local cached = store and store:readSetting(filepath)
    if type(cached) == "table" then return cached end

    return scan_and_cache_metadata(filepath)
end

local function icons_for(book, filepath)
    local found = {}
    local chapter_completion = completion_from_chapter_text(
        type(book) == "table" and book.description)
    local tags = collect_tags(book)
    if #tags == 0 then
        found.complete = chapter_completion
            or completion_from_status_text(book)
            or completion_from_file(book, filepath)
        return found
    end

    -- Badge widgets use the first matching rating/category and the strongest
    -- matching warning. Completion prefers an explicit chapter count, then
    -- falls back to tags, description text, and finally the EPUB scan.

    local warning_yes, warning_external, warning_no, warning_choose_not_to
    for _, tag in ipairs(tags) do
        local value = normalize(tag)
        if value then
            found.rating = found.rating or RATING[value]
            found.category = found.category or CATEGORY[value]
            if value == "no archive warnings apply" then
                warning_no = true
            elseif value == "creator chose not to use archive warnings"
                    or value == "choose not to use archive warnings" then
                warning_choose_not_to = true
            elseif value == "external work" then
                warning_external = true
            elseif value == "graphic depictions of violence"
                    or value == "major character death"
                    or value == "rape/non-con"
                    or value == "underage" then
                warning_yes = true
            end
            local done_tag = value:match("^complete work:%s*(.+)$") or value
            if not chapter_completion and (COMPLETE_YES[done_tag]
                    or (done_tag:find("complete", 1, true)
                    and not done_tag:find("incomplete", 1, true)
                    and not done_tag:find("not complete", 1, true))) then
                found.complete = "complete-yes"
            elseif not chapter_completion and (COMPLETE_NO[done_tag]
                    or done_tag:find("in progress", 1, true)
                    or done_tag:find("incomplete", 1, true)
                    or done_tag:find("not complete", 1, true)) then
                if found.complete ~= "complete-yes" then
                    found.complete = "complete-no"
                end
            end
        end
    end
    if chapter_completion then
        found.complete = chapter_completion
    elseif not found.complete then
        found.complete = completion_from_status_text(book)
            or completion_from_file(book, filepath)
    end
    if warning_yes then
        found.warning = "warning-yes"
    elseif warning_choose_not_to then
        found.warning = "warning-choosenotto"
    elseif warning_no then
        found.warning = "warning-no"
    elseif warning_external then
        found.warning = "warning-external-work"
    end
    return found
end

local image_cache = {}
local function icon_cell(name, side, border)
    local icon_side = side - 2 * border
    local image
    if name then
        local path = asset_dir .. name .. ".png"
        local key = path .. "|" .. tostring(icon_side)
        image = image_cache[key]
        if image == nil then
            local ok, decoded = pcall(RenderImage.renderImageFile, RenderImage,
                                      path, false, icon_side, icon_side)
            if ok and decoded then
                image = decoded
                image_cache[key] = image
            else
                logger.warn("[ao3 plus] failed to load", path, decoded)
                -- Remember failures too; otherwise every repaint retries the
                -- same missing or invalid asset.
                image_cache[key] = false
            end
        end
    end
    local content = image
        and ImageWidget:new{ image = image, image_disposable = false }
        or Widget:new{ dimen = Geom:new{ w = icon_side, h = icon_side } }
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
        margin = 0,
        content,
    }
end

local PANEL_SELECT_PAD_DP = 5
local PANEL_SELECT_RADIUS_DP = 4

-- Top-panel badges. When selected, a light grey rounded area is painted
-- behind the grid, standing in for Bookshelf's selected-cover state.
local PanelBadges = Widget:extend{
    grid = nil,
    pad = 0,
    selected = false,
}

function PanelBadges:getSize()
    return self.dimen
end

function PanelBadges:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.selected then
        bb:paintRoundedRect(x, y, self.dimen.w, self.dimen.h,
            Blitbuffer.COLOR_GRAY_D, Screen:scaleBySize(PANEL_SELECT_RADIUS_DP))
    end
    self.grid:paintTo(bb, x + self.pad, y + self.pad)
end

function PanelBadges:free()
    if self.grid and self.grid.free then self.grid:free() end
end

local function badge_widget(book, width, height, ctx, filepath)
    if type(width) ~= "number" or type(height) ~= "number"
            or width < 1 or height < 1 then
        return nil
    end
    local icons = icons_for(book, filepath)
    if not next(icons) then return nil end

    local border = Size.border.thin
    local gap = math.max(2, Screen:scaleBySize(2))
    local panel = ctx and ctx.panel
    local large_panel = panel
        and G_reader_settings:readSetting("ao3_plus_small_panel_badges") == false
    -- The top panel shrinks its cover column to the badge widget's natural
    -- width, so the grid width (plus the selected area's padding) sets where
    -- the panel text starts. The icon step is 4px of width, so the gap takes
    -- up the remainder.
    if large_panel then gap = gap + 2 * border end
    local inset = (panel and 0)
        or (ctx and (not ctx.bare or ctx.top_left))
        and math.min(ctx.left_margin or Screen:scaleBySize(8),
            math.floor(math.min(width, height) / 4))
        or 0
    local available_width = width - 2 * inset
    local available_height = height - 2 * inset
    local side = math.min(
        math.floor(available_width / 2), math.floor(available_height / 2),
        Screen:scaleBySize(large_panel and PANEL_ICON_DP or LIST_ICON_DP)
            + 2 * border)
    side = math.floor(math.min(side,
        (math.min(available_width, available_height) - gap) / 2))
    if side <= 2 * border then return nil end

    local top = HorizontalGroup:new{ align = "center" }
    top[#top + 1] = icon_cell(icons.rating, side, border)
    top[#top + 1] = HorizontalSpan:new{ width = gap }
    top[#top + 1] = icon_cell(icons.category, side, border)
    local bottom = HorizontalGroup:new{ align = "center" }
    bottom[#bottom + 1] = icon_cell(icons.warning, side, border)
    bottom[#bottom + 1] = HorizontalSpan:new{ width = gap }
    bottom[#bottom + 1] = icon_cell(icons.complete, side, border)
    local grid = VerticalGroup:new{
        align = "center", top, VerticalSpan:new{ width = gap }, bottom,
    }
    if panel then
        -- Bookshelf shrinks the panel's cover column to this widget's width,
        -- so it stays just wider than the grid. Its full height keeps the
        -- column tappable below KOReader's top menu strip.
        local grid_size = grid:getSize()
        local pad = math.max(0, math.min(Screen:scaleBySize(PANEL_SELECT_PAD_DP),
            math.floor((width - grid_size.w) / 2),
            height - grid_size.h))
        return PanelBadges:new{
            grid = grid,
            pad = pad,
            dimen = Geom:new{ w = grid_size.w + 2 * pad, h = height },
        }
    end
    if inset > 0 then
        local padded_grid = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = inset },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = inset },
                grid,
            },
        }
        local inset_widget = TopContainer:new{
            dimen = Geom:new{ w = width, h = height },
            LeftContainer:new{
                dimen = Geom:new{
                    w = width,
                    h = inset + 2 * side + gap,
                },
                padded_grid,
            },
        }
        -- Flags this as badge iconography rather than cover artwork, so
        -- Bookshelf's opening-book squeeze/flex (which distorts whatever is
        -- in the cover slot) can be skipped for it -- see
        -- install_open_effect_guard.
        inset_widget.ao3_plus_placeholder = true
        return inset_widget
    end
    local centered_widget = CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        grid,
    }
    centered_widget.ao3_plus_placeholder = true
    return centered_widget
end

local userpatch = require("userpatch")

local FONT_DEFAULTS = {
    title = { path = "./fonts/noto/NotoSans-Bold.ttf", size = 18 },
    authors = { path = "./fonts/noto/NotoSerif-Italic.ttf", size = 13 },
    fandom = { path = "./fonts/noto/NotoSans-Regular.ttf", size = 10 },
    tags = { path = nil, size = 12 },
    description = { path = "./fonts/noto/NotoSans-Regular.ttf", size = 13 },
    stats = { path = "./fonts/noto/NotoSans-Bold.ttf", size = 12 },
}

local function configured_face(prefix, fallback, default_delta)
    -- Font choices are stored by BookInfoManager because Bookshelf and
    -- CoverBrowser share that settings namespace.
    local BookInfoManager = require("bookinfomanager")
    local defaults = FONT_DEFAULTS[prefix] or {}
    local path = BookInfoManager:getSetting("list_font_" .. prefix .. "_path")
        or defaults.path
    local size = BookInfoManager:getSetting("list_font_" .. prefix .. "_size")
        or defaults.size
    local faceindex = BookInfoManager:getSetting(
        "list_font_" .. prefix .. "_faceindex")
    local base_path = path or (fallback and fallback.ftname)
    if not path and size == nil and faceindex == nil then
        if default_delta == 0 then return fallback end
        local base_size = fallback and fallback.orig_size or 14
        return Font:getFace(base_path or "cfont",
            math.max(8, base_size + default_delta))
    end
    local base_size = fallback and fallback.orig_size or 14
    return Font:getFace(base_path or "cfont", size or base_size + default_delta,
        faceindex)
end

local function display_enabled(name)
    return G_reader_settings:readSetting("ao3_plus_hide_" .. name) ~= true
end

local function max_displayed_tags()
    local value = G_reader_settings:readSetting("ao3_plus_max_tags")
    if type(value) ~= "number" then return MAX_TAGS end
    return math.max(1, math.min(MAX_TAGS_LIMIT, math.floor(value)))
end

local function reset_list_font_defaults(BookInfoManager, prefix)
    local defaults = FONT_DEFAULTS[prefix]
    if not defaults then return end
    for _, suffix in ipairs{"path", "faceindex", "size", "bold", "italic"} do
        BookInfoManager:saveSetting(
            "list_font_" .. prefix .. "_" .. suffix, defaults[suffix])
    end
end

local function read_percent(entry)
    if not entry then return nil end
    local percent = entry.percent_finished
    local path = entry.path or entry.file
    if not percent and path and DocSettings:hasSidecarFile(path) then
        local settings = DocSettings:open(path)
        percent = settings:readSetting("percent_finished")
        if not percent then
            local summary = settings:readSetting("summary")
            percent = summary and summary.percent
        end
    end
    if not percent then return nil end
    if percent <= 1 then percent = percent * 100 end
    return math.max(0, math.min(100, percent))
end

local function progress_bar(percent)
    -- Progress is painted after KOReader's row group so it can use the full
    -- right edge without changing the row's measured text width.
    local bar_width = Screen:scaleBySize(100)
    local bar_height = Screen:scaleBySize(5)
    local gap = Screen:scaleBySize(4)
    -- The percentage shares the "stats" font with the words/chapters text so
    -- both halves of that bottom row stay visually matched.
    local face = configured_face("stats", Font:getFace("cfont", 11), 0)
    if percent >= 100 then
        return TextWidget:new{
            text = "✓ Finished",
            face = face,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    local label = TextWidget:new{
        text = string.format("%d%%", math.floor(percent + .5)),
        face = face,
        alignment = "left",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local reference_label = TextWidget:new{
        text = "100%",
        face = face,
        alignment = "left",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_size = label:getSize()
    local label_area_width = reference_label:getSize().w
    reference_label:free()
    local height = math.max(bar_height, label_size.h)
    local width = bar_width + gap + label_area_width
    local progress_width = math.floor(bar_width * percent / 100)
    local bar = Widget:new{ dimen = Geom:new{ w = width, h = height } }
    function bar:paintTo(bb, x, y)
        local bar_y = y + math.floor((height - bar_height) / 2)
            + Screen:scaleBySize(2)
        bb:paintRect(x, bar_y, bar_width, bar_height,
            Blitbuffer.COLOR_LIGHT_GRAY)
        if progress_width > 0 then
            bb:paintRect(x, bar_y, progress_width, bar_height,
                Blitbuffer.COLOR_GRAY_5)
        end
        local size = label:getSize()
        label:paintTo(bb, x + bar_width + gap
            + label_area_width - size.w,
            y + math.floor((height - size.h) / 2))
    end
    function bar:free()
        label:free()
    end
    return bar
end

local function install_panel_tap()
    -- Match Bookshelf's own tap feedback (_paintOpeningEffect): paint the
    -- grey selected state straight onto the framebuffer and force an
    -- immediate hardware refresh so it is visible for one frame, then hand
    -- off to Bookshelf's normal tap action in the same call -- no timer.
    local HeroCard = package.loaded["lib/bookshelf_hero_card"]
    if not HeroCard then
        local ok, module = pcall(require, "lib/bookshelf_hero_card")
        HeroCard = ok and module or nil
    end
    if type(HeroCard) ~= "table" or type(HeroCard.init) ~= "function"
            or HeroCard.ao3_panel_tap_patched then
        return
    end
    HeroCard.ao3_panel_tap_patched = true
    local original_init = HeroCard.init
    function HeroCard:init(...)
        original_init(self, ...)
        local ok, err = pcall(function()
            local fp = self.book and self.book.filepath
            local spine = self._cover_spine
            local card = spine and spine._cover_card
            local badges = card and card[1]
            if getmetatable(badges) ~= PanelBadges then return end
            if not (fp and self.on_tap) then return end
            -- Bookshelf's opening animation flexes this widget; badges are
            -- not cover artwork, so the selected state replaces it.
            self._cover_spine = nil
            -- The grey area replaces Bookshelf's square selection ring.
            local SpineWidget = package.loaded["lib/bookshelf_spine_widget"]
            local ring = SpineWidget and SpineWidget.BorderOverlay
            local layers = spine[1]
            if ring and type(layers) == "table" then
                for i = #layers, 1, -1 do
                    if getmetatable(layers[i]) == ring then
                        table.remove(layers, i)
                    end
                end
            end
            local hero = self
            function spine:onTap(_, ges)
                if ges and ges.pos and ges.pos.y < Screen:scaleBySize(60) then
                    return false
                end
                badges.selected = true
                local rect = badges.dimen
                if rect and rect.x and Screen.bb then
                    badges:paintTo(Screen.bb, rect.x, rect.y)
                    pcall(function()
                        Screen:refreshUI(rect.x, rect.y, rect.w, rect.h)
                    end)
                end
                badges.selected = false
                hero.on_tap(hero.book)
                return true
            end
        end)
        if not ok then
            logger.warn("[ao3 plus] top panel tap unavailable:", err)
        end
    end
end

-- Grid, shelf and list covers record the tapped SpineWidget in the shared
-- SpineWidget.last_tapped rendezvous (several call sites across Bookshelf),
-- then _paintOpeningEffect squeezes or squashes whatever is in that widget's
-- _cover_card as if it were cover artwork. Our badge grid is not artwork --
-- flexing it looked like the grid breaking apart toward the left edge (the
-- list view's squashCoverOpen effect). Consume the rendezvous before
-- Bookshelf's method reads it whenever the tapped cover is one of ours, so
-- the book still opens normally but with no distortion.
local function install_open_effect_guard()
    local BookshelfWidget = package.loaded["lib/bookshelf_widget"]
    if not BookshelfWidget then
        local ok, module = pcall(require, "lib/bookshelf_widget")
        BookshelfWidget = ok and module or nil
    end
    if type(BookshelfWidget) ~= "table"
            or type(BookshelfWidget._paintOpeningEffect) ~= "function"
            or BookshelfWidget.ao3_open_effect_patched then
        return
    end
    BookshelfWidget.ao3_open_effect_patched = true
    local original = BookshelfWidget._paintOpeningEffect
    function BookshelfWidget:_paintOpeningEffect(fp)
        local ok, err = pcall(function()
            local SpineWidget = package.loaded["lib/bookshelf_spine_widget"]
            local spine = SpineWidget and SpineWidget.last_tapped
            local card = spine and spine._cover_card
            local content = card and card[1]
            if content and (content.ao3_plus_placeholder
                    or getmetatable(content) == PanelBadges) then
                SpineWidget.last_tapped = nil
            end
        end)
        if not ok then
            logger.warn("[ao3 plus] opening-effect guard failed:", err)
        end
        return original(self, fp)
    end
end

local function patch_bookshelf(Bookshelf)
    install_open_effect_guard()
    install_panel_tap()
    if type(Bookshelf.registerPlaceholder) == "function" then
        local ok, err = Bookshelf:registerPlaceholder(
            "ao3-list", function(book, width, height, ctx)
                if ctx and ctx.panel then install_panel_tap() end
                local widget = badge_widget(book, width, height, ctx)
                if not widget then return nil end
                return widget, { frame = false }
            end)
        if not ok then
            logger.warn("[ao3 plus] Bookshelf placeholder unavailable:", err)
        end
    end
    if type(Bookshelf.registerTokens) == "function" then
        local ok, err = Bookshelf:registerTokens("Ao3", {
            ao3_words = {
                description = "Ao3 word count",
                expand = function(book)
                    local metadata = metadata_from_file(
                        type(book) == "table" and book.filepath)
                    return metadata and metadata.wordcount or ""
                end,
            },
            ao3_chapters = {
                description = "Ao3 chapter count",
                expand = function(book)
                    local metadata = metadata_from_file(
                        type(book) == "table" and book.filepath)
                    return metadata and metadata.chapters or ""
                end,
            },
            ao3_fandom = {
                description = "Ao3 fandom",
                expand = function(book)
                    return fandom_for_book(book) or ""
                end,
            },
        })
        if not ok then
            logger.warn("[ao3 plus] Bookshelf tokens unavailable:", err)
        end
    end
end

-- Detailed-list integration

local function patch_coverbrowser(plugin)
    -- CoverBrowser does not expose a row-rendering extension point. The patch
    -- captures the row's text group while ListMenuItem.update builds it, then
    -- replaces only coverless Ao3 rows with the richer layout below.
    local ListMenu = require("listmenu")
    local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
    if type(ListMenu._updateItemsBuildUI) ~= "function" then
        logger.warn("[ao3 plus] detailed-list integration unavailable")
        return
    end
    local ListMenuItem = userpatch.getUpValue(
        ListMenu._updateItemsBuildUI, "ListMenuItem")
    if type(ListMenuItem) ~= "table"
            or type(ListMenuItem.update) ~= "function"
            or type(ListMenuItem.paintTo) ~= "function"
            or ListMenuItem.ao3_badges_patched then
        logger.warn("[ao3 plus] compatible ListMenuItem not found")
        return
    end
    ListMenuItem.ao3_badges_patched = true

    local function compact_cover_slot(container, row_height, item)
        -- KOReader reserves a cover-sized first column even for the placeholder
        -- glyph. Shrinking that column is what gives the metadata widgets room
        -- for fandom, tags, and descriptions.
        if type(container) ~= "table" then return false end
        local compacted = false
        local width_delta = 0
        local target_width = Screen:scaleBySize(85)

        local function widen_metadata(widget, amount)
            if type(widget) ~= "table" then return end
            if type(widget.text) == "string" and type(widget.width) == "number" then
                widget.width = widget.width + amount
                if widget.dimen then widget.dimen.w = widget.width end
                if type(widget.updateSize) == "function" then
                    widget:updateSize()
                end
            end
            for index = 1, #widget do
                widen_metadata(widget[index], amount)
            end
        end

        for i = 1, #container do
            local child = container[i]
            if type(child) == "table" then
                local first = child[1]
                local padding = child[2]
                local main = child[3]
                if type(first) == "table" and type(padding) == "table"
                        and type(main) == "table"
                        and type(first.width) == "number"
                        and type(padding.width) == "number"
                        and first.width >= row_height - Screen:scaleBySize(4)
                        and padding.width <= Screen:scaleBySize(20)
                        and first.width > target_width then
                    local old_width = first.width
                    first.width = target_width
                    if first.dimen then first.dimen.w = target_width end
                    if main.dimen then main.dimen.w = main.dimen.w + old_width - target_width end
                    widen_metadata(main, old_width - target_width)
                    if item._underline_container then
                        item._underline_container.line_x_offset =
                            target_width + padding.width
                        item._underline_container.line_width =
                            math.max(item.width
                                - Screen:scaleBySize(6)
                                - item._underline_container.line_x_offset, 0)
                    end
                    compacted = true
                    width_delta = old_width - target_width
                    break
                end
                local child_compacted, child_delta =
                    compact_cover_slot(child, row_height, item)
                if child_compacted then
                    compacted = true
                    width_delta = child_delta
                    break
                end
            end
        end
        return compacted, width_delta
    end

    local original_update = ListMenuItem.update
    local original_paint_to = ListMenuItem.paintTo
    local original_free = ListMenuItem.free
    function ListMenuItem:update(...)
        local captured
        local original_vertical_new = VerticalGroup.new
        VerticalGroup.new = function(klass, children, ...)
            -- The first wide text group is the stable seam across supported
            -- KOReader row layouts; retaining its original faces and width
            -- lets the patch follow device scaling without hardcoded pixels.
            local group = original_vertical_new(klass, children, ...)
            if not captured and children and children[1]
                    and type(children[1].text) == "string"
                    and children[1].width and children[1].width > 100 then
                local reference = children[2] or children[1]
                captured = {
                    group = group,
                    title = children[1],
                    authors = children[2],
                    face = reference.face,
                    width = children[1].width,
                }
            end
            return group
        end
        local ok, err = pcall(original_update, self, ...)
        VerticalGroup.new = original_vertical_new
        if not ok then error(err) end
        -- This widget is painted separately from the captured row group, so
        -- KOReader's normal child cleanup cannot free an older copy for us.
        if self.ao3_author_widget then
            self.ao3_author_widget:free()
            self.ao3_author_widget = nil
        end
        if not self.bookinfo_found or not self.filepath then return end

        local BookInfoManager = require("bookinfomanager")
        local book = BookInfoManager:getBookInfo(self.filepath, false)
        if not book or book.has_cover or book.ignore_cover
                or not next(icons_for(book, self.filepath)) then
            return
        end
        self.has_description = false

        local _, width_delta = compact_cover_slot(
            self._underline_container, self.height, self)

        if captured and captured.group then
            if width_delta and width_delta > 0 then
                captured.width = captured.width + width_delta
            end
            local function rebuild(widget, prefix, delta)
                if not widget then return end
                local manager = require("bookinfomanager")
                local has_override = FONT_DEFAULTS[prefix] or
                    manager:getSetting("list_font_" .. prefix .. "_path")
                    or manager:getSetting("list_font_" .. prefix .. "_size")
                    or manager:getSetting("list_font_" .. prefix .. "_faceindex")
                        ~= nil
                if not has_override then return end
                local face = configured_face(prefix, widget.face, delta)
                if face ~= widget.face then
                    widget.face = face
                    widget:free(true)
                    widget:init()
                end
            end
            rebuild(captured.title, "title", 0)
            rebuild(captured.authors, "authors", 0)

            local function remove_from_group(widget)
                if not widget then return end
                for index = 1, #captured.group do
                    if captured.group[index] == widget then
                        captured.group[index] = VerticalSpan:new{ width = 0 }
                        widget:free()
                        return
                    end
                end
            end
            if type(book.title) == "string" and book.title ~= "" then
                local previous_title = captured.title
                local title_widget = TextBoxWidget:new{
                    text = book.title,
                    face = previous_title.face,
                    width = math.max(MIN_TEXT_WIDTH,
                        captured.width - LIST_TEXT_MARGIN),
                    height = previous_title:getSize().h,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    fgcolor = captured.fgcolor,
                }
                local replaced = false
                for index = 1, #captured.group do
                    if captured.group[index] == previous_title then
                        captured.group[index] = title_widget
                        captured.title = title_widget
                        previous_title:free()
                        replaced = true
                        break
                    end
                end
                if not replaced then title_widget:free() end
            end
            local title_height = captured.title:getSize().h
            if not display_enabled("title") then
                remove_from_group(captured.title)
            end
            if not display_enabled("author") then
                remove_from_group(captured.authors)
            end
            if display_enabled("author")
                    and captured.authors
                    and type(captured.authors.text) == "string" then
                self.ao3_author_widget = TextWidget:new{
                    text = "by " .. captured.authors.text,
                    face = configured_face("authors", captured.authors.face, 0),
                    fgcolor = captured.fgcolor,
                }
                remove_from_group(captured.authors)
            end
            table.insert(captured.group, 1, VerticalSpan:new{
                width = ROW_TOP_PADDING,
            })

            local function used_height()
                local height = 0
                for index = 1, #captured.group do
                    local child = captured.group[index]
                    if child and child.getSize then
                        height = height + child:getSize().h
                    end
                end
                return height
            end

            local function add_text(prefix, text, delta, gap, height, framed)
                -- All replacement text uses the captured row width. This keeps
                -- long metadata inside the same right edge as native rows and
                -- lets TextBoxWidget perform the final line fitting.
                if type(text) ~= "string" or text == "" then return false end
                if not height or height < Screen:scaleBySize(12) then return false end
                local face = configured_face(prefix, captured.face, delta)
                local right_margin = LIST_TEXT_MARGIN
                local frame_padding = framed and Screen:scaleBySize(5) or 0
                local frame_border = framed and Size.border.thin or 0
                local frame_bottom_padding = framed and math.max(0,
                    frame_padding - Screen:scaleBySize(2)) or 0
                local content_height = height
                local widget = TextBoxWidget:new{
                    text = BD.auto(text),
                    face = face,
                    width = math.max(MIN_TEXT_WIDTH, captured.width - right_margin
                        - 2 * frame_padding
                        - 2 * frame_border),
                    height = content_height - (framed
                        and (frame_padding + frame_bottom_padding
                            + 2 * frame_border) or 0),
                    height_adjust = framed,
                    height_overflow_show_ellipsis = not framed,
                    alignment = "justify",
                    fgcolor = captured.fgcolor,
                }
                if framed then
                    local frame = FrameContainer:new{
                        bordersize = frame_border,
                        radius = Screen:scaleBySize(3),
                        padding_top = frame_padding,
                        padding_bottom = frame_bottom_padding,
                        padding_left = frame_padding,
                        padding_right = frame_padding,
                        margin = 0,
                        widget,
                    }
                    widget = LeftContainer:new{
                        dimen = Geom:new{ w = captured.width - right_margin,
                            h = frame:getSize().h },
                        frame,
                    }
                else
                    widget = LeftContainer:new{
                        dimen = Geom:new{ w = captured.width - right_margin,
                            h = height },
                        widget,
                    }
                end
                captured.group[#captured.group + 1] = VerticalSpan:new{ width = gap }
                captured.group[#captured.group + 1] = widget
                return true
            end

            local content_height = self.height
                - (self.underline_h or 0) - ROW_BOTTOM_PADDING
            local tag_list = collect_tags(book)
            local fandom = fandom_from_tags(tag_list)
            if display_enabled("fandom") and fandom then
                local fandom_widget = TextBoxWidget:new{
                    text = fandom,
                    face = configured_face("fandom", captured.face, -2),
                    width = math.max(MIN_TEXT_WIDTH,
                        captured.width - LIST_TEXT_MARGIN),
                    height = title_height,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    fgcolor = captured.fgcolor,
                }
                local insert_index = 2
                for index = 1, #captured.group do
                    if captured.group[index] == captured.title then
                        insert_index = index + 1
                        break
                    end
                end
                table.insert(captured.group, insert_index, fandom_widget)
            end
            if display_enabled("tags") and #tag_list > 0 then
                local regular_tags = filtered_tags(tag_list)
                if #regular_tags > 0 then
                    local remaining = content_height - used_height()
                    local gap = Screen:scaleBySize(6)
                    local available = remaining - gap
                    if available >= Screen:scaleBySize(12) then
                        local frame_padding = Screen:scaleBySize(5)
                        local tag_width = math.max(MIN_TEXT_WIDTH,
                            captured.width - LIST_TEXT_MARGIN
                                - 2 * frame_padding
                                - 2 * Size.border.thin)
                        local tag_face = configured_face(
                            "tags", captured.face, -2)
                        local frame_bottom_padding = math.max(0,
                            frame_padding - Screen:scaleBySize(2))
                        local frame_height = frame_padding
                            + frame_bottom_padding + 2 * Size.border.thin
                        local tags, text_height = fit_tag_text(regular_tags,
                            max_displayed_tags(), available - frame_height,
                            function(text)
                                local measured = TextBoxWidget:new{
                                    text = BD.auto(text),
                                    face = tag_face,
                                    width = tag_width,
                                    height_adjust = true,
                                    alignment = "justify",
                                    fgcolor = captured.fgcolor,
                                }
                                local height = measured:getSize().h
                                measured:free()
                                return height
                            end)
                        if tags then
                            add_text("tags", tags, -2, gap,
                                text_height + frame_height, true)
                        else
                            logger.warn("[ao3 plus] tag overflow label does not fit:",
                                self.filepath)
                        end
                    end
                end
            end
            local stats_widget
            local stats_height
            local stats_gap = Screen:scaleBySize(6)
            local file_metadata = display_enabled("metadata")
                and metadata_from_file(self.filepath)
            local stats = {}
            if file_metadata then
                if type(file_metadata.wordcount) == "string" then
                    stats[#stats + 1] = "Words: " .. file_metadata.wordcount
                end
                if type(file_metadata.chapters) == "string" then
                    stats[#stats + 1] = "Chapters: "
                        .. file_metadata.chapters
                end
            end
            if #stats > 0 then
                stats_widget = TextWidget:new{
                    text = BD.auto(table.concat(stats, "   ")),
                    face = configured_face("stats", captured.face, -2),
                    max_width = captured.width - LIST_TEXT_MARGIN,
                    alignment = "left",
                    fgcolor = captured.fgcolor,
                }
                stats_height = stats_widget:getSize().h
            end

            local description = type(book.description) == "string"
                and book.description:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
            local show_description = display_enabled("description")
                and description and description ~= ""
            if show_description then
                local words = {}
                for word in description:gmatch("%S+") do
                    words[#words + 1] = word
                    if #words >= 80 then
                        words[#words + 1] = "..."
                        break
                    end
                end
                local gap = Screen:scaleBySize(10)
                local reserved_stats = stats_widget
                    and stats_gap + stats_height or 0
                add_text("description", table.concat(words, " "), -2, gap,
                    content_height - used_height() - gap - reserved_stats)
            end
            if stats_widget then
                local remaining = content_height - used_height()
                if remaining >= stats_gap + stats_height then
                    if not show_description then
                        captured.group[#captured.group + 1] =
                            VerticalSpan:new{
                                width = remaining - stats_gap - stats_height,
                            }
                    end
                    captured.group[#captured.group + 1] =
                        VerticalSpan:new{ width = stats_gap }
                    captured.group[#captured.group + 1] = LeftContainer:new{
                        dimen = Geom:new{
                            w = captured.width - LIST_TEXT_MARGIN,
                            h = stats_height,
                        },
                        stats_widget,
                    }
                else
                    stats_widget:free()
                end
            end
        end

        local function replace_placeholder(container)
            -- The placeholder hook is not available in the detailed list,
            -- so replace KOReader's cover glyph in place and retain the
            -- surrounding row/container geometry.
            if type(container) ~= "table" then return false end
            local replaced = false
            for i = 1, #container do
                local child = container[i]
                if type(child) == "table" and child.text == "⛶" then
                    container[i] = badge_widget(
                        book, self.height, self.height,
                        {
                            bare = true,
                            top_left = true,
                            left_margin = Screen:scaleBySize(16),
                        }, self.filepath)
                    replaced = true
                elseif replace_placeholder(child) then
                    replaced = true
                end
            end
            if replaced and container.bordersize then
                container.bordersize = 0
                container.color = nil
                container.dim = nil
            end
            return replaced
        end
        if replace_placeholder(self._underline_container) then
            compact_cover_slot(self._underline_container, self.height, self)
        end
    end

    function ListMenuItem:paintTo(bb, x, y)
        -- These two elements are deliberately outside the captured group:
        -- the author is right-aligned and progress is anchored to the bottom
        -- edge. Painting them here avoids changing KOReader's row height math.
        local original_left_paint = LeftContainer.paintTo
        LeftContainer.paintTo = function(container, paint_bb, paint_x, paint_y)
            if BD.mirroredUILayout() and container.allow_mirroring then
                paint_x = paint_x + (container.dimen.w
                    - container[1]:getSize().w)
            end
            container.dimen.x = paint_x
            container.dimen.y = paint_y
            container[1]:paintTo(paint_bb, paint_x, paint_y)
        end
        local ok, err = pcall(original_paint_to, self, bb, x, y)
        LeftContainer.paintTo = original_left_paint
        if not ok then error(err) end
        if not self.entry or self.entry.is_file == false then return end
        if self.ao3_author_widget then
            local author_width = self.ao3_author_widget:getSize().w
            self.ao3_author_widget:paintTo(bb,
                x + self.width - author_width - ROW_RIGHT_INSET,
                y + ROW_TOP_PADDING)
        end
        if not display_enabled("progress") then return end
        local percent = read_percent(self.entry)
        if not percent or percent <= 0 then return end
        local progress = progress_bar(percent)
        local progress_x = x + self.width - progress:getSize().w
            - ROW_RIGHT_INSET
        local progress_y = y + self.height - progress:getSize().h
            - ROW_BOTTOM_PADDING
        progress:paintTo(bb, progress_x, progress_y)
        progress:free()
    end

    if type(original_free) == "function" then
        function ListMenuItem:free(...)
            if self.ao3_author_widget then
                self.ao3_author_widget:free()
                self.ao3_author_widget = nil
            end
            return original_free(self, ...)
        end
    end

    if plugin and not plugin.ao3_list_font_menu_patched then
        -- Settings are registered once because the plugin can be patched more
        -- than once during a KOReader session.
        plugin.ao3_list_font_menu_patched = true
        local function font_menu(label, prefix)
            local defaults = FONT_DEFAULTS[prefix]
            local default_size = defaults.size
            local FontList = require("fontlist")
            FontList:getFontList()
            local function key(suffix)
                return "list_font_" .. prefix .. "_" .. suffix
            end
            local function refresh()
                local chooser = plugin.ui and plugin.ui.file_chooser
                if not chooser or type(chooser.updateItems) ~= "function" then
                    logger.warn("[ao3 plus] font refresh unavailable")
                    return
                end
                local ok, err = pcall(chooser.updateItems, chooser)
                if not ok then
                    logger.warn("[ao3 plus] font refresh failed:", err)
                    return
                end
                local UIManager = require("ui/uimanager")
                UIManager:setDirty(chooser, "ui")
            end
            local items = {
                {
                    text_func = function()
                        local value = require("bookinfomanager"):getSetting(key("size"))
                            or default_size
                        return _("Font size") .. ": " .. value
                    end,
                    keep_menu_open = true,
                    callback = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(SpinWidget:new{
                            title_text = label .. " - " .. _("Font size"),
                            value = require("bookinfomanager"):getSetting(key("size"))
                                or default_size,
                            value_min = 8, value_max = 36, value_step = 1,
                            ok_text = _("Set"),
                            callback = function(widget)
                                require("bookinfomanager"):saveSetting(
                                    key("size"), widget.value)
                                refresh()
                            end,
                        })
                    end,
                },
                {
                    text = _("Reset to default"),
                    callback = function()
                        local manager = require("bookinfomanager")
                        reset_list_font_defaults(manager, prefix)
                        refresh()
                    end,
                },
            }
            local entries = {}
            for path, collection in pairs(FontList.fontinfo) do
                for _, entry in ipairs(collection) do
                    if entry.name then
                        entries[#entries + 1] = {
                            path = path,
                            name = entry.name,
                            faceindex = entry.faceindex,
                        }
                    end
                end
            end
            table.sort(entries, function(a, b) return a.name < b.name end)
            for _, entry in ipairs(entries) do
                items[#items + 1] = {
                    text = entry.name,
                    font_func = function(size)
                        local ok, face = pcall(Font.getFace, Font, entry.path,
                            size, entry.faceindex)
                        if ok and face then return face end
                        logger.warn("[ao3 plus] font preview failed:",
                            entry.path, face)
                        return Font:getFace("cfont", size)
                    end,
                    radio = true,
                    checked_func = function()
                        return (require("bookinfomanager"):getSetting(key("path"))
                            or defaults.path) == entry.path
                    end,
                    keep_menu_open = true,
                    callback = function()
                        local manager = require("bookinfomanager")
                        manager:saveSetting(key("path"), entry.path)
                        manager:saveSetting(key("faceindex"), entry.faceindex)
                        refresh()
                    end,
                }
            end
            return { text = label, sub_item_table = items }
        end

        local function refresh_file_list()
            local FileManager = require("apps/filemanager/filemanager")
            local file_manager = FileManager.instance
            local chooser = file_manager and file_manager.file_chooser
            if not chooser or type(chooser.refreshPath) ~= "function" then
                logger.warn("[ao3 plus] list refresh unavailable")
                return false
            end
            local ok, err = pcall(function()
                chooser:refreshPath()
            end)
            if not ok then
                logger.warn("[ao3 plus] display refresh failed:", err)
                return false
            end
            require("ui/uimanager"):setDirty(chooser, "ui")
            return true
        end

        local function display_toggle(label, name)
            return {
                text = label,
                checked_func = function()
                    return display_enabled(name)
                end,
                keep_menu_open = true,
                callback = function(menu_instance)
                    local setting = "ao3_plus_hide_" .. name
                    if display_enabled(name) then
                        G_reader_settings:saveSetting(setting, true)
                    else
                        G_reader_settings:saveSetting(setting, nil)
                    end
                    if menu_instance
                            and type(menu_instance.updateItems) == "function" then
                        menu_instance:updateItems()
                    end
                    refresh_file_list()
                end,
            }
        end

        local function tag_count_menu()
            return {
                text_func = function()
                    return _("# of displayed tags") .. ": "
                        .. max_displayed_tags()
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = _("# of displayed tags"),
                        value = max_displayed_tags(),
                        value_min = 1,
                        value_max = MAX_TAGS_LIMIT,
                        value_step = 1,
                        ok_text = _("Set"),
                        callback = function(widget)
                            G_reader_settings:saveSetting(
                                "ao3_plus_max_tags", widget.value)
                            refresh_file_list()
                        end,
                    })
                end,
            }
        end

        local has_order_entry = false
        for _, id in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if id == "ao3_plus_settings" then
                has_order_entry = true
                break
            end
        end
        if not has_order_entry then
            table.insert(FileManagerMenuOrder.filemanager_settings,
                "ao3_plus_settings")
        end

        local original_add_to_main_menu = plugin.addToMainMenu
        function plugin:addToMainMenu(menu_items)
            original_add_to_main_menu(self, menu_items)
            local ok, err = pcall(function()
                local ao3_settings = {
                    text = _("Ao3 Plus settings"),
                    sub_item_table = {
                        {
                            text = _("Show and hide"),
                            sub_item_table = {
                                display_toggle(_("Show title"), "title"),
                                display_toggle(_("Show author"), "author"),
                                display_toggle(_("Show fandom"), "fandom"),
                                display_toggle(_("Show tags"), "tags"),
                                display_toggle(_("Show description"), "description"),
                                display_toggle(_("Show fic data"), "metadata"),
                                display_toggle(_("Show progress"), "progress"),
                            },
                        },
                        {
                            text = _("Font settings"),
                            sub_item_table = {
                                font_menu(_("Title font"), "title"),
                                font_menu(_("Authors font"), "authors"),
                                font_menu(_("Fandom font"), "fandom"),
                                font_menu(_("Tags font"), "tags"),
                                font_menu(_("Description font"), "description"),
                                font_menu(_("Fic data font"), "stats"),
                            },
                        },
                        {
                            text = _("Tags"),
                            sub_item_table = {
                                tag_count_menu(),
                            },
                        },
                        {
                            text = _("Top panel badge size (Bookshelf only)"),
                            sub_item_table = {
                                {
                                    text = _("Small (same as list rows)"),
                                    radio = true,
                                    checked_func = function()
                                        return G_reader_settings:readSetting(
                                            "ao3_plus_small_panel_badges") ~= false
                                    end,
                                    callback = function()
                                        G_reader_settings:saveSetting(
                                            "ao3_plus_small_panel_badges", true)
                                    end,
                                },
                                {
                                    text = _("Large"),
                                    radio = true,
                                    checked_func = function()
                                        return G_reader_settings:readSetting(
                                            "ao3_plus_small_panel_badges") == false
                                    end,
                                    callback = function()
                                        G_reader_settings:saveSetting(
                                            "ao3_plus_small_panel_badges", false)
                                    end,
                                },
                            },
                            help_text = _("Reopen Bookshelf to apply the new badge size."),
                        },
                        {
                            text = _("Refresh list"),
                            keep_menu_open = true,
                            callback = refresh_file_list,
                        },
                        {
                            text = _("Clean Ao3 Plus cache"),
                            keep_menu_open = true,
                            callback = function()
                                local removed = clean_cache_stores()
                                local InfoMessage = require("ui/widget/infomessage")
                                local message
                                if removed == nil then
                                    message = _("The Ao3 Plus cache could not be cleaned.")
                                elseif removed == 0 then
                                    message = _("No stale cache entries were found.")
                                else
                                    message = string.format(
                                        _("Removed %d stale cache entries."),
                                        removed)
                                end
                                require("ui/uimanager"):show(InfoMessage:new{
                                    text = message,
                                })
                            end,
                        },
                    },
                }
                menu_items.ao3_plus_settings = ao3_settings
            end)
            if not ok then
                logger.warn("[ao3 plus] font menu unavailable:", err)
            end
        end
    end
end

userpatch.registerPatchPluginFunc("bookshelf", patch_bookshelf)
userpatch.registerPatchPluginFunc("coverbrowser", function(plugin)
    local ok, err = pcall(function() patch_coverbrowser(plugin) end)
    if not ok then
        logger.warn("[ao3 plus] CoverBrowser integration unavailable:", err)
    end
end)
