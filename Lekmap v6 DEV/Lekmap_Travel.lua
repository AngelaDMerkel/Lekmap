------------------------------------------------------------------------------
-- Movement-aware travel estimates. A path tracks spent movement within each
-- turn: entering a hill with the last movement point is legal in Civ V.
------------------------------------------------------------------------------
Lekmap_Travel = {}
local T=Lekmap_Travel
local R= nil
local function Rules() R=R or Lekmap_StartRules;return R end
local function Index(x,y) local width=Map.GetGridSize();return y*width+x+1 end

function T.Profile(context,kind)
    local r=Rules()
    local name=kind=="worker" and "UNIT_WORKER" or kind=="settler" and "UNIT_SETTLER" or kind=="workboat" and "UNIT_WORKBOAT" or kind=="sea" and "UNIT_TRIREME" or "UNIT_WARRIOR"
    local unit=r.Resolve(context,"unit",name) or {Moves=2}
    local profile={moves=unit.Moves or 2,sea=kind=="sea" or kind=="workboat",ignore=false,hills_double=false,
        faster_hills=r.Trait(context,"FasterInHills")>0,faster_river=r.Trait(context,"FasterAlongRiver")>0,
        woods_roads=r.Trait(context,"MoveFriendlyWoodsAsRoad")>0}
    local promotions={}
    for _,row in ipairs(r.Group("Unit_FreePromotions","UnitType",unit.Type)) do promotions[row.PromotionType]=true end
    for trait in Lekmap_Utilities.OrderedPairs(context.traits) do
        for _,row in ipairs(r.Group("Trait_FreePromotions","TraitType",trait)) do promotions[row.PromotionType]=true end
        for _,row in ipairs(r.Group("Trait_FreePromotionUnitCombats","TraitType",trait)) do
            if row.UnitCombatType==unit.CombatClass then promotions[row.PromotionType]=true end
        end
        for _,row in ipairs(r.Group("Trait_MovesChangeUnitCombats","TraitType",trait)) do
            if row.UnitCombatType==unit.CombatClass then profile.moves=profile.moves+(row.MovesChange or 0) end
        end
    end
    for name in Lekmap_Utilities.OrderedPairs(promotions) do
        local p=r.Row("UnitPromotions",name) or {}
        profile.moves=profile.moves+(p.MovesChange or 0)
        profile.ignore=profile.ignore or r.True(p.IgnoreTerrainCost)
        profile.hills_double=profile.hills_double or r.True(p.HillsDoubleMove)
        profile.rough_ends=profile.rough_ends or r.True(p.RoughTerrainEndsTurn)
        profile.discount=(profile.discount or 0)+(p.MoveDiscountChange or 0)
    end
    profile.moves=math.max(1,profile.moves)
    profile.denominator=r.Define("MOVE_DENOMINATOR",60)
    return profile
end

local function Push(heap,item)
    local i=#heap+1;heap[i]=item
    while i>1 do
        local parent=math.floor(i/2)
        if heap[parent].cost<item.cost or (heap[parent].cost==item.cost and heap[parent].index<=item.index) then break end
        heap[i]=heap[parent];i=parent
    end
    heap[i]=item
end
local function Pop(heap)
    local first,last=heap[1],table.remove(heap)
    if #heap>0 then
        local i=1
        while i*2<=#heap do
            local child=i*2
            if child<#heap and (heap[child+1].cost<heap[child].cost or
                (heap[child+1].cost==heap[child].cost and heap[child+1].index<heap[child].index)) then child=child+1 end
            if last.cost<heap[child].cost or (last.cost==heap[child].cost and last.index<=heap[child].index) then break end
            heap[i]=heap[child];i=child
        end
        heap[i]=last
    end
    return first
end

function T.StepCost(from,to,direction,profile,spent,overrides,owned)
    local r=Rules()
    local tile=overrides and overrides[Index(to:GetX(),to:GetY())] or r.Snapshot(to)
    if tile.blocked or tile.mountain or tile.wonder or tile.feature=="FEATURE_ICE" then return nil end
    if profile.sea~=tile.water then return nil end
    local feature=r.Row("Features",tile.feature)
    local terrain=r.Row("Terrains",tile.terrain) or {}
    if feature and r.True(feature.Impassable) then return nil end
    local maximum=profile.moves*profile.denominator
    local remaining=maximum-(spent%maximum)
    local crossing=from.IsRiverCrossing and from:IsRiverCrossing(direction) or false
    local cost
    if profile.ignore or (profile.faster_hills and tile.hills) or
        (profile.faster_river and tile.river and from:IsRiverSide()) then cost=1
    else
        cost=(feature and feature.Movement) or terrain.Movement or 1
        if tile.hills then cost=cost+r.Define("HILLS_EXTRA_MOVEMENT",1) end
        cost=math.max(1,cost-(profile.discount or 0))
    end
    if (crossing and not profile.ignore and not profile.faster_river) or
        (profile.rough_ends and (tile.hills or tile.feature=="FEATURE_FOREST" or tile.feature=="FEATURE_JUNGLE")) then return remaining end
    cost=cost*profile.denominator
    if tile.hills and profile.hills_double then cost=math.floor(cost/2) end
    if profile.woods_roads and owned and owned[Index(tile.x,tile.y)] and
        (tile.feature=="FEATURE_FOREST" or tile.feature=="FEATURE_JUNGLE") and not crossing then
        local road=r.Row("Routes","ROUTE_ROAD") or {}
        cost=math.min(cost,road.Movement or 30)
    end
    return math.max(1,math.min(remaining,cost))
end

