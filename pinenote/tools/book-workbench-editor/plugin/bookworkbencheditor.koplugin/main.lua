-- The launcher supplies one private authority socket. Protect it before widgets
-- can spawn children; consume the descriptor only once, on first menu open.
local fd_text = os.getenv("BOOK_WORKBENCH_EDITOR_UI_FD")
local donated_fd = fd_text and tonumber(fd_text)
if not fd_text or not fd_text:match("^[1-9][0-9]*$") or not donated_fd
        or donated_fd < 3 or donated_fd > 1048575 or tostring(donated_fd) ~= fd_text then
    return {disabled=true}
end
local Channel = require("editor_channel")
if not Channel.prepareFD(donated_fd) then return {disabled=true} end
local Codec = require("editor_codec")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font = require("ui/font")
local _ = require("gettext")
local Plugin = WidgetContainer:extend{name="bookworkbencheditor",is_doc_only=false}
local Editor = InputDialog:extend{}

function Editor:init()
    local previous = self.editor.suppress_edit
    self.editor.suppress_edit = true
    -- InputDialog measures the title before allocating the editor's height.
    -- Never mutate only TitleBar afterward: its parent caches child offsets.
    self.title = self.editor:_title()
    if self.editor_view ~= self.editor.view or self.rendered_form ~= self.editor.form then
        self.editor_view,self.rendered_form = self.editor.view,self.editor.form
        self.buttons = self.editor:_buttons(self)
        self._buttons_backup_done,self._buttons_backup = false,nil
    end
    InputDialog.init(self)
    self.editor.suppress_edit = previous
    self.editor:_controls(self)
end
function Editor:onSetRotationMode(mode)
    if mode ~= nil then self.editor:_new_view() end
    return InputDialog.onSetRotationMode(self,mode)
end
function Editor:onCloseWidget()
    self.editor:_closed(self)
    return InputDialog.onCloseWidget(self)
end
function Editor:onCloseDialog()
    -- Native InputDialog searches for an id="close" button. Our host button is
    -- namespaced; Back/Escape must instead use the same guarded close operation.
    return self.editor:_close_editor(self,self.editor_view)
end
function Plugin:init()
    self.view,self.sequence,self.edit_serial = 0,0,0
    self.ui.menu:registerToMainMenu(self)
end
function Plugin:addToMainMenu(items)
    items.wilkbook_book_workbench_editor = {
        text=_("Book editor (experimental)"),sorting_hint="more_tools",
        callback=function() self:_open() end,
    }
end
function Plugin:_message(text) UIManager:show(InfoMessage:new{text=text}) end
function Plugin:_register()
    if self.channel and not self.channel.closed and not self.registered then
        self.registered = self.channel
        UIManager:insertZMQ(self.registered)
    end
end
function Plugin:_unregister()
    if self.registered then UIManager:removeZMQ(self.registered); self.registered=nil end
end
function Plugin:_sync_polling()
    if self.preview_parent then self.preview_parent:_sync_polling(); return end
    local active = self.preview_editor or self
    if self.editor_dialog and self.channel and not self.channel.closed
            and (active.pending or self.pending or self.channel.bytes > 0) then
        self:_register()
    else self:_unregister() end
end
function Plugin:_clear_pending()
    local p = self.pending
    self.pending = nil
    if p and p.timeout then UIManager:unschedule(p.timeout) end
    self:_sync_polling()
    return p
end
function Plugin:_dismiss_confirmation()
    local box = self.confirmation_box
    self.confirmation,self.confirmation_box = nil,nil
    if box then UIManager:close(box) end
end
function Plugin:_failed(reason)
    if self.preview_parent then self.preview_parent:_failed(reason); return end
    if self.preview_editor then
        self.preview_editor:_clear_pending()
        self.preview_editor.disconnected,self.preview_editor.last_error = true,tostring(reason)
    end
    self:_clear_pending()
    self:_dismiss_confirmation()
    self:_unregister()
    if self.channel then self.channel:stop() end
    self.disconnected,self.last_error = true,tostring(reason)
    self:_controls()
    if self.preview_editor then self.preview_editor:_controls() end
end
function Plugin:_send(request,expect_reply,origin)
    origin = origin and (origin.origin or origin)
    if not self.channel or self.channel.closed then return false end
    local owner = self.preview_parent or self
    if owner.sequence == Codec.MAX_SEQUENCE then self:_failed("request sequence exhausted"); return false end
    owner.sequence = owner.sequence+1
    self.sequence = owner.sequence
    local p
    if expect_reply then
        if self.pending then error("one pending UI request required") end
        p = {sequence=self.sequence,request=request,view=self.view,
            serial=origin and origin.serial or self.edit_serial,
            preserve=origin and origin.preserve or request.op == "open" and self.retain_draft,
            origin_action=origin and origin.request.action_id,
            form=origin and origin.form or self.form,origin=origin}
        self.pending = p
    end
    local ok,err = self.channel:send(self.sequence,request)
    if not ok then self:_failed(err); return false end
    self:_sync_polling()
    if p then
        p.timeout = function() if self.pending == p then self:_failed("authority request timed out") end end
        -- Includes sandbox startup (20 s), bounded owner disposal (12 s), and
        -- the resumed author action. Human preview idle has no pending timer.
        UIManager:scheduleIn(60,p.timeout)
    end
    self:_controls()
    return true
