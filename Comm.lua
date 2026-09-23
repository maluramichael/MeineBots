-- MeineBots / Comm.lua
--
-- Kommunikationsschicht: redet mit dem serverseitigen Modul mod-multibot-bridge
-- ueber Addon-Nachrichten (Prefix "MBOT", Feldtrenner "~", Wire "MBOT\t<opcode>~<payload>").
--
-- Gelesen wird chatlos ueber die Bridge (ROSTER / STATES / INVENTORY / QUESTS).
-- Gesteuert wird in v1 ueber Playerbot-Whisper-Kommandos an den Bot (co/nc/follow/...)
-- und ueber .-Kommandos an den Server (.bot add/remove, .playerbots rndbot init).
-- Die Schreib-Wege wandern spaeter auf die RUN~-Endpunkte der Bridge (Phase 2).

MeineBots = MeineBots or {}
local MB = MeineBots

MB.VERSION = "0.1.0"
MB.PREFIX  = "MBOT"
MB.PROTO   = "1"
MB.channel = "WHISPER"   -- Kanal, auf dem die Bridge lauscht (Antwort kommt per WHISPER zurueck)
MB.debug   = false       -- /mb debug schaltet Roh-Logging in den Chat

function MB.Print(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffd8b862[MeineBots]|r " .. tostring(text))
end

MB.bridge  = { connected = false, hello = false, caps = {} }
MB.roster  = {}          -- Array: { {name, cls, lvl, map, alive, hp, mana}, ... }
MB.byName  = {}          -- name -> Roster-Eintrag
MB.states  = {}          -- name -> { combat = "..", noncombat = ".." }
MB.inv     = {}          -- name -> { gold, silver, copper, bagUsed, bagTotal, items = { {..}, .. } }
MB.quests  = {}          -- name -> { {id, completed}, .. }

-- ---------------------------------------------------------------- Mini-Event-Bus
local listeners = {}
function MB.On(evt, fn)
  listeners[evt] = listeners[evt] or {}
  table.insert(listeners[evt], fn)
end
function MB.Emit(evt, ...)
  local l = listeners[evt]
  if not l then return end
  for _, fn in ipairs(l) do fn(...) end
end

-- ---------------------------------------------------------------- Mini-Timer (kein C_Timer in 3.3.5a)
local timers = {}
function MB.After(delay, fn) table.insert(timers, { at = GetTime() + delay, fn = fn }) end
local tf = CreateFrame("Frame")
tf:SetScript("OnUpdate", function()
  if #timers == 0 then return end
  local now = GetTime()
  for i = #timers, 1, -1 do
    local t = timers[i]
    if now >= t.at then table.remove(timers, i); t.fn() end
  end
end)

-- ---------------------------------------------------------------- Encoding (%XX wie in der Bridge)
local function enc(s)
  return (tostring(s or ""):gsub("[%%~\r\n]", function(c) return string.format("%%%02X", string.byte(c)) end))
end
local function dec(s)
  return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
MB.enc, MB.dec = enc, dec

local seq = 0
function MB.NewToken(kind)
  seq = seq + 1
  return (kind or "t") .. math.floor(GetTime() * 1000) .. "-" .. seq
end

-- ---------------------------------------------------------------- Senden
function MB.Send(opcode, args)
  local msg = args and (opcode .. "~" .. args) or opcode
  local target = (MB.channel == "WHISPER") and UnitName("player") or nil
  if MB.debug then MB.Print("TX  " .. msg:sub(1, 180) .. "  [" .. MB.channel .. "]") end
  SendAddonMessage(MB.PREFIX, msg, MB.channel, target)
end

-- Diagnose: Verbindungsstatus + Zaehler in den Chat
function MB.Diag()
  MB.Print("verbunden=" .. tostring(MB.bridge.connected) .. " hello=" .. tostring(MB.bridge.hello)
    .. " kanal=" .. MB.channel .. " roster=" .. #MB.roster .. " bots")
  local caps = {}
  for k in pairs(MB.bridge.caps) do table.insert(caps, k) end
  MB.Print("caps: " .. (next(caps) and table.concat(caps, ", ") or "(keine)"))
  for _, b in ipairs(MB.roster) do
    local st = MB.states[b.name]
    MB.Print(" - " .. b.name .. " Lv" .. b.lvl .. " hp" .. b.hp .. (st and ("  co:" .. st.combat) or "  (kein state)"))
  end
end

function MB.Hello()
  MB.Send("HELLO", MB.PROTO)
end

-- Playerbot-Kommando an EINEN Bot (Whisper) -- Steuerung in v1
function MB.BotCmd(name, cmd)
  if not name or not cmd then return end
  SendChatMessage(cmd, "WHISPER", nil, name)
end

-- Playerbot-Kommando an die GANZE Gruppe (Party-Chat) -- alle eigenen Bots lesen mit (wie MultiBot)
function MB.PartyCmd(cmd)
  if not cmd then return end
  local chan = (GetNumRaidMembers() > 0) and "RAID" or "PARTY"
  SendChatMessage(cmd, chan)
end

-- .-Kommando an den Server (Verwaltung). Der Server fuehrt fuehrende "." als Befehl aus.
function MB.Dot(cmd)
  SendChatMessage(cmd, "SAY")
end

-- ---------------------------------------------------------------- Reads (Bridge)
function MB.ReqRoster() MB.Send("GET", "ROSTER") end
function MB.ReqStates() MB.Send("GET", "STATES~" .. MB.NewToken("st")) end  -- framed (STATE_FRAMING_V1)
function MB.ReqInventory(name) if name then MB.Send("GET", "INVENTORY~" .. name .. "~" .. MB.NewToken("inv")) end end
function MB.ReqQuests(name) if name then MB.Send("GET", "QUESTS~ALL~" .. name .. "~" .. MB.NewToken("q")) end end

-- Quest-Titel on-demand ueber QUEST_INFO (rate-limitiert: eine Anfrage pro ~0.5s)
MB.questTitles = {}
local qiQueue, qiBusy = {}, false
local function qiPump()
  if qiBusy or #qiQueue == 0 then return end
  local id = table.remove(qiQueue, 1)
  if MB.questTitles[id] then return qiPump() end
  qiBusy = true
  MB.Send("GET", "QUEST_INFO~" .. MB.NewToken("qi") .. "~" .. id)
  MB.After(0.55, function() qiBusy = false; qiPump() end)
end
function MB.ReqQuestInfo(id)
  id = tonumber(id)
  if not id or MB.questTitles[id] then return end
  for _, q in ipairs(qiQueue) do if q == id then return end end
  table.insert(qiQueue, id)
  qiPump()
end

function MB.RefreshAll()
  MB.ReqRoster()
  MB.ReqStates()
end

-- ---------------------------------------------------------------- Item-Link parsen
function MB.ParseItem(line)
  local soulbound = line:find("%(soulbound%)") ~= nil
  local id = tonumber(line:match("item:(%d+)"))
  local link = line:match("|c%x+|Hitem.-|h.-|h|r")
  local nameFromLink = line:match("%[(.-)%]")
  local name, q, icon = nameFromLink or ("Item " .. tostring(id or "?")), 1, nil
  if id then
    local iname, ilink, quality, _, _, _, _, _, _, texture = GetItemInfo(id)
    if iname then name = iname end
    if ilink then link = ilink end
    if quality then q = quality end
    icon = texture
  end
  if not icon and id then icon = GetItemIcon(id) end
  return { line = line, link = link, id = id, name = name, q = q, icon = icon, soulbound = soulbound }
end

-- ---------------------------------------------------------------- Eingehende Pakete
local function parseRoster(rest)
  MB.roster = {}
  MB.byName = {}
  for e in rest:gmatch("[^;]+") do
    local name, cls, lvl, map, alive, hp, mana = strsplit(",", e)
    if name and name ~= "" then
      local t = {
        name = name, cls = tonumber(cls) or 0, lvl = tonumber(lvl) or 0,
        map = tonumber(map) or 0, alive = (alive == "1"),
        hp = tonumber(hp) or 0, mana = tonumber(mana) or 0,
      }
      table.insert(MB.roster, t)
      MB.byName[name] = t
    end
  end
  MB.Emit("roster")
end

function MB.OnMessage(message)
  if not message or message == "" then return end
  if MB.debug then MB.Print("RX  " .. message:sub(1, 180)) end
  local op, rest = strsplit("~", message, 2)
  rest = rest or ""

  if op == "HELLO_ACK" then
    MB.bridge.hello = true

  elseif op == "CAPS" then
    MB.bridge.caps = {}
    for c in rest:gmatch("[^,]+") do MB.bridge.caps[c] = true end
    MB.bridge.connected = true
    MB.Emit("connected")
    MB.RefreshAll()

  elseif op == "PONG" then
    -- ignore

  elseif op == "ROSTER" then
    parseRoster(rest)

  elseif op == "STATE" then
    -- Legacy (unframed) -- nur als Fallback; kann bei langen Strategien STATE_TOO_LONG werfen
    local name, combat, noncombat = strsplit("~", rest, 3)
    if name then
      MB.states[name] = { combat = combat or "", noncombat = noncombat or "" }
      MB.Emit("state", name)
    end

  elseif op == "STATES_BEGIN" or op == "STATES_END" then
    -- Rahmen der Gesamtabfrage -- nichts zu tun

  elseif op == "STATE_BEGIN" then
    local _tok, name = strsplit("~", rest, 4)
    if name then MB.states[name] = { combat = "", noncombat = "", _c = {}, _n = {} } end

  elseif op == "STATE_ITEM" then
    local _tok, name, scope, _idx, strat = strsplit("~", rest, 5)
    local st = name and MB.states[name]
    if st then
      strat = dec(strat)
      if scope and scope:lower():find("non") then
        st._n = st._n or {}; table.insert(st._n, strat)
      else
        st._c = st._c or {}; table.insert(st._c, strat)
      end
    end

  elseif op == "STATE_END" then
    local _tok, name = strsplit("~", rest, 4)
    local st = name and MB.states[name]
    if st then
      st.combat = table.concat(st._c or {}, ", ")
      st.noncombat = table.concat(st._n or {}, ", ")
      MB.Emit("state", name)
    end

  elseif op == "INV_SUMMARY" then
    local name, _tok, g, s, c, used, total = strsplit("~", rest)
    if name then
      MB.inv[name] = {
        gold = tonumber(g) or 0, silver = tonumber(s) or 0, copper = tonumber(c) or 0,
        bagUsed = tonumber(used) or 0, bagTotal = tonumber(total) or 0, items = {},
      }
    end

  elseif op == "INV_ITEM" then
    local name, _tok, encLink = strsplit("~", rest, 3)
    local bucket = name and MB.inv[name]
    if bucket then table.insert(bucket.items, MB.ParseItem(dec(encLink))) end

  elseif op == "INV_END" then
    local name = strsplit("~", rest)
    if name then MB.Emit("inventory", name) end

  elseif op == "QUESTS_BEGIN" then
    local name = strsplit("~", rest)
    if name then MB.quests[name] = {} end

  elseif op == "QUESTS_ITEM" then
    local name, _tok, _mode, comp, qid = strsplit("~", rest, 6)
    local bucket = name and MB.quests[name]
    if bucket then table.insert(bucket, { id = tonumber(qid), completed = (comp == "C") }) end

  elseif op == "QUESTS_END" then
    local name = strsplit("~", rest)
    if name then MB.Emit("quests", name) end

  elseif op == "QI_HEAD" then
    local _tok, qid, _lvl, _min, title = strsplit("~", rest, 5)
    qid = tonumber(qid)
    if qid then
      MB.questTitles[qid] = dec(title)
      MB.Emit("questinfo", qid)
    end

  elseif op == "ERR" then
    MB.Emit("err", rest)

  else
    -- andere Bridge-Pakete (DETAIL, STATS, ...) werden in v1 (noch) nicht ausgewertet
  end
end

-- ---------------------------------------------------------------- Event-Frame
local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(_, evt, a1, a2)
  if evt == "CHAT_MSG_ADDON" then
    if a1 == MB.PREFIX then MB.OnMessage(a2) end
  elseif evt == "PLAYER_ENTERING_WORLD" then
    -- kurz warten, bis Bots/Session bereit sind, dann Bridge begruessen
    MB.After(2, MB.Hello)
  end
end)
