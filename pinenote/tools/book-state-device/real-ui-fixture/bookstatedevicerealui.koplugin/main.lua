-- Host-only controller for the production device plugin running inside a full
-- native KOReader ReaderUI. It drives real TouchMenu and generated InputDialog
-- buttons over controlled socketpairs; it is not a storage, sandbox,
-- persistence, activation, or security-boundary test.
local PluginLoader = require("pluginloader")
local SocketFixture = require("real_ui_socket_fixture")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Probe = WidgetContainer:extend{
    name = "bookstatedevicerealui",
    is_doc_only = true,
}

local SAVED_TEXT = "Native widget save — 東京 λ"
local EXPECTED_OVERLAYS = {
    ["Book info cache database updated."] = true,
    ["Documents will be rendered in color on this device.\n"
        .. "If your device is grayscale, you can disable color rendering in "
        .. "the screen sub-menu for reduced memory usage."] = true,
}

local function marker(value)
    print("BOOK_STATE_DEVICE_REAL_UI: " .. value)
end

function Probe:init()
    self.failed = false
    self.finished = false
    self.paint_count = 0
    local root = os.getenv("BOOK_STATE_DEVICE_REAL_UI_ROOT")
    if not root or os.getenv("HOME") ~= root .. "/home"
            or os.getenv("KO_HOME") ~= root .. "/ko" then
        self:_fail("private real-UI profile environment is not exact")
    end
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
        SocketFixture.closeServers()
        UIManager:quit(1)
    end)
end

function Probe:_safe(callback)
    if self.failed or self.finished then return end
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then self:_fail(err) end
end

function Probe:_schedule(delay, callback)
    UIManager:scheduleIn(delay, function()
        self:_safe(callback)
    end)
end

function Probe:_dismiss_startup_overlays()
    local dismissed, seen = 0, {}
    local top = UIManager:getTopmostVisibleWidget()
    while top and dismissed < 2 do
        if not EXPECTED_OVERLAYS[top.text] or seen[top.text] then
            return self:_fail("unexpected startup overlay: " .. tostring(top.text))
        end
        seen[top.text] = true
        UIManager:close(top)
        dismissed = dismissed + 1
        top = UIManager:getTopmostVisibleWidget()
    end
    if not self:_check(dismissed == 2,
            "clean native profile did not show both pinned startup overlays") then
        return false
    end
    marker("startup-overlays-dismissed:2")
    return true
end

local function direct_item(items, id)
    for _, item in ipairs(items or {}) do
        if item.id == id then return item end
    end
end

local function containing_tab(tabs, id)
    local function contains(items)
        for _, item in ipairs(items or {}) do
            if item.id == id or contains(item.sub_item_table) then return true end
        end
        return false
    end
    for index, tab in ipairs(tabs or {}) do
        if contains(tab) then return index end
    end
end

function Probe:_open_through_touch_menu()
    local reader_menu = self.ui.menu
    if not self:_check(reader_menu ~= nil, "ReaderMenu is unavailable") then return end
    if not reader_menu.tab_item_table then reader_menu:setUpdateItemTable() end
    local tab_index = containing_tab(reader_menu.tab_item_table, "more_tools")
    if not self:_check(tab_index ~= nil, "More tools is absent from ReaderMenu") then return end
    reader_menu:onShowMenu(tab_index)
    local container = reader_menu.menu_container
    local touch_menu = container and container[1]
    if not self:_check(touch_menu and type(touch_menu.onMenuSelect) == "function",
            "ReaderMenu did not create a real TouchMenu") then return end
    if not self:_check(UIManager:isWidgetShown(container),
            "real TouchMenu container was not shown") then return end
    local more_tools = direct_item(touch_menu.item_table, "more_tools")
    if not self:_check(more_tools and more_tools.sub_item_table,
            "real TouchMenu lacks the More tools submenu") then return end
    touch_menu:onMenuSelect(more_tools)
    local note = direct_item(touch_menu.item_table, "wilkbook_book_state_note")
    if not self:_check(note and type(note.callback) == "function",
            "production note is absent from real More tools menu") then return end
    marker("touch-menu-selected:more-tools/persistent-note")
    touch_menu:onMenuSelect(note)
end

function Probe:_retain_dialog(dialog, generation)
    local original_paint = dialog.paintTo
    dialog.paintTo = function(widget, ...)
        original_paint(widget, ...)
        self.paint_count = self.paint_count + 1
        if UIManager:getTopmostVisibleWidget() == widget then
            self.last_painted_title = widget.title_bar.title
            self.last_painted_text = widget:getInputText()
            self.last_painted_generation = generation
        end
    end
    UIManager:setDirty(dialog, "ui")
