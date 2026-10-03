------------------------------------------------------------------------------
-- Competitive checks layered over EnormousApplePie's regions and start picker.
-- Joint citizen allocations screen candidates; bounded opening plans compare
-- completed starts under the active rules. No game state is advanced.
-- Keep tolerances together so subsequent gameplay tests can tune the balance settings.
------------------------------------------------------------------------------
Lekmap_Competition = {}
Lekmap_Competition.LIMITS = {
    opening_radius = 3, expansion_radius = 8, territory_radius = 12,
    minimum_food = 8, minimum_production = 5, minimum_open_land = 10,
    minimum_site_value = 14, minimum_approach_width = 2, minimum_naval_access = 8,
    food_ratio = 1.25, production_ratio = 1.30, expansion_ratio = 1.30,
    territory_ratio = 1.40, opponent_distance_ratio = 1.40,
    approach_ratio = 3.0, naval_ratio = 2.0, pressure_ratio = 2.0, plan_ratio = 1.35, require_fresh_water = true,
    refinement_passes = 3, candidates_per_region = 16, maximum_repairs = 12,
    maximum_refinement_evaluations = 288,
}

local width, height, nodes, fields, opening_cache, site_cache, snapshots
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
    if not plot then return 0,0 end
    local c=Lekmap_StartRules.Context(nil,true)
    local yields=Lekmap_StartRules.TileYields(Lekmap_StartRules.Snapshot(plot),c)
    return yields[1],yields[2]
end

