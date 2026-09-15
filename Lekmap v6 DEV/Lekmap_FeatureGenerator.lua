------------------------------------------------------------------------------
--	FILE:               Lekmap_FeatureGenerator.lua  (renamed from HBFeatureGenerator.lua)
--	MODIFIED FOR CIV5:  Bob Thomas
--	PYTHON TO LUA:      Shaun Seckman
--	PURPOSE:            Default method for feature generation
------------------------------------------------------------------------------
--	Copyright (c) 2009, 2010 Firaxis Games, Inc. All rights reserved.
------------------------------------------------------------------------------
-- Note: HBMapmakerUtilities has been merged into Lekmap_Utilities.lua,
-- which is loaded by Lekmap_MapGenerator.lua in the include chain.

------------------------------------------------------------------------------
FeatureGenerator = {}
------------------------------------------------------------------------------
function FeatureGenerator.Create(args)
	--[[ Civ4's truncated "Climate" setting has been abandoned. Civ5 has returned to 
	Civ3-style map options for World Age, Temperature, and Rainfall. Control over the 
	terrain has been removed from the XML.  - Bob Thomas, March 2010  ]]--
	--
	-- Sea Level and World Age map options affect only plot generation.
	-- Temperature map options affect only terrain generation.
	-- Rainfall map options affect only feature generation.
	--	
	local grass_moist = Map.GetCustomOption(8)

	local args = args or {}
	local rainfall = args.rainfall or 2 -- Default is Normal rainfall.
	local jungle_grain = args.jungle_grain or 5
	local forest_grain = args.forest_grain or 6
	local clump_grain = args.clump_grain or 10
	local jungle_change = args.jungle_change or 20
	local forest_change = args.forest_change or 7
	local clump_change = args.clump_change or 5
	local jungle_factor = args.jungle_factor or 7
	local arid_factor = args.arid_factor or 6
	local wet_factor = args.wet_factor or 2
	local marsh_change = args.marsh_change or 1.5
	local oasis_change = args.oasis_change or 1.5
	local frac_x_exp = args.frac_x_exp or -1
	local frac_y_exp = args.frac_y_exp or -1
	
	-- Set feature traits.
	local jungle_percent = args.jungle_percent or 42

	if grass_moist == 1 then
		jungle_percent = jungle_percent - 5
	elseif grass_moist == 3 then
		jungle_percent = jungle_percent + 5
	end

	local forest_percent = args.forest_percent or 18
	local clump_height = args.clump_height or 75
	local marsh_percent = args.marsh_percent or 8
	local oasis_percent = args.oasis_percent or 25

	-- if MapShape == 3 then
	-- 	forest_percent = forest_percent + 6
	-- 	jungle_percent = jungle_percent + 3
	-- 	marsh_percent = marsh_percent + 1
	-- end

	-- Adjust foliage amounts according to user's Rainfall selection. (Which must be passed in by the map script.)
	if rainfall == 1 then -- Rainfall is sparse, climate is Arid.
		jungle_percent = jungle_percent - jungle_change
		jungle_factor = arid_factor
		forest_percent = forest_percent - forest_change
		clump_height = clump_height - clump_change
		marsh_percent = marsh_percent / marsh_change
		oasis_percent = oasis_percent / oasis_change
	elseif rainfall == 3 then -- Rainfall is abundant, climate is Wet.
		jungle_percent = jungle_percent + jungle_change
		jungle_factor = wet_factor
		forest_percent = forest_percent + forest_change
		clump_height = clump_height + clump_change
		marsh_percent = marsh_percent * marsh_change
		oasis_percent = oasis_percent * oasis_change
	else -- Rainfall is Normal.
	end

	--[[ Activate printout for debugging only.
	print("-") print("--- Rainfall Readout ---")
	print("- Rainfall Setting:", rainfall)
	print("- Jungle Percentage:", jungle_percent)
	print("- Loose Forest %:", forest_percent)
	print("- Clump Forest %:", 100 - clump_height)
	print("- Marsh Percentage:", marsh_percent)
	print("- Oasis Percentage:", oasis_percent)
	print("- - - - - - - - - - - - - - -")
	]]--

	local grid_width, grid_height = Map.GetGridSize()
	local world_info = GameInfo.Worlds[Map.GetWorldSize()]
	jungle_grain = jungle_grain + world_info.FeatureGrainChange
	forest_grain = forest_grain + world_info.FeatureGrainChange

	-- create instance data
	local instance = {
	
		-- methods
		__InitFractals     = FeatureGenerator.__InitFractals,
		__InitFeatureTypes = FeatureGenerator.__InitFeatureTypes,
		AddFeatures        = FeatureGenerator.AddFeatures,
		GetLatitudeAtPlot  = FeatureGenerator.GetLatitudeAtPlot,
		AddFeaturesAtPlot  = FeatureGenerator.AddFeaturesAtPlot,
		AddOasisAtPlot     = FeatureGenerator.AddOasisAtPlot,
		AddIceAtPlot       = FeatureGenerator.AddIceAtPlot,
		AddMarshAtPlot     = FeatureGenerator.AddMarshAtPlot,
		AddJunglesAtPlot   = FeatureGenerator.AddJunglesAtPlot,
		AddForestsAtPlot   = FeatureGenerator.AddForestsAtPlot,
		AddAtolls          = FeatureGenerator.AddAtolls,
		AdjustTerrainTypes = FeatureGenerator.AdjustTerrainTypes,
		
		-- members
		grid_width = grid_width,
		grid_height = grid_height,
		
		jungle_percent = jungle_percent,
		jungle_factor = jungle_factor,
		forest_percent = forest_percent,
		clump_height = clump_height,
		marsh_percent = marsh_percent,
		oasis_percent = oasis_percent,
	
		jungle_grain = jungle_grain,
		forest_grain = forest_grain,
		clump_grain = clump_grain,
		
		fractal_flags = Map.GetFractalFlags(),
		frac_x_exp = frac_x_exp,
		frac_y_exp = frac_y_exp,
	}

	-- initialize instance data
	instance:__InitFractals()
	instance:__InitFeatureTypes()
	
	return instance
