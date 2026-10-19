# Tern DevContainers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Tern window-half plugin `devcontainers` that replicates the four rebuild commands of the official VSCode Dev Containers extension, verbatim in name and behavior, for docker and podman.

**Architecture:** Window-half only (`plugin.toml` + `window.luau` + `lib/resolve.luau`). Commands open a dedicated pane streaming `devcontainer up` logs; completion is detected by a status marker file polled with `tern.timer`; on success a second pane runs `devcontainer exec` inside the fresh container. Spec: `docs/superpowers/specs/2026-10-18-tern-devcontainers-design.md` (validated against official VSCode extension v0.470.0, devcontainers/cli source, and full Tern SDK docs).

**Tech Stack:** Tern Plugin SDK (Luau, schema 1 manifest), `devcontainer` CLI, docker/podman CLI for inspect, `tern plugin link` for development.

## Global Constraints

- Manifest keys exactly: `schema = 1`, `id = "devcontainers"`, `name = "Dev Containers"`, `version`, `description`, `icon`, `window = "window.luau"` — no other keys, no `host`, no `[[blocks]]`, no `[[lenses]]` (unknown keys are errors; `blocks`/`lenses` need a host entry).
- Command ids: `rebuild`, `rebuild_no_cache`, `rebuild_reopen`, `rebuild_no_cache_reopen`; palette group `Dev Containers`; titles exactly `Rebuild Container`, `Rebuild Container Without Cache`, `Rebuild and Reopen in Container`, `Rebuild Without Cache and Reopen in Container`.
- Rebuild command line always: `devcontainer up --workspace-folder <host_path> --remove-existing-container` plus ` --build-no-cache` only for the two NoCache commands; appended `; echo $? > <marker>`.
- `available` budget 4 ms: focused-pane cwd lookup plus at most one `tern.fs.exists`; no directory walk-up (config discovery happens in `run`, where its cost is irrelevant — VSCode parity: "fuera" rows show for any host folder).
- `run` budget 50 ms: never block; all engine/inspect work goes through `tern.process.run` callbacks (fresh `cx`).
- Rebuild CLI is broken on this host (`node: libsimdjson.so.33` missing) — end-to-end verification of Tasks 5–6 requires fixing it first (`npm i -g @devcontainers/cli`).
- No local `luau` binary exists: per-task verification is `tern plugin list` (status Ready; Failed shows the exact load error) plus GUI palette checks.

---

### Task 1: Scaffold the plugin package and link it for development

**Files:**
- Create: `plugin.toml`
- Create: `window.luau`

**Interfaces:**
- Consumes: nothing.
- Produces: package `devcontainers` loading Ready; `window.luau` entry that later tasks extend (each keeps the `--!strict` header and `local Resolve = require("./lib/resolve")` import added in Task 2).

- [ ] **Step 1: Write `plugin.toml`**

```toml
schema = 1
id = "devcontainers"
name = "Dev Containers"
version = "0.1.0"
description = "VSCode-parity devcontainer rebuild commands."
icon = "box"
window = "window.luau"
```

- [ ] **Step 2: Write `window.luau`**

```lua
--!strict
-- Dev Containers: VSCode-parity rebuild commands for Tern.
```

- [ ] **Step 3: Link the package for development**

Run: `tern plugin link /hdd/Linux/agigena/Repositorios/Tern-DevContainers`
Expected: prints the plugins folder link (`<config>/plugins/devcontainers.path`).

- [ ] **Step 4: Verify the plugin loads**

Run: `tern plugin list`
Expected: `devcontainers` listed with status `Ready`. If `Failed`, the listed problem text names the exact manifest/entry error — fix and re-run.

- [ ] **Step 5: Commit**

```bash
git add plugin.toml window.luau
git commit -m "feat: scaffold devcontainers plugin package"
```

### Task 2: Path resolution helpers in `lib/resolve.luau`

**Files:**
- Create: `lib/resolve.luau`
- Modify: `window.luau` (add the import line)

**Interfaces:**
- Consumes: `tern.fs.exists(path) -> boolean` (never raises), `tern.plugin.data` (string).
- Produces (later tasks rely on exact signatures):
  - `Resolve.parent_of(path: string): string?` — parent directory, `nil` at filesystem root.
  - `Resolve.find_config(dir: string): string?` — nearest ancestor (≤16 levels) containing `.devcontainer/devcontainer.json` or `.devcontainer.json`, else `nil`.
  - `Resolve.shell_quote(s: string): string` — POSIX single-quoted argument.

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

