-- Locale helper (shared script: loads on both client and server).
-- Language files live in locales/<code>.lua and register themselves:  Locales['en'] = { key = 'text %s' }
-- Pick the language with Config.locale (default 'en'). A missing key falls back to English, then to the key itself.

Locales = Locales or {}

local function currentCode()
    return (Config and Config.locale) or 'en'
end

local function lookup(key)
    local code = currentCode()
    local d = Locales[code]
    local s = d and d[key]
    if s == nil and code ~= 'en' then
        local en = Locales.en
        s = en and en[key]
    end
    return s
end

--- T(key, a, b) -> the translated text with string.format applied when arguments are given.
function T(key, ...)
    local s = lookup(key)
    if s == nil then return tostring(key) end
    if select('#', ...) > 0 then
        local ok, out = pcall(string.format, s, ...)
        if ok then return out end
    end
    return s
end

--- Whole dictionary (English filled in under the chosen language) - sent to the NUI page.
function LocaleDict()
    local out = {}
    for k, v in pairs(Locales.en or {}) do out[k] = v end
    local code = currentCode()
    if code ~= 'en' then
        for k, v in pairs(Locales[code] or {}) do out[k] = v end
    end
    return out
end
