-- Human-driven device adapter. Lua owns only the real InputDialog and paint;
-- the connected Guile authority owns state, Book Session, OCI and runsc.
local Activation = require("activation")

-- The experimental flavor contains this plugin, but a new device remains
-- dormant until root creates the documented activation marker and restarts
-- KOReader. This cannot be enabled by an untrusted book or selected namespace.
if not Activation.enabled() then
    return { disabled = true }
end

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local StateChannel = require("state_channel")
local UIManager = require("ui/uimanager")
local UnixClient = require("unix_client")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Plugin = WidgetContainer:extend{ name = "bookstatedevice", is_doc_only = false }
local GENERATION, MAX_TEXT_BYTES = 1, 4096
local TITLES = {
    ["awaiting-load"] = _("Persistent note — Loading"),
    ["loaded-absent"] = _("Persistent note — No saved note"),
    ["loaded-value"] = _("Persistent note — Loaded"),
    dirty = _("Persistent note — Unsaved changes"),
    pending = _("Persistent note — Saving…"),
    saved = _("Persistent note — Saved"),
    failed = _("Persistent note — Save failed; draft retained"),
    disconnected = _("Persistent note — Authority stopped; NOT saved"),
}
local FAILURES = {
    ["receipt-quota-exhausted"] = true, ["read-only"] = true,
    ["storage-failure"] = true, conflict = true,
}

local function marker(value) print("BOOK_STATE_DEVICE_UI: " .. value) end

function Plugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function Plugin:addToMainMenu(menu_items)
    menu_items.wilkbook_book_state_note = {
        text = _("Persistent note (experimental)"),
        sorting_hint = "more_tools",
        callback = function() self:_open_note() end,
    }
end

function Plugin:_message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Plugin:_send(kind, value)
    local ok, err = self.channel and self.channel:send(kind, GENERATION, value or "")
    if not ok then self:_transport_failed(err) end
    return ok
end

function Plugin:_save_button()
    return self.note_dialog and self.note_dialog.button_table:getButtonById("save")
end

function Plugin:_set_save_enabled(enabled)
    local button = self:_save_button()
    if not button then return end
    if enabled then button:enable() else button:disable() end
    self.note_dialog:refreshButtons()
end

function Plugin:_set_state(state)
    if not self.note_dialog or not TITLES[state] then return end
    self.state = state
    self.note_dialog.title_bar:setTitle(TITLES[state])
    UIManager:setDirty(self.note_dialog, "ui")
    UIManager:nextTick(function()
        if self.note_dialog and self.state == state then self:_send("status", state) end
    end)
end

function Plugin:_transport_failed(reason)
    if self.transport_failed then return end
    self.transport_failed = true
    marker("transport-failed:" .. tostring(reason))
    if self.channel then
        UIManager:removeZMQ(self.channel)
        self.channel:stop()
        self.channel = nil
    end
    if self.note_dialog then
        self:_set_save_enabled(false)
        self:_set_state("disconnected")
    else
        self:_message(_("Book State authority disconnected."))
    end
end

function Plugin:_on_edited(edited)
    if self.suppress_edit or not edited or not self.note_dialog then return end
    if self.transport_failed then
        self:_set_save_enabled(false)
        return
    end
    if self.state == "pending" then
        self.pending_has_newer_edit = true
    elseif self.state == "loaded-absent" or self.state == "loaded-value"
            or self.state == "saved" or self.state == "failed" or self.state == "dirty" then
        if self.state ~= "dirty" then self:_set_state("dirty") end
        self:_set_save_enabled(true)
    end
end

function Plugin:_submit(content)
    if self.transport_failed then
        return false, _("Book State authority disconnected. This draft has not been saved. Keep it open to copy the text, or close and discard it.")
    end
    if not self.note_dialog or (self.state ~= "dirty" and self.state ~= "failed") then
        return false, false
    end
    if #content > MAX_TEXT_BYTES or not StateChannel.validText(content) then
        self:_set_state("failed")
        self:_set_save_enabled(true)
        return false, false
    end
    self.pending_text, self.pending_has_newer_edit = content, false
    self:_set_save_enabled(false)
    self:_set_state("pending")
    self:_send("submit", content)
    return false, false
