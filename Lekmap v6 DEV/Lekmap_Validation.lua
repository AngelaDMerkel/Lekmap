------------------------------------------------------------------------------
-- Final checks complement the existing placement modules. Inspect the live map
-- after every normalization pass; do not infer success from requested counts.
------------------------------------------------------------------------------
Lekmap_Validation = {}
local last_report

function Lekmap_Validation.Check(args)
    args = args or {}
    local report = { errors = {}, warnings = {}, starts = {}, resource_tiles = 0 }
    local width, height = Map.GetGridSize()
    local _, _, major_ids, _, _, _, minor_ids = Lekmap_Utilities.GetPlayerAndTeamInfo()
    local starts, occupied = {}, {}
    local function add_start(id, minor)
        local plot = Players[id]:GetStartingPlot()
        if not plot then
            table.insert(report.errors, "Player " .. id .. " has no starting plot")
            return
        end
        local index = plot:GetY() * width + plot:GetX() + 1
        if plot:IsWater() or plot:IsMountain() or Lekmap_Utilities.IsNaturalWonder(plot) then
            table.insert(report.errors, "Player " .. id .. " has an uninhabitable starting plot")
        end
        if occupied[index] then table.insert(report.errors, "Players share starting plot " .. index) end
        occupied[index] = true
        local record = { player = id, minor = minor, x = plot:GetX(), y = plot:GetY(), resources = {} }
        for _, other in ipairs(starts) do
            if Map.PlotDistance(record.x, record.y, other.x, other.y) < 5 then
                table.insert(report.warnings, "Players " .. id .. " and " .. other.player .. " use relaxed start spacing")
            end
        end
        table.insert(starts, record)
        if not minor then table.insert(report.starts, record) end
    end
    for _, id in ipairs(major_ids) do add_start(id, false) end
    for _, id in ipairs(minor_ids) do add_start(id, true) end

    -- Refresh once after all terrain and feature changes. Validate occupied
    -- resources using the same rules that govern every resource writer.
    Lekmap_Resources.BuildWorldPlotCache()
    local cache = Lekmap_Resources.GetPlotCache()
    for index = 1, width * height do
        local entry = cache[index]
        local plot = Map.GetPlot(entry.x, entry.y)
        local id = plot:GetResourceType(-1)
        if id ~= -1 then
            report.resource_tiles = report.resource_tiles + 1
            local key = Lekmap_ResourceDefs.GetKey(id)
            local active = key and Lekmap_ResourceDefs.active[key]
            local valid = not occupied[index] and not Lekmap_Utilities.IsNaturalWonder(plot) and not plot:IsMountain()
            if active then
                local copy = {}
                for k, v in pairs(entry) do copy[k] = v end
                copy.has_resource = false
                valid = valid and Lekmap_Resources.IsValidPlotForResource(copy, active.def)
            else
                valid = false
            end
            if not valid then
                table.insert(report.errors, string.format("Illegal %s at (%d,%d)", key or tostring(id), entry.x, entry.y))
            end
        end
    end

    for _, start in ipairs(report.starts) do
        local strategic_tiles = {}
        local center = Map.GetPlot(start.x, start.y)
        for ring = 1, 6 do
            for plot in Lekmap_HexUtil.PlotRingIterator(center, ring) do
                local key = Lekmap_ResourceDefs.GetKey(plot:GetResourceType(-1))
                if key and Lekmap_Resources.CanSupplyStart(key, plot:GetX(), plot:GetY(), start, ring <= 3 and 3 or 6) then
                    if ring <= 3 then start.resources[key] = (start.resources[key] or 0) + 1 end
                    if ring <= 3 or key == "URANIUM" then strategic_tiles[key] = (strategic_tiles[key] or 0) + 1 end
                end
            end
        end
        if args.strategicBalance then
            for _, rule in ipairs(Lekmap_Strategics.GetStartRules(args.startQuality, args.strategicDistribution)) do
                if Lekmap_ResourceDefs.IsActive(rule.key) and (strategic_tiles[rule.key] or 0) < rule.count then
                    local target = report.warnings
                    table.insert(target, "Player " .. start.player .. " has a reachable " .. rule.key .. " shortfall")
                end
            end
        end
    end
    if args.competitive then
        Lekmap_Competition.Refresh()
        report.competition = Lekmap_Competition.Inspect(Lekmap_Spawns.GetAllStartPlots(), true)
        Lekmap_Competition.EvaluatePlans(Lekmap_Spawns.GetAllStartPlots(),report.competition)
        local finished=Lekmap_Competition.GetLastReport()
        report.competition.repairs=finished and finished.repairs or {}
        for _,message in ipairs(report.competition.violations) do table.insert(report.warnings, "Competitive balance target: "..message) end
    end
    if args.strategicDistribution and args.strategicDistribution > 1 then
        for index,entry in ipairs(cache) do
            local id=Map.GetPlot(entry.x,entry.y):GetResourceType(-1)
            local key=Lekmap_ResourceDefs.GetKey(id)
            local active=key and Lekmap_ResourceDefs.active[key]
            if active and active.def.class=="strategic" and not Lekmap_Strategics.CanPlaceResource(key,entry.x,entry.y) then
                table.insert(report.errors, "Strategic distribution violation: "..key.." at "..entry.x..","..entry.y)
            end
        end
    end
    report.competitive_targets_met=not report.competition or #report.competition.violations==0
    report.strategic_distribution=Lekmap_Strategics.GetDistributionMode()
    last_report = report
    return report
end

function Lekmap_Validation.Finalize(args)
    local report = Lekmap_Validation.Check(args)
    print(string.format("Lekmap validation: %d major starts, %d resource tiles, %d errors, %d supply warnings",
        #report.starts, report.resource_tiles, #report.errors, #report.warnings))
    for _, warning in ipairs(report.warnings) do print("Lekmap warning: " .. warning) end
    for _, message in ipairs(report.errors) do print("Lekmap error: " .. message) end
    if #report.errors > 0 then
        print("Lekmap recovery: repairing the final map so the game can start.")
        Lekmap_Utilities.RecoverGeneration()
        report.recovered=true
    end
    return report
end

-- Compatibility for callers of the v6 RC1 helper. Finalization is non-blocking.
Lekmap_Validation.AssertValid = Lekmap_Validation.Finalize

function Lekmap_Validation.GetLastReport() return last_report end
