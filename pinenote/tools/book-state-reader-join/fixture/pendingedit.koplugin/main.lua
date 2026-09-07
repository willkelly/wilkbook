-- Join-only finite operator automation.  This does not replace, patch, or gain
-- a reference to the accepted persistent-note controller; it edits the actual
-- topmost InputDialog once, exactly as an operator can while Save is disabled.
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local PendingEdit = WidgetContainer:extend{
    name = "pendingedit",
    is_doc_only = true,
}

local NEW_DRAFT = "Nouveau brouillon — 東京"

function PendingEdit:_look(attempt)
    if self.stopped or self.edited or self.armed then return end
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.title_bar
            and top.title_bar.title == "Persistent note — Saving…"
            and type(top.setInputText) == "function" then
        -- Let the accepted pending-state paint acknowledgement finish first;
        -- then perform the ordinary edit while the receipt remains withheld.
        self.armed = true
        UIManager:scheduleIn(0.15, function()
            if self.stopped or self.edited then return end
            local current = UIManager:getTopmostVisibleWidget()
            if current ~= top or not current.title_bar
                    or current.title_bar.title ~= "Persistent note — Saving…" then
                print("BOOK_STATE_READER_JOIN_PENDING_EDIT: FAIL:pending dialog changed")
                return
            end
            current:setInputText(NEW_DRAFT, true)
            self.edited = true
            print("BOOK_STATE_READER_JOIN_PENDING_EDIT: actual-widget-edited:text-bytes="
                .. #NEW_DRAFT)
        end)
        return
    end
    if attempt >= 200 then
        print("BOOK_STATE_READER_JOIN_PENDING_EDIT: FAIL:pending dialog not found")
        return
    end
    UIManager:scheduleIn(0.01, function() self:_look(attempt + 1) end)
end

function PendingEdit:onReaderReady()
    UIManager:scheduleIn(0.01, function() self:_look(1) end)
end

function PendingEdit:onCloseDocument()
    self.stopped = true
end

return PendingEdit