function T.Field(x,y,context,kind,max_turns,overrides,owned)
    local width=Map.GetGridSize()
    local profile=T.Profile(context,kind)
    local origin=Index(x,y)
    local costs,parents={[origin]=0},{}
    local snapshots=overrides or {}
    local heap={};Push(heap,{index=origin,cost=0})
    local limit=(max_turns or 1000)*profile.moves*profile.denominator
    while #heap>0 do
        local item=Pop(heap)
        if costs[item.index]==item.cost then
            local from=Map.GetPlot((item.index-1)%width,math.floor((item.index-1)/width))
            for direction=0,5 do
                local to=Map.PlotDirection(from:GetX(),from:GetY(),direction)
                if to then
                    local index=Index(to:GetX(),to:GetY())
                    -- Worker plans only inspect their local virtual map. A
                    -- global survey snapshots each plot once, not per edge.
                    if not overrides and not snapshots[index] then snapshots[index]=Rules().Snapshot(to) end
                    local step=snapshots[index] and T.StepCost(from,to,direction,profile,item.cost,snapshots,owned)
                    local next_cost=step and item.cost+step
                    if next_cost and next_cost<=limit and (not costs[index] or next_cost<costs[index]) then
                        costs[index],parents[index]=next_cost,item.index
                        Push(heap,{index=index,cost=next_cost})
                    end
                end
            end
        end
    end
    return {costs=costs,parents=parents,profile=profile,origin=origin}
end
function T.ArrivalTurns(field,index)
    local cost=field.costs[index]
    if cost==nil then return nil end
    return cost/(field.profile.moves*field.profile.denominator)
end
function T.FirstWorkTurn(field,index)
    local cost=field.costs[index]
    if cost==nil then return nil end
    return math.floor(cost/(field.profile.moves*field.profile.denominator))+1
end

function T.Influence(tiles,origin)
    local r=Rules()
    local costs={[origin]=0}
    local heap={};Push(heap,{index=origin,cost=0})
    while #heap>0 do
        local item=Pop(heap)
        if costs[item.index]==item.cost then
            local from=tiles[item.index]
            local plot=Map.GetPlot(from.x,from.y)
            for direction=0,5 do
                local to=Map.PlotDirection(from.x,from.y,direction)
                local index=to and Index(to:GetX(),to:GetY())
                local tile=index and tiles[index]
                if tile and not tile.blocked then
                    local step=1
                    if item.index~=origin or r.Define("USE_FIRST_RING_INFLUENCE_TERRAIN_COST",0)~=0 then
                        step=tile.mountain and r.Define("INFLUENCE_MOUNTAIN_COST",3) or
                            ((r.Row("Terrains",tile.terrain) or {}).InfluenceCost or 1)
                            +((r.Row("Features",tile.feature) or {}).InfluenceCost or 0)
                            +(tile.hills and r.Define("INFLUENCE_HILL_COST",1) or 0)
                        if plot.IsRiverCrossing and plot:IsRiverCrossing(direction) then step=step+r.Define("INFLUENCE_RIVER_COST",1) end
                        step=math.max(1,math.min(3,step))
                    end
                    local cost=item.cost+step
                    if not costs[index] or cost<costs[index] then costs[index]=cost;Push(heap,{index=index,cost=cost}) end
                end
            end
        end
    end
    return costs
end

-- Internally vertex-disjoint routes from a capital to its sixth land ring.
-- Narrow passages outside the first ring are counted as actual bottlenecks.
function T.ExitCapacity(x,y,radius)
    local width=Map.GetGridSize()
    local center=Index(x,y)
    local local_nodes={}
    for plot in Lekmap_HexUtil.PlotAreaSpiralIterator(Map.GetPlot(x,y),radius,nil,nil,nil,true) do
        if not plot:IsWater() and not plot:IsMountain() and not plot:IsNaturalWonder() and plot:GetFeatureType()~=FeatureTypes.FEATURE_ICE then
            local_nodes[Index(plot:GetX(),plot:GetY())]=plot
        end
    end
    local graph={}
    local function edge(a,b,capacity)
        graph[a]=graph[a] or {};graph[b]=graph[b] or {}
        local forward={to=b,capacity=capacity,reverse=#graph[b]+1}
        local backward={to=a,capacity=0,reverse=#graph[a]+1}
        graph[a][#graph[a]+1]=forward;graph[b][#graph[b]+1]=backward
    end
    local source,sink=center*2+1,-1
    for index,plot in Lekmap_Utilities.OrderedPairs(local_nodes) do
        edge(index*2,index*2+1,index==center and 6 or 1)
        if Map.PlotDistance(x,y,plot:GetX(),plot:GetY())==radius then edge(index*2+1,sink,1) end
        for direction=0,5 do
            local other=Map.PlotDirection(plot:GetX(),plot:GetY(),direction)
            local next_index=other and Index(other:GetX(),other:GetY())
            if next_index and local_nodes[next_index] then edge(index*2+1,next_index*2,6) end
        end
    end
    local flow=0
    for _=1,6 do
        local queue,head,parent={source},1,{[source]=true}
        while head<=#queue and not parent[sink] do
            local at=queue[head];head=head+1
            for i,e in ipairs(graph[at] or {}) do
                if e.capacity>0 and not parent[e.to] then parent[e.to]={at=at,edge=i};queue[#queue+1]=e.to end
            end
        end
        if not parent[sink] then break end
        local at=sink
        while at~=source do
            local p=parent[at];local e=graph[p.at][p.edge]
            e.capacity=e.capacity-1;graph[at][e.reverse].capacity=graph[at][e.reverse].capacity+1;at=p.at
        end
        flow=flow+1
    end
    return flow
end
