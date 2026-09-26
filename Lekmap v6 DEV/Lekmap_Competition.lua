------------------------------------------------------------------------------
-- Competitive checks layered over EnormousApplePie's regions and start picker.
-- Measurements are geographic/natural-yield proxies, not a simulation of play.
-- Keep tolerances together so subsequent gameplay tests can tune the balance settings.
------------------------------------------------------------------------------
Lekmap_Competition = {}
Lekmap_Competition.LIMITS = {
    opening_radius = 3, expansion_radius = 8, territory_radius = 12,
    minimum_food = 8, minimum_production = 5, minimum_open_land = 10,
    minimum_site_value = 14, minimum_approach_width = 5, minimum_naval_access = 8,
    food_ratio = 1.25, production_ratio = 1.30, expansion_ratio = 1.30,
    territory_ratio = 1.40, opponent_distance_ratio = 1.40,
    approach_ratio = 2.0, naval_ratio = 2.0, require_fresh_water = true,
    refinement_passes = 3, candidates_per_region = 16, maximum_repairs = 12,
}

local width, height, nodes, fields, opening_cache, site_cache
local field_count=0
local water_components, water_sizes = {}, {}
local yield_tables, reserved, enabled, last_report = {}, {}, false, nil
local bias_requirements = {}

local function Index(x, y) return y * width + x + 1 end
local function Distance(a, b) return Map.PlotDistance(a.x, a.y, b.x, b.y) end
local function Passable(plot)
    return plot and not plot:IsWater() and not plot:IsMountain()
        and not plot:IsNaturalWonder() and plot:GetFeatureType() ~= FeatureTypes.FEATURE_ICE
end

local function ReadYields(table_name, type_column)
    local out = {}
    if GameInfo[table_name] then
        for row in GameInfo[table_name]() do
            local kind = row.YieldType == "YIELD_FOOD" and 1 or row.YieldType == "YIELD_PRODUCTION" and 2 or nil
            if kind then
                local name = row[type_column]
                out[name] = out[name] or {0,0}
                out[name][kind] = out[name][kind] + row.Yield
            end
        end
    end
    return out
end

function Lekmap_Competition.TilePotential(plot)
    if not plot or (plot:IsMountain() and not plot:IsNaturalWonder()) or plot:GetFeatureType() == FeatureTypes.FEATURE_ICE then return 0,0 end
    local terrain = GameInfo.Terrains[plot:GetTerrainType()]
    local feature = GameInfo.Features[plot:GetFeatureType()]
    local basic = yield_tables.terrain[terrain and terrain.Type] or {0,0}
    local food, production = basic[1], basic[2]
    if plot:IsHills() then food, production = 0, GameDefines.HILLS_EXTRA_PRODUCTION or 2 end
    if plot:IsLake() then food, production = GameDefines.LAKE_FOOD or 2, 0 end
    if feature then
        local change = yield_tables.feature[feature.Type] or {0,0}
        if feature.YieldNotAdditive then food, production = change[1], change[2]
        else food, production = food + change[1], production + change[2] end
    end
    local resource = GameInfo.Resources[plot:GetResourceType(-1)]
    -- Hidden strategic yields must not inflate an opening before revelation.
    if resource and Game.GetResourceUsageType(resource.ID) ~= ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
        local change = yield_tables.resource[resource.Type] or {0,0}
        food, production = food + change[1], production + change[2]
    end
    return math.max(0,food), math.max(0,production)
end

