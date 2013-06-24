--------------------------------------------------------------
-- Emigration Mod v5
-- Authors: killmeplease
--------------------------------------------------------------
include( "CustomNotification.lua" );
include( "Prosperity" );
include( "ScriptDataManager" );
--------------------------------------------------------------
LuaEvents.NotificationAddin({ name = "Emigration", type = "CNOTIFICATION_EMIGRATION"})
LuaEvents.NotificationAddin({ name = "Immigration", type = "CNOTIFICATION_IMMIGRATION"})

-- const factors
local iEmigrationDice	= GameInfo.GameSpeeds[PreGame.GetGameSpeed()].GrowthPercent;	-- emigration probability is linked to growth speed
local CooldownTurns		= math.floor(GameInfo.EmigrationSettings["CooldownTurns"].Value * iEmigrationDice / 100 + .5);	-- min turns between two emigrations from one city
local iDistanceLogBase 	= GameInfo.EmigrationSettings["DistanceFactorLogBase"].Value;
local AutocracyModifier = GameInfo.EmigrationSettings["AutocracyModifier"].Value / 100;	-- applied to emigration probability
local OrderModifier		= GameInfo.EmigrationSettings["OrderModifier"].Value / 100;	-- reduces city's weight on immigration
-- variables
local PatriotismModifier = GameInfo.EmigrationSettings["PatriotismModifier"].Value / 100; -- reduces foreign city's weight
local notifications = {};	-- list of notifications to be shown on a player's turn (cant show on PlayerDoTurn because of error)
--------------------------------------------------------------
-- FUNCTIONS
--------------------------------------------------------------
function IsCityMigrationAllowed (toCity, fromTeam)
  if not toCity then return false end
  
  print(string.format("%15s revealed=%s food=%+d blockaded=%s resist=%s razing=%s",
    toCity:GetName(), 
    tostring(toCity:IsRevealed(fromTeam)), 
    toCity:FoodDifference(),
    tostring(toCity:IsBlockaded()), 
    tostring(toCity:IsResistance()), 
    tostring(toCity:IsRazing())))
    
  return toCity:IsRevealed(fromTeam)
           and toCity:FoodDifference() >= 0
           and not toCity:IsBlockaded()
           and not toCity:IsResistance()
           and not toCity:IsRazing()
  end
--------------------------------------------------------------
function GetProsperityRating(player)
	--print("updating prosperity rating");
	local team = player:GetTeam();
	local prosperityRating = {};	-- list of the cities of the world ordered by prosperity: {prosp, city}
  for n, host in pairs(Players) do
     if IsValid(host) and MetAndNoWar(player, host) then
			local macroProsp = GetMacroProsperity(host);
			for city in host:Cities() do
        if IsCityMigrationAllowed(city, team) then
					local prosp = GetLocalProsperity(city) + macroProsp;
					table.insert(prosperityRating, {prosp = prosp, city = city});
				end
			end
		end
	end
	table.sort(prosperityRating, function(c1, c2) return c1.prosp > c2.prosp end);	-- sort cities by prosperity in descending order
  print ("----------------- RETURN PROSP RATING ----------------")
	return prosperityRating;
end
--------------------------------------------------------------
function HasMetWar(playerA, playerB)
  if playerA == playerB then return true, false end
	local teamA = Teams[playerA:GetTeam()];
	local teamB = Teams[playerB:GetTeam()];
  --[[
  print(string.format("playerA=%s teamA=%s teamAIdx=%s playerB=%s teamB=%s teamBIdx=%s",
    playerA:GetName(), tostring(teamA), tostring(playerA:GetTeam()),
    playerB:GetName(), tostring(teamB), tostring(playerB:GetTeam())))
  print(string.format("met=%s metTeamByIdx=%s war=%s warTeamByIdx=%s",
    tostring(teamA:IsHasMet(teamB)), tostring(teamA:IsHasMet(playerB:GetTeam())),
    tostring(teamA:IsAtWar(teamB)), tostring(teamA:IsAtWar(playerB:GetTeam()))))
  --]]
  return teamA:IsHasMet(playerB:GetTeam()), teamA:IsAtWar(playerB:GetTeam())
end
function MetAndNoWar(playerA, playerB)
  local met, war = HasMetWar(playerA, playerB)
  return met and not war
