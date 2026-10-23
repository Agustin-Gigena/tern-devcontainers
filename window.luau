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

-- SSH destinations in ~/.ssh/config the person already has (their own Host
-- entries): candidates to reach an SSH-host machine for the two-hop tunnel.
function Bridge.upstream_hosts(): { string }
	local home = tern.getenv("HOME") or ""
	local out: { string } = {}
	local ok, text = pcall(tern.fs.read, home .. "/.ssh/config")
	if not ok then
		return out
	end
	for line in string.gmatch(text, "[^\n]+") do
		local h = string.match(line, "^%s*Host%s+(.+)%s*$")
		if h ~= nil and not string.find(line, "=") then
			for entry in string.gmatch(h, "%S+") do
				if
					entry ~= "*"
					and not string.find(entry, "[*?]")
					and string.sub(entry, 1, 5) ~= "tern-"
				then
					table.insert(out, entry)
				end
			end
		end
	end
	return out
end

function Bridge.write_remote_alias(ws: string, user: string?, upstream: string): boolean
	local home = tern.getenv("HOME") or ""
	local sshdir = home .. "/.ssh"
	local cfg = sshdir .. "/config"
	local alias = "tern-" .. upstream .. "-" .. (string.match(ws, "[^/]+$") or "dev")
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
	table.insert(lines, "  StrictHostKeyChecking no")
	local proxy = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no "
		.. upstream
		.. ' "docker exec -i --user root \\"$(docker ps -q --filter label=devcontainer.local_folder='
		.. Resolve.shell_quote(ws)
		.. ' | head -1)\\" /usr/sbin/sshd -i"'
	table.insert(lines, "  ProxyCommand " .. proxy)
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

local function read_or_create_keypair(fallback: any, cb: (boolean, any) -> ())
	local priv = tern.plugin.data .. "/" .. BRIDGE_KEY
	if tern.fs.exists(priv) then
		cb(true, fallback)
		return
	end
	tern.process.run({ "ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", priv }, {}, function(r, cx)
		cb(r.status == 0, cx or fallback)
	end)
end

local function ensure_sshd(engine: string, container: string, cb: (string?, any) -> ())
	local script = "which sshd >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq openssh-server); mkdir -p /run/sshd; ssh-keygen -A >/dev/null 2>&1; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
	tern.process.run({ engine, "exec", "--user", "root", container, "sh", "-c", script }, {}, function(r, cx)
		if r.status ~= 0 then
			cb(nil, cx)
			return
		end
		cb(string.match(r.stdout, "SHA256:%S+"), cx)
	end)
end

local function ensure_authorized_keys(engine: string, container: string, user: string?, cb: (boolean, any) -> ())
	local ok, pub = pcall(tern.fs.read, tern.plugin.data .. "/" .. BRIDGE_KEY .. ".pub")
	if not ok then
		cb(false, nil)
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
	tern.process.run(argv, {}, function(r, cx)
		cb(r.status == 0, cx)
	end)
end

