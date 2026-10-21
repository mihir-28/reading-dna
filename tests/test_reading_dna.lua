READING_DNA_TEST = true

package.preload["lib/bookshelf_i18n"] = function()
    return { gettext = function(text) return text end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
package.preload["lib/bookshelf_module_kit"] = function()
    return { moduleStore = function()
        return { get = function() end, set = function() end, delete = function() end }
    end }
end

local module = dofile("micromodules/reading_dna.lua")
local test = module._test
local passed = 0

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s",
        label, tostring(expected), tostring(actual)))
    passed = passed + 1
end

-- Empty and short histories remain bounded, deterministic inputs.
equal(#test.normalizeEvents({}), 0, "empty history")
local short = test.normalizeEvents({
    { book = "a", time = 1000, duration = 30, authors = "Ada Lovelace" },
    { book = "a", time = 1100, duration = 30, authors = "Ada Lovelace" },
})
equal(#short, 2, "short history event count")
equal(test.countAuthorCredits(short), 1, "short history author credits")

-- Overlaps are clipped in chronological order, including nested intervals.
local overlap = test.normalizeEvents({
    { book = "a", time = 1000, duration = 3600, authors = "A" },
    { book = "b", time = 2800, duration = 3600, authors = "B" },
    { book = "c", time = 3000, duration = 30, authors = "C" },
})
equal(#overlap, 2, "overlap event count")
equal(overlap[2].time, 4600, "overlap clipped start")
equal(overlap[2].duration, 1800, "overlap clipped duration")

-- Never split free-form author strings at commas; normalize case/spacing only.
equal(test.countAuthorCredits({
    { authors = "  Lovelace, Ada " },
    { authors = "lovelace,   ada" },
    { authors = "Ada Lovelace" },
    { authors = "N/A" },
}), 2, "ambiguous author metadata")

-- First event anchors eligibility to local calendar days, not 24-hour chunks.
local first_day = os.time({ year = 2026, month = 10, day = 20, hour = 23, min = 59, sec = 0 })
local now = os.time({ year = 2026, month = 10, day = 21, hour = 0, min = 1, sec = 0 })
local selected_start = os.time({ year = 2026, month = 10, day = 1, hour = 0, min = 0, sec = 0 })
equal(test.observedDayCount(now, selected_start, first_day, 30), 2, "local midnight boundary")
equal(test.localDateKey(first_day) ~= test.localDateKey(now), true, "local date boundary")

-- Query/schema failure returns a safe error and closes the read-only handle.
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/mock" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return "file" end }
end
local closed = false
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function()
        return {
            exec = function() end,
            prepare = function() error("no such table: page_stat_data") end,
            close = function() closed = true end,
        }
    end }
end
package.preload["logger"] = function()
    return { warn = function() end }
end
local result, err = test.readEvents(30, 21, 4)
equal(result, nil, "schema failure result")
equal(err, "query_error", "schema failure state")
equal(closed, true, "database handle closed")

print(string.format("Reading DNA: %d regression checks passed", passed))