end
------------------------------------------------------------------------------
function FeatureGenerator:__InitFractals()
	local width = self.grid_width
	local height = self.grid_height
	
	-- Create fractals
	self.jungles       = Fractal.Create(width, height, self.jungle_grain, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)
	self.forests       = Fractal.Create(width, height, self.forest_grain, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)
	self.forest_clumps = Fractal.Create(width, height, self.clump_grain, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)
	self.marsh         = Fractal.Create(width, height, 4, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)
	
	-- Get heights
	self.jungle_bottom = self.jungles:GetHeight((100 - self.jungle_percent) / 2)
	self.jungle_top    = self.jungles:GetHeight((100 + self.jungle_percent) / 2)
	self.jungle_range  = (self.jungle_top - self.jungle_bottom) * self.jungle_factor
	self.forest_level  = self.forests:GetHeight(100 - self.forest_percent)
	self.clump_level   = self.forest_clumps:GetHeight(self.clump_height)
	self.marsh_level   = self.marsh:GetHeight(100 - self.marsh_percent)
end
------------------------------------------------------------------------------
function FeatureGenerator:__InitFeatureTypes()

	self.feature_flood_plains = FeatureTypes.FEATURE_FLOOD_PLAINS
	self.feature_ice = FeatureTypes.FEATURE_ICE
	self.feature_jungle = FeatureTypes.FEATURE_JUNGLE
	self.feature_forest = FeatureTypes.FEATURE_FOREST
	self.feature_oasis = FeatureTypes.FEATURE_OASIS
	self.feature_marsh = FeatureTypes.FEATURE_MARSH
	
	self.terrain_ice = TerrainTypes.TERRAIN_SNOW
	self.terrain_tundra = TerrainTypes.TERRAIN_TUNDRA
	self.terrain_plains = TerrainTypes.TERRAIN_PLAINS
