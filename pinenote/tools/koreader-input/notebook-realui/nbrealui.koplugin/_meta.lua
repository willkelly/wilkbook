local _ = require("gettext")

return {
    name = "nbrealui",
    fullname = _("Notebook real-UI controller (host fixture)"),
    description = _([[Host-only controller for the notebook plugin's native KOReader test: emulates the PineNote input hook chain on the SDL emulator, injects pen and touch, and captures screenshots.]]),
}
