-- luci-app-autoupdate 配置与状态页面
--
-- 说明：本页只做「检测 + 下载」，不自动刷写。
-- 下载完成后给出 sysupgrade 命令和文件路径，由用户自己决定何时升级。

require("luci.sys")
require("luci.http")
require("luci.dispatcher")

local fs = require "nixio.fs"

local STATUS  = "/tmp/autoupdate_status"
local VERFILE = "/etc/fwupdate.version"

local function read_kv(path)
	local t = {}
	local f = io.open(path, "r")
	if not f then
		return t
	end
	for line in f:lines() do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then
			t[k] = v
		end
	end
	f:close()
	return t
end

local function fmt_size(bytes)
	local n = tonumber(bytes)
	if not n or n <= 0 then
		return "—"
	end
	return string.format("%.1f MB", n / 1048576)
end

local function esc(s)
	-- 仅用于可能来自外部的字段，避免破坏页面结构
	if not s then return "" end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local m = Map("autoupdate", translate("固件更新"),
	translate("从你自己的 GitHub 仓库检查是否有新固件。本页只负责检测与下载，实际刷写请在「系统 → 备份/升级」中上传固件完成，升级时机由你决定。"))

local s = m:section(TypedSection, "login", translate("更新设置"))
s.addremove = false
s.anonymous = true

local github = s:option(Value, "github", translate("GitHub 仓库"),
	translate("填 owner/repo，也可以填完整仓库地址"))
github.placeholder = "klxyymail/immortalwrt-cmcc_rax3000m-emmc-237"
github.rmempty = false

local proxy = s:option(Value, "github_proxy", translate("GitHub 代理"),
	translate("选填。直连 GitHub 失败时填代理前缀，会拼在下载地址前面，例如 https://ghfast.top/ （注意结尾斜杠）"))
proxy.placeholder = "https://ghfast.top/"

local api = s:option(Value, "api_base", translate("API 地址"),
	translate("选填。默认 https://api.github.com，仅在需要自建反代时修改"))
api.placeholder = "https://api.github.com"

local dev = s:option(Value, "device_model", translate("设备标识"),
	translate("留 auto 自动识别。命中的是 Release 资产名里的设备段，例如 cmcc_xr30-emmc"))
dev.placeholder = "auto"

local suffix = s:option(Value, "firmware_suffix", translate("固件后缀"),
	translate("用于在 Release 资产里筛选本机固件"))
suffix.placeholder = "-squashfs-sysupgrade.bin"

local wf = s:option(Value, "workflow", translate("构建工作流"),
	translate("用于查询最新成功构建编号，一般不用改"))
wf.placeholder = "build-openwrt.yml"

s = m:section(TypedSection, "login", translate("定时检查"))
s.addremove = false
s.anonymous = true

local en = s:option(Flag, "enable", translate("启用定时检查"),
	translate("到点自动检查一次，只检查不升级；结果记在上面的状态里"))
en.rmempty = false

local week = s:option(ListValue, "week", translate("星期"))
week:value("7", translate("每天"))
week:value("1", translate("周一"))
week:value("2", translate("周二"))
week:value("3", translate("周三"))
week:value("4", translate("周四"))
week:value("5", translate("周五"))
week:value("6", translate("周六"))
week:value("0", translate("周日"))

local hour = s:option(Value, "hour", translate("小时"))
hour.datatype = "range(0,23)"
hour.default = "3"

local minute = s:option(Value, "minute", translate("分钟"))
minute.datatype = "range(0,59)"
minute.default = "0"

-- ---------------------------------------------------------------- 状态区

s = m:section(TypedSection, "login", translate("更新状态"))
s.addremove = false
s.anonymous = true

local st = s:option(DummyValue, "_status", translate("当前"))
st.rawhtml = true

