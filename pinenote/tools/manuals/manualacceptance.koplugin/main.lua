-- Runs inside the actual native ReaderUI; no document/UI substitutes.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Probe = WidgetContainer:extend{ name = "manualacceptance", is_doc_only = true }
local mode = assert(os.getenv("MANUALS_MODE"))
local out = assert(os.getenv("MANUALS_OUT"))

local function pass(message)
    print("MANUALS: PASS: " .. message)
end

function Probe:shot(name)
    UIManager:setDirty(self.ui, "full")
    UIManager:forceRePaint()
    local screen = Device.screen
    -- Check the painted framebuffer, not just whether a PNG was created.
    local dark, light = 0, 0
    for y = 50, screen:getHeight() - 50, 4 do
        for x = 40, screen:getWidth() - 40, 4 do
            local gray = screen.bb:getPixel(x, y):getColor8().a
            if gray < 100 then dark = dark + 1 end
            if gray > 220 then light = light + 1 end
        end
    end
    assert(dark > 100 and light > dark, "blank or mostly dark reader paint: " .. name)
    screen:shot(out .. "/" .. name .. ".png")
    pass(name .. " painted, dark-samples=" .. dark)
end

function Probe:pageText()
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local text = doc:getTextFromXPointers(doc:getPageXPointer(page), doc:getPageXPointer(page + 1))
    return type(text) == "table" and text.text or text
end

function Probe:contains(text)
    local actual = assert(self:pageText(), "no rendered page text")
    assert(actual:find(text, 1, true), "rendered page missing: " .. text .. "\n" .. actual)
    pass("visible text: " .. text)
end

function Probe:toc(title, shot)
    self.ui.toc:onShowToc()
    local item
    for _, candidate in ipairs(self.ui.toc.toc) do
        if candidate.title == title then item = candidate; break end
    end
    assert(item, "missing reader TOC entry: " .. title)
    self.ui.toc:expandParentNode(item.index)
    self.ui.toc.toc_menu:switchItemTable(nil, self.ui.toc.collapsed_toc)
    if shot then self:shot(shot) end
    -- The real TOC Menu's selection callback pushes history and dispatches
    -- GotoXPointer. Do not bypass it with a direct crengine goto.
    self.ui.toc.toc_menu:onMenuSelect(item)
    assert(self.ui.document:getCurrentPage() == item.page, "TOC landed on wrong page")
    pass("TOC selection: " .. title)
end

function Probe:followAndBack(expected, target)
    local doc = self.ui.document
    local links = doc:getPageLinks(true)
    assert(links and #links > 0, "rendered page has no internal links")
    local before = doc:getCurrentPage()
    local chosen
    for _, link in ipairs(links) do
        if link.section and link.section ~= ""
                and (not target or link.section:find(target, 1, true)) then
            chosen = link; break
        end
    end
    assert(chosen, "no internal link target")
    local y, x = doc:getScreenPositionFromXPointer(chosen.a_xpointer)
    local hit = self.ui.link:getLinkFromGes({pos = {x = x + 1, y = y + 1}})
    assert(hit and hit.xpointer == chosen.section, "link hit-test missed its target")
    self.ui.link:showLinkBox(hit, false)
    assert(doc:getCurrentPage() ~= before, "link did not leave source page")
    if expected then self:contains(expected) end
    pass("hit-tested internal link target page=" .. doc:getCurrentPage())
    self.ui.link:onGoBackLink()
    assert(doc:getCurrentPage() == before, "Back did not restore source page")
    pass("Back restored page=" .. before)
end

function Probe:script()
    assert(self.ui.rolling and self.ui.document.is_open, "not a real open reflow document")
    -- Menus/welcome widgets are not part of the book under test.
    for widget in UIManager:topdown_widgets_iter() do
        if widget ~= self.ui then UIManager:close(widget) end
    end
    if mode == "man" then
        self:toc("Section 1 — User commands", "man-toc")
        self:contains("apropos(1)")
        self:shot("man-index")
        self:followAndBack("apropos")
        self:toc("apropos(1)")
        self:contains("SYNOPSIS")
        self:shot("man-page")
        local before = self.ui.document:getCurrentPage()
        self.ui:handleEvent(Event:new("GotoViewRel", 1))
        assert(self.ui.document:getCurrentPage() == before + 1, "next page did not advance")
        self.ui:handleEvent(Event:new("GotoViewRel", -1))
        assert(self.ui.document:getCurrentPage() == before, "previous page did not restore")
        pass("man next/previous page")
    elseif mode == "info" then
        self:toc("1 Introduction", "info-toc")
        self:contains("stream editor")
        self:shot("info-prose")
        self:toc("2.1 Overview")
        self:contains("sed SCRIPT INPUTFILE")
        self:contains("s/hello/world/g")
        self:shot("info-example")
        self:toc("2.2 Command-Line Options")
        self:contains("--version")
        self:contains("copyright notice")
        self:shot("info-table")
        self:toc("2 Running sed")
        self:followAndBack("--version", "n-command-line-options")
    else
        error("unknown mode " .. mode)
    end
end

function Probe:onReaderReady()
    UIManager:scheduleIn(0.2, function()
        local ok, err = xpcall(function() self:script() end, debug.traceback)
        if ok then print("MANUALS: result:ok:" .. mode)
        else print("MANUALS: FAIL: " .. err) end
        self.ui:onClose()
        UIManager:quit(ok and 0 or 1)
    end)
end

return Probe
