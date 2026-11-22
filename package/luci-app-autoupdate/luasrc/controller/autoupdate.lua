module("luci.controller.autoupdate", package.seeall)

local fs = require "nixio.fs"

function index()
	if not fs.access("/etc/config/autoupdate") then
		return
	end

	entry({"admin", "system", "autoupdate"},
		cbi("autoupdate/autoupdate"),
		_("固件更新"), 60).dependent = true
end
