--!nonstrict
-- mediaGrabber bar widget — the [[widget]] entry.
--
-- One glyph for the drive that matters most (a live rip, else the latest
-- outcome), with the percentage beside it while something is ripping.
-- Everything arrives on noctalia.state from the reader service.
--
--   left click   — open the panel
--   middle click — re-read the status files now

local snapshot = nil

local KIND_GLYPH = { cd = "disc", dvd = "movie", data = "archive" }

local function now()
  return tonumber(noctalia.formatTime("%s")) or os.time()
end

local function recent(rec)
  local hours = tonumber(noctalia.getConfig("recent_hours")) or 12
  return rec.updated and now() - rec.updated < hours * 3600
end

-- glyph, colour, text beside it (or nil)
local function look(rec)
  if not rec then
    return "disc", "on_surface/0.5", nil
  end
  local phase = rec.phase
  if phase == "ripping" then
    local pct = type(rec.progress) == "number" and `{math.floor(rec.progress * 100)}%` or nil
    return KIND_GLYPH[rec.kind] or "disc", "primary", pct
  elseif phase == "detecting" or phase == "shipping" then
    return phase == "shipping" and "upload" or "disc", "primary", nil
  elseif phase == "waiting" then
    return "message-question", "secondary", "?"
  elseif not recent(rec) then
    return "disc", "on_surface/0.5", nil
  elseif phase == "failed" or phase == "interrupted" then
    return "alert-triangle", "error", nil
  elseif phase == "done" then
    return "circle-check", "primary", nil
  end
  return "disc", "secondary", nil
end

local function render()
  local rec = snapshot and snapshot.drives and snapshot.drives[1] or nil
  local glyph, color, text = look(rec)

  local idle = not rec or (not rec.live and not recent(rec))
  barWidget.setVisible(not (idle and noctalia.getConfig("hide_when_idle") == true))

  local children = { ui.glyph({ name = glyph, size = 14, color = color }) }
  if text and not barWidget.isVertical() then
    table.insert(children, ui.label({ text = text, fontWeight = "bold", color = color }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  local rows = {}
  if not rec then
    table.insert(rows, { key = noctalia.tr("tooltip.state"), value = noctalia.tr("panel.empty") })
  else
    table.insert(rows, { key = noctalia.tr("tooltip.state"), value = noctalia.tr("phase." .. rec.phase) })
    if rec.disc and rec.disc ~= "" then
      table.insert(rows, { key = noctalia.tr("tooltip.disc"), value = rec.disc })
    end
    if rec.live and rec.step and rec.step ~= "" then
      table.insert(rows, { key = noctalia.tr("tooltip.step"), value = rec.step })
    end
  end
  table.insert(rows, { key = noctalia.tr("tooltip.click"), value = noctalia.tr("tooltip.click-value") })
  barWidget.setTooltip(rows)
end

noctalia.state.watch("mediagrab.snapshot", function(encoded)
  snapshot = encoded and encoded ~= "" and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  -- Once a minute is enough to let a finished run's colour fade.
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel("andrew/mediagrab:panel")
end

function onMiddleClick()
  noctalia.state.set("mediagrab.cmd", tostring(noctalia.nowMs()))
end
