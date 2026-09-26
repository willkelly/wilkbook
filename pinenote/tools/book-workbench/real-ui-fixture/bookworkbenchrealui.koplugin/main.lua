-- Test-only controller. Source editing, prompts, Save, confirmations and Close
-- go through production widgets. No automation messages enter the UI protocol.
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Probe = WidgetContainer:extend{ name = "bookworkbenchrealui", is_doc_only = true }

local SEED = '(define (workbench text) (string-append "seed: " text))\n'
local SUCCESSOR = '(define (workbench text) (string-append "revised: " (string-upcase text)))\n'
local BROKEN = '(define (workbench text)'
local DRAFT = 'unsaved source — retained λ'
local OVERLAYS = {
    ["Book info cache database updated."] = true,
    ["Documents will be rendered in color on this device.\n"
        .. "If your device is grayscale, you can disable color rendering in "
        .. "the screen sub-menu for reduced memory usage."] = true,
}

local function check(value, reason) assert(value, reason) end
local function marker(text) print("BOOK_WORKBENCH_REAL_UI: " .. text) end
local function registrations(channel)
    local count = 0
    for _, source in ipairs(UIManager._zeromqs) do
        if source == channel then count = count + 1 end
    end
    return count
end
local function button(widget, id)
    return assert(widget.button_table:getButtonById(id), "missing real button " .. id)
end
local function find_button(widget, text)
    if type(widget) ~= "table" then return nil end
    if widget.text == text and type(widget.callback) == "function" then return widget end
    for _, child in ipairs(widget) do
        local found = find_button(child, text)
        if found then return found end
    end
end

function Probe:_await(predicate, label)
    coroutine.yield({ predicate = predicate, label = label, attempts = 0 })
end

function Probe:_regression(name)
    self.regressions = self.regressions or {}
    check(not self.regressions[name], "duplicate regression case")
    self.regressions[name] = true
    marker("regression:" .. name)
end

function Probe:_idle_channel(channel)
    check(registrations(channel) == 0 and not self.plugin.pending, "closed idle channel is still registered")
    local inherited, calls, elapsed = channel.waitEvent, 0, false
    channel.waitEvent = function(target)
        calls = calls + 1
        return inherited(target)
    end
    -- Run the actual event loop across more than two of its old 50 ms ZMQ
    -- intervals. The controller's own timers may run; this channel must not.
    UIManager:scheduleIn(0.12, function() elapsed = true end)
    self:_await(function() return elapsed end, "closed-view idle interval")
    channel.waitEvent = inherited
    check(calls == 0 and not channel.closed, "closed editor polls or closes the retained transport")
end

function Probe:_step()
    if self.failed or self.finished then return end
    local ok, err = pcall(function()
        check(not self.plugin or not self.plugin.disconnected,
            "Workbench disconnected: " .. tostring(self.plugin and self.plugin.last_error))
        if self.waiting then
            self.waiting.attempts = self.waiting.attempts + 1
            if not self.waiting.predicate() then
                check(self.waiting.attempts < 1500, "timed out: " .. self.waiting.label)
                return
            end
            self.waiting = nil
        end
        local resumed, waiting = coroutine.resume(self.worker)
        check(resumed, waiting)
        self.waiting = waiting
        if coroutine.status(self.worker) == "dead" then
            self.finished = true
            marker("result:ok")
            UIManager:quit(0)
        end
    end)
    if not ok then
        self.failed = true
        marker("FAIL:" .. tostring(err))
        UIManager:quit(1)
    elseif not self.finished then
        UIManager:scheduleIn(0.01, function() self:_step() end)
    end
end

