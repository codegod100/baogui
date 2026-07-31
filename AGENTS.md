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
nix develop
cargo run
# or
nix run
```

Requires sibling `../vidya` for local cargo path dep. Packaged `nix build` / `nix run` stage vidya from the flake input.

App id / desktop icon: `org.openbao.baogui`.
