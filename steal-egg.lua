-- ============================================================
--  URANIUM for STEAL AN EGG (standalone)
--  Game: Steal An Egg (PlaceId 107778070777162)
--  UI: Zolar Ui (https://github.com/Da7mu/Ui-Collection)
--
--  Standalone project. No other libraries required
--  (besides Zolar Ui, loaded remotely below).
--  Run:
--    loadstring(game:HttpGet("https://raw.githubusercontent.com/Korsac2026/steal-egg/main/steal-egg.lua"))()
--
--  Tabs:
--    Farm     : Auto Farm (steal nearest egg, carry home, plant it),
--               move method (AUTO/TP/TWEEN/WALK with auto-fallback),
--               auto plant, auto sell, live status.
--    Movement : Noclip, Fly, Walk speed, Fly speed.
--    ESP      : Egg ESP (green = stealable now), Player ESP.
--    Settings : theme, rescan, unload, discord.
--  Menu key: RightShift.
-- ============================================================

-- ---------- cleanup previous run ----------
pcall(function()
	local old = getgenv and getgenv().UraniumEgg or nil
	if old then
		if old.Window then pcall(function() old.Window:SetOpen(false) end) end
		if old.Unload then pcall(old.Unload) end
	end
	if getgenv then
		getgenv().UraniumEgg = nil
	end
end)

-- ---------- load Zolar Ui ----------
local Zolar = nil
do
	local urls = {
		"https://raw.githubusercontent.com/Da7mu/Ui-Collection/refs/heads/main/Zolar%20Ui/Library.lua",
		"https://raw.githubusercontent.com/Da7mu/Ui-Collection/main/Zolar%20Ui/Library.lua",
	}
	local err
	for i = 1, #urls do
		local ok, lib = pcall(function()
			return loadstring(game:HttpGet(urls[i]))()
		end)
		if ok and lib then Zolar = lib break end
		err = lib
	end
	if not Zolar then
		error("[Uranium] Zolar Ui failed to load: " .. tostring(err), 0)
	end
end
-- Keep RightShift menu convention (Zolar default is G).
pcall(function() Zolar.MenuKeybind = Enum.KeyCode.RightShift end)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local TARGET_PLACE = 107778070777162
local DISCORD_INVITE = "https://discord.gg/unWK5GXa9U"

local WHITE = Color3.new(1, 1, 1)
local GREEN = Color3.fromRGB(80, 255, 140)
local BLACK = Color3.new(0, 0, 0)

local OWN_NAMES = {
	["UraniumESP"] = true,
	["Uranium_HL"] = true,
	["Uranium_BB"] = true,
}

local function isOurEsp(inst)
	local node = inst
	while node do
		local ok, nm = pcall(function() return node.Name end)
		if ok and OWN_NAMES[nm] then return true end
		node = node.Parent
	end
	return false
end

local State = {
	running = true,
	-- farm
	farm = false,
	autoPlant = true,
	autoSell = false,
	sellInterval = 120,
	moveMethod = "AUTO", -- AUTO cycles TP -> TWEEN -> WALK on failure
	tpDead = false, -- latched when TP gets rubber-banded this session
	tweenDead = false, -- latched when tween gets eaten too (walk-only)
	walkOnly = false, -- latched: server locked all artificial movement
	lastMove = "-",
	safeMode = true, -- ON: farm never flies, TP only short hops, walk capped
	maxTpHop = 50, -- TP allowed only under this distance in safe mode
	safeWalkCap = 50, -- walk speed cap in safe mode
	tweenSpeed = 150,
	walkSpeed = 32,
	flySpeed = 70,
	radius = 4000,
	-- movement
	noclip = false,
	fly = false,
	-- esp
	eggEsp = true,
	playerEsp = false,
	chams = true,
	labels = true,
	maxDist = 2000,
	textSize = 14,
	colEgg = WHITE,
	colEggOpen = GREEN,
	colPlayer = WHITE,
}

local Tracked = {} -- [instance] = {kind, target, part, hl, bb, txt, label, root, stealable}
local Connections = {}
local UiRefs = {}
local SavedHolder, SavedPopup = nil, nil
local FlyBV, FlyBG = nil, nil
local FlyKeys = { W = false, A = false, S = false, D = false, Up = false, Down = false }
local StatusLabel = nil
local Window = nil

local function trackConnection(conn)
	Connections[#Connections + 1] = conn
	return conn
end

local function notify(title, desc, icon)
	if Zolar then
		pcall(function()
			Zolar:Notification({ Name = title, Description = desc or "", Icon = icon or "bell", Duration = 5 })
		end)
	end
end

local function lowerName(inst)
	local ok, name = pcall(function() return inst.Name end)
	if not ok or type(name) ~= "string" then return "" end
	return string.lower(name)
end

local function myCharacter()
	return LocalPlayer and LocalPlayer.Character or nil
end

local function myHRP()
	local char = myCharacter()
	return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function myHumanoid()
	local char = myCharacter()
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function inWorkspace(obj)
	local ok, res = pcall(function() return obj:IsDescendantOf(workspace) end)
	return ok and res
end

local function rootPosition()
	local hrp = myHRP()
	if hrp then return hrp.Position end
	if Camera then return Camera.CFrame.Position end
	return Vector3.new(0, 0, 0)
end

local function setStatus(s)
	if StatusLabel then
		pcall(function() StatusLabel:Set(s) end)
	end
end

-- ===================== MOVEMENT (TP -> TWEEN -> WALK) =====================

-- Instant TP with rubber-band detection. Returns true if we stayed there.
local function tpTo(pos)
	local hrp = myHRP()
	if not hrp then return false end
	local from = hrp.Position
	pcall(function() hrp.CFrame = CFrame.new(pos) end)
	task.wait(0.35)
	local hrp2 = myHRP()
	if not hrp2 then return false end
	local want = (pos - from).Magnitude
	local got = (hrp2.Position - pos).Magnitude
	if want > 25 and got > 25 then
		return false -- snapped back: TP eaten/detected
	end
	return got <= 20
end

-- Smooth tween (anchored so physics doesn't fight it).
local function tweenTo(pos, speed)
	local hrp = myHRP()
	if not hrp then return false end
	local dist = (hrp.Position - pos).Magnitude
	if dist < 4 then return true end
	local dur = math.clamp(dist / (speed or 150), 0.3, 14)
	local wasAnchored, wasCollide = hrp.Anchored, hrp.CanCollide
	pcall(function()
		hrp.Anchored = true
		hrp.CanCollide = false
	end)
	local tw = nil
	pcall(function()
		tw = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = CFrame.new(pos) })
		tw:Play()
	end)
	if not tw then
		pcall(function()
			hrp.Anchored = wasAnchored
			hrp.CanCollide = wasCollide
		end)
		return false
	end
	local t0 = os.clock()
	while os.clock() - t0 < dur + 2.5 do
		if not State.running then break end
		local h = myHRP()
		if not h then break end
		if (h.Position - pos).Magnitude <= 8 then break end
		task.wait(0.15)
	end
	pcall(function() tw:Cancel() end)
	pcall(function()
		hrp.Anchored = wasAnchored
		hrp.CanCollide = wasCollide
	end)
	local h2 = myHRP()
	return h2 and (h2.Position - pos).Magnitude <= 12 or false
end

-- Legit-looking walk with stuck detection (jump + fail).
-- Safe mode caps speed: server knows your trained Speed stat.
local function walkTo(pos, timeout)
	local hum, hrp = myHumanoid(), myHRP()
	if not hum or not hrp then return false end
	local spd = State.safeMode and math.min(State.walkSpeed, State.safeWalkCap) or State.walkSpeed
	pcall(function() hum.WalkSpeed = spd end)
	pcall(function() hum:MoveTo(pos) end)
	local t0 = os.clock()
	-- Server clamps real velocity (~13 studs/s measured), so budget
	-- generously or long walks time out before arriving.
	local limit = timeout or math.clamp((hrp.Position - pos).Magnitude / 12 + 15, 10, 150)
	local lastPos, lastMove, stuck = hrp.Position, os.clock(), 0
	while os.clock() - t0 < limit do
		if not State.running then return false end
		local h, hm = myHRP(), myHumanoid()
		if not h or not hm then return false end
		if (h.Position - pos).Magnitude <= 8 then
			pcall(function() hm:Move(Vector3.new(0, 0, 0)) end)
			return true
		end
		if os.clock() - lastMove >= 1.5 then
			if (h.Position - lastPos).Magnitude < 2 then
				stuck = stuck + 1
				pcall(function() hm.Jump = true end)
				pcall(function() hm:MoveTo(pos) end)
				if stuck >= 3 then
					pcall(function() hm:Move(Vector3.new(0, 0, 0)) end)
					return false
				end
			else
				stuck = 0
			end
			lastPos, lastMove = h.Position, os.clock()
		end
		task.wait(0.2)
	end
	local hf = myHumanoid()
	if hf then pcall(function() hf:Move(Vector3.new(0, 0, 0)) end) end
	local h2 = myHRP()
	return h2 and (h2.Position - pos).Magnitude <= 12 or false
end

-- Dispatcher: AUTO tries TP, falls back to TWEEN then WALK on detection.
-- Safe mode: TP only for short hops (long jumps scream in server logs),
-- farm never uses fly (BodyVelocity physics is the #1 ban flag).
-- Latches: tpDead/tweenDead persist per session; both dead = walk-only.
local function moveTo(pos)
	local hrp0 = myHRP()
	local dist0 = hrp0 and (hrp0.Position - pos).Magnitude or math.huge
	local methods
	if State.walkOnly then
		methods = { "WALK" }
	elseif State.moveMethod == "AUTO" then
		methods = {}
		if not State.tpDead and not (State.safeMode and dist0 > State.maxTpHop) then
			methods[#methods + 1] = "TP"
		end
		if not State.tweenDead then
			methods[#methods + 1] = "TWEEN"
		end
		methods[#methods + 1] = "WALK"
	else
		methods = { State.moveMethod }
	end
	for _, m in ipairs(methods) do
		if not State.running then return false end
		local ok = false
		if m == "TP" then
			ok = tpTo(pos)
		elseif m == "TWEEN" then
			ok = tweenTo(pos, State.tweenSpeed)
		else
			ok = walkTo(pos)
		end
		if ok then
			State.lastMove = m
			return true
		end
		if State.moveMethod == "AUTO" then
			if m == "TP" and not State.tpDead then
				State.tpDead = true
				notify("URANIUM", "TP rubber-banded — TWEEN/WALK from now on", "alert")
			elseif m == "TWEEN" and not State.tweenDead then
				State.tweenDead = true
				notify("URANIUM", "Tween eaten — WALK only from now on", "alert")
			end
			if State.tpDead and State.tweenDead and not State.walkOnly then
				State.walkOnly = true
				notify("URANIUM", "Server locked movement: WALK-ONLY mode (slow but safe)", "alert")
			end
		end
	end
	return false
end

local function waitRespawn()
	while State.running and not myHRP() do
		task.wait(0.5)
	end
	task.wait(0.3)
end

-- ===================== FARM: EGGS =====================

local function eggRootPart(egg)
	if typeof(egg) ~= "Instance" then return nil end
	if egg:IsA("BasePart") then return egg end
	return egg:FindFirstChildWhichIsA("BasePart", true)
end

local function eggPrompt(egg)
	if typeof(egg) ~= "Instance" then return nil end
	if egg:IsA("ProximityPrompt") and egg.Name == "CarryAreaEgg" then return egg end
	local p = egg:FindFirstChild("CarryAreaEgg", true)
	if p and p:IsA("ProximityPrompt") then return p end
	return nil
end

-- All egg spots: anything carrying a CarryAreaEgg prompt.
local function allEggSpots()
	local out = {}
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("ProximityPrompt") and inst.Name == "CarryAreaEgg" and not isOurEsp(inst) then
			local host = inst.Parent
			if host then
				local part = host:IsA("BasePart") and host or host:FindFirstChildWhichIsA("BasePart", true)
				if part and inWorkspace(part) then
					out[#out + 1] = { prompt = inst, part = part, pos = part.Position, open = inst.Enabled }
				end
			end
		end
	end
	return out
end

-- Nearest stealable egg (enabled prompt first, then nearest egg spot).
local function findEggTarget(origin, radius)
	local best, bestDist = nil, radius or State.radius
	for _, t in ipairs(allEggSpots()) do
		if t.open then
			local d = (t.pos - origin).Magnitude
			if d < bestDist then best, bestDist = t, d end
		end
	end
	if best then return best end
	for _, t in ipairs(allEggSpots()) do
		local d = (t.pos - origin).Magnitude
		if d < bestDist then best, bestDist = t, d end
	end
	return best
end

local function listTools()
	local set = {}
	local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") then set[t] = true end
		end
	end
	local char = myCharacter()
	if char then
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") then set[t] = true end
		end
	end
	return set
end

-- Egg tools carry a UID string attribute (gear like Trap/Bat does not).
local function getEggUid(tool)
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then return nil end
	local ok, uid = pcall(function() return tool:GetAttribute("UID") end)
	if ok and type(uid) == "string" and uid ~= "" then return uid end
	return nil
end

local function isEggTool(tool)
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then return false end
	local ok, t = pcall(function() return tool:GetAttribute("ItemType") end)
	if ok and t == "AssetEgg" then return true end
	return getEggUid(tool) ~= nil
end

local function listEggTools()
	local out = {}
	local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if isEggTool(t) then out[#out + 1] = t end
		end
	end
	local char = myCharacter()
	if char then
		for _, t in ipairs(char:GetChildren()) do
			if isEggTool(t) then out[#out + 1] = t end
		end
	end
	return out
end

local function eggUidSet()
	local set = {}
	for _, t in ipairs(listEggTools()) do
		local uid = getEggUid(t)
		if uid then set[uid] = true end
	end
	return set
end

local function pressE(holdTime)
	if not VIM then return false end
	holdTime = holdTime or 0.3
	local ok = false
	pcall(function()
		VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
		ok = true
	end)
	if not ok then return false end
	task.wait(holdTime)
	pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
	return true
end

-- Fire one prompt: executor fast-path, honest hold, real E fallback.
local function firePrompt(prompt)
	if typeof(prompt) ~= "Instance" or not prompt:IsA("ProximityPrompt") then return false end
	if not prompt.Enabled then return false end
	if typeof(fireproximityprompt) == "function" then
		pcall(fireproximityprompt, prompt)
		return true
	end
	local began = false
	pcall(function()
		prompt:InputHoldBegin()
		began = true
	end)
	if began then
		task.wait((prompt.HoldDuration or 0) + 0.2)
		pcall(function() prompt:InputHoldEnd() end)
		return true
	end
	return pressE((prompt.HoldDuration or 0) + 0.4)
end

-- Steal: go near (real prompt range), fire, verify a NEW egg tool (by UID).
local function stealEgg(t)
	if not t or not inWorkspace(t.prompt) then return false end
	local before = eggUidSet()
	local dest = t.pos + Vector3.new(0, 3, 0)
	if not moveTo(dest) then return false end
	if not State.farm then return false end
	task.wait(0.3)
	-- Re-resolve: prompts wake up as we approach.
	if not t.prompt.Enabled then
		task.wait(0.6)
	end
	if not t.prompt.Enabled then return false end
	firePrompt(t.prompt)
	-- Wait for the 1.2s hold to complete server-side, then look for the egg.
	for _ = 1, 10 do
		if not State.farm then return false end
		task.wait(0.3)
		for _, tool in ipairs(listEggTools()) do
			local uid = getEggUid(tool)
			if uid and not before[uid] and inWorkspace(tool) then
				return true, tool
			end
		end
	end
	return false
end

-- My plot: PlotSign text matches username (fallback: nearest plot).
local MyPlot, MyPlotAt = nil, 0
local function myPlot()
	if MyPlot and MyPlot.Parent and os.clock() - MyPlotAt < 60 then return MyPlot end
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, p in ipairs(plots:GetChildren()) do
			local sign = p:FindFirstChild("PlotSign")
			local lbl = sign and sign:FindFirstChildWhichIsA("TextLabel", true)
			local txt = ""
			pcall(function() txt = tostring(lbl and lbl.Text or "") end)
			if txt == LocalPlayer.Name or txt == LocalPlayer.DisplayName then
				MyPlot, MyPlotAt = p, os.clock()
				return p
			end
		end
		-- Fallback: nearest plot by spawn.
		local origin = rootPosition()
		local best, bd = nil, math.huge
		for _, p in ipairs(plots:GetChildren()) do
			local sp = p:FindFirstChild("SpawnPoint")
			if sp and sp:IsA("BasePart") then
				local d = (sp.Position - origin).Magnitude
				if d < bd then best, bd = p, d end
			end
		end
		if best then
			MyPlot, MyPlotAt = best, os.clock()
			return best
		end
	end
	return nil
end

local function plotCenter()
	local p = myPlot()
	if not p then return nil end
	local c = p:FindFirstChild("CenterPoint")
	if c and c:IsA("BasePart") then return c.Position end
	local sp = p:FindFirstChild("SpawnPoint")
	if sp and sp:IsA("BasePart") then return sp.Position end
	return nil
end

-- Plant: stand in my plot, equip an EGG tool (UID attribute, never gear
-- like Trap/Bat), Activate (game plants it via its own tryPlace).
local function plantCarried()
	local center = plotCenter()
	if not center then
		notify("URANIUM", "Plot not found", "alert")
		return false
	end
	if not moveTo(center + Vector3.new(0, 4, 0)) then return false end
	if not State.farm then return false end
	local tools = listEggTools()
	if #tools == 0 then
		setStatus("FARM: no egg tool to plant")
		return false
	end
	local hum = myHumanoid()
	local char = myCharacter()
	for i = #tools, 1, -1 do
		if not State.farm then return false end
		local tool = tools[i]
		if tool and tool.Parent then
			if hum and char and tool.Parent ~= char then
				pcall(function() hum:EquipTool(tool) end)
				task.wait(0.4)
			end
			pcall(function() tool:Activate() end)
			task.wait(0.8)
			if not tool.Parent or not inWorkspace(tool) then
				return true -- planted (tool consumed)
			end
		end
	end
	return false
end

local function stripTags(s)
	return (tostring(s or ""):gsub("<[^>]+>", ""))
end

local function findSellAll()
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("ProximityPrompt") and not isOurEsp(inst) then
			local hay = stripTags(inst.ActionText):lower()
			if string.find(hay, "sell all", 1, true) then
				local host = inst.Parent
				local part = host and (host:IsA("BasePart") and host or host:FindFirstChildWhichIsA("BasePart", true))
				if part and inWorkspace(part) then
					return inst, part.Position
				end
			end
		end
	end
	return nil
end

local function sellAllNow()
	local prompt, pos = findSellAll()
	if not prompt then
		notify("URANIUM", "Sell prompt not found", "info")
		return false
	end
	if not moveTo(pos + Vector3.new(0, 2, 0)) then return false end
	firePrompt(prompt)
	task.wait(0.5)
	notify("URANIUM", "Sell fired", "check")
	return true
end

local function autoFarmLoop()
	while State.farm and State.running do
		waitRespawn()
		if not State.farm then break end
		local origin = rootPosition()
		setStatus("FARM: looking for eggs... (" .. State.lastMove .. ")")
		local t = findEggTarget(origin)
		if not t then
			task.wait(1.0)
		else
			local d = math.floor((t.pos - origin).Magnitude)
			setStatus("FARM: egg " .. d .. "m (" .. (t.open and "OPEN" or "waiting") .. ")")
			if not t.open then
				-- Walk into range so the prompt wakes up, then re-check.
				moveTo(t.pos + Vector3.new(0, 3, 0))
				task.wait(0.6)
				if not State.farm then break end
				t = findEggTarget(rootPosition())
				if not t or not t.open then
					task.wait(0.8)
				else
					local ok = stealEgg(t)
					setStatus(ok and "FARM: egg stolen!" or "FARM: steal failed")
					if ok and State.autoPlant then
						task.wait(0.3)
						if plantCarried() then
							setStatus("FARM: planted!")
							notify("URANIUM", "Egg planted", "check")
						else
							setStatus("FARM: plant failed")
						end
					end
				end
			else
				local ok = stealEgg(t)
				setStatus(ok and "FARM: egg stolen!" or "FARM: steal failed")
				if ok and State.autoPlant then
					task.wait(0.3)
					if plantCarried() then
						setStatus("FARM: planted!")
						notify("URANIUM", "Egg planted", "check")
					else
						setStatus("FARM: plant failed")
					end
				end
			end
		end
		task.wait(0.4)
	end
end

local LastSell = 0
local function autoSellTick()
	if not State.autoSell then return end
	if os.clock() - LastSell < State.sellInterval then return end
	LastSell = os.clock()
	task.spawn(function()
		if State.farm or not State.running then return end
		sellAllNow()
	end)
end

-- ===================== MOVEMENT (noclip / fly) =====================

local function setNoclipParts(collide)
	local char = myCharacter()
	if not char then return end
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			if p.Name == "HumanoidRootPart" then
				pcall(function() p.CanCollide = false end)
			else
				pcall(function() p.CanCollide = collide end)
			end
		end
	end
end

local function enableFly()
	if FlyBV then return end
	local hrp = myHRP()
	if not hrp then return end
	FlyBV = Instance.new("BodyVelocity")
	FlyBV.Name = "UraniumFlyBV"
	FlyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
	FlyBV.Velocity = Vector3.new(0, 0, 0)
	FlyBV.Parent = hrp
	FlyBG = Instance.new("BodyGyro")
	FlyBG.Name = "UraniumFlyBG"
	FlyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
	FlyBG.CFrame = hrp.CFrame
	FlyBG.Parent = hrp
end

local function disableFly()
	if FlyBV then pcall(function() FlyBV:Destroy() end) end
	if FlyBG then pcall(function() FlyBG:Destroy() end) end
	FlyBV, FlyBG = nil, nil
	local hrp = myHRP()
	if hrp then
		pcall(function() hrp.Velocity = Vector3.new(0, 0, 0) end)
	end
end

local function flyStep()
	if not State.fly or not FlyBV or not FlyBG then return end
	local hrp = myHRP()
	if not hrp or not Camera then return end
	local speed = State.flySpeed
	local cf = Camera.CFrame
	local move = Vector3.new(0, 0, 0)
	if FlyKeys.W then move = move + cf.LookVector end
	if FlyKeys.S then move = move - cf.LookVector end
	if FlyKeys.D then move = move + cf.RightVector end
	if FlyKeys.A then move = move - cf.RightVector end
	if FlyKeys.Up then move = move + Vector3.new(0, 1, 0) end
	if FlyKeys.Down then move = move - Vector3.new(0, 1, 0) end
	if move.Magnitude > 0 then
		move = move.Unit * speed
	end
	pcall(function()
		FlyBV.Velocity = move
		FlyBG.CFrame = cf
	end)
end

local function applySpeed(v)
	local hum = myHumanoid()
	if hum then
		pcall(function() hum.WalkSpeed = v or State.walkSpeed end)
	end
end

-- ===================== ESP =====================

local EspFolder = nil

local function getSafeUiParent()
	local ok, parent = pcall(function()
		if gethui then return gethui() end
		return game:GetService("CoreGui")
	end)
	if ok and parent then return parent end
	return (LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")) or workspace
end

local function initEspHolders()
	if not EspFolder or not EspFolder.Parent then
		EspFolder = Instance.new("Folder")
		EspFolder.Name = "UraniumESP"
		EspFolder.Parent = getSafeUiParent()
	end
end
initEspHolders()

local function makeEspObjects(target, part)
	initEspHolders()
	local col = WHITE
	local hl = Instance.new("Highlight")
	hl.Name = "Uranium_HL"
	hl.Adornee = target
	hl.FillColor = col
	hl.FillTransparency = 1
	hl.OutlineColor = col
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = State.chams
	hl.Parent = EspFolder

	local bb = Instance.new("BillboardGui")
	bb.Name = "Uranium_BB"
	bb.Adornee = part
	bb.AlwaysOnTop = true
	bb.Size = UDim2.new(0, 140, 0, 28)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.Enabled = State.labels
	bb.Parent = EspFolder

	local bg = Instance.new("Frame")
	bg.Name = "Badge"
	bg.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	bg.BackgroundTransparency = 0.25
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BorderSizePixel = 0
	bg.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bg

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Border"
	stroke.Color = col
	stroke.Thickness = 1.2
	stroke.Transparency = 0.2
	stroke.Parent = bg

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.BackgroundColor3 = col
	dot.Position = UDim2.new(0, 7, 0.5, -4)
	dot.Size = UDim2.new(0, 8, 0, 8)
	dot.BorderSizePixel = 0
	dot.Parent = bg

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local txt = Instance.new("TextLabel")
	txt.Name = "Label"
	txt.BackgroundTransparency = 1
	txt.Position = UDim2.new(0, 20, 0, 0)
	txt.Size = UDim2.new(1, -24, 1, 0)
	txt.Font = Enum.Font.GothamBold
	txt.TextSize = State.textSize or 12
	txt.TextColor3 = Color3.fromRGB(245, 245, 245)
	txt.TextXAlignment = Enum.TextXAlignment.Left
	txt.Text = ""
	txt.Parent = bg

	return hl, bb, txt, stroke, dot
end

local function removeEntry(inst)
	local e = Tracked[inst]
	if e then
		if e.hl then pcall(function() e.hl:Destroy() end) end
		if e.bb then pcall(function() e.bb:Destroy() end) end
		Tracked[inst] = nil
	end
end

local function clearKind(kind)
	for inst, e in pairs(Tracked) do
		if e.kind == kind then
			removeEntry(inst)
		end
	end
end

local function isKindEnabled(kind)
	if kind == "egg" then return State.eggEsp end
	if kind == "player" then return State.playerEsp end
	return false
end

local function kindColor(kind, open)
	if kind == "egg" then return open and State.colEggOpen or State.colEgg end
	if kind == "player" then return State.colPlayer end
	return WHITE
end

local function addEggEntry(prompt, part)
	if Tracked[prompt] then return end
	if not inWorkspace(prompt) or not inWorkspace(part) then return end
	local target = prompt.Parent
	if target and target:IsA("Attachment") then target = target.Parent end
	if not target then return end
	local hl, bb, txt, stroke, dot = makeEspObjects(target, part)
	Tracked[prompt] = { kind = "egg", target = target, part = part, hl = hl, bb = bb, txt = txt, stroke = stroke, dot = dot, label = "EGG", root = prompt, open = false }
end

local function fullScan()
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("ProximityPrompt") and inst.Name == "CarryAreaEgg" and not isOurEsp(inst) then
			local host = inst.Parent
			if host then
				local part = host:IsA("BasePart") and host or host:FindFirstChildWhichIsA("BasePart", true)
				if part then
					pcall(addEggEntry, inst, part)
				end
			end
		end
	end
	if State.playerEsp then
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LocalPlayer and plr.Character then
				local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
				if hrp and not Tracked[plr.Character] then
					local hl, bb, txt, stroke, dot = makeEspObjects(plr.Character, hrp)
					Tracked[plr.Character] = { kind = "player", target = plr.Character, part = hrp, hl = hl, bb = bb, txt = txt, stroke = stroke, dot = dot, label = plr.Name:upper(), root = plr.Character }
				end
			end
		end
	end
end

local function countEggs()
	local n, open = 0, 0
	for _, e in pairs(Tracked) do
		if e.kind == "egg" and e.hl then
			n = n + 1
			if e.open then open = open + 1 end
		end
	end
	return n, open
end

local function updateEntry(e, origin, maxDist)
	local root = e.root
	if not root or not inWorkspace(root) then
		return false
	end
	if not e.target or not e.part then
		return true
	end
	if e.kind == "egg" and e.root:IsA("ProximityPrompt") then
		local isOpen = false
		pcall(function() isOpen = e.root.Enabled end)
		e.open = isOpen
	end
	local pos = e.part.Position
	local dist = (pos - origin).Magnitude
	if dist > maxDist then
		if e.hl then e.hl.Enabled = false end
		if e.bb then e.bb.Enabled = false end
		return true
	end
	local col = kindColor(e.kind, e.open)
	if e.hl then
		e.hl.Enabled = State.chams
		e.hl.OutlineColor = col
		e.hl.FillColor = col
	end
	if e.bb then e.bb.Enabled = State.labels end
	if e.stroke then pcall(function() e.stroke.Color = col end) end
	if e.dot then pcall(function() e.dot.BackgroundColor3 = col end) end
	local title = e.label
	if e.kind == "egg" and e.open then title = "EGG OPEN" end
	if e.txt then
		e.txt.Text = title .. " [" .. tostring(math.floor(dist)) .. "m]"
	end
	return true
end

-- ===================== ZOLAR UI =====================

local function setToggle(ref, v)
	if ref then pcall(function() ref:Set(v) end) end
end

local MoveModes = { "AUTO", "TP", "TWEEN", "WALK" }

local function buildGui()
	local window = Zolar:Window({
		Name = "URANIUM",
		Icon = "egg",
		Accent = Color3.fromRGB(235, 235, 235),
	})

	-- Farm tab
	local farmTab = window:Tab({ Name = "Farm", Icon = "egg" })
	local farmMain = farmTab:SubTab({ Name = "Auto", Icon = "zap" })

	local fSec = farmMain:Section({ Name = "Auto Farm", Side = 1 })
	UiRefs.farmTgl = fSec:Toggle({
		Name = "Auto Farm", Default = State.farm, Flag = "uraegg_farm",
		Callback = function(v)
			State.farm = v
			if v then
				State.tpDead = false
				State.tweenDead = false
				State.walkOnly = false
				if State.fly then
					State.fly = false
					setToggle(UiRefs.flyTgl, false)
					disableFly()
					notify("URANIUM", "Fly OFF for safe farm (fly = ban flag)", "alert")
				end
				task.spawn(autoFarmLoop)
			end
		end,
	})
	fSec:Button({
		Name = "Move mode: AUTO",
		Callback = function()
			local i = 1
			for k, m in ipairs(MoveModes) do
				if m == State.moveMethod then i = k break end
			end
			i = i % #MoveModes + 1
			State.moveMethod = MoveModes[i]
			State.tpDead = false
			notify("URANIUM", "Move method: " .. State.moveMethod, "move")
			setStatus("Move method: " .. State.moveMethod)
		end,
	})
	fSec:Toggle({
		Name = "Safe mode (no fly, short TPs)", Default = State.safeMode, Flag = "uraegg_safe",
		Callback = function(v) State.safeMode = v end,
	})
	UiRefs.plantTgl = fSec:Toggle({
		Name = "Auto Plant at plot", Default = State.autoPlant, Flag = "uraegg_plant",
		Callback = function(v) State.autoPlant = v end,
	})
	UiRefs.sellTgl = fSec:Toggle({
		Name = "Auto Sell", Default = State.autoSell, Flag = "uraegg_sell",
		Callback = function(v) State.autoSell = v end,
	})
	fSec:Slider({
		Name = "Egg radius", Min = 100, Max = 6000, Default = State.radius, Suffix = "m", Flag = "uraegg_radius",
		Callback = function(v) State.radius = v end,
	})
	fSec:Slider({
		Name = "Sell every", Min = 30, Max = 600, Default = State.sellInterval, Suffix = "s", Flag = "uraegg_sellint",
		Callback = function(v) State.sellInterval = v end,
	})
	fSec:Paragraph({
		Title = "How it works",
		Content = "Steals the nearest open egg, carries it to your plot and plants it. Safe mode walks fast instead of flying (fly gets you banned) and only TPs short hops. AUTO movement falls back to TWEEN then WALK if the server rubber-bands you.",
	})

	local mSec = farmMain:Section({ Name = "Movement", Side = 2 })
	mSec:Slider({
		Name = "Tween speed", Min = 40, Max = 400, Default = State.tweenSpeed, Suffix = "studs/s", Flag = "uraegg_tween",
		Callback = function(v) State.tweenSpeed = v end,
	})
	mSec:Slider({
		Name = "Walk speed", Min = 16, Max = 200, Default = State.walkSpeed, Suffix = "studs/s", Flag = "uraegg_walk",
		Callback = function(v)
			State.walkSpeed = v
			applySpeed(v)
		end,
	})
	mSec:Button({
		Name = "Go to my plot",
		Callback = function()
			task.spawn(function()
				local c = plotCenter()
				if c then
					moveTo(c + Vector3.new(0, 4, 0))
				else
					notify("URANIUM", "Plot not found", "alert")
				end
			end)
		end,
	})
	mSec:Button({
		Name = "Sell All now",
		Callback = function()
			task.spawn(function() sellAllNow() end)
		end,
	})
	local statSec = farmMain:Section({ Name = "Status", Side = 2 })
	StatusLabel = statSec:Label({ Name = "starting..." })

	-- Movement tab
	local movTab = window:Tab({ Name = "Movement", Icon = "wind" })
	local movMain = movTab:SubTab({ Name = "Main", Icon = "move" })
	local movSec = movMain:Section({ Name = "Movement", Side = 1 })
	UiRefs.noclipTgl = movSec:Toggle({
		Name = "Noclip", Default = State.noclip, Flag = "uraegg_noclip",
		Callback = function(v)
			State.noclip = v
			if not v then setNoclipParts(true) end
		end,
	})
	UiRefs.flyTgl = movSec:Toggle({
		Name = "Fly (WASD + Space/Shift)", Default = State.fly, Flag = "uraegg_fly",
		Callback = function(v)
			State.fly = v
			if v then enableFly() else disableFly() end
		end,
	})
	movSec:Paragraph({
		Title = "Hotkeys",
		Content = "N toggles Noclip, V toggles Fly. RightShift toggles this menu.",
	})
	local spdSec = movMain:Section({ Name = "Speed", Side = 2 })
	spdSec:Slider({
		Name = "Fly speed", Min = 20, Max = 150, Default = State.flySpeed, Flag = "uraegg_flyspeed",
		Callback = function(v) State.flySpeed = v end,
	})
	spdSec:Paragraph({
		Title = "Note",
		Content = "Walk speed is on the Farm tab. The game trains Speed on the treadmill; high values may get corrected by the server.",
	})

	-- ESP tab
	local espTab = window:Tab({ Name = "ESP", Icon = "eye" })
	local espMain = espTab:SubTab({ Name = "Main", Icon = "scan-eye" })
	local eSec = espMain:Section({ Name = "Eggs", Side = 1 })
	UiRefs.eggTgl = eSec:Toggle({
		Name = "Egg ESP", Default = State.eggEsp, Flag = "uraegg_esp",
		Callback = function(v)
			State.eggEsp = v
			if v then fullScan() else clearKind("egg") end
		end,
	})
	eSec:Colorpicker({
		Name = "Egg color", Default = State.colEgg, Flag = "uraegg_colegg",
		Callback = function(v) State.colEgg = v end,
	})
	eSec:Colorpicker({
		Name = "Stealable color", Default = State.colEggOpen, Flag = "uraegg_coleggo",
		Callback = function(v) State.colEggOpen = v end,
	})
	UiRefs.playerTgl = eSec:Toggle({
		Name = "Player ESP", Default = State.playerEsp, Flag = "uraegg_playeresp",
		Callback = function(v)
			State.playerEsp = v
			if v then fullScan() else clearKind("player") end
		end,
	})
	eSec:Colorpicker({
		Name = "Player color", Default = State.colPlayer, Flag = "uraegg_colplayer",
		Callback = function(v) State.colPlayer = v end,
	})
	local sSec = espMain:Section({ Name = "Style", Side = 2 })
	sSec:Toggle({
		Name = "Chams (outline)", Default = State.chams, Flag = "uraegg_chams",
		Callback = function(v) State.chams = v end,
	})
	sSec:Toggle({
		Name = "Labels (name + dist)", Default = State.labels, Flag = "uraegg_labels",
		Callback = function(v) State.labels = v end,
	})
	sSec:Slider({
		Name = "Max distance", Min = 100, Max = 6000, Default = State.maxDist, Suffix = "m", Flag = "uraegg_maxdist",
		Callback = function(v) State.maxDist = v end,
	})
	sSec:Slider({
		Name = "Text size", Min = 10, Max = 24, Default = State.textSize, Flag = "uraegg_textsize",
		Callback = function(v)
			State.textSize = v
			for _, e in pairs(Tracked) do
				if e.txt then pcall(function() e.txt.TextSize = v end) end
			end
		end,
	})

	-- Settings tab
	local setTab = window:Tab({ Name = "Settings", Icon = "settings" })
	local cfgSub = setTab:SubTab({ Name = "Config", Icon = "save" })
	cfgSub:ThemeConfig({ })
	local miscSub = setTab:SubTab({ Name = "Misc", Icon = "info" })
	local miscSec = miscSub:Section({ Name = "Script", Side = 1 })
	miscSec:Button({
		Name = "Rescan world",
		Callback = function()
			fullScan()
			notify("URANIUM", "World rescanned", "refresh")
		end,
	})
	miscSec:Button({
		Name = "Copy Discord invite",
		Callback = function()
			pcall(function()
				if typeof(setclipboard) == "function" then
					setclipboard(DISCORD_INVITE)
				end
			end)
			notify("Discord", DISCORD_INVITE .. " — copied", "message-circle")
		end,
	})
	miscSec:Button({
		Name = "Unload script",
		Callback = function()
			if getgenv and getgenv().UraniumEgg and getgenv().UraniumEgg.Unload then
				pcall(getgenv().UraniumEgg.Unload)
				getgenv().UraniumEgg = nil
			end
		end,
	})
	miscSec:Paragraph({
		Title = "Help",
		Content = "RightShift toggles this menu. Farm steals the nearest open egg and plants it at your plot. If teleports get eaten, movement falls back automatically.",
	})

	window:Watermark({ Name = "URANIUM" })
	return window
end

-- ===================== STARTUP =====================

EspFolder = Instance.new("Folder")
EspFolder.Name = "UraniumESP"
do
	local ok, parent = pcall(function()
		if gethui then return gethui() end
		return game:GetService("CoreGui")
	end)
	EspFolder.Parent = (ok and parent) or workspace
end

trackConnection(UserInputService.InputBegan:Connect(function(input, gpe)
	if input.KeyCode == Enum.KeyCode.W then FlyKeys.W = true end
	if input.KeyCode == Enum.KeyCode.A then FlyKeys.A = true end
	if input.KeyCode == Enum.KeyCode.S then FlyKeys.S = true end
	if input.KeyCode == Enum.KeyCode.D then FlyKeys.D = true end
	if input.KeyCode == Enum.KeyCode.Space then FlyKeys.Up = true end
	if input.KeyCode == Enum.KeyCode.LeftShift then FlyKeys.Down = true end
	if not gpe then
		if input.KeyCode == Enum.KeyCode.N and UiRefs.noclipTgl then
			UiRefs.noclipTgl:Set(not State.noclip)
		elseif input.KeyCode == Enum.KeyCode.V and UiRefs.flyTgl then
			UiRefs.flyTgl:Set(not State.fly)
		end
	end
end))

trackConnection(UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.W then FlyKeys.W = false end
	if input.KeyCode == Enum.KeyCode.A then FlyKeys.A = false end
	if input.KeyCode == Enum.KeyCode.S then FlyKeys.S = false end
	if input.KeyCode == Enum.KeyCode.D then FlyKeys.D = false end
	if input.KeyCode == Enum.KeyCode.Space then FlyKeys.Up = false end
	if input.KeyCode == Enum.KeyCode.LeftShift then FlyKeys.Down = false end
end))

trackConnection(workspace.DescendantAdded:Connect(function(inst)
	if isOurEsp(inst) then return end
	if inst:IsA("ProximityPrompt") and inst.Name == "CarryAreaEgg" then
		task.delay(0.5, function()
			if Tracked[inst] or not inWorkspace(inst) then return end
			local host = inst.Parent
			if host then
				local part = host:IsA("BasePart") and host or host:FindFirstChildWhichIsA("BasePart", true)
				if part then
					pcall(addEggEntry, inst, part)
				end
			end
		end)
	elseif inst:IsA("Model") and inst.Name == LocalPlayer.Name and not Tracked[inst] then
		task.delay(0.5, function()
			if not State.playerEsp or Tracked[inst] or not inWorkspace(inst) then return end
			local hrp = inst:FindFirstChild("HumanoidRootPart")
			if hrp then
				local hl, bb, txt, stroke, dot = makeEspObjects(inst, hrp)
				Tracked[inst] = { kind = "player", target = inst, part = hrp, hl = hl, bb = bb, txt = txt, stroke = stroke, dot = dot, label = inst.Name:upper(), root = inst }
			end
		end)
	end
end))

trackConnection(workspace.DescendantRemoving:Connect(function(inst)
	if Tracked[inst] then
		removeEntry(inst)
	end
end))

trackConnection(LocalPlayer.CharacterAdded:Connect(function(char)
	task.wait(1)
	applySpeed(State.walkSpeed)
	if State.fly then enableFly() end
end))

do
	applySpeed(State.walkSpeed)
end
applySpeed(State.walkSpeed)
fullScan()

Window = buildGui()
pcall(function()
	if getgenv and getgenv().Zolar then
		if getgenv().Zolar.Holder then SavedHolder = getgenv().Zolar.Holder.Instance end
		if getgenv().Zolar.PopupHolder then SavedPopup = getgenv().Zolar.PopupHolder.Instance end
	end
end)

local accDist, accCode, accText, accFb = 0, 0, 0, 0
trackConnection(RunService.Heartbeat:Connect(function(dt)
	if not State.running then return end
	local hum = myHumanoid()
	if hum and hum.WalkSpeed ~= State.walkSpeed then
		applySpeed(State.walkSpeed)
	end
	if State.noclip then
		local char = myCharacter()
		if char then
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then
					pcall(function() p.CanCollide = false end)
				end
			end
		end
	end
	flyStep()
	accDist = accDist + dt
	accCode = accCode + dt
	accText = accText + dt
	local doDist = accDist >= 0.3
	local doCode = accCode >= 1.5
	local doText = accText >= 8
	if doDist then accDist = 0 end
	if doCode then accCode = 0 end
	if doText then
		accText = 0
		if State.eggEsp then fullScan() end
	end
	if not doDist and not doCode then
		autoSellTick()
		return
	end
	local origin = rootPosition()
	local maxDist = State.maxDist
	local dead = {}
	for inst, e in pairs(Tracked) do
		if not isKindEnabled(e.kind) then
			dead[#dead + 1] = inst
		else
			local ok, alive = pcall(updateEntry, e, origin, maxDist)
			if not ok or not alive then
				dead[#dead + 1] = inst
			end
		end
	end
	for i = 1, #dead do
		removeEntry(dead[i])
	end
	if doDist and StatusLabel then
		if not State.farm then
			local n, open = countEggs()
			pcall(function()
				local note = ""
				if game.PlaceId ~= TARGET_PLACE then
					note = " (outside STEAL AN EGG)"
				end
				StatusLabel:Set("eggs:" .. n .. " open:" .. open .. " move:" .. State.lastMove .. note)
			end)
		end
	end
	autoSellTick()
end))

if game.PlaceId ~= TARGET_PLACE then
	notify("URANIUM", "Outside STEAL AN EGG — farm disabled, ESP only", "info")
else
	notify("URANIUM loaded", "Press RightShift for the menu", "check")
end

pcall(function()
	if typeof(setclipboard) == "function" then
		setclipboard(DISCORD_INVITE)
	end
end)
notify("Join our Discord", DISCORD_INVITE .. " — invite copied to clipboard", "message-circle")

local Api = {}
Api.Window = Window
function Api.Unload()
	State.running = false
	State.farm = false
	State.fly = false
	State.noclip = false
	disableFly()
	pcall(function()
		local hum = myHumanoid()
		if hum then hum.WalkSpeed = 16 end
	end)
	setNoclipParts(true)
	for _, conn in ipairs(Connections) do
		pcall(function() conn:Disconnect() end)
	end
	for inst in pairs(Tracked) do
		removeEntry(inst)
	end
	pcall(function() EspFolder:Destroy() end)
	if Window then pcall(function() Window:SetOpen(false) end) end
	if SavedHolder then pcall(function() SavedHolder:Destroy() end) end
	if SavedPopup then pcall(function() SavedPopup:Destroy() end) end
	SavedHolder, SavedPopup = nil, nil
end

if getgenv then
	getgenv().UraniumEgg = Api
end

return Api
