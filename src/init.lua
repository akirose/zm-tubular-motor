local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local window_preset_defaults = require "st.zigbee.defaults.windowShadePreset_defaults"
local log = require "log"

local CLUSTER_TUYA = 0xEF00
local SET_DATA = 0x00
local DP_TYPE_BOOL = "\x01"
local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

-- data points
local DP_STATE = "\x01"
local DP_MOTOR_POSITION = "\x02"
local DP_MOTOR_ARRIVED = "\x03"
local DP_MOTOR_DIRECTION = "\x05"

-- motor states
local MOTOR_STATE_OPEN = "\x00"
local MOTOR_STATE_CLOSE = "\x02"
local MOTOR_STATE_STOP = "\x01"
local MOTOR_STATE_STEP_OPEN = "\x03"  -- not tested
local MOTOR_STATE_STEP_CLOSE = "\x04" -- not tested

local packet_id = 0

local function send_tuya_command(device, dp, dp_type, fncmd)
    local header_args = {
        cmd = data_types.ZCLCommandId(SET_DATA)
    }
    local zclh = zcl_messages.ZclHeader(header_args)
    zclh.frame_ctrl:set_cluster_specific()
    local addrh = messages.AddressHeader(
        zb_const.HUB.ADDR,
        zb_const.HUB.ENDPOINT,
        device:get_short_address(),
        device:get_endpoint(CLUSTER_TUYA),
        zb_const.HA_PROFILE_ID,
        CLUSTER_TUYA
    )
    packet_id = (packet_id + 1) % 65536
    local fncmd_len = string.len(fncmd)
    local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) ..
        dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
    local message_body = zcl_messages.ZclMessageBody({
        zcl_header = zclh,
        zcl_body = payload_body
    })
    local send_message = messages.ZigbeeMessageTx({
        address_header = addrh,
        body = message_body
    })
    device:send(send_message)
end

local function tuya_cluster_handler(driver, device, zb_rx)
    local rx = zb_rx.body.zcl_body.body_bytes
    local dp = string.byte(rx:sub(3, 3))
    local fncmd_len = string.unpack(">I2", rx:sub(5, 6))
    local fncmd = string.unpack(">I" .. fncmd_len, rx:sub(7))
    log.debug(string.format("dp=%d, fncmd=%d", dp, fncmd))

    if dp == DP_MOTOR_POSITION or dp == DP_MOTOR_ARRIVED then
        local position = device.preferences.reverse and 100 - (fncmd & 0xff) or (fncmd & 0xff)
        local running = dp ~= DP_MOTOR_ARRIVED

        if device:get_field("running_timer") ~= nil then
            device.thread:cancel_timer(device:get_field("running_timer"))
        end
        device:set_field("running_timer", device.thread:call_with_delay(3.0, function (d)
            log.debug("motor stopped")
        end))

        if position > 0 and position < 100 then
            log.debug("Running: " + running + ", Position: " + position + ", Partially open")
        elseif position == 0 then
            log.debug("Running: " + running + ", Position: " + position + ", Close")
        elseif position == 100 then
            log.debug("Running: " + running + ", Position: " + position + ", Open")
        else
            log.debug("Running: " + running)
        end
    end
end

local function get_current_level(device)
    return device:get_latest_state("main", capabilities.windowShadeLevel.ID,
        capabilities.windowShadeLevel.shadeLevel.NAME)
end

-- Device handlers
local function open_handler(driver, device)
    local current_level = get_current_level(device)
    if current_level == 100 then
        device:emit_event(capabilities.windowShade.windowShade.open())
    end
    send_tuya_command(device, DP_STATE, DP_TYPE_ENUM, MOTOR_STATE_OPEN)
end

local function close_handler(driver, device)
    local current_level = get_current_level(device)
    if current_level == 0 then
        device:emit_event(capabilities.windowShade.windowShade.closed())
    end
    send_tuya_command(device, DP_STATE, DP_TYPE_ENUM, MOTOR_STATE_CLOSE)
end

local function pause_handler(driver, device)
    local current_state = device:get_latest_state("main", capabilities.windowShade.ID,
        capabilities.windowShade.windowShade.NAME)
    device:emit_event(capabilities.windowShade.windowShade(current_state))
    send_tuya_command(device, DP_STATE, DP_TYPE_ENUM, MOTOR_STATE_STOP)
end

local function shade_level_handler(driver, device, command)
    send_tuya_command(device, DP_MOTOR_POSITION, DP_TYPE_VALUE, string.pack(">I4", level_val(device, command.args.shadeLevel)))
end

local function switch_level_handler(driver, device, command)
    shade_level_handler(driver, device, { args = { shadeLevel = command.args.level } })
end

local function preset_position_handler(driver, device)
    local level = device.preferences.presetPosition or device:get_field(window_preset_defaults.PRESET_LEVEL_KEY) or window_preset_defaults.PRESET_LEVEL
    shade_level_handler(driver, device, { args = { shadeLevel = level } })
end

-- Lifecycle handlers
local function device_added(driver, device)
    device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({"open", "close", "pause"}))
end

local function device_init(driver, device)
    
end

local function device_info_changed(driver, device, event, args)
        
end

-- Driver definitions
local zm_tubular_motor = {
    supported_capabilities = {
        capabilities.windowShade,
        capabilities.windowShadePreset,
        capabilities.windowShadeLevel,
        capabilities.switchLevel
    },
    zigbee_handlers = {
        cluster = {
            [CLUSTER_TUYA] = {
                [0x01] = tuya_cluster_handler,
                [0x02] = tuya_cluster_handler
            }
        }
    },
    capability_handlers = {
        [capabilities.windowShade.ID] = {
            [capabilities.windowShade.commands.open.NAME] = open_handler,
            [capabilities.windowShade.commands.close.NAME] = close_handler,
            [capabilities.windowShade.commands.pause.NAME] = pause_handler
        },
        [capabilities.windowShadePreset.ID] = {
            [capabilities.windowShadePreset.commands.presetPosition.NAME] = preset_position_handler
        },
        [capabilities.windowShadeLevel.ID] = {
            [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = shade_level_handler
        },
        [capabilities.switchLevel.ID] = {
            [capabilities.switchLevel.commands.setLevel.NAME] = switch_level_handler
        }
    },
    lifecycle_handlers = {
        added = device_added,
        init = device_init,
        infoChanged = device_info_changed
    }
}

local zigbee_driver = ZigbeeDriver("zemismart-tubular-motor", zm_tubular_motor)
zigbee_driver:run()
