--- chatmarker.lua — capture selected text from anywhere on the mac.
---
--- Why: you can't install an extension into the Claude desktop app,
--- so there's no marker there. Instead — a global hotkey:
--- select text → press it → the chunk flies into the same database as the browser
--- highlights, tagged with which app and window it came from.
---
--- Hotkeys (⌃⌥⌘ — control+option+command):
---   ⌃⌥⌘1  wording (yellow)
---   ⌃⌥⌘2  idea (green)
---   ⌃⌥⌘3  fact / method (blue)
---   ⌃⌥⌘4  debatable / come back to it (red)
---   ⌃⌥⌘N  capture and write a note right away
---   ⌃⌥⌘O  open the database folder
---
--- Why ⌃⌥⌘ and not something shorter: Alt+1…4 are already taken by the browser
--- marker — it catches them on the page. Shorten these hotkeys to Alt+digit and
--- they'll stop reaching the marker in the browser, and something will break in
--- a way nobody can explain. Three keys is a deliberate minimum. If you change
--- them, pick a combination that's free in both the browser and the system.

local M = {}

local HOME = os.getenv("HOME")
local APP_HOME = HOME .. "/.chatmarker"

--- The library root in Google Drive. install.sh writes the path into root.txt,
--- because on Drive it's long and contains an email address.
local function libraryRoot()
  local f = io.open(APP_HOME .. "/root.txt", "r")
  if f then
    local p = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
    if p ~= "" then return p end
  end
  -- fallback if the file isn't there: find it ourselves
  local out = hs.execute([[ls -d "$HOME/Library/CloudStorage/GoogleDrive-"*/"My Drive/AI Highlights" 2>/dev/null | head -1]])
  out = (out or ""):gsub("%s+$", "")
  if out ~= "" then return out end
  return HOME .. "/AI Highlights"
end

local ROOT = libraryRoot()
local INBOX = ROOT .. "/00 Inbox"
local JSON_FILE = INBOX .. "/desktop.json"
local MD_FILE = ROOT .. "/04 Drafts/Captured from desktop.md"

local COLORS = {
  ["1"] = { id = "yellow", label = "wording" },
  ["2"] = { id = "green",  label = "idea" },
  ["3"] = { id = "blue",   label = "fact/method" },
  ["4"] = { id = "red",    label = "debatable/todo" },
}

local function ensureVault()
  hs.execute("mkdir -p '" .. INBOX .. "' '" .. ROOT .. "/04 Drafts'")
end

--- Rebuild the library in the background so the capture doesn't hang.
local function rebuild()
  local py = APP_HOME .. "/venv/bin/python"
  if not hs.fs.attributes(py) then return end
  hs.task.new(py, nil, { APP_HOME .. "/library.py", "--no-ingest" }):start()
end

local function readJson()
  local f = io.open(JSON_FILE, "r")
  if not f then return { highlights = {} } end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return { highlights = {} } end
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.highlights) ~= "table" then
    return { highlights = {} }
  end
  return data
end

local function writeJson(data)
  local f = io.open(JSON_FILE, "w")
  if not f then
    hs.alert.show("Couldn't write " .. JSON_FILE)
    return false
  end
  f:write(hs.json.encode(data, true))
  f:close()
  return true
end

local function appendMd(entry)
  local f = io.open(MD_FILE, "a")
  if not f then return end
  f:write(string.format(
    "\n> %s\n\n`%s` · %s · %s\n%s\n---\n",
    entry.text:gsub("\n", "\n> "),
    entry.colorLabel,
    entry.title,
    entry.createdAt:sub(1, 16):gsub("T", " "),
    entry.note ~= "" and ("\n**Note:** " .. entry.note .. "\n") or ""
  ))
  f:close()
end

--- Copies the selection without wrecking the user's clipboard.
local function grabSelection()
  local before = hs.pasteboard.getContents()
  local marker = "\0__chatmarker__" .. tostring(hs.timer.absoluteTime())
  hs.pasteboard.setContents(marker)

  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  -- wait for the app to put the text on the clipboard (up to ~0.6 sec)
  local text = nil
  for _ = 1, 12 do
    hs.timer.usleep(50000)
    local now = hs.pasteboard.getContents()
    if now and now ~= marker then
      text = now
      break
    end
  end

  hs.timer.doAfter(0.15, function()
    hs.pasteboard.setContents(before or "")
  end)

  return text
end

local function iso8601()
  -- local time in the format the rest of the system understands
  return os.date("!%Y-%m-%dT%H:%M:%S") .. ".000Z"
end

