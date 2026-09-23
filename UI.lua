-- MeineBots / UI.lua
--
-- Ein Fenster, zwei Tabs (Meine Bots / Verwaltung). Liste links, Detail rechts.
-- Steuerung ueber Comm.lua. Bewusst schlank gehalten -- die wichtigen Sachen direkt da.

local MB = MeineBots
MB.UI = MB.UI or {}
local UI = MB.UI

-- ---------------------------------------------------------------- Konstanten
local CLASS_TOKEN = {
  [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
  [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
}
local CLASS_DE = {
  WARRIOR = "Krieger", PALADIN = "Paladin", HUNTER = "Jaeger", ROGUE = "Schurke", PRIEST = "Priester",
  DEATHKNIGHT = "Todesritter", SHAMAN = "Schamane", MAGE = "Magier", WARLOCK = "Hexenmeister", DRUID = "Druide",
}
-- Deine Altbots (fuer die Verwaltung: schnell holen/entlassen)
local KNOWN_ALTS = { "Butterblume", "Hexe", "Kloppi", "Meule", "Veatel", "Hammerline" }

local ROLE_LABEL = { tank = "Tank", heal = "Heiler", dps = "DPS" }

local BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 24,
  insets = { left = 8, right = 8, top = 8, bottom = 8 },
}
local CARD = {
  bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
  tile = false, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local frame, list, detail, manage, logFS, statusFS
local rowFrames = {}
local detailTab = "strat"    -- strat | inv | quests
UI.selected = nil

-- ---------------------------------------------------------------- Helpers
local function classColor(cls)
  local token = CLASS_TOKEN[cls]
  local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
local function roleOf(name)
  local st = MB.states[name]
  if not st then return "dps" end
  local c = (st.combat or ""):lower()
  if c:find("tank") then return "tank" end
  if c:find("heal") then return "heal" end
  return "dps"
end
local function isGrinding(name)
  local st = MB.states[name]
  return st and (st.noncombat or ""):lower():find("grind") ~= nil
end

function MB.Log(text)
  if logFS then logFS:SetText("|cffd8b862[MeineBots]|r " .. (text or "")) end
end

-- ---------------------------------------------------------------- Kontextmenue
local menu
local function ensureMenu()
  if menu then return menu end
  menu = CreateFrame("Frame", "MeineBotsMenu", UIParent)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetBackdrop(BACKDROP)
  menu:SetBackdropColor(0.04, 0.03, 0.02, 0.98)
  menu:Hide()
  menu.buttons = {}
  menu:SetScript("OnUpdate", function(self)
    -- schliessen, wenn Maus ausserhalb und ein Klick faellt (einfacher Auto-Close)
    if not self:IsMouseOver() and not self.hovered and (GetTime() - (self.shownAt or 0)) > 0.15 then
      -- offen lassen bis Klick woanders: hier nur Timeout-Schutz
    end
  end)
  return menu
end
local function closeMenu() if menu then menu:Hide() end end

-- items: { {label=, r,g,b (optional), disabled=, func=} , {sep=true} }
local function showMenu(items, header)
  ensureMenu()
  for _, b in ipairs(menu.buttons) do b:Hide() end
  local y, width = -10, 170
  if header then
    menu.header = menu.header or menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    menu.header:ClearAllPoints()
    menu.header:SetPoint("TOPLEFT", 12, y)
    menu.header:SetText(header)
    menu.header:Show()
    width = math.max(width, menu.header:GetStringWidth() + 24)
    y = y - 18
  elseif menu.header then
    menu.header:Hide()
  end
  local idx = 0
  for _, it in ipairs(items) do
    idx = idx + 1
    local btn = menu.buttons[idx]
    if not btn then
      btn = CreateFrame("Button", nil, menu)
      btn:SetHeight(19)
      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      btn.text:SetPoint("LEFT", 12, 0)
      btn.hl = btn:CreateTexture(nil, "HIGHLIGHT")
      btn.hl:SetAllPoints()
      btn.hl:SetTexture(1, 1, 1, 0.12)
      menu.buttons[idx] = btn
    end
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", 4, y)
    btn:SetPoint("RIGHT", -4, 0)
    if it.sep then
      btn:EnableMouse(false); btn.hl:Hide(); btn.text:SetText(" ")
      btn:SetHeight(6); y = y - 6
    else
      btn:SetHeight(19); btn.hl:Show(); btn:EnableMouse(true)
      btn.text:SetText(it.label)
      if it.disabled then btn.text:SetTextColor(0.5, 0.5, 0.5)
      elseif it.r then btn.text:SetTextColor(it.r, it.g, it.b)
      else btn.text:SetTextColor(0.9, 0.86, 0.75) end
      local fn = it.func
      btn:SetScript("OnClick", function()
        closeMenu()
        if fn and not it.disabled then fn() end
      end)
      width = math.max(width, btn.text:GetStringWidth() + 30)
      y = y - 19
    end
    btn:Show()
  end
  menu:SetWidth(width + 8)
  menu:SetHeight(-y + 12)
  local cx, cy = GetCursorPosition()
  local s = UIParent:GetEffectiveScale()
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / s, cy / s)
  menu.shownAt = GetTime()
  menu:Show()
end
UI.ShowMenu = showMenu
UI.CloseMenu = closeMenu

-- Klick irgendwo schliesst das Menue
local closer = CreateFrame("Frame", nil, UIParent)
closer:SetAllPoints()
closer:SetFrameStrata("FULLSCREEN")
closer:EnableMouse(false)

-- ---------------------------------------------------------------- Aktionen (v1: Whisper/Dot)
local function actFollow(n) MB.BotCmd(n, "follow"); MB.Log(n .. ": folgt dir") end
local function actStay(n)   MB.BotCmd(n, "stay");   MB.Log(n .. ": bleibt stehen") end
local function actAttack(n) MB.BotCmd(n, "attack"); MB.Log(n .. ": greift dein Ziel an") end
local function actVendor(n) MB.BotCmd(n, "sell vendor"); MB.Log(n .. ": geht zum Haendler") end
local function actRepair(n) MB.BotCmd(n, "repair"); MB.Log(n .. ": repariert") end
local function actSummon(n) MB.BotCmd(n, "summon"); MB.Log(n .. ": zu dir gerufen (summon)") end
local function setRole(n, r)
  MB.BotCmd(n, "co +" .. r)
  MB.Log(n .. ": Rolle -> " .. (ROLE_LABEL[r] or r))
  MB.After(0.4, MB.ReqStates)
end
local function startGrind(n) MB.BotCmd(n, "grind"); MB.Log(n .. ": grindet  (Stoppen: Folgen)"); MB.After(0.4, MB.ReqStates) end
local function toggleGrind(n) startGrind(n) end   -- Playerbots: "grind" startet; Folgen/Stopp beendet
local function resetStrats(n)
  MB.BotCmd(n, "follow")
  MB.Log(n .. ": zurueck auf Folgen (Grind gestoppt)")
  MB.After(0.4, MB.ReqStates)
end
local function removeBot(n)
  MB.Dot(".bot remove " .. n)
  MB.Log(n .. ": aus der Gruppe entlassen (.bot remove)")
  MB.After(0.6, MB.RefreshAll)
end
local function addBot(n)
  MB.Dot(".bot add " .. n)
  MB.Log(n .. ": in die Gruppe geholt (.bot add)")
  MB.After(0.6, MB.RefreshAll)
end

-- ---------------------------------------------------------------- Bot-Rechtsklick
local function botContext(name)
  showMenu({
    { label = "Auswaehlen / Details", func = function() UI.Select(name) end },
    { sep = true },
    { label = "Folgen", func = function() actFollow(name) end },
    { label = "Stehen bleiben", func = function() actStay(name) end },
    { label = "Mein Ziel angreifen", func = function() actAttack(name) end },
    { label = "Zu mir rufen (Summon)", func = function() actSummon(name) end },
    { sep = true },
    { label = "Rolle: Tank", func = function() setRole(name, "tank") end },
    { label = "Rolle: Heiler", func = function() setRole(name, "heal") end },
    { label = "Rolle: DPS", func = function() setRole(name, "dps") end },
    { sep = true },
    { label = "Zum Haendler", func = function() actVendor(name) end },
    { label = "Reparieren", func = function() actRepair(name) end },
    { label = "Grinden  (Stoppen: Folgen)", func = function() startGrind(name) end },
    { label = "Zurueck auf Folgen", func = function() resetStrats(name) end },
    { sep = true },
    { label = "Aus Gruppe entlassen", r = 0.95, g = 0.45, b = 0.35, func = function() removeBot(name) end },
  }, name)
end

-- ---------------------------------------------------------------- Item-/Quest-Rechtsklick
local function itemContext(item)
  showMenu({
    { label = "Im Chat verlinken", func = function()
        local lnk = item.link
        if not lnk then MB.Print("kein Item-Link vorhanden"); return end
        if not (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) then ChatFrame_OpenChat("") end
        ChatEdit_InsertLink(lnk)
      end },
    { sep = true },
    { label = "Handel mit mir  (Phase 2)", disabled = true },
    { label = "Verkaufen  (Phase 2)", disabled = true },
    { label = "Zerstoeren  (Phase 2)", r = 0.8, g = 0.5, b = 0.45, disabled = true },
  }, item.name)
end
local function questContext(q)
  local link = GetQuestLink and nil -- 3.3.5a kann fremde Quests nicht direkt verlinken
  showMenu({
    { label = "Details  (Phase 2: QUEST_INFO)", disabled = true },
    { label = "Mit mir teilen  (Phase 2)", disabled = true },
    { label = "Abgeben  (Phase 2: QUEST_TURNIN)", disabled = true },
    { sep = true },
    { label = "Abbrechen  (Phase 2)", r = 0.9, g = 0.45, b = 0.35, disabled = true },
  }, "Quest " .. tostring(q.id))
end

-- ---------------------------------------------------------------- Liste
local ROW_H = 52
local function makeRow(i)
  local r = CreateFrame("Button", nil, list)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", list, "TOPLEFT", 6, -6 - (i - 1) * (ROW_H + 5))
  r:SetPoint("RIGHT", list, "RIGHT", -6, 0)
  r:SetBackdrop(CARD)
  r:SetBackdropColor(0.08, 0.07, 0.04, 1)
  r:SetBackdropBorderColor(0.16, 0.13, 0.08, 1)

  r.warn = r:CreateTexture(nil, "OVERLAY")
  r.warn:SetPoint("TOPLEFT", 1, -4); r.warn:SetPoint("BOTTOMLEFT", 1, 4); r.warn:SetWidth(3)
  r.warn:SetTexture(0.82, 0.29, 0.20, 1); r.warn:Hide()

  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.name:SetPoint("TOPLEFT", 12, -6)
  r.lvl = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.lvl:SetPoint("LEFT", r.name, "RIGHT", 6, 0)
  r.role = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.role:SetPoint("TOPRIGHT", -12, -6)

  r.hp = CreateFrame("StatusBar", nil, r)
  r.hp:SetPoint("TOPLEFT", 12, -23); r.hp:SetPoint("RIGHT", -12, 0); r.hp:SetHeight(6)
  r.hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  r.hp:SetStatusBarColor(0.18, 0.56, 0.24); r.hp:SetMinMaxValues(0, 100)
  r.mana = CreateFrame("StatusBar", nil, r)
  r.mana:SetPoint("TOPLEFT", 12, -31); r.mana:SetPoint("RIGHT", -12, 0); r.mana:SetHeight(5)
  r.mana:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  r.mana:SetStatusBarColor(0.18, 0.37, 0.79); r.mana:SetMinMaxValues(0, 100)

  r.strat = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.strat:SetPoint("TOPLEFT", 12, -39)     -- fester Top-Anker, kein RIGHT -> einzeilig
  r.strat:SetJustifyH("LEFT")

  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r:SetScript("OnClick", function(self, button)
    if button == "RightButton" then botContext(self.botName)
    else UI.Select(self.botName) end
  end)
  return r
end

local function refreshList()
  if not list then return end
  local warns = 0
  for i, b in ipairs(MB.roster) do
    local r = rowFrames[i] or makeRow(i)
    rowFrames[i] = r
    r.botName = b.name
    local cr, cg, cb = classColor(b.cls)
    r.name:SetText(b.name); r.name:SetTextColor(cr, cg, cb)
    r.lvl:SetText("Lv " .. b.lvl .. " " .. (CLASS_DE[CLASS_TOKEN[b.cls] or ""] or ""))
    local role = roleOf(b.name)
    r.role:SetText(ROLE_LABEL[role])
    r.hp:SetValue(b.alive and b.hp or 0)
    r.mana:SetValue(b.mana)
    local st = MB.states[b.name]
    local grind = isGrinding(b.name)
    local line = st and ((st.combat or "") .. "  |  " .. (st.noncombat or "")) or "(keine Strategie-Daten)"
    if #line > 52 then line = line:sub(1, 52) .. "..." end   -- einzeilig halten
    if grind and not MB.grindMode then
      r.strat:SetText("|cffff5555" .. line .. "  [!]|r"); r.warn:Show(); warns = warns + 1
    else
      r.strat:SetText(line); r.warn:Hide()
    end
    if UI.selected == b.name then r:SetBackdropBorderColor(0.85, 0.72, 0.4, 1)
    else r:SetBackdropBorderColor(0.16, 0.13, 0.08, 1) end
    r:Show()
  end
  for i = #MB.roster + 1, #rowFrames do rowFrames[i]:Hide() end
  if list.empty then if #MB.roster == 0 then list.empty:Show() else list.empty:Hide() end end
  if statusFS then
    statusFS:SetText((MB.bridge.connected and "|cff4fc76aBridge verbunden|r" or "|cffff5555Bridge nicht verbunden|r")
      .. "  -  " .. #MB.roster .. " Bots" .. (warns > 0 and ("  -  |cffff5555" .. warns .. " auffaellig|r") or ""))
  end
  if frame and frame.navBotsBadge then frame.navBotsBadge:SetText(#MB.roster) end
end

-- ---------------------------------------------------------------- Detail
local function setDetailTab(t) detailTab = t; UI.RefreshDetail() end

local function renderStrat(b)
  local body = detail.body
  local st = MB.states[b.name] or { combat = "", noncombat = "" }
  detail.txt:SetText("|cffaaaaaaKampf:|r " .. (st.combat ~= "" and st.combat or "-") ..
    "\n|cffaaaaaaAusserhalb:|r " .. (st.noncombat ~= "" and st.noncombat or "-"))
  detail.txt:Show()
  detail.itemHost:Hide()
  detail.questHost:Hide()
end

local function renderInv(b)
  local inv = MB.inv[b.name]
  detail.txt:Hide()
  detail.questHost:Hide()
  local host = detail.itemHost
  host:Show()
  for _, s in ipairs(host.slots) do s:Hide() end
  if not inv then
    host.info:SetText("Lade Inventar ...")
    MB.ReqInventory(b.name)
    return
  end
  local per = 8
  for i, item in ipairs(inv.items) do
    local s = host.slots[i]
    if not s then
      s = CreateFrame("Button", nil, host)
      s:SetSize(34, 34)
      s:SetPoint("TOPLEFT", host, "TOPLEFT", 6 + ((i - 1) % per) * 38, -6 - math.floor((i - 1) / per) * 38)
      s.icon = s:CreateTexture(nil, "ARTWORK"); s.icon:SetAllPoints(); s.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      s:SetBackdrop(CARD); s:SetBackdropColor(0.05, 0.04, 0.02, 1)
      s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      host.slots[i] = s
    end
    s:ClearAllPoints()
    s:SetPoint("TOPLEFT", host, "TOPLEFT", 6 + ((i - 1) % per) * 38, -24 - math.floor((i - 1) / per) * 38)
    s.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.q or 1]
    if qc then s:SetBackdropBorderColor(qc.r, qc.g, qc.b, 1) else s:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
    s.item = item
    s:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if self.item.link then GameTooltip:SetHyperlink(self.item.link) else GameTooltip:SetText(self.item.name) end
      GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    s:SetScript("OnClick", function(self, button)
      if button == "RightButton" then itemContext(self.item) end
    end)
    s:Show()
  end
  local money = string.format("%dg %ds %dc", inv.gold, inv.silver, inv.copper)
  host.info:SetText("Rucksack: " .. inv.bagUsed .. " / " .. inv.bagTotal .. " belegt   -   " .. money ..
    "   -   |cff888888Hover = Tooltip, Rechtsklick = Aktionen|r")
end

local function renderQuests(b)
  local qs = MB.quests[b.name]
  detail.txt:Hide()
  detail.itemHost:Hide()
  local host = detail.questHost
  host:Show()
  for _, r in ipairs(host.rows) do r:Hide() end
  if not qs then host.info:SetText("Lade Quests ..."); MB.ReqQuests(b.name); return end
  host.info:SetText(#qs .. " Quests  -  |cff888888Titel/Ziele folgen in Phase 2 (QUEST_INFO)|r")
  for i, q in ipairs(qs) do
    local r = host.rows[i]
    if not r then
      r = CreateFrame("Button", nil, host)
      r:SetHeight(20)
      r:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -24 - (i - 1) * 22)
      r:SetPoint("RIGHT", host, "RIGHT", -6, 0)
      r:SetBackdrop(CARD); r:SetBackdropColor(0.08, 0.07, 0.04, 1); r:SetBackdropBorderColor(0.16, 0.13, 0.08, 1)
      r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.t:SetPoint("LEFT", 8, 0)
      r.s = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.s:SetPoint("RIGHT", -8, 0)
      r:RegisterForClicks("RightButtonUp")
      host.rows[i] = r
    end
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -24 - (i - 1) * 22); r:SetPoint("RIGHT", host, "RIGHT", -6, 0)
    local title = MB.questTitles[q.id]
    if title then r.t:SetText(title) else r.t:SetText("|cff888888Quest #" .. tostring(q.id) .. " ...|r"); MB.ReqQuestInfo(q.id) end
    if q.completed then r.s:SetText("|cff4fc76aabgeschlossen|r") else r.s:SetText("|cffe0a636aktiv|r") end
    r.quest = q
    r:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(MB.questTitles[self.quest.id] or ("Quest #" .. self.quest.id), 1, 0.82, 0)
      GameTooltip:AddLine("Quest-ID " .. self.quest.id, 0.7, 0.7, 0.7)
      GameTooltip:AddLine(self.quest.completed and "abgeschlossen" or "aktiv", 0.6, 0.8, 1)
      GameTooltip:AddLine("Rechtsklick: Aktionen (Phase 2)", 0.5, 0.5, 0.5)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self) questContext(self.quest) end)
    r:Show()
  end
