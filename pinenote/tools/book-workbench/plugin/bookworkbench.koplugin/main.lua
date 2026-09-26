-- Explicit offline fixture opt-in, checked before loading widgets or transport.
-- The launcher donates one connected socket; the UI supplies no host paths,
-- namespace selectors, execution commands or authored Lua to KOReader.
local fd_text = os.getenv("BOOK_WORKBENCH_UI_FD")
local donated_fd = fd_text and tonumber(fd_text)
if not fd_text or not fd_text:match("^[1-9][0-9]*$") or not donated_fd
        or donated_fd < 3 or donated_fd > 1048575 or tostring(donated_fd) ~= fd_text then
    return { disabled = true }
end

local Channel = require("workbench_channel")
-- Protect the inherited descriptor at module load, before any KOReader widget
-- or utility can launch a child. Its one UI owner is selected on first open.
if not Channel.prepareFD(donated_fd) then return { disabled = true } end
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Plugin = WidgetContainer:extend{ name = "bookworkbench", is_doc_only = false }
local Editor = InputDialog:extend{}
local DEADLINE = 30

-- InputDialog recreates buttons on keyboard and layout changes. Reapply the
-- asynchronous FSM's enablement rather than trusting its native dirty bit.
function Editor:init()
    -- InputText initialization repeats its existing edited state. It is not a
    -- new edit and must not retire a save receipt during keyboard re-layout.
    local suppressed = self.workbench.suppress_edit
    self.workbench.suppress_edit = true
    InputDialog.init(self)
    self.workbench.suppress_edit = suppressed
    if self.workbench then self.workbench:_refresh_controls(self) end
end

function Editor:onSetRotationMode(mode)
    if mode ~= nil then self.workbench:_invalidate_view() end
    return InputDialog.onSetRotationMode(self, mode)
end

function Editor:onCloseWidget()
    self.workbench:_editor_closed(self)
    return InputDialog.onCloseWidget(self)
end

function Plugin:init()
    self.epoch, self.sequence, self.edit_serial = 0, 0, 0
    self.ui.menu:registerToMainMenu(self)
end

function Plugin:addToMainMenu(items)
    items.wilkbook_book_workbench = {
        text = _("Book Workbench (experimental)"), sorting_hint = "more_tools",
        callback = function() self:_open_workspace() end,
    }
end

function Plugin:_message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Plugin:_connected()
    return self.channel and not self.channel.closed and not self.disconnected
end

function Plugin:_dirty()
    return self.source_dialog and (self.saved_source == nil
        or self.source_dialog:getInputText() ~= self.saved_source)
end

function Plugin:_refresh_controls(dialog)
    dialog = dialog or self.source_dialog
    if not dialog or not dialog.button_table then return end
    local idle = (self:_connected() and not self.pending and self.snapshot ~= nil) or false
    local text = dialog:getInputText()
    local dirty = self.saved_source == nil or text ~= self.saved_source
    if self.saved_source ~= nil then
        -- Native Save/Close branch on _text_modified, independently of button
        -- enablement. A new receipt can make unchanged visible bytes dirty, or
        -- make an edited-away-and-back draft clean. Reconcile both native bits
        -- without rewriting the text/cursor or synthesizing an edit callback.
        dialog._text_modified = dirty
        dialog._input_widget.is_text_edited = dirty
        if dialog == self.source_dialog then
            -- If an in-flight save will replace these currently committed
            -- bytes, retain the user's reversion across Close/reopen too.
            self.view_preserve_draft = self.preserve_until_snapshot or dirty
                or (self.pending and self.pending.request.op == "save"
                and text ~= self.pending.request.source) or false
        end
    end
    local enabled = {
        save = idle and dirty,
        preview = idle and not dirty,
        run = idle,
        activate = idle and not dirty and self.preview_version == self.snapshot.workspace_version,
        rollback = idle,
        export = idle,
        close = true,
    }
    for id, allow in pairs(enabled) do
        local button = dialog.button_table:getButtonById(id)
        if button then
            if allow then button:enable() else button:disable() end
        end
    end
    if dialog == self.source_dialog then
        local status
        if self.disconnected then status = _("Disconnected — draft retained")
        elseif self.pending then status = _("Waiting for authority…")
        elseif self.last_error then status = _("Operation failed — draft retained")
        elseif dirty then status = _("Unsaved draft")
        else status = _("Draft saved") end
        dialog.title_bar:setTitle(_("Book Workbench — ") .. status)
        dialog:refreshButtons()
    end
