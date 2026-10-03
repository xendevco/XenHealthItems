local ADDON = ...

local POTIONS = {
	271884, -- Concentrated Silvermoon Health Potion (high)
	271883, -- Concentrated Silvermoon Health Potion
	241304, -- Silvermoon Health Potion (high)
	241305, -- Silvermoon Health Potion
	211880, -- Algari Healing Potion
	211879,
	211878,
}

local STONES = {
	224464, -- Demonic Healthstone
	5512,   -- Healthstone
}

local DEFAULTS = {
	threshold = 40,
	onlyInCombat = true,
	simple = false,
	scale = 100,
	pingBanner = false,
	locked = true,
	showOnCooldown = false,
	point = "CENTER",
	relativePoint = "CENTER",
	x = 0,
	y = 160,
	minimapAngle = 225,
}

local db
local frame
local healthCurve
local percentCurve
local settingsCategory
local forceVisible = false
local testTimer
local ticker
local scanTimer
local reportedError = false

local bagCounts = {}
local spellByItem = {}
local potionSpells = {}
local stoneSpells = {}
local extraPotions = {}
local extraStones = {}

local function Say(msg)
	print("|cff4dff7aXen Health Items|r " .. msg)
end

local function InitDB()
	if type(XenHealthItemsDB) ~= "table" then
		-- One-time migration from the addon's old name (Health Pot Ping).
		local old = _G.HealthPotPingDB
		XenHealthItemsDB = {}
		if type(old) == "table" then
			for key, value in pairs(old) do
				XenHealthItemsDB[key] = value
			end
		end
	end
	db = XenHealthItemsDB
	for key, value in pairs(DEFAULTS) do
		if db[key] == nil then
			db[key] = value
		end
	end
	db.threshold = math.max(10, math.min(80, tonumber(db.threshold) or 40))
end

local function IsSecret(value)
	return value ~= nil and issecretvalue(value)
end

local function PlainNumber(value)
	if value == nil or IsSecret(value) then
		return nil
	end
	if type(value) ~= "number" then
		return nil
	end
	return value
end

local function RequestItems()
	for _, itemID in ipairs(POTIONS) do
		C_Item.RequestLoadItemDataByID(itemID)
	end
	for _, itemID in ipairs(STONES) do
		C_Item.RequestLoadItemDataByID(itemID)
	end
end

local function SpellFor(itemID)
	local cached = spellByItem[itemID]
	if cached ~= nil then
		return cached or nil
	end
	if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(itemID) then
		C_Item.RequestLoadItemDataByID(itemID)
		return nil
	end
	local ok, _, spellID = pcall(C_Item.GetItemSpell, itemID)
	if not ok or not spellID or IsSecret(spellID) then
		return nil
	end
	spellByItem[itemID] = spellID
	return spellID
end

local function NoteKnownSpells()
	wipe(potionSpells)
	wipe(stoneSpells)
	for _, itemID in ipairs(POTIONS) do
		local spellID = SpellFor(itemID)
		if spellID then
			potionSpells[spellID] = true
		end
	end
	for _, itemID in ipairs(STONES) do
		local spellID = SpellFor(itemID)
		if spellID then
			stoneSpells[spellID] = true
		end
	end
end

local function EachBag(fn)
	fn(BACKPACK_CONTAINER or 0)
	for bag = 1, NUM_BAG_SLOTS or 4 do
		fn(bag)
	end
	if Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag then
		fn(Enum.BagIndex.ReagentBag)
	end
end

