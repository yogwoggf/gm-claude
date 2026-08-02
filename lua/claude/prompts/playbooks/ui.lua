-- Playbook: HUDs, VGUI/Derma panels, DHTML. Loaded only when the planner tags a
-- task kind = "ui".

return [====[
# Playbook: Building UI

All UI is CLIENT-ONLY — build it with `run_client_lua`. UI code in `run_server_lua` silently does nothing.

## Pick the right one
1. **HUDPaint + `surface`/`draw`** — passive overlays, counters, bars, markers. No panel, no input, redrawn every frame.
2. **VGUI/Derma** — windows, buttons, lists, anything the player clicks.
3. **DHTML** — complex/animated layouts. Use `[==[ ... ]==]` for the HTML string, and size the DFrame to fit the content.

## HUDPaint
Runs every frame, so keep it cheap: no `Material()`, no table construction, no `ents.FindBy*` inside the hook — build those once outside it. Use `ScrW()`/`ScrH()` for positioning so it works at any resolution; never hardcode pixel coordinates for a 1920x1080 screen. `draw.SimpleText`, `draw.RoundedBox`, and `surface.DrawRect` cover most needs.

## Derma
- Create with `vgui.Create("DFrame")`, then `SetSize`, `Center`, `SetTitle`, `MakePopup` (required for mouse input).
- Lay out with `Dock(FILL/TOP/LEFT/...)` plus `DockMargin`/`DockPadding` rather than manual `SetPos` — it survives resizing.
- Custom look: override `frame.Paint = function(self, w, h) ... end`.
- **Only ever create ONE.** Store it and close the old one first, or every re-run stacks another frame on screen:
  ```lua
  if IsValid(MyFrame) then MyFrame:Remove() end
  MyFrame = vgui.Create("DFrame")
  ```

Non-blocking UI (passive HUD, marquees) — so it doesn't steal the player's mouse and keyboard:
```lua
frame:SetKeyboardInputEnabled(false)
frame:SetMouseInputEnabled(false)
frame:KillFocus()
frame:SetDraggable(false)
frame:ShowCloseButton(false)
```

## DHTML <-> Lua
`DHTML:AddFunction(namespace, name, fn)` exposes a Lua function to JavaScript; `DHTML:RunJavascript(code)` goes the other way.

## Server -> client data
The client cannot read server state directly. Send it with a net message (`util.AddNetworkString` on the server first) or read a networked var off an entity. A HUD that shows a server-side number and never networks it will display nothing or a stale zero.

## Before you run it
- Client realm, and positioned with `ScrW()`/`ScrH()` rather than fixed pixels?
- Existing panel removed before creating a new one?
- `MakePopup()` if it needs clicks — or input disabled if it must not steal focus?
- `HUDPaint` free of per-frame allocations?
- Any server-side value it displays actually networked across?
]====]
