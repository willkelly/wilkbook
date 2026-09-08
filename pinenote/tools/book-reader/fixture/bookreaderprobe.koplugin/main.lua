-- Trusted test fixture for the pinned KOReader desktop/offscreen frontend.
--
-- This plugin is copied into a temporary KO_HOME by run-tests.sh. It is not a
-- production bridge, a wire protocol, a broker, a security boundary, or a
-- durability implementation. Its fake broker is an in-memory callback and it
-- never opens or writes a host path.

local InputDialog = require("ui/widget/inputdialog")
local InteractionSource = require("interaction_source")
local PublicSeamProbe = require("public_seam_probe")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Probe = WidgetContainer:extend{
    name = "bookreaderprobe",
    is_doc_only = true,
}

local ACTION_KEY = "wilkbook_fixture_action"
local ACCEPTED_TEXT = "accepted workspace text"
local REJECTED_TEXT = "rejected workspace text"

local function marker(text)
    print("BOOK_READER_PROBE: " .. text)
end

local FakeBroker = {}

function FakeBroker:new()
    return setmetatable({ save_calls = 0 }, { __index = self })
end

function FakeBroker:save(content)
    self.save_calls = self.save_calls + 1
    if content == ACCEPTED_TEXT then
        marker("save-callback:accepted-fixture-not-durable")
        return true, "Fixture accepted; no durable state was written"
    elseif content == REJECTED_TEXT then
        marker("save-callback:rejected-fixture")
        return false, "Fixture rejection"
    end
    error("fixture broker received unexpected content")
end

function Probe:init()
    self.failed = false
    self.fake_broker = FakeBroker:new()
    self.seam_probe = PublicSeamProbe:install(UIManager, self.ui.highlight)
    marker("plugin-init")

    local root = os.getenv("BOOK_READER_PROBE_ROOT")
    if root and os.getenv("HOME") == string.format("%s/%s", root, "home")
            and os.getenv("KO_HOME") == string.format("%s/%s", root, "ko") then
        marker("environment:scoped")
    else
        self:_fail("HOME/KO_HOME escaped the fixture root")
    end
end

function Probe:_fail(message)
    if not self.failed then
        self.failed = true
        marker("FAIL:" .. message)
        UIManager:nextTick(function()
            self:_closeInteraction("failure")
            self:_removeSelectionAction()
            self:_restoreSeamProbe()
            UIManager:quit(1)
        end)
    end
end

function Probe:_restoreSeamProbe()
    if not self.seam_probe then return false end
    local probe = self.seam_probe
    self.seam_probe = nil
    local restored = probe:restore()
    self:_check(restored and UIManager.insertZMQ == probe.original_insert
            and UIManager.removeZMQ == probe.original_remove
            and self.ui.highlight.addToHighlightDialog
                == probe.original_highlight_add
            and self.ui.highlight.removeFromHighlightDialog
                == probe.original_highlight_remove,
        "public seam observer did not restore wrapped methods")
    return restored
end

function Probe:_check(condition, message)
    if not condition then self:_fail(message) end
    return condition
end

function Probe:_sourceRegistered(source)
    for _, candidate in ipairs(UIManager._zeromqs or {}) do
        if candidate == source then return true end
    end
    return false
end

function Probe:_removeSelectionAction()
    if not self.highlight_button_factory then return false end
    local expected = self.highlight_button_factory
    self.highlight_button_factory = nil
    local removed = self.ui.highlight:removeFromHighlightDialog(ACTION_KEY)
    self:_check(removed == expected,
        "selection removal did not return the registered callback")
    self:_check(self.ui.highlight._highlight_buttons[ACTION_KEY] == nil,
        "selection action remained in ReaderHighlight registry")
    self:_check(self.highlight_seam_counts
            and self.highlight_seam_counts.add == 1
            and self.highlight_seam_counts.remove == 1,
        "selection action did not use public ReaderHighlight removal seam")
    marker("selection-action:removed")
    return true
end