- [ ] **Step 2: Import it in `window.luau`**

Replace the whole content of `window.luau` with:

```lua
--!strict
-- Dev Containers: VSCode-parity rebuild commands for Tern.
local Resolve = require("./lib/resolve")
```

- [ ] **Step 3: Verify the package still loads (module syntax + require path)**

Run: `tern plugin list`
Expected: `devcontainers` → `Ready`. `Failed` with `module 'lib/resolve' not found`-style text means the require path or file name is wrong.

- [ ] **Step 4: Commit**

```bash
git add lib/resolve.luau window.luau
git commit -m "feat: config discovery and shell helpers"
```

### Task 3: Engine detection and container→host path mapping

**Files:**
- Modify: `lib/resolve.luau` (append the two functions before `return Resolve`)

**Interfaces:**
- Consumes: `tern.process.run(argv, opts?, callback)` — raises at call when the program is missing (hence `pcall`); callback `fn(result, cx?)` with `result.status`, `result.stdout`; `tern.json.decode(text)` raises on bad JSON.
- Produces:
  - `export type Engine = "docker" | "podman"`
  - `Resolve.detect_engine(callback: (Engine?) -> ())` — tries `docker`, falls back to `podman`; `nil` when neither works.
  - `Resolve.container_host_path(engine: Engine, container_cwd: string, callback: (string?) -> ())` — host-side path of the bind mount covering `container_cwd` (longest matching `Destination` wins), or `nil`.

- [ ] **Step 1: Append engine detection and mount mapping to `lib/resolve.luau`**

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