end

function Plugin:_edited(edited)
    if self.suppress_edit or not edited then return end
    local text = self.source_dialog and self.source_dialog:getInputText()
    -- Cursor motion can repeat InputText's edited=true notification too.
    if text ~= self.observed_source then
        self.observed_source = text
        self.view_preserve_draft = true
        self.edit_serial = self.edit_serial + 1
        self.preview_version, self.last_error = nil, nil
    end
    self:_refresh_controls()
end

function Plugin:_register_channel()
    if self:_connected() and not self.registered_channel then
        self.registered_channel = self.channel
        UIManager:insertZMQ(self.registered_channel)
    end
end

function Plugin:_unregister_channel()
    local channel = self.registered_channel
    self.registered_channel = nil
    if channel then UIManager:removeZMQ(channel) end
end

function Plugin:_stop_channel()
    if self.shutdown_timeout then
        UIManager:unschedule(self.shutdown_timeout)
        self.shutdown_timeout = nil
    end
    self:_unregister_channel()
    local channel = self.channel
    self.channel = nil
    if channel then channel:stop() end
end

function Plugin:_clear_pending()
    local pending = self.pending
    self.pending = nil
    if pending and pending.timeout then UIManager:unschedule(pending.timeout) end
    return pending
end

function Plugin:_transport_failed(reason)
    if self.disconnected then return end
    self:_clear_pending()
    self.disconnected, self.preview_version = true, nil
    self.epoch = self.epoch + 1
    self.last_error = tostring(reason)
    self:_stop_channel()
    self:_refresh_controls()
end

function Plugin:_request(request, options)
    if not self:_connected() or self.pending then return false end
    self:_register_channel()
    if self.sequence == Channel.MAX_SEQUENCE then
        self:_transport_failed("Workbench request sequence exhausted")
        return false
    end
    self.sequence = self.sequence + 1
    local pending = { sequence = self.sequence, request = request, epoch = self.epoch,
        edit_serial = self.edit_serial, options = options or {}, snapshot = self.snapshot }
    self.pending, self.last_error = pending, nil
    -- The old baseline cannot resolve a preserving resync. Its obligation
    -- survives another rotation/Close and the retirement of this open reply.
    if request.op == "open" and pending.options.preserve_draft then
        self.preserve_until_snapshot = true
    end
    local ok, reason = self.channel:send(pending.sequence, request)
    if not ok then
        if self.pending == pending then self:_clear_pending() end
        self.last_error = reason
        self:_refresh_controls()
        if self.source_dialog then self:_message(reason) end
        return false
    end
    self:_refresh_controls()
    -- Deadline belongs to this exact request; it cannot stop a later session.
    pending.timeout = function()
        if self.pending == pending then self:_transport_failed("Workbench request timed out") end
    end
    UIManager:scheduleIn(DEADLINE, pending.timeout)
    return true
end

function Plugin:_replace_source(text, clean)
    if not self.source_dialog then return end
    self.suppress_edit = true
    self.source_dialog:setInputText(text, not clean)
    self.observed_source = text
    self.view_preserve_draft = not clean
    self.suppress_edit = false
end

function Plugin:_show_text(title, text)
    local viewer
    viewer = TextViewer:new{ title = title, text = text, text_type = "code",
        show_menu = false, para_direction_rtl = false, auto_para_direction = false,
        close_callback = function() if self.result_viewer == viewer then self.result_viewer = nil end end }
    self.result_viewer = viewer
    UIManager:show(viewer)
end

