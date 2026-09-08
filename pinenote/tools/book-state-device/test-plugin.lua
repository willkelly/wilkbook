-- Host-only callback test for the device adapter. It invokes the production
-- InputDialog callbacks; there are no production edit/save test commands.
local ffi = require("ffi")
ffi.cdef[[
int socketpair(int domain, int type, int protocol, int descriptors[2]);
long read(int fd, void *buffer, unsigned long count);
long write(int fd, const void *buffer, unsigned long count);
int close(int fd);
]]
local C = ffi.C
local plugin_dir = assert(arg[1], "plugin directory required")
package.path = plugin_dir .. "/?.lua;" .. package.path

local plugin_fds, peer_fds = {}, {}
for index = 1, 2 do
    local fds = ffi.new("int[2]")
    assert(C.socketpair(1, 1, 0, fds) == 0)
    plugin_fds[index], peer_fds[index] = tonumber(fds[0]), tonumber(fds[1])
end
local connection_index, peer_fd = 0, peer_fds[1]

local ticks, scheduled = {}, {}
local shown = {}
local UIManager
UIManager = {
    insertZMQ = function(_, source) UIManager.source = source end,
    removeZMQ = function(_, source) assert(source == UIManager.source); UIManager.source = nil end,
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

local save_button = {
    enabled = false,
    enable = function(self) self.enabled = true end,
    disable = function(self) self.enabled = false end,
}
local InputDialog = {}
function InputDialog:new(options)
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
        connection_index = connection_index + 1
        return assert(plugin_fds[connection_index], "unexpected third connection")
    end }
end

local function read_line()
    local bytes = {}
    while true do
        local byte = ffi.new("uint8_t[1]")
        assert(C.read(peer_fd, byte, 1) == 1)
        if byte[0] == 10 then return string.char(unpack(bytes)) end
        bytes[#bytes + 1] = tonumber(byte[0])
    end
end
local function write_line(value)
    assert(C.write(peer_fd, value, #value) == #value)
end
local function hex(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end
local function command(kind, value)
    write_line(string.format("%s|1|%s\n", kind, hex(value or "")))
    assert(UIManager.source)
    UIManager.source:waitEvent()
end
local function expect(kind, value)
    local wanted = string.format("%s|1|%s", kind, hex(value or ""))
    local got = read_line()
    assert(got == wanted, string.format("expected %s, got %s", wanted, got))
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
menu_items.wilkbook_book_state_note.callback()
assert(plugin.dialog == owner_dialog and plugin.note_dialog ~= owner_dialog)
expect("channel-ready", "")
drain(ticks)
expect("ready", "")

command("load-absent", "")
drain(ticks)
expect("status", "loaded-absent")
expect("applied", "")
assert(not save_button.enabled)

plugin.note_dialog:setInputText("human save λ")
plugin.note_dialog.edited_callback(true)
drain(ticks)
expect("status", "dirty")
assert(save_button.enabled)
plugin.note_dialog.save_callback(plugin.note_dialog:getInputText())
expect("submit", "human save λ")
drain(ticks)
expect("status", "pending")
assert(not save_button.enabled)

command("commit-ok", "human save λ")
drain(ticks)
expect("status", "saved")
command("present", "human save λ")
drain(ticks)
expect("applied", "human save λ")

plugin.note_dialog.close_callback()
assert(plugin.dialog == owner_dialog and plugin.note_dialog == nil)
expect("closed", "")
drain(scheduled)
assert(UIManager.source == nil)
C.close(peer_fd)

peer_fd = peer_fds[2]
menu_items.wilkbook_book_state_note.callback()
expect("channel-ready", "")
drain(ticks)
expect("ready", "")
command("load-value", "human save λ")
drain(ticks)
expect("status", "loaded-value")
expect("applied", "human save λ")
assert(plugin.note_dialog:getInputText() == "human save λ")
plugin.note_dialog.close_callback()
assert(plugin.dialog == owner_dialog and plugin.note_dialog == nil)
expect("closed", "")
drain(scheduled)
assert(UIManager.source == nil)
C.close(peer_fd)
print("PASS: device plugin mocked-widget submit/save/close/reopen callbacks")
