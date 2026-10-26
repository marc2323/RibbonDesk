-- RibbonDesk configuration with its native menu-bar app.
-- Adjust scrolling, gap, and the active window outline from the menu-bar icon.
-- All window shortcuts use Control + Option.
local home = os.getenv("HOME")
local loaded, preferences = pcall(dofile, home .. "/.config/paneru/preferences.lua")
if not loaded or type(preferences) ~= "table" then preferences = {} end
local behavior_loaded, app_behavior = pcall(dofile, home .. "/.config/paneru/app-behavior.lua")
if not behavior_loaded or type(app_behavior) ~= "table" then app_behavior = {} end
local speed = tonumber(preferences.speed) or 0.65
if speed ~= speed then speed = 0.65 end
speed = math.max(0.2, math.min(1.5, speed))
local function scroll_preference(key, default, lower, upper)
    local value = tonumber(preferences[key]) or default
    if value ~= value then value = default end
    return math.max(lower, math.min(upper, value))
end
local momentum = scroll_preference("momentum", 1.0, 0.0, 3.0)
local momentum_decay = scroll_preference("momentum_decay", 4.0, 1.0, 100.0)
local snap_speed = scroll_preference("snap_speed", 0.8, 0.0, 3.0)
local snap_visible = scroll_preference("snap_visible", 0.55, 0.25, 0.95)
local snap_animation = scroll_preference("snap_animation", 1.0, 0.2, 4.0)
local snap_exit_distance = scroll_preference("snap_exit_distance", 0.12, 0.0, 0.5)
local magnet_strength = scroll_preference("magnet_strength", 1.8, 0.2, 6.0)
local magnet_range = scroll_preference("magnet_range", 0.2, 0.03, 0.4)
local gap = tonumber(preferences.gap) or 6
if gap ~= gap then gap = 6 end
gap = math.floor(math.max(0, math.min(24, gap)) / 2 + 0.5) * 2
local focus_follows_mouse = preferences.focus_follows_mouse ~= false
local border_color = preferences.border_color
if type(border_color) ~= "string" or not border_color:match("^#%x%x%x%x%x%x$") then
    border_color = "#33879E"
end

local config = {
  ["default_workspaces"] = 1,
  ["options"] = {
    ["default_floating"] = true,
    ["preset_column_widths"] = { 0.5, 1.0 },
    ["window_resize_cycle"] = true,
    ["focus_follows_mouse"] = focus_follows_mouse,
    ["preserve_scroll_until_click"] = true,
    ["disabled_spaces"] = preferences.disabled_spaces or {},
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
    ["deceleration"] = momentum_decay,
    ["momentum"] = momentum,
    ["snap_speed"] = snap_speed,
    ["snap_visible"] = snap_visible,
    ["snap_animation"] = snap_animation,
    ["snap_full_width"] = preferences.snap_full_width ~= false,
    ["snap_half_width"] = preferences.snap_half_width ~= false,
    ["snap_back"] = preferences.snap_back == true,
    ["snap_exit_distance"] = snap_exit_distance,
    ["ribbon_overview"] = true,
    ["magnetic_snapping"] = preferences.magnetic_snapping == true,
    ["magnet_strength"] = magnet_strength,
    ["magnet_range"] = magnet_range,
    ["three_finger_paging"] = preferences.three_finger_paging ~= false,
    ["infinite_ribbon"] = preferences.infinite_ribbon == true,
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
    ["active"] = {
      ["border"] = {
        ["enabled"] = preferences.border_enabled ~= false,
        ["color"] = border_color,
        ["width"] = 2.0,
        ["opacity"] = 1.0,
        ["radius"] = "auto",
      },
    },
    ["workspace_menu_status"] = false,
    ["workspace_popup_status"] = false,
    ["menu"] = {
      ["descriptor"] = {
        ["style"] = "hidden",
        ["text"] = "RibbonDesk",
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
-- Each app has exactly one rule; leave floating out of the generic padding
-- rule so rule-table iteration order cannot override an app's saved choice.
for bundle, behavior in pairs(app_behavior) do
    if type(bundle) == "string" and bundle ~= "local.paneru.preferences" then
        config.windows["app:" .. bundle] = {
            title = ".*", bundle_id = bundle, floating = behavior ~= "ribbon",
        }
    end
end
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
paneru.bind("ctrl + alt - o", "overview show")
paneru.bind("ctrl + alt - s", function()
    paneru.exec("/usr/bin/open", {"-a", home .. "/Applications/RibbonDesk.app"})
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
