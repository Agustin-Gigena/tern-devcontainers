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

local post_rebuild: ((any, string) -> ())

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

local function ensure_authorized_keys(engine: string, container: string, user: string?, cb: (boolean) -> ())
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
	local argv: { string }
	if user ~= nil and user ~= "" then
		argv = { engine, "exec", "--user", user, container, "sh", "-c", script }
	else
		argv = { engine, "exec", container, "sh", "-c", script }
	end
	tern.process.run(argv, {}, function(r)
		cb(r.status == 0)
	end)
end

-- remoteUser the way the CLI resolves it (image defaults included);
-- the raw devcontainer.json often lacks it.
local function resolve_user(ws: string, cb: (string?) -> ())
	tern.process.run({ "devcontainer", "read-configuration", "--workspace-folder", ws }, {}, function(r)
		local user: string? = nil
		if r.status == 0 then
			local ok, doc = pcall(tern.json.decode, r.stdout)
			local c = if ok and type(doc) == "table" then doc.configuration else nil
			if type(c) == "table" and type(c.remoteUser) == "string" and c.remoteUser ~= "" then
				user = c.remoteUser
			end
		end
		if user == nil then
			user = Resolve.read_remote_user(ws)
		end
		cb(user)
	end)
end

function Bridge.write_alias(ws: string, user: string?, engine: string): boolean
	local home = tern.getenv("HOME") or ""
	local sshdir = home .. "/.ssh"
	local cfg = sshdir .. "/config"
	local alias = Bridge.alias_name(ws)
	local begin = "# >>> tern-devcontainers " .. alias .. " >>>"
	local finish = "# <<< tern-devcontainers " .. alias .. " <<<"
	local lines = {
		begin,
		"Host " .. alias,
		"  HostName " .. (string.match(ws, "[^/]+$") or "devcontainer"),
	}
	if user ~= nil and user ~= "" then
		table.insert(lines, "  User " .. user)
	end
	table.insert(lines, "  IdentityFile " .. tern.plugin.data .. "/" .. BRIDGE_KEY)
	table.insert(lines, "  IdentitiesOnly yes")
	table.insert(lines, "  UserKnownHostsFile " .. tern.plugin.data .. "/known_hosts")
	-- Host keys rotate on every rebuild (ephemeral fs); accept-new rejects
	-- CHANGED keys. The transport is the local docker socket — the SSH
	-- tunnel adds nothing to protect — so skip the check entirely.
	table.insert(lines, "  StrictHostKeyChecking no")
	-- The container is resolved per connection by its stable label:
	-- image-based projects get a random name on every rebuild.
	table.insert(lines, '  ProxyCommand docker exec -i --user root "$(docker ps -q --filter label=devcontainer.local_folder=' .. Resolve.shell_quote(ws) .. ' | head -1)" /usr/sbin/sshd -i')
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
	if not tern.fs.exists(sshdir) then
		tern.fs.mkdir(sshdir)
	end
	local okw = pcall(function()
		tern.fs.write(cfg, text)
	end)
	return okw
end

function Bridge.provision(cx: any, ws: string, engine: string, cb: (boolean) -> ())
	read_or_create_keypair(function(ok1)
		if not ok1 then
			cx:toast("error", "ssh-keygen is missing or failed")
			cb(false)
			return
		end
		Resolve.container_for_host(engine, ws, function(container)
			if container == nil then
				cx:toast("error", "No running container is bind-mounting this workspace", ws)
				cb(false)
				return
			end
			ensure_sshd(engine, container, function(ok2)
				if not ok2 then
					cx:toast("error", "Could not install openssh-server in the container (Debian/Ubuntu images only) — install it manually")
					cb(false)
					return
				end
				resolve_user(ws, function(user)
					ensure_authorized_keys(engine, container, user, function(ok3)
						if not ok3 then
							cx:toast("error", "Could not write authorized_keys in the container")
							cb(false)
							return
						end
						if not Bridge.write_alias(ws, user, engine) then
							cx:toast("error", "Could not write the SSH config alias")
							cb(false)
							return
						end
						cb(true)
					end)
				end)
			end)
		end)
	end)
end

local function remote_pane(cx: any): number?
	for _, pane in cx.session:panes() do
		local cwd = pane.cwd
		if cwd ~= nil and cwd ~= "" and not tern.fs.exists(cwd) then
			return pane.pane
		end
	end
	return nil
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
		Bridge.provision(cx, ws, engine, function(ok)
			if ok then
				cx:toast("success", "Bridge ready — Tern is reconnecting to the container")
				local host_pane = remote_pane(cx)
				if host_pane ~= nil then
					cx.layout:split(host_pane, "right")
				else
					cx:command("new_session_on_host")
				end
			end
		end)
	end)
