--!strict
-- Dev Containers: native Tern hosts for dev containers.
local Resolve = require("./lib/resolve")

local counter = 0
local pending: { [number]: { ws: string, marker: string } } = {}

local function focused_cwd(cx: any): string?
	local id = cx.session:focused()
	if id == nil then
		return nil
	end
	for _, pane in cx.session:panes() do
		if pane.pane == id and pane.cwd ~= nil and pane.cwd ~= "" then
			return pane.cwd
		end
	end
	return nil
end

local function rebuild_command(ws: string, no_cache: boolean, marker: string): string
	local cmd = "devcontainer up --workspace-folder "
		.. Resolve.shell_quote(ws)
		.. " --remove-existing-container"
	if no_cache then
		cmd = cmd .. " --build-no-cache"
	end
	return cmd .. "; echo $? > " .. Resolve.shell_quote(marker)
end

local function start_rebuild(cx: any, ws: string, no_cache: boolean)
	for _, entry in pending do
		if entry.ws == ws then
			cx:toast("info", "Rebuild already running", ws)
			return
		end
	end
	counter = counter + 1
	local marker = tern.plugin.data .. "/rebuild-" .. counter .. ".status"
	local pane = cx.layout:new_tab({
		cwd = ws,
		command = rebuild_command(ws, no_cache, marker),
	})
	if pane == nil then
		cx:toast("error", "Could not open the rebuild pane")
		return
	end
	pending[pane] = { ws = ws, marker = marker }
end

local function rebuild_dentro(cx: any, no_cache: boolean)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No focused pane with a working directory")
		return
	end
	Resolve.detect_engine(function(engine)
		if engine == nil then
			cx:toast("error", "Neither docker nor podman is available")
			return
		end
		Resolve.container_info(engine, cwd, function(info)
			if info == nil then
				cx:toast("error", "Focused pane is not inside a bind mount of a running container", cwd)
				return
			end
			start_rebuild(cx, info.ws, no_cache)
		end)
	end)
end

local function rebuild_fuera(cx: any, no_cache: boolean)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No focused pane with a working directory")
		return
	end
	local ws = Resolve.find_config(cwd)
	if ws == nil then
		cx:toast("error", "No devcontainer config found in parent directories", cwd)
		return
	end
	start_rebuild(cx, ws, no_cache)
end

local function inside_gate(cx: any): boolean
	local cwd = focused_cwd(cx)
	return cwd ~= nil and not tern.fs.exists(cwd)
end

tern.command({
	id = "rebuild",
	title = "Rebuild Container",
	icon = "terminal",
	group = "Dev Containers",
	available = inside_gate,
	run = function(cx)
		rebuild_dentro(cx, false)
	end,
})

tern.command({
	id = "rebuild_no_cache",
	title = "Rebuild Container Without Cache",
	icon = "terminal",
	group = "Dev Containers",
	available = inside_gate,
	run = function(cx)
		rebuild_dentro(cx, true)
	end,
})

tern.command({
	id = "rebuild_reopen",
	title = "Rebuild and Reopen in Container",
	icon = "terminal",
	group = "Dev Containers",
	available = function(cx)
		local cwd = focused_cwd(cx)
		return cwd ~= nil and tern.fs.exists(cwd)
	end,
	run = function(cx)
		rebuild_fuera(cx, false)
	end,
})

tern.command({
	id = "rebuild_no_cache_reopen",
	title = "Rebuild Without Cache and Reopen in Container",
	icon = "terminal",
	group = "Dev Containers",
	available = function(cx)
		local cwd = focused_cwd(cx)
		return cwd ~= nil and tern.fs.exists(cwd)
	end,
	run = function(cx)
		rebuild_fuera(cx, true)
	end,
})
