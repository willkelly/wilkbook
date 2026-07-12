local _ = require("gettext")
return {
    name = "idlewasher",
    fullname = _("Idle washer"),
    description = _([[Userspace e-ink refresh manager for the PineNote: bundles full washes onto page-turn debt, fires them on reading pauses, and runs a GC16 deep clean after long idle. Replaces the driver's disabled auto-refresh and KOReader's fixed promotion cadence.]]),
}
