-- Trusted native integration fixture. The private channel is host-only test
-- automation; the fixture book has a different socket and cannot use it.

local InputDialog = require("ui/widget/inputdialog")
local PrivateChannel = require("private_channel")
local UIAudit = require("ui_audit")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")

local Probe = WidgetContainer:extend{
    name = "bookinteractionprobe",
    is_doc_only = true,
}

local GENERATION = 1
local QEMU_PRESENTATION_COUNT = 4
local ACTION_KEY = "wilkbook_qemu_fixture_action"
local fixed_inputs = {
    navigation = "Navigation draft",
    close = "Close draft",
}
local expected_startup_overlays = {
    ["Book info cache database updated."] = true,
    ["Documents will be rendered in color on this device.\n"
        .. "If your device is grayscale, you can disable color rendering in "
        .. "the screen sub-menu for reduced memory usage."] = true,
}

local function marker(text)
    print("BOOK_INTERACTION_READER: " .. text)
end

function Probe:_check(condition, message)
    if not condition then self:_fail(message) end
    return condition
end

function Probe:_cleanup()
    if self.has_interaction_dialog and UIManager:isWidgetShown(self.dialog) then
        UIManager:close(self.dialog)
    end
    if self.channel then
        UIManager:removeZMQ(self.channel)
        self.channel:stop()
        self.channel = nil
    end
    if self.action_factory then
        local expected = self.action_factory
        self.action_factory = nil
        local removed =
            self.ui.highlight:removeFromHighlightDialog(ACTION_KEY)
        self:_check(removed == expected,
            "selection removal did not return the registered callback")
        marker("selection-action:removed")
    end
    self.dialog = nil
    self.has_interaction_dialog = false
end

function Probe:_fail(message)
    if self.failed then return end
    self.failed = true
    marker("FAIL:" .. tostring(message))
    UIManager:nextTick(function()
        self:_cleanup()
        if self.audit then self.audit:restore() end
        UIManager:quit(1)
    end)
end

function Probe:init()
    self.state = "starting"
    self.failed = false
    local root = os.getenv("BOOK_INTERACTION_ROOT")
    if os.getenv("BOOK_INTERACTION_TRUSTED_NATIVE_FIXTURE") ~= "1"
            or not root
            or os.getenv("HOME") ~= root .. "/home"
            or os.getenv("KO_HOME") ~= root .. "/ko"
            or os.getenv("BOOK_INTERACTION_CONTROL_FD") ~= "3" then
        self:_fail("trusted fixture environment is not exact")
        return
    end
    local qemu_mode = os.getenv("BOOK_INTERACTION_QEMU_MODE")
    if qemu_mode and qemu_mode ~= "1" then
        self:_fail("QEMU fixture mode is not canonical")
        return
    end
    self.qemu_mode = qemu_mode == "1"
    self.update_input = os.getenv("BOOK_INTERACTION_UPDATE_INPUT")
    self.expected_result = os.getenv("BOOK_INTERACTION_EXPECTED_RESULT")
    if self.qemu_mode then
        if self.update_input or self.expected_result then
            self:_fail("QEMU UI fixture received a host result oracle")
            return
        end
        self.presentation_count = 0
        marker("plugin-init:trusted-qemu-ui-fixture")
    else
        if not self.update_input or self.update_input == ""
                or not self.expected_result or self.expected_result == "" then
            self:_fail("test oracle environment is incomplete")
            return
        end
        marker("plugin-init:trusted-native-fixture")
    end
end

function Probe:_send(kind, value)
    local ok, err = self.channel:send(kind, GENERATION, value or "")
    self:_check(ok, "private event enqueue failed: " .. tostring(err))
    return ok
end

