-- Reading DNA: an offline reading-pattern summary for Bookshelf.
-- Copyright (C) 2026 Reading DNA contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local Kit = require("lib/bookshelf_module_kit")

local MODULE_KEY = "reading_dna"
local MODULE_VERSION = "0.3.2"
local DEFAULT_WINDOW = 30
local SESSION_GAP = 20 * 60
local MIN_SESSION = 60
local MAX_SESSION = 6 * 60 * 60
local MIN_ACTIVE_DAYS = 14
local MIN_TOTAL_SECONDS = 5 * 60 * 60

local store = Kit.moduleStore(MODULE_KEY)
local _refresh
local analysis_pending = false
local analysis_generation = 0

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
        return { events = rows, now = now, window_start = first, first_event = first_event, days = days }
    end)
    if connection then pcall(connection.close, connection) end
    if not ok then
        require("logger").warn("[reading_dna] statistics read failed:", result)
        return nil, "query_error"
    end
    return result
end

-- Yield between bounded batches so even large statistics databases leave time
-- for Kindle UI events. Only explicit user-triggered analysis reaches this path.
local function readEventsAsync(days, onComplete)
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then
        onComplete(nil, "missing_db")
        return
    end

    local now = os.time()
    local first = windowStart(now, days)
    local state = { events = {}, now = now, window_start = first }
    local ok, err = pcall(function()
        local SQLite = require("lua-ljsqlite3/init")
        state.connection = SQLite.open(path, "ro")
        state.connection:exec("PRAGMA busy_timeout=200;")
        state.statement = state.connection:prepare([[
            SELECT p.id_book, p.start_time, p.duration, COALESCE(b.authors, ''),
                   (SELECT MIN(start_time) FROM page_stat_data WHERE duration > 0)
            FROM page_stat_data AS p
            LEFT JOIN book AS b ON b.id = p.id_book
            WHERE p.start_time >= ? AND p.start_time <= ? AND p.duration > 0
            ORDER BY p.start_time ASC
        ]])
        state.row = state.statement:bind(first, now):step()
        state.first_event = tonumber(state.row and state.row[5])
    end)
    if not ok then
        if state.connection then pcall(state.connection.close, state.connection) end
        require("logger").warn("[reading_dna] statistics read failed:", err)
        onComplete(nil, "query_error")
        return
    end

    local function processBatch()
        local batch_ok, batch_err = pcall(function()
            local processed = 0
            while state.row and processed < 100 do
                local timestamp = tonumber(state.row[2])
                local duration = tonumber(state.row[3])
                if timestamp and duration and duration > 0 then
                    state.events[#state.events + 1] = {
                        book = tostring(state.row[1] or "unknown"),
                        time = timestamp,
                        duration = math.min(duration, 12 * 60 * 60),
                        authors = tostring(state.row[4] or ""),
                    }
                end
                processed = processed + 1
                state.row = state.statement:step()
            end
        end)
        if not batch_ok then
            pcall(state.statement.close, state.statement)
            pcall(state.connection.close, state.connection)
            require("logger").warn("[reading_dna] statistics read failed:", batch_err)
            onComplete(nil, "query_error")
            return
        end
        if state.row then
            require("ui/uimanager"):scheduleIn(0.01, processBatch)
            return
        end
        pcall(state.statement.close, state.statement)
        pcall(state.connection.close, state.connection)
        onComplete({ events = state.events, now = state.now,
            window_start = state.window_start, first_event = state.first_event, days = days })
    end
    require("ui/uimanager"):scheduleIn(0.01, processBatch)
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

local function calculateSingle(days, night_start, night_end, result)
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
        observed_days = observed_days,
        total_minutes = math.floor(total_seconds / 60),
        book_count = book_count,
        author_count = author_count,
        evidence = evidence,
        archetype = archetype,
        metrics = metrics,
    }
end