end

function UI.RefreshDetail()
  if not detail then return end
  local name = UI.selected
  local b = name and MB.byName[name]
  if not b then
    detail.name:SetText("-"); detail.meta:SetText("")
    detail.txt:SetText("Kein Bot gewaehlt."); detail.txt:Show()
    detail.itemHost:Hide(); detail.questHost:Hide()
    return
  end
  local cr, cg, cb = classColor(b.cls)
  detail.name:SetText(b.name); detail.name:SetTextColor(cr, cg, cb)
  local role = roleOf(b.name)
  detail.meta:SetText("Level " .. b.lvl .. " " .. (CLASS_DE[CLASS_TOKEN[b.cls] or ""] or "") ..
    "  -  Rolle: " .. ROLE_LABEL[role] .. (isGrinding(b.name) and not MB.grindMode and "  -  |cffff5555grindet trotz Grind-Mode aus|r" or ""))
  -- Tab-Highlight
  for key, tab in pairs(detail.tabs) do
    if key == detailTab then tab:LockHighlight() else tab:UnlockHighlight() end
  end
  if detailTab == "inv" then renderInv(b)
  elseif detailTab == "quests" then renderQuests(b)
  else renderStrat(b) end
end

function UI.Select(name)
  UI.selected = name
  detailTab = "strat"
  refreshList()
  UI.RefreshDetail()
  if name then MB.ReqInventory(name); MB.ReqQuests(name) end
