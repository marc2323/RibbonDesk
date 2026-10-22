-- Paneru configuration with a native settings companion.
-- Adjust speed and gap from the Paneru menu-bar icon.
-- All window shortcuts use Control + Option.
local home = os.getenv("HOME")
local loaded, preferences = pcall(dofile, home .. "/.config/paneru/preferences.lua")
if not loaded or type(preferences) ~= "table" then preferences = {} end
local speed = tonumber(preferences.speed) or 0.65
if speed ~= speed then speed = 0.65 end
speed = math.max(0.2, math.min(1.5, speed))
local gap = tonumber(preferences.gap) or 6
if gap ~= gap then gap = 6 end
gap = math.floor(math.max(0, math.min(24, gap)) / 2 + 0.5) * 2
local focus_follows_mouse = preferences.focus_follows_mouse ~= false

local config = {
  ["default_workspaces"] = 1,
  ["options"] = {
    ["preset_column_widths"] = { 0.5, 1.0 },
    ["window_resize_cycle"] = true,
    ["focus_follows_mouse"] = focus_follows_mouse,
    ["preserve_scroll_until_click"] = true,
    ["mouse_follows_focus"] = false,
    ["auto_center"] = false,
    ["animation_speed"] = 10000.0,
    ["sliver_width"] = 5,
    ["sliver_height"] = 1.0,
    ["virtual_workspace_animations"] = false,
    ["create_virtual_workspace_automatically"] = false,
  },
  ["padding"] = {
    ["top"] = 0,
    ["bottom"] = 0,
    ["left"] = 0,
    ["right"] = 0,
  },
  ["swipe"] = {
    ["sensitivity"] = 0.65,
    ["deceleration"] = 10.0,
    ["continuous"] = false,
    ["gesture"] = {
      ["fingers_count"] = 3,
      ["direction"] = "Natural",
      ["vertical"] = false,
    },
    ["scroll"] = {
      ["modifier"] = "ctrl + alt",
    },
  },
  ["windows"] = {
    ["default"] = {
      ["title"] = ".*",
      ["horizontal_padding"] = 3,
      ["vertical_padding"] = 0,
    },
  },
  ["decorations"] = {
    ["workspace_menu_status"] = false,
    ["workspace_popup_status"] = false,
    ["menu"] = {
      ["descriptor"] = {
        ["style"] = "hidden",
        ["text"] = "Paneru",
      },
    },
  },
  ["restore"] = {
    ["enabled"] = true,
    ["startup_grace_ms"] = 2000,
    ["missing_windows"] = "ignore",
  },
}
config.swipe.sensitivity = speed
config.windows.default.horizontal_padding = math.floor(gap / 2)
config.windows.preferences = {
    title = ".*", bundle_id = "local.paneru.preferences", floating = true,
}
paneru.setup(config)

-- Keep every global shortcut on the same Control + Option modifier.
paneru.bind("ctrl + alt - h", "window focus west")
paneru.bind("ctrl + alt - leftarrow", "window focus west")
paneru.bind("ctrl + alt - l", "window focus east")
paneru.bind("ctrl + alt - rightarrow", "window focus east")
paneru.bind("ctrl + alt - j", "window swap west")
paneru.bind("ctrl + alt - k", "window swap east")
paneru.bind("ctrl + alt - home", "window focus first")
paneru.bind("ctrl + alt - end", "window focus last")
paneru.bind("ctrl + alt - t", "window manage")
paneru.bind("ctrl + alt - q", "quit")
paneru.bind("ctrl + alt - s", function()
    paneru.exec("/usr/bin/open", {"-a", home .. "/Applications/Paneru Settings.app"})
end)

-- Exact width commands use the usable viewport, including Dock reservation.
local calibrated = {}
local function focused_window(ws)
    local id = ws:focused()
    if not id then return nil end
    local window = ws:window(id)
    if not window or window.floating or not window.managed then return nil end
    return id, window
end
local function set_width(ws, ratio)
    local id = focused_window(ws)
    if not id then return ws end
    calibrated[id] = true
    return ws:width(id, ratio)
end
local function toggle_width(ws)
    local id, window = focused_window(ws)
    if not id then return ws end
    local display = ws:display_of(id)
    if not display or not window.frame then return ws end
    return set_width(ws, window.frame.width > display.width * 0.75 and 0.5 or 1.0)
end
paneru.bind("ctrl + alt - r", toggle_width)
paneru.bind("ctrl + alt - 2", function(ws) return set_width(ws, 0.5) end)
paneru.bind("ctrl + alt - 0", function(ws) return set_width(ws, 1.0) end)
paneru.bind("ctrl + alt - f", function(ws) return set_width(ws, 1.0) end)

-- Normalize new columns and explicit gap refreshes. Ordinary focus changes
-- must never resize columns or alter a manually scrolled viewport.
local function calibrate_half(_, ws)
    local id, window = focused_window(ws)
    if not id or calibrated[id] then return ws end
    local display = ws:display_of(id)
    if not display or not window.frame then return ws end
    calibrated[id] = true
    return ws:width(id, window.frame.width <= display.width * 0.75 and 0.5 or 1.0)
end
paneru.on("window_focused", function(event, ws)
    if paneru.state.get("paneru.calibrating_layout") == true then
        return calibrate_half(event, ws)
    end
    return ws
end)
paneru.on("window_spawned", function(event, ws)
    if event.managed and not event.floating and event.window_id == ws:focused() then
        return calibrate_half(event, ws)
    end
    return ws
end)
paneru.on("window_destroyed", function(event) calibrated[event.window_id] = nil end)
