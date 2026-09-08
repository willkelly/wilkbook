-- Trusted persistent-note UI fixture.  Lua owns only widget state and paint;
-- the connected Guile side is the storage/protocol authority.

local InputDialog = require("ui/widget/inputdialog")
local StateChannel = require("state_channel")
local UIAudit = require("ui_audit")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Probe = WidgetContainer:extend{
    name = "bookstatereader",
    is_doc_only = true,
}

local ACTION_KEY = "wilkbook_persistent_note_fixture_action"
local MAX_TEXT_BYTES = 4096
local STATE_TITLES = {
    ["awaiting-load"] = "Persistent note — Loading",
    ["loaded-absent"] = "Persistent note — No saved note",
    ["loaded-value"] = "Persistent note — Loaded",
    dirty = "Persistent note — Unsaved changes",
    pending = "Persistent note — Saving…",
    saved = "Persistent note — Saved",
    failed = "Persistent note — Save failed; draft retained",
}
local FAILURE_CODES = {
    ["receipt-quota-exhausted"] = true,
    ["read-only"] = true,
    ["storage-failure"] = true,
    conflict = true,
}
local EMPTY_COMMANDS = {
    open = true,
    ["load-absent"] = true,
    save = true,
    navigate = true,
    close = true,
    finish = true,
}
local expected_startup_overlays = {
    ["Book info cache database updated."] = true,
    ["Documents will be rendered in color on this device.\n"
        .. "If your device is grayscale, you can disable color rendering in "
        .. "the screen sub-menu for reduced memory usage."] = true,
}

local function marker(text)
    print("BOOK_STATE_READER: " .. text)
end

function Probe:_check(condition, message)
    if not condition then self:_fail(message) end
    return condition
end

function Probe:_fail(message)
    if self.failed then return end
    self.failed = true
    marker("FAIL:" .. tostring(message))
    UIManager:nextTick(function()
        self:_cleanup(false)
        if self.audit then self.audit:restore() end
        UIManager:quit(1)
    end)
end

function Probe:init()
    self.failed = false
    self.cleaned = false
    self.last_generation = 0
    self.render_token = 0
    self.startup_overlays_dismissed = false
    self.startup_overlays_reported = false
    local root = os.getenv("BOOK_STATE_READER_ROOT")
    local mode = os.getenv("BOOK_STATE_READER_MODE")
    if os.getenv("BOOK_STATE_READER_TRUSTED_FIXTURE") ~= "1"
            or not root
            or os.getenv("HOME") ~= root .. "/home"
            or os.getenv("KO_HOME") ~= root .. "/ko"
            or os.getenv("BOOK_STATE_READER_CONTROL_FD") ~= "3"
            or (mode ~= "automated" and mode ~= "interactive") then
        self:_fail("trusted fixture environment is not exact")
        return
    end
    self.fixture_mode = mode
    marker("plugin-init:trusted-" .. mode .. "-fixture")
end

function Probe:_send(kind, generation, value)
    if not self.channel then return false end
    local ok, err = self.channel:send(kind, generation, value or "")
    self:_check(ok, "private event enqueue failed: " .. tostring(err))
    return ok
end

function Probe:_empty_value(message)
    if EMPTY_COMMANDS[message.kind] and message.value ~= "" then
        self:_fail(message.kind .. " command carried a nonempty value")
        return false
    end
    return true
end

function Probe:_save_button()
    return self.note_dialog and self.note_dialog.button_table:getButtonById("save")
end

function Probe:_set_save_enabled(enabled)
    local save = self:_save_button()
    if not self:_check(save ~= nil, "real InputDialog has no Save button") then
        return
    end
    if enabled then save:enable() else save:disable() end
    self.note_dialog:refreshButtons()
end

function Probe:_await_state_paint(token, generation, dialog, arm, state, attempt)
    if self.failed or token ~= self.render_token then return end
    if not self:_check(self.note_dialog == dialog
            and self.generation == generation and self.state == state,
            "state paint confirmation outlived its exact UI state") then
        return
    end
    if arm.seen then
        marker(string.format("status-painted:generation=%d:state=%s",
            generation, state))
        self:_send("status", generation, state)
    elseif attempt >= 20 then
        self:_fail("state confirmation lacked inherited topmost paintTo")
    else
        UIManager:setDirty(dialog, "ui")
        UIManager:scheduleIn(0.05, function()
            self:_await_state_paint(
                token, generation, dialog, arm, state, attempt + 1)
        end)
    end
end

function Probe:_set_state(state)
    local title = STATE_TITLES[state]
    if not self:_check(title ~= nil, "unknown reader UI state") then return end
    self.state = state
    self.render_token = self.render_token + 1
    local token = self.render_token
    local generation = self.generation
    local dialog = self.note_dialog
    dialog.title_bar:setTitle(title)
    local arm = self.audit:armState(
        self.note_dialog_record, state, title, dialog:getInputText())
    UIManager:setDirty(dialog, "ui")
    UIManager:scheduleIn(0.05, function()
        self:_await_state_paint(token, generation, dialog, arm, state, 1)
    end)