local function uid()
  return string.format("hs%x%x", math.random(0, 0xffffff), math.floor(hs.timer.absoluteTime() % 0xffff))
end

--- Encodes a path for a file:// link. Works byte by byte, so non-ASCII
--- characters in the file name are encoded correctly (one UTF-8 byte at a time).
local function encodePath(p)
  return (p:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Preview writes the page number straight into the window title:
---   "REPORT.pdf – Page 10 of 111"
--- We parse the number and ask Preview for the file path over AppleScript.
--- That gives a link "to the spot" for desktop highlights — file://…#page=N,
--- and the dashboard opens it in the browser on exactly the right page.
local function placeLink(app, winTitle)
  local page = winTitle:match("[Pp]age (%d+)")
  if not page then return "", nil end

  local url = ""
  if app and app:bundleID() == "com.apple.Preview" then
    local ok, path = pcall(function()
      local good, result = hs.osascript.applescript(
        'tell application "Preview" to get path of front document')
      return good and result or nil
    end)
    if ok and type(path) == "string" and path ~= "" then
      url = "file://" .. encodePath(path) .. "#page=" .. page
    end
  end
  return url, tonumber(page)
end

--- Two presses in a row on the same selection are almost always an accident,
--- not a wish to save it twice.
local lastCapture = { text = nil, app = nil, at = 0 }

local function capture(colorId, colorLabel, withNote)
  local text = grabSelection()
  if not text or text:gsub("%s", "") == "" then
    hs.alert.show("Select some text first")
    return
  end

  local app = hs.application.frontmostApplication()
  local appName = app and app:name() or "unknown"

  local nowSec = hs.timer.secondsSinceEpoch()
  if text == lastCapture.text and appName == lastCapture.app
     and (nowSec - lastCapture.at) < 3 then
    hs.alert.show("Already saved", 0.6)
    return
  end
  lastCapture = { text = text, app = appName, at = nowSec }

  local win = hs.window.focusedWindow()
  local winTitle = win and win:title() or ""
  local title = winTitle ~= "" and (appName .. " — " .. winTitle) or appName
  local url, page = placeLink(app, winTitle)

  local note = ""
  if withNote then
    -- hs.dialog activates Hammerspoon: if the console is open it'll jump out
    -- over the whole screen. Hide it beforehand.
    if hs.console.hswindow() then hs.closeConsole() end
    local button, input = hs.dialog.textPrompt(
      "Note on the highlight",
      text:sub(1, 160) .. (#text > 160 and "…" or "") .. "\n\nA word with a hash, say #hiring, files the highlight under a topic.",
      "", "Save", "No note"
    )
    if button == "Save" then note = input or "" end
  end

  ensureVault()
  local entry = {
    id = uid(),
    conv = "desktop::" .. appName,
    site = "desktop",
    url = url,
    page = page,
    title = title,
    color = colorId,
    colorLabel = colorLabel,
    note = note,
    text = text,
    createdAt = iso8601(),
  }

  local db = readJson()
  table.insert(db.highlights, entry)
  if writeJson(db) then
    appendMd(entry)
    rebuild()
    hs.alert.show("✎ " .. colorLabel .. " · " .. appName, 0.8)
  end
end

--- Physical key codes (ANSI). Letter names break on a non-English layout:
--- hs.keycode can't find 'n' on a non-Latin layout, spits warnings and hangs the
--- hotkey on whatever letter sits in that spot. Codes don't depend on the layout.
local KEYCODES = { ["1"] = 18, ["2"] = 19, ["3"] = 20, ["4"] = 21, n = 45, o = 31 }

function M.start()
  math.randomseed(os.time())
  ensureVault()

  -- Without Accessibility the hotkeys silently do nothing — no sound, no banner.
  -- We check right away and ask with the system dialog, so nobody has to guess.
  if not hs.accessibilityState(true) then
    hs.alert.show(
      "Chat Marker: give Hammerspoon Accessibility\n" ..
      "Settings → Privacy & Security → Accessibility.\n" ..
      "Without it the capture hotkeys don't work.", 6)
  end

  local mods = { "ctrl", "alt", "cmd" }
  for key, c in pairs(COLORS) do
    hs.hotkey.bind(mods, KEYCODES[key], function() capture(c.id, c.label, false) end)
  end
  hs.hotkey.bind(mods, KEYCODES.n, function() capture("yellow", "wording", true) end)
  hs.hotkey.bind(mods, KEYCODES.o, function() hs.execute("open '" .. ROOT .. "'") end)

  print("[chatmarker] hotkeys bound, library: " .. ROOT)
end

M.start()
return M
