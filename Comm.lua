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
  SendAddonMessage(MB.PREFIX, msg, MB.channel, target)
end

function MB.Hello()
  MB.Send("HELLO", MB.PROTO)
end

-- Playerbot-Kommando an EINEN Bot (Whisper) -- Steuerung in v1
function MB.BotCmd(name, cmd)
  if not name or not cmd then return end
  SendChatMessage(cmd, "WHISPER", nil, name)
end

-- .-Kommando an den Server (Verwaltung). Der Server fuehrt fuehrende "." als Befehl aus.
function MB.Dot(cmd)
  SendChatMessage(cmd, "SAY")
end

-- ---------------------------------------------------------------- Reads (Bridge)
function MB.ReqRoster() MB.Send("GET", "ROSTER") end
function MB.ReqStates() MB.Send("GET", "STATES") end
function MB.ReqInventory(name) if name then MB.Send("GET", "INVENTORY~" .. name .. "~" .. MB.NewToken("inv")) end end
function MB.ReqQuests(name) if name then MB.Send("GET", "QUESTS~ALL~" .. name .. "~" .. MB.NewToken("q")) end end

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
    local name, combat, noncombat = strsplit("~", rest, 3)
    if name then
      MB.states[name] = { combat = combat or "", noncombat = noncombat or "" }
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