end

function Probe:_await_presentation_paint(token, generation, dialog, arm,
        value, attempt)
    if self.failed or token ~= self.presentation_token then return end
    if not self:_check(self.note_dialog == dialog and self.generation == generation,
            "presentation paint confirmation outlived its interaction")
            or not self:_check(dialog:getInputText() == value,
                "authority presentation changed before paint") then
        return
    end
    if arm.seen then
        marker(string.format(
            "presentation-painted:generation=%d:text-bytes=%d",
            generation, #value))
        self:_send("applied", generation, value)
    elseif attempt >= 20 then
        self:_fail("authority presentation lacked inherited topmost paintTo")
    else
        UIManager:setDirty(dialog, "ui")
        UIManager:scheduleIn(0.05, function()
            self:_await_presentation_paint(
                token, generation, dialog, arm, value, attempt + 1)
        end)
    end
end

function Probe:_present(value)
    local generation = self.generation
    local dialog = self.note_dialog
    self.suppress_edit = true
    dialog:setInputText(value, false, true)
    self.suppress_edit = false
    if not self:_check(dialog:getInputText() == value,
            "InputDialog did not retain authority presentation") then
        return
    end
    self.presentation_token = (self.presentation_token or 0) + 1
    local token = self.presentation_token
    local title = dialog.title_bar.title
    local arm = self.audit:armPresentation(self.note_dialog_record, title, value)
    UIManager:setDirty(dialog, "ui")
    UIManager:scheduleIn(0.05, function()
        self:_await_presentation_paint(token, generation, dialog, arm, value, 1)
    end)
end

function Probe:_on_edited(edited)
    if self.suppress_edit or not edited or not self.note_dialog then return end
    if self.state == "pending" then
        self.pending_has_newer_edit = true
        return
    end
    if self.state == "loaded-absent" or self.state == "loaded-value"
            or self.state == "saved" or self.state == "failed"
            or self.state == "dirty" then
        if self.state ~= "dirty" then self:_set_state("dirty") end
    else
        self:_fail("InputDialog edit occurred before authority load")
    end
end

function Probe:_submit(content)
    if not self:_check(self.note_dialog ~= nil and self.generation ~= nil,
            "save callback ran without an interaction") then
        return false, false
    end
    if self.state == "pending" then
        self:_send("ignored", self.generation, "save")
        return false, false
    end
    if not self:_check(self.state == "dirty" or self.state == "failed",
            "save callback ran outside dirty/failed state") then
        return false, false
    end
    if #content > MAX_TEXT_BYTES or not StateChannel.validText(content) then
        self:_set_state("failed")
        self:_set_save_enabled(true)
        return false, false
    end
    self.pending_text = content
    self.pending_has_newer_edit = false
    self:_set_save_enabled(false)
    self:_set_state("pending")
    marker(string.format("submit:generation=%d:text-bytes=%d",
        self.generation, #content))
    self:_send("submit", self.generation, content)
    -- Keep KOReader's generated dialog open, suppress its generic failure
    -- modal, and wait for the Guile authority's explicit receipt/failure.
    return false, false
end

function Probe:_load(value, present)
    if not self:_check(self.state == "awaiting-load",
            "authority load arrived outside awaiting-load") then return end
    self.suppress_edit = true
    self.note_dialog:setInputText(value, false, true)
    self.suppress_edit = false
    self.baseline_text = value
    self.last_committed_text = nil
    self:_set_save_enabled(false)
    self:_set_state(present and "loaded-value" or "loaded-absent")
    -- Loaded state is a presentation too, including present empty text.  Its
    -- applied event remains only a paint observation, never a save receipt.
    self:_present(value)
end

function Probe:_commit_ok(value)
    if not self:_check(self.state == "pending"
            and self.pending_text ~= nil and value == self.pending_text,
            "commit receipt did not match the one pending submission") then
        return
    end
    local current = self.note_dialog:getInputText()
    self.last_committed_text = value
    self.baseline_text = value
    self.pending_text = nil
    if current == value and not self.pending_has_newer_edit then
        self.suppress_edit = true
        self.note_dialog:setInputText(current, false)
        self.suppress_edit = false
        self:_set_save_enabled(false)
        -- This is the only transition that can display Saved.
        self:_set_state("saved")
    else
        self:_set_save_enabled(true)
        self:_set_state("dirty")
    end
end

function Probe:_commit_failed(code)
    if not self:_check(self.state == "pending" and self.pending_text ~= nil,
            "commit failure arrived without a pending submission")
            or not self:_check(FAILURE_CODES[code] == true,
                "commit failure code is not closed") then
        return
    end
    self.pending_text = nil
    self.pending_has_newer_edit = false
    self:_set_save_enabled(true)
    self:_set_state("failed")
    marker("commit-failed:" .. code .. ":draft-retained")
end

function Probe:_invalidate(reason, close_widget)
    local dialog = self.note_dialog
    local generation = self.generation
    if not dialog or not generation then return false end
    self.render_token = self.render_token + 1
    self.presentation_token = (self.presentation_token or 0) + 1
    self.note_dialog = nil
    self.note_dialog_record = nil
    self.generation = nil
    self.state = "inactive"
    self.pending_text = nil
    self.pending_has_newer_edit = false
    self.last_committed_text = nil
    if close_widget and UIManager:isWidgetShown(dialog) then
        UIManager:close(dialog)
    end
    marker(reason .. ":generation=" .. generation)
    self:_send(reason == "navigated" and "navigated" or "closed",
        generation, "")
    return true
end

function Probe:_on_dialog_close()
    -- InputDialog itself closes immediately after this callback returns.
    self:_invalidate("closed", false)
end

function Probe:_dismiss_startup_overlays(report)
    if self.startup_overlays_dismissed then
        if report and not self.startup_overlays_reported then
            self.startup_overlays_reported = true
            marker("startup-overlays-dismissed:2")
        end
        return true
    end
    local dismissed = 0
    local seen = {}
    local top = UIManager:getTopmostVisibleWidget()
    while top and dismissed < 2 do
        if not expected_startup_overlays[top.text] or seen[top.text] then
            self:_fail("unexpected startup overlay above target: "
                .. tostring(top.text))
            return false
        end
        seen[top.text] = true
        UIManager:close(top)
        dismissed = dismissed + 1
        top = UIManager:getTopmostVisibleWidget()
    end
    if top and top.modal and top ~= self.ui then
        self:_fail("unexpected additional startup overlay: "
            .. tostring(top.text))
        return false
    end
    if not self:_check(dismissed == 2,
                "clean profile did not show both pinned startup overlays") then
        return false
    end
    self.startup_overlays_dismissed = true
    if report then
        self.startup_overlays_reported = true
        marker("startup-overlays-dismissed:2")
    end
    return true
end

function Probe:_announce_ready(attempt, generation, dialog)
    if self.failed or self.note_dialog ~= dialog or self.generation ~= generation then
        return
    end
    if UIManager:isWidgetShown(dialog)
            and UIManager:getTopmostVisibleWidget() == dialog then
        marker("dialog-ready:generation=" .. generation)
        self:_send("ready", generation, "")
    elseif attempt >= 40 then
        self:_fail("InputDialog did not become topmost")
    else
        UIManager:scheduleIn(0.05, function()
            self:_announce_ready(attempt + 1, generation, dialog)
        end)
    end
end

function Probe:_open_interaction(requested_generation)
    if not self:_check(not self.note_dialog,
            "selection action opened a duplicate interaction") then return end
    local generation = requested_generation or (self.last_generation + 1)
    if not self:_check(generation == self.last_generation + 1,
            "interaction generation is not the exact successor") then return end
    self.last_generation = generation
    self.generation = generation
    self.state = "awaiting-load"
    self.note_dialog = InputDialog:new{
        title = STATE_TITLES["awaiting-load"],
        input = "",
        allow_newline = true,
        keyboard_visible = self.fixture_mode == "interactive",
        save_callback = function(content) return self:_submit(content) end,
        edited_callback = function(edited) self:_on_edited(edited) end,
        close_callback = function() self:_on_dialog_close() end,
    }
    self.note_dialog_record = self.audit:retainDialog(self.note_dialog, generation)
    UIManager:show(self.note_dialog)
    if not self:_check(UIManager:isWidgetShown(self.note_dialog)
            and self.note_dialog:isTextEditable(),
            "real InputDialog was not shown and editable") then return end
    marker("dialog-shown:generation=" .. generation)
    if not self:_dismiss_startup_overlays(true) then return end
    self:_announce_ready(0, generation, self.note_dialog)
end

function Probe:_invoke_action(generation)
    local registered = self.ui.highlight._highlight_buttons[ACTION_KEY]
    if not self:_check(registered == self.action_factory,
            "registered action changed before invocation") then return end
    local button = registered(self.ui.highlight, 1)
    if not self:_check(type(button) == "table"
            and type(button.callback) == "function",
            "selection action did not produce a callable button") then return end
    self.requested_generation = generation
    button.callback()
    self.requested_generation = nil
end

function Probe:_ignore(message)
    marker(string.format("late-command-ignored:generation=%d:kind=%s",
        message.generation, message.kind))
    self:_send("ignored", message.generation, message.kind)
end

function Probe:_handle_command(message)
    if not self:_empty_value(message) then return end
    local kind = message.kind
    if kind == "open" then
        if self.note_dialog or message.generation ~= self.last_generation + 1 then
            self:_ignore(message)
        else
            self:_invoke_action(message.generation)
        end
        return
    end
    if kind == "finish" then
        if self.note_dialog or message.generation ~= self.last_generation then
            self:_fail("finish arrived before the interaction closed")
            return
        end
        self:_send("done", message.generation, "ok")
        UIManager:nextTick(function()
            self:_cleanup(true)
            if self.failed then UIManager:quit(1) else UIManager:quit(0) end
        end)
        return
    end
    if not self.note_dialog or message.generation ~= self.generation then
        self:_ignore(message)
        return
    end

    if kind == "load-absent" then
        self:_load("", false)
    elseif kind == "load-value" then
        self:_load(message.value, true)
    elseif kind == "edit" then
        if not self:_check(self.state ~= "awaiting-load"
                and self.state ~= "pending",
                "scripted edit arrived in a noneditable protocol state") then
            return
        end
        self.note_dialog:setInputText(message.value, true)
        self:_check(self.note_dialog:getInputText() == message.value,
            "actual InputDialog did not retain scripted edit")
    elseif kind == "save" then
        local save = self:_save_button()
        if self.state == "pending" then
            if self:_check(save and not save.enabled,
                    "pending Save button was not disabled") then
                self:_ignore(message)
            end
        elseif not save or not save.enabled then
            self:_ignore(message)
        else
            -- Invoke KOReader's actual Trapper-wrapped generated callback.
            save.callback()
        end
    elseif kind == "commit-ok" then
        self:_commit_ok(message.value)
    elseif kind == "commit-failed" then
        self:_commit_failed(message.value)
    elseif kind == "present" then
        if not self:_check(self.state == "saved"
                and self.last_committed_text ~= nil
                and message.value == self.last_committed_text,
                "presentation was not preceded by the matching commit receipt") then
            return
        end
        self:_present(message.value)
    elseif kind == "navigate" then
        self:_invalidate("navigated", true)
    elseif kind == "close" then
        local close = self.note_dialog.button_table:getButtonById("close")
        if not self:_check(close and close.enabled,
                "real InputDialog Close button is unavailable") then return end
        close.callback()
    else
        self:_fail("unknown private state-reader command")
    end
end

function Probe:_make_channel()
    self.channel = StateChannel:new{
        fd = 3,
        receive = function(message) self:_handle_command(message) end,
        on_error = function(err) self:_fail(err) end,
    }
    self.audit:retainChannel(self.channel)
    UIManager:insertZMQ(self.channel)
    marker("private-source-registered")
end

function Probe:_cleanup(verify)
    if self.cleaned then return end
    self.cleaned = true
    if self.note_dialog then self:_invalidate("closed", true) end
    if self.channel then
        UIManager:removeZMQ(self.channel)
        self.channel:stop()
        self.channel = nil
    end
    if self.action_factory then
        local expected = self.action_factory
        self.action_factory = nil
        local removed = self.ui.highlight:removeFromHighlightDialog(ACTION_KEY)
        self:_check(removed == expected,
            "selection action removal returned a different callback")
        marker("selection-action:removed")
    end
    if verify and self.audit then
        marker("cleanup-audit:before-quit")
        local ok, err = self.audit:verifyCleanup()
        if not ok then
            self.failed = true
            marker("FAIL:cleanup audit: " .. err)
        else
            marker("cleanup-audit:all-generations-clean")
        end
    end
end

function Probe:onReaderReady()
    if self.failed then return end
    if not self:_check(type(self.ui.highlight.addToHighlightDialog) == "function"
            and type(self.ui.highlight.removeFromHighlightDialog) == "function",
            "ReaderHighlight selection seams are unavailable") then return end
    self.audit = UIAudit:new(UIManager)
    self:_make_channel()
    self.action_factory = function()
        return {
            text = "Open persistent note fixture",
            callback = function()
                self:_open_interaction(self.requested_generation)
            end,
        }
    end
    self.audit:retainAction(self.ui.highlight, ACTION_KEY, self.action_factory)
    self.ui.highlight:addToHighlightDialog(ACTION_KEY, self.action_factory)
    if not self:_check(
            self.ui.highlight._highlight_buttons[ACTION_KEY]
                == self.action_factory,
            "selection action was not present in ReaderHighlight registry")
            or not self:_check(self.audit.action_add_count == 1,
                "selection action did not use the public add seam") then
        return
    end
    marker("selection-action:registered")
    if not self:_dismiss_startup_overlays(false) then return end
    self:_send("channel-ready", 1, "")
end

function Probe:onCloseDocument()
    self:_cleanup(false)
end

return Probe
