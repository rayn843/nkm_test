-- NKM 0.9.5 lightweight runtime profiler with cumulative diagnostic counters.
-- Uses cumulative timings so measurements remain useful across streaming cycles.
NKM.PerfStats = NKM.PerfStats or {}

function NKM.PerfBegin()
    return SysTime()
end

function NKM.PerfRecord(name, startedAt)
    if not isstring(name) or not isnumber(startedAt) then return 0 end
    local elapsed = math.max(0, (SysTime() - startedAt) * 1000)
    local stats = NKM.PerfStats[name]
    if not stats then
        stats = { calls = 0, totalMs = 0, maxMs = 0 }
        NKM.PerfStats[name] = stats
    end
    stats.calls = stats.calls + 1
    stats.totalMs = stats.totalMs + elapsed
    if elapsed > stats.maxMs then stats.maxMs = elapsed end
    return elapsed
end

function NKM.PerfAdd(name, amount)
    if not isstring(name) or not isnumber(amount) then return end
    local stats = NKM.PerfStats[name]
    if not stats then
        stats = { calls = 0, totalMs = 0, maxMs = 0, value = 0 }
        NKM.PerfStats[name] = stats
    end
    stats.value = (stats.value or 0) + amount
end

function NKM.PerfReset()
    NKM.PerfStats = {}
end

function NKM.PerfPrint(prefix)
    prefix = prefix or "NKM"
    local names = {}
    for name in pairs(NKM.PerfStats or {}) do names[#names + 1] = name end
    table.sort(names)
    print("[" .. prefix .. "] Performance counters:")
    if #names == 0 then
        print("[" .. prefix .. "] No samples yet")
        return
    end
    for _, name in ipairs(names) do
        local stat = NKM.PerfStats[name]
        if stat.calls and stat.calls > 0 then
            print(string.format("[%s] %s: calls=%d total=%.3fms avg=%.3fms max=%.3fms",
                prefix, name, stat.calls, stat.totalMs, stat.totalMs / stat.calls, stat.maxMs))
        elseif stat.value ~= nil then
            print(string.format("[%s] %s: %s", prefix, name, tostring(stat.value)))
        end
    end
end
