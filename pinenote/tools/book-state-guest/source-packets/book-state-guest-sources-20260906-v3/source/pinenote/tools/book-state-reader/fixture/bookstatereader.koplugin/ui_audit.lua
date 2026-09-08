-- Independent offscreen observations for the exact inherited InputDialog
-- paints and lifecycle resources used by this fixture.
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
        channel = nil,
        dialogs = {},
        callback_count = 0,
        insert_count = 0,
        remove_count = 0,
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
    assert(not self.highlight, "UI audit already has an action")
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
        return audit.original_highlight_add(owner, observed_key, observed_factory)
    end
    highlight.removeFromHighlightDialog = function(owner, observed_key)
        if owner == audit.highlight and observed_key == audit.action_key then
            audit.action_remove_count = audit.action_remove_count + 1
        end
        return audit.original_highlight_remove(owner, observed_key)
    end
end

function UIAudit:retainChannel(channel)
    assert(not self.channel, "UI audit already has a channel")
    self.channel = channel
    local receive = channel.receive
    local audit = self
    channel.receive = function(message)
        audit.callback_count = audit.callback_count + 1
        return receive(message)
    end
end

function UIAudit:retainDialog(dialog, generation)
    assert(type(generation) == "number", "dialog generation required")
    local record = {
        dialog = dialog,
        generation = generation,
        original_paint = dialog.paintTo,
        observations = {},
        state_arm = nil,
        presentation_arm = nil,
    }
    self.dialogs[#self.dialogs + 1] = record
    local audit = self
    dialog.paintTo = function(widget, ...)
        record.original_paint(widget, ...)
        local observation = {
            title = widget.title_bar.title,
            text = widget:getInputText(),
            topmost = audit.manager:getTopmostVisibleWidget() == widget,
        }
        record.observations[#record.observations + 1] = observation
        local state_arm = record.state_arm
        if state_arm and not state_arm.seen and observation.topmost
                and observation.title == state_arm.title
                and observation.text == state_arm.text then
            state_arm.seen = true
            print(string.format(
                "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=%d:state=%s:text-bytes=%d",
                generation, state_arm.state, #state_arm.text))
        end
        local presentation_arm = record.presentation_arm
        if presentation_arm and not presentation_arm.seen
                and observation.topmost
                and observation.title == presentation_arm.title
                and observation.text == presentation_arm.text then
            presentation_arm.seen = true
            print(string.format(
                "BOOK_STATE_READER_UI_AUDIT: paintTo-presentation:generation=%d:text-bytes=%d",
                generation, #presentation_arm.text))
        end
    end
    return record
end

function UIAudit:armState(record, state, title, text)
    record.state_arm = {
        state = state,
        title = title,
        text = text,
        seen = false,
    }
    return record.state_arm
end

function UIAudit:armPresentation(record, title, text)
    record.presentation_arm = {
        title = title,
        text = text,
        seen = false,
    }
    return record.presentation_arm
end

function UIAudit:restore()
    if self.restored then return false end
    self.restored = true
    self.manager.insertZMQ = self.original_insert
    self.manager.removeZMQ = self.original_remove
    if self.highlight then
        self.highlight.addToHighlightDialog = self.original_highlight_add
        self.highlight.removeFromHighlightDialog = self.original_highlight_remove
    end
    for _, record in ipairs(self.dialogs) do
        record.dialog.paintTo = record.original_paint
    end
    return true
end

function UIAudit:_sourceRegistered()
    for _, source in ipairs(self.manager._zeromqs) do
        if source == self.channel then return true end
    end
    return false
end

function UIAudit:verifyCleanup()
    local failures = {}
    local function require_state(condition, message)
        if not condition then failures[#failures + 1] = message end
    end

    require_state(#self.dialogs >= 1, "no exact InputDialog was retained")
    for _, record in ipairs(self.dialogs) do
        require_state(not self.manager:isWidgetShown(record.dialog),
            "generation " .. record.generation .. " InputDialog remains shown")
        require_state(record.state_arm == nil or record.state_arm.seen,
            "generation " .. record.generation .. " final state paint was not observed")
        require_state(record.presentation_arm == nil
                or record.presentation_arm.seen,
            "generation " .. record.generation
                .. " final presentation paint was not observed")
    end

    require_state(self.channel ~= nil, "exact private channel was lost")
    if self.channel then
        require_state(not self:_sourceRegistered(),
            "exact private source remains registered")
        require_state(self.insert_count == 1,
            "exact source insert count is not one")
        require_state(self.remove_count == 1,
            "exact source remove count is not one")
        require_state(self.channel.closed == true,
            "private channel closed flag is false")
        ffi.errno(0)
        local descriptor_result = C.fcntl(self.channel.fd, F_GETFD)
        local descriptor_errno = ffi.errno()
        require_state(descriptor_result == -1 and descriptor_errno == EBADF,
            "private channel FD is not EBADF")
        local callbacks_before = self.callback_count
        self.channel:waitEvent()
        require_state(self.callback_count == callbacks_before,
            "stale post-cleanup poll invoked a callback")
    end

    require_state(self.highlight ~= nil, "exact selection action was lost")
    if self.highlight then
        require_state(self.highlight._highlight_buttons[self.action_key] == nil,
            "selection action remains registered")
        require_state(self.action_add_count == 1,
            "selection action add count is not one")
        require_state(self.action_remove_count == 1,
            "selection action remove count is not one")
    end

    self:restore()
    if #failures > 0 then return false, table.concat(failures, "; ") end
    print("BOOK_STATE_READER_UI_AUDIT: cleanup:dialogs-source-fd-action-callback:clean")
    return true
end

return UIAudit
