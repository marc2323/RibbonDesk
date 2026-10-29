-- Exercise the actual configuration bridge without an engine or desktop actions.
local source = assert(arg[1], "pass paneru-init.lua")
local real_dofile = dofile
local preferences, configured, app_behavior
_G.dofile = function(path)
    if path:match("/preferences%.lua$") then return preferences end
    if path:match("/app%-behavior%.lua$") then return app_behavior or {} end
    return real_dofile(path)
end
_G.paneru = {
    setup = function(config) configured = config end,
    bind = function() end,
    on = function() end,
}
for _, sample in ipairs({
    { expected = 4.0 },
    { value = 8.5, expected = 8.5 },
    { value = 99, expected = 99.0 },
    { value = 999, expected = 100.0 },
    { value = 0, expected = 1.0 },
    { value = 0/0, expected = 4.0 },
    { value = "invalid", expected = 4.0 },
}) do
    preferences = { speed = 0.55, momentum = 2.2, momentum_decay = sample.value }
    real_dofile(source)
    assert(configured.swipe.deceleration == sample.expected)
    assert(configured.swipe.momentum == 2.2, "decay must not overwrite momentum")
    assert(configured.swipe.sensitivity == 0.55, "decay must not overwrite drag speed")
end
print("Scroll configuration: decay reaches the engine independently of momentum; migration and bounds passed.")

preferences = { snap_animation = 2.5, snap_full_width = false, snap_half_width = false, snap_back = true, snap_exit_distance = 0.3 }
real_dofile(source)
assert(configured.swipe.snap_animation == 2.5 and not configured.swipe.snap_full_width and not configured.swipe.snap_half_width)
assert(configured.swipe.snap_back and configured.swipe.snap_exit_distance == 0.3)
preferences = {}
real_dofile(source)
assert(configured.swipe.snap_animation == 1 and configured.swipe.snap_full_width and configured.swipe.snap_half_width)
assert(not configured.swipe.snap_back and configured.swipe.snap_exit_distance == 0.12)
preferences = { snap_animation = 0/0, snap_exit_distance = 99 }
real_dofile(source)
assert(configured.swipe.snap_animation == 1 and configured.swipe.snap_exit_distance == 0.5)
print("Snap configuration: animation, window sizes, exit behavior, defaults and bounds passed.")

preferences = {}
real_dofile(source)
assert(configured.swipe.three_finger_paging)
preferences = { three_finger_paging = false }
real_dofile(source)
assert(not configured.swipe.three_finger_paging)
print("Three-finger paging configuration: enabled default and explicit free-scroll opt-out passed.")

preferences = {}
real_dofile(source)
assert(not configured.swipe.magnetic_snapping)
assert(configured.swipe.magnet_strength == 1.8 and configured.swipe.magnet_range == 0.2)
preferences = { magnetic_snapping = true, magnet_strength = 3.4, magnet_range = 0.28 }
real_dofile(source)
assert(configured.swipe.magnetic_snapping and configured.swipe.three_finger_paging)
assert(configured.swipe.magnet_strength == 3.4 and configured.swipe.magnet_range == 0.28)
preferences = { magnet_strength = 0/0, magnet_range = 99 }
real_dofile(source)
assert(configured.swipe.magnet_strength == 1.8 and configured.swipe.magnet_range == 0.4)
preferences = { magnet_strength = -1, magnet_range = -1 }
real_dofile(source)
assert(configured.swipe.magnet_strength == 0.2 and configured.swipe.magnet_range == 0.03)
print("Magnetic snapping configuration: opt-in mode, strength, range, defaults and bounds passed.")

for _, value in ipairs({ false, true, "true", 1 }) do
    preferences = { infinite_ribbon = value }
    real_dofile(source)
    assert(configured.swipe.infinite_ribbon == (value == true))
end
preferences = {}
real_dofile(source)
assert(not configured.swipe.infinite_ribbon)
print("Infinite ribbon configuration: disabled default and explicit on/off toggle passed.")

preferences = {}
real_dofile(source)
assert(configured.options.floating_follows_ribbon and configured.swipe.haptics)
preferences = { floating_follows_ribbon = false, trackpad_haptics = false }
real_dofile(source)
assert(not configured.options.floating_follows_ribbon and not configured.swipe.haptics)
assert(#configured.options.preset_column_widths == 4)
assert(math.abs(configured.options.preset_column_widths[1] - 1 / 3) < 1e-9)
assert(math.abs(configured.options.preset_column_widths[3] - 2 / 3) < 1e-9)
print("Floating, haptics and width presets: defaults, opt-outs and thirds passed.")

app_behavior = {
    ["com.example.notes"] = { behavior = "ribbon", width = 0.3333 },
    ["com.example.term"] = { behavior = "inherit", width = 0.6667 },
    ["com.example.bad"] = { behavior = "floating", width = 7 },
}
preferences = {}
real_dofile(source)
assert(configured.windows["app:com.example.notes"].floating == false)
assert(configured.windows["app:com.example.notes"].width == 0.3333)
assert(configured.windows["app:com.example.term"].floating == nil, "inherit keeps the global default")
assert(configured.windows["app:com.example.term"].width == 0.6667)
assert(configured.windows["app:com.example.bad"].floating == true)
assert(configured.windows["app:com.example.bad"].width == nil, "out-of-range widths are ignored")
print("Per-app widths: table entries, inherited behavior and bounds passed.")

app_behavior = { ["com.example.editor"] = "ribbon", ["com.example.chat"] = "floating", ["com.example.browser"] = "ask", ["local.paneru.preferences"] = "ribbon" }
real_dofile(source)
assert(configured.options.default_floating == true)
assert(configured.windows.default.floating == nil, "generic padding must not compete with app rules")
assert(configured.windows["app:com.example.editor"].floating == false)
assert(configured.windows["app:com.example.chat"].floating == true)
assert(configured.windows["app:com.example.browser"].floating == true, "ask windows float until accepted")
assert(configured.windows.preferences.floating == true)
assert(configured.restore.enabled)
print("App behavior configuration: floating default, app overrides, prompt staging, Settings exclusion and session restore passed.")