function Lekmap_Competition.Refresh()
    local previous_snapshots,previous_fields,previous_count=snapshots,fields,field_count
    width, height = Map.GetGridSize()
    Lekmap_Opening.Reset()
    nodes, fields, opening_cache, site_cache = {}, {}, {}, {}
    snapshots={}
    local same_geography=previous_snapshots~=nil and #previous_snapshots==width*height
    field_count=0
    yield_tables = {
        terrain = ReadYields("Terrain_Yields", "TerrainType"),
        feature = ReadYields("Feature_YieldChanges", "FeatureType"),
        resource = ReadYields("Resource_YieldChanges", "ResourceType"),
    }
    for y=0,height-1 do for x=0,width-1 do
        local plot = Map.GetPlot(x,y)
        local node = { x=x, y=y, plot=plot, passable=Passable(plot), adjacent={} }
        local tile=Lekmap_StartRules.Snapshot(plot)
        tile.river_edges=0
        for direction=0,5 do
            if plot.IsRiverCrossing and plot:IsRiverCrossing(direction) then tile.river_edges=tile.river_edges+2^direction end
        end
        local previous=previous_snapshots and previous_snapshots[Index(x,y)]
        if not previous or previous.x~=x or previous.y~=y or previous.terrain~=tile.terrain
            or previous.feature~=tile.feature or previous.hills~=tile.hills or previous.mountain~=tile.mountain
            or previous.water~=tile.water or previous.wonder~=tile.wonder or previous.river~=tile.river
            or previous.river_edges~=tile.river_edges then same_geography=false end
        snapshots[Index(x,y)]=tile
        local yields=Lekmap_StartRules.TileYields(tile,Lekmap_StartRules.Context(nil,true))
        node.food, node.production = yields[1],yields[2]
        for direction=0,5 do
            local other = Map.PlotDirection(x,y,direction)
            if other then node.adjacent[#node.adjacent+1] = Index(other:GetX(),other:GetY()) end
        end
        nodes[Index(x,y)] = node
    end end
    -- Bonus-resource additions do not change travel. Preserve those fields
    -- across repair passes; any terrain/feature/river change invalidates them.
    if same_geography then fields,field_count=previous_fields,previous_count end
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
    snapshots=nil -- A new generation may have different rules or wrapping.
    Lekmap_StartRules.Reset()
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

function Lekmap_Competition.Travel(x,y)
    local key=Index(x,y)..":movement"
    if not fields[key] then
        if field_count>=64 then fields={};field_count=0 end
        fields[key]=Lekmap_Travel.Field(x,y,Lekmap_StartRules.Context(nil,true),"military",width*height,snapshots)
        field_count=field_count+1
    end
    return fields[key]
end

function Lekmap_Competition.Opening(x,y)
    local origin = Index(x,y)
    if opening_cache[origin] then return opening_cache[origin] end
    local land = Lekmap_HexUtil.ReachablePlots(x,y,3,false)
    local usable=0;for _ in pairs(land) do usable=usable+1 end
    local plot=Map.GetPlot(x,y)
    local joint,tiles=Lekmap_Opening.JointPotential(x,y,Lekmap_StartRules.Context(nil,true))
    local naval_access=0
    for _,other in ipairs(nodes[origin].adjacent) do
        naval_access=math.max(naval_access,water_sizes[water_components[other]] or 0)
    end
    local food_cutoff,production_cutoff=math.huge,math.huge
    for _,index in ipairs(joint.worked) do
        food_cutoff=math.min(food_cutoff,nodes[index].food)
        production_cutoff=math.min(production_cutoff,nodes[index].production)
    end
    local out={food=joint.yields[1],production=joint.yields[2],open_land=usable-1,
        fresh=plot:IsFreshWater(),coastal=Lekmap_Utilities.AdjacentToOcean(x,y),x=x,y=y,
        food_cutoff=food_cutoff==math.huge and 0 or food_cutoff,
        production_cutoff=production_cutoff==math.huge and 0 or production_cutoff,
        naval_access=plot:IsCoastalLand() and math.min(30,naval_access) or nil}
    opening_cache[origin]=out
    return out
end

local function SiteValue(index,capital_luxuries)
    if site_cache[index] then
        local value=site_cache[index].value
        for resource,bonus in Lekmap_Utilities.OrderedPairs(site_cache[index].luxuries) do
            if not capital_luxuries or not capital_luxuries[resource] then value=value+bonus end
        end
        return value,site_cache[index].luxuries
    end
    local node=nodes[index]
    local R=Lekmap_StartRules
    local c=R.Context(nil,true)
    local tiles,owned={},{}
    for _,other in ipairs(node.adjacent) do
        tiles[other]=R.Snapshot(nodes[other].plot,{x=node.x,y=node.y});owned[other]=true
    end
    local center=R.Snapshot(node.plot)
    local state={techs=c.techs,buildings={},population=2}
    local allocation=Lekmap_Opening.Allocate(tiles,owned,2,R.TileYields(center,c,state,true),c,state,
        {weights={2,3,0.5,0.5,1,1},surplus=1},false)
    local y=allocation.yields
    local value=2*y[1]+3*y[2]+0.5*y[3]+0.5*y[4]+y[5]+y[6]
        -math.max(0,-allocation.surplus)*10
    -- An expansion's first citizens cannot work its entire eventual radius.
    -- Connection work and research discount nearby luxury value.
    local luxuries={}
    local worker=R.Resolve(c,"unit","UNIT_WORKER")
    if worker then
        for _,tile in Lekmap_Utilities.OrderedPairs(tiles) do
            local resource=R.Revealed(tile,c.techs) and R.Row("Resources",tile.resource)
            if resource and (resource.Happiness or 0)>0 and not luxuries[resource.Type] then
                for _,build in ipairs(R.WorkerBuilds(c,worker)) do
                    local techs={};for k,v in pairs(c.techs) do techs[k]=v end
                    if build.PrereqTech then techs[build.PrereqTech]=true end
                    local connects=false
                    for _,rule in ipairs(R.Group("Improvement_ResourceTypes","ImprovementType",build.ImprovementType)) do
                        if rule.ResourceType==resource.Type and R.True(rule.ResourceTrade) then connects=true end
                    end
                    if connects and R.BuildAllowed(tile,build,c,techs) then
                        local turns=R.BuildWork(tile,build,c,techs)/R.WorkRate(c,worker)
                            +(build.PrereqTech and not c.techs[build.PrereqTech] and (R.ResearchCost(build.PrereqTech,c) or 0)/5 or 0)
                        luxuries[resource.Type]=resource.Happiness/(1+turns/8);break
                    end
                end
            end
        end
    end
    if node.plot:IsFreshWater() then value=value+2 end
    site_cache[index]={value=value,luxuries=luxuries}
    return SiteValue(index,capital_luxuries)
end

function Lekmap_Competition.ExpansionValue(x,y,capital_luxuries)
    return SiteValue(Index(x,y),capital_luxuries)
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
    local routes, regions, travel = {}, {}, {}
    for region,start in Lekmap_Utilities.OrderedPairs(starts) do
        regions[#regions+1]=region
        travel[region]=Lekmap_Competition.Travel(start.x,start.y)
        routes[region]={}
        for index,cost in pairs(travel[region].costs) do
            routes[region][index]=2*cost/(travel[region].profile.moves*travel[region].profile.denominator)
        end
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
        if not opening.approach then opening.approach=Lekmap_Travel.ExitCapacity(start.x,start.y,6) end
        local item={region=region,x=start.x,y=start.y, food=opening.food,production=opening.production,
            fresh=opening.fresh,open_land=opening.open_land,approach=opening.approach, coastal=opening.coastal,
            territory=0,opponent_distance=nil,pressure=0,fronts=0,expansion=0,sites={}, has_opponent=false, naval_access=opening.naval_access}
        local fronts={}
        for _,other in ipairs(regions) do if other~=region and Team(other)~=Team(region) then
            item.has_opponent=true
            local here=Index(start.x,start.y)
            local d=routes[other][here]
            if d then
                item.pressure=item.pressure+1/math.max(1,d/2)
                local entry=travel[other].parents[here]
                if entry then fronts[entry]=true end
            end
            if d and (not item.opponent_distance or d<item.opponent_distance) then item.opponent_distance=d end
        end end
        for _ in pairs(fronts) do item.fronts=item.fronts+1 end
        item.pressure=item.pressure*(1+0.1*math.max(0,item.fronts-1))
        local capital_luxuries={}
        for plot in Lekmap_HexUtil.PlotAreaSpiralIterator(Map.GetPlot(start.x,start.y),3,nil,nil,nil,true) do
            local resource=GameInfo.Resources[plot:GetResourceType(-1)]
            if resource and (resource.Happiness or 0)>0 then capital_luxuries[resource.Type]=true end
        end
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
                    local value,luxuries=0,{}
                    if clear then value,luxuries=SiteValue(index,capital_luxuries) end
                    if value>=L.minimum_site_value then candidates[#candidates+1]={x=node.x,y=node.y,value=value,index=index,luxuries=luxuries} end
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
                local upper_bound=math.min(a.value,b.value)*1000+a.value+b.value
                if upper_bound<=best then break end
                if Distance(a,b)>=4 then
                    local av,bv=a.value,b.value
                    for resource,bonus in Lekmap_Utilities.OrderedPairs(a.luxuries) do
                        if b.luxuries[resource] and not capital_luxuries[resource] then
                            if av>=bv then av=av-bonus else bv=bv-b.luxuries[resource] end
                        end
                    end
                    local pair_value=math.min(av,bv)*1000+av+bv
                    if pair_value>best then
                        item.sites={{x=a.x,y=a.y,index=a.index,value=av},{x=b.x,y=b.y,index=b.index,value=bv}}
                        item.expansion=math.min(av,bv);best=pair_value
                    end
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
        {"territory",L.territory_ratio},{"opponent_distance",L.opponent_distance_ratio},{"approach",L.approach_ratio},{"naval_access",L.naval_ratio},{"pressure",L.pressure_ratio}}) do
        local low,high=math.huge,0
        for _,region in ipairs(regions) do
            local value=report.starts[region][metric[1]]
            if value then low=math.min(low,value); high=math.max(high,value) end
        end
        local ratio=high>0 and high/math.max(metric[1]=="pressure" and 0.01 or 1,low) or 1
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
    local player_count=0;for _ in pairs(assignments) do player_count=player_count+1 end
    -- Keep the ordinary six-player search intact while bounding full-map
    -- rescoring for large lobbies. Biases, scores and repair rules are unchanged.
    local candidate_limit=math.min(L.candidates_per_region,math.max(1,
        math.floor(L.maximum_refinement_evaluations/math.max(1,player_count*L.refinement_passes))))
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
                            +math.min(o.open_land/3,8)-Distance(candidate,original)*0.7
                        local actual=Lekmap_Opening.JointPotential(x,y,Lekmap_StartRules.Context(player,false))
                        -- Civilization terrain benefits steer its own candidate
                        -- ranking; cross-player fairness keeps a common rules baseline.
                        candidate.rank=candidate.rank+math.max(-10,math.min(10,
                            (actual.yields[1]-o.food)*2+actual.yields[2]-o.production))
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
                if #shortlist>=candidate_limit then break end
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

local function ComparePlans(starts,report)
    if not Lekmap_Opening.Available() then return end
    Lekmap_Opening.SetSettlements(starts,MinorStarts())
    local common=Lekmap_StartRules.Context(nil,true)
    report.opening_metrics={}
    for region,start in Lekmap_Utilities.OrderedPairs(starts) do
        local item=report.starts[region]
        item.openings=Lekmap_Opening.Evaluate(start.x,start.y,common)
        for name,score in pairs(item.openings.scores) do
            local metric=report.opening_metrics[name] or {minimum=math.huge,maximum=0}
            metric.minimum=math.min(metric.minimum,score);metric.maximum=math.max(metric.maximum,score)
            report.opening_metrics[name]=metric
        end
    end
    for _,metric in pairs(report.opening_metrics) do
        metric.ratio=metric.maximum/math.max(0.01,metric.minimum)
        metric.limit=Lekmap_Competition.LIMITS.plan_ratio
    end
end

function Lekmap_Competition.EvaluatePlans(starts,report)
    if not report.opening_metrics then ComparePlans(starts,report) end
    if not report.opening_metrics then return end
    for name,metric in Lekmap_Utilities.OrderedPairs(report.opening_metrics) do
        if metric.ratio>metric.limit then
            report.violations[#report.violations+1]=name.." opening spread exceeds "..metric.limit
            report.penalty=report.penalty+(metric.ratio-metric.limit)*30
        end
    end
    for region,start in Lekmap_Utilities.OrderedPairs(starts) do
        local player=Lekmap_Spawns.GetPlayerForRegion(region)
        report.starts[region].civilization_openings=Lekmap_Opening.Evaluate(start.x,start.y,Lekmap_StartRules.Context(player,false))
    end
end

local function PlanDeficit(evaluation,metrics)
    local deficit=0
    for name,score in Lekmap_Utilities.OrderedPairs(evaluation.scores) do
        local target=metrics[name].maximum/metrics[name].limit
        deficit=deficit+math.max(0,target-score)/math.max(1,target)
    end
    return deficit
end

local function RepairPlan(start,evaluation,metrics)
    local baseline=PlanDeficit(evaluation,metrics)
    if baseline<=0 then return false end
    local R=Lekmap_StartRules
    local c=R.Context(nil,true)
    local choices={}
    -- Prefilter legal, unchanged-terrain additions before running timelines.
    for _,key in ipairs({"WHEAT","COW","DEER","BANANA","SHEEP","FISH","STONE","HARDWOOD"}) do
        local active=Lekmap_ResourceDefs.active[key]
        if active then
            for plot in Lekmap_HexUtil.PlotAreaSpiralIterator(Map.GetPlot(start.x,start.y),2,nil,nil,nil,false) do
                if Lekmap_Resources.CanPlaceAt(key,plot:GetX(),plot:GetY()) then
                    local tile=R.Snapshot(plot,{x=start.x,y=start.y})
                    if not active.def.force_valid_feature or tile.feature then
                        local before=R.TileYields(tile,c);tile.resource="RESOURCE_"..key
                        local after=R.TileYields(tile,c)
                        local rank=(after[1]-before[1])*2+(after[2]-before[2])*2+(after[3]-before[3])*0.5
                        choices[#choices+1]={key=key,index=Index(tile.x,tile.y),x=tile.x,y=tile.y,
                            rank=rank-tile.distance*0.3}
                    end
                end
            end
        end
    end
    table.sort(choices,function(a,b)
        if a.rank~=b.rank then return a.rank>b.rank end
        if a.index~=b.index then return a.index<b.index end
        return a.key<b.key
    end)
    local best,best_deficit=nil,baseline
    local seen,attempts={},0
    for _,candidate in ipairs(choices) do
        if not seen[candidate.index] then
            seen[candidate.index]=true;attempts=attempts+1
            local trial=Lekmap_Opening.Evaluate(start.x,start.y,c,nil,
                {[candidate.index]={resource="RESOURCE_"..candidate.key}})
            local deficit=PlanDeficit(trial,metrics)
            local safe=true
            for name,score in pairs(evaluation.scores) do if trial.scores[name]+0.001<score then safe=false end end
            if safe and deficit+0.001<best_deficit then best,best_deficit=candidate,deficit end
            if attempts>=3 then break end
        end
    end
    return best and Lekmap_Resources.PlaceOne(best.x,best.y,best.key,1) or false
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
                if TryRepairBonus(start,need_food and 1 or 2,cutoff,1) then
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
    -- Three bounded corrective passes use the actual opening timelines.
    -- All trials are virtual. Commit only legal additions that reduce the
    -- measured deficit without weakening another opening family.
    ComparePlans(starts,report)
    for pass=1,3 do
        local changed=false
        if not report.opening_metrics then break end
        for region,start in Lekmap_Utilities.OrderedPairs(starts) do
            if (repairs[region] or 0)<L.maximum_repairs and RepairPlan(start,report.starts[region].openings,report.opening_metrics) then
                repairs[region]=(repairs[region] or 0)+1;changed=true
            end
        end
        if not changed then break end
        Lekmap_Competition.Refresh()
        report=Lekmap_Competition.Inspect(starts,true)
        ComparePlans(starts,report)
    end
    Lekmap_Competition.EvaluatePlans(starts,report)
    report.repairs=repairs
    last_report=report
    for region,item in Lekmap_Utilities.OrderedPairs(report.starts) do
        print(string.format("Lekmap competitive region %d: food %.1f, production %.1f, freshwater %s, expansion %.1f (%d sites), land %d, opponent %s, approach %d, naval %s",
            region,item.food,item.production,tostring(item.fresh),item.expansion,#item.sites,item.territory,tostring(item.opponent_distance),item.approach,tostring(item.naval_access)))
    end
    return report
end
function Lekmap_Competition.GetLastReport() return last_report end