function Plugin:_reply(message)
    local pending, reply = self.pending, message.payload
    if message.sequence > self.sequence then return self:_transport_failed("future authority reply") end
    if not pending or message.sequence < pending.sequence then return end -- retired/duplicate reply
    if message.sequence ~= pending.sequence or reply.op ~= pending.request.op then
        return self:_transport_failed("uncorrelated authority reply")
    end
    self:_clear_pending()
    if self.tearing_down then
        if pending.request.op == "close" then self:_stop_channel()
        elseif not self:_request({ op = "close" }) then self:_stop_channel() end
        return
    end
    if pending.epoch ~= self.epoch then
        -- A layout/navigation change retires callbacks, not a possible durable
        -- operation. Read the authoritative snapshot after its reply drains.
        -- The current view decides what to preserve. In particular, neither
        -- an untouched loading placeholder nor a closed view's callback may
        -- replace a reopened editor's draft.
        if self.source_dialog then
            self:_request({ op = "open" }, { preserve_draft = self.view_preserve_draft })
        else
            self:_unregister_channel()
        end
        return
    end
    if not reply.ok then
        local error_text = reply.error == "revision-quota-exhausted"
            and _("This workspace has reached its 128-revision limit. The draft is saved; running, exporting and rolling back installed source still work.")
            or reply.error
        self.preview_version, self.last_error = nil, error_text
        self:_refresh_controls()
        if self.source_dialog then
            if reply.diagnostic then self:_show_text(_("Operation failed — draft retained"),
                error_text .. "\n\n" .. reply.diagnostic)
            else self:_message(error_text) end
        end
        return
    end
    local snapshot, op = reply.snapshot, reply.op
    if op == "preview" or op == "run" or op == "export" then
        local expected = pending.snapshot
        if not expected or reply.workspace_version ~= expected.workspace_version
                or reply.source_digest ~= expected.source_digest
                or reply.activation_generation ~= expected.activation_generation then
            return self:_transport_failed("read-only reply names another workspace/activation")
        end
        if op == "preview" then
            if not self:_dirty() and self.edit_serial == pending.edit_serial then
                self.preview_version = reply.workspace_version
            end
        end
        if op == "export" then
            self:_show_text(_("Exported artifact — read only"), reply.artifact)
        else
            self:_show_text(op == "preview" and _("Preview — trusted-native offline")
                or _("Run installed — trusted-native offline"),
                reply.text .. (reply.diagnostic ~= "" and ("\n\n" .. reply.diagnostic) or ""))
        end
        self:_refresh_controls()
        return
    end
    local before = pending.snapshot
    if op == "save" then
        -- Save CAS binds the draft version, not the activation generation.
        -- Another authority may have activated/rolled back the same workspace.
        if snapshot.source ~= pending.request.source
                or snapshot.workspace_version ~= pending.request.expected_version + 1 then
            return self:_transport_failed("save receipt differs from submitted draft/version")
        end
    elseif op == "activate" then
        if snapshot.activation_generation ~= pending.request.expected_activation + 1
                or snapshot.workspace_version ~= before.workspace_version
                or snapshot.source ~= before.source or snapshot.source_digest ~= before.source_digest then
            return self:_transport_failed("activation receipt differs from submitted draft/generation")
        end
    elseif op == "rollback" then
        -- Rollback CAS binds only activation. It can observe another writer's
        -- newer draft, which becomes the saved baseline, not the visible text.
        if snapshot.activation_generation ~= pending.request.expected_activation + 1 then
            return self:_transport_failed("rollback receipt differs from submitted generation")
        end
    end
    if self.snapshot and (snapshot.workspace_version < self.snapshot.workspace_version
            or snapshot.activation_generation < self.snapshot.activation_generation
            or (snapshot.workspace_version == self.snapshot.workspace_version
                and (snapshot.source ~= self.snapshot.source
                    or snapshot.source_digest ~= self.snapshot.source_digest))
            or (snapshot.activation_generation == self.snapshot.activation_generation
                and (snapshot.active_revision ~= self.snapshot.active_revision
                    or snapshot.previous_revision ~= self.snapshot.previous_revision))) then
        return self:_transport_failed("authority snapshot is not a monotonic workspace/activation")
    end
    self.snapshot = snapshot
    self.saved_source = snapshot.source
    self.preserve_until_snapshot = nil -- only a validated current-view snapshot reconciles it
    if op == "open" then
        if not pending.options.preserve_draft and self.edit_serial == pending.edit_serial then
            self:_replace_source(snapshot.source, true)
        end
    elseif op == "save" then
        self.preview_version = nil
        if pending.options.close_after and self.source_dialog
                and self.source_dialog:getInputText() == pending.request.source
                and self.edit_serial == pending.edit_serial then
            -- Intervening edits prevent automatic Close, even if the user
            -- returned to the submitted bytes. Native cleanliness below is
            -- always byte equality with the receipt, independent of serial.
            self:_refresh_controls()
            self:_close_saved_editor()
        end
    elseif op == "activate" then
        self.preview_version = nil
        self:_show_text(_("Active revision"), snapshot.active_revision)
    elseif op == "rollback" then
        self.preview_version = nil
        self:_show_text(_("Rolled back — draft retained"), snapshot.active_revision)
    end
    self:_refresh_controls()