function Probe:_menu_open()
    local menu = self.ui.menu
    if not menu.tab_item_table then menu:setUpdateItemTable() end
    local function contains(items, id)
        for _, item in ipairs(items or {}) do
            if item.id == id or contains(item.sub_item_table, id) then return true end
        end
    end
    local tab
    for index, items in ipairs(menu.tab_item_table) do
        if contains(items, "more_tools") then tab = index end
    end
    check(tab, "More tools tab missing")
    menu:onShowMenu(tab)
    local real_menu = menu.menu_container[1]
    check(UIManager:isWidgetShown(menu.menu_container), "TouchMenu is not shown")
    local function item(id)
        for _, value in ipairs(real_menu.item_table) do if value.id == id then return value end end
        error("TouchMenu item missing: " .. id)
    end
    real_menu:onMenuSelect(item("more_tools"))
    real_menu:onMenuSelect(item("wilkbook_book_workbench"))
    marker("touch-menu:more-tools/book-workbench")
end

function Probe:_paint(widget, expected, label)
    local inherited = widget.paintTo
    local painted = false
    widget.paintTo = function(target, ...)
        inherited(target, ...)
        local top = UIManager:getTopmostVisibleWidget()
        -- The exact editor-owned keyboard occupies its reserved screen region;
        -- the editor text remains visible above it and still paints natively.
        local keyboard = target._input_widget and target._input_widget.keyboard
        if (top == target or (keyboard and top == keyboard)) and expected() then painted = true end
    end
    UIManager:setDirty(widget, "ui")
    self:_await(function() return painted end, label)
    widget.paintTo = inherited
    marker("inherited-paint:" .. label)
end

function Probe:_result(expected, title)
    self:_await(function() return not self.plugin.pending and self.plugin.result_viewer ~= nil end,
        "result viewer")
    local viewer = self.plugin.result_viewer
    check(viewer.text == expected, "unexpected result: " .. tostring(viewer.text))
    if title then check(viewer.title == title, "wrong result title") end
    self:_paint(viewer, function() return viewer.text == expected end, "result")
    viewer:onClose()
    check(self.plugin.result_viewer == nil, "viewer close callback not run")
end

function Probe:_execute(installed, text)
    button(self.editor, installed and "run" or "preview").callback()
    local prompt = assert(self.plugin.preview_prompt)
    check(UIManager:isWidgetShown(prompt) and prompt:isTextEditable(), "real input prompt missing")
    prompt:setInputText(text)
    button(prompt, "preview").callback()
    check(not UIManager:isWidgetShown(prompt), "prompt did not close after command")
end

function Probe:_confirm(id, label)
    button(self.editor, id).callback()
    local confirm = UIManager:getTopmostVisibleWidget()
    check(confirm and confirm.ok_text == label, "real confirmation missing")
    assert(find_button(confirm, label), "real confirmation button missing").callback()
    check(not UIManager:isWidgetShown(confirm), "confirmation did not close")
end