function Probe:_checkClosedInteraction(source, dialog, expected_callbacks,
        expected_drops, reason)
    local counts = self.seam_probe and self.seam_probe:counts(source)
    self:_check(counts and counts.insert == 1 and counts.remove == 1,
        "public source seam counts were wrong after " .. reason)
    self:_check(not self:_sourceRegistered(source),
        "source remained registered after " .. reason)
    self:_check(source.closed and not source.in_wait and source.stop_count == 1,
        "source did not stop cleanly after " .. reason)
    self:_check(#source.queue == 0,
        "source retained queued payloads after " .. reason)
    self:_check(dialog and not UIManager:isWidgetShown(dialog),
        "interaction dialog remained in UIManager stack after " .. reason)
    self:_check(source.callback_count == expected_callbacks
            and source.dropped_count == expected_drops,
        "source callback/drop counts were wrong after " .. reason)
end

function Probe:_closeInteraction(reason)
    local source, dialog = self.source, self.interaction_dialog
    if not source and not dialog then return false end

    self.source = nil
    self.interaction_dialog = nil
    self.generation = nil

    if source then
        UIManager:removeZMQ(source)
        source:stop()
        self:_check(not self:_sourceRegistered(source),
            "source remained registered after " .. reason)
    end
    if dialog and UIManager:isWidgetShown(dialog) then
        UIManager:close(dialog)
    end
    marker("source-removed:" .. reason)
    return true, source, dialog
end

function Probe:_saveThroughDialog(label, text)
    if not self:_check(self.interaction_dialog ~= nil,
            "save without active dialog") then
        return
    end
    self.interaction_dialog:setInputText(text, true)
    if not self:_check(self.interaction_dialog:getInputText() == text,
            "InputDialog did not retain " .. label .. " edit") then
        return
    end
    marker("dialog-edited:" .. label)

    local save = self.interaction_dialog.button_table:getButtonById("save")
    if not self:_check(save and save.enabled,
            "InputDialog save button was not enabled") then
        return
    end
    -- Invoke the button KOReader generated for save_callback. This traverses
    -- InputDialog's real Trapper-wrapped accepted/rejected save path.
    save.callback()
    if label == "accepted" then
        self:_check(not save.enabled,
            "accepted InputDialog save did not disable Save")
        marker("save-branch:accepted")
    elseif label == "rejected" then
        self:_check(save.enabled,
            "rejected InputDialog save incorrectly disabled Save")
        marker("save-branch:rejected")
    else
        self:_fail("unknown save fixture label")
    end
end

function Probe:_handleMessage(source, message)
    if source ~= self.source then
        self.post_close_callback = true
        self:_fail("callback ran after interaction close")
        return
    end

    if message.generation ~= self.generation then
        self.stale_count = (self.stale_count or 0) + 1
        self:_check(self.interaction_dialog:getInputText()
                == "fixture initial text",
            "stale message changed dialog content")
        marker("stale-generation:rejected=" .. tostring(message.generation))
        return
    end

    if message.kind == "edit-and-save" then
        self:_saveThroughDialog(message.label, message.text)
    elseif message.kind == "close" then
        marker("close-message:generation=" .. tostring(message.generation))
        local closed, closed_source, closed_dialog =
            self:_closeInteraction("close")
        self:_check(closed and closed_source == source,
            "normal close did not own its source")
        self:_check(not self:_closeInteraction("close-again"),
            "normal close was not idempotent")
        marker("interaction-close:idempotent")
        UIManager:scheduleIn(0.12, function()
            self:_afterNormalClose(source, closed_dialog)
        end)
    elseif message.kind == "force-error" then
        marker("forced-callback-error")
        error("fixture forced callback error")
    elseif message.kind == "must-not-run" then
        self.post_close_callback = true
        self:_fail("queued post-close callback ran")
    else
        self:_fail("unknown fixture message kind")
    end
end

