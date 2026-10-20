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

For fully automatic reopen after a rebuild (no picker), persist the
container daemon's state with two named volumes in your compose file:
`tern-state:/home/vscode/.local/state/tern` and
`tern-config:/home/vscode/.config/tern`. The fresh daemon restores its
saved session and the plugin reopens a pane inside without asking.

Two caveats: workspace folder names containing spaces produce ssh aliases
whose names must be quoted manually in `~/.ssh/config`; and
`authorized_keys` is written for the container's default user — if your
`remoteUser` differs, add the key manually.
