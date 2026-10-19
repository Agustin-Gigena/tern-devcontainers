# Tern DevContainers — Design (v2)

Date: 2026-10-19
Status: Approved design (v2), pending implementation plan update
Supersedes: v1 (2026-10-18) — `devcontainer exec` re-entry replaced by native
Tern remote host inside the container

## Goal

A generic Tern plugin `devcontainers` that gives Tern the same architecture
VSCode has for dev containers:

- The **Tern session daemon runs inside the dev container** — installed over
  the same SSH flow Tern already uses for remote hosts (`login → inspect →
  install → service → route`), reached through an SSH alias the plugin
  manages. Container panes are first-class remote panes; they survive window
  close and appear in every window.
- The four rebuild commands of the official VSCode extension, verbatim in
  name and behavior, for docker and podman.
- **Reconnection**: after a rebuild destroys the container, Tern's native
  host reconnection brings the link back; the plugin re-provisions what the
  fresh container lost (sshd binary, keys) so the reconnect is silent.

Ground truth: VSCode official docs (Remote Development FAQ — "The VS Code
Server is quickly installed by VS Code when you connect to a remote
endpoint... The server is started and stopped by VS Code and is not wired
into any user or global login or startup scripts"); official extension
package v0.470.0 (command IDs, titles, when-clauses); devcontainers/cli
source (up/exec flags); full Tern Plugin SDK docs (validated by
subagent review — window-half constraints, no window `pane_exited`,
`tern.process.run` raise semantics, budgets).

## Architecture

```
Tern window (local UI + window half of this plugin)
  └─ remote host attach over SSH alias (ProxyCommand into the container)
       └─ Tern session daemon INSIDE the container
            └─ host-half plugins, native panes (survive window close)
Host machine: rebuild panes, docker/podman, this plugin's window half
```

Mirrors VSCode: local window ≈ UI-only; daemon inside ≈ vscode-server
(injected, lifecycle managed by the tool, runs as remoteUser); native
reconnect ≈ VSCode's reconnecting/reload after rebuild.

```text
Tern-DevContainers/
  plugin.toml      # schema 1, id="devcontainers", window="window.luau"
  window.luau      # commands, marker+timer completion, ssh bridge management
  lib/
    resolve.luau   # config discovery, engine detection, container mapping,
                   # devcontainer.json (JSONC) parsing
  README.md
```

Window-half only. `tern ctl` is a test harness — it cannot attach hosts
programmatically; the native attach dialog is the one supported door.

## Commands

Palette group "Dev Containers". The four rebuild commands keep the official
titles and gating (validated against the extension's package.json):

| Command id | Palette title (official) | VSCode `when` | Tern `available` gate |
|---|---|---|---|
| `rebuild` | Dev Containers: Rebuild Container | `remoteName == dev-container` | focused pane `cwd ≠ ""` and `not tern.fs.exists(cwd)` (path only exists inside a container namespace) |
| `rebuild_no_cache` | Dev Containers: Rebuild Container Without Cache | same | same |
| `rebuild_reopen` | Dev Containers: Rebuild and Reopen in Container | `workspaceFolderCount != 0 && !remoteName` | `tern.fs.exists(cwd)` (any host folder — VSCode shows it with any workspace; config discovery happens at execution) |
| `rebuild_no_cache_reopen` | Dev Containers: Rebuild Without Cache and Reopen in Container | same | same |

`available` budget is 4 ms: a focused-pane cwd lookup plus at most one
`tern.fs.exists`. No walk-up, no process spawns. Discovery and container
membership are confirmed at execution time.

v2 adds two bridge commands (VSCode has no equivalent — its attach is the
window reload itself):

| Command id | Palette title | What it does |
|---|---|---|
| `attach` | Dev Containers: Attach Tern to Container | Ensures the SSH bridge (sshd installed, keypair, authorized_keys, `~/.ssh/config` alias), then runs `cx:command("add_remote_host")` so the native dialog performs Tern's SSH setup (install daemon inside). First attach per project is manual-by-design: `tern ctl` cannot attach hosts. |
| `reconnect` | Dev Containers: Reconnect to Container Host | Re-ensures the bridge (idempotent) and runs `cx:command("switch_host")` to open the Hosts palette; used when the native reconnect needs a nudge. |

## SSH bridge (the plugin-managed part)

- **Keypair**: dedicated ed25519 keypair in the plugin data dir
  (`tern_ed25519` / `tern_ed25519.pub`), generated on first use via
  `tern.process.run({"ssh-keygen", ...})`.
- **authorized_keys**: the public key is appended (idempotent, `grep -qxF`)
  into the container user's `~/.ssh/authorized_keys` through
  `<engine> exec <container> sh -c ...`.
- **sshd binary**: devcontainer images ship without sshd. The bridge ensures
  it with `<engine> exec --user root <container> sh -c 'which sshd || (apt-get update -qq && apt-get install -y -qq openssh-server); mkdir -p /run/sshd'`
  (Debian/Ubuntu images — the official devcontainer base images; other
  families toast an error in v1). Run once per container lifetime: after
  attach and again after every rebuild, because the container filesystem is
  ephemeral — exactly like VSCode reinstalling vscode-server per rebuild.
- **`~/.ssh/config` alias**, written idempotently between managed markers:

  ```sshconfig
  # >>> tern-devcontainers <workspace-name> >>>
  Host tern-<workspace-name>
    HostName <container-name>
    User <remoteUser>
    IdentityFile <data>/tern_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile <data>/known_hosts
    StrictHostKeyChecking accept-new
    ProxyCommand <engine> exec -i --user root <container> /usr/sbin/sshd -i
  # <<< tern-devcontainers <workspace-name> <<<
  ```

  - `sshd -i` (inetd mode) needs **no listening port and no running sshd
    daemon** — one `engine exec` per SSH connection.
  - The alias targets the container **by name**, so after a rebuild the same
    alias resolves to the new container and Tern's native reconnect just
    works.
  - `StrictHostKeyChecking accept-new` + a plugin-private known_hosts file:
    the ephemeral host key changes every rebuild and is accepted silently —
    no fingerprint prompts between rebuilds.
- **remoteUser** is read from `.devcontainer/devcontainer.json` /
  `.devcontainer.json` (JSONC: `//` and `/* */` comments stripped before
  `tern.json.decode`). Missing → the `User` line is omitted and Tern's setup
  asks.

## Execution flow

Rebuild (both variants — unchanged from validated v1):

1. "fuera": walk up from `pane.cwd` (≤16 levels) for
   `.devcontainer/devcontainer.json` or `.devcontainer.json` → workspace
   folder. No config found → error toast (VSCode shows the command with any
   open folder and fails at execution the same way).
2. "dentro": engine detection (`docker ps -q`, pcall-fallback `podman`) →
   inspect running containers' bind `Mounts` → longest `Destination` covering
   `pane.cwd` → `host_path = Source + suffix`. No match → error toast.
3. Open the rebuild pane: `cx.layout:new_tab({ cwd = host_path, command = ...
   })` running `devcontainer up --workspace-folder <host_path>
   --remove-existing-container [--build-no-cache]; echo $? > <marker>` — live
   logs, as in VSCode's rebuild output. Compose files, features,
   `initializeCommand`, `postCreateCommand`, `remoteUser` are the CLI's job.
4. Duplicate guard: live `pending` entry for the same `host_path` → "Rebuild
   already running" toast.

Completion — window-half `tern.timer` poll every 500 ms while `pending` is
non-empty (fresh `cx` per callback). Chosen over window events because
`pane_exited` is host-only and `command_finished` depends on shell
integration, which the docs do not guarantee for `launch.command` panes:

- Marker appears → read status, remove marker and entry, stop polling when
  empty.
- Status 0 → toast success, then **re-provision the bridge** in the fresh
  container (sshd ensure + authorized_keys + alias refresh — the fresh
  container lost the sshd binary). Tern's native host link reconnects on its
  own (alias unchanged, `sshd -i` per connection). When provisioning succeeds
  the plugin runs `cx:command("new_session_on_host")` so a pane **inside the
  container** lands focused — the user-visible outcome of VSCode's window
  reload/reopen. If the daemon needs reinstalling, Tern's SSH setup handles
  it as on any remote host.
- Status ≠ 0 → toast error with exit code; log pane stays open.

First attach (per project, manual-by-design): run *Attach Tern to Container*
→ bridge ensured → native `Add remote host` dialog opens → type the alias
(`tern-<name>`) → Tern runs its SSH setup and installs the daemon inside.
The host persists in Tern afterwards; every rebuild reuses it.

## Error handling

| Case | Behavior |
|---|---|
| `devcontainer` CLI missing or broken | Pane shows the CLI's error live; nonzero exit → toast pointing at the log pane |
| docker and podman both missing | Toast error, no pane opened |
| cwd unknown (`""`) | `available` hides all rows |
| No config in any parent directory ("fuera" run in a random folder) | Error toast, no pane opened — VSCode shows the command with any open folder and fails at execution the same way |
| No sshd in the container's package universe (non-Debian image) | Toast with the manual-install hint; bridge stops |
| `ssh-keygen` missing | Toast error; bridge requires an SSH client stack on the host |
| Container not running ("dentro") | `ps -q` finds nothing for the mount match → error toast |
| Duplicate rebuild | "Rebuild already running" toast |
| Tern reload mid-rebuild | Rebuild continues (shell's process); timers die with the VM → auto re-provision lost; stale markers overwritten (unique id per rebuild) |
| Host key changes every rebuild | Silent: `accept-new` + plugin-private known_hosts |
| iOS client / web tab | No Lua / no processes there; requires Tern desktop with local session daemon (README) |

## Engine support

- **docker**: officially supported by Microsoft (docs: system requirements).
- **podman**: works through the docker-compatible CLI (this machine's
  `docker` is a podman shim); `podman inspect` exposes
  `Mounts[].Source/Destination` in docker-compatible JSON. Microsoft states
  other Docker-compliant CLIs "may work, they are not officially supported" —
  supported by this plugin, not by Microsoft.

## Installation

```bash
tern plugin link /hdd/Linux/agigena/Repositorios/Tern-DevContainers
```

## Prerequisites

- Host `devcontainer` CLI currently broken (`node: libsimdjson.so.33`
  missing) — repair (`npm i -g @devcontainers/cli`) before end-to-end runs.
- `ssh`, `ssh-keygen` on the host (standard OpenSSH).
- Tern desktop (web tab runs no Lua; iOS has no processes).

## Verification plan

1. `tern plugin list` → `devcontainers` Ready.
2. Host pane in a repo → *Attach Tern to Container*: bridge files appear
   (keypair in plugin data, alias block in `~/.ssh/config`, sshd installed in
   container), native dialog opens; after confirming, Tern's daemon runs
   inside (`tern ctl state` / host popover shows the container host) and a
   pane in the container survives closing the window.
3. Host pane in the repo → *Rebuild and Reopen in Container*: live logs, and
   after success the host link reconnects (host popover state `connected`)
   without fingerprint prompts and a **pane inside the container** is
   available and focused (via the New Session flow the plugin opens).
4. Container pane focused → *Rebuild Container*: alias resolves to the new
   container; bridge re-provisioned; reconnect again silent.
5. NoCache variants: feature layers rebuild from scratch (logs).
6. Negative: `~` shows only the two "fuera" rows and running one toasts the
   missing-config error; duplicate-rebuild guard toasts; missing CLI surfaces
   through log pane + toast; non-Debian image → sshd hint toast.

## Explicit non-goals (v1)

- Attaching hosts programmatically (no API — native dialog only).
- Config picker for multiple `.devcontainer/*/devcontainer.json`.
- Persistence of the Tern daemon across rebuilds via volumes (VSCode
  reinstalls vscode-server per rebuild too; the setup flow covers it).
- sshd bootstrap for non-Debian images (toast with hint instead).
- Remote hosts (panes on other machines); window half reads local disk.
- Other VSCode commands (attach-to-running, clone-in-container, open config).
