--[[
Reading Streak in the reader status bar

Shows the current streak from advokatb's readingstreak.koplugin
(https://github.com/advokatb/readingstreak.koplugin) at the end of
KOReader's reading status bar (the footer), e.g.

    ⚡ 12 days
    ⚡ 3 weeks
    ⚡ 12 days | 3 weeks

Choose what to show in KOReader:
    Settings (cog) > Status bar > Reading streak
        Daily streak / Weekly streak / Daily + weekly / Hidden

This is a plain KOReader user patch, NOT a Project: Title patch. The reader
status bar belongs to KOReader core (ReaderFooter), so it does not go through
userpatch.registerPatchPluginFunc("projecttitle", ...).

Install: put this file in koreader/patches/ and restart KOReader.

Requirements:
  * readingstreak.koplugin installed and enabled
    (https://github.com/advokatb/readingstreak.koplugin)
  * Tools > Reading Streak > Settings > UI Integration > "Export to Project Title"
    turned on (required: the plugin only publishes its data to PluginShare when
    this is on, and the patch shows nothing without it)

Data sources:
  * Daily streak: PluginShare.readingstreak (current_streak, getStreakText),
    which the plugin's own Project: Title integration reads.
  * Weekly streak: uses a weekly field from PluginShare.readingstreak if the
    plugin publishes one (see WEEK_FIELDS below). If not, it is calculated from
    the reading dates saved in reading_streak.lua. In testing, this matched the
    plugin's own weekly streak (see README for edge cases).
--]]

local logger = require("logger")
local PluginShare = require("pluginshare")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ReaderFooter = require("apps/reader/modules/readerfooter")
local _ = require("gettext")

---------------------------------------------------------------------------
-- Options you may want to change
---------------------------------------------------------------------------
local SYMBOL = "⚡"              -- set to "" for text only
local SEPARATOR = " | "           -- between daily and weekly when showing both
local SHOW_WHEN_ZERO = false      -- show the streak even when it is 0
local DEFAULT_MODE = "daily"      -- "daily", "weekly", "both" or "off"
local WEEK_STARTS_ON_MONDAY = true -- false = weeks start on Sunday
local CACHE_SECONDS = 60          -- how long the calculated weekly streak is cached

-- Possible names the plugin might use for a weekly streak in PluginShare.
-- The first one that holds a number is used.
local WEEK_FIELDS = {
    "current_week_streak",
    "current_weekly_streak",
    "weekly_streak",
    "week_streak",
}

local SETTING_KEY = "footer_reading_streak_mode"
local DATE_PATTERN = "^(%d%d%d%d)%-(%d%d)%-(%d%d)$"

---------------------------------------------------------------------------
-- Mode setting (stored in KOReader's global settings)
---------------------------------------------------------------------------
local VALID_MODES = { daily = true, weekly = true, both = true, off = true }

local function getMode()
    local mode = G_reader_settings and G_reader_settings:readSetting(SETTING_KEY)
    if VALID_MODES[mode] then
        return mode
    end
    return DEFAULT_MODE
end

local function setMode(mode)
    if VALID_MODES[mode] and G_reader_settings then
        G_reader_settings:saveSetting(SETTING_KEY, mode)
    end
end

---------------------------------------------------------------------------
-- Calendar helpers (pure arithmetic, no timezone surprises)
---------------------------------------------------------------------------
-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm)
local function daysFromCivil(y, m, d)
    if m <= 2 then
        y = y - 1
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- 1970-01-01 was a Thursday
local function weekIndex(days)
    local offset = WEEK_STARTS_ON_MONDAY and 3 or 4
    return math.floor((days + offset) / 7)
end

---------------------------------------------------------------------------
-- Daily streak (from the plugin)
---------------------------------------------------------------------------
local function getDailyText()
    local rs = PluginShare.readingstreak
    if not rs then
        return nil
    end

    local streak = rs.current_streak or 0
    if streak <= 0 and not SHOW_WHEN_ZERO then
        return nil
    end

    if type(rs.getStreakText) == "function" then
        local ok, result = pcall(rs.getStreakText)
        if ok and result then
            return tostring(result)
        end
    end
    return tostring(streak) .. (streak == 1 and " day" or " days")
end

---------------------------------------------------------------------------
-- Weekly streak
---------------------------------------------------------------------------
local week_cache = { time = nil, value = nil }

-- Collect anything that looks like a YYYY-MM-DD date, as a key (with a truthy
-- value) or as a value, anywhere in the plugin's saved data.
local function collectDates(tbl, out, depth)
    if depth > 3 then
        return
    end
    for k, v in pairs(tbl) do
        if type(k) == "string" and v and k:match(DATE_PATTERN) then
            out[k] = true
        end
        if type(v) == "string" and v:match(DATE_PATTERN) then
            out[v] = true
        elseif type(v) == "table" then
            collectDates(v, out, depth + 1)
        end
    end
end

local function computeWeeklyStreak()
    local now = os.time()
    if week_cache.time and (now - week_cache.time) < CACHE_SECONDS then
        return week_cache.value
    end

    local ok, result = pcall(function()
        local path = DataStorage:getSettingsDir() .. "/reading_streak.lua"
        local store = LuaSettings:open(path)
        local dates = {}
        collectDates(store.data or {}, dates, 0)

        local weeks = {}
        for date in pairs(dates) do
            local y, m, d = date:match(DATE_PATTERN)
            weeks[weekIndex(daysFromCivil(tonumber(y), tonumber(m), tonumber(d)))] = true
        end

        local t = os.date("*t")
        local w = weekIndex(daysFromCivil(t.year, t.month, t.day))
        -- If you haven't read yet this week, the streak is still alive
        -- until the week ends, so start counting from last week.
        if not weeks[w] then
            w = w - 1
        end
        local count = 0
        while weeks[w] do
            count = count + 1
            w = w - 1
        end
        return count
    end)

    if not ok then
        logger.warn("reader-footer-streak: weekly calculation failed", tostring(result))
        return nil
    end

    week_cache.time = now
    week_cache.value = result
    return result
end

local function getWeeklyStreak()
    local rs = PluginShare.readingstreak
    if rs then
        for _, field in ipairs(WEEK_FIELDS) do
            if type(rs[field]) == "number" then
                return rs[field]
            end
        end
    end
    return computeWeeklyStreak()
end

local function getWeeklyText()
    local weeks = getWeeklyStreak()
    if not weeks then
        return nil
    end
    if weeks <= 0 and not SHOW_WHEN_ZERO then
        return nil
    end
    return tostring(weeks) .. (weeks == 1 and " week" or " weeks")
end

---------------------------------------------------------------------------
-- Footer text
---------------------------------------------------------------------------
local keys_logged = false

local function logPluginKeysOnce()
    if keys_logged then
        return
    end
    local rs = PluginShare.readingstreak
    if not rs then
        return
    end
    keys_logged = true
    local keys = {}
    for k in pairs(rs) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    logger.info("reader-footer-streak: PluginShare.readingstreak keys: " .. table.concat(keys, ", "))
end

local function buildFooterText()
    local mode = getMode()
    if mode == "off" then
        return nil
    end

    logPluginKeysOnce()

    local parts = {}
    if mode == "daily" or mode == "both" then
        local text = getDailyText()
        if text then
            parts[#parts + 1] = text
        end
    end
    if mode == "weekly" or mode == "both" then
        local text = getWeeklyText()
        if text then
            parts[#parts + 1] = text
        end
    end
    if #parts == 0 then
        return nil
    end

    local text = table.concat(parts, SEPARATOR)
    if SYMBOL ~= "" then
        text = SYMBOL .. " " .. text
    end
    return text
end

---------------------------------------------------------------------------
-- Hook 1: add the text to the reading status bar
---------------------------------------------------------------------------
local orig_init = ReaderFooter.init

ReaderFooter.init = function(self, ...)
    orig_init(self, ...)

    if type(self.addAdditionalFooterContent) ~= "function" then
        logger.warn("reader-footer-streak: ReaderFooter:addAdditionalFooterContent not found in this KOReader version")
        return
    end

    self:addAdditionalFooterContent(function()
        local ok, result = pcall(buildFooterText)
        if not ok then
            logger.warn("reader-footer-streak: error building text", tostring(result))
            return nil
        end
        if result == nil and not PluginShare.readingstreak and not self._streak_warned then
            self._streak_warned = true
            logger.info("reader-footer-streak: PluginShare.readingstreak is nil (plugin not loaded or export disabled)")
        end
        return result
    end)
end

---------------------------------------------------------------------------
-- Hook 2: add "Reading streak" to Settings > Status bar
---------------------------------------------------------------------------
local orig_addToMainMenu = ReaderFooter.addToMainMenu

ReaderFooter.addToMainMenu = function(self, menu_items, ...)
    orig_addToMainMenu(self, menu_items, ...)

    local status_bar = menu_items and menu_items.status_bar
    if not (status_bar and type(status_bar.sub_item_table) == "table") then
        logger.warn("reader-footer-streak: could not find the Status bar menu, no menu option added")
        return
    end

    local function refresh()
        pcall(function()
            self:onUpdateFooter(true)
        end)
    end

    local function radio(label, mode)
        return {
            text = label,
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                return getMode() == mode
            end,
            callback = function()
                setMode(mode)
                refresh()
            end,
        }
    end

    table.insert(status_bar.sub_item_table, {
        text = _("Reading streak"),
        sub_item_table = {
            radio(_("Daily streak"), "daily"),
            radio(_("Weekly streak"), "weekly"),
            radio(_("Daily + weekly"), "both"),
            radio(_("Hidden"), "off"),
        },
    })
end
