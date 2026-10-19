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
