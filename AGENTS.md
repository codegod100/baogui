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

Repo-level environment: `.cursor/environment.json` + `.cursor/install.sh`. Determinate
Nix is installed by the install script (`--init none`; no systemd). Day-to-day
build/run still uses **plain `cargo`** on the host rustup toolchain; `nix develop`
is available when you need egui link libraries from the flake. Standard commands
live in `README.md` / `flake.nix`. Non-obvious caveats:

- **Nix daemon:** started during install. If `nix` later fails with a daemon
  socket error, run:
  `sudo nohup /nix/var/nix/profiles/default/bin/nix-daemon >/tmp/nix-daemon.log 2>&1 &`
- **Load nix in a bare shell:**
  `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`
- **Toolchain:** needs Rust ≥ 1.85 (a transitive dep requires `edition2024`). The
  VM's default `rustup` toolchain is recent stable; the preinstalled
  `/usr/local/cargo` 1.83 is too old, so don't pin to it.
- **`vidya` path dep lives at `/vidya`.** `../vidya` from `/workspace` resolves to
  `/vidya`. Use vidya's latest **`main`** branch — the `flake.lock`-pinned rev is
  stale and lacks APIs baogui uses (`icon_button`, `table_text`, `Col`/`ColKind`,
  `Icon::Copy`), so building against it fails. The install script clones it if
  missing.
- **egui/eframe system libs** (incl. `libxkbcommon-x11`, GL, wayland, x11) are
  installed at the system level, not by the install script. Missing
  `libxkbcommon-x11.so` panics at startup on X11.
- **Run (GUI):** `cd /workspace && cargo run` (or `./target/debug/baogui`) on
  `DISPLAY=:1`. It auto-connects via `BAO_ADDR`/`BAO_TOKEN` env or
  `~/.vault-token`; the token field only appears if that fails.
- **End-to-end testing:** run a throwaway server with
  `bao server -dev -dev-root-token-id=root` (the `bao`/OpenBao binary is
  installed), then `export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root`. Dev
  mode auto-creates the `secret/` KV v2 mount.
- **Lint/test:** `cargo clippy` and `cargo test` work (the `live_tests` are
  `#[ignore]`). `cargo fmt --check` reports diffs from the committed source under
  newer rustfmt — pre-existing, not a real failure.