end

function Probe:_assert_real_dialog(generation)
    local plugin = self.production
    local dialog = plugin.note_dialog
    if not self:_check(dialog and dialog ~= plugin.dialog,
            "TouchMenu selection did not create a separate note InputDialog") then return end
    if not self:_check(plugin.dialog == self.dialog and plugin.ui == self.ui,
            "PluginLoader did not inject the exact ReaderUI owner") then return end
    if not self:_check(UIManager:isWidgetShown(dialog)
            and UIManager:getTopmostVisibleWidget() == dialog,
            "production InputDialog is not shown topmost") then return end
    local save = dialog.button_table and dialog.button_table:getButtonById("save")
    local close = dialog.button_table and dialog.button_table:getButtonById("close")
    if not self:_check(save and close and type(save.callback) == "function"
            and type(close.callback) == "function",
            "real InputDialog did not generate Save and Close buttons") then return end
    if not self:_check(type(dialog.title_bar.setTitle) == "function"
            and type(dialog.refreshButtons) == "function"
            and dialog:isTextEditable(),
            "real InputDialog title/editor/refresh APIs are unavailable") then return end
    if not dialog:isKeyboardVisible() then dialog:onShowKeyboard() end
    if not self:_check(dialog:isKeyboardVisible(),
            "real InputDialog keyboard could not be shown") then return end
    -- Keep subsequent paint assertions about the editor itself rather than the
    -- emulator's keyboard overlay; availability was exercised above.
    dialog:onCloseKeyboard()
    self.dialogs = self.dialogs or {}
    self.dialogs[generation] = dialog
    self:_retain_dialog(dialog, generation)
    marker("input-dialog-real:generation=" .. generation
        .. ":owner-separated:keyboard-available")
    return dialog
end

function Probe:_await_events(index, expected, continuation, attempt)
    attempt = attempt or 0
    while expected[1] do
        local event = SocketFixture.take(index)
        if not event then break end
        local wanted = table.remove(expected, 1)
        if not self:_check(event.kind == wanted[1] and event.generation == 1
                and event.value == wanted[2],
                string.format("socket %d expected %s/%q, got %s/%q",
                    index, wanted[1], wanted[2], event.kind, event.value)) then
            return
        end
        marker(string.format("frame:%d:%s:%s", index, event.kind,
            event.value == "" and "empty" or event.value))
    end
    if not expected[1] then return continuation() end
    if attempt >= 250 then return self:_fail("timed out waiting for real StateChannel frames") end
    self:_schedule(0.01, function()
        self:_await_events(index, expected, continuation, attempt + 1)
    end)
end

function Probe:_await_paint(generation, title, text, minimum_count, continuation,
        attempt)
    attempt = attempt or 0
    if self.paint_count > minimum_count
            and self.last_painted_generation == generation
            and self.last_painted_title == title
            and self.last_painted_text == text then
        marker("paint:generation=" .. generation .. ":" .. title)
        return continuation()
    end
    if attempt >= 200 then return self:_fail("timed out waiting for exact InputDialog paint") end
    local dialog = self.dialogs[generation]
    if dialog then UIManager:setDirty(dialog, "ui") end
    self:_schedule(0.01, function()
        self:_await_paint(generation, title, text, minimum_count,
            continuation, attempt + 1)
    end)
end

function Probe:_close_and_reopen(first_dialog)
    local close = first_dialog.button_table:getButtonById("close")
    close.callback()
    self:_schedule(0.05, function()
        if not self:_check(self.production.dialog == self.dialog,
                "generated Close changed the injected ReaderUI owner") then return end
        if not self:_check(self.production.note_dialog == nil
                and not UIManager:isWidgetShown(first_dialog),
                "generated Close did not close only the note editor") then return end
        self:_await_events(1, {{"closed", ""}}, function()
            self:_schedule(0.06, function()
                if not self:_check(self.production.channel == nil,
                        "closed editor retained its StateChannel") then return end
                if not self:_check(SocketFixture.peerClosed(1),
                        "closed editor retained its socketpair endpoint") then return end
                self:_open_through_touch_menu()
                local second = self:_assert_real_dialog(2)
                if not second then return end
                self:_await_events(2,
                    {{"channel-ready", ""}, {"ready", ""}}, function()
                    SocketFixture.send(2, "load-value", SAVED_TEXT)
                    self:_await_events(2,
                        {{"status", "loaded-value"}, {"applied", SAVED_TEXT}},
                        function()
                            if not self:_check(second:getInputText() == SAVED_TEXT,
                                    "fresh socket load did not restore saved text") then return end
                            local before = self.paint_count
                            self:_await_paint(2, "Persistent note — Loaded",
                                SAVED_TEXT, before, function()
                                second.button_table:getButtonById("close").callback()
                                self:_await_events(2, {{"closed", ""}}, function()
                                    self:_schedule(0.06, function()
                                        if not self:_check(self.production.dialog == self.dialog
                                                and self.production.note_dialog == nil,
                                                "second Close damaged owner/editor lifecycle") then return end
                                        marker("close-reopen:fresh-socket:same-text")
                                         self:_test_disconnect()
                                    end)
                                end)
                            end)
                        end)
                end)
            end)
        end)
    end)