local function RescanBags()
	wipe(bagCounts)
	NoteKnownSpells()

	local seenPotion = {}
	local seenStone = {}
	for _, itemID in ipairs(POTIONS) do
		seenPotion[itemID] = true
	end
	for _, itemID in ipairs(STONES) do
		seenStone[itemID] = true
	end
	wipe(extraPotions)
	wipe(extraStones)

	EachBag(function(bag)
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not IsSecret(info.itemID) then
				local count = PlainNumber(info.stackCount) or 1
				bagCounts[info.itemID] = (bagCounts[info.itemID] or 0) + count
			end
		end
	end)

	for itemID in pairs(bagCounts) do
		local spellID = SpellFor(itemID)
		if spellID and potionSpells[spellID] and not seenPotion[itemID] then
			seenPotion[itemID] = true
			extraPotions[#extraPotions + 1] = itemID
		elseif spellID and stoneSpells[spellID] and not seenStone[itemID] then
			seenStone[itemID] = true
			extraStones[#extraStones + 1] = itemID
		end
	end
end

local function IsListed(itemID)
	for _, id in ipairs(POTIONS) do
		if id == itemID then
			return true
		end
	end
	for _, id in ipairs(STONES) do
		if id == itemID then
			return true
		end
	end
	return bagCounts[itemID] ~= nil
end

local function QueueScan()
	if scanTimer then
		return
	end
	scanTimer = C_Timer.NewTimer(0.25, function()
		scanTimer = nil
		RescanBags()
	end)
end

local function CountOf(itemID)
	local scanned = bagCounts[itemID]
	if scanned and scanned > 0 then
		return scanned
	end
	local ok, count = pcall(C_Item.GetItemCount, itemID)
	count = ok and PlainNumber(count) or nil
	return count or 0
end

local function ItemName(itemID)
	local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
	if name and name ~= "" then
		return name
	end
	return nil
end

local function ItemIcon(itemID)
	local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
	if icon then
		return icon
	end
	return 135230
end

local function ChargeInfo(spellID)
	if not spellID or not C_Spell.GetSpellCharges then
		return nil
	end
	local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
	if ok then
		return info
	end
	return nil
end

local function CooldownInfo(spellID)
	if not spellID or not C_Spell.GetSpellCooldown then
		return nil
	end
	local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
	if ok then
		return info
	end
	return nil
end

-- isActive stays readable in combat. A real potion cooldown and the global
-- cooldown both set it, so a short or GCD-only timer still counts as ready.
-- Charge counts can be secret; a recharging healthstone stays visible.
local function CanPress(spellID)
	local charges = ChargeInfo(spellID)
	if charges then
		local current = PlainNumber(charges.currentCharges)
		if current ~= nil then
			return current > 0, true
		end
		return true, true
	end

	local info = CooldownInfo(spellID)
	if not info or type(info.isActive) ~= "boolean" or IsSecret(info.isActive) then
		return true, false
	end
	if not info.isActive then
		return true, false
	end

	local duration = PlainNumber(info.duration)
	if duration ~= nil then
		return duration <= 2.5, false
	end
	if type(info.isOnGCD) == "boolean" and not IsSecret(info.isOnGCD) and info.isOnGCD then
		return true, false
	end
	return false, false
end

-- Only used to correct a false "on cooldown". A false result is ignored because
-- the global cooldown also makes an item look unusable.
local function ItemLooksUsable(itemID)
	if not C_Item.IsUsableItem then
		return nil
	end
	local ok, usable = pcall(C_Item.IsUsableItem, itemID)
	if ok and type(usable) == "boolean" and not IsSecret(usable) then
		return usable
	end
	return nil
end

local function ListWithExtras(staticList, extras)
	local list = {}
	local seen = {}
	for _, itemID in ipairs(staticList) do
		list[#list + 1] = itemID
		seen[itemID] = true
	end
	for _, itemID in ipairs(extras) do
		if not seen[itemID] then
			list[#list + 1] = itemID
			seen[itemID] = true
		end
	end
	return list
end

local function Pick(list)
	local ready, waiting
	for _, itemID in ipairs(list) do
		if CountOf(itemID) > 0 then
			local spellID = SpellFor(itemID)
			local canPress, isCharge = CanPress(spellID)
			if not canPress and ItemLooksUsable(itemID) then
				canPress = true
			end
			local entry = {
				itemID = itemID,
				count = CountOf(itemID),
				spellID = spellID,
				isCharge = isCharge,
				name = ItemName(itemID),
				icon = ItemIcon(itemID),
			}
			if canPress then
				if not ready then
					ready = entry
				end
			elseif not waiting then
				waiting = entry
			end
		end
	end
	return ready, waiting
end

local function BuildCurves()
	local threshold = (db.threshold or 40) / 100
	threshold = math.max(0.05, math.min(0.95, threshold))

	local curve = C_CurveUtil.CreateColorCurve()
	curve:SetType(Enum.LuaCurveType.Step)
	local shown = CreateColor(1, 1, 1, 1)
	local hidden = CreateColor(1, 1, 1, 0)
	curve:AddPoint(0, shown)
	curve:AddPoint(threshold, hidden)
	curve:AddPoint(1, hidden)
	healthCurve = curve

	local percent = C_CurveUtil.CreateCurve()
	percent:SetType(Enum.LuaCurveType.Step)
	for i = 0, 100 do
		percent:AddPoint(i / 100, i)
	end
	percentCurve = percent
end

local function ApplySwipe(cooldown, entry)
	if not entry or not entry.spellID then
		cooldown:Clear()
		return
	end
	local duration
	if entry.isCharge and C_Spell.GetSpellChargeDuration then
		local ok, value = pcall(C_Spell.GetSpellChargeDuration, entry.spellID)
		if ok then
			duration = value
		end
	end
	if not duration and C_Spell.GetSpellCooldownDuration then
		local ok, value = pcall(C_Spell.GetSpellCooldownDuration, entry.spellID)
		if ok then
			duration = value
		end
	end
	if duration then
		cooldown:SetCooldownFromDurationObject(duration)
	else
		cooldown:Clear()
	end
end

-- Returns remaining cooldown text like "42s" or "1:05", or nil when it can't be read.
local function CooldownText(entry)
	if not entry or not entry.spellID then
		return nil
	end
	local remaining
	local info = CooldownInfo(entry.spellID)
	if info then
		local start, duration = PlainNumber(info.startTime), PlainNumber(info.duration)
		if start and duration and duration > 0 then
			remaining = start + duration - GetTime()
		end
	end
	if not remaining and C_Spell.GetSpellCooldownDuration then
		local ok, duration = pcall(C_Spell.GetSpellCooldownDuration, entry.spellID)
		if ok and duration and duration.GetRemainingDuration then
			local okRem, value = pcall(duration.GetRemainingDuration, duration)
			remaining = okRem and PlainNumber(value) or nil
		end
	end
	if not remaining or remaining <= 0 then
		return nil
	end
	remaining = math.ceil(remaining)
	if remaining >= 60 then
		return string.format("%d:%02d", math.floor(remaining / 60), remaining % 60)
	end
	return remaining .. "s"
end

local function ShowSlot(slot, entry, desaturate)
	slot.icon:SetTexture(entry.icon or 135230)
	slot.icon:SetDesaturated(desaturate and true or false)
	local charges = entry.spellID and ChargeInfo(entry.spellID)
	local current = charges and PlainNumber(charges.currentCharges)
	local maxCharges = charges and PlainNumber(charges.maxCharges)
	if current and maxCharges and maxCharges > 1 then
		slot.count:SetText(tostring(current))
	elseif entry.count > 1 then
		slot.count:SetText(tostring(entry.count))
	else
		slot.count:SetText("")
	end
	ApplySwipe(slot.cooldown, entry)
	slot:Show()
end

local function Layout(anchor)
	frame.headline:ClearAllPoints()
	frame.headline:SetPoint("LEFT", anchor, "RIGHT", 14, 16)
	frame.sub:ClearAllPoints()
	frame.sub:SetPoint("TOPLEFT", frame.headline, "BOTTOMLEFT", 0, -4)
	frame.percent:ClearAllPoints()
	frame.percent:SetPoint("TOPLEFT", frame.sub, "BOTTOMLEFT", 0, -2)
end

local function UpdatePercent()
	if not percentCurve then
		frame.percent:SetText("")
		return
	end
	-- Step curve emits a whole number. %s is allowed when that number is secret.
	frame.percent:SetText(string.format("%s%%", UnitHealthPercent("player", true, percentCurve)))
end

local function PrettyKey(key)
	if not key or key == "" or IsSecret(key) then
		return nil
	end
	if GetBindingText then
		local text = GetBindingText(key, "KEY_", true)
		if text and text ~= "" and not IsSecret(text) then
			return text
		end
	end
	key = tostring(key)
	key = key:gsub("SHIFT%-", "S-")
	key = key:gsub("CTRL%-", "C-")
	key = key:gsub("ALT%-", "A-")
	key = key:gsub("BUTTON(%d)", "M%1")
	key = key:gsub("NUMPAD", "N")
	return key
end

local function HotkeyText(button)
	if not button then
		return nil
	end
	local font = button.HotKey or button.hotkey
	if not font and button.GetName then
		local name = button:GetName()
		font = name and _G[name .. "HotKey"]
	end
	if not font or not font.GetText then
		return nil
	end
	local text = font:GetText()
	if not text or IsSecret(text) then
		return nil
	end
	text = tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = strtrim(text)
	if text == "" or text == RANGE_INDICATOR then
		return nil
	end
	return text
end

local function ButtonAction(button)
	if not button then
		return nil
	end
	if type(button.action) == "number" and not IsSecret(button.action) then
		return button.action
	end
	if button.GetAction then
		local ok, slot = pcall(button.GetAction, button)
		if ok and type(slot) == "number" and not IsSecret(slot) then
			return slot
		end
	end
	return nil
end

local function MacroUsesItem(macroID, itemIDs)
	if type(macroID) ~= "number" or IsSecret(macroID) then
		return false
	end
	local body
	if GetMacroBody then
		body = GetMacroBody(macroID)
	end
	if type(body) ~= "string" and GetMacroInfo then
		body = select(3, GetMacroInfo(macroID))
	end
	if type(body) ~= "string" then
		return false
	end
	local lower = body:lower()
	for _, itemID in ipairs(itemIDs) do
		if lower:find("item:" .. itemID, 1, true) then
			return true
		end
		local name = ItemName(itemID)
		if name and name ~= "" and lower:find(name:lower(), 1, true) then
			return true
		end
	end
	return false
end

local function ActionMatches(slot, itemIDs, spellIDs)
	if not slot or not GetActionInfo then
		return false
	end
	local ok, actionType, id = pcall(GetActionInfo, slot)
	if not ok or not actionType or IsSecret(actionType) or IsSecret(id) then
		return false
	end
	if actionType == "item" then
		for _, itemID in ipairs(itemIDs) do
			if id == itemID then
				return true
			end
		end
	elseif actionType == "spell" then
		for _, spellID in ipairs(spellIDs) do
			if id == spellID then
				return true
			end
		end
	elseif actionType == "macro" then
		return MacroUsesItem(id, itemIDs)
	end
	return false
end

local BAR_BUTTONS = {
	{ "ActionButton", "ACTIONBUTTON%d" },
	{ "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON%d" },
	{ "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON%d" },
	{ "MultiBarRightButton", "MULTIACTIONBAR3BUTTON%d" },
	{ "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON%d" },
	{ "MultiBar5Button", "MULTIACTIONBAR5BUTTON%d" },
	{ "MultiBar6Button", "MULTIACTIONBAR6BUTTON%d" },
	{ "MultiBar7Button", "MULTIACTIONBAR7BUTTON%d" },
	{ "ElvUI_Bar1Button", "ELVUIBAR1BUTTON%d" },
	{ "ElvUI_Bar2Button", "ELVUIBAR2BUTTON%d" },
	{ "ElvUI_Bar3Button", "ELVUIBAR3BUTTON%d" },
	{ "ElvUI_Bar4Button", "ELVUIBAR4BUTTON%d" },
	{ "ElvUI_Bar5Button", "ELVUIBAR5BUTTON%d" },
	{ "ElvUI_Bar6Button", "ELVUIBAR6BUTTON%d" },
	{ "DominosActionButton", "ACTIONBUTTON%d" },
	{ "BT4Button", "CLICK BT4Button%d:LeftButton" },
}

local function FindKeybind(itemIDs)
	local spellIDs = {}
	for _, itemID in ipairs(itemIDs) do
		local spellID = SpellFor(itemID)
		if spellID then
			spellIDs[#spellIDs + 1] = spellID
		end
	end

	for _, bar in ipairs(BAR_BUTTONS) do
		for i = 1, 12 do
			local button = _G[bar[1] .. i]
			local slot = ButtonAction(button)
			if slot and ActionMatches(slot, itemIDs, spellIDs) then
				local hot = HotkeyText(button)
				if hot then
					return hot
				end
				local key = PrettyKey(GetBindingKey(bar[2]:format(i)))
				if key then
					return key
				end
			end
		end
	end
	return nil
end

local function OwnsAny(itemIDs)
	for _, itemID in ipairs(itemIDs) do
		if CountOf(itemID) > 0 then
			return true
		end
	end
	return false
end

local function ShowKeybinds()
	local stoneIDs = ListWithExtras(STONES, extraStones)
	local potIDs = ListWithExtras(POTIONS, extraPotions)
	local stoneKey = OwnsAny(stoneIDs) and FindKeybind(stoneIDs) or nil
	local potKey = OwnsAny(potIDs) and FindKeybind(potIDs) or nil

	if stoneKey then
		frame.keybind:SetText(stoneKey)
		if potKey and potKey ~= stoneKey then
			frame.keyName:SetText("Pot " .. potKey)
		else
			frame.keyName:SetText("Healthstone")
		end
	elseif potKey then
		frame.keybind:SetText(potKey)
		frame.keyName:SetText("Health Pot")
	else
		frame.keybind:SetText("")
		frame.keyName:SetText("")
	end
end

local function ReadableFraction()
	local pct = UnitHealthPercent("player", true)
	pct = PlainNumber(pct)
	if not pct then
		return nil
	end
	if pct > 1.001 then
		pct = pct / 100
	end
	return pct
end

local function InCombat()
	return UnitAffectingCombat("player") or InCombatLockdown()
end

local RefreshPingClick

-- Protected frame: scale can't change in combat; the ticker re-applies it afterwards.
local function ApplyScale()
	if frame and not InCombatLockdown() then
		local scale = (db.scale or 100) / 100
		if frame:GetScale() ~= scale then
			frame:SetScale(scale)
		end
	end
end

local function ApplyLock()
	frame:SetMovable(not db.locked)
	frame:EnableMouse(not db.locked or forceVisible)
	if frame.SetMouseClickEnabled then
		frame:SetMouseClickEnabled(not db.locked or forceVisible)
		frame:SetMouseMotionEnabled(not db.locked or forceVisible)
	end
	frame.hint:SetShown(not db.locked and not frame.compact)
	if frame.lockButton and frame.lockButton.label then
		frame.lockButton.label:SetText(db.locked and "Unlock" or "Lock")
	end
	if db.locked then
		if not frame.compact and frame.pulse and not frame.pulse:IsPlaying() then
			frame.pulse:Play()
		end
	else
		if frame.pulse then
			frame.pulse:Stop()
		end
		ApplyScale()
	end
	if RefreshPingClick then
		RefreshPingClick()
	end
end

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or 160)
end

RefreshPingClick = function()
	if not frame or not frame.pingButton then
		return
	end
	-- Secure ping only on the small bar, and only while locked so drag still works.
	-- With pingBanner the button stays clickable on every layout, so nothing has to change in combat.
	local pingClick = (frame.compact or db.pingBanner) and db.locked and not forceVisible
	-- Secure button: mouse state can't change in combat; the ticker retries after combat.
	if not InCombatLockdown() then
		frame.pingButton:EnableMouse(pingClick)
		if frame.pingButton.SetMouseClickEnabled then
			frame.pingButton:SetMouseClickEnabled(pingClick)
			frame.pingButton:SetMouseMotionEnabled(pingClick)
		end
	end
	if frame.lockButton then
		local lockClick = forceVisible or not db.locked or not frame.compact
		-- In compact mode the whole bar is the ping; unlock from the minimap.
		frame.lockButton:SetShown(not frame.compact)
		frame.lockButton:EnableMouse(lockClick)
		if frame.lockButton.SetMouseClickEnabled then
			frame.lockButton:SetMouseClickEnabled(lockClick)
			frame.lockButton:SetMouseMotionEnabled(lockClick)
		end
	end
end

local function RefreshLockButton(gated)
	local canUse = forceVisible or not db.locked or gated
	if not InCombatLockdown() then
		frame:EnableMouse(canUse and (not db.locked or forceVisible))
		if frame.SetMouseClickEnabled then
			frame:SetMouseClickEnabled(canUse and (not db.locked or forceVisible))
			frame:SetMouseMotionEnabled(canUse and (not db.locked or forceVisible))
		end
	end
	RefreshPingClick()
end

local function SetCompact(compact)
	ApplyScale()
	frame.compact = compact and true or false
	-- The frame is protected (it parents the secure ping button), so it can't be resized in combat.
	-- Update runs on a ticker, so the size catches up on the first tick after combat ends.
	local canResize = not InCombatLockdown()
	local simple = db.simple and not compact
	frame.simple = simple and true or false
	if compact then
		if canResize then
			frame:SetSize(118, 28)
		end
		frame.pulse:Stop()
		if canResize then
			ApplyScale()
		end
		frame:SetBackdropColor(0.06, 0.0, 0.0, 0.82)
		frame:SetBackdropBorderColor(0.85, 0.2, 0.1, 0.9)
	else
		if canResize then
			frame:SetSize(700, simple and 64 or 118)
		end
		frame:SetBackdropColor(0.08, 0.0, 0.0, 0.88)
		frame:SetBackdropBorderColor(0.95, 0.12, 0.08, 1)
		if db.locked and not frame.pulse:IsPlaying() then
			frame.pulse:Play()
		end
	end
	frame.headline:SetShown(not compact)
	frame.sub:SetShown(not compact and not simple)
	frame.keybind:SetShown(not compact and not simple)
	frame.keyName:SetShown(not compact and not simple)
	if simple then
		frame.headline:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
		frame.headline:SetWidth(680)
		frame.headline:SetJustifyH("CENTER")
		frame.headline:ClearAllPoints()
		frame.headline:SetPoint("CENTER", frame, "CENTER", 0, 0)
	else
		frame.headline:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
		frame.headline:SetWidth(340)
		frame.headline:SetJustifyH("LEFT")
	end
	frame.pingLabel:SetShown(compact)
	frame.hint:SetShown(not compact and not simple and not db.locked)
	frame.percent:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
	if simple then
		frame.slot1:Hide()
		frame.slot2:Hide()
		frame.percent:SetText("")
		frame.percent:Hide()
	elseif not compact then
		frame.percent:Show()
	end
	if compact then
		frame.percent:Show()
		frame.slot1:Hide()
		frame.slot2:Hide()
		frame.percent:ClearAllPoints()
		frame.percent:SetJustifyH("LEFT")
		frame.percent:SetPoint("LEFT", 8, 0)
		frame.pingLabel:ClearAllPoints()
		frame.pingLabel:SetPoint("RIGHT", -8, 0)
	else
		frame.percent:SetJustifyH("LEFT")
	end
	RefreshPingClick()
end

local function Update()
	local stoneReady, stoneWait = Pick(ListWithExtras(STONES, extraStones))
	local potReady, potWait = Pick(ListWithExtras(POTIONS, extraPotions))

	local hasReady = stoneReady ~= nil or potReady ~= nil
	local simpleWait = db.simple and not hasReady and not forceVisible and (stoneWait ~= nil or potWait ~= nil)

	if forceVisible and not hasReady then
		SetCompact(true)
		frame.sub:SetText("")
		pcall(UpdatePercent)
		frame:SetAlpha(1)
		RefreshLockButton(true)
		return
	end

	local left = stoneReady
	local right = potReady
	if not left and right then
		left = right
		right = nil
	end

	SetCompact(not hasReady and not simpleWait)

	local simple = frame.simple
	if hasReady and left and not simple then
		ShowSlot(frame.slot1, left, false)
		Layout(frame.slot1)
	else
		frame.slot1:Hide()
	end

	if hasReady and right and not simple then
		ShowSlot(frame.slot2, right, false)
		frame.slot2:ClearAllPoints()
		frame.slot2:SetPoint("LEFT", frame.slot1, "RIGHT", 8, 0)
		Layout(frame.slot2)
	else
		frame.slot2:Hide()
	end

	if stoneReady and potReady then
		frame.headline:SetText("USE STONE + POT")
	elseif stoneReady then
		frame.headline:SetText("USE HEALTHSTONE")
	elseif potReady then
		frame.headline:SetText("USE HEALTH POT")
	end

	local names = {}
	if hasReady and left and left.name then
		names[#names + 1] = left.name
	end
	if hasReady and right and right.name then
		names[#names + 1] = right.name
	end
	frame.sub:SetText(table.concat(names, "  +  "))
	pcall(UpdatePercent)
	if hasReady then
		pcall(ShowKeybinds)
	else
		frame.keybind:SetText("")
		frame.keyName:SetText("")
	end

	if simple and hasReady then
		local simpleNames = {}
		if stoneReady then
			simpleNames[#simpleNames + 1] = "HEALTHSTONE"
		end
		if potReady then
			simpleNames[#simpleNames + 1] = "HEALTHPOT"
		end
		local text = "USE " .. table.concat(simpleNames, " + ") .. " NOW"
		local key = frame.keybind:GetText()
		if key and key ~= "" then
			text = text .. " [" .. key .. "]"
		end
		frame.headline:SetText(text)
	elseif simpleWait then
		local text = "NO HEALTH ITEM AVAILABLE"
		local stoneCd = CooldownText(stoneWait)
		local potCd = CooldownText(potWait)
		if stoneCd and potCd then
			text = text .. " [HS " .. stoneCd .. " / POT " .. potCd .. "]"
		elseif stoneCd or potCd then
			text = text .. " [" .. (stoneCd or potCd) .. "]"
		end
		frame.headline:SetText(text)
	end

	local dead = UnitIsDeadOrGhost("player")
	if IsSecret(dead) then
		dead = false
	end
	local gated = not dead and (not db.onlyInCombat or InCombat())
	if forceVisible then
		frame:SetAlpha(1)
		RefreshLockButton(true)
		return
	end
	if not gated then
		frame:SetAlpha(0)
		RefreshLockButton(false)
		return
	end

	local applied = false
	if healthCurve then
		applied = pcall(function()
			local color = UnitHealthPercent("player", true, healthCurve)
			frame:SetAlpha(select(4, color:GetRGBA()))
		end)
	end
	if not applied then
		local pct = ReadableFraction()
		frame:SetAlpha((pct and pct < (db.threshold / 100)) and 1 or 0)
	end

	RefreshLockButton(true)
end

local function SafeUpdate()
	local ok, err = pcall(Update)
	if not ok and not reportedError then
		reportedError = true
		Say("error: " .. tostring(err))
	end
end

local function ToggleLock()
	db.locked = not db.locked
	forceVisible = not db.locked
	ApplyLock()
	SafeUpdate()
	Say(db.locked and "locked." or "unlocked. Drag the banner, then click Lock.")
end

local function CreateIconSlot(parent)
	local slot = CreateFrame("Frame", nil, parent)
	slot:SetSize(64, 64)
	slot.bg = slot:CreateTexture(nil, "BACKGROUND")
	slot.bg:SetColorTexture(0, 0, 0, 1)
	slot.bg:SetPoint("TOPLEFT", -2, 2)
	slot.bg:SetPoint("BOTTOMRIGHT", 2, -2)
	slot.icon = slot:CreateTexture(nil, "ARTWORK")
	slot.icon:SetAllPoints()
	slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	slot.cooldown = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
	slot.cooldown:SetAllPoints()
	slot.cooldown:SetDrawEdge(false)
	slot.count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
	slot.count:SetPoint("BOTTOMRIGHT", -1, 2)
	slot.count:SetJustifyH("RIGHT")
	slot:EnableMouse(false)
	slot.cooldown:EnableMouse(false)
	if slot.cooldown.SetMouseClickEnabled then
		slot.cooldown:SetMouseClickEnabled(false)
		slot.cooldown:SetMouseMotionEnabled(false)
	end
	slot:Hide()
	return slot
end

local function CreateAlert()
	frame = CreateFrame("Frame", "XenHealthItemsFrame", UIParent, "BackdropTemplate")
	frame:SetSize(700, 118)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 2,
	})
	frame:SetBackdropColor(0.08, 0.0, 0.0, 0.88)
	frame:SetBackdropBorderColor(0.95, 0.12, 0.08, 1)
	frame:SetAlpha(0)
	ApplyPosition()

	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not db.locked then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		if IsSecret(x) or IsSecret(y) then
			return
		end
		db.point = point
		db.relativePoint = relPoint
		db.x = x
		db.y = y
	end)

	frame.slot1 = CreateIconSlot(frame)
	frame.slot1:SetPoint("LEFT", 16, 4)
	frame.slot2 = CreateIconSlot(frame)

	frame.headline = frame:CreateFontString(nil, "OVERLAY")
	frame.headline:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
	frame.headline:SetTextColor(1, 0.82, 0.15)
	frame.headline:SetJustifyH("LEFT")
	frame.headline:SetWidth(340)
	frame.headline:SetText("USE HEALTH POT")

	frame.sub = frame:CreateFontString(nil, "OVERLAY")
	frame.sub:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
	frame.sub:SetTextColor(1, 0.85, 0.8)
	frame.sub:SetJustifyH("LEFT")
	frame.sub:SetWidth(340)

	frame.percent = frame:CreateFontString(nil, "OVERLAY")
	frame.percent:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
	frame.percent:SetTextColor(1, 1, 1)
	frame.percent:SetJustifyH("LEFT")
	frame.percent:SetDrawLayer("OVERLAY", 7)

	frame.pingLabel = frame:CreateFontString(nil, "OVERLAY")
	frame.pingLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
	frame.pingLabel:SetTextColor(1, 0.82, 0.55)
	frame.pingLabel:SetText("Ping")
	frame.pingLabel:SetDrawLayer("OVERLAY", 7)
	frame.pingLabel:Hide()

	frame.pingButton = CreateFrame("Button", "XenHealthItemsSecure", frame, "SecureActionButtonTemplate")
	frame.pingButton:SetAllPoints()
	frame.pingButton:SetFrameLevel(frame:GetFrameLevel() + 2)
	frame.pingButton:RegisterForClicks("LeftButtonDown")
	frame.pingButton:SetAttribute("type", "macro")
	frame.pingButton:SetAttribute("macrotext", "/ping [@player] Warning")
	if frame.pingButton.SetPropagateMouseClicks then
		frame.pingButton:SetPropagateMouseClicks(false)
	end
	frame.pingButton:EnableMouse(false)
	frame.pingButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Click to ping your health")
		GameTooltip:AddLine("Warning ping on yourself", 1, 1, 1)
		GameTooltip:Show()
	end)
	frame.pingButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	frame.keybind = frame:CreateFontString(nil, "OVERLAY")
	frame.keybind:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
	frame.keybind:SetTextColor(1, 0.95, 0.6)
	frame.keybind:SetJustifyH("RIGHT")
	frame.keybind:SetPoint("RIGHT", -92, 10)

	frame.keyName = frame:CreateFontString(nil, "OVERLAY")
	frame.keyName:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	frame.keyName:SetTextColor(1, 0.85, 0.75)
	frame.keyName:SetJustifyH("RIGHT")
	frame.keyName:SetPoint("TOPRIGHT", frame.keybind, "BOTTOMRIGHT", 0, -2)

	frame.lockButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
	frame.lockButton:SetSize(70, 22)
	frame.lockButton:SetPoint("TOPRIGHT", -8, -8)
	frame.lockButton:SetFrameLevel(frame:GetFrameLevel() + 5)
	frame.lockButton:EnableMouse(true)
	frame.lockButton:RegisterForClicks("LeftButtonUp")
	frame.lockButton:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame.lockButton:SetBackdropColor(0.25, 0.02, 0.02, 0.95)
	frame.lockButton:SetBackdropBorderColor(1, 0.45, 0.2, 1)
	frame.lockButton.label = frame.lockButton:CreateFontString(nil, "OVERLAY")
	frame.lockButton.label:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	frame.lockButton.label:SetPoint("CENTER")
	frame.lockButton.label:SetText("Unlock")
	frame.lockButton:SetScript("OnClick", function()
		ToggleLock()
	end)
	frame.lockButton:SetScript("OnEnter", function(self)
		self:SetBackdropColor(0.45, 0.05, 0.02, 1)
	end)
	frame.lockButton:SetScript("OnLeave", function(self)
		self:SetBackdropColor(0.25, 0.02, 0.02, 0.95)
	end)

	frame.hint = frame:CreateFontString(nil, "OVERLAY")
	frame.hint:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	frame.hint:SetPoint("BOTTOM", 0, 6)
	frame.hint:SetText("Drag, then click Lock.")
	frame.hint:Hide()

	frame.pulse = frame:CreateAnimationGroup()
	frame.pulse:SetLooping("BOUNCE")
	-- Slowly fade the headline between gold and orange-red; the frame itself never moves.
	local fade = frame.pulse:CreateAnimation("Animation")
	fade:SetDuration(1.4)
	fade:SetSmoothing("IN_OUT")
	fade:SetScript("OnUpdate", function(self)
		local t = self:GetSmoothProgress()
		frame.headline:SetTextColor(1, 0.82 - 0.5 * t, 0.15 - 0.05 * t)
	end)
	frame.pulse:SetScript("OnStop", function()
		frame.headline:SetTextColor(1, 0.82, 0.15)
	end)

	ApplyLock()
end

local function RefreshOptions(panel)
	if not panel or not panel.controls then
		return
	end
	for _, control in ipairs(panel.controls) do
		if control.Refresh then
			control:Refresh()
		end
	end
end

local function MakeCheck(parent, name, label, getter, setter)
	local box = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	local text = box.Text or _G[name .. "Text"]
	if text then
		text:SetText(label)
	end
	box:SetScript("OnClick", function(self)
		setter(self:GetChecked() and true or false)
	end)
	box.Refresh = function(self)
		self:SetChecked(getter())
	end
	return box
end

local function MakeSlider(parent, name, minV, maxV, getter, setter, formatter)
	local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	slider:SetWidth(280)
	slider:SetMinMaxValues(minV, maxV)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	local low = slider.Low or _G[name .. "Low"]
	local high = slider.High or _G[name .. "High"]
	local text = slider.Text or _G[name .. "Text"]
	if low then low:SetText(tostring(minV)) end
	if high then high:SetText(tostring(maxV)) end
	slider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		setter(value)
		local label = self.Text or _G[name .. "Text"]
		if label then
			label:SetText(formatter(value))
		end
	end)
	slider.Refresh = function(self)
		local value = getter()
		self:SetValue(value)
		local label = text or self.Text or _G[name .. "Text"]
		if label then
			label:SetText(formatter(value))
		end
	end
	return slider
end

local function CreateOptions()
	local panel = CreateFrame("Frame")
	panel.name = "Xen Health Items"
	panel.controls = {}

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Xen Health Items")

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	about:SetWidth(520)
	about:SetJustifyH("LEFT")
	about:SetText("Big banner when a pot or healthstone is ready under your threshold. Small bar when they are missing or on cooldown. Click the small bar to Warning-ping yourself. Minimap: left-click lock, right-click options.")

	local threshold = MakeSlider(panel, "XenHealthItemsThreshold", 10, 80, function()
		return db.threshold
	end, function(value)
		db.threshold = value
		BuildCurves()
	end, function(value)
		return "Warn below " .. value .. "%"
	end)
	threshold:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -28)
	panel.controls[#panel.controls + 1] = threshold

	local simpleBox = MakeCheck(panel, "XenHealthItemsSimple", "Simple banner: just \"USE <item> NOW [key]\" (applies out of combat)", function()
		return db.simple
	end, function(value)
		db.simple = value
	end)
	simpleBox:SetPoint("TOPLEFT", threshold, "BOTTOMLEFT", 0, -24)
	panel.controls[#panel.controls + 1] = simpleBox

	local pingBox = MakeCheck(panel, "XenHealthItemsPingBanner", "Click the banner to Warning-ping your health (banner area then blocks clicks, even while hidden)", function()
		return db.pingBanner
	end, function(value)
		db.pingBanner = value
		if RefreshPingClick then
			RefreshPingClick()
		end
	end)
	pingBox:SetPoint("TOPLEFT", simpleBox, "BOTTOMLEFT", 0, -8)
	panel.controls[#panel.controls + 1] = pingBox

	local combat = MakeCheck(panel, "XenHealthItemsCombat", "Only in combat", function()
		return db.onlyInCombat
	end, function(value)
		db.onlyInCombat = value
	end)
	combat:SetPoint("TOPLEFT", pingBox, "BOTTOMLEFT", 0, -8)

	local scaleSlider = MakeSlider(panel, "XenHealthItemsScale", 50, 200, function()
		return db.scale or 100
	end, function(value)
		db.scale = value
		ApplyScale()
	end, function(value)
		return "Alert size " .. value .. "%"
	end)
	scaleSlider:SetPoint("TOPLEFT", combat, "BOTTOMLEFT", 4, -32)
	panel.controls[#panel.controls + 1] = scaleSlider
	panel.controls[#panel.controls + 1] = combat

	local pingNow = CreateFrame("Button", "XenHealthItemsPingNow", panel, "SecureActionButtonTemplate,UIPanelButtonTemplate")
	pingNow:SetSize(180, 24)
	pingNow:SetText("Ping my health now")
	-- Protected frames can't anchor to regions or sibling widgets here, so anchor to the panel itself.
	pingNow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -24, -16)
	pingNow:RegisterForClicks("AnyUp", "AnyDown")
	pingNow:SetAttribute("type", "macro")
	pingNow:SetAttribute("macrotext", "/ping [@player] Warning")

	panel:SetScript("OnShow", function(self)
		RefreshOptions(self)
	end)
	RefreshOptions(panel)

	settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
	Settings.RegisterAddOnCategory(settingsCategory)
end

local function OpenOptions()
	if InCombatLockdown() then
		Say("options can't be opened in combat.")
		return
	end
	if settingsCategory and Settings.OpenToCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	end
end

local MINIMAP_SHAPES = {
	["ROUND"] = { true, true, true, true },
	["SQUARE"] = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local minimapButton

local function UpdateMinimapButton()
	if not minimapButton or not Minimap then
		return
	end
	local angle = math.rad(db.minimapAngle or 225)
	local x, y = math.cos(angle), math.sin(angle)
	local q = 1
	if x < 0 then
		q = q + 1
	end
	if y > 0 then
		q = q + 2
	end
	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	local quad = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND
	local w = (Minimap:GetWidth() / 2) + 5
	local h = (Minimap:GetHeight() / 2) + 5
	if quad[q] then
		x, y = x * w, y * h
	else
		local diagW = math.sqrt(2 * w * w) - 10
		local diagH = math.sqrt(2 * h * h) - 10
		x = math.max(-w, math.min(x * diagW, w))
		y = math.max(-h, math.min(y * diagH, h))
	end
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
	if minimapButton or not Minimap then
		return
	end
	local button = CreateFrame("Button", "XenHealthItemsMinimapButton", Minimap)
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER")
	icon:SetTexture(135230)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(54, 54)
	border:SetPoint("CENTER", 0, 0)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Xen Health Items")
		GameTooltip:AddLine(db.locked and "Left-click: unlock" or "Left-click: lock", 1, 1, 1)
		GameTooltip:AddLine("Right-click: options", 1, 1, 1)
		GameTooltip:AddLine("Drag to move", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:SetScript("OnUpdate", function(self)
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
			UpdateMinimapButton()
		end)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnClick", function(self, click)
		if self.dragging then
			self.dragging = false
			return
		end
		if click == "RightButton" then
			OpenOptions()
		else
			ToggleLock()
		end
	end)

	minimapButton = button
	UpdateMinimapButton()
end

local function Help()
	Say("minimap left-click locks the banner, right-click opens options. /hpp test previews the banner.")
end

local function StartTest()
	forceVisible = true
	if testTimer then
		testTimer:Cancel()
	end
	testTimer = C_Timer.NewTimer(6, function()
		testTimer = nil
		if db.locked then
			forceVisible = false
		end
	end)
	Say("preview for 6 seconds.")
	SafeUpdate()
end

SLASH_XENHEALTHITEMS1 = "/hpp"
SLASH_XENHEALTHITEMS2 = "/healthpot"
SLASH_XENHEALTHITEMS3 = "/xhi"
SlashCmdList.XENHEALTHITEMS = function(msg)
	if not db or not frame then
		return
	end
	msg = strtrim(msg or ""):lower()
	local percent = tonumber(msg:match("^percent%s+(%d+)") or msg:match("^threshold%s+(%d+)") or msg:match("^hp%s+(%d+)"))

	if msg == "" or msg == "toggle" then
		ToggleLock()
	elseif msg == "unlock" or msg == "move" then
		db.locked = false
		forceVisible = true
		ApplyLock()
		Say("unlocked. Drag the banner, then /hpp lock.")
	elseif msg == "lock" then
		db.locked = true
		forceVisible = false
		ApplyLock()
		Say("locked.")
	elseif msg == "test" or msg == "preview" then
		StartTest()
	elseif msg == "combat" then
		db.onlyInCombat = not db.onlyInCombat
		Say(db.onlyInCombat and "combat only." or "also out of combat.")
	elseif msg == "cooldown" then
		db.showOnCooldown = not db.showOnCooldown
		Say(db.showOnCooldown and "showing while on cooldown." or "hidden while on cooldown.")
	elseif percent then
		db.threshold = math.max(10, math.min(80, percent))
		BuildCurves()
		Say("warn below " .. db.threshold .. "%.")
	elseif msg == "options" or msg == "config" then
		OpenOptions()
	else
		Help()
	end
	SafeUpdate()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON and arg1 ~= "XenHealthItems" then
			return
		end
		InitDB()
		if not C_CurveUtil or not C_CurveUtil.CreateColorCurve or not UnitHealthPercent then
			Say("needs the retail health curve API, so it did not start.")
			return
		end
		BuildCurves()
		CreateAlert()
		CreateOptions()
		CreateMinimapButton()
		RequestItems()
		QueueScan()
		Say("loaded. Warns below " .. db.threshold .. "%. Minimap: left-click locks, right-click opens options.")
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not frame then
			return
		end
		RequestItems()
		QueueScan()
		if not ticker then
			ticker = C_Timer.NewTicker(0.1, SafeUpdate)
		end
	elseif event == "BAG_UPDATE_DELAYED" then
		if frame then
			QueueScan()
		end
	elseif event == "ITEM_DATA_LOAD_RESULT" then
		if frame and type(arg1) == "number" and IsListed(arg1) then
			spellByItem[arg1] = nil
			QueueScan()
		end
	end
end)
