--!nonstrict
-- mediaGrabber reader — the headless [[service]] entry.
--
-- Every tick: read each <drive>.json under status_dir, decide what it means
-- now (a "ripping" record with a dead pid is interrupted), and publish the
-- lot JSON-encoded on noctalia.state as "mediagrab.snapshot". The bar and the
-- panel only ever watch that key.
--
-- Plain file reads, no subprocess: once a second while a rip runs, every
-- five seconds otherwise. The directory is listed every tenth read, which
-- is how a second drive turns up without a setting.

local ACTIVE = { detecting = true, waiting = true, ripping = true, shipping = true }

local drives = {}
local lastList = -1000000
local lastKey = nil

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function now()
  return tonumber(noctalia.formatTime("%s")) or os.time()
end

local function statusDir()
  local dir = trim(noctalia.getConfig("status_dir"))
  return dir ~= "" and noctalia.expandPath(dir) or "/var/lib/mediagrabber/status"
end

local function bootId()
  return trim(noctalia.readFile("/proc/sys/kernel/random/boot_id"))
end

local function listDrives(dir)
  local found = {}
  for _, name in noctalia.listDir(dir) or {} do
    local drive = name:match("^(.+)%.json$")
    if drive then
      table.insert(found, drive)
    end
  end
  table.sort(found)
  return found
end

-- One record, or nil when unreadable (caught mid-replace: the next tick has it).
local function readRecord(dir, drive, boot)
  local ok, doc = pcall(noctalia.json.decode, noctalia.readFile(`{dir}/{drive}.json`) or "")
  if not ok or type(doc) ~= "table" or type(doc.phase) ~= "string" then
    return nil
  end
  doc.drive = doc.drive ~= "" and doc.drive or drive
  doc.live = ACTIVE[doc.phase] == true
  if doc.live then
    local alive = type(doc.pid) == "number" and noctalia.fileExists(`/proc/{doc.pid}`)
    if doc.boot ~= boot or not alive then
      doc.message = doc.phase == "waiting" and "" or doc.step or ""
      doc.phase = "interrupted"
      doc.live = false
      doc.progress = nil
    end
  end
  return doc
end

function poll()
  local dir = statusDir()
  local stamp = now()
  if stamp - lastList >= 30 or #drives == 0 and stamp - lastList >= 10 then
    drives = listDrives(dir)
    lastList = stamp
  end

  local boot = bootId()
  local records = {}
  local live = 0
  for _, drive in drives do
    local rec = readRecord(dir, drive, boot)
    if rec then
      table.insert(records, rec)
      if rec.live then
        live += 1
      end
    end
  end
  -- Live runs first, then the most recently updated.
  table.sort(records, function(a, b)
    if a.live ~= b.live then
      return a.live
    end
    return (a.updated or 0) > (b.updated or 0)
  end)

  noctalia.setUpdateInterval(live > 0 and 1000 or 5000)

  local snapshot = { drives = records, live = live, dir = dir }
  local key = noctalia.json.encode(snapshot)
  if key ~= lastKey then
    lastKey = key
    noctalia.state.set("mediagrab.snapshot", key)
  end
end

function onConfigChanged()
  lastList = -1000000
  poll()
end

function onIpc(event)
  if event == "refresh" then
    lastList = -1000000
    poll()
  end
end

function update()
  poll()
end

-- The bar's middle click and the panel opening. Any value means "now": a
-- replay of the last one at startup only costs one extra read.
noctalia.state.watch("mediagrab.cmd", function(_)
  lastList = -1000000
  poll()
end)
