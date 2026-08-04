#!/usr/bin/env bash
# Cursor Cloud install script - idempotent; safe to re-run on cached Builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOCKET="/nix/var/nix/daemon-socket/socket"
VIDYA_URL="${BAOGUI_VIDYA_URL:-https://tangled.org/nandi.uk/vidya.git}"

log() {
  echo "baogui-install: $*" >&2
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

load_nix_env() {
  # shellcheck disable=SC1091
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
  export PATH="/nix/var/nix/profiles/default/bin:${HOME}/.nix-profile/bin:${PATH}"
  if [[ -S "$SOCKET" ]]; then
    export NIX_REMOTE=daemon
  else
    unset NIX_REMOTE || true
  fi
}

nix_store_ok() {
  command -v nix >/dev/null 2>&1 || return 1
  if [[ -S "$SOCKET" ]]; then
    export NIX_REMOTE=daemon
    nix store ping --store daemon >/dev/null 2>&1
    return $?
  fi
  unset NIX_REMOTE || true
  nix store ping --store local >/dev/null 2>&1 && [[ -w /nix/var/nix ]]
}

ensure_nix_flakes() {
  local want="experimental-features = nix-command flakes"
  export NIX_CONFIG="${NIX_CONFIG:-}"
  case " ${NIX_CONFIG} " in
    *" experimental-features "*) ;;
    *)
      if [[ -n "$NIX_CONFIG" ]]; then
        export NIX_CONFIG="${NIX_CONFIG}"$'\n'"${want}"$'\n'"accept-flake-config = true"
      else
        export NIX_CONFIG="${want}"$'\n'"accept-flake-config = true"
      fi
      ;;
  esac

  mkdir -p "${HOME}/.config/nix"
  touch "${HOME}/.config/nix/nix.conf"
  if ! grep -qE '^[[:space:]]*experimental-features[[:space:]]*=' "${HOME}/.config/nix/nix.conf" 2>/dev/null; then
    {
      echo "experimental-features = nix-command flakes"
      echo "accept-flake-config = true"
    } >>"${HOME}/.config/nix/nix.conf"
  fi

  if [[ -w /etc/nix/nix.conf ]] || sudo -n true 2>/dev/null; then
    run_root mkdir -p /etc/nix
    run_root touch /etc/nix/nix.conf
    if ! grep -qE '^[[:space:]]*experimental-features[[:space:]]*=' /etc/nix/nix.conf 2>/dev/null; then
      {
        echo "experimental-features = nix-command flakes"
        echo "accept-flake-config = true"
      } | run_root tee -a /etc/nix/nix.conf >/dev/null
    fi
  fi
}

start_nix_daemon() {
  if [[ -S "$SOCKET" ]]; then
    export NIX_REMOTE=daemon
    return 0
  fi

  local bin="/nix/var/nix/profiles/default/bin/nix"
  if [[ ! -x "$bin" ]]; then
    bin="$(command -v nix || true)"
  fi
  [[ -n "$bin" ]] || return 1

  run_root mkdir -p /nix/var/nix/daemon-socket
  run_root chmod 755 /nix/var/nix/daemon-socket
  log "starting nix daemon (no systemd)..."
  run_root bash -c "setsid '$bin' daemon >>/tmp/nix-daemon.log 2>&1 < /dev/null &" || true

  local i
  for i in $(seq 1 60); do
    if [[ -S "$SOCKET" ]]; then
      export NIX_REMOTE=daemon
      log "nix daemon socket is up"
      return 0
    fi
    sleep 0.25
  done

  log "nix daemon did not create $SOCKET"
  return 1
}

install_determinate_nix() {
  load_nix_env
  ensure_nix_flakes

  if command -v nix >/dev/null 2>&1; then
    if ! nix_store_ok; then
      start_nix_daemon || true
      load_nix_env
    fi
    if nix_store_ok; then
      log "nix already installed and store reachable"
      return 0
    fi
  fi

  log "installing Determinate Nix..."
  if ! curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install linux --no-confirm --init none; then
    load_nix_env
    if ! command -v nix >/dev/null 2>&1; then
      log "Determinate Nix install failed"
      exit 1
    fi
    log "Determinate Nix installer reported an existing install; continuing"
  fi

  load_nix_env
  ensure_nix_flakes

  if ! nix_store_ok; then
    start_nix_daemon || true
    load_nix_env
  fi

  if ! command -v nix >/dev/null 2>&1; then
    log "nix not on PATH after install"
    exit 1
  fi

  if ! nix_store_ok; then
    log "nix installed but store is not reachable"
    exit 1
  fi

  log "Determinate Nix ready ($(nix --version 2>/dev/null | head -1))"
}

