local _ = require("gettext")

return {
    name = "bookinteractionprobe",
    fullname = _("Book interaction integration fixture"),
    description = _([[Trusted native fixture only: joins an InputDialog to the
host's private test channel. It is not a sandbox or production bridge.]]),
}