end

-- ---------------------------------------------------------------- Fenster
local function switchView(v)
  UI.view = v
  if v == "bots" then frame.viewBots:Show() else frame.viewBots:Hide() end
  if v == "manage" then frame.viewManage:Show() else frame.viewManage:Hide() end
  if frame.groupbar then if v == "bots" then frame.groupbar:Show() else frame.groupbar:Hide() end end
  if v == "bots" then frame.navBots:LockHighlight(); frame.navManage:UnlockHighlight()
  else frame.navManage:LockHighlight(); frame.navBots:UnlockHighlight() end
  closeMenu()
end

local function makeButton(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 90, h or 22); b:SetText(text)
  return b
end

local autoTimer
local function scheduleRefresh()
  if not frame or not frame:IsShown() then return end
  MB.RefreshAll()
  MB.After(5, scheduleRefresh)
end

local function buildManage()
  manage = CreateFrame("Frame", nil, frame)
  manage:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -96)
  manage:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 64)

  local head = manage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  head:SetPoint("TOPLEFT", 0, 0); head:SetText("Verwaltung")

  local g = manage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  g:SetPoint("TOPLEFT", 0, -30); g:SetText("|cffd8b862Meine Gruppe|r  -  Altbots holen / entlassen")

  -- Alt-Buttons
  local prev
  for i, alt in ipairs(KNOWN_ALTS) do
    local add = makeButton(manage, alt .. "  +", 120, 20)
    if i == 1 then add:SetPoint("TOPLEFT", 0, -52) else add:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4) end
    add:SetScript("OnClick", function() addBot(alt) end)
    local rem = makeButton(manage, "-", 24, 20)
    rem:SetPoint("LEFT", add, "RIGHT", 4, 0)
    rem:SetScript("OnClick", function() removeBot(alt) end)
    prev = add
  end

  local eb = CreateFrame("EditBox", nil, manage, "InputBoxTemplate")
  eb:SetSize(150, 20); eb:SetPoint("TOPLEFT", 170, -52); eb:SetAutoFocus(false)
  local ebl = manage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ebl:SetPoint("BOTTOMLEFT", eb, "TOPLEFT", -4, 2); ebl:SetText("Bot per Name holen")
  local ebb = makeButton(manage, "Holen", 60, 20)
  ebb:SetPoint("LEFT", eb, "RIGHT", 6, 0)
  ebb:SetScript("OnClick", function()
    local n = eb:GetText()
    if n and n ~= "" then addBot(n); eb:SetText(""); eb:ClearFocus() end
  end)

  local g2 = manage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  g2:SetPoint("TOPLEFT", 170, -96); g2:SetText("|cffd8b862Zufalls-Flotte|r")
  local reroll = makeButton(manage, "Flotte neu wuerfeln", 160, 22)
  reroll:SetPoint("TOPLEFT", 170, -118)
  reroll:SetScript("OnClick", function() MB.Dot(".playerbots rndbot init"); MB.Log("Flotte neu gewuerfelt (.playerbots rndbot init)") end)

  local note = manage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", 0, -210); note:SetPoint("RIGHT", 0, 0); note:SetJustifyH("LEFT")
  note:SetText("|cff888888Flotten-Groesse, Fraktion, Gilden-Zuweisung sind .conf-Werte und wirken erst nach einem Neustart.\n"
    .. "Formation / Loot / Raid-Marker und Item-Aktionen folgen in Phase 2 ueber die RUN-Endpunkte der Bridge.|r")

  manage:Hide()