function Probe:_submit()
    if not self:_check(self.state == "input-ready" and self.phase ~= nil,
            "dialog submit occurred outside an input phase") then
        return false, false
    end
    local phase = self.phase
    local content = self.dialog:getInputText()
    local expected_input = self.qemu_mode and self.current_input
        or self.inputs[phase]
    if not self:_check(UIManager:isWidgetShown(self.dialog),
            "InputDialog was not shown when its Save callback ran")
            or not self:_check(content == expected_input,
            "InputDialog did not submit its current fixture text") then
        return false, false
    end
    self.state = "waiting"
    marker("submit:" .. phase)
    self:_send("submit", content)
    if self.qemu_mode or phase ~= "update" then
        self.pending_tick_sent = false
        local submitted_at = time.now()
        UIManager:scheduleIn(0.1, function()
            if not self.channel or self.channel.closed then return end
            local elapsed_ms = time.to_ms(time.since(submitted_at))
            if not self:_check(self.state == "waiting" and self.phase == phase,
                    "scheduled UI task did not run during the pending wait")
                    or not self:_check(elapsed_ms >= 70 and elapsed_ms <= 300,
                        "scheduled UI task ran outside the delayed reply window")
                    or not self:_check(UIManager:isWidgetShown(self.dialog)
                        and UIManager:getTopmostVisibleWidget() == self.dialog
                        and self.dialog:getInputText() == expected_input,
                        "InputDialog was not topmost during the delayed wait") then
                return
            end
            marker("ui-wait-task:" .. phase .. ":topmost-during-delay")
            self.pending_tick_sent = true
            self:_send("tick", phase)
        end)
    end
    -- Exercise InputDialog's real rejected/pending branch without a message.
    return false, false
end

function Probe:_set_qemu_input(value)
    if not self:_check(self.state == "ready" or self.state == "applied",
            "new QEMU input arrived while another interaction was pending")
            or not self:_check(self.presentation_count
                    < QEMU_PRESENTATION_COUNT,
                "QEMU UI fixture received too many inputs")
            or not self:_check(value ~= "",
                "QEMU UI fixture received an empty input") then
        return
    end
    self.phase = "qemu-" .. tostring(self.presentation_count + 1)
    self.current_input = value
    self.state = "input-ready"
    self.dialog:setInputText(value, true)
    if not self:_check(self.dialog:getInputText() == value,
            "InputDialog did not retain QEMU fixture input") then
        return
    end
    marker("dialog-input:" .. self.phase)
    local save = self.dialog.button_table:getButtonById("save")
    if not self:_check(save and save.enabled,
            "InputDialog save button is unavailable") then
        return
    end
    UIManager:nextTick(function()
        save.callback()
        self:_check(save.enabled,
            "pending InputDialog callback incorrectly disabled Save")
    end)
end

function Probe:_set_input(phase, value)
    if not self:_check(self.state == "ready" or self.state == "applied",
            "new input arrived while another interaction was pending")
            or not self:_check(value == self.inputs[phase],
                "host sent unexpected fixture input") then
        return
    end
    self.phase = phase
    self.state = "input-ready"
    self.dialog:setInputText(value, true)
    if not self:_check(self.dialog:getInputText() == value,
            "InputDialog did not retain fixture input") then
        return
    end
    marker("dialog-input:" .. phase)
    local save = self.dialog.button_table:getButtonById("save")
    if not self:_check(save and save.enabled,
            "InputDialog save button is unavailable") then
        return
    end
    UIManager:nextTick(function()
        save.callback()
        self:_check(save.enabled,
            "pending InputDialog callback incorrectly disabled Save")
    end)
end

function Probe:_await_presentation_paint(value, phase, paints_before, attempt)
    if not self:_check(self.state == "painting-presentation"
            and self.phase == phase,
            "presentation paint check ran in the wrong phase")
            or not self:_check(UIManager:isWidgetShown(self.dialog)
                and UIManager:getTopmostVisibleWidget() == self.dialog,
                "InputDialog was not topmost at presentation paint check")
            or not self:_check(self.dialog:getInputText() == value,
                "presentation text was not retained through repaint") then
        return
    end
    if self.audit:topmostPaintCount(value) <= paints_before then
        if attempt >= 20 then
            self:_fail("exact presentation lacked a real topmost paintTo")
            return
        end
        -- SDL/offscreen may coalesce a dirty request with the preceding dialog
        -- edit. Keep requesting this same real widget within a finite one-second
        -- observation window; never acknowledge before inherited paintTo ran.
        UIManager:setDirty(self.dialog, "ui")
        UIManager:scheduleIn(0.05, function()
            self:_await_presentation_paint(
                value, phase, paints_before, attempt + 1)
        end)
        return
    end
    marker("present-painted-exact:" .. value)
    if self.qemu_mode then
        self.presentation_count = self.presentation_count + 1
    end
    self.state = "applied"
    self:_send("applied", value)
end

