local root = arg[1] or "../../packages/koreader-device/frontend/device/pinenote"
local function slurp(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
local device, powerd = slurp(root .. "/device.lua"), slurp(root .. "/powerd.lua")
local failures = 0
local function check(ok, label)
    print((ok and "PASS: " or "FAIL: ") .. label); if not ok then failures = failures + 1 end
end
check(not device:find('WILKBOOK_PINENOTE_VALIDATION', 1, true), "production driver needs no early validation patch")
check(device:find('canSuspend = suspend_qualified', 1, true), "production exposes canSuspend")
check(device:find('local suspend_qualified = true', 1, true), "hardware acceptance promotes suspend")
check(device:find('suspend_wait_timeout = 3', 1, true),
      "KOReader acknowledgement is scheduled before the broker deadline")
check(device:find('function PineNote:supportsScreensaver()', 1, true), "screensaver support is implemented")
check(device:find('wilkbook-power-control', 1, true) and device:find('[142] = "BrokerSleep"', 1, true)
      and device:find('[143] = "BrokerWake"', 1, true)
      and device:find('if ev.value == 1 then return "Suspend" end', 1, true)
      and device:find('if ev.value == 1 then return "Resume" end', 1, true),
      "broker virtual keys adapt directly to one Suspend and Resume event")
check(device:find('setRequiredDevice(devs.power_control)', 1, true), "broker input loss forces reader restart")
check(device:find('/run/wilkbook-power/request', 1, true) and device:find('ready ', 1, true), "ready protocol is wired")
check(device:find('os.execute("/run/current-system/profile/sbin/halt")', 1, true)
      and not device:find('halt -p', 1, true)
      and device:find('/run/current-system/profile/sbin/reboot', 1, true),
      "power commands use the installed Shepherd interfaces by absolute path")
check(device:find('pinenote%-wifi%-control') and device:find('restoreWifiAsync', 1, true), "Wi-Fi toggle and restore are wired")
check(device:find('/run/current%-system/profile/bin/pinenote%-wifi%-control'),
      "Wi-Fi control uses the packaged production helper")
check(device:find('if ok and complete_callback then complete_callback() end', 1, true),
      "Wi-Fi completion callback is not reported on helper failure")
check(device:find('hasWifiManager = no', 1, true)
      and not device:find('setWirelessBackend', 1, true),
      "Wi-Fi toggle does not require the omitted lj-wpaclient module")
check(device:find("honors KOReader's auto_restore_wifi preference", 1, true)
      and not device:find('restore_wifi_after_resume', 1, true),
      "KOReader remains the sole owner of Wi-Fi restore policy")
check(powerd:find('self.device:_beforeSuspend()', 1, true) and powerd:find('self.device:_afterResume()', 1, true),
      "powerd quarantines and restores input")
check(powerd:find('local total = cool_level + warm_level', 1, true)
      and powerd:find('warm_level / total', 1, true),
      "powerd reconstructs aggregate intensity and warmth from both channels")
check(powerd:find('hw_intensity', 1, true)
      and powerd:find('function PineNotePowerD:isFrontlightOnHW()', 1, true)
      and powerd:find('self:_decideFrontlightState()', 1, true),
      "frontlight keeps restore intensity separate from applied hardware state")
os.exit(failures == 0 and 0 or 1)