function Probe:_newInteraction(generation, max_queued)
    if not self:_check(not self.source and not self.interaction_dialog,
            "interaction opened while another was active") then
        return
    end

    self.generation = generation
    self.interaction_dialog = InputDialog:new{
        title = "Book reader fixture",
        input = "fixture initial text",
        allow_newline = true,
        keyboard_visible = false,
        save_callback = function(content)
            return self.fake_broker:save(content)
        end,
    }
    UIManager:show(self.interaction_dialog)
    if not self:_check(UIManager:isWidgetShown(self.interaction_dialog),
            "InputDialog was not shown")
            or not self:_check(self.interaction_dialog:isTextEditable(),
                "InputDialog was not editable") then
        return
    end
    marker("dialog-shown:generation=" .. tostring(generation))

    local source
    source = InteractionSource:new{
        max_queued = max_queued,
        receive = function(message)
            self:_handleMessage(source, message)
        end,
        on_error = function(err)
            self:_onSourceError(source, err)
        end,
    }
    self.source = source
    local seam_counts = self.seam_probe:observe(source)
    UIManager:insertZMQ(source)
    self:_check(self:_sourceRegistered(source),
        "source was not registered during interaction")
    self:_check(seam_counts.insert == 1 and seam_counts.remove == 0,
        "source did not use public UIManager insertion seam")
    marker("source-registered:generation=" .. tostring(generation))
    return source
end

function Probe:_enqueue(source, message)
    local ok, err = source:enqueue(message)
    self:_check(ok, "fixture enqueue failed: " .. tostring(err))
end

function Probe:_openNormalInteraction()
    local source = self:_newInteraction(7, 5)
    if not source then return end
    self:_enqueue(source, {
        generation = 6,
        kind = "edit-and-save",
        label = "stale",
        text = "stale text must not appear",
    })
    self:_enqueue(source, {
        generation = 7,
        kind = "edit-and-save",
        label = "accepted",
        text = ACCEPTED_TEXT,
    })
    self:_enqueue(source, {
        generation = 7,
        kind = "edit-and-save",
        label = "rejected",
        text = REJECTED_TEXT,
    })
    self:_enqueue(source, { generation = 7, kind = "close" })
    self:_enqueue(source, { generation = 7, kind = "must-not-run" })
    local overflow_ok, overflow_err = source:enqueue({
        generation = 7,
        kind = "must-not-run",
    })
    self:_check(not overflow_ok and overflow_err == "queue-full",
        "source queue bound was not enforced")
    marker("queue-bound:enforced")
end

function Probe:_afterNormalClose(source, dialog)
    self:_checkClosedInteraction(source, dialog, 4, 1, "normal close")
    self:_check(source.last_wait_caller == "processZMQs",
        "normal source was not driven by UIManager:processZMQs")
    self:_check(not self.post_close_callback,
        "post-close callback flag was set")
    local callback_count = source.callback_count
    source:waitEvent()
    self:_check(source.callback_count == callback_count,
        "stale waitEvent invoked a callback after normal close")
    local enqueue_ok, enqueue_err = source:enqueue({ kind = "must-not-run" })
    self:_check(not enqueue_ok and enqueue_err == "closed",
        "normal source accepted work after close")
    self:_check(self.fake_broker.save_calls == 2,
        "fake broker did not receive exactly two save callbacks")
    marker("post-close:no-callback")
    self:_openErrorInteraction()
end

function Probe:_openErrorInteraction()
    local source = self:_newInteraction(8, 2)
    if not source then return end
    self:_enqueue(source, { generation = 8, kind = "force-error" })
    self:_enqueue(source, { generation = 8, kind = "must-not-run" })
end

function Probe:_onSourceError(source, err)
    self:_check(tostring(err):find("fixture forced callback error", 1, true),
        "source reported the wrong callback error")
    marker("source-error:caught")
    local closed, closed_source, closed_dialog = self:_closeInteraction("error")
    self:_check(closed and closed_source == source,
        "error close did not own its source")
    self:_check(not self:_closeInteraction("error-again"),
        "error close was not idempotent")
    marker("interaction-error-close:idempotent")
    UIManager:scheduleIn(0.12, function()
        self:_afterErrorClose(source, closed_dialog)
    end)
end

