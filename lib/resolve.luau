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

export type Engine = "docker" | "podman"

local function probe(engine: Engine, callback: (Engine?, any) -> ())
	local ok = pcall(function()
		tern.process.run({ engine, "ps", "-q" }, {}, function(result, cx)
			callback(if result.status == 0 then engine else nil, cx)
		end)
	end)
	if not ok then
		callback(nil, nil)
	end
end

function Resolve.detect_engine(callback: (Engine?, any) -> ())
	probe("docker", function(engine, cx)
		if engine ~= nil then
			callback(engine, cx)
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
	tern.process.run({ engine, "ps", "-q" }, {}, function(result, cx)
		if result.status ~= 0 then
			callback(nil, cx)
			return
		end
		local argv = { engine, "inspect" }
		for id in string.gmatch(result.stdout, "%S+") do
			table.insert(argv, id)
		end
		if #argv == 2 then
			callback(nil, cx)
			return
		end
		tern.process.run(argv, {}, function(r2, cx)
			if r2.status ~= 0 then
				callback(nil, cx)
				return
			end
			local ok, containers = pcall(tern.json.decode, r2.stdout)
			if not ok then
				callback(nil, cx)
				return
			end
			callback(containers, cx)
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
	callback: ({ ws: string, container: string }?, any) -> ()
)
	inspect_all(engine, function(containers, cx)
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
		callback(best, cx)
	end)
end

function Resolve.container_for_host(engine: Engine, host_path: string, callback: (string?, any) -> ())
	inspect_all(engine, function(containers, cx)
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
		callback(best_name, cx)
	end)
end

function Resolve.read_config(config_dir: string): { remoteUser: string?, workspaceFolder: string? }
	local out: { remoteUser: string?, workspaceFolder: string? } = {}
	for _, name in { "/.devcontainer/devcontainer.json", "/.devcontainer.json" } do
		local path = config_dir .. name
		if tern.fs.exists(path) then
			local ok, text = pcall(tern.fs.read, path)
			if not ok then
				return out
			end
			local stripped = string.gsub(text, "/%*.-%*/", "")
			stripped = string.gsub(stripped, "//[^\n]*", "")
			local ok2, doc = pcall(tern.json.decode, stripped)
			if ok2 and type(doc) == "table" then
				if type(doc.remoteUser) == "string" then
					out.remoteUser = doc.remoteUser
				end
				if type(doc.workspaceFolder) == "string" then
					out.workspaceFolder = doc.workspaceFolder
				end
			end
			return out
		end
	end
	return out
end

return Resolve