end
function Plugin:_edited(edited)
    if self.suppress_edit or not edited or not self.editor_dialog then return end
    local text = self.editor_dialog:getInputText()
    if text ~= self.observed_text then
        self.observed_text,self.retained_text,self.retain_draft = text,text,true
        self.edit_serial = self.edit_serial+1
        -- An edit also retires trusted confirmation callbacks. The authority
        -- will invalidate its token on the next open/action or explicit close.
        if self.confirmation then
            local token,origin = self.confirmation.token,self.confirmation.origin
            self:_dismiss_confirmation()
            self:_send({op="decision",view=self.view,token=token,accept=false},true,origin)
        end
    end
    self:_controls()
end
function Plugin:_title()
    local title = self.form and self.form.title or _("Book editor — loading")
    if self.preview_parent then
        -- Trusted chrome is never selected by the candidate title or action IDs.
        return _("Disposable preview — changes are discarded\n")..title
            ..(self.last_error and _(" — failed") or self.pending and _(" — waiting") or "")
    end
    if self.disconnected then return _("Disconnected — draft retained") end
    if self.last_error then return _("Operation failed — draft retained") end
    if self.pending then return title.._(" — waiting") end
    return title
end
function Plugin:_controls(dialog)
    dialog = dialog or self.editor_dialog
    if not dialog or not dialog.button_table then return end
    if dialog.title ~= self:_title() or dialog.editor_view ~= self.view then
        -- Editor:init installs the desired title before layout and reapplies
        -- controls. Identical titles do not recreate TitleBar or InputDialog.
        dialog:reinit()
        return
    end
    local idle = self.channel and not self.channel.closed and self.form
        and not self.pending and not self.confirmation and not self.preview_editor
        and not (self.preview_parent and self.last_error)
    for i=1,8 do
        local action = self.form and self.form.actions[i]
        -- Internal positional widget ids cannot collide with authored ids,
        -- including names such as close/save/preview/install.
        local button = dialog.button_table:getButtonById("authored_"..i)
        if button then
            if idle and action and action.enabled then button:enable() else button:disable() end
        end
    end
    local finish = dialog.button_table:getButtonById("host_preview_finish")
    if finish then if idle then finish:enable() else finish:disable() end end
    dialog:refreshButtons()
end
function Plugin:_close_editor(dialog,view)
    if self.editor_dialog ~= dialog or self.view ~= view then return false end
    UIManager:close(dialog)
    return true
end
function Plugin:_buttons(dialog)
    local rows = {}
    local form,view = self.form,self.view
    for i,action in ipairs(form and form.actions or {}) do
        local id = action.id
        if i % 2 == 1 then rows[#rows+1] = {} end
        table.insert(rows[#rows],{text=action.label,id="authored_"..i,enabled=false,
            callback=function()
                if self.view == view and self.form == form then self:_action(id) end
            end})
    end
    if self.preview_parent then
        rows[#rows+1] = {{text=_("Finish preview"),id="host_preview_finish",callback=function()
            self.preview_parent:_finish_preview(self,true)
        end},{text=_("Cancel preview"),id="host_preview_cancel",callback=function()
            self.preview_parent:_finish_preview(self,false)
        end}}
    else
        rows[#rows+1] = {{text=_("Close"),id="host_close",callback=function()
            self:_close_editor(dialog,view)
        end}}
    end
    return rows
end
function Plugin:_render()
    local dialog = self.editor_dialog
    if not dialog then return end
    -- InputDialog:reinit retains text, cursor, scroll and keyboard visibility.
    -- Suppress repeated edited notifications during InputText reconstruction.
    self.suppress_edit = true
    dialog:reinit()
    self.suppress_edit = false
    self:_controls()
    if self.form.status ~= "" then self:_message(self.form.status) end
end
function Plugin:_action(id)
    if not self.editor_dialog or not self.form or self.pending or self.confirmation or self.disconnected
            or self.preview_editor or (self.preview_parent and self.last_error) then return false end
    local allowed = false
    for _,action in ipairs(self.form.actions) do
        if action.id == id and action.enabled then allowed = true; break end
    end
    if not allowed then return false end
    local text = self.editor_dialog:getInputText()
    if not Codec.validText(text,8192) then self:_message(_("Text must be UTF-8 without NUL, at most 8192 bytes.")); return false end
    self.last_error = nil
    return self:_send({op=self.preview_parent and "preview-action" or "action",view=self.view,
        token=self.preview_token,surface_handle=self.form.surface_handle,
        surface_generation=self.form.surface_generation,action_id=id,text=text},true)
