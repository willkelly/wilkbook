-- Independent call-count observer for the public UIManager source and
-- ReaderHighlight action seams. It records only sources/keys explicitly handed
-- to observe(), so unrelated KOReader plugins cannot satisfy the assertions.

local PublicSeamProbe = {}
PublicSeamProbe.__index = PublicSeamProbe

function PublicSeamProbe:install(manager, highlight)
    local probe = setmetatable({
        manager = manager,
        highlight = highlight,
        original_insert = manager.insertZMQ,
        original_remove = manager.removeZMQ,
        original_highlight_add = highlight.addToHighlightDialog,
        original_highlight_remove = highlight.removeFromHighlightDialog,
        observed_sources = setmetatable({}, { __mode = "k" }),
        observed_actions = {},
        installed = true,
    }, self)

    probe.insert_wrapper = function(ui, source)
        local counts = probe.observed_sources[source]
        if counts then counts.insert = counts.insert + 1 end
        return probe.original_insert(ui, source)
    end
    manager.insertZMQ = probe.insert_wrapper
    probe.remove_wrapper = function(ui, source)
        local counts = probe.observed_sources[source]
        if counts then counts.remove = counts.remove + 1 end
        return probe.original_remove(ui, source)
    end
    manager.removeZMQ = probe.remove_wrapper
    probe.highlight_add_wrapper = function(reader_highlight, key, factory)
        local counts = probe.observed_actions[key]
        if counts then counts.add = counts.add + 1 end
        return probe.original_highlight_add(reader_highlight, key, factory)
    end
    highlight.addToHighlightDialog = probe.highlight_add_wrapper
    probe.highlight_remove_wrapper = function(reader_highlight, key)
        local counts = probe.observed_actions[key]
        if counts then counts.remove = counts.remove + 1 end
        return probe.original_highlight_remove(reader_highlight, key)
    end
    highlight.removeFromHighlightDialog = probe.highlight_remove_wrapper
    return probe
end

function PublicSeamProbe:observe(source)
    assert(self.installed, "public seam observer is not installed")
    local counts = { insert = 0, remove = 0 }
    self.observed_sources[source] = counts
    return counts
end

function PublicSeamProbe:counts(source)
    return self.observed_sources[source]
end

function PublicSeamProbe:observeAction(key)
    assert(self.installed, "public seam observer is not installed")
    assert(self.observed_actions[key] == nil, "action key already observed")
    local counts = { add = 0, remove = 0 }
    self.observed_actions[key] = counts
    return counts
end

function PublicSeamProbe:actionCounts(key)
    return self.observed_actions[key]
end

function PublicSeamProbe:restore()
    if not self.installed then return false end
    self.manager.insertZMQ = self.original_insert
    self.manager.removeZMQ = self.original_remove
    self.highlight.addToHighlightDialog = self.original_highlight_add
    self.highlight.removeFromHighlightDialog = self.original_highlight_remove
    self.installed = false
    return true
end

return PublicSeamProbe
