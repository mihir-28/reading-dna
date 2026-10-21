-- Reading DNA: an offline reading-pattern summary for Bookshelf.
-- Copyright (C) 2026 Reading DNA contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local Kit = require("lib/bookshelf_module_kit")

local MODULE_KEY = "reading_dna"
local MODULE_VERSION = "0.1.3"
local DEFAULT_WINDOW = 30
local SESSION_GAP = 20 * 60
local MIN_SESSION = 60
local MAX_SESSION = 6 * 60 * 60
local MIN_ACTIVE_DAYS = 14
local MIN_TOTAL_SECONDS = 5 * 60 * 60

local store = Kit.moduleStore(MODULE_KEY)
local _refresh

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function localDateKey(timestamp)
    return os.date("%Y-%m-%d", timestamp)
end

local function localDayStart(timestamp)
    local date = os.date("*t", timestamp)
    date.hour, date.min, date.sec = 0, 0, 0
    return os.time(date)
end

local function windowStart(now, days)
    local date = os.date("*t", now)
    date.hour, date.min, date.sec = 0, 0, 0
    date.day = date.day - days + 1
    return os.time(date)
end

local function median(values)
    if #values == 0 then return nil end
    table.sort(values)
    local middle = math.floor((#values + 1) / 2)
    if #values % 2 == 1 then return values[middle] end
    return (values[middle] + values[middle + 1]) / 2
end

local function nightFraction(timestamp, duration, night_start, night_end)
    -- Count seconds by local hour. Reading events are short; cap each event at
    -- 12 hours so malformed rows cannot dominate the summary.
    local left = clamp(math.floor(tonumber(duration) or 0), 0, 12 * 60 * 60)
    local late = 0
    local cursor = timestamp
    while left > 0 do
        local parts = os.date("*t", cursor)
        local until_hour = 3600 - (parts.min * 60 + parts.sec)
        local chunk = math.min(left, until_hour)
        local hour = parts.hour
        local is_night
        if night_start > night_end then
            is_night = hour >= night_start or hour < night_end
        else
            is_night = hour >= night_start and hour < night_end
        end
        if is_night then late = late + chunk end
        cursor, left = cursor + chunk, left - chunk
    end
    return late
end

-- Statistics can contain overlapping page intervals. Assign overlap to the
-- earliest event so totals, daily shares, and session lengths never double-count.
local function normalizeEvents(events)
    local normalized, covered_until = {}, nil
    for _, event in ipairs(events) do
        local start_time = math.max(event.time, covered_until or event.time)
        local finish = event.time + event.duration
        if finish > start_time then
            normalized[#normalized + 1] = {
                book = event.book,
                time = start_time,
                duration = finish - start_time,
                authors = event.authors,
            }
            covered_until = finish
        end
    end
    return normalized
end

-- KOReader's authors field is free-form metadata. Commas are not a safe
-- delimiter (some names use "Family, Given"), so count normalized credits as
-- stored instead of guessing at individual contributors.
local function countAuthorCredits(events)
    local credits = {}
    for _, event in ipairs(events) do
        local credit = event.authors:gsub("%s+", " "):match("^%s*(.-)%s*$"):lower()
        if credit ~= "" and credit ~= "n/a" then credits[credit] = true end
    end
    local count = 0
    for _ in pairs(credits) do count = count + 1 end
    return count
end

local function observedDayCount(now, selected_start, first_event, days)
    local first_eligible = selected_start
    if first_event and first_event > first_eligible then
        first_eligible = localDayStart(first_event)
    end
    local cursor = first_eligible
    local count = 0
    while cursor <= now and count < days do
        count = count + 1
        local date = os.date("*t", cursor)
        date.day = date.day + 1
        cursor = os.time(date)
    end
    return math.max(1, count)
end

local function readEvents(days, night_start, night_end)
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "missing_db"
    end

    local now = os.time()
    local first = windowStart(now, days)
    local connection
    local ok, result = pcall(function()
        local SQLite = require("lua-ljsqlite3/init")
        connection = SQLite.open(path, "ro")
        connection:exec("PRAGMA busy_timeout=200;")

        local rows = {}
        local statement = connection:prepare([[
            SELECT p.id_book, p.start_time, p.duration, COALESCE(b.authors, ''),
                   (SELECT MIN(start_time) FROM page_stat_data WHERE duration > 0)
            FROM page_stat_data AS p
            LEFT JOIN book AS b ON b.id = p.id_book
            WHERE p.start_time >= ? AND p.start_time <= ? AND p.duration > 0
            ORDER BY p.start_time ASC
        ]])
        local step = statement:bind(first, now):step()
        local first_event = tonumber(step and step[5])
        while step do
            local timestamp = tonumber(step[2])
            local duration = tonumber(step[3])
            if timestamp and duration and duration > 0 then
                rows[#rows + 1] = {
                    book = tostring(step[1] or "unknown"),
                    time = timestamp,
                    duration = math.min(duration, 12 * 60 * 60),
                    authors = tostring(step[4] or ""),
                }
            end
            step = statement:step()
        end
        statement:close()
        return { events = rows, now = now, window_start = first, first_event = first_event }
    end)
    if connection then pcall(connection.close, connection) end
    if not ok then
        require("logger").warn("[reading_dna] statistics read failed:", result)
        return nil, "query_error"
    end
    return result
end

local function sessionize(events)
    local sessions = {}
    local current
    for _, event in ipairs(events) do
        local event_end = event.time + event.duration
        if not current or event.time - current.last_end > SESSION_GAP then
            current = {
                start = event.time,
                last_end = event_end,
                duration = event.duration,
                book = event.book,
            }
            sessions[#sessions + 1] = current
        else
            current.last_end = math.max(current.last_end, event_end)
            current.duration = current.duration + event.duration
            current.book = event.book
        end
    end

    local valid, lengths, switches = {}, {}, 0
    local previous_book
    for _, session in ipairs(sessions) do
        local duration = clamp(session.duration, 0, MAX_SESSION)
        if duration >= MIN_SESSION then
            valid[#valid + 1] = session
            lengths[#lengths + 1] = duration
            if previous_book and previous_book ~= session.book then
                switches = switches + 1
            end
            previous_book = session.book
        end
    end
    return valid, lengths, switches
end

local function calculate(days, night_start, night_end)
    local result, err = readEvents(days, night_start, night_end)
    if not result then return nil, err end
    local raw_events = result.events
    local events = normalizeEvents(raw_events)
    if #events == 0 then return { empty = true, days = days, analyzed_at = result.now } end

    local day_totals, books = {}, {}
    local active_days, total_seconds, late_seconds = 0, 0, 0
    for _, event in ipairs(events) do
        local date = localDateKey(event.time)
        day_totals[date] = day_totals[date] or {}
        day_totals[date][event.book] = (day_totals[date][event.book] or 0) + event.duration
        total_seconds = total_seconds + event.duration
        late_seconds = late_seconds + nightFraction(event.time, event.duration, night_start, night_end)
    end

    local loyal_days = 0
    for _, by_book in pairs(day_totals) do
        active_days = active_days + 1
        local day_total, day_max = 0, 0
        for _, seconds in pairs(by_book) do
            day_total = day_total + seconds
            day_max = math.max(day_max, seconds)
        end
        if day_total > 0 and day_max / day_total >= 0.6 then loyal_days = loyal_days + 1 end
    end

    local sessions, session_lengths, switches = sessionize(events)
    local observed_days = observedDayCount(result.now, result.window_start, result.first_event, days)
    local consistency = 100 * active_days / observed_days
    local median_session = median(session_lengths)
    local book_count = 0
    for _, event in ipairs(raw_events) do books[event.book] = true end
    for _ in pairs(books) do book_count = book_count + 1 end
    local author_count = countAuthorCredits(raw_events)

    local metrics = {
        { key = "consistency", label = _("Consistency"), raw = T(_("%1 / %2 days"), active_days, observed_days),
            score = active_days >= 3 and clamp(consistency, 0, 100) or nil,
            sample = active_days, available = active_days >= 3 and total_seconds >= 30 * 60,
            confidence_hint = active_days < 3 and _("Need 3 active days") or _("Need 30 minutes recorded") },
        { key = "depth", label = _("Session depth"), raw = median_session and T(_("%1 min median session"), math.floor(median_session / 60 + 0.5)) or nil,
            score = median_session and clamp(median_session / (60 * 60) * 100, 0, 100) or nil,
            sample = #sessions, available = #sessions >= 3, confidence_hint = _("Need 3 valid sessions") },
        { key = "loyalty", label = _("Book loyalty"), raw = T(_("%1 / %2 focused days"), loyal_days, active_days),
            score = active_days > 0 and 100 * loyal_days / active_days or nil, sample = active_days,
            available = active_days >= 5, confidence_hint = _("Need 5 active days") },
        { key = "exploration", label = _("Exploration"), raw = T(_("%1 books · %2 author credits"), book_count, author_count),
            score = clamp(50 * math.min(1, book_count / 10) + 50 * math.min(1, author_count / 5), 0, 100),
            sample = book_count, available = book_count >= 3, confidence_hint = _("Need 3 books") },
        { key = "night", label = _("Night reading"), raw = total_seconds > 0 and T(_("%1% of read time"), math.floor(100 * late_seconds / total_seconds + 0.5)) or nil,
            score = total_seconds > 0 and 100 * late_seconds / total_seconds or nil,
            sample = math.floor(total_seconds / 60), available = total_seconds >= 60 * 60,
            confidence_hint = _("Need 60 minutes recorded") },
        { key = "switching", label = _("Switches"), raw = T(_("%1 / %2 sessions"), switches, #sessions),
            score = #sessions > 1 and 100 * switches / (#sessions - 1) or nil,
            sample = #sessions, available = #sessions >= 4, confidence_hint = _("Need 4 valid sessions") },
    }

    for _, metric in ipairs(metrics) do
        if not metric.available then metric.score = nil end
        if metric.score then metric.score = clamp(math.floor(metric.score + 0.5), 0, 100) end
    end

    local evidence = active_days >= MIN_ACTIVE_DAYS and total_seconds >= MIN_TOTAL_SECONDS
    local values = {}
    for _, metric in ipairs(metrics) do values[metric.key] = metric.score end
    local archetype = "Mixed Reader"
    if evidence then
        if values.night and values.night >= 60 then archetype = "Night Owl"
        elseif values.depth and values.loyalty and values.depth >= 65 and values.loyalty >= 65 then archetype = "Deep Diver"
        elseif values.exploration and values.exploration >= 65 then archetype = "Explorer"
        elseif values.depth and values.consistency and values.depth >= 60 and values.consistency >= 65 then archetype = "Marathoner"
        elseif values.switching and values.switching >= 70 then archetype = "Wanderer" end
    end

    return {
        empty = false,
        days = days,
        analyzed_at = result.now,
        active_days = active_days,
        total_minutes = math.floor(total_seconds / 60),
        book_count = book_count,
        author_count = author_count,
        evidence = evidence,
        archetype = archetype,
        metrics = metrics,
    }
end

local function getWindow(ctx)
    local value = tonumber(ctx.config:get("window_days", DEFAULT_WINDOW)) or DEFAULT_WINDOW
    if value ~= 30 and value ~= 90 and value ~= 365 then value = DEFAULT_WINDOW end
    return value
end

local function getSnapshot(days)
    local snapshot = store:get("snapshot")
    if type(snapshot) == "table" and snapshot.days == days then return snapshot end
    return nil
end

local function textWidget(text, width, scale_pct, role)
    local TextWidget = require("lib/bookshelf_colour_text")
    local opts = (role == "title" or role == "value") and { bold = true } or nil
    local size = role == "title" and 24 or (role == "value" and 17 or 13)
    local face, bold = Kit.face(size, scale_pct, opts)
    return TextWidget:new{
        text = text,
        face = face,
        bold = bold,
        fgcolor = (role == "muted" or role == "label") and Kit.COLOR_MUTED or Kit.COLOR_PRIMARY,
        max_width = width,
    }
end

local function renderMetric(metric, width, scale_pct, show_scores)
    local score = metric.score
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(metric.label, width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(2) }
    group[#group + 1] = textWidget(metric.raw or _("No reading data"), width, scale_pct, "value")
    if show_scores and score then
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
        group[#group + 1] = Kit.progressBar{
            width = math.max(50, width), height = Kit.sc(scale_pct)(5), fraction = score / 100,
        }
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
        group[#group + 1] = textWidget(T(_("Score %1 / 100"), score), width, scale_pct, "muted")
    elseif not score then
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
        group[#group + 1] = textWidget(metric.confidence_hint or _("More reading data needed"), width, scale_pct, "muted")
    end
    return group
end

local function renderProfileHeader(snapshot, label, width, scale_pct, days)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(label, width, scale_pct, "title")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    if not snapshot.evidence then
        group[#group + 1] = textWidget(_("Provisional profile"), width, scale_pct, "muted")
    end
    group[#group + 1] = textWidget(
        T(_("%1 active · %2 books · %3d"), snapshot.active_days, snapshot.book_count, days),
        width, scale_pct, "normal")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
    group[#group + 1] = textWidget(
        T(_("Updated %1"), os.date("%b %d, %Y", snapshot.analyzed_at)),
        width, scale_pct, "muted")
    return group
end

local function render(ctx)
    local width, scale_pct = math.max(50, ctx.width or 200), ctx.scale or 100
    local days = getWindow(ctx)
    local show_scores = ctx.config:get("show_scores", true) ~= false
    _refresh = ctx.refresh

    if ctx.preview then
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("Mixed Reader"),
            sub = _("Tap to analyze your reading patterns"),
            context = T(_("Last %1 days · Works offline"), days),
        }
    end

    local snapshot = getSnapshot(days)
    if not snapshot then
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("Not analyzed yet"),
            sub = _("Tap to analyze your reading patterns"),
            context = T(_("Last %1 days · Works offline"), days),
        }
    end
    if snapshot.error then
        local message = snapshot.error == "missing_db"
            and _("Statistics database not found")
            or _("Statistics unavailable; tap to retry")
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("Unable to analyze"),
            sub = message,
        }
    end
    if snapshot.empty then
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("No reading history"),
            sub = _("KOReader has no reading events in this window."),
            context = T(_("Analyzed %1"), os.date("%Y-%m-%d", snapshot.analyzed_at)),
        }
    end

    local label = ctx.config:get("show_archetype", true) and snapshot.archetype or _("Profile")
    local group = require("ui/widget/verticalgroup"):new{ align = "left" }
    local VerticalSpan = require("ui/widget/verticalspan")
    local header = renderProfileHeader(snapshot, label, width, scale_pct, days)
    group[#group + 1] = header
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(16) }
    local full = ctx.surface == "fullscreen"
    local visible_metrics = snapshot.metrics
    if not full then
        visible_metrics = {}
        for _, metric in ipairs(snapshot.metrics) do visible_metrics[#visible_metrics + 1] = metric end
        table.sort(visible_metrics, function(a, b)
            if a.score == nil then return false end
            if b.score == nil then return true end
            return a.score > b.score
        end)
    end
    if full and width >= Kit.twoColMinWidth() * 1.45 then
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local gap = Kit.sc(scale_pct)(18)
        local col_width = math.floor((width - gap) / 2)
        for index = 1, #visible_metrics, 2 do
            local row = HorizontalGroup:new{ align = "top",
                renderMetric(visible_metrics[index], col_width, scale_pct, show_scores),
                HorizontalSpan:new{ width = gap },
                visible_metrics[index + 1]
                    and renderMetric(visible_metrics[index + 1], col_width, scale_pct, show_scores)
                    or HorizontalSpan:new{ width = col_width },
            }
            group[#group + 1] = row
            if index + 1 < #visible_metrics then
                group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(18) }
            end
        end
    else
        local count = full and #visible_metrics or math.min(2, #visible_metrics)
        for i = 1, count do
            local metric = visible_metrics[i]
            if metric then group[#group + 1] = renderMetric(metric, width, scale_pct, show_scores) end
            if i < count then group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) } end
        end
    end
    if full then
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(18) }
        group[#group + 1] = textWidget(
            T(_("%1 min · %2 credits"), snapshot.total_minutes, snapshot.author_count),
            width, scale_pct, "muted")
        group[#group + 1] = textWidget(
            _("Finished books are not tracked reliably."),
            width, scale_pct, "muted")
    end
    return group
end

local showSettings
showSettings = function(ctx)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local current = getWindow(ctx)
    local night_window = ctx.config:get("night_window", "21-04")
    local show_scores = ctx.config:get("show_scores", true) ~= false
    local show_archetype = ctx.config:get("show_archetype", true) ~= false
    local dialog
    local function updateSetting(name, value)
        return function()
            UIManager:close(dialog)
            ctx.config:set(name, value)
            store:delete("snapshot")
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            showSettings(ctx)
        end
    end
    local function chooseWindow(days)
        return function()
            UIManager:close(dialog)
            ctx.config:set("window_days", days)
            store:delete("snapshot")
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            showSettings(ctx)
        end
    end
    local function chooseNight(window)
        return function()
            UIManager:close(dialog)
            ctx.config:set("night_window", window)
            store:delete("snapshot")
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            showSettings(ctx)
        end
    end
    dialog = ButtonDialog:new{
        title = _("Reading DNA settings"),
        title_align = "center",
        buttons = {
            { { text = (current == 30 and "✓ " or "  ") .. _("Last 30 days"), callback = chooseWindow(30) } },
            { { text = (current == 90 and "✓ " or "  ") .. _("Last 90 days"), callback = chooseWindow(90) } },
            { { text = (current == 365 and "✓ " or "  ") .. _("Last 365 days"), callback = chooseWindow(365) } },
            { { text = _("Night hours"), enabled = false } },
            { { text = (night_window == "20-06" and "✓ " or "  ") .. "20:00–06:00", callback = chooseNight("20-06") } },
            { { text = (night_window == "21-04" and "✓ " or "  ") .. "21:00–04:00", callback = chooseNight("21-04") } },
            { { text = (night_window == "22-05" and "✓ " or "  ") .. "22:00–05:00", callback = chooseNight("22-05") } },
            { { text = (show_scores and "✓ " or "  ") .. _("Show scores"), callback = updateSetting("show_scores", not show_scores) } },
            { { text = (show_archetype and "✓ " or "  ") .. _("Show archetype"), callback = updateSetting("show_archetype", not show_archetype) } },
            { { text = _("Done"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

local module = {
    key = MODULE_KEY,
    version = MODULE_VERSION,
    title = _("Reading DNA"),
    summary = _("From KOReader reading statistics. Works offline."),
    keep_open = true,
    render = render,
    on_tap = function(ctx)
        local days = getWindow(ctx)
        local night_window = ctx.config:get("night_window", "21-04")
        local night_hours = {
            ["20-06"] = { 20, 6 }, ["21-04"] = { 21, 4 }, ["22-05"] = { 22, 5 },
        }
        local selected_night = night_hours[night_window] or night_hours["21-04"]
        local night_start, night_end = selected_night[1], selected_night[2]
        local snapshot, err = calculate(days, night_start, night_end)
        if snapshot then
            store:set("snapshot", snapshot)
        else
            store:set("snapshot", {
                error = err,
                days = days,
                analyzed_at = os.time(),
            })
        end
        if _refresh then _refresh() end
    end,
    show_settings = showSettings,
}

-- Private test seam; absent in KOReader production unless explicitly enabled.
if rawget(_G, "READING_DNA_TEST") then
    module._test = {
        normalizeEvents = normalizeEvents,
        countAuthorCredits = countAuthorCredits,
        observedDayCount = observedDayCount,
        localDateKey = localDateKey,
        readEvents = readEvents,
    }
end

return module
