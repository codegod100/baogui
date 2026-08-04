#!/usr/bin/env bash
# Load boxd credentials from OpenBao and export BOXD_TOKEN (JWT) for the CLI.
#
# The CLI accepts BOXD_TOKEN (JWT) via --token / env. BOXD_API_KEY (bxd_…) must be
# exchanged first — do not pass the raw key as BOXD_TOKEN.
#
# Usage:
#   eval "$(./scripts/boxd-env.sh)"
#   eval "$(./scripts/boxd-env.sh --github-env)"   # CI: sets BOXD_TOKEN in GITHUB_ENV
#   ./scripts/boxd-env.sh --check                # verify auth (boxd machine list)
#
# OpenBao keys (secret/data/ai-api-keys):
#   BOXD_TOKEN   — JWT (eyJ…), used directly
#   BOXD_API_KEY — bxd_… API key, exchanged when BOXD_TOKEN unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=export
CHECK=0
BOXD_EXCHANGE_URL="${BOXD_EXCHANGE_URL:-https://app.boxd.sh/api/v1/auth/token}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-env) MODE=github-env; shift ;;
    --export) MODE=export; shift ;;
    --check) CHECK=1; shift ;;
    -h | --help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "boxd-env: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${OPENBAO_TOKEN:-}" ]]; then
  echo "boxd-env: OPENBAO_TOKEN must be set" >&2
  exit 1
fi

eval "$("$ROOT/scripts/fetch-openbao-env.sh" --keys BOXD_TOKEN,BOXD_API_KEY 2>/dev/null)" || {
  echo "boxd-env: failed to read BOXD_TOKEN / BOXD_API_KEY from OpenBao" >&2
  exit 1
}

resolve_boxd_token() {
  if [[ -n "${BOXD_TOKEN:-}" && "$BOXD_TOKEN" == eyJ* ]]; then
    printf '%s' "$BOXD_TOKEN"
    return 0
  fi
  if [[ -z "${BOXD_API_KEY:-}" ]]; then
    echo "boxd-env: set BOXD_TOKEN (JWT) or BOXD_API_KEY (bxd_…) in OpenBao" >&2
    return 1
  fi
  local resp http token
  resp="$(mktemp)"
  http="$(curl -sS -o "$resp" -w '%{http_code}' \
    -X POST "$BOXD_EXCHANGE_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"api_key\":\"$BOXD_API_KEY\"}")"
  if [[ "$http" != "200" ]]; then
    echo "boxd-env: API key exchange failed (HTTP $http): $(cat "$resp")" >&2
    rm -f "$resp"
    return 1
  fi
  token="$(jq -r '.token // empty' "$resp")"
  rm -f "$resp"
  [[ -n "$token" ]] || {
    echo "boxd-env: exchange response missing token" >&2
    return 1
  }
  printf '%s' "$token"
}

JWT="$(resolve_boxd_token)"
export BOXD_TOKEN="$JWT"

if [[ "$CHECK" == 1 ]]; then
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v boxd >/dev/null || {
    echo "boxd-env: boxd CLI not installed" >&2
    exit 1
  }
  boxd machine list --json >/dev/null
  echo "boxd-env: auth OK" >&2
  exit 0
fi

emit() {
  case "$MODE" in
    github-env)
      if [[ -z "${GITHUB_ENV:-}" ]]; then
        echo "boxd-env: GITHUB_ENV unset" >&2
        exit 1
      fi
      if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$JWT"
      fi
      {
        echo "BOXD_TOKEN<<EOF"
        echo "$JWT"
        echo "EOF"
      } >>"$GITHUB_ENV"
      echo "boxd-env: set BOXD_TOKEN" >&2
      ;;
    export)
      printf 'export BOXD_TOKEN=%q\n' "$JWT"
      ;;
  esac
}

emit