end
------------------------------------------------------------------------------
function FeatureGenerator:AddFeatures(allow_mountains_on_coast)
	local flag = allow_mountains_on_coast or false
	--[[ Removing mountains from coasts cannot be done during plot or terrain 
	generation, because the function that determines what is or isn't adjacent
	to a salt water ocean requires both plot and terrain data to operate. So
	even though this operation is, strictly speaking, a plot-type operation, I
	have added it here in the default FeatureGenerator so I can easily call on
	it for any script that needs it.  - Bob Thomas, March 2010  ]]--
	--
	if allow_mountains_on_coast == false then -- remove any mountains from coastal plots
		for x = 0, self.grid_width - 1 do
			for y = 0, self.grid_height - 1 do
				local plot = Map.GetPlot(x, y)
				if plot:GetPlotType() == PlotTypes.PLOT_MOUNTAIN then
					if plot:IsCoastalLand() then
						plot:SetPlotType(PlotTypes.PLOT_HILLS, false, true) -- These flags are for recalc of areas and rebuild of graphics. Instead of recalc over and over, do recalc at end of loop.
					end
				end
			end
		end
		-- This function needs to recalculate areas after operating. However, so does 
		-- adding feature ice, so the recalc was removed from here and put in MapGenerator()
	end
	
	self:AddAtolls() -- Adds Atolls to oceanic maps.
	
	-- Main loop, adds features to all plots as appropriate
	for y = 0, self.grid_height - 1, 1 do
		for x = 0, self.grid_width - 1, 1 do
			self:AddFeaturesAtPlot(x, y)
		end
	end
	
	self:AdjustTerrainTypes() -- Sets terrain under jungles and softens arctic rivers
end
------------------------------------------------------------------------------
function FeatureGenerator:GetLatitudeAtPlot(x, y)
	-- Latitude affects only jungles and ice by default.
	-- However, you can make use of it in replacement methods for AddAtPlot if you wish.
	-- Returns a value in the range of 0.0 (tropical) to 1.0 (polar)
	return math.abs((self.grid_height / 2) - y) / (self.grid_height / 2)
end
------------------------------------------------------------------------------
function FeatureGenerator:AddFeaturesAtPlot(x, y)
	-- adds any appropriate features at the plot (x, y) where (0,0) is in the SW
	local lat = self:GetLatitudeAtPlot(x, y)
	local plot = Map.GetPlot(x, y)

	if plot:CanHaveFeature(self.feature_flood_plains) then
		-- All desert plots along river are set to flood plains.
		plot:SetFeatureType(self.feature_flood_plains, -1)
	end
	
	if (plot:GetFeatureType() == FeatureTypes.NO_FEATURE) then
		self:AddOasisAtPlot(plot, x, y, lat)
	end

	if (plot:GetFeatureType() == FeatureTypes.NO_FEATURE) then
		self:AddIceAtPlot(plot, x, y, lat)
	end

	if (plot:GetFeatureType() == FeatureTypes.NO_FEATURE) then
		self:AddMarshAtPlot(plot, x, y, lat)
	end
		
	if (plot:GetFeatureType() == FeatureTypes.NO_FEATURE) then
		self:AddJunglesAtPlot(plot, x, y, lat)
	end
	
	if (plot:GetFeatureType() == FeatureTypes.NO_FEATURE) then
		self:AddForestsAtPlot(plot, x, y, lat)
	end
		
