local _ = require("gettext")

return {
    name = "pendingedit",
    fullname = _("Pending-edit test operator"),
    description = _([[Join-only automation: performs one ordinary widget edit
while a persistent-note save is pending. It owns no protocol descriptor.]]),
}