end
--------------------------------------------------------------
function Migration(iPlayer)		-- executed at the start of an each player's turn
	local player = Players[iPlayer];
	if player:IsMinorCiv() then
		return;
	end
	if player:GetTotalPopulation() - player:GetNumCities() == 0 then	-- no spare citizens to emigrate
		return;
	end

  print("---------MIGRATION-------------------")
  local elapsedTime = os.clock()

	print(GetPlayerName(player) .. " - Turn " .. Game.GetGameTurn());
	local destList = GetProsperityRating(player);
	if # destList < 2 then	-- # returns number of elements
		print("---------END MIGRATION (DESTS)-------")
		return;
	end

	local currentEraType = GameInfo.Eras("ID = " .. player:GetCurrentEra())().Type;
	--print("current era = " .. currentEraType);
	local EraModifier = GameInfo.EmigrationEraModifiers("EraType = '" .. currentEraType .. "'")().EmigrationModifier / 100;
	--print("era modifier = " .. EraModifier);
	local maxDist = GameInfo.EmigrationEraModifiers("EraType = '" .. currentEraType .. "'")().MaxDistance;
	--print("era max distance = " .. maxDist);
	local maxProsp = destList[1].prosp;
	--print("maxProsp = " .. maxProsp .. " for the " .. destList[1].city:GetName());

	for n, rec in ipairs(destList) do
		local city = rec.city;
		local owner = Players[city:GetOwner()];
		local modData = AccessData(city:Plot(), "Emigration");
		local lastEmigrationTurn = modData.lastEmigrationTurn or -100
    
		--print("test city " .. city:GetName() .. "  " .. rec.prosp .. " / " .. lastEmigrationTurn);

    if owner == player and n > 1 then
      -- Compare the current population to the old population.
      -- If the population grew from last turn, disallow
      -- migration under the theory that newly grown cities
      -- aren't being handled quite right (maybe their
      -- happiness state isn't updated by time this script runs).
      local iOldPopulation = modData.lastPopulation or 0
      local dPop = city:GetPopulation() - iOldPopulation

      -- BUG: If Emigration mod is disabled, during that time, any
      -- cities that grow will be stuck in hysteresis until their
      -- population changes (from growth or starvation). This is
      -- a corner-case that I'm not concerned with.
      
      local nextEmigrationTurn = lastEmigrationTurn + CooldownTurns
      
      if dPop > 0 and iOldPopulation > 0 then
        --print(string.format("%-15s growth hysteresis (no migration)", city:GetName()))
      elseif Game.GetGameTurn() <= nextEmigrationTurn then
        --print(string.format("%-15s recent migration hysteresis (no migration until turn %d)",
        --  city:GetName(), nextEmigrationTurn+1))
      else
        local maxDiff = maxProsp - rec.prosp;
        --print("maxDiff = "..maxDiff);
        -- determine emigration probability
        local emigrationProb = maxDiff * log2(city:GetPopulation());	-- no emigration from size 1 cities
        emigrationProb = emigrationProb * EraModifier;
        if player:HasPolicy(GameInfoTypes.POLICY_AUTOCRACY) then
          --print(" - has autocracy");
          emigrationProb = emigrationProb * AutocracyModifier;
        end
        -- test if an emigration should occur
        local roll = Map.Rand(iEmigrationDice, "Emigration");
        --print("***** Emigration probability for "..city:GetName().." = "..emigrationProb);
        --print("roll = "..roll.." of "..iEmigrationDice);
        if roll < emigrationProb then
          -- determine a destination city and send an emigrant
          --print("determine destination city");
          local destCity, destProsp = GetDestinationCity(destList, n - 1, maxDist, player);
          if destCity ~= nil then
            --print("destination city is "..destCity:GetName());
            MoveCitizen(city, destCity, rec.prosp, destProsp);
          end
        end
      end
    end
  end
  print(string.format("Migration execution time %d ms", (os.clock() - elapsedTime) * 1000))
  print("-------------------------------------")