end
------------------------------------------------------------------------------
function FeatureGenerator:AddOasisAtPlot(plot, x, y, lat)
	if(plot:CanHaveFeature(self.feature_oasis)) then
		if Map.Rand(100, "Add Oasis Lua") <= self.oasis_percent then
			plot:SetFeatureType(self.feature_oasis, -1)
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AddIceAtPlot(plot, x, y, lat)
	if(plot:CanHaveFeature(self.feature_ice)) then
		if Map.IsWrapX() and (y == 0 or y == self.grid_height - 1) then
			plot:SetFeatureType(self.feature_ice, -1)

		else
			local rand = Map.Rand(200, "Add Ice Lua") / 100.0

			if(rand < 8 * (lat - 0.875)) then
				plot:SetFeatureType(self.feature_ice, -1)
			elseif(rand < 4 * (lat - 0.75)) then
				plot:SetFeatureType(self.feature_ice, -1)
			end
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AddMarshAtPlot(plot, x, y, lat)
	local marsh_height = self.marsh:GetHeight(x, y)
	if(marsh_height >= self.marsh_level) then
		if(plot:CanHaveFeature(self.feature_marsh)) then
			plot:SetFeatureType(self.feature_marsh, -1)
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AddJunglesAtPlot(plot, x, y, lat)
	local jungle_height = self.jungles:GetHeight(x, y)
	local climate_info = GameInfo.Climates[Map.GetClimate()]
	if jungle_height <= self.jungle_top and jungle_height >= self.jungle_bottom + (self.jungle_range * lat) then
		if(plot:CanHaveFeature(self.feature_jungle)) then
			plot:SetFeatureType(self.feature_jungle, -1)
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AddForestsAtPlot(plot, x, y, lat)
	if (self.forests:GetHeight(x, y) >= self.forest_level) or (self.forest_clumps:GetHeight(x, y) >= self.clump_level) then
		if plot:CanHaveFeature(self.feature_forest) then
			plot:SetFeatureType(self.feature_forest, -1)
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AdjustTerrainTypes()
	-- This function added April 2009 for Civ5, by Bob Thomas.
	-- Purpose of this function is to turn terrain under jungles
	-- into Plains, and to soften arctic terrain types at rivers.
	local width = self.grid_width - 1
	local height = self.grid_height - 1
	
	for y = 0, height do
		for x = 0, width do
			local plot = Map.GetPlot(x, y)
			
			if (plot:GetFeatureType() == self.feature_jungle) then
				plot:SetTerrainType(self.terrain_plains, false, true)  -- These flags are for recalc of areas and rebuild of graphics. No need to recalc from any of these changes.		
			elseif (plot:IsRiver()) then
				local terrain_type = plot:GetTerrainType()
				if (terrain_type == self.terrain_tundra) then
					plot:SetTerrainType(self.terrain_plains, false, true)
				elseif (terrain_type == self.terrain_ice) then
					plot:SetTerrainType(self.terrain_tundra, false, true)					
				end
			end
		end
	end
