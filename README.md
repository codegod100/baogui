# BaoGUI

<p align="center">
  <img src="data/icons/org.openbao.baogui.png" alt="BaoGUI icon" width="128" height="128">
</p>

A simple **Vidya / egui** desktop client for [OpenBao](https://openbao.org/) (Vault-compatible KV secrets).

This is a port of [BaoGTK](../baogtk) with the same OpenBao API surface, rebuilt on the [Vidya](https://tangled.org/nandi.uk/vidya) theme layer (no GTK).

## Features

- Connect with server URL + token (`BAO_ADDR` / `BAO_TOKEN` / `~/.vault-token` prefilled)
- Auto-detect KV mount (prefers `secret/`)
- Browse folders and secrets
- Read, create, edit, and permanently delete KV v2 secrets
- Mask / reveal secret values; copy path or values to clipboard
- Desktop entry + hicolor icons (`org.openbao.baogui`)

## Run

```bash
nix run                 # apps.default → baogui
nix run .#baogui
```

### Local cargo (sibling `../vidya`)

```bash
nix develop
cargo run --release

# or packaged build without enter:
nix run .#build
./target/release/baogui
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

## Nix

| Output | Role |
|--------|------|
| `apps.default` / `apps.baogui` | Launch the window (packaged derivation) |
| `apps.build` | `cargo build --release` via devshell tools |
| `packages.default` / `packages.baogui` | Wrapped binary (`LD_LIBRARY_PATH` for GL/Wayland) |
| `devShells.default` | rustc + cargo + egui runtime libs |

Flake input `vidya` is staged beside the crate so `path = "../vidya"` resolves under `nix build` / `nix run`.

## License

MIT
