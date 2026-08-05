# BaoGUI

<p align="center">
  <img src="data/icons/org.openbao.baogui.png" alt="BaoGUI icon" width="128" height="128">
</p>

A simple **Vidya / egui** desktop client for [OpenBao](https://openbao.org/) (Vault-compatible KV secrets).

This is a port of [BaoGTK](../baogtk) with the same OpenBao API surface, rebuilt on the [Vidya](https://tangled.org/nandi.uk/vidya) theme layer (no GTK).

## Features

- Auto-connect with stored token (`BAO_TOKEN` / `~/.vault-token` / `~/.bao-token`); token field only appears if that fails
- OIDC browser login on desktop and Android (same flow as `bao login -method=oidc`, callback on `http://localhost:8250/oidc/callback`)
- Auto-detect KV mount (prefers `secret/`)
- Browse folders and secrets
- Read, create, edit, and permanently delete KV v2 secrets
- Mask / reveal secret values; copy path or values to clipboard
- Desktop entry + hicolor icons (`org.openbao.baogui`)

## Run

```bash
nix run                 # apps.default → cargo run (host rustup)
nix run .#baogui        # same
```

Uses **PATH** `cargo`/`rustc` (rustup), sets egui GL/Wayland `LD_LIBRARY_PATH`, stages FreeDesktop icons + `.desktop` under `target/xdg-data/` for Wayland app_id, then **`cargo run`**. Does not download nixpkgs rustc. Needs sibling `../vidya`.

Desktop entry source: `data/share/applications/org.openbao.baogui.desktop`.

### Other entry points

```bash
nix run .#build         # cargo build (pass -- --release if you want)
nix develop             # egui libs + helpers; host rustc → cargo run
nix build .#baogui      # pure package (binary + .desktop + icons)
```

## Usage

1. Start OpenBao (dev mode example):

   ```bash
   bao server -dev
   # note Root Token and export BAO_ADDR / BAO_TOKEN
   ```

2. Run BaoGUI and click **Connect**.

3. Browse the sidebar, open a secret to view/edit key-value pairs, or use **New** to create one.

## Environment

| Variable | Purpose |
|----------|---------|
| `BAO_ADDR` / `VAULT_ADDR` | Server URL (default `http://127.0.0.1:8200`) |
| `BAO_TOKEN` / `VAULT_TOKEN` | Auth token |
| `BAO_TOKEN_PATH` | Token file (default `~/.vault-token`) |
| `BAO_OIDC_MOUNT` / `VAULT_OIDC_MOUNT` | OIDC auth mount path (default `oidc`) |
| `BAO_OIDC_ROLE` / `VAULT_OIDC_ROLE` | Optional OIDC role (uses server `default_role` if empty) |
| `BAO_OIDC_PORT` / `VAULT_OIDC_PORT` | Local OIDC callback port (default `8250`) |

### OIDC setup

Enable JWT/OIDC auth on OpenBao (often mounted at `oidc`) and allow the CLI redirect URI:

```text
http://localhost:8250/oidc/callback
```

In BaoGUI (desktop or APK), choose **OIDC**, set the mount/role if needed, then **Login with OIDC**. The system browser completes provider login; the app listens on localhost for the callback and then connects with the returned client token. On Android, return to BaoGUI after the browser shows success.

## Nix

| Output | Role |
|--------|------|
| `apps.default` / `apps.baogui` | Stage `.desktop`/icons, `cargo run` (host rustup) |
| `apps.build` | `cargo build` only (host rustup) |
| `packages.default` / `packages.baogui` | Pure wrapped binary + desktop entry + icons |
| `devShells.default` | egui runtime libs + pkg-config/glib (host rustc) |

Flake input `vidya` is staged for `nix build` only. Day-to-day `nix run` needs sibling `../vidya` for the Cargo path dep.

## License

MIT
