-- Reports, for every language file, which keys are missing compared with English and which translations have a
-- different number of %s placeholders (that would break the text). Run from the resource folder:
--   lua tests/locale_check.lua            exits 1 when a placeholder count is wrong
--   lua tests/locale_check.lua --strict   also exits 1 when any key is missing
Locales = {}
local files = {}
if LOCALE_FILES then
    files = LOCALE_FILES
else
    local p = io.popen('ls locales')
    for name in p:lines() do if name:match('%.lua$') then files[#files + 1] = name end end
    p:close()
end
table.sort(files)
for _, f in ipairs(files) do dofile('locales/' .. f) end

local function placeholders(s)
    local n = 0
    for _ in s:gmatch('%%[sd%%]') do n = n + 1 end
    return n
end

local en = Locales.en
local enKeys = {}
for k in pairs(en) do enKeys[#enKeys + 1] = k end
table.sort(enKeys)

local bad, missingTotal = 0, 0
for _, f in ipairs(files) do
    local code = f:gsub('%.lua$', '')
    if code ~= 'en' then
        local d = Locales[code]
        if not d then
            print(('%-6s no table named Locales[%q] in the file'):format(code, code))
            bad = bad + 1
        else
            local missing, wrong, extra = 0, {}, {}
            for _, k in ipairs(enKeys) do
                local v = d[k]
                if v == nil then missing = missing + 1
                elseif placeholders(v) ~= placeholders(en[k]) then wrong[#wrong + 1] = k end
            end
            for k in pairs(d) do if en[k] == nil then extra[#extra + 1] = k end end
            missingTotal = missingTotal + missing
            print(('%-6s %3d/%d translated, %d missing%s%s'):format(code, #enKeys - missing, #enKeys, missing,
                #wrong > 0 and (', WRONG PLACEHOLDERS: ' .. table.concat(wrong, ', ')) or '',
                #extra > 0 and (', unused keys: ' .. table.concat(extra, ', ')) or ''))
            bad = bad + #wrong
        end
    end
end
os.exit((bad == 0 and (arg[1] ~= '--strict' or missingTotal == 0)) and 0 or 1)
