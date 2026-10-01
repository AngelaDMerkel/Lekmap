------------------------------------------------------------------------------
-- Bounded, deterministic single-capital opening plans. Tiles, research,
-- workers, ownership, treasury and buildings are virtual; the game is untouched.
-- Expansion results describe settler readiness and settlement headroom, not
-- assumed trade deals, stolen workers, ruins, policies or chosen beliefs.
------------------------------------------------------------------------------
Lekmap_Opening = {}
local O=Lekmap_Opening
local R,T
O.PLANS={
    {name="growth",weights={3,2,0.35,0.8,1,0.8},surplus=2,
        builds={"UNIT_SCOUT","BUILDING_MONUMENT","UNIT_WORKER","BUILDING_GRANARY","BUILDING_SHRINE","BUILDING_LIBRARY","UNIT_SETTLER"},
        techs={"TECH_POTTERY","TECH_ANIMAL_HUSBANDRY","TECH_MINING","TECH_CALENDAR","TECH_TRAPPING","TECH_WRITING","TECH_SAILING","TECH_OPTICS"}},
    {name="expansion",weights={2,3,0.5,0.7,0.8,0.5},surplus=1,
        builds={"UNIT_SCOUT","UNIT_WORKER","UNIT_SETTLER","BUILDING_MONUMENT","UNIT_SETTLER","BUILDING_GRANARY"},
        techs={"TECH_MINING","TECH_POTTERY","TECH_ANIMAL_HUSBANDRY","TECH_CALENDAR","TECH_TRAPPING","TECH_THE_WHEEL","TECH_SAILING"}},
    {name="military",weights={1.5,4,0.5,0.8,0.5,0.4},surplus=0,
        builds={"UNIT_SCOUT","UNIT_WORKER","UNIT_ARCHER","UNIT_ARCHER","UNIT_SPEARMAN","BUILDING_MONUMENT","BUILDING_GRANARY"},
        techs={"TECH_ARCHERY","TECH_MINING","TECH_BRONZE_WORKING","TECH_ANIMAL_HUSBANDRY","TECH_POTTERY","TECH_THE_WHEEL","TECH_SAILING"}},
}
local cache,settlements={},{}
local function Initialize() R=Lekmap_StartRules;T=Lekmap_Travel end
local function CopyMap(t) local out={};for k,v in pairs(t or {}) do out[k]=v end;return out end
local function Index(plot) local width=Map.GetGridSize();return plot:GetY()*width+plot:GetX()+1 end
local function Value(yields,weights) local sum=0;for i=1,6 do sum=sum+yields[i]*weights[i] end;return sum end
function O.Reset() Initialize();cache={};settlements={} end
function O.SetSettlements(starts,minors)
    cache={};settlements={}
    for _,start in Lekmap_Utilities.OrderedPairs(starts or {}) do settlements[#settlements+1]=start end
    for _,start in ipairs(minors or {}) do settlements[#settlements+1]=start end
end
function O.Available() Initialize();return #R.Rows("Units")>0 and #R.Rows("Buildings")>0 and #R.Rows("Technologies")>0 end

-- Dynamic programming over citizen count and food. Each tile is used once;
-- food and production always come from the same selected workforce.
function O.Allocate(tiles,owned,population,base,c,state,plan,settler)
    Initialize()
    local dp={[0]={[0]={yields=R.Zero(),score=0}}}
    local ordered={}
    for index,tile in Lekmap_Utilities.OrderedPairs(tiles) do
        if owned[index] and not tile.city and tile.distance<=3 then
            local yields=R.TileYields(tile,c,state)
            if Value(yields,{1,1,1,1,1,1})>0 then ordered[#ordered+1]={index=index,yields=yields} end
        end
    end
    local factors=R.ModifyCityYields({1,1,1,1,1,1},c,state)
    for i,item in ipairs(ordered) do
        for count=math.min(population,i),1,-1 do
            dp[count]=dp[count] or {}
            for food,previous in Lekmap_Utilities.OrderedPairs(dp[count-1]) do
                local next_food=food+item.yields[1]
                local score=previous.score
                for y=2,6 do score=score+item.yields[y]*plan.weights[y]*factors[y] end
                local existing=dp[count][next_food]
                if not existing or score>existing.score then
                    dp[count][next_food]={score=score,yields=R.Add(R.Copy(previous.yields),item.yields),
                        previous=previous,index=item.index}
                end
            end
        end
    end
    local best,best_score
    local consumption=population*R.Define("FOOD_CONSUMPTION_PER_POPULATION",2)
    for count=0,population do
        for _,candidate in Lekmap_Utilities.OrderedPairs(dp[count] or {}) do
            local yields=R.Add(R.Copy(base),candidate.yields)
            -- Unassigned citizens are ordinary unemployed citizens, not free
            -- extra workers on unavailable second/third-ring tiles.
            yields[2]=yields[2]+population-count
            yields=R.ModifyCityYields(yields,c,state)
            local surplus=yields[1]-consumption
            local score
            if settler then score=(yields[2]+R.SettlerFood(math.floor(surplus)))*plan.weights[2]
                +yields[3]*plan.weights[3]+yields[4]*plan.weights[4]+yields[5]*plan.weights[5]+yields[6]*plan.weights[6]
            else score=Value(yields,plan.weights)-math.max(0,(plan.surplus or 0)-surplus)*25 end
            if not best_score or score>best_score then best,best_score={yields=yields,node=candidate,count=count,surplus=surplus},score end
        end
    end
    local worked={}
    local node=best.node
    while node and node.index do worked[#worked+1]=node.index;node=node.previous end
    table.sort(worked)
    best.worked=worked
    return best
end

local function CollectTiles(x,y,radius)
    local center=Map.GetPlot(x,y)
    local tiles={}
    for plot in Lekmap_HexUtil.PlotAreaSpiralIterator(center,radius or 5,nil,nil,nil,true) do
        local tile=R.Snapshot(plot,{x=x,y=y})
        tile.index=Index(plot);tile.city=plot==center
        for _,other in ipairs(settlements) do
            if other.x~=x or other.y~=y then
                local distance=Map.PlotDistance(other.x,other.y,tile.x,tile.y)
                -- Do not fund an opening with a tile that another settlement
                -- owns first or has an equally strong geographic claim to.
                if distance<=1 or distance<=tile.distance then tile.blocked=true end
            end
        end
        if tile.city then tile.feature=nil;tile.improvement=nil end
        tiles[tile.index]=tile
    end
    return tiles,Index(center)
end

function O.JointPotential(x,y,c)
    Initialize()
    local tiles,origin=CollectTiles(x,y,1)
    local state={techs=CopyMap(c.techs),buildings=R.InitialBuildings(c),population=4}
    local owned={}
    for index,tile in pairs(tiles) do if tile.distance<=1 then owned[index]=true end end
    local base=R.Add(R.TileYields(tiles[origin],c,state,true),R.CityExtras(c,state))
    local allocation=O.Allocate(tiles,owned,4,base,c,state,{weights={1,2,0.25,0.5,0.5,0.25},surplus=0},false)
    return allocation,tiles
end

local function AdjacentOwned(tile,owned)
    for direction=0,5 do
        local plot=Map.PlotDirection(tile.x,tile.y,direction)
        if plot and owned[Index(plot)] then return true end
    end
    return false
end
local function BorderCandidates(tiles,state,c)
    if state.influence_revision~=state.revision then
        state.influence=T.Influence(tiles,state.center.index);state.influence_revision=state.revision
    end
    local candidates={}
    for index,tile in Lekmap_Utilities.OrderedPairs(tiles) do
        if state.influence[index] and not tile.blocked and not state.owned[index] and AdjacentOwned(tile,state.owned) then
            local resource=R.Revealed(tile,state.techs)
            local score=state.influence[index]*R.Define("PLOT_INFLUENCE_DISTANCE_MULTIPLIER",100)
            if resource then score=score+R.Define("PLOT_INFLUENCE_RESOURCE_COST",-105)
            elseif tile.water then score=score+R.Define("PLOT_INFLUENCE_WATER_COST",25) end
            if tile.distance>3 then score=score+R.Define("PLOT_INFLUENCE_RING_COST",100) end
            if tile.wonder then score=score+R.Define("PLOT_INFLUENCE_NW_COST",-105) end
            local yields=R.TileYields(tile,c,state)
            score=score+Value(yields,{1,1,1,1,1,1})*R.Define("PLOT_INFLUENCE_YIELD_POINT_COST",-1)
            candidates[#candidates+1]={index=index,score=score,influence=state.influence[index],yields=yields}
        end
    end
    table.sort(candidates,function(a,b) if a.score==b.score then return a.index<b.index end;return a.score<b.score end)
    return candidates
end
local function Purchase(tiles,state,c,plan,turn)
    if state.purchases>=2 or R.Define("BUY_PLOTS_DISABLED",0)~=0 then return end
    local candidates=BorderCandidates(tiles,state,c)
    local cheapest=math.huge
    for _,candidate in ipairs(candidates) do cheapest=math.min(cheapest,candidate.influence) end
    local best,best_gain
    for _,candidate in ipairs(candidates) do
        local tile=tiles[candidate.index]
        if tile.distance<=R.Define("MAXIMUM_BUY_PLOT_DISTANCE",3) then
            local base=R.Define("PLOT_BASE_COST",50)+state.purchases*R.Define("PLOT_ADDITIONAL_COST_PER_PLOT",5)
            base=math.floor(base*(100+R.Trait(c,"PlotBuyCostModifier"))/100)
            local factor=R.Define("PLOT_INFLUENCE_BASE_MULTIPLIER",100)
                +(candidate.influence-cheapest)*R.Define("PLOT_INFLUENCE_DISTANCE_MULTIPLIER",100)/R.Define("PLOT_INFLUENCE_DISTANCE_DIVISOR",3)
            if R.Revealed(tile,state.techs) then factor=factor+R.Define("PLOT_BUY_RESOURCE_COST",-100) end
            local cost=math.floor(base*math.max(100,factor)/100)
            cost=math.floor(cost*(c.speed.GoldPercent or 100)/100)
            local divisor=R.Define("PLOT_COST_APPEARANCE_DIVISOR",5)
            cost=math.max(divisor,math.floor(cost/divisor)*divisor)
            local resource=R.Revealed(tile,state.techs) and R.Row("Resources",tile.resource)
            local gain=Value(candidate.yields,plan.weights)+(resource and (resource.Happiness or 0) or 0)
            -- Spend only accumulated gold, and retain a maintenance reserve.
            if state.gold>=cost+20 and (resource or tile.wonder) and (not best_gain or gain>best_gain) then
                best,best_gain={index=candidate.index,cost=cost},gain
            end
        end
    end
    if best then
        state.gold=state.gold-best.cost;state.gold_spent=state.gold_spent+best.cost
        state.owned[best.index]=true;state.acquired[best.index]=turn;state.purchases=state.purchases+1
        state.revision=state.revision+1
    end
end

local function AvailableProject(c,state,name)
    local kind=name:sub(1,5)=="UNIT_" and "unit" or "building"
    local row=R.Resolve(c,kind,name)
    if not row or (row.PrereqTech and not state.techs[row.PrereqTech]) then return nil end
    if kind=="unit" then
        if row.Domain=="DOMAIN_SEA" and not state.center.coastal then return nil end
        for _,resource in ipairs(R.Group("Unit_ResourceQuantityRequirements","UnitType",row.Type)) do
            if (state.resources[resource.ResourceType] or 0)<(resource.Cost or 0) then return nil end
        end
    end
    if kind=="building" then
        if state.buildings[row.Type] or (row.Cost or -1)<0 then return nil end
        if R.True(row.Water) and not state.center.coastal then return nil end
        if R.True(row.River) and not state.center.river then return nil end
        if R.True(row.FreshWater) and not state.center.fresh then return nil end
    elseif R.True(row.Found) then
        if state.population<R.Define("CITY_MIN_SIZE_FOR_SETTLERS",2) or R.Trait(c,"NoAnnexing")>0 then return nil end
        if state.happiness<=R.Define("VERY_UNHAPPY_THRESHOLD",-10) then return nil end
    end
    return {kind=kind,row=row,cost=R.Cost(row,kind,c),progress=0,settler=kind=="unit" and R.True(row.Food)}
end
local function NextProject(c,state,plan)
    -- Coastal food needs its own worker. A boat is only commissioned for an
    -- owned, legally improvable sea resource and is consumed on completion.
    if state.center.coastal and state.sea_targets>0 then
        local active=0
        for _,unit in ipairs(state.units) do if unit.row.Domain=="DOMAIN_SEA" and not unit.consumed then active=active+1 end end
        if active<state.sea_targets then
            local boat=AvailableProject(c,state,"UNIT_WORKBOAT")
            if boat then return boat end
        end
    end
    if plan.name=="growth" and state.center.coastal and state.sea_workable>=2 then
        local lighthouse=AvailableProject(c,state,"BUILDING_LIGHTHOUSE")
        if lighthouse then return lighthouse end
    end
    for index,name in ipairs(plan.builds) do
        if not state.orders[index] then
            local project=AvailableProject(c,state,name)
            if project then project.order=index;return project end
        end
    end
    return AvailableProject(c,state,plan.name=="military" and "UNIT_ARCHER" or "UNIT_WORKER")
end

local function WorkerAction(unit,tiles,state,c,plan,turn,horizon)
    if unit.consumed or turn<unit.available then return end
    if unit.job then
        if turn<unit.job.begin then return end
        unit.job.progress=unit.job.progress+R.WorkRate(c,unit.row)
        if unit.job.progress>=unit.job.work then
            local tile=tiles[unit.job.index]
            local feature=unit.job.feature
            local production,food=R.Chop(feature,c,tile.distance)
            if not state.owned[unit.job.index] then
                local percent=R.Define("DIFFERENT_TEAM_FEATURE_PRODUCTION_PERCENT",50)
                production,food=math.floor(production*percent/100),math.floor(food*percent/100)
            end
            if feature and R.True(feature.Remove) then tile.feature=nil end
            tile.improvement=unit.job.build.ImprovementType or tile.improvement
            local improvement=R.Row("Improvements",tile.improvement)
            if improvement and R.True(improvement.RemovesResource) then tile.resource=nil end
            state.chop_production=state.chop_production+production;state.chop_food=state.chop_food+food
            state.pending_chop=state.pending_chop+production;state.food=state.food+food
            unit.x,unit.y=tile.x,tile.y
            if R.True(unit.job.build.Kill) then unit.consumed=true end
            state.improvements[#state.improvements+1]={index=tile.index,build=unit.job.build.Type,turn=turn}
            unit.job=nil;unit.available=turn+1;state.revision=state.revision+1
        end
        return
    end
    local builds=R.WorkerBuilds(c,unit.row)
    if #builds==0 then return end
    local kind=unit.row.Domain=="DOMAIN_SEA" and "workboat" or "worker"
    local field=T.Field(unit.x,unit.y,c,kind,6,tiles,state.owned)
    local best,best_value
    local occupied={}
    for _,other in ipairs(state.units) do if other~=unit and other.job then occupied[other.job.index]=true end end
    for index,tile in Lekmap_Utilities.OrderedPairs(tiles) do
        if not tile.city and tile.distance<=3 and not tile.wonder and not occupied[index] then
            local first=T.FirstWorkTurn(field,index)
            if first then
                for _,build in ipairs(builds) do
                    local allowed,feature=R.BuildAllowed(tile,build,c,state.techs)
                    if allowed and (state.owned[index] or not build.ImprovementType) then
                        local proposed=CopyMap(tile)
                        if feature and R.True(feature.Remove) then proposed.feature=nil end
                        proposed.improvement=build.ImprovementType or proposed.improvement
                        local imp=R.Row("Improvements",proposed.improvement)
                        if imp and R.True(imp.RemovesResource) then proposed.resource=nil end
                        local before=R.TileYields(tile,c,state)
                        local after=R.TileYields(proposed,c,state)
                        local work=R.BuildWork(tile,build,c,state.techs)
                        local work_turns=math.max(1,math.ceil(work/R.WorkRate(c,unit.row)))
                        local finish=turn+first-1+work_turns-1
                        local production,food=R.Chop(feature,c,tile.distance)
                        if not state.owned[index] then
                            local percent=R.Define("DIFFERENT_TEAM_FEATURE_PRODUCTION_PERCENT",50)/100
                            production,food=math.floor(production*percent),math.floor(food*percent)
                        end
                        local resource=R.Revealed(proposed,state.techs) and R.Row("Resources",proposed.resource)
                        local connects=false
                        for _,rule in ipairs(R.Group("Improvement_ResourceTypes","ImprovementType",proposed.improvement)) do
                            if resource and rule.ResourceType==resource.Type and R.True(rule.ResourceTrade) then connects=true end
                        end
                        local happiness=(connects and resource and (resource.Happiness or 0)>0 and not state.luxuries[resource.Type]) and resource.Happiness or 0
                        local gain=Value(after,plan.weights)-Value(before,plan.weights)
                        local score=(gain*math.max(0,horizon-finish)+production*plan.weights[2]+food*plan.weights[1]+happiness*8)/(first+work_turns)
                        if finish<=horizon and score>0 and (not best_value or score>best_value) then
                            best={index=index,build=build,feature=feature,work=work,progress=0,begin=turn+first-1};best_value=score
                        end
                    end
                end
            end
        end
    end
    if best then unit.job=best;WorkerAction(unit,tiles,state,c,plan,turn,horizon) end
end

function O.Simulate(x,y,c,plan,horizon,proposed)
    Initialize()
    local tiles,origin=CollectTiles(x,y)
    for index,changes in pairs(proposed or {}) do
        if tiles[index] then for field,value in pairs(changes) do tiles[index][field]=value end end
    end
    horizon=horizon or math.max(20,math.min(150,R.Scale(40,c,"TrainPercent")))
    local state={center=tiles[origin],population=R.Define("INITIAL_CITY_POPULATION",1)+(c.era.FreePopulation or 0),
        food=0,gold=(c.handicap.Gold or 0)+(c.era.StartingGold or 0),gold_spent=0,faith=0,culture=0,border_culture=0,
        techs=CopyMap(c.techs),buildings=R.InitialBuildings(c),owned={},acquired={},orders={},units={},
        completed={},improvements={},research={},purchases=0,border_level=0,revision=0,
        pending_chop=0,chop_production=0,chop_food=0,settlers={},population_turns=0,
        totals=R.Zero(),military_production=0,military_strength=0,luxuries={},resources={},starvation_turns=0,unhappy_turns=0,sea_targets=0,sea_workable=0}
    for index,tile in pairs(tiles) do if tile.distance<=1 and not tile.blocked then state.owned[index]=true;state.acquired[index]=0 end end
    for _=1,math.min(36,R.Trait(c,"ExtraFoundedCityTerritoryClaimRange")) do
        local candidates=BorderCandidates(tiles,state,c)
        if #candidates==0 then break end
        local index=candidates[1].index
        state.owned[index]=true;state.acquired[index]=0;state.revision=state.revision+1
    end
    local warrior=R.Resolve(c,"unit","UNIT_WARRIOR")
    if warrior then state.units[1]={row=warrior,x=x,y=y,available=1} end
    local plan_research={}
    local has_sea=false
    for _,tile in Lekmap_Utilities.OrderedPairs(tiles) do
        local resource=R.Row("Resources",tile.resource)
        if tile.distance<=2 and resource then
            if tile.water then has_sea=true end
            if (resource.Happiness or 0)>0 and resource.TechCityTrade then plan_research[#plan_research+1]=resource.TechCityTrade end
        end
    end
    -- Keep each plan's first technology, then respond to local connection needs.
    table.insert(plan_research,1,plan.techs[1])
    if has_sea and state.center.coastal then table.insert(plan_research,2,"TECH_SAILING") end
    if has_sea and state.center.coastal and plan.name=="growth" then table.insert(plan_research,3,"TECH_OPTICS") end
    for _,tech in ipairs(plan.techs) do plan_research[#plan_research+1]=tech end
    local research_progress=0
    local allocation_cache={}
    for turn=1,horizon do
        state.turn=turn
        state.happiness,state.luxuries,state.luxury_copies=R.Happiness(c,state,tiles)
        for _,unit in ipairs(state.units) do if (unit.row.WorkRate or 0)>0 then WorkerAction(unit,tiles,state,c,plan,turn,horizon) end end
        Purchase(tiles,state,c,plan,turn)
        state.resources=R.ConnectedResources(c,state,tiles)
        state.sea_targets=0
        state.sea_workable=0
        local boat=R.Resolve(c,"unit","UNIT_WORKBOAT")
        if boat then
            for index,tile in pairs(tiles) do
                if state.owned[index] and tile.water and tile.distance<=3 and tile.resource and not tile.improvement then
                    for _,build in ipairs(R.WorkerBuilds(c,boat)) do
                        if R.BuildAllowed(tile,build,c,state.techs) then state.sea_targets=state.sea_targets+1;break end
                    end
                end
                if state.owned[index] and tile.water and tile.distance<=3 then state.sea_workable=state.sea_workable+1 end
            end
        end
        state.project=state.project or NextProject(c,state,plan)
        local center_yields=R.TileYields(state.center,c,state,true)
        local base=R.Add(center_yields,R.CityExtras(c,state))
        local settler=state.project and state.project.settler
        local key=state.population..":"..state.revision..":"..tostring(settler)
        local allocation=allocation_cache[key]
        if not allocation then
            allocation=O.Allocate(tiles,state.owned,state.population,base,c,state,plan,settler)
            allocation_cache[key]=allocation
        end
        local yields=R.Copy(allocation.yields)
        local maintenance=R.Maintenance(c,state,turn)
        local net_gold=yields[3]-maintenance
        if state.gold+net_gold<0 then yields[4]=math.max(0,yields[4]+state.gold+net_gold) end
        state.gold=math.max(0,state.gold+net_gold)
        state.faith=state.faith+yields[6];state.culture=state.culture+yields[5];state.border_culture=state.border_culture+yields[5]
        local surplus=yields[1]-state.population*R.Define("FOOD_CONSUMPTION_PER_POPULATION",2)
        state.happiness,state.luxuries,state.luxury_copies=R.Happiness(c,state,tiles)
        if state.happiness<0 then state.unhappy_turns=state.unhappy_turns+1 end
        local modifier=state.project and R.ProductionModifier(c,state,state.project) or 0
        local production=yields[2]+yields[2]/math.max(0.01,R.ModifyCityYields({1,1,1,1,1,1},c,state)[2])*modifier/100
            +(settler and R.SettlerFood(math.floor(surplus)) or 0)+state.pending_chop
        state.pending_chop=0
        if not settler then
            local growth=surplus
            if growth>0 then
                local modifier=state.happiness<=R.Define("VERY_UNHAPPY_THRESHOLD",-10) and R.Define("VERY_UNHAPPY_GROWTH_PENALTY",-100)
                    or state.happiness<0 and R.Define("UNHAPPY_GROWTH_PENALTY",-75) or 0
                growth=growth*math.max(0,100+modifier)/100
            end
            state.food=state.food+growth
            local threshold=R.GrowthThreshold(state.population,c)
            if state.food>=threshold then
                local kept=0;for name in pairs(state.buildings) do kept=kept+((R.Row("Buildings",name) or {}).FoodKept or 0) end
                state.food=state.food-threshold+math.floor(threshold*math.min(100,kept)/100)
                state.population=state.population+1
                state.revision=state.revision+1
                if state.population==4 then state.population_four=turn end
            elseif state.food<0 then
                state.starvation_turns=state.starvation_turns+1
                state.food=0;state.population=math.max(1,state.population-1);state.revision=state.revision+1
            end
        end
        if state.project then
            local project=state.project
            project.progress=project.progress+production
            if project.kind=="unit" and ((project.row.Combat or 0)>0 or (project.row.RangedCombat or 0)>0) then
                state.military_production=state.military_production+production
            end
            if project.progress>=project.cost then
                state.completed[#state.completed+1]={type=project.row.Type,turn=turn,cost=project.cost}
                if project.order then state.orders[project.order]=true end
                if project.kind=="building" then state.buildings[project.row.Type]=true
                else
                    state.units[#state.units+1]={row=project.row,x=x,y=y,available=turn+1}
                    state.military_strength=state.military_strength+math.max(project.row.Combat or 0,project.row.RangedCombat or 0)
                    if R.True(project.row.Found) then state.settlers[#state.settlers+1]=turn end
                end
                local overflow=math.min(project.cost,project.progress-project.cost)
                state.project=NextProject(c,state,plan)
                if state.project then state.project.progress=overflow end
                state.revision=state.revision+1
            end
        end
        local tech=R.NextResearch(plan_research,state.techs)
        if tech then
            research_progress=research_progress+yields[4]
            local cost=R.ResearchCost(tech,c,state.techs)
            if research_progress>=cost then
                research_progress=research_progress-cost;state.techs[tech]=true
                state.research[#state.research+1]={type=tech,turn=turn};state.revision=state.revision+1
            end
        end
        if state.border_culture>=R.BorderThreshold(state.border_level,c) then
            local candidates=BorderCandidates(tiles,state,c)
            if #candidates>0 then
                state.border_culture=state.border_culture-R.BorderThreshold(state.border_level,c)
                local index=candidates[1].index
                state.owned[index]=true;state.acquired[index]=turn;state.border_level=state.border_level+1;state.revision=state.revision+1
            end
        end
        if not state.pantheon_ready and state.faith>=R.Define("RELIGION_MIN_FAITH_FIRST_PANTHEON",10) then state.pantheon_ready=turn end
        state.population_turns=state.population_turns+state.population
        R.Add(state.totals,yields)
        state.last_yields=yields;state.last_worked=allocation.worked
        if plan.trace then
            state.history=state.history or {}
            state.history[turn]={population=state.population,food=state.food,gold=state.gold,
                worked=allocation.worked,settler=settler==true,yields=yields,production=production}
        end
    end
    state.happiness,state.luxuries,state.luxury_copies=R.Happiness(c,state,tiles)
    state.expansion_happiness=R.Happiness(c,state,tiles,1,1)
    state.horizon=horizon;state.tiles=tiles;state.plan=plan.name
    return state
end

function O.Evaluate(x,y,c,horizon,proposed)
    Initialize()
    local key=x..":"..y..":"..tostring(c.player)..":"..tostring(c.neutral)..":"..tostring(horizon)
    if not proposed and cache[key] then return cache[key] end
    if not O.Available() then return nil end
    local result={profiles={}}
    for _,plan in ipairs(O.PLANS) do result.profiles[plan.name]=O.Simulate(x,y,c,plan,horizon,proposed) end
    result.scores={}
    for name,s in pairs(result.profiles) do
        -- Explicit comparison weights, not a predicted victory probability.
        local economy=s.gold/s.horizon*0.2+s.totals[4]/s.horizon*0.15+s.faith/s.horizon*0.25
        if name=="growth" then result.scores[name]=s.population_turns/s.horizon+economy
        elseif name=="expansion" then
            local readiness=0
            for _,turn in ipairs(s.settlers) do readiness=readiness+1+(s.horizon-turn)/s.horizon end
            if s.project and s.project.settler then readiness=readiness+s.project.progress/s.project.cost end
            result.scores[name]=1+readiness*2+math.max(0,s.expansion_happiness)*0.2+economy
        else result.scores[name]=1+s.military_production/s.horizon+s.military_strength*0.1+economy end
    end
    if not proposed then cache[key]=result end
    return result
end