end

function Probe:_test_disconnect()
    self:_open_through_touch_menu()
    local dialog = self:_assert_real_dialog(3)
    if not dialog then return end
    self:_await_events(3, {{"channel-ready", ""}, {"ready", ""}}, function()
        SocketFixture.closeServers()
        self:_schedule(0.1, function()
            if not self:_check(self.production.transport_failed,
                    "real socket EOF did not fail the transport") then return end
            dialog:setInputText("unsaved draft", true, false)
            if not self:_check(not dialog.button_table:getButtonById("save").enabled,
                    "editing after disconnect re-enabled Save") then return end
            local before = self.paint_count
            self:_await_paint(3, "Persistent note — Authority stopped; NOT saved",
                "unsaved draft", before, function()
                    marker("disconnect:draft-retained:save-disabled:not-saved-painted")
                    UIManager:close(dialog)
                    self.finished = true
                    marker("result:ok")
                    UIManager:quit(0)
                end)
        end)
    end)
end

function Probe:_run_interaction()
    -- The SDL emulator advertises a host keyboard, so its clean-profile default
    -- suppresses the on-screen keyboard. Enable it only in this private test
    -- profile to exercise the PineNote-facing InputDialog keyboard path.
    G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
    self:_open_through_touch_menu()
    local dialog = self:_assert_real_dialog(1)
    if not dialog then return end
    self:_await_events(1, {{"channel-ready", ""}, {"ready", ""}}, function()
        SocketFixture.send(1, "load-absent", "")
        self:_await_events(1,
            {{"status", "loaded-absent"}, {"applied", ""}}, function()
            dialog:setInputText(SAVED_TEXT, true, false)
            self:_await_events(1, {{"status", "dirty"}}, function()
                local save = dialog.button_table:getButtonById("save")
                if not self:_check(save.enabled,
                        "real generated Save button did not enable after edit") then return end
                save.callback()
                self:_await_events(1,
                    {{"submit", SAVED_TEXT}, {"status", "pending"}}, function()
                    SocketFixture.send(1, "commit-ok", SAVED_TEXT)
                    self:_await_events(1, {{"status", "saved"}}, function()
                        if not self:_check(not save.enabled,
                                "receipt did not disable real generated Save button") then return end
                        local before_saved = self.paint_count
                        self:_await_paint(1, "Persistent note — Saved",
                            SAVED_TEXT, before_saved, function()
                            local before_present = self.paint_count
                            SocketFixture.send(1, "present", SAVED_TEXT)
                            self:_await_events(1, {{"applied", SAVED_TEXT}}, function()
                                self:_await_paint(1, "Persistent note — Saved",
                                    SAVED_TEXT, before_present, function()
                                    self:_close_and_reopen(dialog)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

function Probe:onReaderReady()
    self:_safe(function()
        if not self:_dismiss_startup_overlays() then return end
        self.production = PluginLoader:getPluginInstance("bookstatedevice")
        if not self:_check(self.production ~= nil,
                "PluginLoader did not instantiate the production device plugin") then return end
        if not self:_check(self.production.dialog == self.dialog
                and self.production.dialog ~= nil,
                "production plugin lacks the ReaderUI-injected owner dialog") then return end
        if not self:_check(self.production.note_dialog == nil,
                "production plugin has an editor before menu selection") then return end
        marker("pluginloader-owner-injection:exact")
        UIManager:scheduleIn(10, function()
            if not self.finished and not self.failed then
                self:_fail("global native UI test deadline expired")
            end
        end)
        UIManager:nextTick(function()
            self:_safe(function() self:_run_interaction() end)
        end)
    end)
end

function Probe:onCloseDocument()
    if self.production and self.production.note_dialog
            and UIManager:isWidgetShown(self.production.note_dialog) then
        UIManager:close(self.production.note_dialog)
    end
end

return Probe
