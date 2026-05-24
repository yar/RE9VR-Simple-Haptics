-- RE9VR Simple Haptics
-- Additive bHaptics support for RE9VR. This script does not overwrite RE9VR files.

if reframework and reframework.get_game_name and reframework:get_game_name() ~= "re9" then
    return
end

local MOD_NAME = "RE9VR Simple Haptics"
local CONFIG_PATH = "bhaptics/re9vr_simple_haptics_config.json"
local EFFECTS_PATH = "bhaptics/re9vr_simple_haptics_effects.json"
local STATUS_RELATIVE_PATH = "data/bhpatics_bridge.status"
local QUEUE_RELATIVE_PATH = "data/bhpatics_bridge.queue"
local DIRECT_BRIDGE_INITIAL_RETRY_SECONDS = 5.0
local DIRECT_BRIDGE_BACKOFF_RETRY_SECONDS = 15.0
local DIRECT_BRIDGE_BACKOFF_AFTER_FAILURES = 3
local STARTUP_EFFECT_READY_DELAY_SECONDS = 0.15

local function log_info(message)
    if log and log.info then
        log.info("[" .. MOD_NAME .. "] " .. tostring(message))
    end
end

local function safe(callback)
    local ok, result = pcall(callback)
    if ok then
        return result
    end
    return nil
end

local unpack_values = table.unpack or unpack

local function read_text(path)
    local file = nil
    local ok = false
    if io and io.open then
        ok, file = pcall(io.open, path, "rb")
    end
    if not ok then
        return nil
    end
    if file == nil then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function write_append_line(path, line)
    local file = nil
    local ok = false
    if io and io.open then
        ok, file = pcall(io.open, path, "ab")
    end
    if not ok then
        return false
    end
    if file == nil then
        return false
    end
    file:write(line, "\n")
    file:close()
    return true
end