end

function Plugin:_save(text, closing)
    if not self.snapshot or self.pending or not self:_connected() then return false, false end
    if not Channel.validText(text, Channel.MAX_SOURCE) then
        self.last_error = _("Source must be valid UTF-8, without NUL, and at most 8192 bytes.")
        self:_refresh_controls()
        return false, self.last_error
    end
    self:_request({ op = "save", expected_version = self.snapshot.workspace_version,
        source = text }, { close_after = closing == true })
    return false, false -- async acknowledgement owns the Saved state
end

function Plugin:_preview(installed)
    if not self.snapshot or self.pending or not self:_connected()
            or (not installed and self:_dirty()) then return end
    local epoch, version = self.epoch, self.snapshot.workspace_version
    local prompt
    prompt = InputDialog:new{ title = installed and _("Run installed input — trusted-native offline")
            or _("Preview input — trusted-native offline"),
        input = "sample", input_hint = _("1–2048 UTF-8 bytes"), allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(prompt) end },
            { text = installed and _("Run installed") or _("Preview"), id = "preview", callback = function()
                local text = prompt:getInputText()
                if text == "" or not Channel.validText(text, Channel.MAX_INPUT) then
                    self:_message(_("Input must be 1–2048 UTF-8 bytes without NUL.")); return
                end
                UIManager:close(prompt)
                if self.epoch == epoch and self.snapshot and self.snapshot.workspace_version == version
                        and (installed or not self:_dirty()) and not self.pending then
                    if installed then self:_request({ op = "run", text = text })
                    else
                        self.preview_version = nil
                        self:_request({ op = "preview", expected_version = version, text = text })
                    end
                end
            end },
        }} }
    self.preview_prompt = prompt
    UIManager:show(prompt)
    prompt:onShowKeyboard()
end

function Plugin:_activate()
    if not self.snapshot or self.pending or not self:_connected() or self:_dirty()
            or self.preview_version ~= self.snapshot.workspace_version then return end
    local epoch, version = self.epoch, self.snapshot.workspace_version
    local activation = self.snapshot.activation_generation
    UIManager:show(ConfirmBox:new{ text = _("Activate this previewed workspace revision?"),
        ok_text = _("Activate"), ok_callback = function()
            if self.epoch == epoch and self.snapshot and not self:_dirty()
                    and self.preview_version == version and self.snapshot.workspace_version == version
                    and self.snapshot.activation_generation == activation then
                self:_request({ op = "activate", expected_version = version,
                    expected_activation = activation })
            end
        end })
end

function Plugin:_rollback()
    if not self.snapshot or self.pending or not self:_connected() then return end
    local epoch, activation = self.epoch, self.snapshot.activation_generation
    UIManager:show(ConfirmBox:new{ text = _("Restore the previous active revision? The draft is retained."),
        ok_text = _("Roll back"), ok_callback = function()
            if self.epoch == epoch and self.snapshot and self.snapshot.activation_generation == activation then
                self:_request({ op = "rollback", expected_activation = activation })
            end
        end })
end

function Plugin:_invalidate_view()
    if not self.source_dialog or self.tearing_down then return end
    self.epoch, self.preview_version = self.epoch + 1, nil
    if not self.pending then
        self:_request({ op = "open" }, { preserve_draft = self.view_preserve_draft })
    end
    self:_refresh_controls()
end

function Plugin:onPageUpdate() self:_invalidate_view() end
function Plugin:onPosUpdate() self:_invalidate_view() end
function Plugin:onSetRotationMode() self:_invalidate_view() end

function Plugin:_close_saved_editor()
    local dialog = self.source_dialog
    if dialog then self:_editor_closed(dialog); UIManager:close(dialog) end
end

function Plugin:_editor_closed(dialog)
    if not dialog or self.source_dialog ~= dialog then return end
    self.retained_source = dialog:getInputText()
    self.retained_dirty = self.preserve_until_snapshot
        or self.saved_source == nil and self.view_preserve_draft
        or (self.saved_source ~= nil and self.retained_source ~= self.saved_source)
        or (self.pending and self.pending.request.op == "save"
            and self.retained_source ~= self.pending.request.source) or false
    self.source_dialog, self.preview_version = nil, nil
    self.epoch = self.epoch + 1
    self:_close_auxiliary_views()
    -- Keep the one donated transport for the next menu open. An in-flight
    -- request drains with a retired epoch; only a fresh open can load the next
    -- view, and only plugin teardown sends the terminal protocol close.
    -- Registration itself forces UIManager's 50 ms wakeup; retain the FD, not
    -- idle polling. A pending reply unregisters after it has drained instead.
    if not self.pending and not self.tearing_down then self:_unregister_channel() end
