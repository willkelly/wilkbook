-- Test-copy override only. The runner installs this in a private copy of the
-- production plugin; the canonical activation validator is never modified.
return { enabled = function() return true end }
