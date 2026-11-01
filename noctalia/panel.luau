--!nonstrict
-- mediaGrabber panel — the [[panel]] entry.
--
-- One card per drive, live rips first: what the disc is, the phase, the
-- step ("track 3 of 12", "0:41:10 of 1:52:33"), a progress bar with an
-- estimate of what is left, and — once the run is over — its outcome, the
-- same text the desktop notification carried. Buttons: the unit's journal
-- in a terminal, and Eject when nothing is running on that drive.

-- Must match height = … in plugin.toml: the root column's height is what
-- sizes the panel, and without it the scroll area grows instead of scrolling.
local PANEL_HEIGHT = 420

local snapshot = nil
local isOpen = false

local KIND_GLYPH = { cd = "disc", dvd = "movie", data = "archive" }
local PHASE_COLOR = {
  detecting = "primary",
  waiting = "secondary",
  ripping = "primary",
  shipping = "primary",
  done = "primary",
  failed = "error",
  interrupted = "error",
  note = "secondary",
}

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function now()
  return tonumber(noctalia.formatTime("%s")) or os.time()
end

local function duration(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 90 then
    return tr("time.seconds", { n = tostring(seconds) })
  elseif seconds < 5400 then
    return tr("time.minutes", { n = tostring(math.floor(seconds / 60 + 0.5)) })
  elseif seconds < 172800 then
    return tr("time.hours", { n = string.format("%.1f", seconds / 3600) })
  end
  return tr("time.days", { n = tostring(math.floor(seconds / 86400)) })
end

-- "12 min left": the rate so far in this phase, carried to the end. Only once
-- there is enough of it to mean something.
local function remaining(rec)
  local p = rec.progress
  if type(p) ~= "number" or p < 0.03 or p >= 1 or type(rec.since) ~= "number" then
    return nil
  end
  local spent = now() - rec.since
  if spent < 20 then
    return nil
  end
  return tr("card.left", { value = duration(spent * (1 - p) / p) })
end

-- Only a /dev/srN-shaped name is ever handed to a command.
local function safeDrive(rec)
  local d = tostring(rec.drive or "")
  return d:match("^[%w_-]+$") and d or nil
end

-- ── Sections ─────────────────────────────────────────────────────────────────

local function header()
  local live = snapshot and snapshot.live or 0
  local subtitle = live > 0 and tr("panel.live", { n = tostring(live) }) or tr("panel.idle")
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "disc", size = 20, color = live > 0 and "primary" or "on_surface/0.7" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 12, color = live > 0 and "primary" or "on_surface/0.65" }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      onClick = "onRefresh",
    }),
  })
end

local function card(rec)
  local color = PHASE_COLOR[rec.phase] or "on_surface"
  local drive = safeDrive(rec)
  local kind = rec.kind ~= nil and rec.kind ~= "" and rec.kind or "unknown"
  local title = rec.disc ~= nil and rec.disc ~= "" and rec.disc or tr("kind." .. kind)
  local phaseText = tr("phase." .. rec.phase)

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = KIND_GLYPH[rec.kind] or "disc", size = 16, color = color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = title, fontWeight = "bold", fontSize = 13, maxLines = 2 }),
        ui.label({
          text = `{phaseText} · {rec.drive}`,
          fontSize = 11,
          color = color,
          maxLines = 1,
        }),
      }),
      ui.button({
        glyph = "file-text",
        variant = "ghost",
        controlSize = "sm",
        enabled = drive ~= nil,
        tooltip = tr("card.log"),
        onClick = function()
          noctalia.runInTerminal(`journalctl -n 200 -f -u mediagrab@{drive}.service`)
        end,
      }),
      ui.button({
        glyph = "player-eject",
        variant = "ghost",
        controlSize = "sm",
        enabled = drive ~= nil and not rec.live,
        tooltip = rec.live and tr("card.eject-busy") or tr("card.eject"),
        onClick = function()
          noctalia.runAsync(`eject /dev/{drive}`, function(result)
            if result.exitCode ~= 0 then
              noctalia.notifyError(tr("toast.title"), noctalia.string.trim(result.stderr or "") ~= ""
                and noctalia.string.trim(result.stderr) or tr("toast.eject-failed"))
            end
          end, 20000)
        end,
      }),
    }),
  }

  if rec.live and rec.step and rec.step ~= "" then
    table.insert(children, ui.label({ text = rec.step, fontSize = 12, maxLines = 4 }))
  end

  if rec.live and type(rec.progress) == "number" then
    local pct = math.floor(rec.progress * 100)
    local left = remaining(rec)
    table.insert(children, ui.progress({
      progress = rec.progress,
      height = 6,
      radius = 3,
      fill = "primary",
      track = "on_surface/0.08",
    }))
    table.insert(children, ui.label({
      text = left and `{pct}% · {left}` or `{pct}%`,
      fontSize = 11,
      color = "on_surface/0.65",
    }))
  end

  if rec.phase == "waiting" then
    table.insert(children, ui.label({ text = tr("card.waiting"), fontSize = 11, color = "secondary", maxLines = 2 }))
  end

  if not rec.live then
    local text = rec.message or ""
    if rec.phase == "interrupted" then
      text = text ~= "" and tr("card.interrupted-at", { step = text }) or tr("card.interrupted")
    end
    if text ~= "" then
      local tone = (rec.phase == "failed" or rec.phase == "interrupted") and "error"
        or (rec.phase == "done" and "primary" or "secondary")
      table.insert(children, ui.column({ padding = 8, fill = `{tone}/0.12`, radius = 8 }, {
        ui.label({ text = text, fontSize = 11, maxLines = 6 }),
      }))
    end
  end

  local when
  if rec.live and type(rec.started) == "number" then
    when = tr("card.running-for", { value = duration(now() - rec.started) })
  elseif type(rec.updated) == "number" then
    when = tr("card.ended", { value = duration(now() - rec.updated) })
  end
  if when then
    table.insert(children, ui.label({ text = when, fontSize = 11, color = "on_surface/0.55" }))
  end

  return ui.column({
    key = `drive-{rec.drive}`,
    gap = 6,
    padding = 10,
    fill = "surface_variant/0.5",
    radius = 8,
  }, children)
end

local function cards()
  local rows = {}
  for _, rec in (snapshot and snapshot.drives or {}) do
    table.insert(rows, card(rec))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({
      text = tr("panel.empty-detail", { dir = snapshot and snapshot.dir or "" }),
      fontSize = 12,
      color = "on_surface/0.6",
      maxLines = 4,
    }))
  end
  return ui.scroll({ gap = 8, flexGrow = 1 }, rows)
end

local function render()
  if not isOpen then
    return
  end
  panel.render(ui.column({ gap = 10, padding = 14, height = PANEL_HEIGHT }, { header(), cards() }))
end

-- ── Lifecycle & callbacks ────────────────────────────────────────────────────

noctalia.state.watch("mediagrab.snapshot", function(encoded)
  snapshot = encoded and encoded ~= "" and noctalia.json.decode(encoded) or nil
  render()
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("mediagrab.snapshot")
  snapshot = encoded and encoded ~= "" and noctalia.json.decode(encoded) or nil
  render()
  noctalia.state.set("mediagrab.cmd", tostring(noctalia.nowMs()))
end

function onClose()
  isOpen = false
end

function onRefresh()
  noctalia.state.set("mediagrab.cmd", tostring(noctalia.nowMs()))
end