local function calculate(days, night_start, night_end, provided_result, provided_error)
    local result, err = provided_result, provided_error
    if not result and not err then result, err = readEvents(days, night_start, night_end) end
    if not result then return nil, err end

    -- Trends compare two complete, adjacent windows of equal length.
    if result.days and result.days >= days * 2 then
        local current_start = windowStart(result.now, days)
        local previous_end = current_start - 1
        local previous_start = windowStart(previous_end, days)
        local current_events, previous_events = {}, {}
        for _, event in ipairs(result.events) do
            if event.time >= current_start and event.time <= result.now then
                current_events[#current_events + 1] = event
            elseif event.time >= previous_start and event.time <= previous_end then
                previous_events[#previous_events + 1] = event
            end
        end
        local current = calculateSingle(days, night_start, night_end, {
            events = current_events, now = result.now, window_start = current_start,
            first_event = result.first_event,
        })
        local previous = calculateSingle(days, night_start, night_end, {
            events = previous_events, now = previous_end, window_start = previous_start,
            first_event = result.first_event,
        })
        if not current.empty and not previous.empty
                and current.active_days >= 3 and previous.active_days >= 3
                and current.total_minutes >= 30 and previous.total_minutes >= 30 then
            current.trend = {
                days = current.active_days - previous.active_days,
                minutes = current.total_minutes - previous.total_minutes,
            }
        end
        return current
    end
    return calculateSingle(days, night_start, night_end, result)
end

local function getWindow(ctx)
    local value = tonumber(ctx.config:get("window_days", DEFAULT_WINDOW)) or DEFAULT_WINDOW
    if value ~= 30 and value ~= 90 and value ~= 365 then value = DEFAULT_WINDOW end
    return value
end

local function startAnalysis(ctx, replace_pending)
    if analysis_pending and not replace_pending then return end
    analysis_generation = analysis_generation + 1
    local generation = analysis_generation
    analysis_pending = true
    local days = getWindow(ctx)
    local night_window = ctx.config:get("night_window", "21-04")
    local night_hours = {
        ["20-06"] = { 20, 6 }, ["21-04"] = { 21, 4 }, ["22-05"] = { 22, 5 },
    }
    local selected_night = night_hours[night_window] or night_hours["21-04"]
    local night_start, night_end = selected_night[1], selected_night[2]
    store:set("snapshot", { pending = true, days = days })
    if _refresh then _refresh() end
    readEventsAsync(days * 2, function(result, err)
        -- A newer settings choice supersedes this result; never display a stale window.
        if generation ~= analysis_generation then return end
        analysis_pending = false
        local snapshot
        if result then
            snapshot, err = calculate(days, night_start, night_end, result)
        end
        if snapshot then store:set("snapshot", snapshot)
        else store:set("snapshot", { error = err, days = days, analyzed_at = os.time() }) end
        if _refresh then _refresh() end
    end)
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

local function getLayout(ctx)
    local layout = ctx.config:get("reading_dna_layout", "field_notes")
    if layout ~= "field_notes" and layout ~= "shelf_index" and layout ~= "fingerprint" then
        return "field_notes"
    end
    return layout
end


local function addDivider(group, width)
    local LineWidget = require("ui/widget/linewidget")
    local Geom = require("ui/geometry")
    group[#group + 1] = LineWidget:new{
        background = Kit.COLOR_MUTED,
        dimen = Geom:new{ w = math.max(1, width), h = 1 },
    }
end

local function metricByKey(snapshot, key)
    for _, metric in ipairs(snapshot.metrics) do
        if metric.key == key then return metric end
    end
end

local function getObservedDays(snapshot)
    if tonumber(snapshot.observed_days) then return tonumber(snapshot.observed_days) end
    local consistency = metricByKey(snapshot, "consistency")
    local stored = consistency and consistency.raw or ""
    return tonumber(stored:match("/%s*(%d+)%s+days")) or snapshot.active_days
end

local function renderLeadStat(value, label, width, scale_pct)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(value, width, scale_pct, "value")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
    group[#group + 1] = textWidget(label, width, scale_pct, "muted")
    return group
end

local function addTrend(group, snapshot, width, scale_pct, days)
    if not snapshot.trend then return end
    local VerticalSpan = require("ui/widget/verticalspan")
    local signed = function(value)
        return value > 0 and ("+" .. value) or tostring(value)
    end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(10) }
    group[#group + 1] = textWidget(
        T(_("Vs prior %1d: %2 days · %3 min"), days,
            signed(snapshot.trend.days), signed(snapshot.trend.minutes)),
        width, scale_pct, "muted")
end

local function renderMetricGrid(group, metrics, width, scale_pct, show_scores)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local gap = Kit.sc(scale_pct)(18)
    local col_width = math.max(1, math.floor((width - gap) / 2))
    for index = 1, #metrics, 2 do
        group[#group + 1] = HorizontalGroup:new{ align = "top",
            renderMetric(metrics[index], col_width, scale_pct, show_scores),
            HorizontalSpan:new{ width = gap },
            metrics[index + 1]
                and renderMetric(metrics[index + 1], col_width, scale_pct, show_scores)
                or HorizontalSpan:new{ width = col_width },
        }
        if index + 1 < #metrics then
            group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(16) }
        end
    end
end

local function renderFieldNotes(snapshot, label, width, scale_pct, days, show_scores)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = renderProfileHeader(snapshot, label, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }

    local observed_days = getObservedDays(snapshot)
    local lead_gap = Kit.sc(scale_pct)(12)
    local lead_width = math.max(1, math.floor((width - 2 * lead_gap) / 3))
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        renderLeadStat(tostring(snapshot.active_days), _("Active days"), lead_width, scale_pct),
        HorizontalSpan:new{ width = lead_gap },
        renderLeadStat(tostring(snapshot.book_count), _("Books"), lead_width, scale_pct),
        HorizontalSpan:new{ width = lead_gap },
        renderLeadStat(tostring(snapshot.total_minutes), _("Minutes read"), lead_width, scale_pct),
    }
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(14) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(10) }
    renderMetricGrid(group, snapshot.metrics, width, scale_pct, show_scores)
    addTrend(group, snapshot, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(10) }
    group[#group + 1] = textWidget(
        T(_("History span: %1 of %2 days · %3 author credits"),
            observed_days, days, snapshot.author_count),
        width, scale_pct, "muted")
    group[#group + 1] = textWidget(_("Finished books are not tracked reliably."), width, scale_pct, "muted")
    return group
end

local function renderShelfIndex(snapshot, label, width, scale_pct, days, show_scores)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(_("KOReader · Reading record"), width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    group[#group + 1] = textWidget(label, width, scale_pct, "title")
    group[#group + 1] = textWidget(
        T(_("No. 01 · %1 active days in %2 selected"), snapshot.active_days, days),
        width, scale_pct, "muted")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }

    local rows = {
        { _("Window"), T(_("Last %1 days"), days) },
        { _("History span"), T(_("%1 of %2 days"), getObservedDays(snapshot), days) },
        { _("Books opened"), tostring(snapshot.book_count) },
        { _("Reading time"), T(_("%1 minutes"), snapshot.total_minutes) },
    }
    for _, row in ipairs(rows) do
        group[#group + 1] = textWidget(T(_("%1 · %2"), row[1], row[2]), width, scale_pct, "normal")
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
        addDivider(group, width)
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(7) }
    end
    group[#group + 1] = textWidget(_("MEASURE  ·  OBSERVED"), width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    for index, metric in ipairs(snapshot.metrics) do
        group[#group + 1] = textWidget(
            T(_("%1  ·  %2"), metric.label, metric.raw or metric.confidence_hint or _("Not available")),
            width, scale_pct, "normal")
        if show_scores and metric.score then
            group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
            group[#group + 1] = Kit.progressBar{
                width = math.max(50, width), height = Kit.sc(scale_pct)(4), fraction = metric.score / 100,
            }
            group[#group + 1] = textWidget(T(_("Score %1 / 100"), metric.score), width, scale_pct, "muted")
        end
        if index < #snapshot.metrics then
            group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(6) }
            addDivider(group, width)
            group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(6) }
        end
    end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) }
    group[#group + 1] = textWidget(
        T(_("%1 author credits · Finished books not tracked reliably"), snapshot.author_count),
        width, scale_pct, "muted")
    addTrend(group, snapshot, width, scale_pct, days)
    return group
