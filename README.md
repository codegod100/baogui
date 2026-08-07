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

## Testing

`cargo test` runs unit tests plus HTTP fixture tests under `tests/`. Canned OpenBao/Vault responses live in `tests/fixtures/`; mockito serves them locally so the API client is exercised without `BAO_ADDR` / `BAO_TOKEN` or a real server.

Optional live check (needs credentials):

```bash
cargo test live_read -- --ignored --nocapture
```

## Packaging / CI artifacts

| Package | Status | How to get / run |
|---------|--------|------------------|
| **APK** | Built by CI on [nixbuild.net](https://nixbuild.net) (`nix build .#android` via `ssh-ng`) | Download `baogui.apk` from GitHub Actions or Buildkite (needs `NIXBUILD_TOKEN` / `OPENBAO_TOKEN`). Install on device / Waydroid / emulator. |
| **Flatpak** | Manifest + CI bundle | `flatpak/org.openbao.baogui.yml` — Wayland runtime ships libs. Download `org.openbao.baogui.flatpak` from Buildkite, or build locally (below). |
| **Nix desktop** | Local / flake (CI verifies on nixbuild) | `nix run` or `nix build .#baogui` — wraps with Wayland/`LD_LIBRARY_PATH` from nixpkgs. |

Buildkite (`.buildkite/pipeline.yml`) runs host check always, then Flatpak bundle upload, then nixbuild.net jobs when secrets exist: APK upload + `.#baogui` verify (`scripts/ci-nixbuild.sh`). Cluster secrets live under [nandi → Default cluster → Secrets](https://buildkite.com/organizations/nandi/clusters): **`NIXBUILD_TOKEN`** (preferred) or **`OPENBAO_TOKEN`** (fetches `NIXBUILD_TOKEN` from OpenBao, same as GHA). Soft-skip with a clear log when neither is set; the token is never printed. Pipeline: [baogui-aopjch](https://buildkite.com/nandi/baogui-aopjch). It does **not** publish a raw `target/release/baogui` ELF (that fails with `NoWaylandLib` without system Wayland libs / wrong glibc).

### Flatpak (local)

Needs [Flatpak](https://flatpak.org/) + `flatpak-builder` + `appstreamcli`, a Flathub remote, and sibling `../vidya` (same path dep as `cargo run`).

```bash
# once
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# NixOS / missing host tools:
nix-shell -p flatpak-builder appstream --run './scripts/flatpak.sh build'

./scripts/flatpak.sh build     # → org.openbao.baogui.flatpak
./scripts/flatpak.sh install   # install bundle (or build+install)
flatpak run org.openbao.baogui
# or: ./scripts/flatpak.sh run
```

Manifest: `flatpak/org.openbao.baogui.yml` (Freedesktop Platform/Sdk **25.08** + `rust-stable` extension). Build arranges `baogui/` + `vidya/` so `path = "../vidya"` works; crates.io is fetched at build time (`--share=network`). Desktop entry + hicolor icons + AppStream metainfo are installed into `/app/share/`.

## Nix

| Output | Role |
|--------|------|
| `apps.default` / `apps.baogui` | Stage `.desktop`/icons, `cargo run` (host rustup) |
| `apps.build` | `cargo build` only (host rustup) |
| `packages.default` / `packages.baogui` | Pure wrapped binary + desktop entry + icons |
| `packages.android` | Pure APK (`baogui.apk`, aarch64) |
| `devShells.default` | egui runtime libs + pkg-config/glib (host rustc) |

Flake input `vidya` is staged for `nix build` only. Day-to-day `nix run` needs sibling `../vidya` for the Cargo path dep.

## License

MIT