end

function Plugin:_load(value, present)
    if self.state ~= "awaiting-load" then return self:_transport_failed("late load") end
    self.suppress_edit = true
    self.note_dialog:setInputText(value, false, true)
    self.suppress_edit = false
    self:_set_save_enabled(false)
    self:_set_state(present and "loaded-value" or "loaded-absent")
    UIManager:setDirty(self.note_dialog, "ui")
    UIManager:nextTick(function()
        if self.note_dialog then self:_send("applied", value) end
    end)
end

function Plugin:_commit_ok(value)
    if self.state ~= "pending" or value ~= self.pending_text then
        return self:_transport_failed("uncorrelated commit receipt")
    end
    local current = self.note_dialog:getInputText()
    self.pending_text = nil
    if current == value and not self.pending_has_newer_edit then
        -- A validated receipt makes this the native InputDialog's saved
        -- baseline too; otherwise its generated Close still sees a draft.
        self.suppress_edit = true
        self.note_dialog:setInputText(current, false)
        self.suppress_edit = false
        self:_set_save_enabled(false)
        self:_set_state("saved")
    else
        self:_set_save_enabled(true)
        self:_set_state("dirty")
    end
end

function Plugin:_handle(message)
    if message.generation ~= GENERATION or not self.note_dialog then return end
    if message.kind == "load-absent" then self:_load("", false)
    elseif message.kind == "load-value" then self:_load(message.value, true)
    elseif message.kind == "commit-ok" then self:_commit_ok(message.value)
    elseif message.kind == "commit-failed" and FAILURES[message.value] then
        self.pending_text = nil
        self:_set_save_enabled(true)
        self:_set_state("failed")
    elseif message.kind == "present" then
        -- Presentation is accepted only when it repeats the saved value. It is
        -- a paint request, not storage authority.
        if self.note_dialog:getInputText() ~= message.value then
            return self:_transport_failed("presentation differs from dialog value")
        end
        UIManager:setDirty(self.note_dialog, "ui")
        UIManager:nextTick(function()
            if self.note_dialog then self:_send("applied", message.value) end
        end)
    else self:_transport_failed("unexpected authority command") end
end

function Plugin:_close_transport()
    local channel = self.channel
    self.channel = nil
    if channel then
        UIManager:removeZMQ(channel)
        channel:stop()
    end
end

function Plugin:_on_close()
    if self.channel then self:_send("closed", "") end
    self.note_dialog, self.state, self.pending_text = nil, "inactive", nil
    UIManager:scheduleIn(0.05, function() self:_close_transport() end)
end

function Plugin:_open_note()
    -- KOReader injects self.dialog as the owning reader/file-manager window.
    -- Keep our editor separate so that window never suppresses opening a note.
    if self.note_dialog then return end
    local fd, err = UnixClient.connect()
    if not fd then return self:_message(err) end
    self.transport_failed = false
    self.channel = StateChannel:new{
        fd = fd,
        receive = function(message) self:_handle(message) end,
        on_error = function(reason) self:_transport_failed(reason) end,
    }
    UIManager:insertZMQ(self.channel)
    self.state = "awaiting-load"
    self.note_dialog = InputDialog:new{
        title = TITLES[self.state], input = "", allow_newline = true,
        input_hint = _("Note text (not a file name)"),
        keyboard_visible = true,
        save_callback = function(content) return self:_submit(content) end,
        edited_callback = function(edited) self:_on_edited(edited) end,
        close_callback = function() self:_on_close() end,
    }
    UIManager:show(self.note_dialog)
    self:_set_save_enabled(false)
    self:_send("channel-ready", "")
    UIManager:nextTick(function()
        if self.note_dialog then self:_send("ready", "") end
    end)
    marker("dialog-opened:fixed-guile-note")
end

function Plugin:onCloseWidget()
    if self.note_dialog and UIManager:isWidgetShown(self.note_dialog) then UIManager:close(self.note_dialog) end
    self:_close_transport()
end

return Plugin
