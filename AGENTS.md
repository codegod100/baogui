# BaoGUI

Simple Vidya (egui) OpenBao (Vault-compatible KV) client — a port of BaoGTK.

## Version control

**jj is used for version control instead of git.** Prefer `jj` for status, diffs, commits, bookmarks, and push/fetch. Do not use a pager (`jj --config 'ui.paginate=never'` or `PAGER=cat`) — pagers break agent tooling.

Common mappings:

| Intent | Use |
|--------|-----|
| Status | `jj status` |
| Diff | `jj diff` |
| Log | `jj log --no-pager` |
| Commit | `jj commit -m "..."` (or describe working copy) |
| New change | `jj new` |
| Undo / edit | `jj undo`, `jj edit`, `jj abandon` |
| Bookmarks | `jj bookmark set main -r @` |
| Push | `jj git push` |
| Fetch | `jj git fetch` |

This repo is colocated with git (`.jj` + `.git`); remotes still go through the git remote via `jj git …`.

## Dev

```bash
nix run                 # cargo run (host rustup + staged .desktop/icons)
nix develop             # interactive → cargo run (egui libs; host rustc)
nix build .#baogui      # pure package (stages flake input vidya)
```

`nix run` / `nix run .#baogui` use **PATH** `cargo`/`rustc` (rustup), set egui `LD_LIBRARY_PATH`, stage FreeDesktop data under `target/xdg-data/`, and **`cargo run`**. They do **not** pull nixpkgs rustc. Needs sibling `../vidya`. Packaged `nix build .#baogui` stages vidya from the flake input and installs the desktop entry under `$out/share/applications/`.

App id / desktop icon: `org.openbao.baogui`.

## Cursor Cloud specific instructions

- Repo-level environment: `.cursor/environment.json` + `.cursor/install.sh`.
- Determinate Nix is installed by the install script (`--init none`; no systemd).
  The nix daemon is started during install. If `nix` later fails with a daemon
  socket error, run:
  `sudo nohup /nix/var/nix/profiles/default/bin/nix-daemon >/tmp/nix-daemon.log 2>&1 &`
- In a bare shell, load nix with:
  `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`
- Sibling `../vidya` is required for `cargo` / `nix run`. The install script
  clones it to `/vidya` when missing.
- Host rustup (`cargo`/`rustc` on PATH) is used by `nix run`; use
  `nix develop --command <cmd>` when you need egui link libraries from the flake.