end
function Plugin:_begin_preview(message,origin)
    origin = origin.origin or origin
    if self.preview_parent or (origin.request.op ~= "action" and origin.request.op ~= "open") or message.form.action_id ~= "open"
            or message.preview_view == self.view then self:_failed("unsolicited preview"); return end
    local candidate = setmetatable({preview_parent=self,preview_token=message.token,
        view=message.preview_view,sequence=self.sequence,edit_serial=0,ready=true,
        channel=self.channel,form=message.form,observed_text=message.form.text,
        last_request=message.form.request_id,last_host_sequence=message.form.sequence,
        last_generation=message.form.surface_generation}, {__index=Plugin})
    self.preview_editor,self.preview_origin = candidate,origin
    candidate:_show_editor()
    self:_controls()
end
function Plugin:_discard_preview()
    local candidate = self.preview_editor
    if not candidate then return end
    self.preview_editor = nil
    candidate:_clear_pending()
    local dialog = candidate.editor_dialog
    candidate.editor_dialog = nil
    if dialog then UIManager:close(dialog) end
end
function Plugin:_finish_preview(candidate,accept)
    if self.preview_editor ~= candidate or not candidate.editor_dialog
            or (accept and (candidate.pending or candidate.last_error)) then return false end
    local origin = self.preview_origin
    self:_discard_preview()
    self.preview_origin = nil
    if not self.channel or self.channel.closed then self:_controls(); return false end
    return self:_send({op="preview-finish",view=candidate.view,token=candidate.preview_token,
        accept=accept},true,origin)
end
function Plugin:_confirm(message,p)
    p = p.origin or p
    if self.preview_parent or (p.request.op ~= "action" and p.request.op ~= "open") then
        self:_failed("unsolicited confirmation"); return
    end
    if p.serial ~= self.edit_serial then
        self:_send({op="decision",view=self.view,token=message.token,accept=false},true,p)
        return
    end
    local confirmation = {token=message.token,view=self.view,serial=self.edit_serial,origin=p}
    self.confirmation = confirmation
    local function decide(accept)
        if self.confirmation ~= confirmation or self.view ~= confirmation.view
                or self.edit_serial ~= confirmation.serial or not self.editor_dialog then return end
        self.confirmation,self.confirmation_box = nil,nil
        self:_send({op="decision",view=self.view,token=confirmation.token,accept=accept},true,p)
    end
    -- Only this host message can create privileged chrome. Authored labels and
    -- ids do not select this code path. The native join may set this callback
    -- for a richer trusted confirmation presentation; it receives no paths.
    if self.host_confirmation then
        self.host_confirmation(message.kind,message.summary,function() decide(true) end,function() decide(false) end)
    else
        local box = ConfirmBox:new{
            text=(message.kind == "install" and _("Install revision?\n\n") or _("Recover editor?\n\n"))..message.summary,
            ok_text=message.kind == "install" and _("Install") or _("Recover"),cancel_text=_("Cancel"),
            ok_callback=function() decide(true) end,cancel_callback=function() decide(false) end,
        }
        self.confirmation_box = box
        UIManager:show(box)
    end
    self:_controls()