end
--------------------------------------------------------------
function GetDestinationCity(data, numBetterCities, maxDist, player)
	--print("---------GET DESTINATION-------------")

	-- generate a city-specific weights (considering distance)
	local weights = {};
	local fromCity = data[numBetterCities + 1].city;
	local fromProsp = data[numBetterCities + 1].prosp;
	local fromX = fromCity:GetX();
	local fromY = fromCity:GetY();
	local sumWgt = 0;
  
  --print("Migrants from " .. fromCity:GetName() .. " are considering " .. numBetterCities .. " better cities.")
	--print(" - num better cities = " .. numBetterCities);
	for i = 1, numBetterCities do
		local toCity = data[i].city;
		local toPlayer = Players[toCity:GetOwner()];
		local dist = iDistanceLogBase;
		local hasSoL = hasSOL(toPlayer);
		local wgt = 0;
		local dprosp = data[i].prosp - fromProsp;
		--print(toCity:GetName() .. " delta prosp = " .. dprosp);
		--if hasSoL then
		--  print(" - " .. toCity:GetName() .. "'s owner has SoL");
		--end
		if fromCity:GetOwner() ~= toCity:GetOwner() and not hasSoL then	-- calc dist if its a foreign city and its owner doesnt have SoL
			dist = Map.PlotDistance(fromX, fromY, toCity:GetX(), toCity:GetY());
			--print(" - distance to " .. toCity:GetName() .. " = "..dist);
		end
		if dist <= maxDist then
			wgt = dprosp * 10 / LogN(dist, iDistanceLogBase);	-- a normalized weight with the distance applied
			--print(" - wgt with distance applied = " .. wgt);	
		else
			--print("   " .. toCity:GetName() .. " is too far and wont be considered");
		end
		--print("   check for Order..");
		if toPlayer:HasPolicy(GameInfoTypes.POLICY_ORDER) then
			--print(" - has order. diminish weight by " .. OrderModifier);
			wgt = wgt * OrderModifier;
		--else
		--	print(" - no order");
		end
    
    -- The inertia to leave your own country should be a bit higher. Someone would
    -- much rather relocate to another state, for instance, instead of moving to
    -- a different culture and a different language.
    if fromCity:GetOwner() ~= toCity:GetOwner() then
      -- Reduce all others to keep exponential scaling down.
      --print(" - reducing foreign city weight by " .. PatriotismModifier)
      wgt = wgt / (1 + PatriotismModifier)
    end
    
		wgt = wgt * wgt;
		sumWgt = sumWgt + wgt;
		weights[i] = wgt;
		--print(toCity:GetName() .. " weight = " .. wgt);
	end
	local roll = Map.Rand(sumWgt, "Emigration - Determine dest city roll");
	--print("dest city roll = " .. roll);
	local accWgt = 0;
  
	local retCity = nil
	local retProsp = nil
	for i = 1, numBetterCities do
		accWgt = accWgt + weights[i];
		if roll < accWgt then
			retCity = data[i].city
			retProsp = data[i].prosp
			break
		end
	end
  
	--print("-------------------------------------")
	return retCity, retProsp;
end
--------------------------------------------------------------
function MoveCitizen(fromCity, toCity, fromProsp, toProsp)
	fromCity:SetPopulation(fromCity:GetPopulation() - 1, true);	--decrease population in a source city
	toCity:SetPopulation(toCity:GetPopulation() + 1, true);	-- increase population in a destination city
	-- cooldown
	local modData = AccessData(fromCity:Plot(), "Emigration");
	modData.lastEmigrationTurn = Game.GetGameTurn();
	SaveData(fromCity:Plot());
	 --print("last emigration turn saved ("..modData.lastEmigrationTurn..")");

	-- create a notification to the player:
	local fromPlayer= Players[fromCity:GetOwner()];
	local toPlayer = Players[toCity:GetOwner()];

  print(string.format("Migrants have relocated from %s (owned by %s) to %s (owned by %s)", 
    fromCity:GetName(), fromPlayer:GetName(), toCity:GetName(), toPlayer:GetName()))
  print(" - FROM " .. GetProsperityDebugString(fromCity))
  print(" - TO   " .. GetProsperityDebugString(toCity))
  print("-------------------------------------")

  -- DEBUG: debugMetWar
  --   Attempting to track down the case where emigration happens
  --   to an unmet civilization or to one at war, both of which
  --   should not happen.
  local met, war = HasMetWar(fromPlayer, toPlayer)
  local debugMetWar = " ("
  if not met then debugMetWar = debugMetWar .. "un" end
  debugMetWar = debugMetWar .. "met, "
  if war then 
    debugMetWar = debugMetWar .. "war"
  else
    debugMetWar = debugMetWar .. "peace"
  end
  debugMetWar = debugMetWar .. ") "
  
	if fromPlayer:IsHuman() and fromPlayer ~= toPlayer then	-- show only in case of foreign emigration
  -- DEBUG: debugMetWar
  local destination = GetPlayerName(toPlayer);
		--local summary = "A [ICON_CITIZEN] citizen from " .. fromCity:GetName() .. " left for the " .. destination;
		--print("creating a notification");
		local smr = Locale.ConvertTextKey("TXT_KEY_EMIGRATION_SUMMARY", fromCity:GetName(), destination .. debugMetWar, 
      string.format("%.1f", fromProsp), string.format ("%.1f", toProsp));
		local txt = Locale.ConvertTextKey("TXT_KEY_EMIGRATION_TEXT", destination);
		table.insert(notifications, { type = "Emigration", text = txt, summary = smr, city = fromCity });
	elseif toPlayer:IsHuman() then
		local source = fromCity:GetName();
		if fromPlayer ~= toPlayer then
      -- DS: Ideally, need a new TXT_KEYs for this case. The original author was lazy, too, and
      -- overloaded the TXT_KEY ("the Roman Empire" or "the Boston", as good and bad examples).
      -- I also did not update non-English translations parameters.
			source = "the " .. GetPlayerName(fromPlayer);
		end
    
		--local summary = "A [ICON_CITIZEN] citizen from " .. source .. " came to " .. toCity:GetName();
		local smr = Locale.ConvertTextKey("TXT_KEY_IMMIGRATION_SUMMARY", source .. debugMetWar, toCity:GetName(),
      string.format("%.1f", fromProsp), string.format ("%.1f", toProsp));
		local txt = Locale.ConvertTextKey("TXT_KEY_IMMIGRATION_TEXT", source);
		table.insert(notifications, { type = "Immigration", text = txt, summary = smr, city = toCity });
	end
