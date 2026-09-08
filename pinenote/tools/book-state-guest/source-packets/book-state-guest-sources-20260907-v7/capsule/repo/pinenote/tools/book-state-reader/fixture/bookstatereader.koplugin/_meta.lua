local _ = require("gettext")

return {
    name = "bookstatereader",
    fullname = _("Persistent note integration fixture"),
    description = _([[Trusted fixture only: an editable note whose state is
owned by a connected Guile authority. It installs no shipping plugin.]]),
}