-- remoteUser the way the CLI resolves it (image defaults included);
-- the raw devcontainer.json often lacks it.
local function resolve_user(ws: string, cb: (string?, any) -> ())
	tern.process.run({ "devcontainer", "read-configuration", "--workspace-folder", ws }, {}, function(r, cx)
		local user: string? = nil
		if r.status == 0 then
			local ok, doc = pcall(tern.json.decode, r.stdout)
			local c = if ok and type(doc) == "table" then doc.configuration else nil
			if type(c) == "table" and type(c.remoteUser) == "string" and c.remoteUser ~= "" then
				user = c.remoteUser
			end
		end
		if user == nil then
			user = Resolve.read_config(ws).remoteUser
		end
		cb(user, cx)
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

function Bridge.provision(fallback: any, ws: string, engine: string, cb: (boolean, any) -> ())
	read_or_create_keypair(fallback, function(ok1, cx)
		if not ok1 then
			if cx then
				cx:toast("error", "ssh-keygen is missing or failed")
			end
			cb(false, cx)
			return
		end
		Resolve.container_for_host(engine, ws, function(container, cx)
			if container == nil then
				if cx then
					cx:toast("error", "No running container is bind-mounting this workspace", ws)
				end
				cb(false, cx)
				return
			end
			ensure_sshd(engine, container, function(fp, cx)
				if fp == nil then
					if cx then
						cx:toast("error", "Could not install openssh-server in the container (Debian/Ubuntu images only) — install it manually")
					end
					cb(false, cx)
					return
				end
				tern.kv.set("fp:" .. Bridge.alias_name(ws), fp)
				resolve_user(ws, function(user, cx)
					ensure_authorized_keys(engine, container, user, function(ok3, cx)
						if not ok3 then
							if cx then
								cx:toast("error", "Could not write authorized_keys in the container")
							end
							cb(false, cx)
							return
						end
						if not Bridge.write_alias(ws, user, engine) then
							if cx then
								cx:toast("error", "Could not write the SSH config alias")
							end
							cb(false, cx)
							return
						end
						cb(true, cx)
					end)
				end)
			end)
		end)
	end)
end

-- Container workspaceFolder: the CLI resolves defaults and substitution;
-- the raw devcontainer.json is the fallback.
local function resolve_workspace_folder(ws: string, cb: (string?, any) -> ())
	tern.process.run({ "devcontainer", "read-configuration", "--workspace-folder", ws }, {}, function(r, cx)
		local folder: string? = nil
		if r.status == 0 then
			local ok, doc = pcall(tern.json.decode, r.stdout)
			local c = if ok and type(doc) == "table" then doc.configuration else nil
			if type(c) == "table" and type(c.workspaceFolder) == "string" and c.workspaceFolder ~= "" then
				folder = c.workspaceFolder
			end
		end
		if folder == nil then
			folder = Resolve.read_config(ws).workspaceFolder
		end
		cb(folder, cx)
	end)
end

-- Attach the managed host and open a shell INSIDE the container, focused.
-- No dialogs, no pickers: hosts:add waits for the (re)connection — that is
-- the rebuild-reconnect barrier — and a pinned host-key fingerprint is
-- trusted automatically (the transport is the local docker socket).
local function connect_and_open(cx: any, alias: string, ws: string)
	local function open_shell(cx2: any)
		resolve_workspace_folder(ws, function(folder, cx3)
			local opts: { cwd: string }? = nil
			if folder ~= nil and folder ~= "" then
				opts = { cwd = folder }
			end
			cx3.hosts:terminal(alias, opts):next(function(_pane, err, cx4)
				if err ~= nil then
					cx4:toast("error", "Host conectado pero no pude abrir el shell", tostring(err))
				end
			end)
		end)
	end

	local pinned = tern.kv.get("fp:" .. alias)
	cx.hosts:add(alias):next(function(host, err, cx2)
		if err == nil and host ~= nil then
			open_shell(cx2)
			return
		end
		if pinned == nil or type(pinned) ~= "string" then
			cx2:toast("info", "Confirmá la verificación del host en el diálogo", alias)
			cx2:command("add_remote_host")
			return
		end
		cx2.hosts:trust(alias, pinned)
		cx2.hosts:add(alias):next(function(_host, err2, cx3)
			if err2 == nil then
				open_shell(cx3)
			else
				cx3:toast("info", "Confirmá la verificación del host en el diálogo", alias)
				cx3:command("add_remote_host")
			end
		end)
	end)
end

-- Attach to a devcontainer that lives on an SSH-host machine: the
-- provisioning runs inside that machine's pane (its docker, its paths)
-- and completion is polled through the person's own ssh upstream.
local function remote_attach(cx: any, pane: number, cwd: string)
	local upstreams = Bridge.upstream_hosts()
	local upstream: string? = nil
	for _, h in upstreams do
		if h == "tern-upstream" then
			upstream = h
			break
		end
	end
	if upstream == nil and #upstreams == 1 then
		upstream = upstreams[1]
	end
	if upstream == nil then
		cx:toast("error", "Agregá el Host de la máquina remota a ~/.ssh/config (una entrada Host propia, sin wildcards) y volvé a correr Attach")
		return
	end
	read_or_create_keypair(cx, function(ok, cx)
		if not ok then
			if cx then
				cx:toast("error", "ssh-keygen is missing or failed")
			end
			return
		end
		local okp, pub = pcall(tern.fs.read, tern.plugin.data .. "/" .. BRIDGE_KEY .. ".pub")
		if not okp then
			if cx then
				cx:toast("error", "Could not read the plugin keypair")
			end
			return
		end
		pub = string.gsub(pub, "%s+$", "")
		local q = Resolve.shell_quote(pub)
		local script = table.concat({
			"d=$(pwd)",
			"i=0",
			'while [ "$i" -lt 16 ]; do',
			'[ -f "$d/.devcontainer/devcontainer.json" ] && break',
			'[ -f "$d/.devcontainer.json" ] && break',
			"d=${d%/*}",
			'[ "$d" = "/" ] && break',
			"i=$((i+1)); done",
			"command -v devcontainer >/dev/null 2>&1 || npm install -g @devcontainers/cli >/dev/null 2>&1",
			"U=$(devcontainer read-configuration --workspace-folder \"$d\" 2>/dev/null | sed -n 's/.*\"remoteUser\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1)",
			'C=$(docker ps -q --filter label=devcontainer.local_folder="$d" | head -1)',
			"docker exec --user root \"$C\" sh -c 'which sshd >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq openssh-server); mkdir -p /run/sshd; ssh-keygen -A >/dev/null 2>&1'",
			"docker exec --user \"${U:-$(docker exec \"$C\" id -un)}\" \"$C\" sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF "
				.. q
				.. " ~/.ssh/authorized_keys || echo "
				.. q
				.. " >> ~/.ssh/authorized_keys)'",
			'printf \'%s\\n%s\\n%s\\n\' "${U:-}" "$d" "$(docker exec --user root "$C" ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | grep -o \'SHA256:[^ ]*\')" > /tmp/tern-dc-meta',
			"touch /tmp/tern-dc-attach.done",
		}, "; ")
		cx:run(pane, "sh -c " .. Resolve.shell_quote(script) .. "\r")
		cx:toast("info", "Provisionando el container en la máquina remota…", upstream)
		local tries = 0
		local function check(ccx: any)
			tries = tries + 1
			tern.process.run(
				{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", upstream, "cat /tmp/tern-dc-meta 2>/dev/null" },
				{},
				function(r, rcx)
					local live = if rcx ~= nil then rcx else ccx
					local u, w, fp = string.match(r.stdout, "^(.-)\n(.-)\n(SHA256:%S+)")
					if u ~= nil then
						local alias = "tern-" .. upstream .. "-" .. (string.match(w, "[^/]+$") or "dev")
						if fp ~= nil then
							tern.kv.set("fp:" .. alias, fp)
						end
						if Bridge.write_remote_alias(w, u, upstream) then
							if live then
								connect_and_open(live, alias, w)
							end
						else
							if live then
								live:toast("error", "Could not write the SSH config alias")
							end
						end
					elseif tries < 30 then
						tern.timer(2000, check)
					else
						if live then
							live:toast("error", "No pude verificar por ssh (" .. upstream .. ") — necesitás key autorizada en esa máquina; mirá el pane remoto")
						end
					end
				end
			)
		end
		tern.timer(3000, check)
	end)
end

post_rebuild = function(cx: any, ws: string)
	if not Bridge.alias_exists(ws) then
		cx:toast("info", "Container rebuilt — run 'Attach Tern to Container' for native reconnection", ws)
		return
	end
	Resolve.detect_engine(function(engine, ecx)
		if engine == nil then
			return
		end
		Bridge.provision(ecx, ws, engine, function(ok, pcx)
			if ok and pcx then
				pcx:toast("success", "Rebuilt — reconectando al container", ws)
				connect_and_open(pcx, Bridge.alias_name(ws), ws)
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

local function focused_pane_id(cx: any): number?
	local id = cx.session:focused()
	if id == nil then
		return nil
	end
	for _, pane in cx.session:panes() do
		if pane.pane == id then
			return pane.pane
		end
	end
	return nil
end

-- Rebuild on an SSH-host pane: the CLI runs on that machine, inside the
-- pane's own shell, where the person watches the logs.
local function remote_rebuild(cx: any, pane: number, no_cache: boolean)
	local script = table.concat({
		"d=$(pwd)",
		"i=0",
		'while [ "$i" -lt 16 ]; do',
		'[ -f "$d/.devcontainer/devcontainer.json" ] && break',
		'[ -f "$d/.devcontainer.json" ] && break',
		"d=${d%/*}",
		'[ "$d" = "/" ] && break',
		"i=$((i+1)); done",
		"command -v devcontainer >/dev/null 2>&1 || npm install -g @devcontainers/cli >/dev/null 2>&1",
		'devcontainer up --workspace-folder "$d" --remove-existing-container'
			.. (if no_cache then " --build-no-cache" else ""),
	}, "; ")
	cx:run(pane, "sh -c " .. Resolve.shell_quote(script) .. "\r")
	cx:toast("info", "Rebuild corriendo en el pane remoto — al terminar, Reconnect reconecta el host")
end

local function rebuild_dentro(cx: any, no_cache: boolean)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No focused pane with a working directory")
		return
	end
	local pane = focused_pane_id(cx)
	Resolve.detect_engine(function(engine, ecx)
		if engine == nil then
			if ecx then
				ecx:toast("error", "Neither docker nor podman is available")
			end
			return
		end
		Resolve.container_info(engine, cwd, function(info, icx)
			if info == nil then
				-- Not a local container: the pane lives on another machine
				-- (SSH host). Run the rebuild inside that pane's shell.
				remote_rebuild(if icx ~= nil then icx else cx, pane, no_cache)
				return
			end
			start_rebuild(if icx ~= nil then icx else cx, info.ws, no_cache)
		end)
	end)
end

local function resolve_ws(cx: any): string?
	local pinned = tern.kv.get("pinned_ws")
	if type(pinned) == "string" and Resolve.find_config(pinned) ~= nil then
		return pinned
	end
	local ctx = tern.kv.get("ctx")
	if type(ctx) == "table" and type(ctx.dir) == "string" then
		local ws = Resolve.find_config(ctx.dir)
		if ws ~= nil then
			return ws
		end
	end
	local cwd = focused_cwd(cx)
	if cwd ~= nil then
		return Resolve.find_config(cwd)
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
	available = function(cx)
		return focused_cwd(cx) ~= nil
	end,
	run = function(cx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			return
		end
		if not tern.fs.exists(cwd) then
			local pane = focused_pane_id(cx)
			if pane ~= nil then
				remote_attach(cx, pane, cwd)
			end
			return
		end
		local ws = resolve_ws(cx)
		if ws == nil then
			cx:toast("error", "No devcontainer config found — open a file of the project in the editor once, or cd into it", focused_cwd(cx) or "")
			return
		end
		Resolve.detect_engine(function(engine, ecx)
			if engine == nil then
				if ecx then
					ecx:toast("error", "Neither docker nor podman is available")
				end
				return
			end
			Bridge.provision(cx, ws, engine, function(ok, pcx)
				if ok and pcx then
					connect_and_open(pcx, Bridge.alias_name(ws), ws)
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
	available = function(cx)
		return focused_cwd(cx) ~= nil
	end,
	run = function(cx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			return
		end
		if not tern.fs.exists(cwd) then
			local pane = focused_pane_id(cx)
			if pane ~= nil then
				remote_attach(cx, pane, cwd)
			end
			return
		end
		local ws = resolve_ws(cx)
		if ws == nil then
			cx:toast("error", "No devcontainer config found — open a file of the project in the editor once, or cd into it", focused_cwd(cx) or "")
			return
		end
		Resolve.detect_engine(function(engine, ecx)
			if engine == nil then
				if ecx then
					ecx:toast("error", "Neither docker nor podman is available")
				end
				return
			end
			Bridge.provision(cx, ws, engine, function(ok, pcx)
				if ok and pcx then
					connect_and_open(pcx, Bridge.alias_name(ws), ws)
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

tern.command({
	id = "pin_project",
	title = "Pin Project Folder",
	icon = "file",
	group = "Dev Containers",
	available = outside_gate,
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
		tern.kv.set("pinned_ws", ws)
		cx:toast("success", "Pinned — rebuild/attach usan siempre esta carpeta", ws)
	end,
})

tern.on("window_start", function(_cx)
	pcall(function()
		for _, name in tern.fs.list(tern.plugin.data) do
			if string.match(name, "^rebuild-%d+%.status$") then
				pcall(tern.fs.remove, tern.plugin.data .. "/" .. name)
			end
		end
	end)
end)