end

local function poll(cx: any)
	local live = {}
	for _, pane in cx.session:panes() do
		live[pane.pane] = true
	end
	for pane, entry in pending do
		if not live[pane] then
			pending[pane] = nil
			pcall(tern.fs.remove, entry.marker)
			cx:toast("info", "Rebuild pane closed — the rebuild may still be running", entry.ws)
		end
	end
	for pane, entry in pending do
		local ok, text = pcall(tern.fs.read, entry.marker)
		if ok and type(text) == "string" then
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
	local inner = "devcontainer up --workspace-folder "
		.. Resolve.shell_quote(ws)
		.. " --remove-existing-container"
	if no_cache then
		inner = inner .. " --build-no-cache"
	end
	inner = inner .. "; echo $? > " .. Resolve.shell_quote(marker)
	-- The pane runs the line through the login shell, which may be fish
	-- (no `$?`): run POSIX syntax under an explicit sh.
	return "sh -c " .. Resolve.shell_quote(inner)
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

local function resolve_ws(cx: any): string?
	local cwd = focused_cwd(cx)
	if cwd ~= nil then
		local ws = Resolve.find_config(cwd)
		if ws ~= nil then
			return ws
		end
	end
	local ctx = tern.kv.get("ctx")
	if type(ctx) == "table" and type(ctx.dir) == "string" then
		return Resolve.find_config(ctx.dir)
	end
	return nil
end

local function rebuild_fuera(cx: any, no_cache: boolean)
	local ws = resolve_ws(cx)
	if ws == nil then
		cx:toast("error", "No devcontainer config found — open a file of the project in the editor once, or cd into it", focused_cwd(cx) or "")
		return
	end
	start_rebuild(cx, ws, no_cache)
end

local function inside_gate(cx: any): boolean
	local cwd = focused_cwd(cx)
	return cwd ~= nil and not tern.fs.exists(cwd)
end

local function outside_gate(cx: any): boolean
	local cwd = focused_cwd(cx)
	return cwd ~= nil and tern.fs.exists(cwd)
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
	available = outside_gate,
	run = function(cx)
		rebuild_fuera(cx, false)
	end,
})

tern.command({
	id = "rebuild_no_cache_reopen",
	title = "Rebuild Without Cache and Reopen in Container",
	icon = "terminal",
	group = "Dev Containers",
	available = outside_gate,
	run = function(cx)
		rebuild_fuera(cx, true)
	end,
})

tern.command({
	id = "attach",
	title = "Attach Tern to Container",
	icon = "branch",
	group = "Dev Containers",
	available = outside_gate,
	run = function(cx)
		local ws = resolve_ws(cx)
		if ws == nil then
			cx:toast("error", "No devcontainer config found — open a file of the project in the editor once, or cd into it", focused_cwd(cx) or "")
			return
		end
		Resolve.detect_engine(function(engine)
			if engine == nil then
				cx:toast("error", "Neither docker nor podman is available")
				return
			end
			Bridge.provision(cx, ws, engine, function(ok)
				if ok then
					cx:toast("success", "Bridge ready — confirm the dialog to install Tern in the container", Bridge.alias_name(ws))
					cx:command("add_remote_host")
				end
			end)
		end)
	end,
})

tern.command({
	id = "reconnect",
	title = "Reconnect to Container Host",
	icon = "terminal",
	group = "Dev Containers",
	available = outside_gate,
	run = function(cx)
		local ws = resolve_ws(cx)
		if ws == nil then
			cx:toast("error", "No devcontainer config found — open a file of the project in the editor once, or cd into it", focused_cwd(cx) or "")
			return
		end
		Resolve.detect_engine(function(engine)
			if engine == nil then
				cx:toast("error", "Neither docker nor podman is available")
				return
			end
			Bridge.provision(cx, ws, engine, function(ok)
				if ok then
					cx:command("switch_host")
				end
			end)
		end)
	end,
})

tern.route.open(function(req, _cx)
	local dir = req.path
	local ok = pcall(tern.fs.list, dir)
	if not ok then
		dir = string.match(dir, "^(.*)/[^/]+$") or dir
	end
	tern.kv.set("ctx", { dir = dir, host = req.host })
	return nil
end)

tern.on("cwd", function(ev, _cx)
	if ev.path ~= nil and ev.path ~= "" then
		tern.kv.set("ctx", { dir = ev.path, host = "" })
	end
end)

tern.on("window_start", function(_cx)
	pcall(function()
		for _, name in tern.fs.list(tern.plugin.data) do
			if string.match(name, "^rebuild-%d+%.status$") then
				pcall(tern.fs.remove, tern.plugin.data .. "/" .. name)
			end
		end
	end)
end)