ensure_vidya_sibling() {
  local parent
  parent="$(cd "$ROOT/.." && pwd)"
  VIDYA_DIR="${parent%/}/vidya"

  if [[ -f "$VIDYA_DIR/Cargo.toml" ]]; then
    log "vidya sibling present at $VIDYA_DIR"
    return 0
  fi

  log "cloning vidya to $VIDYA_DIR"
  if [[ ! -d "$parent" ]] || [[ ! -w "$parent" ]]; then
    run_root mkdir -p "$parent"
    run_root chown "$(id -u):$(id -g)" "$parent"
  fi
  git clone --depth 1 -b main "$VIDYA_URL" "$VIDYA_DIR"
}

cargo_version_ok() {
  local ver="${1:?}"
  printf '%s\n%s\n' "1.85.0" "$ver" | sort -CV 2>/dev/null
}

ensure_rust_toolchain() {
  # Prefer rustup's cargo over stale system toolchains (e.g. /usr/local/cargo 1.83).
  export PATH="${HOME}/.cargo/bin:/usr/local/cargo/bin:${PATH}"
  export CARGO_HOME="${HOME}/.cargo"
  export RUSTUP_HOME="${HOME}/.rustup"

  if ! command -v cargo >/dev/null 2>&1 && ! command -v rustup >/dev/null 2>&1; then
    log "installing rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal
  fi

  # shellcheck disable=SC1091
  [[ -f "${HOME}/.cargo/env" ]] && . "${HOME}/.cargo/env"
  export PATH="${HOME}/.cargo/bin:${PATH}"

  if ! command -v cargo >/dev/null 2>&1; then
    log "cargo not on PATH (install rustup from https://rustup.rs/)"
    return 0
  fi

  local ver
  ver="$(cargo --version | awk '{print $2}')"
  if cargo_version_ok "$ver"; then
    log "cargo $ver ok"
    return 0
  fi

  if command -v rustup >/dev/null 2>&1; then
    log "cargo $ver too old (need >= 1.85); installing stable via rustup..."
    rustup toolchain install stable
    rustup default stable
    # shellcheck disable=SC1091
    [[ -f "${HOME}/.cargo/env" ]] && . "${HOME}/.cargo/env"
    export PATH="${HOME}/.cargo/bin:${PATH}"
    ver="$(cargo --version | awk '{print $2}')"
    log "cargo $ver ready"
    return 0
  fi

  log "warning: cargo $ver < 1.85 and rustup not found — installing rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
  export PATH="${HOME}/.cargo/bin:${PATH}"
  log "cargo $(cargo --version | awk '{print $2}') ready"
}

ensure_system_egui_libs() {
  if ldconfig -p 2>/dev/null | grep -qE 'libxkbcommon-x11\.so'; then
    log "libxkbcommon-x11 present"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "installing libxkbcommon-x11-0 (required for X11)..."
    run_root apt-get update -qq
    run_root apt-get install -y -qq libxkbcommon-x11-0
    return 0
  fi

  log "libxkbcommon-x11 missing; nix run will use nixpkgs egui libs (may need newer glibc)"
}

warm_cargo_deps() {
  ensure_rust_toolchain
  if ! command -v cargo >/dev/null 2>&1; then
    log "skipping cargo fetch (cargo not on PATH)"
    return 0
  fi
  log "fetching cargo dependencies ($(cargo --version 2>&1 | head -1))..."
  cargo fetch
}

warm_flake() {
  if ! nix_store_ok; then
    log "skipping flake warm (nix store unavailable)"
    return 0
  fi
  log "warming flake dev shell..."
  nix develop "$ROOT" -c true
}

remove_starship_shell_init() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk '
    /^# starship prompt \(installed by \.cursor\/install\.sh\)$/ { skip=1; next }
    skip && /^eval "\$\(starship init bash\)"$/ { skip=0; next }
    skip { next }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

ensure_starship_shell_init() {
  local marker='# starship prompt (installed by .cursor/install.sh)'
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local init_line='eval "$(starship init bash)"'
  local rc="${HOME}/.bashrc"

  # Starship lives in ~/.local/bin; only .bashrc is sourced by non-login shells.
  # Ubuntu .profile sources .bashrc before adding ~/.local/bin, so init belongs in bashrc.
  remove_starship_shell_init "${HOME}/.profile"
  remove_starship_shell_init "$rc"

  {
    echo ''
    echo "$marker"
    echo "$path_line"
    echo "$init_line"
  } >>"$rc"
}

install_starship() {
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v starship >/dev/null 2>&1; then
    log "starship already installed ($(starship --version 2>&1 | head -1))"
    ensure_starship_shell_init
    return 0
  fi

  log "installing starship..."
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "${HOME}/.local/bin"
  export PATH="${HOME}/.local/bin:${PATH}"
  ensure_starship_shell_init
  log "starship ready ($(starship --version 2>&1 | head -1))"
}

install_determinate_nix
ensure_vidya_sibling
ensure_rust_toolchain
ensure_system_egui_libs
warm_cargo_deps
warm_flake
install_starship

log "done"