function Resolve.container_host_path(
	engine: Engine,
	container_cwd: string,
	callback: (string?) -> ()
)
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
			if not ok or type(containers) ~= "table" then
				callback(nil)
				return
			end
			local best: string? = nil
			local best_len = -1
			for _, container in containers do
				for _, mount in (container.Mounts or {}) do
					if mount.Type == "bind" and mount.Source ~= nil and mount.Destination ~= nil then
						local dest: string = mount.Destination
						local covers = container_cwd == dest
							or (
								string.sub(container_cwd, 1, #dest) == dest
								and string.sub(container_cwd, #dest + 1, #dest + 1) == "/"
							)
						if covers and #dest > best_len then
							best_len = #dest
							best = mount.Source .. string.sub(container_cwd, #dest + 1)
						end
					end
				end
			end
			callback(best)
		end)
	end)
end
```

- [ ] **Step 2: Verify the package still loads**

Run: `tern plugin list`
Expected: `devcontainers` → `Ready` (a Luau syntax error surfaces as `Failed` with the problem text).

- [ ] **Step 3: Commit**

```bash
git add lib/resolve.luau
git commit -m "feat: docker/podman engine detection and bind-mount host path mapping"
```

### Task 4: The four commands with VSCode-parity gating and rebuild launch

**Files:**
- Modify: `window.luau` (full content below)

**Interfaces:**
- Consumes: `Resolve.find_config`, `Resolve.shell_quote`, `Resolve.detect_engine`, `Resolve.container_host_path`, `tern.plugin.data`.
- Produces:
  - Palette commands `plugin.devcontainers.rebuild`, `.rebuild_no_cache`, `.rebuild_reopen`, `.rebuild_no_cache_reopen` (group `Dev Containers`).
  - `start_rebuild(cx, ws: string, no_cache: boolean)` — shared launcher with duplicate guard; stores `pending[pane] = { ws = ws, marker = marker }`; Task 5 consumes `pending`.

- [ ] **Step 1: Replace `window.luau` with the full implementation**

```lua
--!strict
-- Dev Containers: VSCode-parity rebuild commands for Tern.
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
		Resolve.container_host_path(engine, cwd, function(ws)
			if ws == nil then
				cx:toast("error", "Focused pane is not inside a bind mount of a running container", cwd)
				return
			end
			start_rebuild(cx, ws, no_cache)
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
```

- [ ] **Step 2: Verify load and status**

Run: `tern plugin list`
Expected: `devcontainers` → `Ready` (a bad command id such as `bind`, or a manifest mismatch, fails load with the exact problem).

- [ ] **Step 3: GUI palette checks (Tern desktop)**

1. Focus a pane inside a repo with `.devcontainer/` (host side): palette shows only `Rebuild and Reopen in Container` and `Rebuild Without Cache and Reopen in Container`.
2. Focus a pane inside the dev container (`/Contagiar`-style path): palette shows only `Rebuild Container` and `Rebuild Container Without Cache`.
3. Focus a pane in `~` or `/tmp`: only the two "fuera" rows appear (VSCode parity: `workspaceFolderCount != 0` with any folder); running one toasts `No devcontainer config found in parent directories` and opens no pane.
Expected: exactly the rows of the VSCode `when` matrix.

- [ ] **Step 4: Commit**

```bash
git add window.luau
git commit -m "feat: four VSCode-parity rebuild commands with gating and rebuild launch"
```

### Task 5: Completion marker polling, automatic re-entry, stale-marker cleanup

**Files:**
- Modify: `window.luau` (add the pieces below; insertion points noted)

**Interfaces:**
- Consumes: `pending` (Task 4), `Resolve.shell_quote`, `tern.timer(ms, fn)` (window callbacks get fresh `cx`), `tern.fs.read/remove/list` (in `pcall`).
- Produces: automatic `devcontainer exec` pane after a successful rebuild; error toast with exit status otherwise; `rebuild-<n>.status` files cleaned on `window_start`.

- [ ] **Step 1: Add the polling machinery after `pending` declaration**

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
				local exec = "devcontainer exec --workspace-folder "
					.. Resolve.shell_quote(entry.ws)
					.. " bash"
				local newpane = cx.layout:split(pane, "right", { cwd = entry.ws, command = exec })
				if newpane == nil then
					cx.layout:new_tab({ cwd = entry.ws, command = exec })
				end
				cx:toast("success", "Rebuilt", entry.ws)
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

- [ ] **Step 2: Start polling from `start_rebuild`**

In `start_rebuild`, after `pending[pane] = { ws = ws, marker = marker }` add:

```lua
	start_polling()
```

- [ ] **Step 3: Clean stale markers on window start (end of `window.luau`)**

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
Expected: `devcontainers` → `Ready`.

- [ ] **Step 5: Commit**

```bash
git add window.luau
git commit -m "feat: marker-poll completion, automatic exec re-entry, stale marker cleanup"
```

### Task 6: README and end-to-end verification matrix

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: user-facing install/usage doc.

- [ ] **Step 1: Write `README.md`**

```markdown
# devcontainers — Tern plugin

The four rebuild commands of the VSCode Dev Containers extension, verbatim,
as Tern palette commands. Works with docker and podman.

## Install

    tern plugin link /path/to/Tern-DevContainers

Requires: `devcontainer` CLI (`npm i -g @devcontainers/cli`) and either
`docker` or `podman` on PATH. Tern desktop (the web tab runs no Lua).

## Commands (palette group "Dev Containers")

| When | Command |
| --- | --- |
| Focused pane inside a dev container | Rebuild Container, Rebuild Container Without Cache |
| Focused pane outside any dev container (any host folder; without config it errors like VSCode) | Rebuild and Reopen in Container, Rebuild Without Cache and Reopen in Container |

Each command opens a pane streaming the `devcontainer up` build logs. On
success a second pane opens a shell inside the fresh container
(`devcontainer exec ... bash`); on failure a toast shows the exit status and
the log pane stays open.

"Inside" resolution is generic: the running containers are inspected
(`docker`/`podman inspect`) and the bind mount whose destination covers the
pane's cwd maps it back to its host path. Note: Microsoft officially supports
docker; podman works via the docker-compatible CLI and is supported by this
plugin, not by Microsoft.
```

- [ ] **Step 2: Fix the host `devcontainer` CLI (prerequisite for end-to-end)**

Run: `devcontainer --version`
Expected today: `node: error while loading shared libraries: libsimdjson.so.33` — repair with `npm i -g @devcontainers/cli`, then re-run until a version prints.

- [ ] **Step 3: End-to-end verification (GUI, after Step 2)**

1. Host pane in Contagiar → *Rebuild and Reopen in Container* → live log pane → success toast → new shell pane inside the container (`vscode@…:/Contagiar`).
2. Focus that container shell → *Rebuild Container* → host path resolved via inspect (watch the new rebuild pane's `--workspace-folder` shows `/hdd/.../Contagiar`) → rebuild → re-entry pane.
3. *Rebuild Container Without Cache* → logs show feature layers building from scratch.
4. Negative: duplicate trigger while first rebuild runs → "Rebuild already running" toast.
5. Negative: focus `~` → run *Rebuild and Reopen in Container* → error toast `No devcontainer config found in parent directories`, no pane; same for the NoCache variant.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README with install, commands and engine support"
```
