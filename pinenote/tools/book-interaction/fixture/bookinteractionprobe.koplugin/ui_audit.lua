-- Independent SDL/offscreen fixture observations for the exact dialog, source,
-- callback, and donated descriptor. This is test instrumentation, not reader
-- behavior or a physical-display oracle.
local ffi = require("ffi")

ffi.cdef[[
int fcntl(int fd, int command, ...);
]]

local C = ffi.C
local F_GETFD = 1
local EBADF = 9

local UIAudit = {}
UIAudit.__index = UIAudit

function UIAudit:new(manager)
    local audit = setmetatable({
        manager = manager,
        dialog = nil,
        channel = nil,
        callback_count = 0,
        insert_count = 0,
        remove_count = 0,
        paint_observations = {},
        armed_paint_text = nil,
        armed_paint_observed = false,
        original_insert = manager.insertZMQ,
        original_remove = manager.removeZMQ,
        highlight = nil,
        action_key = nil,
        action_factory = nil,
        action_add_count = 0,
        action_remove_count = 0,
        original_highlight_add = nil,
        original_highlight_remove = nil,
        restored = false,
    }, self)

    manager.insertZMQ = function(owner, source)
        if source == audit.channel then
            audit.insert_count = audit.insert_count + 1
        end
        return audit.original_insert(owner, source)
    end
    manager.removeZMQ = function(owner, source)
        if source == audit.channel then
            audit.remove_count = audit.remove_count + 1
        end
        return audit.original_remove(owner, source)
    end
    return audit
end

function UIAudit:retainAction(highlight, key, factory)
    assert(not self.highlight, "UI audit already has a selection action")
    assert(type(key) == "string" and type(factory) == "function",
        "selection action audit requires a key and factory")
    self.highlight = highlight
    self.action_key = key
    self.action_factory = factory
    self.original_highlight_add = highlight.addToHighlightDialog
    self.original_highlight_remove = highlight.removeFromHighlightDialog
    local audit = self
    highlight.addToHighlightDialog = function(owner, observed_key,
            observed_factory)
        if owner == audit.highlight and observed_key == audit.action_key then
            audit.action_add_count = audit.action_add_count + 1
        end
        return audit.original_highlight_add(
            owner, observed_key, observed_factory)
    end
    highlight.removeFromHighlightDialog = function(owner, observed_key)
        if owner == audit.highlight and observed_key == audit.action_key then
            audit.action_remove_count = audit.action_remove_count + 1
        end
        return audit.original_highlight_remove(owner, observed_key)
    end
end

function UIAudit:actionCounts()
    return self.action_add_count, self.action_remove_count
end

function UIAudit:retainDialog(dialog)
    assert(not self.dialog, "UI audit already has a dialog")
    self.dialog = dialog
    self.original_paint = dialog.paintTo
    local audit = self
    dialog.paintTo = function(widget, ...)
        audit.original_paint(widget, ...)
        local observed_text = widget:getInputText()
        local observed_topmost =
            audit.manager:getTopmostVisibleWidget() == widget
        audit.paint_observations[#audit.paint_observations + 1] = {
            text = observed_text,
            topmost = observed_topmost,
        }
        if not audit.armed_paint_observed
                and observed_topmost
                and observed_text == audit.armed_paint_text then
            audit.armed_paint_observed = true
            print("BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:"
                .. observed_text)
        end
    end
end

function UIAudit:armPaint(text)
    self.armed_paint_text = text
    self.armed_paint_observed = false
end

function UIAudit:retainChannel(channel)
    assert(not self.channel, "UI audit already has a private channel")
    self.channel = channel
    local receive = channel.receive
    local audit = self
    channel.receive = function(message)
        audit.callback_count = audit.callback_count + 1
        return receive(message)
    end
end

function UIAudit:topmostPaintCount(text)
    local count = 0
    for _, observation in ipairs(self.paint_observations) do
        if observation.topmost and observation.text == text then
            count = count + 1
        end
    end
    return count
end

function UIAudit:_sourceRegistered()
    for _, source in ipairs(self.manager._zeromqs) do
        if source == self.channel then return true end
    end
    return false
end

function UIAudit:restore()
    if self.restored then return end
    self.restored = true
    self.manager.insertZMQ = self.original_insert
    self.manager.removeZMQ = self.original_remove
    if self.highlight then
        self.highlight.addToHighlightDialog = self.original_highlight_add
        self.highlight.removeFromHighlightDialog = self.original_highlight_remove
    end
    if self.dialog and self.original_paint then
        self.dialog.paintTo = self.original_paint
    end
end

function UIAudit:verifyCleanup()
    local failures = {}
    local function require_state(condition, message)
        if not condition then failures[#failures + 1] = message end
    end

    require_state(self.dialog ~= nil, "exact InputDialog reference was lost")
    require_state(self.channel ~= nil, "exact private channel reference was lost")
    if self.dialog then
        require_state(not self.manager:isWidgetShown(self.dialog),
            "exact InputDialog is still shown before quit")
    end
    if self.channel then
        require_state(not self:_sourceRegistered(),
            "exact private source remains registered before quit")
        require_state(self.insert_count == 1,
            "public insertZMQ count for exact source is not one")
        require_state(self.remove_count == 1,
            "public removeZMQ count for exact source is not one")
        require_state(self.channel.closed == true,
            "private channel closed flag is false before quit")

        ffi.errno(0)
        local descriptor_result = C.fcntl(self.channel.fd, F_GETFD)
        local descriptor_errno = ffi.errno()
        require_state(descriptor_result == -1 and descriptor_errno == EBADF,
            "private channel FD is not EBADF before quit")

        local callbacks_before = self.callback_count
        self.channel:waitEvent()
        require_state(self.callback_count == callbacks_before,
            "stale post-cleanup poll invoked a private callback")
    end
    if self.highlight then
        require_state(self.action_factory ~= nil,
            "exact selection action factory was lost")
        require_state(
            self.highlight._highlight_buttons[self.action_key] == nil,
            "selection action remains registered before quit")
        require_state(self.action_add_count == 1,
            "public selection action add count is not one")
        require_state(self.action_remove_count == 1,
            "public selection action remove count is not one")
    end

    self:restore()
    if #failures > 0 then return false, table.concat(failures, "; ") end
    print("BOOK_INTERACTION_UI_AUDIT: "
        .. "cleanup:dialog-source-counts-closed-fd-no-callback:ok")
    if self.highlight then
        print("BOOK_INTERACTION_UI_AUDIT: "
            .. "cleanup:selection-action-counts-registry:ok")
    end
    return true
end

return UIAudit