function Probe:_handle_command(message)
    if message.generation ~= GENERATION then
        self:_fail("private control generation mismatch")
        return
    end
    local kind, value = message.kind, message.value
    if kind == "input-update" then
        if self.qemu_mode then
            self:_set_qemu_input(value)
        else
            self:_set_input("update", value)
        end
    elseif kind == "input-navigation" then
        self:_set_input("navigation", value)
    elseif kind == "input-close" then
        self:_set_input("close", value)
    elseif kind == "present" then
        local expected_phase = self.phase
        local presentation_valid = self.state == "waiting"
            and (self.qemu_mode or self.phase == "update")
        if not self:_check(presentation_valid,
                "presentation arrived outside update wait")
                or (self.qemu_mode and not self:_check(
                    self.pending_tick_sent == true,
                    "QEMU presentation arrived before the scheduled UI tick"))
                or (not self.qemu_mode and not self:_check(
                    value == self.expected_result,
                    "presentation did not match the independent test oracle")) then
            return
        end
        local top = UIManager:getTopmostVisibleWidget()
        if not UIManager:isWidgetShown(self.dialog) or top ~= self.dialog then
            self:_fail("InputDialog was not topmost before presentation; top-text="
                .. tostring(top and top.text))
            return
        end
        local paints_before = self.audit:topmostPaintCount(value)
        self.audit:armPaint(value)
        self.dialog:setInputText(value, true)
        UIManager:setDirty(self.dialog, "ui")
        self.state = "painting-presentation"
        UIManager:scheduleIn(0.05, function()
            self:_await_presentation_paint(
                value, expected_phase, paints_before, 1)
        end)
    elseif kind == "stale-navigation" then
        if not self:_check(self.state == "waiting"
                and self.phase == "navigation",
                "navigation rejection arrived outside navigation wait")
                or not self:_check(UIManager:isWidgetShown(self.dialog)
                    and UIManager:getTopmostVisibleWidget() == self.dialog
                    and self.dialog:getInputText() == self.inputs.navigation,
                    "stale navigation reply changed InputDialog text") then
            return
        end
        marker("stale-navigation:dialog-preserved")
        self.state = "applied"
        self:_send("applied", "navigation")
    elseif kind == "closed" then
        if not self:_check(self.state == "waiting" and self.phase == "close",
                "close result arrived outside close wait")
                or not self:_check(UIManager:isWidgetShown(self.dialog)
                    and UIManager:getTopmostVisibleWidget() == self.dialog
                    and self.dialog:getInputText() == self.inputs.close,
                    "stale close reply changed InputDialog text") then
            return
        end
        self.dialog:setInputText("Session closed; stale reply rejected", true)
        self:_check(self.dialog:getInputText()
                == "Session closed; stale reply rejected",
            "close status did not update the actual InputDialog")
        marker("close:dialog-responsive-and-preserved")
        self.state = "applied"
        self:_send("applied", "close")
    elseif kind == "finish" then
        local finish_valid = self.state == "applied"
            and ((self.qemu_mode
                    and self.presentation_count == QEMU_PRESENTATION_COUNT)
                or (not self.qemu_mode and self.phase == "close"))
        if not self:_check(finish_valid,
                "finish arrived before all UI acknowledgements") then
            return
        end
        self:_send("done", "ok")
        self.state = "done"
        UIManager:nextTick(function()
            marker("cleanup-audit:before-quit")
            self:_cleanup()
            local ok, err = self.audit:verifyCleanup()
            if not ok then
                self.failed = true
                marker("FAIL:cleanup audit: " .. err)
                UIManager:quit(1)
                return
            end
            marker("cleanup-audit:dialog-source-channel-fd-callback:clean")
            if self.qemu_mode then
                marker("qemu-presentations-painted:"
                    .. tostring(self.presentation_count))
            end
            marker("result:ok")
            UIManager:quit(0)
        end)
    else
        self:_fail("unknown private command")
    end
end

function Probe:_make_channel()
    self.channel = PrivateChannel:new{
        fd = 3,
        receive = function(message) self:_handle_command(message) end,
        on_error = function(err) self:_fail(err) end,
    }
    self.audit:retainChannel(self.channel)
    UIManager:insertZMQ(self.channel)
    marker("private-source-registered")
end

