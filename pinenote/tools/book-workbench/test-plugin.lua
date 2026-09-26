-- Fast offline channel/FSM checks. The widgets here are mocks; the companion
-- real-UI runner separately drives the bundled InputDialog and TouchMenu.
local plugin_dir = assert(arg[1], "usage: test-plugin.lua PLUGIN-DIRECTORY [REAL-RECEIPTS-FILE]")
local bundle = os.getenv("KOREADER_NATIVE_BUNDLE")
    or "/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03"
package.path = plugin_dir .. "/?.lua;" .. package.path
package.cpath = bundle .. "/lib/koreader/common/?.so;" .. package.cpath
local JSON = require("rapidjson")
local ffi = require("ffi")
ffi.cdef[[
int socketpair(int domain, int kind, int protocol, int descriptors[2]);
int pipe(int descriptors[2]);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
]]
local Channel = require("workbench_channel")
local C = ffi.C
local checks = 0
local function check(condition, reason)
    assert(condition, reason)
    checks = checks + 1
end
local function hex(text)
    return (text:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end
local function frame(sequence, payload)
    return "reply|" .. sequence .. "|" .. hex(JSON.encode(payload)) .. "\n"
end
local function snapshot(version, source, activation, active)
    return { workspace_version = version or 0, source = source or "seed",
        source_digest = string.rep("a", 64), active_revision = active or "seed-r1",
        previous_revision = false, activation_generation = activation or 0 }
end
local function success(op, snap)
    return { ok = true, op = op, snapshot = snap }
end
local function readonly(op, snap, text)
    local result = { ok = true, op = op, workspace_version = snap.workspace_version,
        source_digest = snap.source_digest, activation_generation = snap.activation_generation }
    if op == "export" then result.artifact = text
    else result.text, result.diagnostic = text, "" end
    return result
end

check(Channel.validCommand({ op = "save", expected_version = 0, source = string.rep("λ", 4096) }), "8 KiB UTF-8 source rejected")
check(not Channel.validCommand({ op = "save", expected_version = 0, source = string.rep("λ", 4097) }), "oversized source accepted")
for _, text in ipairs({"\0", "\192\128", "\237\160\128", "\244\144\128\128", "\226\130"}) do
    check(not Channel.validText(text, 8192), "invalid UTF-8/NUL accepted")
end
check(not Channel.validCommand({ op = "open", path = "/anything" }), "host path accepted")
check(not Channel.validCommand({ op = "save", expected_version = 0.5, source = "x" }), "fractional version accepted")
check(not Channel.validCommand({ op = "run", text = string.rep("x", 2049) }), "oversized run input accepted")
check(not Channel.validCommand({ op = "run", text = "" }), "empty run input accepted")
check(not Channel.validCommand({ op = "preview", expected_version = 0, text = "" }), "empty preview input accepted")
check(Channel.validCommand({ op = "run", text = "sample" }), "nonempty run input rejected")
check(Channel.encodeCommand(2147483647, {op = "open"}) ~= nil, "last legal sequence rejected")
check(Channel.encodeCommand(2147483648, {op = "open"}) == nil, "oversized sequence accepted")
local worst = Channel.encodeCommand(1, {op = "save", expected_version = 0, source = string.rep("\1", 8192)})
check(worst and #worst <= Channel.MAX_LINE + 1, "worst escaped valid source does not fit")
local valid = frame(1, success("open", snapshot())):sub(1, -2)
check(Channel.parseReply(valid) ~= nil, "valid reply rejected")
for _, line in ipairs({
    valid:gsub("reply|1|", "reply|01|"), valid:gsub("reply|1|", "reply|0|"),
    valid:gsub("reply|1|", "reply|1e0|"), valid:gsub("reply|1|", "reply|2147483648|"),
    valid:gsub("reply|", "command|"), "reply|1|7B7D", "reply|1|f", "reply|1|ff",
    "reply|1|" .. hex('{"ok":false,"op":"save","error":"x","ok":false}'),
    "reply|1|" .. hex('{"ok":false,"op":"save","error":"x","\\u006fk":false}'),
    "reply|1|" .. hex('{"ok":false,"op":"save","error":{ "a":{ "b":{} }}}'),
    "reply|1|" .. hex('{"ok":false,"op":"save","error":[]}'),
    "reply|1|" .. hex('{"ok":false,"op":"save","error":"x"} trailing'),
    string.rep("x", Channel.MAX_LINE + 1),
}) do
    check(Channel.parseReply(line) == nil, "malformed frame accepted")
end

local shown, sources, timers = {}, {}, {}
local registrations, removals = {}, {}
local UI = {}
function UI:show(widget) shown[#shown + 1] = widget end
function UI:close(widget)
    for i = #shown, 1, -1 do if shown[i] == widget then table.remove(shown, i) end end
    if widget.onCloseWidget then widget:onCloseWidget() end
end
function UI:isWidgetShown(widget)
    for _, item in ipairs(shown) do if item == widget then return true end end
    return false
end
function UI:setDirty() end
function UI:insertZMQ(source)
    assert(not sources[source], "duplicate channel registration")
    sources[source] = true
    registrations[source] = (registrations[source] or 0) + 1
end
function UI:removeZMQ(source)
    assert(sources[source], "channel removed without a registration")
    sources[source] = nil
    removals[source] = (removals[source] or 0) + 1
end
function UI:processZMQs()
    for source in pairs(sources) do source:waitEvent() end
end
function UI:scheduleIn(_, callback) timers[#timers + 1] = callback end
function UI:nextTick(callback) callback() end
function UI:unschedule(callback)
    for i = #timers, 1, -1 do if timers[i] == callback then table.remove(timers, i) end end
end

local Base = {}
function Base:extend(values) values.__index = values; return setmetatable(values, { __index = self }) end
function Base:new(values)
    values = setmetatable(values or {}, { __index = self })
    if values.init then values:init() end
    return values
end
local Dialog = Base:extend{}
function Dialog:init()
    self.text = self.text or self.input or ""
    self._input_widget = { is_text_edited = self._text_modified == true }
    self.title_bar = { title = self.title, setTitle = function(bar, value) bar.title = value end }
    local by_id = {}
    for _, row in ipairs(self.buttons or {}) do
        for _, button in ipairs(row) do if button.id then by_id[button.id] = button end end
    end
    if self.save_callback then
        by_id.save = { callback = function()
            -- Native InputDialog's generated Save has this independent guard.
            if self._text_modified then self.save_callback(self:getInputText()) end
        end,
            enabled = self._text_modified == true }
        local function close() self.close_callback(); UI:close(self) end
        by_id.close = { callback = function()
            if self._text_modified then
                UI:show{ choice1_callback = close, choice2_callback = function()
                    if self.save_callback(self:getInputText(), true) ~= false then close() end
                end }
            else close() end
        end }
    end
    for _, button in pairs(by_id) do
        if button.enabled == nil then button.enabled = true end
        function button:enable() self.enabled = true end
        function button:disable() self.enabled = false end
    end
    self.button_table = { getButtonById = function(_, id) return by_id[id] end }
end
function Dialog:getInputText() return self.text end
function Dialog:setInputText(text, edited)
    self.text, self._text_modified = text, edited == true
    self._input_widget.is_text_edited = edited == true
    if self.edited_callback and edited ~= nil then self.edited_callback(edited) end
end
function Dialog:refreshButtons() end
function Dialog:onShowKeyboard() end
function Dialog:onCloseWidget() end
function Dialog:onSetRotationMode() self:init() end
local passthrough = { new = function(_, value) return value end }
package.loaded["ui/uimanager"] = UI
package.loaded["ui/widget/inputdialog"] = Dialog
package.loaded["ui/widget/confirmbox"] = passthrough
package.loaded["ui/widget/infomessage"] = passthrough
package.loaded["ui/widget/textviewer"] = passthrough
package.loaded["ui/widget/container/widgetcontainer"] = Base
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded.gettext = function(value) return value end

local original_fd = os.getenv("BOOK_WORKBENCH_UI_FD")
C.unsetenv("BOOK_WORKBENCH_UI_FD")
check(assert(loadfile(plugin_dir .. "/main.lua"))().disabled, "plugin enabled without fixture FD")
for _, invalid in ipairs({"0", "2", "03", "3.0", "1e1", "-3", "2147483648"}) do
    C.setenv("BOOK_WORKBENCH_UI_FD", invalid, 1)
    check(assert(loadfile(plugin_dir .. "/main.lua"))().disabled, "invalid fixture FD enabled plugin")
end

local function fixture(defer_open)
    local fds = ffi.new("int[2]")
    assert(C.socketpair(1, 1, 0, fds) == 0)
    C.setenv("BOOK_WORKBENCH_UI_FD", tostring(tonumber(fds[0])), 1)
    local Class = assert(loadfile(plugin_dir .. "/main.lua"))()
    check(C.fcntl(fds[0], 1) % 2 == 1, "donated descriptor inheritable before menu open")
    local owner = {}
    local plugin = Class:new{ dialog = owner, ui = { menu = { registerToMainMenu = function() end } } }
    local menu = {}; plugin:addToMainMenu(menu)
    menu.wilkbook_book_workbench.callback()
    check(plugin.dialog == owner and plugin.source_dialog ~= owner, "owner/dialog conflation")
    check(not plugin.source_dialog.button_table:getButtonById("preview").enabled, "preview enabled before load")
    local server, input = tonumber(fds[1]), ""
    local function command()
        for _ = 1, 80 do
            local newline = input:find("\n", 1, true)
            if newline then
                local line = input:sub(1, newline - 1); input = input:sub(newline + 1)
                local sequence, text = line:match("^command|([1-9][0-9]*)|([0-9a-f]+)$")
                check(sequence ~= nil, "wrong command frame")
                text = text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
                return JSON.decode(text), tonumber(sequence)
            end
            local buffer = ffi.new("uint8_t[16384]")
            local count = C.recv(server, buffer, 16384, 64)
            if count > 0 then input = input .. ffi.string(buffer, count) end
            UI:processZMQs()
        end
        error("no complete command")
    end
    local function send(payload, sequence, wire)
        local line = wire or frame(sequence or plugin.sequence, payload)
        local offset = 0
        for _ = 1, 80 do
            if offset < #line then
                local count = C.send(server, ffi.cast("const uint8_t *", line) + offset,
                    math.min(8192, #line - offset), 16384 + 64)
                if count > 0 then offset = offset + tonumber(count) end
            end
            UI:processZMQs()
            if offset == #line and (not plugin.channel or #plugin.channel.input == 0) then return end
        end
        error("reply did not drain")
    end
    local function stop()
        plugin:onCloseDocument()
        if plugin.channel then
            local request = command()
            check(request.op == "close", "terminal teardown did not request close")
            send(success("close", plugin.snapshot or snapshot()))
        end
        C.close(server)
    end
    local request = command(); check(request.op == "open", "first request was not open")
    if not defer_open then send(success("open", snapshot())) end
    return plugin, command, send, stop, server
end

local plugin, command, send, stop = fixture()
local dialog = plugin.source_dialog
local function button(id) return dialog.button_table:getButtonById(id) end
local function edit(text) dialog:setInputText(text, true) end
edit("new source λ")
button("save").callback()
local request = command()
check(request.op == "save" and request.source == "new source λ" and request.expected_version == 0, "wrong save request")
send({ok = false, op = "save", error = "storage-failure"})
check(dialog:getInputText() == "new source λ" and button("save").enabled, "save failure lost draft/retry")
check(button("rollback").enabled, "recovery blocked by source failure")
button("save").callback(); command()
edit("newer unsaved source")
send(success("save", snapshot(1, "new source λ")))
check(dialog:getInputText() == "newer unsaved source" and button("save").enabled, "older save replaced newer edit")
check(not button("preview").enabled, "dirty source can preview")
button("save").callback(); command()
send(success("save", snapshot(2, "newer unsaved source")))
check(not dialog._text_modified and not button("save").enabled, "native saved baseline not reset")
check(button("preview").enabled and not button("activate").enabled, "preview/activation gate incorrect")
button("preview").callback()
local prompt = plugin.preview_prompt
check(prompt:getInputText() == "sample", "preview prompt did not seed nonempty input")
prompt:setInputText("")
local input_seq = plugin.sequence
prompt.button_table:getButtonById("preview").callback()
check(plugin.sequence == input_seq and UI:isWidgetShown(prompt), "empty input issued a command")
prompt:setInputText("hello")
prompt.button_table:getButtonById("preview").callback()
request = command(); check(request.op == "preview" and request.text == "hello", "preview prompt bypassed")
local saved = plugin.snapshot
send(readonly("preview", saved, "changed behavior"))
check(plugin.snapshot == saved and button("activate").enabled, "preview replaced snapshot or lost ticket")
check(plugin.result_viewer.text == "changed behavior", "preview text not displayed")
button("activate").callback(); shown[#shown].ok_callback()
request = command(); check(request.expected_activation == 0 and request.expected_version == 2, "activation not CAS-bound")
send(success("activate", snapshot(2, saved.source, 1, "successor-r2")))
check(not button("activate").enabled and plugin.snapshot.active_revision == "successor-r2", "activation state incorrect")
edit("deliberately broken source")
button("run").callback(); plugin.preview_prompt:setInputText("world")
plugin.preview_prompt.button_table:getButtonById("preview").callback()
request = command(); check(request.op == "run" and request.expected_version == nil, "UI selected draft for installed run")
send(readonly("run", plugin.snapshot, "installed behavior"))
check(dialog:getInputText() == "deliberately broken source" and plugin.result_viewer.text == "installed behavior", "run lost draft")
button("rollback").callback(); shown[#shown].ok_callback()
request = command(); check(request.op == "rollback" and request.expected_activation == 1, "rollback blocked or not correlated")
send(success("rollback", snapshot(2, saved.source, 2)))
check(dialog:getInputText() == "deliberately broken source" and plugin.snapshot.active_revision == "seed-r1", "rollback replaced dirty draft")
button("export").callback(); command()
saved = plugin.snapshot
send(readonly("export", saved, "portable artifact"))
check(plugin.snapshot == saved and plugin.result_viewer.text == "portable artifact", "export wrote/replaced source")
local seq = plugin.sequence
send(readonly("export", saved, "stale artifact"), seq - 1)
check(plugin.result_viewer.text == "portable artifact", "stale response applied")
button("save").callback(); command()
plugin:_invalidate_view()
send(success("save", snapshot(3, "deliberately broken source", 2)))
request = command(); check(request.op == "open", "invalidated callback did not resync")
edit("draft retained through navigation")
send(success("open", snapshot(3, "deliberately broken source", 2)))
check(dialog:getInputText() == "draft retained through navigation", "resync replaced dirty source")
button("save").callback(); command()
local serial = plugin.edit_serial
plugin:_edited(true) -- InputText repeats dirty=true on cursor movement.
check(plugin.edit_serial == serial, "cursor movement retired a save receipt")
UI:close(dialog)
check(plugin.retained_source == "draft retained through navigation", "close discarded dirty source")
local kept_channel = plugin.channel
check(sources[kept_channel] and registrations[kept_channel] == 1 and not removals[kept_channel],
    "Close unregistered before its pending save drained")
send(success("save", snapshot(4, "draft retained through navigation", 2)))
check(plugin.channel and not plugin.pending, "ordinary Close terminated donated transport")
check(not sources[kept_channel] and removals[kept_channel] == 1, "closed view kept polling after its reply drained")
local idle_polls = 0
local wait_event = kept_channel.waitEvent
kept_channel.waitEvent = function(channel) idle_polls = idle_polls + 1; return wait_event(channel) end
for _ = 1, 20 do UI:processZMQs() end
check(idle_polls == 0 and not kept_channel.closed, "closed idle view performs I/O or loses its FD")
check(#timers == 0, "completed requests retained deadline closures")
plugin:_open_workspace()
check(sources[kept_channel] and registrations[kept_channel] == 2, "reopen did not register its retained FD exactly once")
request = command(); check(request.op == "open", "reopen did not load a fresh snapshot")
local reopened = plugin.source_dialog
reopened:setInputText("reopened draft", true)
send(success("open", snapshot(4, "draft retained through navigation", 2)))
check(reopened:getInputText() == "reopened draft" and reopened._text_modified,
    "reopen replaced the retained draft or its native dirty state")
local old_sequence = plugin.sequence
dialog.close_callback()
dialog.save_callback("stale widget save")
button("export").callback()
check(plugin.source_dialog == reopened and plugin.sequence == old_sequence, "retired widget callback acted on reopened view")
reopened.button_table:getButtonById("save").callback(); command()
send(success("save", snapshot(5, "reopened draft", 2)))
UI:close(reopened)
check(not sources[kept_channel], "idle Close retained UI polling")
plugin:_open_workspace(); command()
send(success("open", snapshot(5, "reopened draft", 2)))
check(plugin.source_dialog:getInputText() == "reopened draft" and not plugin.source_dialog._text_modified,
    "clean close/reopen did not recover committed source")
stop()
check(plugin.channel == nil and next(sources) == nil and #timers == 0, "terminal teardown retained channel/deadline")

local p2, take2, send2, stop2, server2 = fixture()
p2.source_dialog:setInputText("disconnect draft", true)
C.close(server2)
p2.channel:waitEvent()
check(p2.disconnected and p2.source_dialog:getInputText() == "disconnect draft", "EOF lost draft")
p2.source_dialog:init()
check(not p2.source_dialog.button_table:getButtonById("save").enabled, "reinit enabled Save after EOF")
p2:onCloseDocument()

local p3, take3, send3, stop3 = fixture()
p3.source_dialog:setInputText("wrong receipt draft", true)
p3.source_dialog.button_table:getButtonById("save").callback(); take3()
send3(success("save", snapshot(1, "different content")))
check(p3.disconnected and p3.source_dialog:getInputText() == "wrong receipt draft", "mismatched save receipt accepted")
stop3()
local p4, take4, send4, stop4 = fixture()
send4(success("open", snapshot()), p4.sequence + 1)
check(p4.disconnected, "future reply accepted")
stop4()

for _, edited in ipairs({false, true}) do
    local p, take, reply, done = fixture(true)
    if edited then p.source_dialog:setInputText("early draft", true) end
    p.source_dialog:onSetRotationMode(1)
    reply(success("open", snapshot()))
    check(take().op == "open", "rotated initial load did not resync")
    reply(success("open", snapshot()))
    check(p.source_dialog:getInputText() == (edited and "early draft" or "seed"),
        "initial-load rotation replaced an edit or retained its empty placeholder")
    done()
end

for _, change in ipairs({
    function(snap) snap.active_revision = "unrelated-r2" end,
    function(snap) snap.previous_revision = "unrelated-r3" end,
    function(snap) snap.workspace_version = 2 end,
}) do
    local p, take, reply, done = fixture()
    p.source_dialog:setInputText("saved source", true)
    p.source_dialog.button_table:getButtonById("save").callback(); take()
    local invalid = snapshot(1, "saved source"); change(invalid)
    reply(success("save", invalid))
    check(p.disconnected and p.saved_source == "seed"
        and p.source_dialog:getInputText() == "saved source", "mismatched save generation acknowledged")
    done()
end

-- Save may observe an independently advanced activation. Only an unchanged
-- generation binds the old active/previous IDs; draft bytes and v+1 remain CAS.
for _, generation in ipairs({1, 3}) do
    local p, take, reply, done = fixture()
    p.source_dialog:setInputText("saved source", true)
    p.source_dialog.button_table:getButtonById("save").callback(); take()
    local advanced = snapshot(1, "saved source", generation, "other-installed-revision")
    advanced.previous_revision = "other-previous-revision"
    reply(success("save", advanced))
    check(not p.disconnected and p.snapshot.activation_generation == generation
        and p.saved_source == "saved source" and not p.source_dialog._text_modified,
        "valid save after an independent activation was rejected")
    done()
end
do
    local p, take, reply, done = fixture(true)
    reply(success("open", snapshot(0, "seed", 2)))
    p.source_dialog:setInputText("saved source", true)
    p.source_dialog.button_table:getButtonById("save").callback(); take()
    reply(success("save", snapshot(1, "saved source", 1)))
    check(p.disconnected and p.saved_source == "seed", "save accepted a backwards activation generation")
    done()
end

for _, change in ipairs({
    function(snap) snap.activation_generation = 0 end,
    function(snap) snap.activation_generation = 2 end,
    function(snap) snap.source = "unrelated draft" end,
    function(snap) snap.source_digest = string.rep("b", 64) end,
}) do
    for _, op in ipairs({"activate", "rollback"}) do
        local p, take, reply, done = fixture()
        if op == "activate" then
            p.preview_version = 0
            p:_activate()
        else p:_rollback() end
        shown[#shown].ok_callback(); take()
        local invalid = snapshot(0, "seed", 1); change(invalid)
        reply(success(op, invalid))
        check(p.disconnected and p.snapshot.activation_generation == 0, "mismatched activation receipt applied")
        done()
    end
end

do
    local p, take, reply, done = fixture()
    p.preview_version = 0; p:_activate(); shown[#shown].ok_callback(); take()
    reply(success("activate", snapshot(1, "seed", 1)))
    check(p.disconnected, "dual-CAS activation accepted another draft version")
    done()
end

-- Intervening edits affect automatic Close, not byte-identical cleanliness.
for _, close_after in ipairs({false, true}) do
    local p, take, reply, done = fixture()
    local editor = p.source_dialog
    editor:setInputText("submitted", true)
    if close_after then
        editor.button_table:getButtonById("close").callback()
        shown[#shown].choice2_callback()
    else editor.button_table:getButtonById("save").callback() end
    take()
    editor:setInputText("intermediate", true)
    editor:setInputText("submitted", true)
    reply(success("save", snapshot(1, "submitted")))
    check(not p:_dirty() and not editor._text_modified and not editor._input_widget.is_text_edited
        and not editor.button_table:getButtonById("save").enabled, "edit-away/back kept a false native dirty baseline")
    check(p.source_dialog == editor, "intervening edits still allowed automatic Save-and-Close")
    editor.button_table:getButtonById("close").callback()
    check(not p.source_dialog and not p.retained_dirty, "generated Close falsely prompted for committed bytes")
    done()
end

local receipt_cases = 0
if arg[2] then
    local genuine = {}
    for line in io.lines(arg[2]) do
        local decoded = assert(Channel.parseReply(line), "invalid production-encoded receipt")
        genuine[#genuine + 1] = { payload = decoded.payload, sequence = decoded.sequence, wire = line .. "\n" }
    end
    check(#genuine == 4, "expected four two-authority receipts")
    local function receipt(p, send, index)
        local value = genuine[index]
        check(value.sequence == p.pending.sequence, "production receipt is not correlated with this UI request")
        send(value.payload, value.sequence, value.wire)
    end
    do
        local p, take, reply, done = fixture(true)
        receipt(p, reply, 1)
        p.source_dialog:setInputText("A draft", true)
        p.source_dialog.button_table:getButtonById("save").callback()
        local request = take()
        check(request.op == "save" and request.expected_version == 0 and request.source == "A draft",
            "UI did not issue the genuine receipt's save")
        receipt(p, reply, 2)
        check(not p.disconnected and p.snapshot.workspace_version == 1 and p.snapshot.activation_generation == 1
            and p.saved_source == "A draft" and not p.source_dialog._text_modified,
            "real A-save after B-rollback was rejected or failed to clean the editor")
        receipt_cases = receipt_cases + 1
        done()
    end
    do
        local p, take, reply, done = fixture(true)
        receipt(p, reply, 3)
        local seed = p.snapshot
        local editor = p.source_dialog
        check(not editor._text_modified, "rollback interleaving did not begin with a clean editor")
        p:_rollback(); shown[#shown].ok_callback()
        local request = take()
        check(request.op == "rollback" and request.expected_activation == 0, "UI did not issue the genuine receipt's rollback")
        receipt(p, reply, 4)
        check(not p.disconnected and p.snapshot.workspace_version == 1 and p.snapshot.activation_generation == 1
            and p.saved_source == "B draft" and editor:getInputText() == "seed",
            "real A-rollback after B-save was rejected or overwrote visible bytes")
        check(editor._text_modified and editor._input_widget.is_text_edited
            and editor.button_table:getButtonById("save").enabled, "new saved baseline did not dirty the retained native editor")
        editor.button_table:getButtonById("save").callback()
        check(p.pending ~= nil, "generated native Save's dirty guard silently discarded the retained draft")
        request = take()
        check(request.op == "save" and request.expected_version == 1 and request.source == "seed",
            "recovery save did not use the new authority baseline")
        local saved = { workspace_version = 2, activation_generation = 1, source = "seed",
            source_digest = seed.source_digest, active_revision = p.snapshot.active_revision,
            previous_revision = p.snapshot.previous_revision }
        reply(success("save", saved))
        editor.button_table:getButtonById("close").callback()
        check(not p.source_dialog, "recovery save did not clean generated Close's baseline")
        receipt_cases = receipt_cases + 1
        done()
    end
end

for _, op in ipairs({"preview", "run", "export"}) do
    for _, key in ipairs({"workspace_version", "activation_generation", "source_digest"}) do
        local p, take, reply, done = fixture()
        if op == "export" then p:_request({op = "export"})
        elseif op == "run" then p:_request({op = "run", text = "sample"})
        else p:_request({op = "preview", expected_version = 0, text = "sample"}) end
        take()
        local invalid = readonly(op, p.snapshot, "different result")
        invalid[key] = key == "source_digest" and string.rep("b", 64) or 1
        reply(invalid)
        check(p.disconnected and not p.result_viewer, "read-only reply with wrong metadata applied")
        done()
    end
end

local p5, take5, send5, stop5 = fixture()
p5:_preview(); p5.preview_prompt.button_table:getButtonById("preview").callback(); take5()
local expired = p5.pending.timeout
p5.source_dialog:onSetRotationMode(1)
send5(readonly("preview", p5.snapshot, "retired preview"))
check(not p5.result_viewer and p5.preview_version == nil and take5().op == "open", "rotated preview callback applied")
send5(success("open", snapshot()))
expired()
check(not p5.disconnected and #timers == 0, "retired deadline stopped current view")
p5.source_dialog:setInputText("timeout draft", true)
p5.source_dialog.button_table:getButtonById("save").callback(); take5()
p5.pending.timeout()
check(p5.disconnected and p5.source_dialog:getInputText() == "timeout draft" and #timers == 0, "timeout discarded source or leaked timer")
stop5()

local p6, take6, send6, stop6, server6 = fixture()
C.close(server6)
p6.source_dialog:setInputText("write-error draft", true)
p6.source_dialog.button_table:getButtonById("save").callback()
check(p6.disconnected and p6.source_dialog:getInputText() == "write-error draft", "write error discarded draft (or SIGPIPE killed UI)")
p6:onCloseDocument()

local p7, take7, reply7, done7 = fixture()
local old_editor, channel = p7.source_dialog, p7.channel
old_editor:setInputText("submitted before Close", true)
old_editor.button_table:getButtonById("save").callback(); take7()
local old_seq = p7.sequence
UI:close(old_editor)
p7:_open_workspace()
local new_editor = p7.source_dialog
new_editor:setInputText("edited after reopen", true)
check(p7.sequence == old_seq and p7.pending, "reopen overlapped an outstanding request")
reply7(success("save", snapshot(1, "submitted before Close")), old_seq)
check(p7.saved_source == "seed" and new_editor:getInputText() == "edited after reopen",
    "old save receipt changed reopened editor/baseline")
check(take7().op == "open", "retired save did not drain into a fresh open")
reply7(success("open", snapshot(1, "submitted before Close")))
check(p7.channel == channel and new_editor:getInputText() == "edited after reopen"
    and new_editor._text_modified, "same-FD reopen lost dirty source")
check(registrations[channel] == 1 and not removals[channel], "immediate reopen double-registered or removed its pending channel")
done7()

-- A preserving open is still waiting on the new baseline. Retire it again
-- before its reply, including a close whose reply drains while the view is gone.
for _, interruption in ipairs({"none", "rotation", "close-reopen", "close-drain-reopen"}) do
    local p, take, reply, done = fixture()
    local editor = p.source_dialog
    editor:setInputText("in-flight replacement", true)
    editor.button_table:getButtonById("save").callback(); take()
    editor:setInputText("seed", true)
    check(not editor._text_modified, "reversion to the known committed baseline is falsely dirty")
    editor.button_table:getButtonById("close").callback()
    p:_open_workspace()
    reply(success("save", snapshot(1, "in-flight replacement")))
    check(take().op == "open", "reversion/reopen did not drain the old save first")
    check(p.pending.options.preserve_draft, "first resync did not preserve the reverted source")
    if interruption ~= "none" then
        if interruption == "rotation" then
            p.source_dialog:onSetRotationMode(1)
        else
            p.source_dialog.button_table:getButtonById("close").callback()
            check(not p.source_dialog, "second Close falsely prompted against the old baseline")
            if interruption == "close-drain-reopen" then
                reply(success("open", snapshot(1, "in-flight replacement")))
                check(not p.pending and not sources[p.channel], "closed resync did not drain and unregister")
            end
            p:_open_workspace()
        end
        if interruption ~= "close-drain-reopen" then
            reply(success("open", snapshot(1, "in-flight replacement")))
        end
        check(take().op == "open" and p.saved_source == "seed", "retired resync changed the current baseline")
    end
    reply(success("open", snapshot(1, "in-flight replacement")))
    editor = p.source_dialog
    check(editor:getInputText() == "seed" and editor._text_modified and editor._input_widget.is_text_edited
        and p.saved_source == "in-flight replacement" and p.snapshot.workspace_version == 1,
        "preserving resync lost the reverted draft after " .. interruption)
    editor.button_table:getButtonById("save").callback()
    check(p.pending ~= nil, "retained draft's native Save did nothing after " .. interruption)
    local request = take()
    check(request.op == "save" and request.expected_version == 1 and request.source == "seed",
        "retained draft's Save did not use the reconciled baseline")
    reply(success("save", snapshot(2, "seed")))
    check(not editor._text_modified and not editor._input_widget.is_text_edited and not p.view_preserve_draft,
        "current-view save did not clear the reconciled preservation obligation")
    done()
end

local p8, take8, reply8, done8 = fixture()
p8:_request({op = "run", text = "sample"}); take8()
p8:onCloseDocument()
reply8(readonly("run", p8.snapshot, "late teardown result"))
check(not p8.result_viewer and take8().op == "close", "teardown did not drain pending result before close")
reply8(success("close", p8.snapshot))
check(p8.channel == nil and #timers == 0, "close acknowledgement retained teardown deadline")
done8()

local p9, take9, reply9, done9 = fixture()
p9.preview_version = 0
p9:_activate(); shown[#shown].ok_callback(); take9()
reply9({ok = false, op = "activate", error = "revision-quota-exhausted"})
check(shown[#shown].text == "This workspace has reached its 128-revision limit. The draft is saved; running, exporting and rolling back installed source still work.",
    "revision quota error did not explain remaining recovery actions")
check(p9.saved_source == "seed" and p9.snapshot.active_revision == "seed-r1", "quota error changed saved/active source")
local quota_buttons = p9.source_dialog.button_table
check(quota_buttons:getButtonById("run").enabled and quota_buttons:getButtonById("export").enabled
    and quota_buttons:getButtonById("rollback").enabled and not quota_buttons:getButtonById("activate").enabled,
    "quota error blocked recovery or allowed a blind activation retry")
done9()

local p10, take10, reply10, done10 = fixture()
p10:onCloseDocument()
check(take10().op == "close", "idle teardown omitted terminal close")
p10.shutdown_timeout()
check(p10.channel == nil and not p10.pending and #timers == 0, "silent teardown exceeded bounded cleanup")
done10()

-- The same production pump is nonreentrant and consumes at most one frame.
local pipe = ffi.new("int[2]"); assert(C.pipe(pipe) == 0)
check(Channel:new{fd = tonumber(pipe[0]), receive = function() end} == nil, "non-socket adopted as authority")
check(C.fcntl(pipe[0], 1) == -1, "rejected donated descriptor leaked")
C.close(pipe[1])
local fds = ffi.new("int[2]"); assert(C.socketpair(1, 1, 0, fds) == 0)
local count, errors, channel = 0, 0
channel = assert(Channel:new{fd = tonumber(fds[0]), receive = function()
    count = count + 1; channel:waitEvent()
end, on_error = function() errors = errors + 1 end})
local wire = frame(1, success("open", snapshot())) .. frame(2, success("open", snapshot()))
assert(C.send(fds[1], wire, #wire, 16384) == #wire)
channel:waitEvent(); check(count == 1, "reentrant or unbounded receive")
channel:waitEvent(); check(count == 2, "second bounded pump failed")
local bad = "reply|01|00\n"; assert(C.send(fds[1], bad, #bad, 16384) == #bad)
channel:waitEvent(); channel:waitEvent()
check(channel.closed and errors == 1, "malformed transport did not fail once")
check(not channel:stop(), "stop was not idempotent")
C.close(fds[1])
if original_fd then C.setenv("BOOK_WORKBENCH_UI_FD", original_fd, 1)
else C.unsetenv("BOOK_WORKBENCH_UI_FD") end
print("PASS: Workbench channel/FSM " .. checks .. " checks (mock widgets; no source execution)")
print("Production-authority/SQLite receipt interleavings: " .. receipt_cases)