end

function Plugin:_open_workspace()
    if self.source_dialog or self.tearing_down then return end
    if not self.channel and donated_fd then
        local fd = donated_fd
        donated_fd = nil -- never re-adopt a numeric FD after close/reuse
        local channel, err = Channel:new{ fd = fd,
            receive = function(message) self:_reply(message) end,
            on_error = function(reason) self:_transport_failed(reason) end }
        if not channel then return self:_message(err) end
        self.channel = channel
    elseif not self.channel and self.retained_source == nil then
        return self:_message(_("The donated fixture connection is already in use."))
    end
    self.epoch = self.epoch + 1
    self.view_preserve_draft = self.retained_dirty or false
    self.observed_source = self.retained_source or ""
    local dialog
    local function current_view() return self.source_dialog == dialog end
    dialog = Editor:new{
        workbench = self, title = _("Book Workbench — Loading"), input = self.observed_source,
        _text_modified = self.retained_dirty == true,
        input_hint = _("Source text; saved by the workspace authority"),
        input_face = Font:getFace("infont", 18), para_direction_rtl = false,
        fullscreen = true, condensed = true, allow_newline = true,
        cursor_at_end = false, add_nav_bar = true, rotation_enabled = true,
        save_button_text = _("Save draft"),
        close_unsaved_confirm_text = _("The draft has unsaved changes. Closing keeps it in memory only."),
        close_discard_button_text = _("Close without saving"),
        close_discarded_notif_text = _("Draft retained for this reader session"),
        save_callback = function(text, closing)
            if current_view() then return self:_save(text, closing) end
            return false, false
        end,
        edited_callback = function(edited) if current_view() then self:_edited(edited) end end,
        close_callback = function() self:_editor_closed(dialog) end,
        buttons = {{{ text = _("Export"), id = "export", callback = function()
                if current_view() and self.snapshot then self:_request({ op = "export" }) end
            end }},
            {{ text = _("Preview"), id = "preview", callback = function()
                if current_view() then self:_preview() end
            end },
             { text = _("Run installed"), id = "run", callback = function()
                if current_view() then self:_preview(true) end
            end }},
            {{ text = _("Activate"), id = "activate", callback = function()
                if current_view() then self:_activate() end
            end },
             { text = _("Roll back"), id = "rollback", callback = function()
                if current_view() then self:_rollback() end
            end }},
        },
    }
    self.source_dialog = dialog
    UIManager:show(self.source_dialog)
    -- If the last view closed while a request was pending, its retired reply
    -- will issue this open after it drains; no second request is outstanding.
    self:_request({ op = "open" }, { preserve_draft = self.view_preserve_draft })
    self:_refresh_controls()
end

function Plugin:_close_auxiliary_views()
    if self.preview_prompt and UIManager:isWidgetShown(self.preview_prompt) then UIManager:close(self.preview_prompt) end
    if self.result_viewer and UIManager:isWidgetShown(self.result_viewer) then UIManager:close(self.result_viewer) end
    self.preview_prompt, self.result_viewer = nil, nil
end

function Plugin:onCloseDocument()
    if self.tearing_down then return end
    self.tearing_down = true
    self:_close_auxiliary_views()
    self:_close_saved_editor()
    self.epoch, self.preview_version = self.epoch + 1, nil
    if not self:_connected() then self:_clear_pending(); self:_stop_channel(); return end
    -- Reader-to-file-manager navigation leaves the event loop running: drain
    -- any old request, then acknowledge close. A stopped loop exits with EOF.
    -- Bound a silent peer even if this reader widget has already disappeared.
    self.shutdown_timeout = function()
        self:_clear_pending()
        self:_stop_channel()
    end
    UIManager:scheduleIn(5, self.shutdown_timeout)
    if not self.pending and not self:_request({ op = "close" }) then
        self:_clear_pending()
        self:_stop_channel()
    end
end

Plugin.onCloseWidget = Plugin.onCloseDocument
return Plugin
