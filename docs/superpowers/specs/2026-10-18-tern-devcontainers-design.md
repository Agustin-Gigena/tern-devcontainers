# Tern DevContainers — Design

Date: 2026-10-18
Status: Approved design, pending implementation plan
Scope: Tern plugin `devcontainers` — VSCode-equivalent devcontainer rebuild commands

## Goal

A generic Tern plugin that replicates the four rebuild commands of the official
VSCode Dev Containers extension (`ms-vscode-remote.remote-containers`), verbatim
in name and behavior, for docker and podman, working from panes inside the
container and from host panes.

Ground truth used: official extension package (v0.470.0, marketplace vsix) for
command IDs, titles and palette `when` clauses; official CLI
(`devcontainers/cli`) source for `up` flags.

## Commands

Window-half commands (`tern.command`), palette group "Dev Containers":

| Command id | Palette title (official) | VSCode `when` | Tern `available` gate |
|---|---|---|---|
| `rebuild` | Dev Containers: Rebuild Container | `remoteName == dev-container` | focused pane `cwd ≠ ""` and `not tern.fs.exists(cwd)` (path only exists inside a container namespace) |
| `rebuild_no_cache` | Dev Containers: Rebuild Container Without Cache | same | same |
| `rebuild_reopen` | Dev Containers: Rebuild and Reopen in Container | `workspaceFolderCount != 0 && !remoteName` | `cwd` exists; walk-up (≤16 levels) finds `.devcontainer/devcontainer.json` or `.devcontainer.json` |
| `rebuild_no_cache_reopen` | Dev Containers: Rebuild Without Cache and Reopen in Container | same | same |

`available` budget is 4 ms: only cheap `tern.fs.exists` calls, never process
spawns. Container membership is confirmed at execution time, not in `available`.

## Architecture

Window-half only: `plugin.toml` (schema 1, `id = "devcontainers"`,
`window = "window.luau"`) plus `lib/resolve.luau`. No host entry, no blocks, no
lenses, no styles.

```text
Tern-DevContainers/
  plugin.toml
  window.luau      # commands, pane_exited handler, engine detection
  lib/
    resolve.luau   # find_devcontainer_config(), resolve_container_host_path()
  README.md
```

## Execution flow

Variant "fuera" (host pane):

1. Walk up from `pane.cwd` (≤16 levels) to find `.devcontainer/devcontainer.json`
   or `.devcontainer.json`. The found directory is `host_path` (workspace folder).
2. Open the rebuild pane (below).

Variant "dentro" (container pane):

1. Detect engine: `tern.process.run({"docker", "ps", "-q"})`; if the binary is
   missing (call raises), retry with `podman`; if both raise, toast an error and
   stop.
2. Inspect each running container's `Mounts`; find bind mounts whose
   `Destination` equals `pane.cwd` or is an ancestor of it; the longest matching
   `Destination` wins. `host_path = Source + suffix`.
3. No match → toast `cwd is not inside a bind mount of a running container` and
   stop.

Rebuild pane (both variants):

```bash
devcontainer up --workspace-folder <host_path> --remove-existing-container \
  [--build-no-cache]        # only for the two NoCache commands
```

- Opened with `cx.layout:new_tab({ cwd = host_path, command = ... })` so build
  logs stream live, as in VSCode.
- Compose files, features, `initializeCommand`, `postCreateCommand` and
  `remoteUser` are handled by the CLI itself; the plugin adds no logic of its
  own.
- The pane is tracked in `pending[pane] = { ws = host_path }`.
- Duplicate guard: a live `pending` entry for the same `host_path` toasts
  "Rebuild already running" and does not start another.

Completion — window event `pane_exited` on a tracked pane:

- Status 0 → `cx.layout:split(rebuild_pane, "right", { cwd = host_path,
  command = "devcontainer exec --workspace-folder <host_path> bash" })`, toast
  success. The new pane takes focus; user lands inside the fresh container,
  matching VSCode's automatic reopen/reconnect.
- Status ≠ 0 → toast error with exit code; the log pane stays open.

Old panes whose shells lived in the removed container die on their own
(VSCode closes its terminals too); the plugin ignores their `pane_exited`
events.

## Error handling

| Case | Behavior |
|---|---|
| `devcontainer` CLI missing or broken | Pane shows the CLI's error live; nonzero exit → toast pointing at the log pane |
| docker and podman both missing (variant "dentro") | Toast error, no pane opened |
| cwd unknown (`""`) | `available` hides all four rows |
| Repo uses root `.devcontainer.json` | Walk-up checks both locations (spec default) |
| Alternative config subfolders of `.devcontainer/` | Out of scope for v1 (no picker, as VSCode has) |
| Tern reload mid-rebuild | Rebuild continues (it is the shell's process); automatic re-entry is lost — log pane shows the final status for a manual exec |
| iOS client / web tab | No Lua there; plugin requires Tern desktop with local session daemon (documented in README) |

## Installation

```bash
tern plugin link /hdd/Linux/agigena/Repositorios/Tern-DevContainers
```

Linked package: edits hot-reload; `tern plugin install` copies instead.

## Prerequisite

Host `devcontainer` CLI is currently broken on this machine
(`node: libsimdjson.so.33: cannot open shared object file`). Reinstall/repair
(e.g. `npm i -g @devcontainers/cli`) before verification.

## Verification plan

1. `tern plugin list` → `devcontainers` Ready.
2. Host pane inside a repo with `.devcontainer/`: palette shows only the two
   "fuera" rows; run *Rebuild and Reopen in Container* → live log pane → new
   shell inside the container.
3. Focused pane inside the container: palette shows only the two "dentro" rows;
   run *Rebuild Container* → a container-only path (e.g. `/Contagiar`) resolved
   to its host path via inspect → rebuild → automatic re-entry.
4. NoCache variants: feature layers rebuild from scratch (visible in logs).
5. Negative: `available` rows hidden outside projects; duplicate-rebuild guard
   toasts; missing CLI surfaces through the log pane + error toast.

## Explicit non-goals (v1)

- Attach to running container, open config file, clone-in-container — other
  VSCode commands, not requested.
- Config picker for multiple `.devcontainer/*/devcontainer.json`.
- Remote hosts (panes on other machines); window half reads local disk.