end

local function renderBookSpines(book_count, width, scale_pct)
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local height = Kit.sc(scale_pct)(62)
    local spine_width = math.max(3, Kit.sc(scale_pct)(12))
    local gap = math.max(2, Kit.sc(scale_pct)(5))
    local count = math.min(book_count, 24, math.max(1, math.floor((width + gap) / (spine_width + gap))))
    local total_width = count * (spine_width + gap) - gap
    local WidgetClass = Widget:extend{}
    function WidgetClass:getSize() return Geom:new{ w = total_width, h = height } end
    function WidgetClass:paintTo(bb, x, y)
        for i = 1, count do
            local h = math.floor(height * (0.48 + ((i * 7) % 9) / 20))
            local sx = x + (i - 1) * (spine_width + gap)
            local sy = y + height - h
            bb:paintRect(sx, sy, spine_width, h, Kit.COLOR_PRIMARY)
            if spine_width > 2 and h > 3 then
                local fill = i % 3 == 0 and Kit.COLOR_MUTED or Kit.CARD_BG
                bb:paintRect(sx + 1, sy + 1, spine_width - 2, h - 2, fill)
            end
        end
    end
    return WidgetClass:new{}
end

local function renderFingerprint(snapshot, label, width, scale_pct, days, show_scores)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(_("Your reading fingerprint"), width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    group[#group + 1] = textWidget(label, width, scale_pct, "title")
    group[#group + 1] = textWidget(
        T(_("%1 active · %2 books · stats %3 / %4 days"),
            snapshot.active_days, snapshot.book_count, getObservedDays(snapshot), days),
        width, scale_pct, "normal")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) }
    group[#group + 1] = renderBookSpines(snapshot.book_count, width, scale_pct)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    group[#group + 1] = textWidget(T(_("%1 minutes read · %2 author credits"), snapshot.total_minutes, snapshot.author_count),
        width, scale_pct, "muted")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    renderMetricGrid(group, snapshot.metrics, width, scale_pct, show_scores)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    group[#group + 1] = textWidget(
        T(_("Coverage: %1 of %2 selected days"), getObservedDays(snapshot), days),
        width, scale_pct, "muted")
    addTrend(group, snapshot, width, scale_pct, days)
    return group