end

local function buildFrame()
  frame = CreateFrame("Frame", "MeineBotsFrame", UIParent)
  frame:SetSize(760, 516)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0.09, 0.07, 0.05, 1)
  frame:SetMovable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    MeineBotsDB = MeineBotsDB or {}
    MeineBotsDB.pos = { p, rp, x, y }
  end)
  tinsert(UISpecialFrames, "MeineBotsFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14); title:SetText("|cffd8b862MeineBots|r")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  -- Top-Navigation
  frame.navBots = makeButton(frame, "Meine Bots", 120, 22)
  frame.navBots:SetPoint("TOPLEFT", 14, -40)
  frame.navBots:SetScript("OnClick", function() switchView("bots") end)
  frame.navBotsBadge = frame.navBots:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.navBotsBadge:SetPoint("RIGHT", frame.navBots, "RIGHT", -8, 0)
  frame.navManage = makeButton(frame, "Verwaltung", 120, 22)
  frame.navManage:SetPoint("LEFT", frame.navBots, "RIGHT", 6, 0)
  frame.navManage:SetScript("OnClick", function() switchView("manage") end)

  statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusFS:SetPoint("TOPLEFT", 16, -70)

  -- View: Meine Bots
  frame.viewBots = CreateFrame("Frame", nil, frame)
  frame.viewBots:SetPoint("TOPLEFT", 14, -88)
  frame.viewBots:SetPoint("BOTTOMRIGHT", -14, 64)

  list = CreateFrame("Frame", nil, frame.viewBots)
  list:SetPoint("TOPLEFT", 0, 0); list:SetPoint("BOTTOMLEFT", 0, 0); list:SetWidth(340)
  list:SetBackdrop(CARD); list:SetBackdropColor(0.05, 0.04, 0.02, 0.6); list:SetBackdropBorderColor(0.16, 0.13, 0.08, 1)
  list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  list.empty:SetPoint("TOP", 0, -40); list.empty:SetWidth(300); list.empty:SetJustifyH("CENTER")
  list.empty:SetText("Keine sichtbaren Bots.\n\nSind deine Bots online und mit dir\nin einer Gruppe? Dann |cffffff00Aktualisieren|r.\n\nTipp: |cffffff00/mb debug|r zeigt die Roh-Kommunikation.")

  detail = CreateFrame("Frame", nil, frame.viewBots)
  detail:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
  detail:SetPoint("BOTTOMRIGHT", 0, 0)
  detail:SetBackdrop(CARD); detail:SetBackdropColor(0.05, 0.04, 0.02, 0.6); detail:SetBackdropBorderColor(0.16, 0.13, 0.08, 1)

  detail.name = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detail.name:SetPoint("TOPLEFT", 12, -10)
  detail.meta = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detail.meta:SetPoint("TOPLEFT", 12, -32)

  -- Detail-Tabs
  detail.tabs = {}
  local function detailTabBtn(key, text, x)
    local b = makeButton(detail, text, 84, 20)
    b:SetPoint("TOPLEFT", 10 + x, -50)
    b:SetScript("OnClick", function() setDetailTab(key) end)
    detail.tabs[key] = b
    return b
  end
  detailTabBtn("strat", "Strategien", 0)
  detailTabBtn("inv", "Inventar", 88)
  detailTabBtn("quests", "Quests", 176)

  detail.body = CreateFrame("Frame", nil, detail)
  detail.body:SetPoint("TOPLEFT", 10, -78); detail.body:SetPoint("BOTTOMRIGHT", -10, 60)  -- ueber den zwei Button-Reihen

  detail.txt = detail.body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detail.txt:SetPoint("TOPLEFT", 4, -4); detail.txt:SetPoint("RIGHT", -4, 0); detail.txt:SetJustifyH("LEFT")

  detail.itemHost = CreateFrame("Frame", nil, detail.body)
  detail.itemHost:SetAllPoints()
  detail.itemHost.slots = {}
  detail.itemHost.info = detail.itemHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detail.itemHost.info:SetPoint("TOPLEFT", 4, -2); detail.itemHost.info:SetPoint("RIGHT", -4, 0); detail.itemHost.info:SetJustifyH("LEFT")
  detail.itemHost:Hide()

  detail.questHost = CreateFrame("Frame", nil, detail.body)
  detail.questHost:SetAllPoints()
  detail.questHost.rows = {}
  detail.questHost.info = detail.questHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  detail.questHost.info:SetPoint("TOPLEFT", 6, -4); detail.questHost.info:SetPoint("RIGHT", -6, 0); detail.questHost.info:SetJustifyH("LEFT")
  detail.questHost:Hide()

  -- Per-Bot-Steuerung (rechts, wirkt auf den GEWAEHLTEN Bot) -- zwei Reihen
  local function detBtn(label, w) return makeButton(detail, label, w or 70, 20) end
  -- Reihe 1: Aktionen
  detail.aFollow = detBtn("Folgen", 56);      detail.aFollow:SetPoint("BOTTOMLEFT", 10, 34)
  detail.aStop   = detBtn("Stopp", 52);       detail.aStop:SetPoint("LEFT", detail.aFollow, "RIGHT", 3, 0)
  detail.aAtk    = detBtn("Angriff", 58);     detail.aAtk:SetPoint("LEFT", detail.aStop, "RIGHT", 3, 0)
  detail.aSummon = detBtn("Summon", 60);      detail.aSummon:SetPoint("LEFT", detail.aAtk, "RIGHT", 3, 0)
  detail.aVend   = detBtn("Vendor", 56);      detail.aVend:SetPoint("LEFT", detail.aSummon, "RIGHT", 3, 0)
  detail.aRep    = detBtn("Reparieren", 72);  detail.aRep:SetPoint("LEFT", detail.aVend, "RIGHT", 3, 0)
  detail.aFollow:SetScript("OnClick", function() if UI.selected then actFollow(UI.selected) end end)
  detail.aStop:SetScript("OnClick",   function() if UI.selected then actStay(UI.selected) end end)
  detail.aAtk:SetScript("OnClick",    function() if UI.selected then actAttack(UI.selected) end end)
  detail.aSummon:SetScript("OnClick", function() if UI.selected then actSummon(UI.selected) end end)
  detail.aVend:SetScript("OnClick",   function() if UI.selected then actVendor(UI.selected) end end)
  detail.aRep:SetScript("OnClick",    function() if UI.selected then actRepair(UI.selected) end end)
  -- Reihe 2: Rolle / Grind / Reset
  detail.roleTank = detBtn("Tank", 58);   detail.roleTank:SetPoint("BOTTOMLEFT", 10, 8)
  detail.roleHeal = detBtn("Heiler", 58); detail.roleHeal:SetPoint("LEFT", detail.roleTank, "RIGHT", 3, 0)
  detail.roleDps  = detBtn("DPS", 58);    detail.roleDps:SetPoint("LEFT", detail.roleHeal, "RIGHT", 3, 0)
  detail.grind    = detBtn("Grind", 58);  detail.grind:SetPoint("LEFT", detail.roleDps, "RIGHT", 8, 0)
  detail.reset    = detBtn("Reset", 66);  detail.reset:SetPoint("LEFT", detail.grind, "RIGHT", 3, 0)
  detail.roleTank:SetScript("OnClick", function() if UI.selected then setRole(UI.selected, "tank") end end)
  detail.roleHeal:SetScript("OnClick", function() if UI.selected then setRole(UI.selected, "heal") end end)
  detail.roleDps:SetScript("OnClick",  function() if UI.selected then setRole(UI.selected, "dps") end end)
  detail.grind:SetScript("OnClick",    function() if UI.selected then startGrind(UI.selected) end end)
  detail.reset:SetScript("OnClick",    function() if UI.selected then resetStrats(UI.selected) end end)

  -- EINE Leiste unten -- wirkt auf ALLE eigenen Bots (Party-/Raid-Chat, wie MultiBot)
  frame.groupbar = CreateFrame("Frame", nil, frame)
  frame.groupbar:SetPoint("BOTTOMLEFT", 14, 34); frame.groupbar:SetPoint("BOTTOMRIGHT", -14, 34); frame.groupbar:SetHeight(24)
  local glbl = frame.groupbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  glbl:SetPoint("LEFT", 2, 0); glbl:SetText("|cffd8b862Alle:|r")
  local groupActs = {
    { "Folgen", "follow" }, { "Stopp", "stay" }, { "Angriff", "attack" }, { "Summon", "summon" },
    { "Grind", "grind" }, { "Vendor", "sell vendor" }, { "Reparieren", "repair" },
  }
  local gx = 38
  for _, a in ipairs(groupActs) do
    local b = makeButton(frame.groupbar, a[1], 78, 22)
    b:SetPoint("LEFT", gx, 0); gx = gx + 80
    local cmd = a[2]
    b:SetScript("OnClick", function() MB.PartyCmd(cmd); MB.Log("Alle: " .. cmd); MB.After(0.5, MB.ReqStates) end)
  end
  local refresh = makeButton(frame.groupbar, "Aktualisieren", 96, 22)
  refresh:SetPoint("RIGHT", 0, 0)
  refresh:SetScript("OnClick", function() MB.RefreshAll(); MB.Log("Aktualisiere ...") end)

  logFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  logFS:SetPoint("BOTTOMLEFT", 16, 12); logFS:SetPoint("RIGHT", -16, 0); logFS:SetJustifyH("LEFT")

  buildManage()
  frame.viewManage = manage

  frame:SetScript("OnShow", function()
    refreshList()             -- gecachtes Roster sofort zeigen
    UI.RefreshDetail()
    MB.Hello()                -- Handshake (idempotent) -> Bridge antwortet mit CAPS
    MB.After(0.5, MB.RefreshAll)
    MB.After(2.0, MB.RefreshAll)   -- Bots loggen evtl. noch ein
    scheduleRefresh()
    MB.Log("bereit -- /mb debug zeigt die Roh-Kommunikation.")
  end)

  -- gespeicherte Position
  if MeineBotsDB and MeineBotsDB.pos then
    local p, rp, x, y = unpack(MeineBotsDB.pos)
    frame:ClearAllPoints(); frame:SetPoint(p, UIParent, rp, x, y)
  end

  switchView("bots")
  refreshList()
  UI.RefreshDetail()
end

-- Auf Bridge-Events reagieren
MB.On("roster", function()
  if UI.selected and not MB.byName[UI.selected] then UI.selected = nil end  -- veraltete Auswahl bereinigen
  if not UI.selected and MB.roster[1] then UI.selected = MB.roster[1].name end
  refreshList(); UI.RefreshDetail()
end)
MB.On("state", function() refreshList(); if frame and frame:IsShown() then UI.RefreshDetail() end end)
MB.On("inventory", function(name) if name == UI.selected and detailTab == "inv" then UI.RefreshDetail() end end)
MB.On("quests", function(name) if name == UI.selected and detailTab == "quests" then UI.RefreshDetail() end end)
MB.On("questinfo", function() if frame and frame:IsShown() and detailTab == "quests" then UI.RefreshDetail() end end)
MB.On("connected", function() MB.Log("mit Bridge verbunden."); refreshList() end)
MB.On("err", function(rest) MB.Log("|cffff5555Fehler:|r " .. tostring(rest)) end)

-- ---------------------------------------------------------------- Toggle + Slash
function UI.Toggle()
  if not frame then buildFrame() end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

SLASH_MEINEBOTS1 = "/mb"
SLASH_MEINEBOTS2 = "/meinebots"
SlashCmdList["MEINEBOTS"] = function(msg)
  msg = (msg or ""):lower():gsub("%s+", "")
  if msg == "debug" then
    MB.debug = not MB.debug
    MB.Print("Debug " .. (MB.debug and "AN" or "AUS"))
    if MB.debug then MB.Diag(); MB.Hello(); MB.After(0.4, MB.RefreshAll) end
    return
  elseif msg == "diag" then
    MB.Diag(); MB.Hello(); MB.After(0.4, MB.RefreshAll)
    return
  end
  UI.Toggle()
end

-- Minimap-Hinweis in den Chat beim ersten Login
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
  MeineBotsDB = MeineBotsDB or {}
  DEFAULT_CHAT_FRAME:AddMessage("|cffd8b862MeineBots|r geladen -- |cffffff00/mb|r oeffnet das Fenster.")
end)