function Lekmap_Competition.Refresh()
    width, height = Map.GetGridSize()
    nodes, fields, opening_cache, site_cache = {}, {}, {}, {}
    field_count=0
    yield_tables = {
        terrain = ReadYields("Terrain_Yields", "TerrainType"),
        feature = ReadYields("Feature_YieldChanges", "FeatureType"),
        resource = ReadYields("Resource_YieldChanges", "ResourceType"),
    }
    for y=0,height-1 do for x=0,width-1 do
        local plot = Map.GetPlot(x,y)
        local node = { x=x, y=y, plot=plot, passable=Passable(plot), adjacent={} }
        node.food, node.production = Lekmap_Competition.TilePotential(plot)
        for direction=0,5 do
            local other = Map.PlotDirection(x,y,direction)
            if other then node.adjacent[#node.adjacent+1] = Index(other:GetX(),other:GetY()) end
        end
        nodes[Index(x,y)] = node
    end end
    -- Early naval access uses the contiguous shallow-water component. Ocean
    -- transport is considered separately for contested offshore strategics.
    water_components,water_sizes={},{}
    local component=0
    for index,node in ipairs(nodes) do
        local function navigable(n)
            return n.plot:IsWater() and not n.plot:IsLake() and not n.plot:IsNaturalWonder()
                and n.plot:GetTerrainType()==TerrainTypes.TERRAIN_COAST
                and n.plot:GetFeatureType()~=FeatureTypes.FEATURE_ICE
        end
        if not water_components[index] and navigable(node) then
            component=component+1
            local queue,head={index},1
            water_components[index]=component
            while head<=#queue do
                local at=queue[head];head=head+1
                for _,other in ipairs(nodes[at].adjacent) do
                    if not water_components[other] and navigable(nodes[other]) then
                        water_components[other]=component;queue[#queue+1]=other
                    end
                end
            end
            water_sizes[component]=#queue
        end
    end
end

function Lekmap_Competition.Begin(active)
    enabled, reserved, last_report = active == true, {}, nil
    bias_requirements = {}
    Lekmap_Competition.Refresh()
end
function Lekmap_Competition.IsEnabled() return enabled end

-- Unit-edge graph distance through land (and optionally shallow coastal water).
function Lekmap_Competition.Distances(x, y, water)
    if not nodes then Lekmap_Competition.Refresh() end
    local origin = Index(x,y)
    local key = origin .. (water and ":sea" or ":land")
    if fields[key] then return fields[key] end
    local distances, queue, head = {[origin]=0}, {origin}, 1
    while head <= #queue do
        local index = queue[head]; head = head+1
        for _, other in ipairs(nodes[index].adjacent) do
            local node = nodes[other]
            local coastal = water and node.plot:IsWater() and not node.plot:IsNaturalWonder()
                and node.plot:GetFeatureType() ~= FeatureTypes.FEATURE_ICE
            if distances[other] == nil and (node.passable or coastal) then
                distances[other] = distances[index]+1
                queue[#queue+1] = other
            end
        end
    end
    -- Keep memory bounded on large grids and 22-player candidate searches.
    if field_count>=64 then fields={};field_count=0 end
    fields[key] = distances
    field_count=field_count+1
    return distances
end

local function TopFour(values)
    table.sort(values, function(a,b) return a>b end)
    local sum=0; for i=1,math.min(4,#values) do sum=sum+values[i] end
    return sum
end

function Lekmap_Competition.Opening(x,y)
    local origin = Index(x,y)
    if opening_cache[origin] then return opening_cache[origin] end
    local land = Lekmap_HexUtil.ReachablePlots(x,y,3,false)
    local coast = Lekmap_HexUtil.ReachablePlots(x,y,3,true)
    local food, production, usable, width_at_three = {}, {}, 0, 0
    for index, steps in pairs(coast) do
        local node = nodes[index]
        if index ~= origin and (land[index] or node.plot:IsWater()) then
            food[#food+1], production[#production+1] = node.food, node.production
        end
        if land[index] then
            usable = usable+1
            if land[index] == 3 then width_at_three = width_at_three+1 end
        end
    end
    local plot = Map.GetPlot(x,y)
    local naval_access=0
    for _,other in ipairs(nodes[origin].adjacent) do
        naval_access=math.max(naval_access,water_sizes[water_components[other]] or 0)
    end
    -- Founding clears removable features; use the ordinary city-center floor.
    local out = {food=TopFour(food)+2, production=TopFour(production)+(plot:IsHills() and 2 or 1),
        open_land=usable-1, approach=width_at_three, fresh=plot:IsFreshWater(),
        coastal=Lekmap_Utilities.AdjacentToOcean(x,y), x=x,y=y,
        food_cutoff=food[4] or 0, production_cutoff=production[4] or 0,
        naval_access=plot:IsCoastalLand() and math.min(30,naval_access) or nil}
    opening_cache[origin]=out
    return out
end

local function SiteValue(index)
    if site_cache[index] then return site_cache[index] end
    local node = nodes[index]
    local value = 4 -- city center; no improvements, policies or civilization bonuses
    for _, other in ipairs(node.adjacent) do
        local n = nodes[other]
        if n.passable or n.plot:IsNaturalWonder() then value = value + n.food*2 + n.production end
    end
    if node.plot:IsFreshWater() then value=value+2 end
    site_cache[index]=value
    return value
end

local function Team(region)
    local player_id = Lekmap_Spawns.GetPlayerForRegion(region)
    return player_id and Players[player_id]:GetTeam() or region
end

local function MinorStarts()
    local result={}
    if Lekmap_CityStates and Lekmap_CityStates.GetAllPlots then
        for _,p in Lekmap_Utilities.OrderedPairs(Lekmap_CityStates.GetAllPlots()) do result[#result+1]=p end
    end
    return result
end

function Lekmap_Competition.Inspect(starts, final)
    local L = Lekmap_Competition.LIMITS
    local report = { starts={}, violations={}, penalty=0, metrics={}, enabled=enabled }
    local routes, regions = {}, {}
    for region,start in Lekmap_Utilities.OrderedPairs(starts) do
        regions[#regions+1]=region
        routes[region]=Lekmap_Competition.Distances(start.x,start.y,false)
    end
    local owners={}
    for index,node in ipairs(nodes) do if node.passable then
        local closest=math.huge
        for _,region in ipairs(regions) do
            local d=routes[region][index]
            if d and d<closest then owners[index],closest=region,d end
        end
    end end
    -- A fixed ten-tile disk cuts a coastal region in half before measuring its
    -- available expansion land. Scale the common survey radius to region area;
    -- second/third city candidates still use the tighter eight-step radius.
    local owned_land=0; for _ in pairs(owners) do owned_land=owned_land+1 end
    local territory_radius=math.min(24,math.max(L.territory_radius,math.ceil(math.sqrt(owned_land/math.max(1,#regions)))))
    report.territory_radius=territory_radius
    local minors=final and MinorStarts() or {}
    for _,region in ipairs(regions) do
        local start=starts[region]
        local opening=Lekmap_Competition.Opening(start.x,start.y)
        local item={region=region,x=start.x,y=start.y, food=opening.food,production=opening.production,
            fresh=opening.fresh,open_land=opening.open_land,approach=opening.approach, coastal=opening.coastal,
            territory=0,opponent_distance=nil,expansion=0,sites={}, has_opponent=false, naval_access=opening.naval_access}
        for _,other in ipairs(regions) do if other~=region and Team(other)~=Team(region) then
            item.has_opponent=true
            local d=routes[region][Index(starts[other].x,starts[other].y)]
            if d and (not item.opponent_distance or d<item.opponent_distance) then item.opponent_distance=d end
        end end
        local candidates={}
        for index,node in ipairs(nodes) do
            local distance=routes[region][index]
            if distance and distance<=territory_radius and owners[index]==region then
                item.territory=item.territory+1
                if distance<=L.expansion_radius and Distance(start,node)>=4
                    and node.plot:GetTerrainType()~=TerrainTypes.TERRAIN_SNOW
                    and node.plot:GetFeatureType()~=FeatureTypes.FEATURE_OASIS then
                    local clear=true
                    for _,other in ipairs(regions) do
                        if Distance(starts[other],node)<4 then clear=false; break end
                    end
                    if clear then for _,minor in ipairs(minors) do if Distance(minor,node)<4 then clear=false; break end end end
                    local value=clear and SiteValue(index) or 0
                    if value>=L.minimum_site_value then candidates[#candidates+1]={x=node.x,y=node.y,value=value,index=index} end
                end
            end
        end
        table.sort(candidates,function(a,b) if a.value==b.value then return a.index<b.index end; return a.value>b.value end)
        -- The best legal pair, rather than two sites that cannot coexist.
        local best=-1
        for i,a in ipairs(candidates) do
            if a.value*1000+a.value*2<best then break end
            for j=i+1,#candidates do
                local b=candidates[j]
                local pair_value=math.min(a.value,b.value)*1000+a.value+b.value
                if pair_value<=best then break end
                if Distance(a,b)>=4 then
                    item.sites={a,b}; item.expansion=math.min(a.value,b.value); best=pair_value
                    break
                end
            end
        end
        report.starts[region]=item
    end
    local function violation(message, amount)
        report.violations[#report.violations+1]=message
        report.penalty=report.penalty+amount
    end
    for _,region in ipairs(regions) do
        local s=report.starts[region]
        local bias=bias_requirements[region]
        if bias then
            local coastal=Lekmap_Utilities.AdjacentToOcean(s.x,s.y)
                or (bias.allow_inland_sea and Lekmap_Utilities.AdjacentToInlandSea(s.x,s.y))
            if bias.require_coastal and not coastal then violation("Region "..region.." lost its required coastal start",100) end
            if bias.avoid_ocean and Lekmap_Utilities.AdjacentToOcean(s.x,s.y) then violation("Region "..region.." violates coastal-civs-only placement",50) end
        end
        for _,floor in ipairs({{"food",L.minimum_food},{"production",L.minimum_production},
            {"open_land",L.minimum_open_land},{"approach",L.minimum_approach_width}}) do
            if s[floor[1]]<floor[2] then violation("Region "..region.." lacks "..floor[1],(floor[2]-s[floor[1]])*10) end
        end
        if s.naval_access and s.naval_access<L.minimum_naval_access then violation("Region "..region.." lacks usable naval access",20) end
        if L.require_fresh_water and not s.fresh then violation("Region "..region.." has no capital freshwater",20) end
        if #s.sites<2 then violation("Region "..region.." lacks two reachable expansion sites",100) end
        if s.has_opponent and not s.opponent_distance then violation("Region "..region.." is isolated from opponents",100) end
    end
    for _,metric in ipairs({{"food",L.food_ratio},{"production",L.production_ratio},{"expansion",L.expansion_ratio},
        {"territory",L.territory_ratio},{"opponent_distance",L.opponent_distance_ratio},{"approach",L.approach_ratio},{"naval_access",L.naval_ratio}}) do
        local low,high=math.huge,0
        for _,region in ipairs(regions) do
            local value=report.starts[region][metric[1]]
            if value then low=math.min(low,value); high=math.max(high,value) end
        end
        local ratio=high>0 and high/math.max(1,low) or 1
        if low==math.huge then low=nil end
        report.metrics[metric[1]]={minimum=low,maximum=high,ratio=ratio,limit=metric[2]}
        if ratio>metric[2] then violation(metric[1].." spread exceeds "..metric[2],(ratio-metric[2])*30) end
    end
    return report
end

local function Compatible(plot,region,bias,settings)
    if not Passable(plot) or plot:GetArea()~=region.areaID
        or plot:GetFeatureType()==FeatureTypes.FEATURE_OASIS then return false end
    local ocean=Lekmap_Utilities.AdjacentToOcean(plot:GetX(),plot:GetY())
    local inland=Lekmap_Utilities.AdjacentToInlandSea(plot:GetX(),plot:GetY())
    if inland and not ocean and not settings.allow_inland_sea then return false end
    if bias.coastal_hard and not ocean and not (settings.allow_inland_sea and inland) then return false end
    if settings.no_coast_inland and not bias.coastal and ocean then return false end
    return true
end

function Lekmap_Competition.RefineStarts(starts,assignments,biases,settings)
    if not enabled then return end
    Lekmap_Competition.Refresh()
    local L=Lekmap_Competition.LIMITS
    for player,region in Lekmap_Utilities.OrderedPairs(assignments) do
        local bias=biases[player]
        bias_requirements[region]={require_coastal=bias.coastal_hard==true,
            allow_inland_sea=settings.allow_inland_sea==true,
            avoid_ocean=settings.no_coast_inland and not bias.coastal}
    end
    local current=Lekmap_Competition.Inspect(starts,false)
    for pass=1,L.refinement_passes do
        if #current.violations==0 then break end
        local changed=false
        for player,region_id in Lekmap_Utilities.OrderedPairs(assignments) do
            if #current.violations==0 then break end
            local original=starts[region_id]
            local region=Lekmap_Regions.GetRegion(region_id)
            local options={}
            for ry=0,region.height-1 do for rx=0,region.width-1 do
                local x,y=(region.westX+rx)%width,(region.southY+ry)%height
                local plot=Map.GetPlot(x,y)
                if Compatible(plot,region,biases[player],settings) then
                    local candidate={x=x,y=y}
                    local clear=true
                    for r,other in Lekmap_Utilities.OrderedPairs(starts) do
                        if r~=region_id and Distance(candidate,other)<({6,8,10})[settings.start_distance or 2] then clear=false; break end
                    end
                    if clear then
                        local o=Lekmap_Competition.Opening(x,y)
                        -- Keep nearby alternatives and the original regional/coastal bias.
                        candidate.rank=(o.fresh and 25 or 0)+math.min(o.food,12)*2+math.min(o.production,9)
                            +math.min(o.approach,12)-Distance(candidate,original)*0.7
                        options[#options+1]=candidate
                    end
                end
            end end
            table.sort(options,function(a,b)
                if a.rank==b.rank then return Index(a.x,a.y)<Index(b.x,b.y) end
                return a.rank>b.rank
            end)
            local shortlist={}
            for _,candidate in ipairs(options) do
                local distinct=true
                for _,chosen in ipairs(shortlist) do if Distance(candidate,chosen)<3 then distinct=false; break end end
                if distinct then shortlist[#shortlist+1]=candidate end
                if #shortlist>=L.candidates_per_region then break end
            end
            local best,best_report=original,current
            for _,candidate in ipairs(shortlist) do
                starts[region_id]=candidate
                local trial=Lekmap_Competition.Inspect(starts,false)
                if trial.penalty+0.001<best_report.penalty then best,best_report=candidate,trial end
            end
            starts[region_id]=best
            if best~=original then
                changed=true
                print(string.format("Lekmap competition: moved region %d start within its region to (%d,%d)",region_id,best.x,best.y))
            end
            current=best_report
        end
        if not changed then break end
    end
    -- Later city-state/wonder placement must leave two viable settling sites.
    reserved={}
    for region,item in Lekmap_Utilities.OrderedPairs(current.starts) do
        reserved[region]=item.sites
    end
    last_report=current
end

function Lekmap_Competition.BlocksCityState(x,y)
    if not enabled then return false end
    for _,sites in Lekmap_Utilities.OrderedPairs(reserved) do
        for _,site in ipairs(sites) do if Map.PlotDistance(x,y,site.x,site.y)<4 then return true end end
    end
    return false
end
function Lekmap_Competition.IsReservedSite(x,y)
    if not enabled then return false end
    for _,sites in Lekmap_Utilities.OrderedPairs(reserved) do
        for _,site in ipairs(sites) do if x==site.x and y==site.y then return true end end
    end
    return false
end

local function TryRepairBonus(origin,axis,cutoff,radius)
    local choices=axis==2 and {"STONE","HARDWOOD"} or {"WHEAT","COW","DEER","BANANA","SHEEP","FISH","STONE","HARDWOOD"}
    for _,key in ipairs(choices) do
        local changes=yield_tables.resource["RESOURCE_"..key] or {0,0}
        local delta=axis==0 and changes[1]*2+changes[2] or changes[axis]
        if delta>0 then
            local candidates=Lekmap_Resources.GeneratePlotList(key,{x=origin.x,y=origin.y,radius=radius,start_area=true})
            for _,index in ipairs(candidates) do
                local node=nodes[index]
                local def=Lekmap_ResourceDefs.active[key].def
                local changes_feature=def.force_valid_feature and node.plot:GetFeatureType()==FeatureTypes.NO_FEATURE
                local current=axis==1 and node.food or node.production
                -- Expansion value counts passable land adjacent to the future city.
                local improves=axis==0 and node.passable or (axis~=0 and current+delta>cutoff)
                if improves and not changes_feature and Lekmap_Resources.PlaceOne(node.x,node.y,key,1) then return true end
            end
        end
    end
    return false
end

function Lekmap_Competition.Finish(starts)
    if not enabled then return nil end
    Lekmap_Competition.Refresh()
    local report=Lekmap_Competition.Inspect(starts,true)
    local L=Lekmap_Competition.LIMITS
    local repairs={}
    -- At most twelve corrective bonuses per player, shared between their
    -- opening and two expansions. Never remove resources or repaint geography.
    for attempt=1,L.maximum_repairs do
        local changed=false
        for region,start in Lekmap_Utilities.OrderedPairs(starts) do
            repairs[region]=repairs[region] or 0
            local item=report.starts[region]
            local need_food=item.food<math.max(L.minimum_food,report.metrics.food.maximum/L.food_ratio)
            local need_production=item.production<math.max(L.minimum_production,report.metrics.production.maximum/L.production_ratio)
            if repairs[region]<L.maximum_repairs and (need_food or need_production) then
                local cutoff=Lekmap_Competition.Opening(start.x,start.y)[need_food and "food_cutoff" or "production_cutoff"]
                if TryRepairBonus(start,need_food and 1 or 2,cutoff,3) then
                    repairs[region]=repairs[region]+1;changed=true
                end
            end
            local target=math.max(L.minimum_site_value,report.metrics.expansion.maximum/L.expansion_ratio)
            for _,site in ipairs(item.sites) do
                if repairs[region]<L.maximum_repairs and site.value<target and TryRepairBonus(site,0,0,1) then
                    repairs[region]=repairs[region]+1;changed=true
                end
            end
        end
        if not changed then break end
        Lekmap_Competition.Refresh()
        report=Lekmap_Competition.Inspect(starts,true)
    end
    report.repairs=repairs
    last_report=report
    for region,item in Lekmap_Utilities.OrderedPairs(report.starts) do
        print(string.format("Lekmap competitive region %d: food %.1f, production %.1f, freshwater %s, expansion %.1f (%d sites), land %d, opponent %s, approach %d, naval %s",
            region,item.food,item.production,tostring(item.fresh),item.expansion,#item.sites,item.territory,tostring(item.opponent_distance),item.approach,tostring(item.naval_access)))
    end
    return report
end
function Lekmap_Competition.GetLastReport() return last_report end
