# Tern DevContainers Implementation Plan (v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tern plugin `devcontainers` — the Tern session daemon runs inside the dev container as a native remote host (VSCode's architecture: server injected, lifecycle managed, silent reconnect after rebuild), plus the four VSCode-parity rebuild commands.

**Architecture:** Window-half only. Rebuild commands stream `devcontainer up` logs in a dedicated pane and detect completion via a status marker polled with `tern.timer`. An SSH bridge (per-connection `sshd -i` over `engine exec` ProxyCommand, managed `~/.ssh/config` alias, dedicated keypair) lets Tern's native SSH flow install its daemon inside the container; the alias targets the container by name so Tern's native reconnect survives rebuilds.

**Tech Stack:** Tern Plugin SDK (Luau, schema 1), `devcontainer` CLI, docker/podman CLI (inspect/exec), OpenSSH (`ssh-keygen`, `ssh`), `tern plugin link`.

## Global Constraints

- Manifest keys exactly: `schema = 1`, `id = "devcontainers"`, `name = "Dev Containers"`, `version`, `description`, `icon`, `window = "window.luau"` — nothing else (unknown keys are errors).
- Rebuild command ids/titles/gating match the official extension v0.470.0 exactly (see spec's Commands table). Additional bridge commands: `attach`, `reconnect`.
- Rebuild line: `devcontainer up --workspace-folder <host_path> --remove-existing-container [--build-no-cache]; echo $? > <marker>`.
- `available` (4 ms): focused-pane cwd lookup + at most one `tern.fs.exists`; no walk-up, no processes.
- `run` (50 ms) and timer callbacks (50 ms): never block; everything slow goes through `tern.process.run` callbacks (fresh `cx` in window half).
- Completion detection is marker-file + `tern.timer` polling — never window `pane_exited` (host-only) or `command_finished` (needs shell integration).
- Re-provision after rebuild mirrors VSCode reinstalling vscode-server: fresh containers lose sshd, so the bridge re-installs it silently when the alias block already exists (project was attached before).
- No local `luau` binary: per-task verification is `tern plugin list` (status Ready; Failed prints the load error) plus GUI checks.
- Host `devcontainer` CLI currently broken (`libsimdjson.so.33`) — fix (`npm i -g @devcontainers/cli`) before Task 8's end-to-end.

---

### Task 1: Scaffold the plugin package and link it

**Files:**
- Create: `plugin.toml`
- Create: `window.luau`

**Interfaces:**
- Produces: package `devcontainers` loading Ready; `window.luau` entry extended by later tasks (keeps the `--!strict` header and `local Resolve = require("./lib/resolve")`).

- [ ] **Step 1: Write `plugin.toml`**

```toml
schema = 1
id = "devcontainers"
name = "Dev Containers"
version = "0.2.0"
description = "Dev containers as native Tern hosts: VSCode-parity rebuilds and native reconnection."
icon = "box"
window = "window.luau"
```

- [ ] **Step 2: Write `window.luau`**

```lua
--!strict
-- Dev Containers: native Tern hosts for dev containers.
local Resolve = require("./lib/resolve")
```

- [ ] **Step 3: Link and verify**

Run: `tern plugin link /hdd/Linux/agigena/Repositorios/Tern-DevContainers && tern plugin list`
Expected: `linked devcontainers 0.2.0 → …` then `devcontainers 0.2.0 Dev Containers … ready`.

- [ ] **Step 4: Commit**

```bash
git add plugin.toml window.luau
git commit -m "feat: scaffold devcontainers plugin package"
```

### Task 2: Path resolution helpers in `lib/resolve.luau`

**Files:**
- Create: `lib/resolve.luau`

**Interfaces:**
- Consumes: `tern.fs.exists(path) -> boolean` (never raises).
- Produces:
  - `Resolve.parent_of(path: string): string?`
  - `Resolve.find_config(dir: string): string?` — nearest ancestor (≤16 levels) holding `.devcontainer/devcontainer.json` or `.devcontainer.json`.
  - `Resolve.shell_quote(s: string): string` — POSIX single-quote escaping.

- [ ] **Step 1: Write `lib/resolve.luau`**

```lua
--!strict
-- Workspace/config resolution and small shell helpers for the devcontainers plugin.

local Resolve = {}

function Resolve.parent_of(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

function Resolve.find_config(dir: string): string?
	local at: string? = dir
	for _ = 1, 16 do
		if at == nil or at == "" then
			return nil
		end
		if tern.fs.exists(at .. "/.devcontainer/devcontainer.json") then
			return at
		end
		if tern.fs.exists(at .. "/.devcontainer.json") then
			return at
		end
		at = Resolve.parent_of(at)
	end
	return nil
end

function Resolve.shell_quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

return Resolve
```

- [ ] **Step 2: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready`. `Failed` naming `lib/resolve` means wrong require path or file name.

- [ ] **Step 3: Commit**

```bash
git add lib/resolve.luau
git commit -m "feat: config discovery and shell helpers"
```

### Task 3: Engine detection, container mapping, remoteUser parsing

**Files:**
- Modify: `lib/resolve.luau` (append before `return Resolve`)

**Interfaces:**
- Consumes: `tern.process.run` (raises at call when the binary is missing → `pcall`), `tern.json.decode` (raises on bad JSON → `pcall`), `tern.fs.read`.
- Produces:
  - `export type Engine = "docker" | "podman"`
  - `Resolve.detect_engine(callback: (Engine?) -> ())`
  - `Resolve.container_info(engine: Engine, container_cwd: string, callback: ({ ws: string, container: string }?) -> ())` — longest bind `Destination` covering `container_cwd`; `ws = Source + suffix`, `container` = container name (`.Name` minus leading `/`).
  - `Resolve.container_for_host(engine: Engine, host_path: string, callback: (string?) -> ())` — name of a running container with a bind `Source` covering `host_path` (used after a "fuera" rebuild, where the container cwd is unknown).
  - `Resolve.read_remote_user(config_dir: string): string?` — `remoteUser` from the JSONC `devcontainer.json` (comments stripped naively; any failure → `nil`).

- [ ] **Step 1: Append the functions**

Insert before the final `return Resolve`:

```lua
export type Engine = "docker" | "podman"

local function probe(engine: Engine, callback: (Engine?) -> ())
	local ok = pcall(function()
		tern.process.run({ engine, "ps", "-q" }, {}, function(result)
			callback(if result.status == 0 then engine else nil)
		end)
	end)
	if not ok then
		callback(nil)
	end
end

function Resolve.detect_engine(callback: (Engine?) -> ())
	probe("docker", function(engine)
		if engine ~= nil then
			callback(engine)
		else
			probe("podman", callback)
		end
	end)
end

local function name_of(c: any): string
	local n = tostring(c.Name or "")
	return string.gsub(n, "^/", "")
end

local function inspect_all(engine: Engine, callback: (any?) -> ())
	tern.process.run({ engine, "ps", "-q" }, {}, function(result)
		if result.status ~= 0 then
			callback(nil)
			return
		end
		local argv = { engine, "inspect" }
		for id in string.gmatch(result.stdout, "%S+") do
			table.insert(argv, id)
		end
		if #argv == 2 then
			callback(nil)
			return
		end
		tern.process.run(argv, {}, function(r2)
			if r2.status ~= 0 then
				callback(nil)
				return
			end
			local ok, containers = pcall(tern.json.decode, r2.stdout)
			if not ok then
				callback(nil)
				return
			end
			callback(containers)
		end)
	end)
end

local function covers(path: string, base: string): boolean
	if path == base then
		return true
	end
	return string.sub(path, 1, #base) == base
		and string.sub(path, #base + 1, #base + 1) == "/"
end

function Resolve.container_info(
	engine: Engine,
	container_cwd: string,
	callback: ({ ws: string, container: string }?) -> ()
)
	inspect_all(engine, function(containers)
		local best: { ws: string, container: string }? = nil
		local best_len = -1
		for _, c in (containers or {}) do
			for _, m in (c.Mounts or {}) do
				if m.Type == "bind" and m.Source ~= nil and m.Destination ~= nil then
					local dest: string = m.Destination
					if covers(container_cwd, dest) and #dest > best_len then
						best_len = #dest
						best = {
							ws = m.Source .. string.sub(container_cwd, #dest + 1),
							container = name_of(c),
						}
					end
				end
			end
		end
		callback(best)
	end)
end

function Resolve.container_for_host(engine: Engine, host_path: string, callback: (string?) -> ())
	inspect_all(engine, function(containers)
		local best_name: string? = nil
		local best_len = -1
		for _, c in (containers or {}) do
			for _, m in (c.Mounts or {}) do
				if m.Type == "bind" and m.Source ~= nil and m.Destination ~= nil then
					local src: string = m.Source
					if covers(host_path, src) and #src > best_len then
						best_len = #src
						best_name = name_of(c)
					end
				end
			end
		end
		callback(best_name)
	end)
end

function Resolve.read_remote_user(config_dir: string): string?
	for _, name in { "/.devcontainer/devcontainer.json", "/.devcontainer.json" } do
		local path = config_dir .. name
		if tern.fs.exists(path) then
			local ok, text = pcall(tern.fs.read, path)
			if not ok then
				return nil
			end
			local stripped = string.gsub(text, "/%*.-%*/", "")
			stripped = string.gsub(stripped, "//[^\n]*", "")
			local ok2, doc = pcall(tern.json.decode, stripped)
			if ok2 and type(doc) == "table" and type(doc.remoteUser) == "string" then
				return doc.remoteUser
			end
			return nil
		end
	end
	return nil
end
```

- [ ] **Step 2: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready`.

- [ ] **Step 3: Commit**

```bash
git add lib/resolve.luau
git commit -m "feat: engine detection, bind-mount container mapping, remoteUser parsing"
```

### Task 4: The four rebuild commands with VSCode-parity gating

**Files:**
- Modify: `window.luau` (add everything below; keep the require line)

**Interfaces:**
- Consumes: `Resolve.find_config`, `Resolve.shell_quote`, `Resolve.detect_engine`, `Resolve.container_info`.
- Produces:
  - Palette commands `plugin.devcontainers.rebuild`, `.rebuild_no_cache`, `.rebuild_reopen`, `.rebuild_no_cache_reopen` (group `Dev Containers`).
  - `pending: { [number]: { ws: string, marker: string } }` and `start_rebuild(cx, ws, no_cache)` — Task 5 consumes them.
  - `focused_cwd(cx)` and `rebuild_dentro/rebuild_fuera(cx, no_cache)` helpers.

- [ ] **Step 1: Add state and helpers to `window.luau`**

```lua
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
```

- [ ] **Step 2: Register the four commands**

```lua
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
```

- [ ] **Step 3: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready`.

- [ ] **Step 4: GUI palette checks**

1. Host pane in a repo with `.devcontainer/`: only the two "fuera" rows show.
2. Pane inside the container (`/Contagiar`-style path): only the two "dentro" rows show.
3. Pane in `~` or `/tmp`: only the two "fuera" rows show (VSCode parity: any open folder); running one toasts `No devcontainer config found in parent directories` and opens no pane.

- [ ] **Step 5: Commit**

```bash
git add window.luau
git commit -m "feat: four VSCode-parity rebuild commands"
```

### Task 5: Completion marker polling and post-rebuild bridge re-provision

**Files:**
- Modify: `window.luau` (add polling; wire into `start_rebuild`)

**Interfaces:**
- Consumes: `pending`, `tern.timer` (fresh `cx`), `tern.fs.read/remove` in `pcall`, `tern.fs.list`.
- Produces:
  - `post_rebuild(cx, ws: string)` — if the project's alias block exists in `~/.ssh/config` (attached before), silently re-provisions the bridge in the fresh container; otherwise toasts the attach hint. Task 6 supplies `Bridge.provision` and `Bridge.alias_exists`.
  - Poll loop: 500 ms re-arming timer; success → toast + `post_rebuild`; failure → toast with exit status.

- [ ] **Step 1: Add a temporary `post_rebuild` (chunk-scope local variable, declared BEFORE the poll so `poll` captures the variable — Task 6 reassigns it)**

```lua
local post_rebuild: ((any, string) -> ()) = function(cx: any, _ws: string)
	cx:toast("info", "Container rebuilt — run 'Attach Tern to Container' to enable native reconnection")
end
```

- [ ] **Step 2: Add the polling machinery after it**

```lua
local polling = false

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
```

In `start_rebuild`, after `pending[pane] = { ws = ws, marker = marker }` add `start_polling()`.

- [ ] **Step 3: Clean stale markers on window start (end of file)**

```lua
tern.on("window_start", function(_cx)
	for _, name in tern.fs.list(tern.plugin.data) do
		if string.match(name, "^rebuild-%d+%.status$") then
			pcall(tern.fs.remove, tern.plugin.data .. "/" .. name)
		end
	end
end)
```

- [ ] **Step 4: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready`.

- [ ] **Step 5: Commit**

```bash
git add window.luau
git commit -m "feat: marker-poll completion with post-rebuild hook and stale cleanup"
```

### Task 6: SSH bridge — keypair, sshd, authorized_keys, managed alias, re-provision

**Files:**
- Modify: `window.luau` (add a `Bridge` section above `poll`; replace Task 5 Step 2's `post_rebuild` with the real one)

**Interfaces:**
- Consumes: `tern.process.run`, `tern.fs` (read/write/exists/mkdir in `pcall` where they can fail), `tern.getenv("HOME")`, `Resolve.read_remote_user`, `Resolve.container_for_host`, `Resolve.detect_engine`, `Resolve.shell_quote`.
- Produces:
  - `Bridge.alias_name(ws: string): string` — `tern-<basename>`.
  - `Bridge.alias_exists(ws: string): boolean`.
  - `Bridge.write_alias(ws: string, container: string, user: string?, engine: string)` — idempotent managed block between `# >>> tern-devcontainers <alias> >>>` / `<<<` markers.
  - `Bridge.provision(cx, ws: string, container: string, engine: string, cb: (boolean) -> ())` — keypair → sshd ensure → authorized_keys → alias; toasts concrete failures.
  - `post_rebuild(cx, ws: string)` (final) — `alias_exists` → detect engine → `container_for_host` → `provision` silently; else attach hint.

- [ ] **Step 1: Add the Bridge section above `poll`**

```lua
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
```

- [ ] **Step 2: Replace the Task 5 `post_rebuild` (REASSIGN the same variable — no `local`, so `poll`'s captured upvalue sees the real implementation)**

```lua
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
```

- [ ] **Step 3: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready`.

- [ ] **Step 4: Commit**

```bash
git add window.luau
git commit -m "feat: ssh bridge — keypair, sshd ensure, authorized_keys, managed alias, silent re-provision"
```

### Task 7: Attach and reconnect commands

**Files:**
- Modify: `window.luau` (append after the four rebuild commands)

**Interfaces:**
- Consumes: `Resolve.find_config/detect_engine/container_info/read_remote_user`, `Bridge.provision/alias_name`, `cx:command("add_remote_host")`, `cx:command("switch_host")` (built-in palette commands, confirmed in the actions reference).
- Produces: palette commands `plugin.devcontainers.attach`, `.reconnect`.

- [ ] **Step 1: Add the two commands**

```lua
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
```

- [ ] **Step 2: Verify load**

Run: `tern plugin list`
Expected: `devcontainers … ready` (six commands total).

- [ ] **Step 3: Commit**

```bash
git add window.luau
git commit -m "feat: attach and reconnect commands over the native host flow"
```

### Task 8: README and end-to-end verification matrix

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces: user-facing install/usage doc.

- [ ] **Step 1: Write `README.md`**

```markdown
# devcontainers — Tern plugin

Dev containers as native Tern hosts, with the four rebuild commands of the
VSCode Dev Containers extension, verbatim. Works with docker and podman.

## Architecture

Like VSCode: a server runs **inside** the container and your window stays
local. Tern's session daemon is installed inside the container over Tern's
own SSH host flow; container panes are native remote panes (they survive
closing the window) and reconnect on their own after every rebuild.

The plugin manages an SSH bridge: a dedicated keypair, `sshd -i` started
per-connection through `docker/podman exec` (no ports, no daemon), and a
managed `Host tern-<project>` block in `~/.ssh/config` that targets the
container by name.

## Install

    tern plugin link /path/to/Tern-DevContainers

Requires: `devcontainer` CLI (`npm i -g @devcontainers/cli`), OpenSSH
(`ssh`, `ssh-keygen`), and `docker` or `podman`. Tern desktop.

## Commands (palette group "Dev Containers")

| Command | When |
| --- | --- |
| Rebuild Container / Rebuild Container Without Cache | focused pane inside a dev container |
| Rebuild and Reopen in Container / Rebuild Without Cache and Reopen in Container | focused pane in any host folder (errors like VSCode when no config exists) |
| Attach Tern to Container | first-time setup: provisions the bridge and opens Tern's native Add Remote Host dialog |
| Reconnect to Container Host | opens the Hosts palette when the native reconnect needs a nudge |

Rebuilds stream `devcontainer up` logs in a dedicated pane; on success the
plugin re-provisions sshd and keys in the fresh container and Tern
reconnects natively — no fingerprint prompts (`accept-new` with a
plugin-private known_hosts file). Like VSCode reinstalling vscode-server,
the container's ephemeral filesystem loses the daemon and Tern's SSH setup
reinstalls it.

Note: Microsoft officially supports docker; podman works via the
docker-compatible CLI and is supported by this plugin, not by Microsoft.
```

- [ ] **Step 2: Fix the host `devcontainer` CLI**

Run: `devcontainer --version`
Expected today: `libsimdjson.so.33` error — repair with `npm i -g @devcontainers/cli` until a version prints.

- [ ] **Step 3: End-to-end verification (GUI)**

1. Host pane in Contagiar → *Attach Tern to Container*: keypair appears in plugin data, `~/.ssh/config` gains the managed block, sshd installs in the container, native dialog opens; confirm with the alias → Tern's daemon runs inside; open a pane on that host, close the window, reopen — pane still alive.
2. Host pane → *Rebuild and Reopen in Container*: live logs; after success the container host reconnects (host popover `connected`) with no fingerprint prompt, and a pane inside the container is available and focused via the New Session flow.
3. Container pane focused → *Rebuild Container*: alias resolves to the new container (rebuild pane's `--workspace-folder` shows the host path), bridge re-provisioned silently, reconnect again silent.
4. *Rebuild Container Without Cache*: logs show feature layers from scratch.
5. Negative: duplicate trigger → "Rebuild already running"; `~` → fuera rows visible, run → missing-config toast; missing CLI → log pane + error toast.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README with native-host architecture and verification matrix"
```