end
--------------------------------------------------------------
function NewTurn()
	-- show notifications on active player's turn
	for _, msg in pairs(notifications) do
		CustomNotification(msg.type, msg.text, msg.summary, 0, msg.city, 0, 0);
	end
	notifications = {};
end
--------------------------------------------------------------
function OnPopulationChange(iHexX, iHexY, iPopulation, iUnknown)
  local pPlot = Map.GetPlot(ToGridFromHex(iHexX, iHexY))
  local pCity = pPlot:GetPlotCity()
  
  -- This will fire on the from- and to-cities, but we only
  -- want to do something for the from-city.
  local modData = AccessData(pPlot, "Emigration");
  local iOldPopulation = modData.lastPopulation or 0
  
  local dPop = iPopulation - iOldPopulation

  --[[
  if pCity then
    local iOwner = pCity:GetOwner()
    print(string.format("%s (owned by %s) population %d (%+d)", 
      pCity:GetName(), Players[iOwner]:GetName(), iPopulation, dPop))
  end
  --]]
  
  modData.lastPopulation = iPopulation
  SaveData(pPlot)
end
--------------------------------------------------------------
Events.ActivePlayerTurnStart.Add( NewTurn );
Events.SerialEventCityPopulationChanged.Add( OnPopulationChange );
GameEvents.PlayerDoTurn.Add( Migration );
--------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------
function IsValid(player)	-- this player is in game
	return player and player:IsAlive()
end
--------------------------------------------------------------
function GetPlayerName(player)	-- get player's name for notification
	if player:IsMinorCiv() then
		local minorCivType = player:GetMinorCivType();
		local minorCivInfo = GameInfo.MinorCivilizations[minorCivType];
		return Locale.ConvertTextKey(minorCivInfo.Description);
	end
	local iCivType = player:GetCivilizationType();
	local civInfo = GameInfo.Civilizations[iCivType];			
	return Locale.ConvertTextKey(civInfo.Description);	
end
--------------------------------------------------------------
function hasSOL(player)
	return player:GetBuildingClassCount(GameInfoTypes.BUILDINGCLASS_STATUE_OF_LIBERTY) > 0;
end
--------------------------------------------------------------
function log2(n)
local _n = 2
local x = 1
    if (_n < n) then
        repeat
            x = x + 1
            _n = _n + _n
        until (_n >= n)
    elseif (_n > n) then
        if (n == 1) then
            return 0
        else
            return nil
        end
    end 
    if (_n > n) then
        return x-1
    else
        return x
    end 
end
--------------------------------------------------------------
function LogN(arg, base)
	return math.log(arg)/math.log(base);
end
--------------------------------------------------------------