end
function Plugin:_reply(message)
    if self.preview_editor then self.preview_editor:_reply(message); return end
    local p,v = self.pending,message.payload
    if message.sequence > self.sequence then self:_failed("future authority reply"); return end
    if not p or message.sequence < p.sequence then return end
    if message.sequence ~= p.sequence or p.view ~= self.view then self:_failed("uncorrelated authority reply"); return end
    self:_clear_pending()
    if p.request.op == "hello" then
        if v.op ~= "ready" then self:_failed("expected ready"); return end
        self.ready = true
        if self.editor_dialog then self:_request_open() end
        return
    end
    if v.view ~= self.view then self:_failed("reply names another view"); return end
    if v.op == "preview" then
        if not self.preview_parent then self:_begin_preview(v,p); return end
        if v.token ~= self.preview_token or v.preview_view ~= self.view then
            self:_failed("preview names another lifetime"); return
        end
    elseif v.op == "preview-failure" then
        if not self.preview_parent or v.token ~= self.preview_token then
            self:_failed("preview failure names another lifetime"); return
        end
        self.last_error = v.error
        self:_controls(); self:_message(v.error); return
    end
    if v.op == "failure" then
        self.last_error = v.error
        self:_controls()
        if self.editor_dialog then self:_message(v.error) end
        return
    end
    if v.op == "confirmation" then self:_confirm(v,p); return end
    if v.op ~= "present" and v.op ~= "preview" then self:_failed("expected presentation"); return end
    local form = v.form
    local origin = p.origin or p
    if origin.request.op == "open" then
        if form.action_id ~= "open" or (self.last_generation and form.surface_generation <= self.last_generation) then
            self:_failed("open did not produce a fresh surface generation"); return
        end
    elseif origin.request.op == "action" or origin.request.op == "preview-action" then
        if form.action_id ~= origin.request.action_id or form.surface_handle ~= origin.request.surface_handle
                or form.surface_generation ~= origin.request.surface_generation then
            self:_failed("presentation does not match submitted action"); return
        end
    else self:_failed("presentation for invalid operation"); return end
    if self.last_request and (form.request_id <= self.last_request or form.sequence <= self.last_host_sequence) then
        self:_failed("nonmonotonic presentation identity"); return
    end
    self.last_request,self.last_host_sequence,self.last_generation = form.request_id,form.sequence,form.surface_generation
    self.form,self.last_error = form,nil
    if self.editor_dialog and p.serial == self.edit_serial and not p.preserve then
        self.suppress_edit = true
        if self.editor_dialog:getInputText() ~= form.text then self.editor_dialog:setInputText(form.text,false) end
        self.suppress_edit = false
        self.observed_text,self.retained_text,self.retain_draft = form.text,form.text,false
    end
    self:_render()
end
function Plugin:_request_open()
    if not self.editor_dialog then return end
    local text = self.editor_dialog:getInputText()
    if not Codec.validText(text,8192) then
        -- Oversized local edits stay visible; a resync uses empty input while
        -- the preserve flag forbids its result from overwriting the draft.
        self.retain_draft = true
        text = ""
    end
    self:_send({op="open",view=self.view,text=text},true)
end
function Plugin:_new_view()
    if not self.editor_dialog then return end
    if self.preview_parent then return end
    self:_discard_preview()
    self.retained_text = self.editor_dialog:getInputText()
    self:_clear_pending()
    self:_dismiss_confirmation()
    self.view = self.view+1
    self.form,self.last_error = nil,nil
    if self.ready then self:_request_open()
    else self:_send({op="hello",protocol_version=1},true) end
    self:_controls()
end
function Plugin:_closed(dialog)
    if self.editor_dialog ~= dialog then return end
    if self.preview_parent then self.preview_parent:_finish_preview(self,false); return end
    self:_discard_preview()
    self.retained_text = dialog:getInputText()
    self.editor_dialog = nil
    self:_clear_pending()
    self:_dismiss_confirmation()
    self:_send({op="close",view=self.view},false)
    -- No reply/deadline/polling remains after Close. If backpressure prevents
    -- the close frame from draining immediately, EOF retires the host view.
    self:_unregister()
    if self.channel and self.channel.bytes > 0 then self:_failed("close could not drain; draft retained") end
    self.form = nil
end
function Plugin:_open()
    if self.editor_dialog or self.tearing_down then return end
    if not self.channel and donated_fd then
        local fd = donated_fd; donated_fd = nil
        local channel,err = Channel:new{fd=fd,receive=function(v) self:_reply(v) end,
            on_progress=function() self:_sync_polling() end,
            on_error=function(reason) self:_failed(reason) end}
        if not channel then self:_message(err); return end
        self.channel = channel
    end
    if not self.channel and self.retained_text == nil then self:_message(_("Editor connection already in use.")); return end
    self.view = self.view+1
    self.observed_text = self.retained_text or ""
    self:_show_editor()
    if self.ready then self:_request_open() else self:_send({op="hello",protocol_version=1},true) end
    self:_controls()
end
function Plugin:_show_editor()
    local dialog
    dialog = Editor:new{editor=self,title=_("Book editor — loading"),input=self.observed_text,
        input_face=Font:getFace("infont",18),fullscreen=true,condensed=true,allow_newline=true,
        cursor_at_end=false,add_nav_bar=true,rotation_enabled=true,para_direction_rtl=false,
        edited_callback=function(edited) if self.editor_dialog == dialog then self:_edited(edited) end end,
        close_callback=function() self:_closed(dialog) end,
    }
    -- KOReader injects its ReaderUI/FileManager owner as self.dialog. Keep that
    -- native ownership field distinct from this plugin's editable surface.
    self.editor_dialog = dialog
    UIManager:show(dialog)
    self:_controls()
end
function Plugin:onSetRotationMode() self:_new_view() end
function Plugin:onCloseDocument()
    self.tearing_down = true
    if self.editor_dialog then UIManager:close(self.editor_dialog) end
    self:_clear_pending(); self:_dismiss_confirmation(); self:_unregister()
    if self.channel then self.channel:stop() end
end
Plugin.onCloseWidget = Plugin.onCloseDocument
return Plugin
