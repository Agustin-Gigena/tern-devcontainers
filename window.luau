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

local post_rebuild: ((any, string) -> ()) = function(cx: any, _ws: string)
	cx:toast("info", "Container rebuilt — run 'Attach Tern to Container' to enable native reconnection")
end

local polling = false

local BRIDGE_KEY = "tern_ed25519"

local Bridge = {}

function Bridge.alias_name(ws: string): string
	return "tern-" .. (string.match(ws, "[^/]+$") or "dev")
end

function Bridge.alias_exists(ws: string): boolean
	local home = tern.getenv("HOME") or ""
	local cfg = home .. "/.ssh/config"
	if not tern.fs.exists(cfg) then
		return false
	end
	local ok, text = pcall(tern.fs.read, cfg)
	if not ok then
		return false
	end
	return string.find(text, "Host " .. Bridge.alias_name(ws) .. "\n", 1, true) ~= nil
end

local function read_or_create_keypair(cb: (boolean) -> ())
	local priv = tern.plugin.data .. "/" .. BRIDGE_KEY
	if tern.fs.exists(priv) then
		cb(true)
		return
	end
	tern.process.run({ "ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", priv }, {}, function(r)
		cb(r.status == 0)
	end)
end

local function ensure_sshd(engine: string, container: string, cb: (boolean) -> ())
	local script = "which sshd >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq openssh-server); mkdir -p /run/sshd"
	tern.process.run({ engine, "exec", "--user", "root", container, "sh", "-c", script }, {}, function(r)
		cb(r.status == 0)
	end)
end

local function ensure_authorized_keys(engine: string, container: string, cb: (boolean) -> ())
	local ok, pub = pcall(tern.fs.read, tern.plugin.data .. "/" .. BRIDGE_KEY .. ".pub")
	if not ok then
		cb(false)
		return
	end
	pub = string.gsub(pub, "%s+$", "")
	local q = Resolve.shell_quote(pub)
	local script = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF "
		.. q
		.. " ~/.ssh/authorized_keys || echo "
		.. q
		.. " >> ~/.ssh/authorized_keys)"
	tern.process.run({ engine, "exec", container, "sh", "-c", script }, {}, function(r)
		cb(r.status == 0)
	end)
end

function Bridge.write_alias(ws: string, container: string, user: string?, engine: string): boolean
	local home = tern.getenv("HOME") or ""
	local sshdir = home .. "/.ssh"
	local cfg = sshdir .. "/config"
	local alias = Bridge.alias_name(ws)
	local begin = "# >>> tern-devcontainers " .. alias .. " >>>"
	local finish = "# <<< tern-devcontainers " .. alias .. " <<<"
	local lines = {
		begin,
		"Host " .. alias,
		"  HostName " .. container,
	}
	if user ~= nil and user ~= "" then
		table.insert(lines, "  User " .. user)
	end
	table.insert(lines, "  IdentityFile " .. tern.plugin.data .. "/" .. BRIDGE_KEY)
	table.insert(lines, "  IdentitiesOnly yes")
	table.insert(lines, "  UserKnownHostsFile " .. tern.plugin.data .. "/known_hosts")
	table.insert(lines, "  StrictHostKeyChecking accept-new")
	table.insert(lines, "  ProxyCommand " .. engine .. " exec -i --user root " .. container .. " /usr/sbin/sshd -i")
	table.insert(lines, finish)
	local block = table.concat(lines, "\n")
	local text = ""
	if tern.fs.exists(cfg) then
		local ok, t = pcall(tern.fs.read, cfg)
		if not ok then
			return false
		end
		text = t
	end
	local s, e = string.find(text, begin .. ".-" .. finish)
	if s ~= nil then
		text = string.sub(text, 1, s - 1) .. block .. string.sub(text, e + 1)
	else
		if text ~= "" and string.sub(text, -1) ~= "\n" then
			text = text .. "\n"
		end
		text = text .. block .. "\n"
	end
	local okw = pcall(function()
		tern.fs.mkdir(sshdir)
		tern.fs.write(cfg, text)
	end)
	return okw