local function path_candidates(relative_path)
    local suffix = tostring(relative_path or ""):gsub("\\", "/")
    local candidates = {}
    if suffix ~= "" then
        if suffix:sub(1, 5) == "data/" then
            candidates[#candidates + 1] = suffix:sub(6)
        end
        candidates[#candidates + 1] = "reframework/" .. suffix
        candidates[#candidates + 1] = suffix
        candidates[#candidates + 1] = "_storage_/reframework/" .. suffix
        candidates[#candidates + 1] = "_storage_/" .. suffix
    end
    return candidates
end

local function read_first(paths)
    for _, path in ipairs(paths or {}) do
        local text = read_text(path)
        if text ~= nil then
            return text, path
        end
    end
    return nil, nil
end

local function append_first(paths, line)
    for _, path in ipairs(paths or {}) do
        if write_append_line(path, line) then
            return true, path
        end
    end
    return false, nil
end

local function parse_key_values(text)
    local parsed = {}
    if type(text) ~= "string" then
        return parsed
    end
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key ~= nil then
            parsed[key] = value
        end
    end
    return parsed
end

local function text_is_true(value)
    return value == "1" or value == "true" or value == "TRUE"
end

local function json_decode(text)
    if type(text) ~= "string" or json == nil then
        return nil
    end
    if type(json.load_string) == "function" then
        return safe(function() return json.load_string(text) end)
    end
    if type(json.decode) == "function" then
        return safe(function() return json.decode(text) end)
    end
    return nil
end

local function json_encode(value)
    if json == nil then
        return nil
    end
    if type(json.dump_string) == "function" then
        return safe(function() return json.dump_string(value) end)
    end
    if type(json.encode) == "function" then
        return safe(function() return json.encode(value) end)
    end
    return nil
end

local function normalize_tact_file(value)
    local name = tostring(value or ""):gsub("\\", "/")
    if name == "" then
        return nil
    end
    if not name:lower():match("%.tact$") then
        name = name .. ".tact"
    end
    return name
end

local function tact_path_candidates(tact_file)
    local normalized = normalize_tact_file(tact_file)
    if normalized == nil then
        return {}
    end
    return {
        "reframework/data/bhaptics/" .. normalized,
        "data/bhaptics/" .. normalized,
        "bhaptics/" .. normalized,
        normalized,
    }
end

local function json_skip_whitespace(text, index)
    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch ~= " " and ch ~= "\t" and ch ~= "\r" and ch ~= "\n" then
            return index
        end
        index = index + 1
    end
    return index
end

local function json_string_end(text, index)
    if text:sub(index, index) ~= '"' then
        return nil
    end

    index = index + 1
    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch == "\\" then
            index = index + 2
        elseif ch == '"' then
            return index
        else
            index = index + 1
        end
    end
    return nil
end

local function json_value_end(text, index)
    index = json_skip_whitespace(text, index)
    local first = text:sub(index, index)
    if first == '"' then
        return json_string_end(text, index)
    end

    if first == "{" or first == "[" then
        local stack = { first == "{" and "}" or "]" }
        index = index + 1
        local length = #text
        while index <= length do
            local ch = text:sub(index, index)
            if ch == '"' then
                local ending = json_string_end(text, index)
                if ending == nil then
                    return nil
                end
                index = ending + 1
            elseif ch == "{" then
                stack[#stack + 1] = "}"
                index = index + 1
            elseif ch == "[" then
                stack[#stack + 1] = "]"
                index = index + 1
            elseif ch == stack[#stack] then
                stack[#stack] = nil
                if #stack == 0 then
                    return index
                end
                index = index + 1
            else
                index = index + 1
            end
        end
        return nil
    end

    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch == "," or ch == "}" or ch == "]" then
            return index - 1
        end
        index = index + 1
    end
    return length
end

local function extract_top_level_json_member(text, member_name)
    if type(text) ~= "string" or type(member_name) ~= "string" then
        return nil
    end

    local index = json_skip_whitespace(text, 1)
    if text:sub(index, index) ~= "{" then
        return nil
    end
    index = index + 1

    local length = #text
    while index <= length do
        index = json_skip_whitespace(text, index)
        local ch = text:sub(index, index)
        if ch == "," then
            index = index + 1
            index = json_skip_whitespace(text, index)
            ch = text:sub(index, index)
        end
        if ch == "}" then
            return nil
        end
        if ch ~= '"' then
            return nil
        end

        local key_end = json_string_end(text, index)
        if key_end == nil then
            return nil
        end
        local key = text:sub(index + 1, key_end - 1)

        index = json_skip_whitespace(text, key_end + 1)
        if text:sub(index, index) ~= ":" then
            return nil
        end

        local value_start = json_skip_whitespace(text, index + 1)
        local value_end = json_value_end(text, value_start)
        if value_end == nil then
            return nil
        end
        if key == member_name then
            return text:sub(value_start, value_end)
        end
        index = value_end + 1
    end

    return nil
end

local function load_tact_project_json(tact_file)
    local text, path = read_first(tact_path_candidates(tact_file))
    if text == nil then
        return nil, nil, "tact file not found"
    end
    local raw_project_json = extract_top_level_json_member(text, "project")
    if type(raw_project_json) == "string" and raw_project_json:sub(1, 1) == "{" then
        return raw_project_json, path, nil
    end

    local decoded = json_decode(text)
    if type(decoded) ~= "table" or type(decoded.project) ~= "table" then
        return nil, path, "tact project missing"
    end
    local project_json = json_encode(decoded.project)
    if type(project_json) ~= "string" then
        return nil, path, "json encoder unavailable"
    end
    return project_json, path, nil
end

local function wrap_direct_bridge(bridge)
    if type(bridge) ~= "table" then
        return nil
    end
    if type(bridge.register_project) ~= "function"
        or type(bridge.submit_registered) ~= "function"
    then
        return nil
    end

    return {
        mode = "lua_bridge",
        ensure_connected = function()
            if type(bridge.ensure_connected) ~= "function" then
                return true
            end
            return bridge.ensure_connected() == true
        end,
        register_project = function(key, project_json)
            return bridge.register_project(key, project_json) == true
        end,
        submit_registered = function(key)
            return bridge.submit_registered(key) == true
        end,
        send_raw = function(payload)
            return type(bridge.send_raw) == "function" and bridge.send_raw(payload) == true or false
        end,
        get_status = function()
            if type(bridge.get_status) ~= "function" then
                return nil
            end
            local status = safe(function() return bridge.get_status() end)
            return type(status) == "table" and status or nil
        end,
    }
end

local function create_queue_bridge()
    local status_paths = path_candidates(STATUS_RELATIVE_PATH)
    local queue_paths = path_candidates(QUEUE_RELATIVE_PATH)

    local function get_status()
        local text, status_path = read_first(status_paths)
        if text == nil then
            return nil
        end
        local parsed = parse_key_values(text)
        return {
            ready = text_is_true(parsed.ready),
            connected = text_is_true(parsed.connected),
            directLua = text_is_true(parsed.directLua),
            phase = parsed.phase,
            mode = parsed.mode,
            lastError = parsed.lastError,
            lastCommand = parsed.lastCommand,
            statusPath = status_path,
            queuePath = parsed.queuePath or queue_paths[1],
        }
    end

    local function enqueue(parts)
        local ok = append_first(queue_paths, table.concat(parts, "\t"))
        return ok == true
    end

    return {
        mode = "queue_bridge",
        ensure_connected = function()
            return enqueue({ "ENSURE_CONNECTED" })
        end,
        register_project = function(key, project_json)
            return enqueue({ "REGISTER_PROJECT", tostring(key or ""), "0.0", tostring(project_json or "") })
        end,
        submit_registered = function(key)
            return enqueue({ "SUBMIT_REGISTERED", tostring(key or "") })
        end,
        send_raw = function(payload)
            return enqueue({ "SEND_RAW", tostring(payload or "") })
        end,
        get_status = get_status,
    }
end

local bridge_cache = nil
local queue_bridge = nil

local function resolve_bridge()
    local direct = wrap_direct_bridge(rawget(_G, "BhapticsBridge") or rawget(_G, "bhaptics_bridge"))
    if direct ~= nil then
        bridge_cache = direct
        return bridge_cache
    end

    if queue_bridge == nil then
        queue_bridge = create_queue_bridge()
    end

    bridge_cache = queue_bridge
    return bridge_cache
end

local state = rawget(_G, "RE9VR_SIMPLE_HAPTICS")
if type(state) ~= "table" then
    state = {
        enabled = true,
        effects = {},
        effects_by_key = {},
        registered_all = false,
        last_register_attempt = 0.0,
        last_weapon_id = nil,
        holster_zone_until = 0.0,
        reload_sound_context_until = 0.0,
        wrappers = {},
        originals = {},
        external_events = {},
        native_hooks = {},
        hooks_installed = false,
        startup_played = false,
        startup_ready_at = 0.0,
    }
    _G.RE9VR_SIMPLE_HAPTICS = state
end
state.wrappers = type(state.wrappers) == "table" and state.wrappers or {}
state.originals = type(state.originals) == "table" and state.originals or {}
state.external_events = type(state.external_events) == "table" and state.external_events or {}
state.native_hooks = type(state.native_hooks) == "table" and state.native_hooks or {}
state.failed_bridge_connect_attempts = tonumber(state.failed_bridge_connect_attempts) or 0

local function load_config()
    local cfg = json and json.load_file and safe(function() return json.load_file(CONFIG_PATH) end) or nil
    if type(cfg) == "table" and type(cfg.enabled) == "boolean" then
        state.enabled = cfg.enabled
    end
end

local function save_config()
    if json == nil or type(json.dump_file) ~= "function" then
        return
    end
    safe(function()
        json.dump_file(CONFIG_PATH, {
            enabled = state.enabled ~= false,
        })
    end)
end

local FALLBACK_EFFECTS = {
    { key = "RE9_SH_Startup", tact_file = "RE9_SH_Startup.tact", description = "Startup confirmation", trigger_description = "script starts", preview_shortcut = "0", cooldown = 1.0 },
    { key = "RE9_SH_Pistol_Right", tact_file = "RE9_SH_Pistol_Right.tact", description = "Handgun recoil", trigger_description = "handgun/revolver shot", preview_shortcut = "1", cooldown = 0.055 },
    { key = "RE9_SH_Auto_Right", tact_file = "RE9_SH_Auto_Right.tact", description = "Automatic recoil", trigger_description = "SMG/auto fire", preview_shortcut = "2", cooldown = 0.035 },
    { key = "RE9_SH_Shotgun_Right", tact_file = "RE9_SH_Shotgun_Right.tact", description = "Shotgun recoil", trigger_description = "shotgun/magnum shot", preview_shortcut = "3", cooldown = 0.12 },
    { key = "RE9_SH_Rifle_Right", tact_file = "RE9_SH_Rifle_Right.tact", description = "Rifle recoil", trigger_description = "rifle/launcher shot", preview_shortcut = "4", cooldown = 0.09 },
    { key = "RE9_SH_Melee_Swing_R", tact_file = "RE9_SH_Melee_Swing_R.tact", description = "Melee swing", trigger_description = "melee swing", preview_shortcut = "5", cooldown = 0.18 },
    { key = "RE9_SH_Melee_Hit_R", tact_file = "RE9_SH_Melee_Hit_R.tact", description = "Melee hit", trigger_description = "melee hit", preview_shortcut = "6", cooldown = 0.10 },
    { key = "RE9_SH_Grenade", tact_file = "RE9_SH_Grenade.tact", description = "Throwable", trigger_description = "throwable use", preview_shortcut = "7", cooldown = 0.35 },
    { key = "RE9_SH_Holster_Hip", tact_file = "RE9_SH_Holster_Hip.tact", description = "Hip holster", trigger_description = "hip holster draw/stow", preview_shortcut = "8", cooldown = 0.45 },
    { key = "RE9_SH_Holster_Shoulder", tact_file = "RE9_SH_Holster_Shoulder.tact", description = "Shoulder holster", trigger_description = "shoulder holster draw/stow", preview_shortcut = "9", cooldown = 0.45 },
    { key = "RE9_SH_Holster_Chest", tact_file = "RE9_SH_Holster_Chest.tact", description = "Chest holster", trigger_description = "chest holster draw/stow", preview_shortcut = "a", cooldown = 0.45 },
    { key = "RE9_SH_Heal", tact_file = "RE9_SH_Heal.tact", description = "Healing", trigger_description = "HP recovery", preview_shortcut = "b", cooldown = 1.0 },
    { key = "RE9_SH_Player_Damage", tact_file = "RE9_SH_Player_Damage.tact", description = "Player damage", trigger_description = "player damage", preview_shortcut = "c", cooldown = 0.42 },
    { key = "RE9_SH_Electric_Damage", tact_file = "RE9_SH_Electric_Damage.tact", description = "Electric damage", trigger_description = "electric player damage", preview_shortcut = "d", cooldown = 0.9 },
    { key = "RE9_SH_Player_Death", tact_file = "RE9_SH_Player_Death.tact", description = "Player death", trigger_description = "player death", preview_shortcut = "e", cooldown = 4.0 },
    { key = "RE9_SH_Camera_Shake", tact_file = "RE9_SH_Camera_Shake.tact", description = "Camera shake", trigger_description = "camera shake", preview_shortcut = "f", cooldown = 0.55 },
    { key = "RE9_SH_Add_Item", tact_file = "RE9_SH_Add_Item.tact", description = "Item pickup", trigger_description = "inventory add", preview_shortcut = "g", cooldown = 0.25 },
    { key = "RE9_SH_Reload_Mag_Grab", tact_file = "RE9_SH_Reload_Mag_Grab.tact", description = "Reload grab", trigger_description = "manual reload grab", preview_shortcut = "h", cooldown = 0.12 },
    { key = "RE9_SH_Reload_Mag_Insert", tact_file = "RE9_SH_Reload_Mag_Insert.tact", description = "Reload insert", trigger_description = "manual reload insert", preview_shortcut = "i", cooldown = 0.16 },
    { key = "RE9_SH_Reload_Mag_Drop", tact_file = "RE9_SH_Reload_Mag_Drop.tact", description = "Reload drop", trigger_description = "manual reload drop", preview_shortcut = "j", cooldown = 0.18 },
    { key = "RE9_SH_Reload_Rack_Back", tact_file = "RE9_SH_Reload_Rack_Back.tact", description = "Rack back", trigger_description = "manual rack back", preview_shortcut = "k", cooldown = 0.14 },
    { key = "RE9_SH_Reload_Rack_Forward", tact_file = "RE9_SH_Reload_Rack_Forward.tact", description = "Rack forward", trigger_description = "manual rack forward", preview_shortcut = "l", cooldown = 0.14 },
    { key = "RE9_SH_Dry_Fire_Right", tact_file = "RE9_SH_Dry_Fire_Right.tact", description = "Dry fire", trigger_description = "dry fire", preview_shortcut = "m", cooldown = 0.12 },
    { key = "RE9_SH_Barrel_Close", tact_file = "RE9_SH_Barrel_Close.tact", description = "Barrel close", trigger_description = "barrel close", preview_shortcut = "n", cooldown = 0.18 },
    { key = "RE9_SH_Throwable_Equip", tact_file = "RE9_SH_Throwable_Equip.tact", description = "Throwable equip", trigger_description = "throwable equip", preview_shortcut = "o", cooldown = 0.35 },
    { key = "RE9_SH_Throwable_Release", tact_file = "RE9_SH_Throwable_Release.tact", description = "Throwable release", trigger_description = "throwable release", preview_shortcut = "p", cooldown = 0.35 },
    { key = "RE9_SH_Block_Stance", tact_file = "RE9_SH_Block_Stance.tact", description = "Block stance", trigger_description = "block stance", preview_shortcut = "y", cooldown = 0.65 },
    { key = "RE9_SH_Block_Impact", tact_file = "RE9_SH_Block_Impact.tact", description = "Block impact", trigger_description = "block impact", preview_shortcut = "r", cooldown = 0.28 },
    { key = "RE9_SH_Parry_Success", tact_file = "RE9_SH_Parry_Success.tact", description = "Parry success", trigger_description = "parry success", preview_shortcut = "s", cooldown = 0.35 },
    { key = "RE9_SH_Syringe_Ready", tact_file = "RE9_SH_Syringe_Ready.tact", description = "Syringe ready", trigger_description = "optional external event: manual syringe ready", preview_shortcut = "t", cooldown = 0.4 },
    { key = "RE9_SH_Syringe_Zone", tact_file = "RE9_SH_Syringe_Zone.tact", description = "Syringe zone", trigger_description = "optional external event: manual syringe injection zone", preview_shortcut = "u", cooldown = 0.2 },
    { key = "RE9_SH_Syringe_Fail", tact_file = "RE9_SH_Syringe_Fail.tact", description = "Syringe fail", trigger_description = "optional external event: manual syringe failed", preview_shortcut = "v", cooldown = 0.35 },
    { key = "RE9_SH_Bike_Start", tact_file = "RE9_SH_Bike_Start.tact", description = "Bike start", trigger_description = "bike mode start", preview_shortcut = "w", cooldown = 1.0 },
    { key = "RE9_SH_Bike_Rumble", tact_file = "RE9_SH_Bike_Rumble.tact", description = "Bike rumble", trigger_description = "bike mode rumble", preview_shortcut = "x", cooldown = 0.55 },
}

local function load_effects()
    local data = json and json.load_file and safe(function() return json.load_file(EFFECTS_PATH) end) or nil
    local effects = type(data) == "table" and type(data.effects) == "table" and data.effects or FALLBACK_EFFECTS
    state.effects = {}
    state.effects_by_key = {}
    state.registered_all = false
    state.startup_ready_at = 0.0
    for _, entry in ipairs(effects) do
        if type(entry) == "table" and type(entry.key) == "string" and type(entry.tact_file) == "string" then
            local embedded_project_json = entry.project_json or entry.projectJson
            local use_embedded_project = type(embedded_project_json) == "string" and entry.prefer_tact_file == false
            local effect = {
                key = entry.key,
                tact_file = entry.tact_file,
                description = entry.description or entry.key,
                trigger_description = entry.trigger_description or "",
                preview_shortcut = entry.preview_shortcut or "",
                cooldown = math.max(0.0, tonumber(entry.cooldown) or 0.1),
                registered = false,
                register_failed = false,
                project_load_attempted = use_embedded_project,
                project_json = use_embedded_project and embedded_project_json or nil,
                tact_path = nil,
                last_error = nil,
                next_allowed = 0.0,
            }
            state.effects[#state.effects + 1] = effect
            state.effects_by_key[effect.key] = effect
        end
    end
end

local function bridge_connected_status(bridge)
    if type(bridge) ~= "table" or type(bridge.get_status) ~= "function" then
        return nil
    end
    local status = safe(function() return bridge.get_status() end)
    if type(status) == "table" and type(status.connected) == "boolean" then
        return status.connected
    end
    return nil
end

local function ensure_bridge_available(bridge)
    if type(bridge) ~= "table" then
        return false
    end
    if bridge.mode ~= "lua_bridge" then
        return true
    end
    if bridge_connected_status(bridge) == true then
        state.next_bridge_connect_attempt = 0.0
        state.failed_bridge_connect_attempts = 0
        return true
    end

    local now = os.clock()
    if now < (state.next_bridge_connect_attempt or 0.0) then
        return false
    end
    if type(bridge.ensure_connected) ~= "function" then
        return false
    end
    local ok, connected = pcall(bridge.ensure_connected)
    if ok and connected == true then
        state.next_bridge_connect_attempt = 0.0
        state.failed_bridge_connect_attempts = 0
        return true
    end
    state.failed_bridge_connect_attempts = (tonumber(state.failed_bridge_connect_attempts) or 0) + 1
    local retry_seconds = state.failed_bridge_connect_attempts >= DIRECT_BRIDGE_BACKOFF_AFTER_FAILURES
        and DIRECT_BRIDGE_BACKOFF_RETRY_SECONDS
        or DIRECT_BRIDGE_INITIAL_RETRY_SECONDS
    state.next_bridge_connect_attempt = now + retry_seconds
    return false
end

local function register_effect(effect, bridge)
    if effect == nil or effect.registered == true then
        return effect ~= nil
    end

    bridge = bridge or resolve_bridge()
    if bridge == nil then
        effect.last_error = "bridge unavailable"
        return false
    end
    if not ensure_bridge_available(bridge) then
        effect.last_error = "bridge unavailable"
        return false
    end

    if type(effect.project_json) ~= "string" and effect.project_load_attempted ~= true then
        local project_json, tact_path, err = load_tact_project_json(effect.tact_file)
        effect.project_json = project_json
        effect.tact_path = tact_path
        effect.last_error = err
        effect.project_load_attempted = true
    end
    if type(effect.project_json) ~= "string" then
        effect.register_failed = true
        return false
    end

    if bridge.register_project(effect.key, effect.project_json) then
        effect.registered = true
        effect.register_failed = false
        effect.last_error = nil
        return true
    end

    effect.last_error = "register_project failed"
    return false
end

local function register_pending()
    local now = os.clock()
    if now - (state.last_register_attempt or 0.0) < 1.0 then
        return
    end
    state.last_register_attempt = now

    local bridge = resolve_bridge()
    if not ensure_bridge_available(bridge) then
        state.registered_all = false
        return
    end
    local all_registered = true
    local registered_count = 0
    for _, effect in ipairs(state.effects or {}) do
        if effect.registered ~= true then
            if not register_effect(effect, bridge) then
                all_registered = false
            end
        end
        if effect.registered == true then
            registered_count = registered_count + 1
        end
    end
    if all_registered and state.registered_all ~= true then
        state.registered_all = true
        state.startup_ready_at = os.clock() + STARTUP_EFFECT_READY_DELAY_SECONDS
        log_info("registered " .. tostring(registered_count) .. " effects from metadata")
    end
end

local function play_effect(key, reason)
    if state.enabled == false then
        return false
    end

    local effect = state.effects_by_key and state.effects_by_key[key] or nil
    if effect == nil then
        return false
    end

    local now = os.clock()
    if now < (effect.next_allowed or 0.0) then
        return false
    end

    local bridge = resolve_bridge()
    if bridge == nil then
        return false
    end
    if not ensure_bridge_available(bridge) then
        return false
    end

    local ok = bridge.submit_registered(effect.key) == true
    if ok then
        effect.next_allowed = now + effect.cooldown
        effect.last_error = nil
        _G.RE9VR_SIMPLE_HAPTICS_LAST = {
            key = effect.key,
            tact_file = effect.tact_file,
            reason = reason or "",
            mode = "registered",
            at = now,
        }
        return true
    end

    effect.last_error = "submit_registered failed"
    return false
end

local function queue_haptics_event(name, data)
    if type(name) ~= "string" or name == "" then
        return false
    end
    state.external_events = type(state.external_events) == "table" and state.external_events or {}
    state.external_events[#state.external_events + 1] = {
        name = name,
        data = type(data) == "table" and data or {},
        at = os.clock(),
    }
    return true
end

_G.re9_vr_trigger_bhaptics_event = queue_haptics_event

local EVENT_EFFECTS = {
    player_damage = "RE9_SH_Player_Damage",
    electric_damage = "RE9_SH_Electric_Damage",
    player_death = "RE9_SH_Player_Death",
    camera_shake = "RE9_SH_Camera_Shake",
    add_item = "RE9_SH_Add_Item",
    reload_mag_grab = "RE9_SH_Reload_Mag_Grab",
    reload_mag_insert = "RE9_SH_Reload_Mag_Insert",
    reload_mag_drop = "RE9_SH_Reload_Mag_Drop",
    reload_rack_back = "RE9_SH_Reload_Rack_Back",
    reload_rack_forward = "RE9_SH_Reload_Rack_Forward",
    reload_dry_fire = "RE9_SH_Dry_Fire_Right",
    reload_barrel_close = "RE9_SH_Barrel_Close",
    throwable_equip = "RE9_SH_Throwable_Equip",
    throwable_release = "RE9_SH_Throwable_Release",
    block_stance = "RE9_SH_Block_Stance",
    block_impact = "RE9_SH_Block_Impact",
    parry_success = "RE9_SH_Parry_Success",
    syringe_ready = "RE9_SH_Syringe_Ready",
    syringe_zone = "RE9_SH_Syringe_Zone",
    syringe_fail = "RE9_SH_Syringe_Fail",
    syringe_success = "RE9_SH_Heal",
    bike_start = "RE9_SH_Bike_Start",
    bike_rumble = "RE9_SH_Bike_Rumble",
}

local RELOAD_SOUND_EVENTS = {
    mag_grab = "reload_mag_grab",
    mag_insert = "reload_mag_insert",
    mag_floor = "reload_mag_drop",
    mag_drop = "reload_mag_drop",
    slide_back = "reload_rack_back",
    slide_fwd = "reload_rack_forward",
    dry_fire = "reload_dry_fire",
    barrel_close = "reload_barrel_close",
}

local function grip_held(hand)
    local vr = rawget(_G, "vrmod")
    if type(vr) ~= "table" or type(vr.is_action_active) ~= "function" then
        return false
    end

    local ok, held = pcall(function()
        local action_grip = vr:get_action_grip()
        local joystick = nil
        if hand == "left" and type(vr.get_left_joystick) == "function" then
            joystick = vr:get_left_joystick()
        elseif hand == "right" and type(vr.get_right_joystick) == "function" then
            joystick = vr:get_right_joystick()
        end
        if joystick == nil then
            return false
        end
        return vr:is_action_active(action_grip, joystick)
    end)

    return ok and held == true
end

local function reload_sound_event_allowed(event_name, now)
    if event_name == "reload_mag_grab" then
        local left_reload_context = rawget(_G, "__vr_in_mag_holster_zone") == true
            or rawget(_G, "__vr_hide_flashlight_during_reload") == true
            or grip_held("left")
        local right_only_grip = grip_held("right") and not grip_held("left")
        if not left_reload_context or right_only_grip then
            return false
        end
        state.reload_sound_context_until = now + 2.0
        return true
    end

    if event_name == "reload_mag_insert" or event_name == "reload_mag_drop" then
        local left_reload_context = rawget(_G, "__vr_in_mag_holster_zone") == true
            or rawget(_G, "__vr_hide_flashlight_during_reload") == true
            or now <= (state.reload_sound_context_until or 0.0)
        if not left_reload_context then
            return false
        end
        state.reload_sound_context_until = now + 2.0
        return true
    end

    return true
end

local RELOAD_SOUND_EVENT_BY_ID = {
    [1829826749] = "reload_dry_fire",

    [1149869414] = "reload_barrel_close",
    [1771113055] = "reload_barrel_close",
    [3365416453] = "reload_barrel_close",

    [1311819693] = "reload_rack_back",
    [1679015039] = "reload_rack_back",
    [1949962718] = "reload_rack_back",
    [2077601956] = "reload_rack_back",
    [2889636088] = "reload_rack_back",
    [2959785997] = "reload_rack_back",
    [3033074820] = "reload_rack_back",
    [4100985192] = "reload_rack_back",
    [4125335400] = "reload_rack_back",
    [4145758334] = "reload_rack_back",
    [4156236415] = "reload_rack_back",

    [395320922] = "reload_rack_forward",

    [88179426] = "reload_mag_insert",
    [529475776] = "reload_mag_insert",
    [740602526] = "reload_mag_insert",
    [851781981] = "reload_mag_insert",
    [1206855557] = "reload_mag_insert",
    [1734907393] = "reload_mag_insert",
    [1874412918] = "reload_mag_insert",
    [2285578736] = "reload_mag_insert",
    [2364385236] = "reload_mag_insert",
    [2373329892] = "reload_mag_insert",
    [2787349215] = "reload_mag_insert",
    [3161648387] = "reload_mag_insert",
    [3237741632] = "reload_mag_insert",
    [3398771685] = "reload_mag_insert",
    [3465740230] = "reload_mag_insert",
    [3880458957] = "reload_mag_insert",
    [4208137125] = "reload_mag_insert",

    [368630953] = "reload_mag_grab",
    [889979551] = "reload_mag_grab",
    [894004244] = "reload_mag_grab",
    [911663998] = "reload_mag_grab",
    [1194338602] = "reload_mag_grab",
    [1223695543] = "reload_mag_grab",
    [1618725184] = "reload_mag_grab",
    [1659952173] = "reload_mag_grab",
    [1742429568] = "reload_mag_grab",
    [2219423702] = "reload_mag_grab",
    [2559475988] = "reload_mag_grab",
    [2752792510] = "reload_mag_grab",
    [2825150174] = "reload_mag_grab",
    [3102803017] = "reload_mag_grab",
    [3352915156] = "reload_mag_grab",
    [3528949666] = "reload_mag_grab",

    [12365814] = "reload_mag_drop",
    [420335143] = "reload_mag_drop",
    [435491427] = "reload_mag_drop",
    [891115126] = "reload_mag_drop",
    [924634061] = "reload_mag_drop",
    [1147792872] = "reload_mag_drop",
    [1420331441] = "reload_mag_drop",
    [1424548980] = "reload_mag_drop",
    [1459829088] = "reload_mag_drop",
    [1591085525] = "reload_mag_drop",
    [1672122679] = "reload_mag_drop",
    [1816913827] = "reload_mag_drop",
    [2589228240] = "reload_mag_drop",
    [2719697074] = "reload_mag_drop",
    [2880610454] = "reload_mag_drop",
    [3287908441] = "reload_mag_drop",
    [3688259091] = "reload_mag_drop",
    [4125460989] = "reload_mag_drop",
}

local function handle_reload_sound_trigger(args)
    if sdk == nil or type(sdk.to_int64) ~= "function" then
        return
    end
    local sound_id = nil
    pcall(function()
        sound_id = sdk.to_int64(args[3]) & 0xFFFFFFFF
    end)
    local event_name = sound_id and RELOAD_SOUND_EVENT_BY_ID[sound_id] or nil
    if event_name == nil then
        return
    end

    local now = os.clock()
    if not reload_sound_event_allowed(event_name, now) then
        return
    end
    if state.last_reload_sound_id == sound_id and now < (state.last_reload_sound_until or 0.0) then
        return
    end
    state.last_reload_sound_id = sound_id
    state.last_reload_sound_until = now + 0.025
    queue_haptics_event(event_name, { sound_id = sound_id })
end

local function play_external_event(event)
    if type(event) ~= "table" then
        return
    end
    local name = tostring(event.name or "")
    if name == "reload_sound" and type(event.data) == "table" then
        name = RELOAD_SOUND_EVENTS[tostring(event.data.kind or "")]
    end
    local effect_key = name and EVENT_EFFECTS[name] or nil
    if effect_key ~= nil then
        play_effect(effect_key, name)
    end
end

local function update_external_events()
    if type(state.external_events) ~= "table" or #state.external_events == 0 then
        return
    end
    local events = state.external_events
    state.external_events = {}
    for _, event in ipairs(events) do
        pcall(play_external_event, event)
    end
end

local function method_signature_text(method)
    local ok, value = pcall(function() return tostring(method) end)
    return ok and value or ""
end

local function find_method(type_def, method_name)
    if type_def == nil or type(method_name) ~= "string" then
        return nil
    end
    local method = safe(function() return type_def:get_method(method_name) end)
    if method ~= nil then
        return method
    end
    local simple_name = method_name:match("^([^%(]+)")
    local methods = safe(function() return type_def:get_methods() end)
    if simple_name == nil or type(methods) ~= "table" then
        return nil
    end
    for _, candidate in ipairs(methods) do
        local ok_name, candidate_name = pcall(function() return candidate:get_name() end)
        if ok_name and candidate_name == simple_name then
            local signature = method_signature_text(candidate)
            if signature == "" or signature:find(method_name, 1, true) or not method_name:find("%(", 1, false) then
                return candidate
            end
        end
    end
    return nil
end

local function install_native_hook(id, type_name, method_name, pre, post)
    state.native_hooks = type(state.native_hooks) == "table" and state.native_hooks or {}
    local hook_state = state.native_hooks[id]
    if type(hook_state) ~= "table" then
        hook_state = {}
        state.native_hooks[id] = hook_state
    end
    if hook_state.installed or hook_state.failed then
        return
    end
    local td = sdk and sdk.find_type_definition and sdk.find_type_definition(type_name) or nil
    if td == nil then
        hook_state.status = "waiting for " .. tostring(type_name)
        return
    end
    local method = find_method(td, method_name)
    if method == nil then
        hook_state.status = "waiting for " .. tostring(type_name) .. "." .. tostring(method_name)
        return
    end
    local ok, err = pcall(function()
        sdk.hook(method, pre or function(_) end, post or function(retval) return retval end)
    end)
    if ok then
        hook_state.installed = true
        hook_state.status = "installed"
        log_info("event hook installed: " .. tostring(id))
    else
        hook_state.failed = true
        hook_state.status = "failed: " .. tostring(err)
        log_info("event hook failed: " .. tostring(id) .. ": " .. tostring(err))
    end
end

local function numeric_value(value)
    if type(value) == "number" then
        return value
    end
    if value == nil then
        return nil
    end
    local direct = tonumber(value)
    if direct ~= nil then
        return direct
    end
    local text = tostring(value)
    return tonumber(text:match("(%-?%d+%.?%d*)"))
end

local function damage_info_from_args(args)
    if sdk == nil or type(sdk.to_managed_object) ~= "function" then
        return nil
    end
    return safe(function() return sdk.to_managed_object(args[3]) end)
end

local function is_block_pose_active()
    if rawget(_G, "__vr_bhaptics_block_pose_active") == true then
        return true
    end
    return os.clock() <= (state.vigem_lb_parry_until or 0.0)
end

local function handle_player_damage(args)
    local damage_info = damage_info_from_args(args)
    local attr = damage_info and safe(function() return damage_info:call("getAttackAttribute") end) or nil
    local damage = damage_info and safe(function() return damage_info:call("get_Damage") end) or nil
    state.last_damage_amount = numeric_value(damage)
    state.last_damage_attribute = numeric_value(attr)
    if state.last_damage_attribute == 8 then
        queue_haptics_event("electric_damage", { damage = state.last_damage_amount })
    elseif is_block_pose_active() then
        queue_haptics_event("block_impact", { damage = state.last_damage_amount })
    else
        queue_haptics_event("player_damage", { damage = state.last_damage_amount })
    end
end

local function install_native_event_hooks()
    install_native_hook(
        "player_damage",
        "app.PlayerAttackDamageDriver",
        "onDamageCalc",
        function(args) pcall(handle_player_damage, args) end,
        function(retval) return retval end
    )
    install_native_hook(
        "parry_success",
        "app.PlayerAttackDamageDriver",
        "onParrySuccess",
        function(_) queue_haptics_event("parry_success") end,
        function(retval) return retval end
    )
    install_native_hook(
        "camera_shake",
        "app.CameraShakeController",
        "request",
        function(_) queue_haptics_event("camera_shake") end,
        function(retval) return retval end
    )
    install_native_hook(
        "player_death",
        "app.PlayerUpdaterBase",
        "onDead",
        function(_) queue_haptics_event("player_death") end,
        function(retval) return retval end
    )
    install_native_hook(
        "add_item",
        "app.Inventory",
        "mergeOrAdd(app.ItemAmountData[], System.Boolean, app.Inventory.AcquireItemOptions, app.ItemStockChangedEventType)",
        function(_) end,
        function(retval)
            queue_haptics_event("add_item")
            return retval
        end
    )
    install_native_hook(
        "throw_item_shell",
        "app.PlayerMelee",
        "createShell",
        function(_) queue_haptics_event("throwable_release") end,
        function(retval) return retval end
    )
    install_native_hook(
        "reload_sound",
        "soundlib.SoundContainer",
        "trigger(System.UInt32)",
        function(args) pcall(handle_reload_sound_trigger, args) end,
        function(retval) return retval end
    )
end

local PISTOLS = {
    arm0000 = true, arm0001 = true, arm0003 = true, arm0004 = true, arm0007 = true,
}

local MAGNUMS = {
    arm0005 = true, arm0006 = true, arm0400 = true,
}

local SHOTGUNS = {
    arm0100 = true, arm0103 = true, arm0104 = true,
}

local AUTOS = {
    arm0500 = true, arm0501 = true, arm0503 = true, arm0505 = true,
}

local RIFLES = {
    arm0600 = true, arm0601 = true, arm0700 = true,
}

local THROWABLES = {
    arm0200 = true, arm0202 = true, arm0203 = true, arm0204 = true, arm0207 = true,
}

local MELEE = {
    arm0300 = true, arm0303 = true, arm0335 = true, arm0350 = true, arm0353 = true, arm0354 = true, arm3001 = true,
}

local function normalize_weapon_id(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    local match = text:match("(arm%d+)")
    if match ~= nil then
        return match:lower()
    end
    return nil
end

local function read_weapon_from_context()
    local character_manager = sdk and sdk.get_managed_singleton and sdk.get_managed_singleton("app.CharacterManager") or nil
    if character_manager == nil then
        return nil
    end
    local context = safe(function() return character_manager:call("get_PlayerContextFast") end)
    local updater = context and safe(function() return context:call("get_Updater") end) or nil
    local equipment = updater and safe(function() return updater:call("get_Equipment") end) or nil
    local weapon_id = equipment and safe(function() return equipment:get_field("<EquipWeaponID>k__BackingField") end) or nil
    return normalize_weapon_id(weapon_id and safe(function() return weapon_id:call("ToString") end) or nil)
end

local function current_weapon_id()
    return normalize_weapon_id(rawget(_G, "__vr_weapon_name")) or read_weapon_from_context()
end

local PARRY_WEAPONS_BY_CHAR = {
    cp_A000 = { arm0300 = true, arm0350 = true },
    cp_A100 = { arm0354 = true },
}

local function is_parry_weapon_id(weapon_id)
    local id = normalize_weapon_id(weapon_id)
    if id == nil then
        return false
    end
    local char = rawget(_G, "__vr_current_char")
    local set = char and PARRY_WEAPONS_BY_CHAR[char] or nil
    return set ~= nil and set[id] == true
end

local function mark_possible_block_pose()
    if is_parry_weapon_id(current_weapon_id()) then
        state.vigem_lb_parry_until = os.clock() + 0.12
    end
end

local function effect_for_weapon_fire(weapon_id)
    local id = normalize_weapon_id(weapon_id)
    if id == nil then
        return "RE9_SH_Pistol_Right"
    end
    if THROWABLES[id] then
        return "RE9_SH_Grenade"
    end
    if SHOTGUNS[id] or MAGNUMS[id] then
        return "RE9_SH_Shotgun_Right"
    end
    if AUTOS[id] then
        return "RE9_SH_Auto_Right"
    end
    if RIFLES[id] then
        return "RE9_SH_Rifle_Right"
    end
    if PISTOLS[id] then
        return "RE9_SH_Pistol_Right"
    end
    return "RE9_SH_Pistol_Right"
end

local function effect_for_holster(weapon_id)
    local id = normalize_weapon_id(weapon_id)
    if id == nil then
        return "RE9_SH_Holster_Hip"
    end
    if SHOTGUNS[id] or AUTOS[id] or RIFLES[id] then
        return "RE9_SH_Holster_Shoulder"
    end
    if MAGNUMS[id] or THROWABLES[id] then
        return "RE9_SH_Holster_Chest"
    end
    return "RE9_SH_Holster_Hip"
end

local function trigger_weapon_fire()
    if rawget(_G, "__vr_pump_fire_blocked") == true then
        return
    end
    play_effect(effect_for_weapon_fire(current_weapon_id()), "weapon_fire")
end

local function install_fire_hook()
    if state.fire_hook_installed or state.fire_hook_failed then
        return
    end
    local td = sdk and sdk.find_type_definition and sdk.find_type_definition("app.PlayerEquipment") or nil
    if td == nil then
        state.fire_hook_status = "waiting for app.PlayerEquipment"
        return
    end
    local method = td and td:get_method("execFire") or nil
    if method == nil then
        state.fire_hook_status = "waiting for app.PlayerEquipment.execFire"
        return
    end
    local ok, err = pcall(function()
        sdk.hook(method, function(_) end, function(retval)
            pcall(trigger_weapon_fire)
            return retval
        end)
    end)
    if ok then
        state.fire_hook_installed = true
        state.fire_hook_status = "installed"
        log_info("fire hook installed")
    else
        state.fire_hook_failed = true
        state.fire_hook_status = "failed: " .. tostring(err)
        log_info("fire hook failed: " .. tostring(err))
    end
end

local function read_hit_point_value(hit_point)
    if hit_point == nil then
        return nil
    end
    local value = safe(function() return hit_point:get_field("<CurrentHitPoint>k__BackingField") end)
    if type(value) == "number" then
        return value
    end
    value = safe(function() return hit_point:call("get_CurrentHitPoint") end)
    if type(value) == "number" then
        return value
    end
    value = safe(function() return hit_point:get_field("_CurrentHitPoint") end)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function read_max_hit_point_value(hit_point)
    if hit_point == nil then
        return nil
    end
    local value = safe(function() return hit_point:get_field("<MaxHitPoint>k__BackingField") end)
    if type(value) == "number" then
        return value
    end
    value = safe(function() return hit_point:call("get_MaxHitPoint") end)
    if type(value) == "number" then
        return value
    end
    value = safe(function() return hit_point:get_field("_MaxHitPoint") end)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function hit_point_from_args(args)
    if sdk == nil or type(sdk.to_managed_object) ~= "function" then
        return nil
    end
    return safe(function() return sdk.to_managed_object(args[2]) end)
end

local function heal_delta_threshold(hit_point)
    local max_hp = read_max_hit_point_value(hit_point)
    if type(max_hp) == "number" and max_hp > 0 then
        return math.max(5, max_hp * 0.03)
    end
    return 5
end

local function play_heal_if_hp_increased(hit_point, before, source)
    if type(before) ~= "number" then
        return
    end
    local after = read_hit_point_value(hit_point)
    if type(after) ~= "number" then
        return
    end
    local delta = after - before
    if delta < heal_delta_threshold(hit_point) then
        return
    end

    local now = os.clock()
    if now < (state.next_heal_detection_allowed or 0.0) then
        return
    end
    state.next_heal_detection_allowed = now + 1.75
    state.last_heal_delta = delta
    play_effect("RE9_SH_Heal", source or "hp_recovery")
end

local function hook_heal_delta_method(td, signature, source)
    local method = td:get_method(signature)
    if method == nil then
        return false, nil
    end

    local ok, err = pcall(function()
        sdk.hook(method, function(args)
            local hit_point = hit_point_from_args(args)
            state.pending_heal_sample = {
                hit_point = hit_point,
                before = read_hit_point_value(hit_point),
                source = source,
            }
        end, function(retval)
            local sample = state.pending_heal_sample
            state.pending_heal_sample = nil
            if type(sample) == "table" then
                play_heal_if_hp_increased(sample.hit_point, sample.before, sample.source)
            end
            return retval
        end)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function hook_set_current_hit_point(td)
    local method = td:get_method("set_CurrentHitPoint(System.Int32)")
    if method == nil then
        return false, nil
    end

    local ok, err = pcall(function()
        sdk.hook(method, function(args)
            local hit_point = hit_point_from_args(args)
            local before = read_hit_point_value(hit_point)
            local target = nil
            pcall(function()
                target = sdk.to_int64(args[3]) & 0xFFFFFFFF
            end)
            state.pending_heal_sample = {
                hit_point = hit_point,
                before = before,
                target = target,
                source = "hp_increase",
            }
        end, function(retval)
            local sample = state.pending_heal_sample
            state.pending_heal_sample = nil
            if type(sample) == "table" then
                if type(sample.target) == "number" and type(sample.before) == "number" then
                    local delta = sample.target - sample.before
                    if delta >= heal_delta_threshold(sample.hit_point) then
                        play_heal_if_hp_increased(sample.hit_point, sample.before, sample.source)
                    end
                else
                    play_heal_if_hp_increased(sample.hit_point, sample.before, sample.source)
                end
            end
            return retval
        end)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function install_heal_hook()
    if state.heal_hook_installed or state.heal_hook_failed then
        return
    end
    local td = sdk and sdk.find_type_definition and sdk.find_type_definition("app.HitPoint") or nil
    if td == nil then
        state.heal_hook_status = "waiting for app.HitPoint"
        return
    end
    local hooked = false
    local failed = false
    local failure = nil

    for _, candidate in ipairs({
        { signature = "recovery(System.Int32, app.HitPoint.RecoveryFactor)", source = "hp_recovery" },
        { signature = "recoveryRate(System.Single, app.HitPoint.RecoveryFactor)", source = "hp_recovery_rate" },
    }) do
        local ok, err = hook_heal_delta_method(td, candidate.signature, candidate.source)
        if ok then
            hooked = true
        elseif err ~= nil then
            failed = true
            failure = err
        end
    end

    local ok_set, err_set = hook_set_current_hit_point(td)
    if ok_set then
        hooked = true
    elseif err_set ~= nil then
        failed = true
        failure = err_set
    end

    state.heal_hook_installed = hooked
    if hooked then
        state.heal_hook_status = "installed hp delta"
    elseif failed then
        state.heal_hook_failed = true
        state.heal_hook_status = "failed: " .. tostring(failure)
        log_info("heal hook failed: " .. tostring(failure))
    else
        state.heal_hook_status = "waiting for app.HitPoint.recovery"
    end
end

local function install_hooks()
    install_fire_hook()
    install_heal_hook()
    install_native_event_hooks()
end

local function wrap_global_haptic_function(global_name, effect_key)
    local current = rawget(_G, global_name)
    if type(current) ~= "function" or current == state.wrappers[global_name] then
        return
    end

    state.originals[global_name] = current
    local wrapper = function(...)
        local results = { pcall(current, ...) }
        play_effect(effect_key, global_name)
        if results[1] then
            return unpack_values(results, 2)
        end
        return nil
    end
    state.wrappers[global_name] = wrapper
    _G[global_name] = wrapper
end

local function update_global_wrappers()
    wrap_global_haptic_function("re9_vr_trigger_melee_swing_haptic", "RE9_SH_Melee_Swing_R")
    wrap_global_haptic_function("re9_vr_trigger_melee_hit_haptic", "RE9_SH_Melee_Hit_R")
end

local function update_vigem_wrapper()
    if type(vigem) ~= "table" or type(vigem.set_button) ~= "function" then
        return
    end
    if vigem.set_button == state.vigem_set_button_wrapper then
        return
    end

    local original = vigem.set_button
    state.vigem_set_button_original = original
    local wrapper = function(button, pressed, ...)
        if tostring(button or "") == "LB" and (pressed == true or pressed == 1) then
            pcall(mark_possible_block_pose)
        end
        return original(button, pressed, ...)
    end
    state.vigem_set_button_wrapper = wrapper
    vigem.set_button = wrapper
end

local function update_holster_weapon_change()
    local now = os.clock()
    if rawget(_G, "__vr_in_holster_zone") == true then
        state.holster_zone_until = now + 0.45
    end

    local weapon_id = current_weapon_id()
    if state.last_weapon_id == nil then
        state.last_weapon_id = weapon_id
        return
    end

    if weapon_id ~= state.last_weapon_id then
        if now <= (state.holster_zone_until or 0.0) then
            play_effect(effect_for_holster(weapon_id or state.last_weapon_id), "holster_weapon_change")
        end
        state.last_weapon_id = weapon_id
    end
end

local function update_throwable_equip_edge()
    local now = os.clock()
    local weapon_id = current_weapon_id()
    local throwable_id = weapon_id ~= nil and THROWABLES[weapon_id] == true and weapon_id or nil
    if state.throwable_equip_observed ~= true then
        state.throwable_equip_observed = true
        state.last_throwable_weapon_id = throwable_id
        return
    end

    if throwable_id ~= nil and throwable_id ~= state.last_throwable_weapon_id then
        if now > (state.holster_zone_until or 0.0) then
            play_effect("RE9_SH_Throwable_Equip", "throwable_equip")
        end
    end
    state.last_throwable_weapon_id = throwable_id
end

local function update_axe_swing_edge()
    local active = rawget(_G, "vr_axe_swing") == true
    if active and not state.last_axe_swing_active then
        play_effect("RE9_SH_Melee_Swing_R", "vr_axe_swing")
    end
    state.last_axe_swing_active = active
end

local function update_block_pose_edge()
    local active = is_block_pose_active()
    if active and not state.last_block_pose_active then
        play_effect("RE9_SH_Block_Stance", "block_pose_active")
    end
    state.last_block_pose_active = active
end

local function update_bike_mode()
    local now = os.clock()
    local active = rawget(_G, "__vr_bike_fp_active") == true
    if active and not state.last_bike_active then
        play_effect("RE9_SH_Bike_Start", "bike_start")
        state.next_bike_rumble = now + 0.35
    end
    if active and now >= (state.next_bike_rumble or 0.0) then
        play_effect("RE9_SH_Bike_Rumble", "bike_rumble")
        state.next_bike_rumble = now + 0.75
    end
    if not active then
        state.next_bike_rumble = nil
    end
    state.last_bike_active = active
end

local function update_startup_feedback()
    if state.startup_played then
        return
    end
    if type(state.effects_by_key) ~= "table" or state.effects_by_key.RE9_SH_Startup == nil then
        return
    end
    if state.registered_all ~= true or os.clock() < (state.startup_ready_at or 0.0) then
        return
    end
    if play_effect("RE9_SH_Startup", "startup") then
        state.startup_played = true
    end
end

load_config()
load_effects()
install_hooks()

if re and re.on_frame then
    re.on_frame(function()
        install_hooks()
        register_pending()
        update_external_events()
        update_global_wrappers()
        update_vigem_wrapper()
        update_holster_weapon_change()
        update_throwable_equip_edge()
        update_axe_swing_edge()
        update_block_pose_edge()
        update_bike_mode()
        update_startup_feedback()
    end)
end

if re and re.on_script_reset then
    re.on_script_reset(function()
        state.registered_all = false
        state.startup_played = false
        state.startup_ready_at = 0.0
        state.external_events = {}
        state.last_bike_active = false
        state.last_block_pose_active = false
        state.next_bridge_connect_attempt = 0.0
        state.failed_bridge_connect_attempts = 0
        state.vigem_lb_parry_until = 0.0
        state.throwable_equip_observed = false
        state.last_throwable_weapon_id = nil
        state.last_reload_sound_id = nil
        state.last_reload_sound_until = 0.0
        state.reload_sound_context_until = 0.0
        for _, effect in ipairs(state.effects or {}) do
            effect.registered = false
            effect.next_allowed = 0.0
        end
    end)
end

_G.__vr_ui_callbacks = _G.__vr_ui_callbacks or {}
table.insert(_G.__vr_ui_callbacks, { order = 98, fn = function()
    imgui.text_colored("bHaptics:", 0xFF00FFFF)
    local changed, enabled = imgui.checkbox("##re9vr_simple_haptics_enabled", state.enabled ~= false)
    imgui.same_line()
    imgui.text_colored("Enable", 0xFF00FF00)
    imgui.same_line()
    imgui.text("RE9VR Simple Haptics")
    if changed then
        state.enabled = enabled and true or false
        save_config()
    end
    local bridge = resolve_bridge()
    imgui.text("Bridge: " .. (bridge and bridge.mode or "not ready"))
    local bridge_status = bridge and bridge.get_status and bridge.get_status() or nil
    if type(bridge_status) == "table" then
        local player_state = bridge_status.connected == true and "connected" or "not connected"
        local phase = tostring(bridge_status.phase or "")
        if phase ~= "" then
            player_state = player_state .. " (" .. phase .. ")"
        end
        imgui.text("Player: " .. player_state)
        if type(bridge_status.lastCommand) == "string" and bridge_status.lastCommand ~= "" then
            imgui.text("Last command: " .. bridge_status.lastCommand)
        end
        if type(bridge_status.lastError) == "string" and bridge_status.lastError ~= "" then
            imgui.text("Bridge error: " .. bridge_status.lastError)
        end
    end
    imgui.text("Fire hook: " .. tostring(state.fire_hook_status or (state.fire_hook_installed and "installed" or "waiting")))
    imgui.text("Heal hook: " .. tostring(state.heal_hook_status or (state.heal_hook_installed and "installed" or "waiting")))
    local installed_events = 0
    local waiting_events = 0
    for _, hook_state in pairs(state.native_hooks or {}) do
        if type(hook_state) == "table" and hook_state.installed then
            installed_events = installed_events + 1
        else
            waiting_events = waiting_events + 1
        end
    end
    imgui.text("Event hooks: " .. tostring(installed_events) .. " installed, " .. tostring(waiting_events) .. " waiting")
    if imgui.button("Preview revolver shot") then
        play_effect("RE9_SH_Shotgun_Right", "ui_preview_revolver")
    end
    imgui.same_line()
    if imgui.button("Preview healing") then
        play_effect("RE9_SH_Heal", "ui_preview_healing")
    end
    local last = rawget(_G, "RE9VR_SIMPLE_HAPTICS_LAST")
    if type(last) == "table" then
        imgui.text("Last: " .. tostring(last.key) .. " (" .. tostring(last.reason) .. ", " .. tostring(last.mode or "registered") .. ")")
    end
    imgui.separator()
end })

log_info("loaded registered metadata build")