end
------------------------------------------------------------------------------
function FeatureGenerator:AddAtolls()
	-- This function added Feb 2011 by Bob Thomas.
	-- Adds the new feature Atolls in to the game, for oceanic maps.
	local map_width, map_height = Map.GetGridSize()
	local biggest_ocean = Map.FindBiggestArea(true)
	local num_biggest_ocean_plots = 0
	if biggest_ocean ~= nil then
		num_biggest_ocean_plots = biggest_ocean:GetNumTiles()
	end
	if num_biggest_ocean_plots <= (map_width * map_height) / 4 then -- No major oceans on this world.
		return
	end
	
	-- World has oceans, proceed with adding Atolls.
	local num_atolls_placed = 0
	local direction_types = {
		DirectionTypes.DIRECTION_NORTHEAST,
		DirectionTypes.DIRECTION_EAST,
		DirectionTypes.DIRECTION_SOUTHEAST,
		DirectionTypes.DIRECTION_SOUTHWEST,
		DirectionTypes.DIRECTION_WEST,
		DirectionTypes.DIRECTION_NORTHWEST,
	}
	local world_sizes = {
		[GameInfo.Worlds.WORLDSIZE_DUEL.ID] = 2,
		[GameInfo.Worlds.WORLDSIZE_TINY.ID] = 4,
		[GameInfo.Worlds.WORLDSIZE_SMALL.ID] = 5,
		[GameInfo.Worlds.WORLDSIZE_STANDARD.ID] = 7,
		[GameInfo.Worlds.WORLDSIZE_LARGE.ID] = 9,
		[GameInfo.Worlds.WORLDSIZE_HUGE.ID] = 12,
	}
	local atoll_target = world_sizes[Map.GetWorldSize()]
	local atoll_number = atoll_target + Map.Rand(atoll_target, "Number of Atolls to place - LUA")
	local feature_atoll
	for this_feature in GameInfo.Features() do
		if this_feature.Type == "FEATURE_ATOLL" then
			feature_atoll = this_feature.ID
		end
	end

	-- Generate candidate plot lists.
	local temp_one_tile_island_list, temp_alpha_list, temp_beta_list = {}, {}, {}
	local temp_gamma_list, temp_delta_list, temp_epsilon_list = {}, {}, {}
	for y = 0, map_height - 1 do
		for x = 0, map_width - 1 do
			local i = y * map_width + x + 1 -- Lua tables/lists/arrays start at 1, not 0 like C++ or Python
			local plot = Map.GetPlot(x, y)
			local plot_type = plot:GetPlotType()
			if plot_type == PlotTypes.PLOT_OCEAN then
				local feature_type = plot:GetFeatureType()
				if feature_type ~= FeatureTypes.FEATURE_ICE then
					if not plot:IsLake() then
						local terrain_type = plot:GetTerrainType()
						if terrain_type == TerrainTypes.TERRAIN_COAST then
							if plot:IsAdjacentToLand() then
								-- Check all adjacent plots and identify adjacent landmasses.
								local num_land_adjacent, biggest_adj_area = 0, 0
								local is_plot_valid = true
								for loop, direction in ipairs(direction_types) do
									local adj_plot = Map.PlotDirection(x, y, direction)
									if adj_plot ~= nil then
										local adj_plot_type = adj_plot:GetPlotType()
										if adj_plot_type ~= PlotTypes.PLOT_OCEAN then -- Found land.
											num_land_adjacent = num_land_adjacent + 1
											-- Avoid being adjacent to tundra, snow, or feature ice!
											local adj_terrain_type = adj_plot:GetTerrainType()
											if adj_terrain_type == TerrainTypes.TERRAIN_TUNDRA or adj_terrain_type == TerrainTypes.TERRAIN_SNOW then
												is_plot_valid = false
											end
											local adj_feature_type = adj_plot:GetFeatureType()
											if adj_feature_type == FeatureTypes.FEATURE_ICE then
												is_plot_valid = false
											end
											if adj_plot_type == PlotTypes.PLOT_LAND or adj_plot_type == PlotTypes.PLOT_HILLS then
												local area_id = adj_plot:GetArea()
												local adj_area = Map.GetArea(area_id)
												local num_area_plots = adj_area:GetNumTiles()
												if num_area_plots > biggest_adj_area then
													biggest_adj_area = num_area_plots
												end
											end
										end
									end
								end
								-- Only plots with a single land plot adjacent can be eligible.
								if num_land_adjacent == 1 and is_plot_valid == true then
									if biggest_adj_area >= 76 then
										-- discard this site
									elseif biggest_adj_area >= 41 then
										table.insert(temp_epsilon_list, i)
									elseif biggest_adj_area >= 17 then
										table.insert(temp_delta_list, i)
									elseif biggest_adj_area >= 8 then
										table.insert(temp_gamma_list, i)
									elseif biggest_adj_area >= 3 then
										table.insert(temp_beta_list, i)
									elseif biggest_adj_area >= 1 then
										table.insert(temp_alpha_list, i)
									--else -- Unexpected result
										--print("** Area Plot Count =", biggest_adj_area)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	local alpha_list = Lekmap_Utilities.GetShuffledCopyOfTable(temp_alpha_list)
	local beta_list = Lekmap_Utilities.GetShuffledCopyOfTable(temp_beta_list)
	local gamma_list = Lekmap_Utilities.GetShuffledCopyOfTable(temp_gamma_list)
	local delta_list = Lekmap_Utilities.GetShuffledCopyOfTable(temp_delta_list)
	local epsilon_list = Lekmap_Utilities.GetShuffledCopyOfTable(temp_epsilon_list)

	-- Determine maximum number able to be placed, per candidate category.
	local max_alpha = math.ceil(table.maxn(alpha_list) / 4)
	local max_beta = math.ceil(table.maxn(beta_list) / 5)
	local max_gamma = math.ceil(table.maxn(gamma_list) / 4)
	local max_delta = math.ceil(table.maxn(delta_list) / 3)
	local max_epsilon = math.ceil(table.maxn(epsilon_list) / 4)
	
	-- Place Atolls.
	local plot_index
	local i_alpha, i_beta, i_gamma, i_delta, i_epsilon = 1, 1, 1, 1, 1
	for loop = 1, atoll_number do
		local able_to_proceed = true
		local dice_roll = 1 + Map.Rand(100, "Atoll Placement Type - LUA")
		if dice_roll <= 40 and max_alpha > 0 then
			plot_index = alpha_list[i_alpha]
			i_alpha = i_alpha + 1
			max_alpha = max_alpha - 1
			--print("- Alpha site chosen")
		elseif dice_roll <= 65 then
			if max_beta > 0 then
				plot_index = beta_list[i_beta]
				i_beta = i_beta + 1
				max_beta = max_beta - 1
				--print("- Beta site chosen")
			elseif max_alpha > 0 then
				plot_index = alpha_list[i_alpha]
				i_alpha = i_alpha + 1
				max_alpha = max_alpha - 1
				--print("- Alpha site chosen")
			else -- Unable to place this Atoll
				--print("-") print("* Atoll #", loop, "was unable to be placed.")
				able_to_proceed = false
			end
		elseif dice_roll <= 80 then
			if max_gamma > 0 then
				plot_index = gamma_list[i_gamma]
				i_gamma = i_gamma + 1
				max_gamma = max_gamma - 1
				--print("- Gamma site chosen")
			elseif max_beta > 0 then
				plot_index = beta_list[i_beta]
				i_beta = i_beta + 1
				max_beta = max_beta - 1
				--print("- Beta site chosen")
			elseif max_alpha > 0 then
				plot_index = alpha_list[i_alpha]
				i_alpha = i_alpha + 1
				max_alpha = max_alpha - 1
				--print("- Alpha site chosen")
			else -- Unable to place this Atoll
				--print("-") print("* Atoll #", loop, "was unable to be placed.")
				able_to_proceed = false
			end
		elseif dice_roll <= 90 then
			if max_delta > 0 then
				plot_index = delta_list[i_delta]
				i_delta = i_delta + 1
				max_delta = max_delta - 1
				--print("- Delta site chosen")
			elseif max_gamma > 0 then
				plot_index = gamma_list[i_gamma]
				i_gamma = i_gamma + 1
				max_gamma = max_gamma - 1
				--print("- Gamma site chosen")
			elseif max_beta > 0 then
				plot_index = beta_list[i_beta]
				i_beta = i_beta + 1
				max_beta = max_beta - 1
				--print("- Beta site chosen")
			elseif max_alpha > 0 then
				plot_index = alpha_list[i_alpha]
				i_alpha = i_alpha + 1
				max_alpha = max_alpha - 1
				--print("- Alpha site chosen")
			else -- Unable to place this Atoll
				--print("-") print("* Atoll #", loop, "was unable to be placed.")
				able_to_proceed = false
			end
		else
			if max_epsilon > 0 then
				plot_index = epsilon_list[i_epsilon]
				i_epsilon = i_epsilon + 1
				max_epsilon = max_epsilon - 1
				--print("- Epsilon site chosen")
			elseif max_delta > 0 then
				plot_index = delta_list[i_delta]
				i_delta = i_delta + 1
				max_delta = max_delta - 1
				--print("- Delta site chosen")
			elseif max_gamma > 0 then
				plot_index = gamma_list[i_gamma]
				i_gamma = i_gamma + 1
				max_gamma = max_gamma - 1
				--print("- Gamma site chosen")
			elseif max_beta > 0 then
				plot_index = beta_list[i_beta]
				--print("- Beta site chosen")
				i_beta = i_beta + 1
				max_beta = max_beta - 1
			elseif max_alpha > 0 then
				plot_index = alpha_list[i_alpha]
				i_alpha = i_alpha + 1
				max_alpha = max_alpha - 1
				--print("- Alpha site chosen")
			else -- Unable to place this Atoll
				--print("-") print("* Atoll #", loop, "was unable to be placed.")
				able_to_proceed = false
			end
		end
		if able_to_proceed and plot_index ~= nil then
			local x = (plot_index - 1) % map_width
			local y = (plot_index - x - 1) / map_width
			local plot = Map.GetPlot(x, y)
			plot:SetFeatureType(feature_atoll, -1)
			num_atolls_placed = num_atolls_placed + 1
		--else
			--print("** ERROR ** Atoll unable to be placed and/or chosen Plot Index was nil.")
		end
	end
	
	--[[ Debug report
	print("-") print("- Atoll Target Number: ", atoll_number)
	print("- Number of Atolls placed: ", num_atolls_placed) print("-")
	print("- Atolls placed in Alpha locations: ", i_alpha - 1)
	print("- Atolls placed in Beta locations: ", i_beta - 1)
	print("- Atolls placed in Gamma locations: ", i_gamma - 1)
	print("- Atolls placed in Delta locations: ", i_delta - 1)
	print("- Atolls placed in Epsilon locations: ", i_epsilon - 1)
	]]--
end
------------------------------------------------------------------------------