end

local function renderFullScreenLayout(layout, snapshot, label, width, scale_pct, days, show_scores)
    local renderers = {
        field_notes = renderFieldNotes,
        shelf_index = renderShelfIndex,
        fingerprint = renderFingerprint,
    }
    local ok, widget = pcall(renderers[layout] or renderFieldNotes,
        snapshot, label, width, scale_pct, days, show_scores)
    if ok and widget then return widget end
    require("logger").warn("[reading_dna] full-screen layout failed:", layout, widget)
    return Kit.valueCard{
        width = width, scale_pct = scale_pct,
        heading = _("Reading DNA"), value = _("Layout unavailable"),
        sub = _("Check the KOReader log or choose another layout."),
    }
end


local function render(ctx)
    local width, scale_pct = math.max(50, ctx.width or 200), ctx.scale or 100
    local days = getWindow(ctx)
    local show_scores = ctx.config:get("show_scores", true) ~= false
    local layout = getLayout(ctx)
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
    if snapshot.pending then
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("Analyzing…"),
            sub = _("Reading stats…"),
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
    local full = ctx.surface == "fullscreen"
    if full then
        return renderFullScreenLayout(layout, snapshot, label, width, scale_pct, days, show_scores)
    end
    local group = require("ui/widget/verticalgroup"):new{ align = "left" }
    local VerticalSpan = require("ui/widget/verticalspan")
    group[#group + 1] = renderProfileHeader(snapshot, label, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(16) }
    local visible_metrics = {}
    for _, metric in ipairs(snapshot.metrics) do visible_metrics[#visible_metrics + 1] = metric end
    table.sort(visible_metrics, function(a, b)
        if a.score == nil then return false end
        if b.score == nil then return true end
        return a.score > b.score
    end)
    local count = math.min(2, #visible_metrics)
    for i = 1, count do
        group[#group + 1] = renderMetric(visible_metrics[i], width, scale_pct, show_scores)
        if i < count then group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(12) } end
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
    -- Older builds wrote their choice to Bookshelf's own `layout` entry field.
    -- Move only our known values to a namespaced key, then release the host key.
    local legacy_layout = ctx.config:get("layout")
    if legacy_layout == "field_notes" or legacy_layout == "shelf_index" or legacy_layout == "fingerprint" then
        if ctx.config:get("reading_dna_layout") == nil then
            ctx.config:set("reading_dna_layout", legacy_layout)
        end
        ctx.config:delete("layout")
    end
    local current_layout = getLayout(ctx)
    local dialog
    local function updateSetting(name, value)
        return function()
            UIManager:close(dialog)
            ctx.config:set(name, value)
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            showSettings(ctx)
        end
    end
    local function chooseWindow(days)
        return function()
            UIManager:close(dialog)
            ctx.config:set("window_days", days)
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            startAnalysis(ctx, true)
            showSettings(ctx)
        end
    end
    local function chooseNight(window)
        return function()
            UIManager:close(dialog)
            ctx.config:set("night_window", window)
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            startAnalysis(ctx, true)
            showSettings(ctx)
        end
    end
    local function chooseLayout(layout)
        return function()
            UIManager:close(dialog)
            ctx.config:set("reading_dna_layout", layout)
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
            { { text = _("Full-screen layout"), enabled = false } },
            { { text = (current_layout == "field_notes" and "✓ " or "  ") .. _("Field Notes"), callback = chooseLayout("field_notes") } },
            { { text = (current_layout == "shelf_index" and "✓ " or "  ") .. _("Shelf Index"), callback = chooseLayout("shelf_index") } },
            { { text = (current_layout == "fingerprint" and "✓ " or "  ") .. _("Fingerprint"), callback = chooseLayout("fingerprint") } },
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
        startAnalysis(ctx, false)
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
        readEventsAsync = readEventsAsync,
        calculate = calculate,
    }
end

return module