function Probe:_afterErrorClose(source, dialog)
    self:_checkClosedInteraction(source, dialog, 1, 1, "callback error")
    self:_check(source.last_wait_caller == "processZMQs",
        "error source was not driven by UIManager:processZMQs")
    self:_check(not self.post_close_callback,
        "post-error callback flag was set")
    local callback_count = source.callback_count
    source:waitEvent()
    self:_check(source.callback_count == callback_count,
        "stale waitEvent invoked a callback after callback error")
    local enqueue_ok, enqueue_err = source:enqueue({ kind = "must-not-run" })
    self:_check(not enqueue_ok and enqueue_err == "closed",
        "error source accepted work after close")
    marker("post-error:no-callback")

    self:_openDocumentCloseInteraction()
end

function Probe:_openDocumentCloseInteraction()
    local source = self:_newInteraction(9, 1)
    if not source then return end
    local dialog = self.interaction_dialog
    self:_enqueue(source, { generation = 9, kind = "must-not-run" })
    self.expected_document_close_source = source

    -- Close ReaderUI while a registered source and dialog are still active.
    -- ReaderUI must emit CloseDocument, where teardown removes both.
    self.ui:onClose(false)
    self:_check(self.close_document_seen == 1,
        "ReaderUI close did not emit exactly one CloseDocument")
    self:_check(self.ui.document == nil,
        "ReaderUI close did not clear its document")
    self:_check(self.ui.highlight._highlight_buttons[ACTION_KEY] == nil,
        "ReaderHighlight registry retained the selection action")
    self:_checkClosedInteraction(source, dialog, 0, 1,
        "active document close")
    local callback_count = source.callback_count
    source:waitEvent()
    self:_check(source.callback_count == callback_count,
        "stale waitEvent invoked a callback after document close")
    local enqueue_ok, enqueue_err = source:enqueue({ kind = "must-not-run" })
    self:_check(not enqueue_ok and enqueue_err == "closed",
        "document-closed source accepted new work")
    self:_check(not self.post_close_callback,
        "document-close callback flag was set")
    self.expected_document_close_source = nil
    marker("document-close:postconditions")
    self:_restoreSeamProbe()

    if self.failed then
        marker("result:failed")
        UIManager:quit(1)
    else
        marker("result:ok")
        UIManager:quit(0)
    end
end

function Probe:onReaderReady()
    marker("reader-ready")
    if self.failed then
        UIManager:quit(1)
        return
    end
    if not self:_check(type(self.ui.highlight.addToHighlightDialog) == "function"
            and type(self.ui.highlight.removeFromHighlightDialog) == "function",
            "ReaderHighlight selection seams are unavailable")
            or not self:_check(type(UIManager.insertZMQ) == "function"
                and type(UIManager.removeZMQ) == "function",
                "UIManager async seams are unavailable") then
        UIManager:quit(1)
        return
    end

    self.highlight_button_factory = function()
        return {
            text = "Open book reader fixture",
            callback = function()
                marker("selection-action:invoked-by-fixture")
                self:_openNormalInteraction()
            end,
        }
    end
    self.highlight_seam_counts = self.seam_probe:observeAction(ACTION_KEY)
    self.ui.highlight:addToHighlightDialog(
        ACTION_KEY, self.highlight_button_factory)
    self:_check(self.ui.highlight._highlight_buttons[ACTION_KEY]
            == self.highlight_button_factory,
        "selection action was not present in ReaderHighlight registry")
    self:_check(self.highlight_seam_counts.add == 1
            and self.highlight_seam_counts.remove == 0,
        "selection action did not use public ReaderHighlight add seam")
    marker("selection-action:registered")

    -- Automation invokes the registered button factory directly. This pins
    -- registration and the action callback, not touch selection/menu layout.
    UIManager:nextTick(function()
        local button = self.highlight_button_factory(self.ui.highlight, 1)
        if self:_check(type(button) == "table"
                and type(button.callback) == "function",
                "selection action did not produce a button") then
            button.callback()
        else
            UIManager:quit(1)
        end
    end)
end

function Probe:onCloseDocument()
    self.close_document_seen = (self.close_document_seen or 0) + 1
    if self.source or self.interaction_dialog then
        self:_check(self.source == self.expected_document_close_source,
            "unexpected interaction was active during CloseDocument")
        marker("close-document:active-interaction")
        self:_closeInteraction("document")
    else
        marker("close-document:no-interaction")
    end
    self:_removeSelectionAction()
end

return Probe