function Probe:_open_qemu_interaction()
    if not self:_check(not self.has_interaction_dialog,
            "QEMU selection action opened a duplicate interaction") then
        return
    end
    marker("selection-action:invoked-by-fixture")
    self.dialog = InputDialog:new{
        title = "Book interaction QEMU fixture",
        input = "Waiting for guest authority",
        allow_newline = true,
        keyboard_visible = false,
        save_callback = function() return self:_submit() end,
    }
    self.has_interaction_dialog = true
    self.audit:retainDialog(self.dialog)
    UIManager:show(self.dialog)
    if not self:_check(UIManager:isWidgetShown(self.dialog)
            and self.dialog:isTextEditable(),
            "real InputDialog was not shown and editable") then
        return
    end
    marker("dialog-shown")
    if not self:_dismiss_startup_overlays() then return end
    self:_announce_ready_when_topmost(0)
end

function Probe:_on_qemu_reader_ready()
    if not self:_check(type(self.ui.highlight.addToHighlightDialog) == "function"
            and type(self.ui.highlight.removeFromHighlightDialog) == "function",
            "ReaderHighlight selection seams are unavailable") then
        return
    end
    self.audit = UIAudit:new(UIManager)
    self:_make_channel()
    self.action_factory = function()
        return {
            text = "Open book interaction fixture",
            callback = function() self:_open_qemu_interaction() end,
        }
    end
    local expected = self.action_factory
    self.audit:retainAction(self.ui.highlight, ACTION_KEY, expected)
    self.ui.highlight:addToHighlightDialog(ACTION_KEY, expected)
    local adds, removes = self.audit:actionCounts()
    if not self:_check(
            self.ui.highlight._highlight_buttons[ACTION_KEY] == expected,
            "selection action was not present in ReaderHighlight registry")
            or not self:_check(adds == 1 and removes == 0,
                "selection action did not use the public add seam") then
        return
    end
    marker("selection-action:registered")
    UIManager:nextTick(function()
        local registered = self.ui.highlight._highlight_buttons[ACTION_KEY]
        if not self:_check(registered == expected,
                "registered selection action changed before invocation") then
            return
        end
        local button = registered(self.ui.highlight, 1)
        if self:_check(type(button) == "table"
                and type(button.callback) == "function",
                "selection action did not produce a button") then
            button.callback()
        end
    end)
end

function Probe:_announce_ready_when_topmost(attempt)
    if self.failed then return end
    if UIManager:isWidgetShown(self.dialog)
            and UIManager:getTopmostVisibleWidget() == self.dialog then
        self.state = "ready"
        marker("dialog-topmost")
        self:_send("ready", "dialog")
    elseif attempt >= 40 then
        self:_fail("InputDialog did not become topmost after startup")
    else
        UIManager:scheduleIn(0.05, function()
            self:_announce_ready_when_topmost(attempt + 1)
        end)
    end
end

function Probe:_dismiss_startup_overlays()
    local dismissed = 0
    local seen = {}
    local top = UIManager:getTopmostVisibleWidget()
    while top and top ~= self.dialog and dismissed < 8 do
        if not expected_startup_overlays[top.text] or seen[top.text] then
            self:_fail("unexpected startup overlay above InputDialog: "
                .. tostring(top.text))
            return false
        end
        seen[top.text] = true
        UIManager:close(top)
        dismissed = dismissed + 1
        top = UIManager:getTopmostVisibleWidget()
    end
    if not self:_check(top == self.dialog,
            "could not make InputDialog topmost before fixture readiness") then
        return false
    end
    if not self:_check(dismissed == 2,
            "clean profile did not show both pinned startup overlays") then
        return false
    end
    marker("startup-overlays-dismissed:" .. dismissed)
    return true
end

function Probe:onReaderReady()
    if self.failed then return end
    if self.qemu_mode then
        self:_on_qemu_reader_ready()
        return
    end
    self.inputs = {
        update = self.update_input,
        navigation = fixed_inputs.navigation,
        close = fixed_inputs.close,
    }
    self.audit = UIAudit:new(UIManager)
    self.dialog = InputDialog:new{
        title = "Book interaction fixture",
        input = "Waiting for fixture host",
        allow_newline = true,
        keyboard_visible = false,
        save_callback = function() return self:_submit() end,
    }
    self.has_interaction_dialog = true
    self.audit:retainDialog(self.dialog)
    self:_make_channel()
    UIManager:nextTick(function()
        UIManager:show(self.dialog)
        if not self:_check(UIManager:isWidgetShown(self.dialog)
                and self.dialog:isTextEditable(),
                "real InputDialog was not shown and editable") then
            return
        end
        marker("dialog-shown")
        if not self:_dismiss_startup_overlays() then return end
        self:_announce_ready_when_topmost(0)
    end)
end

function Probe:onCloseDocument()
    self:_cleanup()
end

return Probe
