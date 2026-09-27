-- Session-only KOReader startup patch, installed at the path below and removed
-- after opening the requested sampler. Uses the plugin's ordinary launch path.
local UI = require("ui/uimanager")
local logger = require("logger")
local id = "20260927T051718Z-d466ff"
local patch = "/root/.config/koreader/patches/2-open-handwriting-sampler.lua"
local attempts = 0
local function open()
    attempts = attempts + 1
    local plugin
    for w in UI:topdown_widgets_iter() do
        if w.notebook then plugin = w.notebook; break end
    end
    if not plugin then
        if attempts < 10 then UI:scheduleIn(1, open)
        else logger.warn("[sampler] no notebook host; open manually from Tools") end
        return
    end
    plugin:launch("id", id)
    for w in UI:topdown_widgets_iter() do
        if w.name == "notebook_window" and w.session.id == id and w.paper then
            UI:setDirty(w, "ui")
            UI:forceRePaint()
            require("device").screen:shot(
                "/data/wilkbook/diagnostic-backups/gen24-before-sampler-20260926/sampler-first-page.png")
            local ok, err = os.remove(patch)
            logger.info("[sampler] opened", id, "page", w.c.page_n,
                        "one-shot patch removed", ok, err)
            return
        end
    end
    logger.warn("[sampler] notebook launch did not open the expected paper")
end
UI:scheduleIn(2, open)