function st.cfgvalue(self, section)
	local d = read_kv(STATUS)
	local v = read_kv(VERFILE)
	local out = {}

	local cur = translate("未知（旧固件，无版本标识）")
	if v.BUILD_STAMP and v.BUILD_STAMP ~= "" then
		cur = v.BUILD_STAMP
		if v.BUILD_RUN and v.BUILD_RUN ~= "" then
			cur = cur .. translate("（构建 #") .. v.BUILD_RUN .. translate("）")
		end
	end
	table.insert(out, translate("当前固件") .. "：<strong>" .. esc(cur) .. "</strong>")

	local res  = d.RESULT or "idle"
	local msg  = d.MESSAGE or translate("尚未检查")
	local col  = "#666"
	if res == "update" or res == "error" then
		col = "#c00"
	elseif res == "none" then
		col = "#080"
	elseif res == "downloading" or res == "ready" then
		col = "#c60"
	end

	table.insert(out, "<br />" .. translate("状态") ..
		"：<strong style=\"color:" .. col .. "\">" .. esc(msg) .. "</strong>")

	if res == "update" or res == "downloading" or res == "ready" then
		if d.REMOTE_RUN and d.REMOTE_RUN ~= "" then
			table.insert(out, "<br />" .. translate("最新构建") .. "：#" .. esc(d.REMOTE_RUN))
		end
		if d.TAG and d.TAG ~= "" then
			table.insert(out, "<br />" .. translate("版本标签") .. "：" .. esc(d.TAG))
		end
		if d.ASSET and d.ASSET ~= "" then
			table.insert(out, "<br />" .. translate("固件文件") .. "：" .. esc(d.ASSET))
		end
		if d.SIZE and d.SIZE ~= "" then
			table.insert(out, "<br />" .. translate("文件大小") .. "：" .. fmt_size(d.SIZE))
		end
	end

	if res == "downloading" then
		table.insert(out, "<br />" .. translate("已下载") .. "：" .. fmt_size(d.DOWNLOADED))
		table.insert(out, "<br /><span style=\"color:#666\">" ..
			translate("页面每 4 秒自动刷新，下载期间请不要关闭。") .. "</span>")
		table.insert(out, "<script type=\"text/javascript\">" ..
			"setTimeout(function(){ window.location.reload(); }, 4000);" ..
			"</script>")
	end

	if res == "ready" then
		local integrity = translate("未校验")
		if d.SHA_OK == "1" then
			integrity = translate("sha256 校验通过")
		elseif d.SHA_OK == "0" then
			integrity = translate("sha256 校验失败")
		elseif d.SHA_OK == "skip" then
			integrity = translate("未取得校验值，已跳过")
		end
		local fp = d.FILE or ""
		table.insert(out, "<br />" .. translate("完整性") .. "：" .. integrity)
		table.insert(out, "<br />" .. translate("文件位置") .. "：<code>" .. esc(fp) .. "</code>")
		table.insert(out,
			"<div style=\"margin-top:10px;padding:10px;background:#f7f7f7;border-left:3px solid #09c\">" ..
			translate("刷写方式（保留配置）：登录 SSH 执行") ..
			"<br /><code>sysupgrade -k " .. esc(fp) .. "</code>" ..
			"<br /><br />" ..
			translate("或者把该文件下载到电脑，在「系统 → 备份/升级」中上传刷写。") ..
			"<br /><span style=\"color:#c00\">" ..
			translate("注意：/tmp 是内存盘，重启后文件会消失，请尽快刷写。") ..
			"</span></div>")
	end

	if res == "error" then
		table.insert(out, "<br /><span style=\"color:#c00\">" ..
			translate("详细日志：") .. " <code>/tmp/autoupdate.log</code></span>")
	end

	return table.concat(out, "")
end

-- ---------------------------------------------------------------- 按钮

local bc = s:option(Button, "_check", translate("检查更新"))
bc.inputtitle = translate("立即检查")
bc.inputstyle = "apply"
function bc.write(self, section)
	-- 同步执行：只发两个 API 请求，超时控制在 15 秒/次
	luci.sys.call("/usr/bin/AutoUpdate check >/dev/null 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin/system/autoupdate"))
end

local bd = s:option(Button, "_fetch", translate("下载固件"))
bd.inputtitle = translate("下载到路由器")
bd.inputstyle = "apply"
function bd.write(self, section)
	-- 后台执行：固件几十 MB，不能阻塞表单提交
	luci.sys.call("( /usr/bin/AutoUpdate fetch >/dev/null 2>&1 </dev/null & )")
	luci.http.redirect(luci.dispatcher.build_url("admin/system/autoupdate"))
end

-- 保存配置后重建 crontab（定时检查开关/时间可能变了）
m.on_after_commit = function(self)
	luci.sys.call("/etc/init.d/autoupdate restart >/dev/null 2>&1")
end

return m