function Probe:_run()
    self.plugin = assert(PluginLoader:getPluginInstance("bookworkbench"), "production plugin not loaded")
    check(self.plugin.dialog == self.dialog and self.plugin.ui == self.ui, "wrong injected ReaderUI owner")
    G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog, "real source editor did not open")
    local editor = self.editor
    check(editor ~= self.plugin.dialog and UIManager:isWidgetShown(editor), "source/owner separation failed")
    check(editor.fullscreen and editor:isTextEditable(), "real full-screen InputDialog missing")
    self:_await(function() return not self.plugin.pending and self.plugin.snapshot end, "initial load")
    check(not self.plugin.disconnected and editor:getInputText() == SEED, "wrong seed load")
    editor:toggleKeyboard(false)
    self:_paint(editor, function() return editor:getInputText() == SEED end, "loaded-source")
    self:_execute(true, "alpha")
    self:_result("seed: alpha")

    editor:setInputText(SUCCESSOR, true, false)
    check(button(editor, "save").enabled and not button(editor, "preview").enabled, "dirty controls incorrect")
    button(editor, "save").callback() -- real InputDialog -> Trapper -> save_callback
    check(self.plugin.pending and not button(editor, "save").enabled, "save did not become pending")
    editor:toggleKeyboard()
    check(not button(editor, "save").enabled, "keyboard reinit enabled pending Save")
    editor:toggleKeyboard(false)
    editor:setInputText(DRAFT, true, false)
    editor:setInputText(SUCCESSOR, true, false)
    self:_await(function() return not self.plugin.pending end, "draft save")
    check(not self.plugin.disconnected and not editor._text_modified and not editor:isTextEdited(),
        "native saved baseline not reset after edit-away/back")
    check(editor:getInputText() == SUCCESSOR and self.plugin.snapshot.workspace_version == 1, "source not saved")
    self:_paint(editor, function() return editor:getInputText() == SUCCESSOR and not editor._text_modified end,
        "saved-source")
    local saved_channel = self.plugin.channel
    button(editor, "close").callback()
    check(not self.plugin.source_dialog and not UIManager:isWidgetShown(editor),
        "generated Close falsely prompted for byte-identical committed source")
    self:_regression("save-edit-away-back:clean-generated-close")
    self:_idle_channel(saved_channel)
    self:_regression("idle-close:unregistered-no-polls")
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog)
    editor = self.editor
    check(self.plugin.channel == saved_channel and registrations(saved_channel) == 1,
        "reopen did not register its retained channel exactly once")
    self:_await(function() return not self.plugin.pending end, "reopen committed source")
    check(editor:getInputText() == SUCCESSOR and not editor._text_modified, "clean reopened source is dirty")
    self:_regression("reopen:single-registration")
    editor:toggleKeyboard(false)

    -- Keep the pre-save committed bytes as a clean native InputDialog value.
    -- When the receipt moves the saved baseline, these retained bytes become
    -- dirty without another edit. The generated Save guard must agree with its
    -- enabled button, as it must after rollback observes a concurrent save.
    editor:setInputText(SEED, true, false)
    button(editor, "save").callback()
    check(self.plugin.pending, "baseline-change save did not start")
    editor:setInputText(SUCCESSOR, false, false)
    check(not editor._text_modified, "retained value did not start with a clean native baseline")
    self:_await(function() return not self.plugin.pending end, "new saved baseline")
    check(self.plugin.saved_source == SEED and editor:getInputText() == SUCCESSOR
        and editor._text_modified and editor:isTextEdited() and button(editor, "save").enabled,
        "new committed baseline did not mark retained bytes natively dirty")
    button(editor, "save").callback()
    check(self.plugin.pending and self.plugin.pending.request.source == SUCCESSOR,
        "enabled generated Save silently ignored the retained draft")
    self:_await(function() return not self.plugin.pending end, "save retained bytes against new baseline")
    check(not editor._text_modified and not editor:isTextEdited(), "retained-byte save did not clean both native bits")
    self:_regression("new-baseline:retained-bytes-generated-save")
    -- Retire a real pending preview by rotating the actual fullscreen widget.
    -- The source survives; its late result cannot enable Activate or open a
    -- viewer. Exercise the smaller landscape viewport with the keyboard too.
    self:_execute(false, "retired by rotation")
    editor:onSetRotationMode(1)
    self:_await(function() return not self.plugin.pending end, "rotation resync")
    check(not self.plugin.result_viewer and not button(editor, "activate").enabled,
        "late preview survived rotation")
    editor:toggleKeyboard(true)
    check(editor.text_height >= editor._input_widget:getLineHeight(), "landscape keyboard leaves no editor line")
    self:_paint(editor, function() return editor:getInputText() == SUCCESSOR end, "landscape-source")
    editor:toggleKeyboard(false)
    editor:onSetRotationMode(0)
    self:_await(function() return not self.plugin.pending end, "portrait resync")
    check(not editor._text_modified, "rotation resync dirtied saved source")
    marker("rotation:late-preview-retired:source-retained")
    self:_execute(true, "alpha")
    self:_result("seed: alpha")
    self:_execute(false, "alpha")
    self:_result("revised: ALPHA")
    check(button(editor, "activate").enabled, "matching preview did not enable Activate")
    self:_confirm("activate", "Activate")
    self:_await(function() return self.plugin.result_viewer end, "activation")
    local successor_revision = self.plugin.snapshot.active_revision
    self:_result(successor_revision, "Active revision")
    self:_execute(true, "beta")
    self:_result("revised: BETA")
    marker("saved-preview-activate-installed:distinct")

    button(editor, "export").callback()
    self:_await(function() return self.plugin.result_viewer end, "export")
    local artifact = self.plugin.result_viewer.text
    check(artifact:find("revised:", 1, true), "export does not contain active source")
    self:_result(artifact, "Exported artifact — read only")

    editor:setInputText(BROKEN, true, false)
    button(editor, "save").callback()
    self:_await(function() return not self.plugin.pending end, "broken-source save")
    check(self.plugin.snapshot.source == BROKEN, "invalid source could not be saved as a draft")
    self:_execute(false, "test")
    self:_await(function() return self.plugin.result_viewer end, "preview diagnostic")
    local diagnostic = self.plugin.result_viewer.text
    check(diagnostic:find("preview-failed", 1, true), "preview diagnostic absent")
    self:_result(diagnostic, "Operation failed — draft retained")
    check(editor:getInputText() == BROKEN and not button(editor, "activate").enabled,
        "failed preview lost source or enabled activation")
    check(self.plugin.snapshot.active_revision == successor_revision, "failed preview changed active revision")
    editor:setInputText(DRAFT, true, false)
    self:_execute(true, "gamma")
    self:_result("revised: GAMMA")
    self:_confirm("rollback", "Roll back")
    self:_await(function() return self.plugin.result_viewer end, "rollback")
    self:_result(self.plugin.snapshot.active_revision, "Rolled back — draft retained")
    check(editor:getInputText() == DRAFT and button(editor, "save").enabled, "rollback lost unsaved draft")
    self:_execute(true, "delta")
    self:_result("seed: delta")
    marker("broken-draft-diagnostic-rollback:recovered")

    self:_execute(true, "retired by close")
    button(editor, "close").callback() -- real generated Close + unsaved confirmation
    local close = UIManager:getTopmostVisibleWidget()
    assert(find_button(close, "Close without saving"), "native unsaved close choice absent").callback()
    check(not UIManager:isWidgetShown(editor) and self.plugin.source_dialog == nil, "editor survived Close")
    check(self.plugin.retained_source == DRAFT and self.plugin.dialog == self.dialog, "close lost draft or owner")
    local channel, fd = self.plugin.channel, self.plugin.channel.fd
    check(not self.plugin.tearing_down and self.plugin.pending, "ordinary Close terminated the session")
    -- Reopen before the old installed-run reply can drain. That reply may only
    -- trigger a fresh open, never install a result into the replacement view.
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog)
    local reopened = self.editor
    self:_await(function() return not self.plugin.pending end, "same-FD reopen after a pending reply")
    check(not self.plugin.result_viewer and self.plugin.channel == channel and channel.fd == fd,
        "reopen adopted another channel or applied a retired result")
    check(reopened:getInputText() == DRAFT and reopened._text_modified and button(reopened, "save").enabled,
        "same-menu reopen lost the dirty draft")
    reopened:toggleKeyboard(false)
    self:_paint(reopened, function() return reopened:getInputText() == DRAFT end, "reopened-draft")
    self:_execute(true, "after reopen")
    self:_result("seed: after reopen")
    marker("same-menu-reopen:same-fd:dirty-draft-retained")

    self:_execute(true, "drain while closed")
    button(reopened, "close").callback()
    assert(find_button(UIManager:getTopmostVisibleWidget(), "Close without saving")).callback()
    check(self.plugin.pending and registrations(channel) == 1,
        "pending Close unregistered before its late result drained")
    self:_await(function() return not self.plugin.pending end, "closed-view result drain")
    check(not self.plugin.result_viewer and not self.plugin.source_dialog, "retired closed-view result reopened a widget")
    self:_idle_channel(channel)
    self:_regression("pending-close:drained-unregistered")
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog)
    reopened = self.editor
    check(registrations(channel) == 1, "reopen after drain duplicated the registration")
    self:_await(function() return not self.plugin.pending end, "reopen after unregistered drain")
    check(reopened:getInputText() == DRAFT and reopened._text_modified, "drain/reopen lost the draft")
    reopened:toggleKeyboard(false)
    -- The previous Close-without-saving toast stays above new modal widgets.
    -- Wait for the real editor to be visible before operating its confirmation.
    self:_paint(reopened, function() return reopened:getInputText() == DRAFT end, "reopened-after-drain")

    reopened:setInputText(SUCCESSOR, true, false)
    check(reopened._text_modified, "Save-and-Close test source is not dirty")
    button(reopened, "close").callback()
    local save_close = UIManager:getTopmostVisibleWidget()
    assert(find_button(save_close, "Save"), "native Save-and-Close choice absent").callback()
    check(self.plugin.source_dialog == reopened and self.plugin.pending,
        "Save-and-Close closed before its asynchronous receipt")
    reopened:setInputText(DRAFT, true, false)
    reopened:setInputText(SUCCESSOR, true, false)
    self:_await(function() return not self.plugin.pending end, "Save-and-Close with intervening edits")
    check(self.plugin.source_dialog == reopened and UIManager:isWidgetShown(reopened)
        and not reopened._text_modified and not reopened:isTextEdited(),
        "intervening edits auto-closed the editor or left a false dirty baseline")
    self:_regression("save-close-edit-away-back:clean-editor-stays-open")
    button(reopened, "close").callback()
    check(not self.plugin.source_dialog and not self.plugin.retained_dirty,
        "subsequent generated Close falsely prompted for already committed source")
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog)
    self:_await(function() return not self.plugin.pending end, "reopen after Save-and-Close")
    check(self.editor:getInputText() == SUCCESSOR and not self.editor._text_modified,
        "reopen lost the acknowledged Save-and-Close source")
    check(button(self.editor, "preview").enabled and not button(self.editor, "activate").enabled,
        "reopen kept an old preview/activation grant")
    self:_execute(true, "after Close-Save")
    self:_result("seed: after Close-Save")
    self.editor:setInputText(SEED, true, false)
    button(self.editor, "close").callback()
    assert(find_button(UIManager:getTopmostVisibleWidget(), "Save")).callback()
    check(self.plugin.source_dialog and self.plugin.pending, "normal Save-and-Close closed before its receipt")
    self:_await(function() return not self.plugin.pending and not self.plugin.source_dialog end, "normal acknowledged Save-and-Close")
    check(not self.plugin.retained_dirty and registrations(channel) == 0, "normal Save-and-Close left a dirty or polled view")
    self:_menu_open()
    self.editor = assert(self.plugin.source_dialog)
    self:_await(function() return not self.plugin.pending end, "reopen normal Save-and-Close")
    check(self.editor:getInputText() == SEED and not self.editor._text_modified, "normal Save-and-Close did not persist source")
    marker("generated-close-save:receipt-gated:reopened-clean")
    button(self.editor, "close").callback()
    check(self.plugin.channel == channel and not self.plugin.source_dialog, "clean Close stopped the transport")
    self.plugin:onCloseDocument()
    self:_await(function() return self.plugin.channel == nil end, "terminal plugin close acknowledgement")
    check(not self.plugin.pending, "terminal close retained a pending callback")
    check(registrations(channel) == 0, "terminal close retained its I/O registration")
    marker("terminal-teardown:authority-closed:channel-released")
    local cases = 0
    for _ in pairs(self.regressions) do cases = cases + 1 end
    check(cases == 6, "real-widget regression coverage is incomplete")
    marker("regression-cases:" .. cases)
end

function Probe:onReaderReady()
    local root = os.getenv("BOOK_WORKBENCH_REAL_UI_ROOT")
    if not root or os.getenv("HOME") ~= root .. "/home" or os.getenv("KO_HOME") ~= root .. "/ko" then
        marker("FAIL:private fixture profile missing"); UIManager:quit(1); return
    end
    local seen = {}
    for _ = 1, 2 do
        local top = UIManager:getTopmostVisibleWidget()
        if not top or not OVERLAYS[top.text] or seen[top.text] then
            marker("FAIL:unexpected startup overlay"); UIManager:quit(1); return
        end
        seen[top.text] = true; UIManager:close(top)
    end
    self.worker = coroutine.create(function() self:_run() end)
    UIManager:nextTick(function() self:_step() end)
end

return Probe