end

function Bridge.provision(cx: any, ws: string, container: string, engine: string, cb: (boolean) -> ())
	read_or_create_keypair(function(ok1)
		if not ok1 then
			cx:toast("error", "ssh-keygen is missing or failed")
			cb(false)
			return
		end
		ensure_sshd(engine, container, function(ok2)
			if not ok2 then
				cx:toast("error", "Could not install openssh-server in the container (Debian/Ubuntu images only in v1)")
				cb(false)
				return
			end
			ensure_authorized_keys(engine, container, function(ok3)
				if not ok3 then
					cx:toast("error", "Could not write authorized_keys in the container")
					cb(false)
					return
				end
				if not Bridge.write_alias(ws, container, Resolve.read_remote_user(ws), engine) then
					cx:toast("error", "Could not write the SSH config alias")
					cb(false)
					return
				end
				cb(true)
			end)
		end)
	end)
end

post_rebuild = function(cx: any, ws: string)
	if not Bridge.alias_exists(ws) then
		cx:toast("info", "Container rebuilt — run 'Attach Tern to Container' for native reconnection", ws)
		return
	end
	Resolve.detect_engine(function(engine)
		if engine == nil then
			return
		end
		Resolve.container_for_host(engine, ws, function(container)
			if container == nil then
				return
			end
			Bridge.provision(cx, ws, container, engine, function(ok)
				if ok then
					cx:toast("success", "Bridge ready — Tern is reconnecting to the container", container)
					cx:command("new_session_on_host")
				end
			end)
		end)
	end)
end

local function poll(cx: any)
	for pane, entry in pending do
		local ok, text = pcall(tern.fs.read, entry.marker)
		if ok then
			local status = tonumber((string.gsub(text, "%s+", ""))) or -1
			pending[pane] = nil
			pcall(tern.fs.remove, entry.marker)
			if status == 0 then
				cx:toast("success", "Rebuilt", entry.ws)
				post_rebuild(cx, entry.ws)
			else
				cx:toast("error", "Rebuild failed (exit " .. status .. ")", entry.ws)
			end
		end
	end
	if next(pending) ~= nil then
		tern.timer(500, poll)
	else
		polling = false
	end
end

local function start_polling()
	if polling then
		return
	end
	polling = true
	tern.timer(500, poll)
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
	start_polling()
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

tern.command({
	id = "attach",
	title = "Attach Tern to Container",
	icon = "branch",
	group = "Dev Containers",
	available = function(cx)
		local cwd = focused_cwd(cx)
		return cwd ~= nil and tern.fs.exists(cwd)
	end,
	run = function(cx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			return
		end
		local ws = Resolve.find_config(cwd)
		if ws == nil then
			cx:toast("error", "No devcontainer config found in parent directories", cwd)
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
				Bridge.provision(cx, info.ws, info.container, engine, function(ok)
					if ok then
						cx:toast("success", "Bridge ready — confirm the dialog to install Tern in the container", Bridge.alias_name(info.ws))
						cx:command("add_remote_host")
					end
				end)
			end)
		end)
	end,
})

tern.command({
	id = "reconnect",
	title = "Reconnect to Container Host",
	icon = "terminal",
	group = "Dev Containers",
	available = function(cx)
		local cwd = focused_cwd(cx)
		return cwd ~= nil and tern.fs.exists(cwd)
	end,
	run = function(cx)
		cx:command("switch_host")
	end,
})

tern.on("window_start", function(_cx)
	for _, name in tern.fs.list(tern.plugin.data) do
		if string.match(name, "^rebuild-%d+%.status$") then
			pcall(tern.fs.remove, tern.plugin.data .. "/" .. name)
		end
	end
end)
