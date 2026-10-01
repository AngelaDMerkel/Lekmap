------------------------------------------------------------------------------
-- Read the active rules database for hypothetical opening evaluations. These
-- functions never create cities/units, alter plots, research techs or spend RNG.
------------------------------------------------------------------------------
Lekmap_StartRules = {}
local R = Lekmap_StartRules
R.YIELDS = {"YIELD_FOOD","YIELD_PRODUCTION","YIELD_GOLD","YIELD_SCIENCE","YIELD_CULTURE","YIELD_FAITH"}
local yield_number={}
for i,name in ipairs(R.YIELDS) do yield_number[name]=i end
local tables,indices,contexts,yield_cache={},{},{},{}

function R.True(value) return value==true or value==1 end
function R.Zero() return {0,0,0,0,0,0} end
function R.Copy(value) local out={};for i=1,6 do out[i]=value[i] or 0 end;return out end
function R.Add(target,value,multiplier)
    for i=1,6 do target[i]=(target[i] or 0)+(value[i] or 0)*(multiplier or 1) end
    return target
end
function R.Define(name,default)
    local value=GameDefines and tonumber(GameDefines[name])
    return value~=nil and value or default
end
function R.Reset() tables,indices,contexts,yield_cache={},{},{},{} end

function R.Rows(name)
    if tables[name] then return tables[name] end
    local rows={}
    local source=GameInfo[name]
    if source then
        local ok,result=pcall(function()
            local out={};for row in source() do out[#out+1]=row end;return out
        end)
        if ok then rows=result end
    end
    tables[name]=rows
    return rows
end
function R.Group(name,column,value)
    local key=name..":"..column
    if not indices[key] then
        local index={}
        for _,row in ipairs(R.Rows(name)) do
            local field=row[column]
            if field~=nil then index[field]=index[field] or {};index[field][#index[field]+1]=row end
        end
        indices[key]=index
    end
    return indices[key][value] or {}
end
function R.Row(name,value)
    if value==nil then return nil end
    local source=GameInfo[name]
    if source and source[value] then return source[value] end
    for _,row in ipairs(R.Rows(name)) do if row.Type==value or row.ID==value then return row end end
end
function R.YieldChanges(name,column,value,filters)
    local key=name..":"..column..":"..tostring(value)
    if filters then
        for field,expected in Lekmap_Utilities.OrderedPairs(filters) do key=key..":"..field.."="..tostring(expected) end
    end
    if yield_cache[key] then return yield_cache[key] end
    local out=R.Zero()
    for _,row in ipairs(R.Group(name,column,value)) do
        local matches=true
        for field,expected in pairs(filters or {}) do if row[field]~=expected then matches=false;break end end
        local i=yield_number[row.YieldType]
        if matches and i then out[i]=out[i]+(row.Yield or 0) end
    end
    yield_cache[key]=out
    return out
end

local function ReadCall(object,method,default)
    if object and object[method] then
        local ok,value=pcall(object[method],object)
        if ok and value~=nil then return value end
    end
    return default
end
function R.Context(player_id,neutral)
    local key=tostring(player_id)..":"..tostring(neutral==true)
    if contexts[key] then return contexts[key] end
    local player=player_id~=nil and Players and Players[player_id]
    local speed_id=Game.GetGameSpeedType and Game.GetGameSpeedType() or 2
    local era_id=Game.GetStartEra and Game.GetStartEra() or 0
    local speed=R.Row("GameSpeeds",speed_id) or {}
    local era=R.Row("Eras",era_id) or {}
    local c={player=player_id,neutral=neutral==true,speed=speed,era=era,traits={},techs={},
        team=ReadCall(player,"GetTeam",player_id),civ=nil,worker_speed=0}
    if not neutral and player then
        local civ=R.Row("Civilizations",ReadCall(player,"GetCivilizationType",nil))
        c.civ=civ and civ.Type
        local leader=R.Row("Leaders",ReadCall(player,"GetLeaderType",nil))
        local leaders={}
        if leader then leaders[leader.Type]=true end
        if not leader and c.civ then
            for _,row in ipairs(R.Group("Civilization_Leaders","CivilizationType",c.civ)) do leaders[row.LeaderheadType]=true end
        end
        for _,row in ipairs(R.Rows("Leader_Traits")) do
            if leaders[row.LeaderType] then c.traits[row.TraitType]=true end
        end
    end
    -- The common ancient baseline starts with Agriculture. Additional free
    -- technologies come from the selected civilization and initialized team.
    c.techs.TECH_AGRICULTURE=true
    if c.civ then
        for _,row in ipairs(R.Group("Civilization_FreeTechs","CivilizationType",c.civ)) do c.techs[row.TechType]=true end
    end
    local team=not neutral and Teams and c.team~=nil and Teams[c.team]
    for _,tech in ipairs(R.Rows("Technologies")) do
        local tech_era=R.Row("Eras",tech.Era)
        if tech_era and tech_era.ID<(era.ID or 0) then c.techs[tech.Type]=true end
        if team and team.IsHasTech and team:IsHasTech(tech.ID) then c.techs[tech.Type]=true end
    end
    c.handicap=R.Row("HandicapInfos",ReadCall(player,"GetHandicapType",3)) or R.Row("HandicapInfos","HANDICAP_PRINCE") or {}
    contexts[key]=c
    return c
end
function R.Trait(c,field)
    local total=0
    for name in Lekmap_Utilities.OrderedPairs(c.traits) do
        local row=R.Row("Traits",name)
        local value=row and row[field]
        if R.True(value) then total=total+1 elseif type(value)=="number" then total=total+value end
    end
    return total
end
function R.TraitYields(c,name,filters)
    local out=R.Zero()
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do R.Add(out,R.YieldChanges(name,"TraitType",trait,filters)) end
    return out
end
function R.Scale(value,c,field)
    value=math.floor(value*(c.speed[field] or 100)/100)
    return math.floor(value*(c.era[field] or 100)/100)
end
function R.GrowthThreshold(population,c)
    local extra=population-1
    local value=R.Define("BASE_CITY_GROWTH_THRESHOLD",15)
        +math.floor(extra*R.Define("CITY_GROWTH_MULTIPLIER",6))
        +math.floor(extra^R.Define("CITY_GROWTH_EXPONENT",1.8))
    return math.max(1,R.Scale(value,c,"GrowthPercent"))
end
function R.BorderThreshold(level,c)
    local value=R.Define("CULTURE_COST_FIRST_PLOT",15)
        +math.floor((level*R.Define("CULTURE_COST_LATER_PLOT_MULTIPLIER",8))^R.Define("CULTURE_COST_LATER_PLOT_EXPONENT",1.1))
    value=math.floor(value*(100+math.max(R.Define("CULTURE_PLOT_COST_MOD_MINIMUM",-85),R.Trait(c,"PlotCultureCostModifier")))/100)
    value=math.floor(value*(c.speed.CulturePercent or 100)/100)
    local divisor=R.Define("CULTURE_COST_VISIBLE_DIVISOR",5)
    if value>divisor*2 then value=math.floor(value/divisor)*divisor end
    return math.max(1,value)
end
function R.SettlerFood(surplus)
    if surplus<=0 then return 0 end
    if surplus<=2 then return math.floor(surplus) end
    if surplus<=4 then return math.floor(2+(surplus-2)*0.5) end
    return math.floor(3+(surplus-4)*0.25)
end

function R.Snapshot(plot,origin)
    local terrain=R.Row("Terrains",plot:GetTerrainType())
    local feature=R.Row("Features",plot:GetFeatureType())
    local resource=R.Row("Resources",plot:GetResourceType(-1))
    return {x=plot:GetX(),y=plot:GetY(),terrain=terrain and terrain.Type,feature=feature and feature.Type,
        resource=resource and resource.Type,quantity=plot:GetNumResource(),hills=plot:IsHills(),mountain=plot:IsMountain(),water=plot:IsWater(),
        lake=plot:IsLake(),river=plot:IsRiverSide(),fresh=plot:IsFreshWater(),coastal=plot:IsCoastalLand(),
        wonder=plot:IsNaturalWonder(),distance=origin and Map.PlotDistance(origin.x,origin.y,plot:GetX(),plot:GetY()) or 0}
end
function R.Revealed(tile,known)
    local row=R.Row("Resources",tile.resource)
    if row and row.TechReveal==nil and #R.Rows("Technologies")==0 and Game.GetResourceUsageType
        and Game.GetResourceUsageType(row.ID)==ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then return false end
    return row and (not row.TechReveal or known[row.TechReveal]) and not row.PolicyReveal
end
function R.TileYields(tile,c,state,city)
    state=state or {techs=c.techs,buildings={}}
    local known=state.techs or c.techs
    local feature=not city and R.Row("Features",tile.feature) or nil
    if tile.feature=="FEATURE_ICE" or (tile.mountain and not tile.wonder) then return R.Zero() end
    local out=R.Copy(R.YieldChanges("Terrain_Yields","TerrainType",tile.terrain))
    local infos=R.Rows("Yields")
    for _,info in ipairs(infos) do
        local i=yield_number[info.Type]
        if i then
            if tile.hills then out[i]=out[i]+(info.HillsChange or 0) end
            if tile.mountain then out[i]=out[i]+(info.MountainChange or 0) end
            if tile.lake then out[i]=out[i]+(info.LakeChange or 0) end
        end
    end
    -- Minimal API fixtures may omit the Yields metadata; real games provide it.
    if #infos==0 then
        if tile.hills then out[1],out[2]=0,2 end
        if tile.lake then out[1],out[2]=2,0 end
    end
    if feature then
        local f=R.Copy(R.YieldChanges("Feature_YieldChanges","FeatureType",feature.Type))
        for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
            for _,row in ipairs(R.Group("Trait_FeatureYieldChanges","TraitType",trait)) do
                local i=yield_number[row.YieldType]
                if i and row.FeatureType==feature.Type and (not tile.improvement or R.True(row.AllowImprovement)) then f[i]=f[i]+row.Yield end
            end
        end
        R.Add(f,R.TraitYields(c,"Trait_UnimprovedFeatureYieldChanges",{FeatureType=feature.Type}),tile.improvement and 0 or 1)
        if tile.wonder then
            R.Add(f,R.TraitYields(c,"Trait_YieldChangesNaturalWonder"))
            local modifier=R.Trait(c,"NaturalWonderYieldModifier")
            for i=1,6 do f[i]=math.floor(f[i]*(100+modifier)/100) end
        end
        if R.True(feature.YieldNotAdditive) then out=f else R.Add(out,f) end
    end
    R.Add(out,R.TraitYields(c,"Trait_TerrainYieldChanges",{TerrainType=tile.terrain}))
    local prefix,column,value=feature and "Feature" or "Terrain",feature and "FeatureType" or "TerrainType",feature and feature.Type or tile.terrain
    if tile.river then R.Add(out,R.YieldChanges(prefix.."_RiverYieldChanges",column,value)) end
    if tile.hills then R.Add(out,R.YieldChanges(prefix.."_HillsYieldChanges",column,value)) end
    if tile.mountain then R.Add(out,R.YieldChanges(prefix.."_MountainYieldChanges",column,value)) end
    local resource=R.Revealed(tile,known) and R.Row("Resources",tile.resource)
    if resource then
        R.Add(out,R.YieldChanges("Resource_YieldChanges","ResourceType",tile.resource))
        R.Add(out,R.TraitYields(c,"Trait_ResourceYieldChanges",{ResourceType=tile.resource}))
        R.Add(out,R.TraitYields(c,"Trait_ResourceClassYieldChange",{ResourceClassType=resource.ResourceClassType}))
    end
    if tile.improvement then
        local imp=tile.improvement
        R.Add(out,R.YieldChanges("Improvement_Yields","ImprovementType",imp))
        R.Add(out,R.TraitYields(c,"Trait_ImprovementYieldChanges",{ImprovementType=imp}))
        if tile.fresh then R.Add(out,R.YieldChanges("Improvement_FreshWaterYields","ImprovementType",imp)) end
        if tile.river then R.Add(out,R.YieldChanges("Improvement_RiverSideYields","ImprovementType",imp)) end
        if tile.hills then R.Add(out,R.YieldChanges("Improvement_HillsYields","ImprovementType",imp)) end
        if tile.coastal then R.Add(out,R.YieldChanges("Improvement_CoastalLandYields","ImprovementType",imp)) end
        if resource then R.Add(out,R.YieldChanges("Improvement_ResourceType_Yields","ImprovementType",imp,{ResourceType=tile.resource})) end
        for _,table_name in ipairs({"Improvement_TechYieldChanges",tile.fresh and "Improvement_TechFreshWaterYieldChanges" or "Improvement_TechNoFreshWaterYieldChanges"}) do
            for _,row in ipairs(R.Group(table_name,"ImprovementType",imp)) do
                local i=yield_number[row.YieldType]
                if i and known[row.TechType] then out[i]=out[i]+row.Yield end
            end
        end
    end
    for building in pairs(state.buildings or {}) do
        if resource then R.Add(out,R.YieldChanges("Building_ResourceYieldChanges","BuildingType",building,{ResourceType=tile.resource})) end
        if tile.water then R.Add(out,R.YieldChanges("Building_SeaPlotYieldChanges","BuildingType",building)) end
        if tile.lake then R.Add(out,R.YieldChanges("Building_LakePlotYieldChanges","BuildingType",building)) end
        if tile.water and resource then R.Add(out,R.YieldChanges("Building_SeaResourceYieldChanges","BuildingType",building)) end
        if tile.river then R.Add(out,R.YieldChanges("Building_RiverPlotYieldChanges","BuildingType",building)) end
        R.Add(out,R.YieldChanges("Building_TerrainYieldChanges","BuildingType",building,{TerrainType=tile.terrain}))
        if feature then R.Add(out,R.YieldChanges("Building_FeatureYieldChanges","BuildingType",building,{FeatureType=feature.Type})) end
        if tile.improvement then R.Add(out,R.YieldChanges("Building_ImprovementYieldChanges","BuildingType",building,{ImprovementType=tile.improvement})) end
    end
    if city then
        for i,name in ipairs(R.YIELDS) do
            local info=R.Row("Yields",name) or {MinCity=i==1 and 2 or i==2 and 1 or 0,MinCityOnHillsAdjust=i==2 and 1 or 0}
            out[i]=math.max(out[i]+(info.CityChange or 0),(info.MinCity or 0)+(tile.hills and (info.MinCityOnHillsAdjust or 0) or 0))
        end
    end
    for i=1,6 do out[i]=math.max(0,math.floor(out[i])) end
    return out
end

function R.Resolve(c,kind,type_name)
    local table_name=kind=="unit" and "Units" or "Buildings"
    local row=R.Row(table_name,type_name)
    if not row then return nil end
    local class_column=kind=="unit" and "Class" or "BuildingClass"
    local class=row[class_column]
    if kind=="unit" then
        for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
            for _,disabled in ipairs(R.Group("Trait_NoTrain","TraitType",trait)) do
                if disabled.UnitClassType==class then return nil end
            end
        end
    end
    if c.civ then
        local overrides=kind=="unit" and "Civilization_UnitClassOverrides" or "Civilization_BuildingClassOverrides"
        local field=kind=="unit" and "UnitClassType" or "BuildingClassType"
        for _,override in ipairs(R.Group(overrides,"CivilizationType",c.civ)) do
            if override[field]==class then return R.Row(table_name,override[kind=="unit" and "UnitType" or "BuildingType"]) end
        end
    end
    return row
end
function R.Cost(row,kind,c)
    local cost=row.Cost or 0
    if kind=="unit" and R.True(row.Found) and cost==0 then
        cost=R.Define("SETTLER_PRODUCTION_SPEED",0)
        if cost==0 then
            local buildings=0
            for _,class in ipairs(R.Rows("BuildingClasses")) do
                local building=R.Resolve(c,"building",class.DefaultBuilding)
                local era=building and R.Row("Eras",building.FreeStartEra)
                if era and era.ID<=(c.era.ID or 0) then buildings=buildings+R.Cost(building,"building",c) end
            end
            cost=math.floor(buildings*(100+R.Define("NEW_CITY_BUILDING_VALUE_MODIFIER",-60))/100)
                +math.floor(R.Define("ADVANCED_START_CITY_COST",84)*(c.speed.GrowthPercent or 100)/100)
            for population=1,R.Define("INITIAL_CITY_POPULATION",1)+(c.era.FreePopulation or 0) do
                cost=cost+math.floor(R.GrowthThreshold(population,c)*R.Define("ADVANCED_START_POPULATION_COST",150)/100)
            end
        end
        cost=math.floor(cost*(100+(row.SettlerCostModifier or 0))/100)
        return math.max(1,math.floor(cost*(100+(row.FinalProductionCostModifier or 0))/100))
    end
    if kind=="building" then
        for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
            for _,override in ipairs(R.Group("Trait_BuildingCostOverride","TraitType",trait)) do
                if override.BuildingType==row.Type and override.YieldType=="YIELD_PRODUCTION" and override.Cost>0 then cost=override.Cost end
            end
        end
    end
    cost=math.floor(cost*R.Define(kind=="unit" and "UNIT_PRODUCTION_PERCENT" or "BUILDING_PRODUCTION_PERCENT",100)/100)
    cost=R.Scale(cost,c,kind=="unit" and "TrainPercent" or "ConstructPercent")
    if kind=="unit" then cost=math.floor(cost*(100+(row.FinalProductionCostModifier or 0))/100) end
    return math.max(1,cost)
end

function R.ProductionModifier(c,state,project)
    local modifier=0
    if project.kind=="unit" then
        for _,row in ipairs(R.Group("Unit_ProductionTraits","UnitType",project.row.Type)) do
            if c.traits[row.TraitType] then modifier=modifier+(row.Trait or 0) end
        end
        for _,row in ipairs(R.Group("Unit_ProductionModifierBuildings","UnitType",project.row.Type)) do
            if state.buildings[row.BuildingType] then modifier=modifier+(row.ProductionModifier or 0) end
        end
        for building in pairs(state.buildings) do
            for _,row in ipairs(R.Group("Building_DomainProductionModifiers","BuildingType",building)) do
                if row.DomainType==project.row.Domain then modifier=modifier+(row.Modifier or 0) end
            end
            for _,row in ipairs(R.Group("Building_UnitCombatProductionModifiers","BuildingType",building)) do
                if row.UnitCombatType==project.row.CombatClass then modifier=modifier+(row.Modifier or 0) end
            end
        end
    else
        for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
            for _,row in ipairs(R.Group("Trait_BuildingClassProductionModifiers","TraitType",trait)) do
                if row.BuildingClassType==project.row.BuildingClass then modifier=modifier+(row.ProductionModifier or 0) end
            end
        end
    end
    return modifier
end

function R.ConnectedResources(c,state,tiles)
    local available={}
    for index,tile in pairs(tiles) do
        local resource=state.owned[index] and R.Revealed(tile,state.techs) and R.Row("Resources",tile.resource)
        if resource and (not resource.TechCityTrade or state.techs[resource.TechCityTrade]) then
            local connected=tile.city
            for _,row in ipairs(R.Group("Improvement_ResourceTypes","ImprovementType",tile.improvement)) do
                if row.ResourceType==resource.Type and R.True(row.ResourceTrade) then connected=true end
            end
            if connected then available[resource.Type]=(available[resource.Type] or 0)+(tile.quantity or 1) end
        end
    end
    for _,unit in ipairs(state.units) do if not unit.consumed then
        for _,row in ipairs(R.Group("Unit_ResourceQuantityRequirements","UnitType",unit.row.Type)) do
            available[row.ResourceType]=(available[row.ResourceType] or 0)-(row.Cost or 0)
        end
    end end
    return available
end

local function Contains(name,column,value,field,expected)
    for _,row in ipairs(R.Group(name,column,value)) do if row[field]==expected then return true end end
    return false
end
function R.BuildAllowed(tile,build,c,known)
    if build.PrereqTech and not known[build.PrereqTech] then return false end
    if R.True(build.SpecificCivRequired) and build.CivilizationType~=c.civ then return false end
    local removal
    for _,row in ipairs(R.Group("BuildFeatures","BuildType",build.Type)) do
        if row.FeatureType==tile.feature then
            if row.PrereqTech and not known[row.PrereqTech] then return false end
            removal=row
        end
    end
    if not build.ImprovementType then return removal and R.True(removal.Remove),removal end
    local imp=R.Row("Improvements",build.ImprovementType)
    if not imp or tile.wonder or tile.mountain then return false end
    if tile.improvement==build.ImprovementType then return false end
    if R.True(imp.SpecificCivRequired) and imp.CivilizationType~=c.civ then return false end
    if R.True(imp.CreatedByGreatPerson) or R.True(imp.GraphicalOnly) or R.True(imp.Goody) then return false end
    if R.True(imp.Water)~=tile.water then return false end
    if R.True(imp.RequiresFlatlands) and tile.hills then return false end
    if R.True(imp.RequiresFlatlandsOrFreshWater) and tile.hills and not tile.fresh then return false end
    if R.True(imp.NoFreshWater) and tile.fresh then return false end
    if R.True(imp.Coastal) and not tile.coastal then return false end
    if R.True(imp.RequiresFeature) and not Contains("Improvement_ValidFeatures","ImprovementType",imp.Type,"FeatureType",tile.feature) then return false end
    if R.True(imp.NoTwoAdjacent) then return false end -- adjacency-dependent unique improvements need an explicit plan
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
        if Contains("Trait_NoBuildImprovement","TraitType",trait,"ImprovementType",imp.Type) then return false end
    end
    local resource=R.Revealed(tile,known) and tile.resource
    local resource_rule
    if resource then
        for _,row in ipairs(R.Group("Improvement_ResourceTypes","ImprovementType",imp.Type)) do
            if row.ResourceType==resource then resource_rule=row end
        end
        if not resource_rule and not R.True(imp.BuildableOnResources) then return false end
    end
    local valid=resource_rule and R.True(resource_rule.ResourceMakesValid)
    valid=valid or (tile.hills and R.True(imp.HillsMakesValid)) or (tile.fresh and R.True(imp.FreshWaterMakesValid))
        or (tile.river and R.True(imp.RiverSideMakesValid))
        or Contains("Improvement_ValidTerrains","ImprovementType",imp.Type,"TerrainType",tile.terrain)
        or Contains("Improvement_ValidFeatures","ImprovementType",imp.Type,"FeatureType",tile.feature)
    if not valid then return false end
    if tile.feature and not (removal and R.True(removal.Remove))
        and not Contains("Improvement_ValidFeatures","ImprovementType",imp.Type,"FeatureType",tile.feature) then return false end
    return true,removal
end
function R.BuildWork(tile,build,c,known)
    local time=build.Time or 0
    local resource=R.Revealed(tile,known) and R.Row("Resources",tile.resource)
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
        for _,override in ipairs(R.Group("Trait_BuildImprovementBuildTimeOverride","TraitType",trait)) do
            if override.BuildType==build.Type and (not override.ResourceClassRequired or
                (resource and override.ResourceClassRequired==resource.ResourceClassType)) then time=override.Time end
        end
    end
    for _,change in ipairs(R.Group("Build_TechTimeChanges","BuildType",build.Type)) do
        if known[change.TechType] then time=time+(change.TimeChange or 0) end
    end
    local _,feature=R.BuildAllowed(tile,build,c,known)
    if feature and (R.True(feature.Remove) or build.ImprovementType=="IMPROVEMENT_FORT") then time=time+(feature.Time or 0) end
    local terrain=R.Row("Terrains",tile.terrain) or {}
    time=math.floor(time*math.max(0,100+(terrain.BuildModifier or 0))/100)
    return math.max(0,math.floor(R.Scale(time,c,"BuildPercent")/10)*10)
end
function R.Chop(feature,c,distance)
    if not feature or not R.True(feature.Remove) then return 0,0 end
    local scale=(c.speed.FeatureProductionPercent or 100)/100
    return math.floor(math.max(0,(feature.Production or 0)-math.max(0,distance-2)*5)*scale),
        math.floor(math.max(0,(feature.Food or 0)-math.max(0,distance-2)*5)*scale)
end

function R.CityExtras(c,state)
    local out=R.Zero()
    out[4]=(state.population or 1)*R.Define("SCIENCE_PER_POPULATION",1)
    R.Add(out,R.TraitYields(c,"Trait_CityYieldChange"))
    R.Add(out,R.TraitYields(c,"Trait_CapitalYieldChange"))
    out[5]=out[5]+R.Trait(c,"CityCultureBonus")
    for name in pairs(state.buildings) do
        if name=="BUILDING_PALACE" and #R.Rows("Buildings")==0 then R.Add(out,{0,3,3,3,1,0}) end
        R.Add(out,R.YieldChanges("Building_YieldChanges","BuildingType",name))
        R.Add(out,R.YieldChanges("Building_YieldChangesPerPop","BuildingType",name),state.population/100)
        local row=R.Row("Buildings",name) or {}
        R.Add(out,R.TraitYields(c,"Trait_BuildingClassYieldChanges",{BuildingClassType=row.BuildingClass}))
    end
    return out
end
function R.ModifyCityYields(yields,c,state)
    local modifiers=R.TraitYields(c,"Trait_YieldModifiers")
    for name in pairs(state.buildings) do
        R.Add(modifiers,R.YieldChanges("Building_YieldModifiers","BuildingType",name))
        modifiers[5]=modifiers[5]+((R.Row("Buildings",name) or {}).CultureRateModifier or 0)
    end
    for i=1,6 do yields[i]=math.floor(yields[i]*math.max(0,100+modifiers[i]))/100 end
    return yields
end
function R.InitialBuildings(c)
    local result={}
    local palace=R.Resolve(c,"building","BUILDING_PALACE")
    if palace then result[palace.Type]=true
    elseif #R.Rows("Buildings")==0 then result.BUILDING_PALACE=true end
    for _,class in ipairs(R.Rows("BuildingClasses")) do
        local building=R.Resolve(c,"building",class.DefaultBuilding)
        local era=building and R.Row("Eras",building.FreeStartEra)
        if era and era.ID<=(c.era.ID or 0) then result[building.Type]=true end
    end
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
        local row=R.Row("Traits",trait) or {}
        for _,field in ipairs({"FreeBuilding","FreeCapitalBuilding"}) do
            local class=R.Row("BuildingClasses",row[field])
            local building=class and R.Resolve(c,"building",class.DefaultBuilding)
            if building then result[building.Type]=true end
        end
    end
    return result
end
function R.ResearchCost(name,c,known)
    local row=R.Row("Technologies",name)
    if not row then return nil end
    local world=R.Row("Worlds",Map.GetWorldSize()) or {}
    local cost=math.floor((row.Cost or 0)*(c.handicap.ResearchPercent or 100)/100)
    cost=math.floor(cost*(world.ResearchPercent or 100)/100)
    cost=R.Scale(cost,c,"ResearchPercent")
    local modifier=100
    for _,prerequisite in ipairs(R.Group("Technology_ORPrereqTechs","TechType",name)) do
        if (known or c.techs)[prerequisite.PrereqTech] then modifier=modifier+R.Define("TECH_COST_KNOWN_PREREQ_MODIFIER",20) end
    end
    -- One founded capital; no assumed discounts from meeting other teams.
    local fixed=math.floor(cost*10000/math.max(1,modifier))
    fixed=math.floor(fixed*(100+math.floor(world.NumCitiesTechCostMod or 0))/100)
    return math.max(1,math.ceil(fixed/100))
end
function R.NextResearch(preferences,known)
    local function needed(name,visiting)
        if known[name] or visiting[name] then return nil end
        if not R.Row("Technologies",name) then return nil end
        visiting[name]=true
        for _,row in ipairs(R.Group("Technology_PrereqTechs","TechType",name)) do
            if not known[row.PrereqTech] then return needed(row.PrereqTech,visiting) end
        end
        local ors=R.Group("Technology_ORPrereqTechs","TechType",name)
        if #ors>0 then
            local have=false
            for _,row in ipairs(ors) do if known[row.PrereqTech] then have=true end end
            if not have then return needed(ors[1].PrereqTech,visiting) end
        end
        return name
    end
    for _,name in ipairs(preferences) do local next_tech=needed(name,{});if next_tech then return next_tech end end
end
function R.WorkerBuilds(c,unit)
    local allowed={}
    for _,row in ipairs(R.Group("Unit_Builds","UnitType",unit.Type)) do allowed[row.BuildType]=true end
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
        for _,row in ipairs(R.Group("Trait_UnitCombatBuilds","TraitType",trait)) do
            if row.UnitCombatType==unit.CombatClass then allowed[row.BuildType]=true end
        end
    end
    local out={}
    for name in Lekmap_Utilities.OrderedPairs(allowed) do
        local row=R.Row("Builds",name)
        if row and not row.RouteType and not R.True(row.Repair) and not R.True(row.RemoveRoute) then out[#out+1]=row end
    end
    return out
end
function R.WorkRate(c,unit)
    local base=unit.WorkRate or 100
    for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
        for _,row in ipairs(R.Group("Trait_UnitCombatWorkRateChange","TraitType",trait)) do
            if row.UnitCombatType==unit.CombatClass then base=base+(row.WorkRateChange or 0) end
        end
    end
    return math.max(1,math.floor(base*math.max(0,100+R.Trait(c,"WorkerSpeedModifier"))/100))
end
function R.Luxuries(c,state,tiles)
    local unique,copies,happiness={},{},0
    for index,tile in pairs(tiles) do
        local resource=state.owned[index] and R.Revealed(tile,state.techs) and R.Row("Resources",tile.resource)
        if resource and (resource.Happiness or 0)>0 and (not resource.TechCityTrade or state.techs[resource.TechCityTrade]) then
            local connected=tile.city
            for _,row in ipairs(R.Group("Improvement_ResourceTypes","ImprovementType",tile.improvement)) do
                if row.ResourceType==resource.Type and R.True(row.ResourceTrade) then connected=true end
            end
            if connected then
                copies[resource.Type]=(copies[resource.Type] or 0)+1
                if not unique[resource.Type] then
                    unique[resource.Type]=true
                    happiness=happiness+resource.Happiness+(c.handicap.ExtraHappinessPerLuxury or 0)
                else happiness=happiness+R.Define("HAPPINESS_PER_EXTRA_LUXURY",0) end
            end
        end
    end
    return unique,copies,happiness
end
function R.Happiness(c,state,tiles,extra_cities,extra_population)
    local unique,copies,luxury=R.Luxuries(c,state,tiles)
    local city_cost=R.Define("UNHAPPINESS_PER_CITY",3)*(1+(extra_cities or 0))
        *(100+R.Trait(c,"CityUnhappinessModifier"))/100*(c.handicap.NumCitiesUnhappinessMod or 100)/100
    local population=(state.population+(extra_population or 0))*R.Define("UNHAPPINESS_PER_POPULATION",1)
        *(100+R.Trait(c,"PopulationUnhappinessModifier"))/100*(c.handicap.PopulationUnhappinessMod or 100)/100
    local local_happiness,unmodded=0,0
    for name in pairs(state.buildings) do
        local row=R.Row("Buildings",name) or {}
        local_happiness=local_happiness+(row.Happiness or 0)
        unmodded=unmodded+(row.UnmoddedHappiness or 0)
    end
    return (c.handicap.HappinessDefault or 9)+luxury+unmodded+math.min(state.population,local_happiness)-math.floor(city_cost+population),unique,copies
end
function R.Maintenance(c,state,turn)
    local buildings=0
    for name in pairs(state.buildings) do buildings=buildings+((R.Row("Buildings",name) or {}).GoldMaintenance or 0) end
    buildings=buildings*(c.handicap.BuildingCostPercent or 100)/100
    local count=0
    for _,unit in ipairs(state.units) do if not unit.consumed and not R.True(unit.row.NoMaintenance) then count=count+1 end end
    local paid=math.max(0,count-(c.handicap.GoldFreeUnits or 0)-R.Define("INITIAL_BASE_FREE_UNITS",0))
    local estimate=0
    for _,row in ipairs(R.Group("GameSpeed_Turns","GameSpeedType",c.speed.Type)) do estimate=estimate+(row.TurnsPerIncrement or 0) end
    if estimate==0 then estimate=R.Scale(500,c,"GrowthPercent") end
    local progress=turn/math.max(1,estimate)
    local per_unit=R.Define("INITIAL_GOLD_PER_UNIT_TIMES_100",50)/100
    local base=paid*per_unit
    for _,unit in ipairs(state.units) do
        if not unit.consumed then
            if not R.True(unit.row.NoMaintenance) and (unit.row.Combat or 0)>0 then
                base=base+per_unit*R.Trait(c,unit.row.Domain=="DOMAIN_SEA" and "NavalUnitMaintenanceModifier" or "LandUnitMaintenanceModifier")/100
            end
            for trait in Lekmap_Utilities.OrderedPairs(c.traits) do
                for _,row in ipairs(R.Group("Trait_MaintenanceModifierUnitCombats","TraitType",trait)) do
                    if row.UnitCombatType==unit.row.CombatClass then base=base+per_unit*(row.MaintenanceModifier or 0)/100 end
                end
            end
        end
    end
    base=math.max(0,base)
    local units=(base*(1+progress*R.Define("UNIT_MAINTENANCE_GAME_MULTIPLIER",8)))^(1+progress/R.Define("UNIT_MAINTENANCE_GAME_EXPONENT_DIVISOR",7))
    units=math.floor(units*(c.handicap.UnitCostPercent or 100)/100)
    return math.max(0,buildings+units)
end
