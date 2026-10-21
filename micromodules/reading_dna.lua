-- Reading DNA: an offline reading-pattern summary for Bookshelf.
-- Copyright (C) 2026 Reading DNA contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local Kit = require("lib/bookshelf_module_kit")

local MODULE_KEY = "reading_dna"
local MODULE_VERSION = "0.4.0"
local PROFILE_SCHEMA_VERSION = "0.4"
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

local function longestActiveStreak(dates)
    if #dates == 0 then return 0 end
    table.sort(dates)
    local longest, current = 1, 1
    for index = 2, #dates do
        local year, month, day = dates[index - 1]:match("(%d+)-(%d+)-(%d+)")
        local parts = { year = tonumber(year), month = tonumber(month), day = tonumber(day) }
        parts.hour, parts.min, parts.sec = 12, 0, 0
        parts.day = parts.day + 1
        if localDateKey(os.time(parts)) == dates[index] then
            current = current + 1
        else
            longest = math.max(longest, current)
            current = 1
        end
    end
    return math.max(longest, current)
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
    if #events == 0 then
        return { empty = true, days = days, analyzed_at = result.now, profile_schema = PROFILE_SCHEMA_VERSION }
    end

    local day_totals, books, weekend_dates = {}, {}, {}
    local active_days, total_seconds, late_seconds, weekend_seconds = 0, 0, 0, 0
    for _, event in ipairs(events) do
        local date = localDateKey(event.time)
        day_totals[date] = day_totals[date] or {}
        day_totals[date][event.book] = (day_totals[date][event.book] or 0) + event.duration
        total_seconds = total_seconds + event.duration
        late_seconds = late_seconds + nightFraction(event.time, event.duration, night_start, night_end)
        local weekday = os.date("*t", event.time).wday
        if weekday == 1 or weekday == 7 then
            weekend_seconds = weekend_seconds + event.duration
            weekend_dates[date] = true
        end
    end

    local focused_days = 0
    for _, by_book in pairs(day_totals) do
        active_days = active_days + 1
        local day_total, day_max = 0, 0
        for _, seconds in pairs(by_book) do
            day_total = day_total + seconds
            day_max = math.max(day_max, seconds)
        end
        if day_total > 0 and day_max / day_total >= 0.6 then focused_days = focused_days + 1 end
    end

    local sessions, session_lengths, switches = sessionize(events)
    local observed_days = observedDayCount(result.now, result.window_start, result.first_event, days)
    local regularity_pct = math.floor(100 * active_days / observed_days + 0.5)
    local median_session = median(session_lengths)
    local active_dates = {}
    for date in pairs(day_totals) do active_dates[#active_dates + 1] = date end
    local longest_streak = longestActiveStreak(active_dates)
    local book_count = 0
    for _, event in ipairs(raw_events) do books[event.book] = true end
    for _ in pairs(books) do book_count = book_count + 1 end
    local author_count = countAuthorCredits(raw_events)
    local weekend_active_days = 0
    for _ in pairs(weekend_dates) do weekend_active_days = weekend_active_days + 1 end
    local night_pct = total_seconds > 0 and math.floor(100 * late_seconds / total_seconds + 0.5) or 0
    local weekend_pct = total_seconds > 0 and math.floor(100 * weekend_seconds / total_seconds + 0.5) or 0
    local switch_denominator = math.max(0, #sessions - 1)
    local switch_pct = switch_denominator > 0
        and math.floor(100 * switches / switch_denominator + 0.5) or 0
    local focus_pct = active_days > 0 and math.floor(100 * focused_days / active_days + 0.5) or 0
    local switch_raw = switch_denominator > 0
        and T(_("%1 of %2 session transitions · %3%"), switches, switch_denominator, switch_pct)
        or _("No session transitions yet")
    local night_window = T(_("%1:00–%2:00"), string.format("%02d", night_start), string.format("%02d", night_end))
    local metrics = {
        { key = "consistency", label = _("Reading regularity"),
            raw = T(_("%1 of %2 history days · %3%"), active_days, observed_days, regularity_pct),
            detail = _("History span starts at first recorded event; gaps count as non-reading days."),
            sample = observed_days, available = active_days >= 3 and total_seconds >= 30 * 60,
            confidence_hint = active_days < 3 and _("Need 3 active days") or _("Need 30 minutes recorded") },
        { key = "depth", label = _("Session length"),
            raw = median_session and T(_("%1 min median"), math.floor(median_session / 60 + 0.5)) or _("Not enough sessions"),
            detail = T(_("%1 valid sessions · split after 20 min idle"), #sessions),
            sample = #sessions, available = #sessions >= 3, confidence_hint = _("Need 3 valid sessions") },
        { key = "loyalty", label = _("Focused days"),
            raw = T(_("%1 of %2 reading days · %3%"), focused_days, active_days, focus_pct),
            detail = _("One book held at least 60% of that day’s recorded time."), sample = active_days,
            available = active_days >= 5, confidence_hint = _("Need 5 reading days") },
        { key = "exploration", label = _("Reading breadth"),
            raw = T(_("%1 titles · %2 author metadata entries"), book_count, author_count),
            detail = _("Author entries are distinct stored metadata strings, not verified people."),
            sample = book_count, available = book_count >= 3, confidence_hint = _("Need 3 titles") },
        { key = "night", label = _("Night-time share"),
            raw = T(_("%1% of reading time · %2"), night_pct, night_window),
            detail = _("Share inside selected device-local hours; not a quality score."),
            sample = math.floor(total_seconds / 60), available = total_seconds >= 60 * 60,
            confidence_hint = _("Need 60 minutes recorded") },
        { key = "switching", label = _("Book changes"),
            raw = switch_raw,
            detail = _("Different books across adjacent valid sessions."), sample = #sessions,
            available = #sessions >= 4, confidence_hint = _("Need 4 valid sessions") },
        { key = "streak", label = _("Longest reading streak"),
            raw = T(_("%1 consecutive days"), longest_streak),
            detail = _("Consecutive local calendar days with recorded reading."), sample = active_days,
            available = active_days >= 3, confidence_hint = _("Need 3 reading days") },
        { key = "weekend", label = _("Weekend reading"),
            raw = T(_("%1% of time · %2 weekend days"), weekend_pct, weekend_active_days),
            detail = _("Share of recorded time on Saturday and Sunday, using device-local dates."),
            sample = weekend_active_days, available = weekend_active_days >= 4,
            confidence_hint = _("Need 4 weekend reading days") },
    }

    local evidence = active_days >= MIN_ACTIVE_DAYS and total_seconds >= MIN_TOTAL_SECONDS
    local archetypes = {}
    local function addArchetype(name)
        archetypes[#archetypes + 1] = name
    end
    if evidence then
        if regularity_pct >= 35 then addArchetype(_("Steady Reader")) end
        if median_session and median_session >= 30 * 60 and #sessions >= 3 then
            addArchetype(_("Long-session Reader"))
        elseif median_session and median_session <= 15 * 60 and #sessions >= 5 then
            addArchetype(_("Short-session Reader"))
        end
        if active_days >= 5 and focus_pct >= 60 then addArchetype(_("Focused Reader")) end
        if book_count >= 8 then addArchetype(_("Wide-ranging Reader")) end
        if total_seconds >= 3 * 60 * 60 and night_pct >= 40 then addArchetype(_("Night Reader")) end
        if #sessions >= 4 and switch_pct >= 40 then addArchetype(_("Book-switching Reader")) end
        if longest_streak >= 5 then addArchetype(_("Streak Builder")) end
        if weekend_active_days >= 4 and weekend_pct >= 50 then addArchetype(_("Weekend Reader")) end
    end
    if #archetypes == 0 then archetypes[1] = evidence and _("Mixed Reader") or _("Building a pattern") end

    return {
        empty = false,
        days = days,
        analyzed_at = result.now,
        coverage_start = result.first_event
            and math.max(result.first_event, result.window_start or result.first_event)
            or result.window_start,
        active_days = active_days,
        observed_days = observed_days,
        total_minutes = math.floor(total_seconds / 60),
        book_count = book_count,
        author_count = author_count,
        evidence = evidence,
        archetype = archetypes[1],
        archetypes = archetypes,
        profile_schema = PROFILE_SCHEMA_VERSION,
        metrics = metrics,
        longest_streak = longest_streak,
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
    store:set("snapshot", { pending = true, days = days, profile_schema = PROFILE_SCHEMA_VERSION })
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
    if type(snapshot) == "table" and snapshot.days == days
            and (snapshot.pending or snapshot.error or snapshot.profile_schema == PROFILE_SCHEMA_VERSION) then
        return snapshot
    end
    return nil
end

local function textWidget(text, width, scale_pct, role)
    local TextWidget = require("lib/bookshelf_colour_text")
    local opts = (role == "title" or role == "display" or role == "value"
        or role == "metric_value" or role == "lead") and { bold = true } or nil
    local size = role == "display" and 42 or (role == "lead" and 38
        or (role == "metric_value" and 21 or (role == "title" and 24 or (role == "value" and 17 or 13))))
    local face, bold = Kit.face(size, scale_pct, opts)
    return TextWidget:new{
        text = text,
        face = face,
        bold = bold,
        fgcolor = (role == "muted" or role == "label") and Kit.COLOR_MUTED or Kit.COLOR_PRIMARY,
        max_width = width,
    }
end

local function renderMetric(metric, width, scale_pct)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(metric.label, width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(2) }
    group[#group + 1] = textWidget(metric.raw or _("No reading data"), width, scale_pct, "value")
    if metric.detail then group[#group + 1] = textWidget(metric.detail, width, scale_pct, "muted") end
    if not metric.available and metric.confidence_hint then
        group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(2) }
        group[#group + 1] = textWidget(T(_("Provisional · %1"), metric.confidence_hint), width, scale_pct, "muted")
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

local function getCoverageText(snapshot)
    if snapshot.coverage_start then
        return T(_("%1 days · %2—%3"), getObservedDays(snapshot),
            os.date("%b %d", snapshot.coverage_start), os.date("%b %d, %Y", snapshot.analyzed_at))
    end
    return T(_("%1 observed days"), getObservedDays(snapshot))
end

local function getTraitSummary(snapshot)
    if not snapshot.evidence then
        return T(_("Building a pattern · needs %1 active days and 5 hours."), MIN_ACTIVE_DAYS)
    end
    local traits = snapshot.archetypes or {}
    if #traits == 1 and traits[1] == _("Mixed Reader") then
        return _("No single reading pattern stands out yet.")
    end
    if #traits > 0 then return T(_("Patterns: %1"), table.concat(traits, " · ")) end
    return _("No reading patterns available yet.")
end

local function renderLeadStat(value, label, width, scale_pct)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(value, width, scale_pct, "lead")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(3) }
    group[#group + 1] = textWidget(label, width, scale_pct, "muted")
    return group
end

local function renderReadingNote(metric, label, note, width, scale_pct, value_override)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = textWidget(label, width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(2) }
    group[#group + 1] = textWidget(value_override or (metric and metric.raw or _("No reading data")), width, scale_pct, "metric_value")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(2) }
    group[#group + 1] = textWidget((metric and metric.detail) or note, width, scale_pct, "muted")
    if metric and not metric.available and metric.confidence_hint then
        group[#group + 1] = textWidget(T(_("Provisional · %1"), metric.confidence_hint),
            width, scale_pct, "muted")
    end
    return group
end

local function frameWidget(child, scale_pct, target_width)
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local pad, stroke = Kit.sc(scale_pct)(6), math.max(1, Kit.sc(scale_pct)(1))
    local child_size = child:getSize()
    local width, height = math.max(child_size.w + pad * 2, target_width or 0), child_size.h + pad * 2
    local FrameWidget = Widget:extend{}
    function FrameWidget:getSize() return Geom:new{ w = width, h = height } end
    function FrameWidget:paintTo(bb, x, y)
        bb:paintRect(x, y, width, stroke, Kit.COLOR_MUTED)
        bb:paintRect(x, y + height - stroke, width, stroke, Kit.COLOR_MUTED)
        bb:paintRect(x, y, stroke, height, Kit.COLOR_MUTED)
        bb:paintRect(x + width - stroke, y, stroke, height, Kit.COLOR_MUTED)
        child:paintTo(bb, x + pad, y + pad)
    end
    return FrameWidget:new{}
end

local function renderMeasureTile(metric, title, width, scale_pct, target_width)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local content = VerticalGroup:new{ align = "left" }
    content[#content + 1] = textWidget(title or metric.label, width, scale_pct, "label")
    content[#content + 1] = textWidget(metric.raw or _("No reading data"), width, scale_pct, "metric_value")
    content[#content + 1] = textWidget(metric.detail or "", width, scale_pct, "muted")
    if not metric.available and metric.confidence_hint then
        content[#content + 1] = textWidget(T(_("Provisional · %1"), metric.confidence_hint),
            width, scale_pct, "muted")
    end
    return frameWidget(content, scale_pct, target_width or (width + Kit.sc(scale_pct)(12)))
end

local function renderBarcode(width, scale_pct)
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local height = Kit.sc(scale_pct)(28)
    local pattern = { 2, 1, 3, 1, 1, 2, 1, 3, 2, 1, 1, 2, 3, 1, 2, 1, 3, 1, 1, 2, 2, 1 }
    local modules = 0
    for i = 1, #pattern do modules = modules + pattern[i] end
    local unit = math.max(1, math.floor(width / modules))
    local BarcodeWidget = Widget:extend{}
    function BarcodeWidget:getSize() return Geom:new{ w = unit * modules, h = height } end
    function BarcodeWidget:paintTo(bb, x, y)
        local offset = 0
        for i = 1, #pattern do
            if i % 2 == 1 then bb:paintRect(x + offset, y, pattern[i] * unit, height, Kit.COLOR_PRIMARY) end
            offset = offset + pattern[i] * unit
        end
    end
    return BarcodeWidget:new{}
end

local function addTrend(group, snapshot, width, scale_pct, days)
    if not snapshot.trend then return end
    local VerticalSpan = require("ui/widget/verticalspan")
    local signed = function(value)
        return value > 0 and ("+" .. value) or tostring(value)
    end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(10) }
    group[#group + 1] = textWidget(
        T(_("Vs previous %1-day window: %2 reading days · %3 min"), days,
            signed(snapshot.trend.days), signed(snapshot.trend.minutes)),
        width, scale_pct, "muted")
end

local function renderFieldNotes(snapshot, label, width, scale_pct, days, show_traits)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local group = VerticalGroup:new{ align = "left" }
    local observed_days = getObservedDays(snapshot)
    local masthead = HorizontalGroup:new{ align = "center",
        textWidget(T(_("READING DNA  /  %1"), os.date("%Y", snapshot.analyzed_at)), width * 0.78, scale_pct, "label"),
        frameWidget(textWidget("R", Kit.sc(scale_pct)(32), scale_pct, "title"), scale_pct),
    }
    group[#group + 1] = masthead
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    group[#group + 1] = textWidget(label, width, scale_pct, "display")
    group[#group + 1] = textWidget(
        _("A descriptive profile based on recorded reading activity."), width, scale_pct, "muted")
    local trait_summary = show_traits and getTraitSummary(snapshot) or nil
    if trait_summary then group[#group + 1] = textWidget(trait_summary, width, scale_pct, "muted") end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(10) }
    group[#group + 1] = textWidget(T(_("Selected window: %1 days"), days), width, scale_pct, "label")
    group[#group + 1] = textWidget(T(_("Recorded-history span: %1"), getCoverageText(snapshot)),
        width, scale_pct, "normal")
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }

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
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    group[#group + 1] = textWidget(_("READING PATTERNS"), width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(6) }
    local note_gap = Kit.sc(scale_pct)(18)
    local note_width = math.max(1, math.floor((width - note_gap) / 2))
    local depth = metricByKey(snapshot, "depth")
    local loyalty = metricByKey(snapshot, "loyalty")
    local night = metricByKey(snapshot, "night")
    local switching = metricByKey(snapshot, "switching")
    local streak = metricByKey(snapshot, "streak")
    local weekend = metricByKey(snapshot, "weekend")
    local notes = {
        { metricByKey(snapshot, "consistency"), _("Reading regularity") },
        { depth, _("Session length") },
        { loyalty, _("Focused days") },
        { metricByKey(snapshot, "exploration"), _("Reading breadth") },
        { night, _("Night-time share") },
        { switching, _("Book changes") },
        { streak, _("Longest reading streak") },
        { weekend, _("Weekend reading") },
    }
    for index = 1, #notes, 2 do
        local left, right = notes[index], notes[index + 1]
        group[#group + 1] = HorizontalGroup:new{ align = "top",
            renderReadingNote(left[1], left[2], left[3], note_width, scale_pct),
            HorizontalSpan:new{ width = note_gap },
            right and renderReadingNote(right[1], right[2], right[3], note_width, scale_pct)
                or HorizontalSpan:new{ width = note_width },
        }
        if index + 1 < #notes then group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) } end
    end
    addTrend(group, snapshot, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    local coverage_note = VerticalGroup:new{ align = "left",
        textWidget(
        T(_("History span: %1 days within the selected %2-day window."), observed_days, days),
        width - Kit.sc(scale_pct)(12), scale_pct, "muted"),
        textWidget(_("Finished books are not tracked reliably."), width - Kit.sc(scale_pct)(12), scale_pct, "muted"),
    }
    group[#group + 1] = frameWidget(coverage_note, scale_pct, width)
    return group
end

local function renderShelfIndex(snapshot, label, width, scale_pct, days, show_traits)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local group = VerticalGroup:new{ align = "left" }
    local header_gap = Kit.sc(scale_pct)(12)
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        textWidget(_("KOREADER  /  READING RECORD"), width - header_gap - 45, scale_pct, "label"),
        HorizontalSpan:new{ width = header_gap },
        textWidget(_("NO. 01"), 45, scale_pct, "label"),
    }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    group[#group + 1] = textWidget(label, width, scale_pct, "display")
    group[#group + 1] = textWidget(
        _("Profile classification · descriptive, not diagnostic"),
        width, scale_pct, "muted")
    local trait_summary = show_traits and getTraitSummary(snapshot) or nil
    if trait_summary then group[#group + 1] = textWidget(trait_summary, width, scale_pct, "muted") end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    local coverage = VerticalGroup:new{ align = "left",
        textWidget(_("RECORDED-HISTORY SPAN"), width - Kit.sc(scale_pct)(120), scale_pct, "label"),
        textWidget(T(_("%1 within %2 selected days"), getCoverageText(snapshot), days),
            width - Kit.sc(scale_pct)(120), scale_pct, "normal"),
    }
    local cover_row = HorizontalGroup:new{ align = "center",
        coverage,
        HorizontalSpan:new{ width = Kit.sc(scale_pct)(8) },
        textWidget(snapshot.evidence and _("EVIDENCE MET") or _("PROVISIONAL"),
            Kit.sc(scale_pct)(88), scale_pct, "label"),
    }
    group[#group + 1] = frameWidget(cover_row, scale_pct, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    local triptych_gap = Kit.sc(scale_pct)(10)
    local triptych_width = math.max(1, math.floor((width - 2 * triptych_gap) / 3))
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        renderLeadStat(T(_("%1/%2"), snapshot.active_days, getObservedDays(snapshot)),
            _("Days read"), triptych_width, scale_pct),
        HorizontalSpan:new{ width = triptych_gap },
        renderLeadStat(tostring(snapshot.book_count), _("Books"), triptych_width, scale_pct),
        HorizontalSpan:new{ width = triptych_gap },
        renderLeadStat(tostring(snapshot.total_minutes), _("Minutes"), triptych_width, scale_pct),
    }
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(6) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    group[#group + 1] = textWidget(_("MEASURE  ·  OBSERVED"), width, scale_pct, "label")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(5) }
    local ledger = {
        { metricByKey(snapshot, "consistency"), _("READING REGULARITY") },
        { metricByKey(snapshot, "depth"), _("SESSION LENGTH") },
        { metricByKey(snapshot, "loyalty"), _("FOCUSED DAYS") },
        { metricByKey(snapshot, "exploration"), _("READING BREADTH") },
        { metricByKey(snapshot, "night"), _("NIGHT-TIME SHARE") },
        { metricByKey(snapshot, "switching"), _("BOOK CHANGES") },
        { metricByKey(snapshot, "streak"), _("LONGEST STREAK") },
        { metricByKey(snapshot, "weekend"), _("WEEKEND READING") },
    }
    for index = 1, #ledger do
        local metric = ledger[index][1]
        local raw = metric and metric.raw or _("Not available")
        local value = VerticalGroup:new{ align = "left",
            textWidget(raw, width * 0.52, scale_pct, "metric_value"),
            metric and textWidget(metric.detail, width * 0.52, scale_pct, "muted")
                or textWidget(_("No metric data"), width * 0.52, scale_pct, "muted"),
        }
        if metric and not metric.available and metric.confidence_hint then
            value[#value + 1] = textWidget(T(_("Provisional · %1"), metric.confidence_hint),
                width * 0.52, scale_pct, "muted")
        end
        local row = HorizontalGroup:new{ align = "center",
            textWidget(ledger[index][2], width * 0.42, scale_pct, "label"),
            HorizontalSpan:new{ width = Kit.sc(scale_pct)(8) },
            value,
        }
        group[#group + 1] = row
        addDivider(group, width)
    end
    addTrend(group, snapshot, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(7) }
    local foot_width = math.max(1, width - Kit.sc(scale_pct)(120))
    local foot = VerticalGroup:new{ align = "left",
        textWidget(snapshot.evidence and _("* Enough data for pattern labels.") or _("* Profile remains provisional."),
            foot_width, scale_pct, "muted"),
        textWidget(_("Finished books not tracked reliably."), foot_width, scale_pct, "muted"),
    }
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        foot,
        HorizontalSpan:new{ width = Kit.sc(scale_pct)(8) },
        renderBarcode(Kit.sc(scale_pct)(100), scale_pct),
    }
    return group
end

local function renderBookSpines(book_count, width, scale_pct)
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local height = Kit.sc(scale_pct)(100)
    local shelf_height = Kit.sc(scale_pct)(4)
    local count = math.max(1, math.min(tonumber(book_count) or 0, 24))
    local gap = math.max(2, Kit.sc(scale_pct)(5))
    local spine_heights = {}
    for i = 1, count do
        spine_heights[i] = math.random(46, 75) / 100
    end
    local WidgetClass = Widget:extend{}
    function WidgetClass:getSize() return Geom:new{ w = width, h = height } end
    function WidgetClass:paintTo(bb, x, y)
        for i = 1, count do
            local slot_x = math.floor((i - 1) * width / count)
            local slot_end = math.floor(i * width / count)
            local spine_width = math.max(1, slot_end - slot_x - gap)
            local h = math.floor((height - shelf_height) * spine_heights[i])
            local sx = x + slot_x
            local sy = y + height - shelf_height - h
            bb:paintRect(sx, sy, spine_width, h, Kit.COLOR_PRIMARY)
            if spine_width > 2 and h > 3 then
                local fill = i % 3 == 0 and Kit.COLOR_MUTED or Kit.CARD_BG
                bb:paintRect(sx + 1, sy + 1, spine_width - 2, h - 2, fill)
            end
        end
        bb:paintRect(x, y + height - shelf_height, width, shelf_height, Kit.COLOR_PRIMARY)
    end
    return WidgetClass:new{}
end

local function renderFingerprint(snapshot, label, width, scale_pct, days, show_traits)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local group = VerticalGroup:new{ align = "left" }
    local header_gap = Kit.sc(scale_pct)(10)
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        textWidget(_("YOUR READING FINGERPRINT"), width - header_gap - 55, scale_pct, "label"),
        HorizontalSpan:new{ width = header_gap },
        textWidget(T(_("%1d"), days), 55, scale_pct, "label"),
    }
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(4) }
    group[#group + 1] = textWidget(label, width, scale_pct, "display")
    local trait_summary = show_traits and getTraitSummary(snapshot) or nil
    if trait_summary then group[#group + 1] = textWidget(trait_summary, width, scale_pct, "muted") end
    group[#group + 1] = textWidget(
        T(_("%1 reading days · history %2"), snapshot.active_days, getCoverageText(snapshot)),
        width, scale_pct, "normal")
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(8) }
    group[#group + 1] = renderBookSpines(snapshot.book_count, width, scale_pct)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(4) }
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        textWidget(T(_("%1 books opened"), snapshot.book_count), width * 0.48, scale_pct, "muted"),
        HorizontalSpan:new{ width = header_gap },
        textWidget(T(_("%1 min recorded"), snapshot.total_minutes), width * 0.48, scale_pct, "muted"),
    }
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(9) }
    addDivider(group, width)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(7) }
    local tile_gap = Kit.sc(scale_pct)(10)
    local tile_width = math.max(1, math.floor((width - tile_gap) / 2))
    local tile_inner = math.max(1, tile_width - Kit.sc(scale_pct)(12))
    local tile_titles = {
        _("Reading regularity"), _("Session length"), _("Focused days"),
        _("Reading breadth"), _("Night-time share"), _("Book changes"),
        _("Longest reading streak"), _("Weekend reading"),
    }
    for index = 1, #snapshot.metrics, 2 do
        local left = renderMeasureTile(snapshot.metrics[index], tile_titles[index], tile_inner, scale_pct, tile_width)
        local right = snapshot.metrics[index + 1]
            and renderMeasureTile(snapshot.metrics[index + 1], tile_titles[index + 1], tile_inner, scale_pct, tile_width)
            or HorizontalSpan:new{ width = tile_width }
        group[#group + 1] = HorizontalGroup:new{ align = "top",
            left,
            HorizontalSpan:new{ width = tile_gap },
            right,
        }
        if index + 1 < #snapshot.metrics then group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(7) } end
    end
    addTrend(group, snapshot, width, scale_pct, days)
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(7) }
    group[#group + 1] = HorizontalGroup:new{ align = "top",
        textWidget(T(_("Coverage: %1 of %2 days"), getObservedDays(snapshot), days), width * 0.56, scale_pct, "muted"),
        HorizontalSpan:new{ width = header_gap },
        textWidget(T(_("PROFILE  ·  %1"), label), width * 0.42, scale_pct, "label"),
    }
    return group
end

local function renderFullScreenLayout(layout, snapshot, label, width, scale_pct, days, show_traits)
    local renderers = {
        field_notes = renderFieldNotes,
        shelf_index = renderShelfIndex,
        fingerprint = renderFingerprint,
    }
    local ok, widget = pcall(renderers[layout] or renderFieldNotes,
        snapshot, label, width, scale_pct, days, show_traits)
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
    local show_traits = ctx.config:get("show_archetype", true) ~= false
    local layout = getLayout(ctx)
    _refresh = ctx.refresh

    if ctx.preview then
        return Kit.valueCard{
            width = width, scale_pct = scale_pct,
            heading = _("Reading DNA"), value = _("Reading profile"),
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

    local label = _("Reading profile")
    local full = ctx.surface == "fullscreen"
    if full then
        return renderFullScreenLayout(layout, snapshot, label, width, scale_pct, days, show_traits)
    end
    local group = require("ui/widget/verticalgroup"):new{ align = "left" }
    local VerticalSpan = require("ui/widget/verticalspan")
    group[#group + 1] = renderProfileHeader(snapshot, label, width, scale_pct, days)
    local trait_summary = show_traits and getTraitSummary(snapshot) or nil
    if trait_summary then group[#group + 1] = textWidget(trait_summary, width, scale_pct, "muted") end
    group[#group + 1] = VerticalSpan:new{ width = Kit.sc(scale_pct)(16) }
    local visible_metrics = {}
    local metric_order = {}
    for index, metric in ipairs(snapshot.metrics) do
        metric_order[metric.key] = index
        visible_metrics[#visible_metrics + 1] = metric
    end
    table.sort(visible_metrics, function(a, b)
        if a.available ~= b.available then return a.available end
        return metric_order[a.key] < metric_order[b.key]
    end)
    local count = math.min(2, #visible_metrics)
    for i = 1, count do
        group[#group + 1] = renderMetric(visible_metrics[i], width, scale_pct)
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
            { { text = (show_archetype and "✓ " or "  ") .. _("Show reader traits"), callback = updateSetting("show_archetype", not show_archetype) } },
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
