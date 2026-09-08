local _ = require("gettext")

return {
    name = "bookreaderprobe",
    fullname = _("Book reader integration probe (fixture)"),
    description = _([[Offline fixture only: exercises KOReader's reader, dialog, and asynchronous-source seams. It is not a broker or security boundary.]]),
}
