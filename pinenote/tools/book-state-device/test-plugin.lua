-- Host-only callback test for the device adapter. It invokes the production
-- InputDialog callbacks; there are no production edit/save test commands.
local ffi = require("ffi")
ffi.cdef[[
int socketpair(int domain, int type, int protocol, int descriptors[2]);
long read(int fd, void *buffer, unsigned long count);
long write(int fd, const void *buffer, unsigned long count);
int close(int fd);
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long count, int timeout);
]]
local C = ffi.C
local plugin_dir = assert(arg[1], "plugin directory required")
package.path = plugin_dir .. "/?.lua;" .. package.path

local peers = {}

local ticks, scheduled = {}, {}
local shown, sources = {}, {}
local UIManager = {
    -- Like the real UIManager, allow a closing channel to coexist with a new one.
    insertZMQ = function(_, source) assert(not sources[source]); sources[source] = true end,
    removeZMQ = function(_, source) sources[source] = nil end,
    show = function(_, widget) shown[widget] = true end,
    close = function(_, widget) shown[widget] = nil end,
    isWidgetShown = function(_, widget) return shown[widget] == true end,
    setDirty = function() end,
    nextTick = function(_, callback) ticks[#ticks + 1] = callback end,
    scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback end,
}
local function drain(queue)
    while queue[1] do table.remove(queue, 1)() end
end

local InputDialog = {}
function InputDialog:new(options)
    local save_button = {
        enabled = false,
        enable = function(self) self.enabled = true end,
        disable = function(self) self.enabled = false end,
    }
    options.text = options.input
    options.title_bar = {
        title = options.title,
        setTitle = function(self, value) self.title = value end,
    }
    options.button_table = { getButtonById = function(_, id)
        assert(id == "save"); return save_button
    end }
    function options:setInputText(value) self.text = value end
    function options:getInputText() return self.text end
    function options:refreshButtons() end
    return options
end
local WidgetContainer = {}
function WidgetContainer:extend(values) return values end

package.preload["activation"] = function()
    return { enabled = function() return true end }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/inputdialog"] = function() return InputDialog end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["unix_client"] = function()
    return { connect = function()
        local fds = ffi.new("int[2]")
        assert(C.socketpair(1, 1, 0, fds) == 0)
        local fd = tonumber(fds[0])
        peers[fd] = tonumber(fds[1])
        return fd
    end }
end

local function readable(session)
    local fds = ffi.new("struct pollfd[1]")
    fds[0].fd, fds[0].events = session.peer, 1
    local count = C.poll(fds, 1, 0)
    assert(count >= 0, "socket poll failed")
    return count == 1
end
local function read_line(session)
    local bytes = {}
    while true do
        assert(readable(session), "expected a UI frame, but the socket is empty")
        local byte = ffi.new("uint8_t[1]")
        assert(C.read(session.peer, byte, 1) == 1, "UI channel closed instead of sending a frame")
        if byte[0] == 10 then return string.char(unpack(bytes)) end
        bytes[#bytes + 1] = tonumber(byte[0])
    end
end
local function hex(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end
local function command(session, kind, value)
    local line = string.format("%s|1|%s\n", kind, hex(value or ""))
    assert(C.write(session.peer, line, #line) == #line)
    assert(sources[session.channel], "authority command needs a registered channel")
    session.channel:waitEvent()
end
local function expect(session, kind, value)
    local wanted = string.format("%s|1|%s", kind, hex(value or ""))
    local got = read_line(session)
    assert(got == wanted, string.format("expected %s, got %s", wanted, got))
end
local function expect_empty(session)
    assert(not readable(session), "unexpected UI frame or closed socket")
end
local function expect_closed(session)
    assert(session.channel.closed and not sources[session.channel],
        "retired channel is still live or registered")
    assert(readable(session), "retired channel did not close its socket")
    assert(C.read(session.peer, ffi.new("uint8_t[1]"), 1) == 0,
        "retired channel sent a stale frame instead of closing")
    C.close(session.peer)
end

local Plugin = assert(loadfile(plugin_dir .. "/main.lua"))()
local menu_items = {}
local owner_dialog = {}
local plugin = setmetatable({
    dialog = owner_dialog, -- ReaderUI and FileManager inject this attribute.
    ui = { menu = { registerToMainMenu = function(_, owner) assert(owner) end } },
}, { __index = Plugin })
plugin:init()
plugin:addToMainMenu(menu_items)
assert(menu_items.wilkbook_book_state_note)
local function open_note()
    menu_items.wilkbook_book_state_note.callback()
    assert(plugin.dialog == owner_dialog and plugin.note_dialog ~= owner_dialog)
    local session = {
        dialog = assert(plugin.note_dialog), channel = assert(plugin.channel),
        peer = assert(peers[plugin.channel.fd]),
    }
    session.save = session.dialog.button_table:getButtonById("save")
    expect(session, "channel-ready", "")
    return session
end
local function ready(session)
    drain(ticks)
    expect(session, "ready", "")
end
local function load_note(session, value)
    command(session, value and "load-value" or "load-absent", value)
    drain(ticks)
    expect(session, "status", value and "loaded-value" or "loaded-absent")
    expect(session, "applied", value or "")
    assert(not session.save.enabled)
end
local function edit(session, value)
    session.dialog:setInputText(value)
    session.dialog.edited_callback(true)
end
local function submit(session, value)
    local was_dirty = plugin.state == "dirty"
    edit(session, value)
    drain(ticks)
    if not was_dirty then expect(session, "status", "dirty") end
    assert(session.save.enabled)
    local ok, message = session.dialog.save_callback(session.dialog:getInputText())
    assert(ok == false and message == false)
    expect(session, "submit", value)
    assert(not session.save.enabled)
end
local function close_note(session)
    session.dialog.close_callback()
    UIManager:close(session.dialog)
    assert(plugin.dialog == owner_dialog and plugin.note_dialog == nil)
    expect(session, "closed", "")
end
local function finish(session)
    close_note(session)
    drain(ticks)
    drain(scheduled)
    expect_closed(session)
    assert(plugin.channel == nil and next(sources) == nil)
end

local first = open_note()
ready(first)
load_note(first)
submit(first, "human save λ")
drain(ticks)
expect(first, "status", "pending")
command(first, "commit-ok", "human save λ")
drain(ticks)
expect(first, "status", "saved")
command(first, "present", "human save λ")
drain(ticks)
expect(first, "applied", "human save λ")
finish(first)

local second = open_note()
ready(second)
load_note(second, "human save λ")
assert(second.dialog:getInputText() == "human save λ")
finish(second)
print("PASS: device plugin mocked-widget submit/save/close/reopen callbacks")

-- Retain callbacks from each phase, then reopen BEFORE the old close timer or
-- those callbacks drain. A new in-flight save deliberately uses the old text:
-- content equality and the wire's constant generation cannot prove ownership.
for _, phase in ipairs({ "ready", "load", "status", "paint" }) do
    local old = open_note()
    if phase ~= "ready" then
        ready(old)
        if phase == "load" then
            command(old, "load-value", "old load")
        else
            load_note(old, "old load")
            submit(old, "same submitted text")
            if phase == "paint" then
                drain(ticks)
                expect(old, "status", "pending")
                command(old, "commit-ok", "same submitted text")
                drain(ticks)
                expect(old, "status", "saved")
                command(old, "present", "same submitted text")
            end
        end
    end
    local stale_ticks = ticks
    ticks = {}
    assert(#stale_ticks > 0, "regression must retain real production callbacks")
    close_note(old)
    local current = open_note()
    assert(current.channel ~= old.channel and current.dialog ~= old.dialog)
    assert(sources[old.channel] and not old.channel.closed,
        "old transport must still be draining when the new editor opens")
    ready(current)
    load_note(current, "fresh load")
    submit(current, "same submitted text")
    drain(ticks)
    expect(current, "status", "pending")

    local function assert_pending()
        assert(plugin.channel == current.channel and sources[current.channel]
                and not current.channel.closed and not plugin.transport_failed,
            "stale callback killed the reopened transport")
        assert(plugin.note_dialog == current.dialog and plugin.state == "pending"
                and plugin.pending_text == "same submitted text"
                and not plugin.pending_has_newer_edit and not current.save.enabled
                and current.dialog:getInputText() == "same submitted text",
            "stale callback changed the reopened request/editor")
        expect_empty(current)
    end

    drain(stale_ticks)
    assert_pending()
    -- The old source remains registered for output flushing. Its real receive
    -- and error callbacks must be inert, including receipts matching the NEW save.
    for _, message in ipairs({
        { "load-absent", "" }, { "load-value", "stale load" },
        { "commit-ok", "same submitted text" },
        { "commit-failed", "storage-failure" },
        { "present", "same submitted text" },
    }) do
        command(old, message[1], message[2])
        drain(ticks)
        assert_pending()
    end
    old.channel.on_error("old connection failed during close")
    old.dialog.edited_callback(true)
    old.dialog.save_callback("stale submit")
    old.dialog.close_callback()
    drain(ticks)
    assert_pending()

    drain(scheduled)
    expect_closed(old)
    assert_pending()
    -- Even already-retained callbacks delivered after retirement stay inert.
    old.channel.receive{ generation = 1, kind = "commit-ok", value = "same submitted text" }
    old.channel.on_error("late old error")
    assert_pending()

    -- A legitimate receipt still leaves a newer local edit dirty, including an
    -- edit reverted to the submitted bytes while the save was in flight.
    edit(current, "newer draft")
    local draft = "newer draft"
    if phase == "status" then
        draft = "same submitted text"
        edit(current, draft)
    end
    assert(plugin.pending_has_newer_edit)
    command(current, "commit-ok", "same submitted text")
    drain(ticks)
    expect(current, "status", "dirty")
    assert(plugin.pending_text == nil and current.save.enabled)
    assert(current.dialog:getInputText() == draft)
    -- Once the new editor can save again, the old widget's callback must not
    -- submit its content on that editor's behalf.
    local stale_ok, stale_message = old.dialog.save_callback("stale submit")
    assert(stale_ok == false and stale_message == false)
    drain(ticks)
    assert(plugin.state == "dirty" and plugin.pending_text == nil and current.save.enabled
            and current.dialog:getInputText() == draft)
    expect_empty(current)
    submit(current, "final draft λ")
    drain(ticks)
    expect(current, "status", "pending")
    command(current, "commit-ok", "final draft λ")
    drain(ticks)
    expect(current, "status", "saved")
    assert(not current.save.enabled and plugin.pending_text == nil)
    command(current, "present", "final draft λ")
    drain(ticks)
    expect(current, "applied", "final draft λ")
    finish(current)
    print("PASS: immediate reopen isolates stale " .. phase
        .. "/receive/error/widget callbacks and preserves the new save")
end

-- Reader teardown also invalidates deferred work, without requiring a dialog's
-- generated Close button to have run first.
local shutdown = open_note()
plugin:onCloseWidget()
drain(ticks)
drain(scheduled)
expect_closed(shutdown)
assert(not shown[shutdown.dialog] and plugin.channel == nil and next(sources) == nil)
print("PASS: reader teardown cancels pending note work")
