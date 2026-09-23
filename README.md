# MeineBots

Ein schlankes World-of-Warcraft-3.3.5a-Addon zum Verwalten von **Playerbots** — eine
Liste aller Bots deiner Gruppe, ein Detailbereich (Inventar / Quests / Strategien) und
ein Verwaltungs-Tab, um Bots zu holen und die Zufalls-Flotte zu steuern.

Bewusst einfach: **die wichtigen Sachen sind direkt da**, kein Menü-Graben.

> Ersatz/Alternative zum `MultiBot-Chatless`-Addon — nutzt aber dieselbe serverseitige
> Bridge (`mod-multibot-bridge`, Prefix `MBOT`). MultiBot kann parallel laufen oder weg.

## Bedienung

- `/mb` (oder `/meinebots`) öffnet/schließt das Fenster. Am Titel verschiebbar.
- **Meine Bots:** links die Liste (HP/Mana, Rolle, aktive Strategien mit Grind-Warnung),
  rechts das Detail. Klick wählt einen Bot, **Rechtsklick** öffnet ein Aktionsmenü
  (Folgen, Rolle, Grind, Reset, Entlassen …).
- **Verwaltung:** Altbots holen/entlassen (`.bot add` / `.bot remove`), Flotte neu würfeln
  (`.playerbots rndbot init`).

## Architektur

```
Client (dieses Addon, Lua)
  └─ Addon-Nachrichten  "MBOT\t<opcode>~<payload>"  (LANG_ADDON)
       ↕
Server (mod-multibot-bridge, C++)  +  mod-playerbots
```

- **Lesen (chatlos, über die Bridge):** `GET~ROSTER`, `GET~STATES`, `GET~INVENTORY`, `GET~QUESTS`.
- **Steuern (v1):** Playerbot-Whisper-Kommandos an den Bot (`co +tank`, `nc +grind`,
  `follow`, `stay`, `attack`, `sell vendor`, `repair`) und `.`-Kommandos an den Server
  (`.bot add/remove`, `.playerbots rndbot init`).

Der Draht-Kontrakt der Bridge (Auszug):

| Request | Antwort |
|---|---|
| `GET~ROSTER` | `ROSTER` = `name,cls,lvl,map,alive,hp,mana;…` |
| `GET~STATES` | pro Bot `STATE` = `name~combat~noncombat` |
| `GET~INVENTORY~<bot>~<token>` | `INV_SUMMARY` / `INV_ITEM` (Item-Link) / `INV_END` |
| `GET~QUESTS~ALL~<bot>~<token>` | `QUESTS_BEGIN` / `QUESTS_ITEM` / `QUESTS_END` |

## Stand (v0.1.0)

**Funktioniert:** Verbindung/Handshake, Live-Liste (Roster + Strategien + Grind-Warnung),
Inventar mit echten Item-Icons + Tooltips, Quest-Liste, Rollen/Grind/Follow-Stopp-Angriff/
Vendor/Reparieren, Bot-Rechtsklick, Altbots holen/entlassen, Flotte neu würfeln.

**Phase 2 (braucht kleine Bridge-Ergänzungen oder ist noch nicht verdrahtet):**
- Item-Aktionen Handel/Verkauf/Zerstören (`RUN~ITEM_ACTION` / `RUN~TRADE`)
- Quest-Titel/Ziele, Abgeben, Abbrechen, Teilen (`QUEST_INFO` / `QUEST_TURNIN` / neu)
- Formation / Loot / Raid-Marker / Group-Roll (`RUN~FORMATION` / `RUN~LOOT` / `RUN~RTI` / `RUN~GROUP_ROLL`)
- Flotten-Config (Größe/Fraktion/Gilde) — sind `.conf`-Werte, wirken erst nach Neustart

> **Hinweis:** Noch nicht im Client getestet. Die genauen Playerbot-Kommando-Tokens
> (`co`/`nc`/`sell vendor`/…) und der Sende-Kanal (`WHISPER`) können je nach
> Playerbots-Build minimal abweichen und werden beim ersten Live-Test feinjustiert.

## Dateien

- `MeineBots.toc` — Addon-Manifest
- `Comm.lua` — Bridge-Protokoll (MBOT), Kommando-Helfer, Event-Bus
- `UI.lua` — Fenster, Liste, Detail, Verwaltung, Kontextmenüs, `/mb`

## Lizenz

MIT — siehe [LICENSE](LICENSE).
