#!/usr/bin/env bash
# Lists git repos under ~/work with uncommitted or unpushed work.
# Exit 0 = everything is safe on GitHub, exit 1 = something would be lost.
set -uo pipefail

dirty=0
while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"
  msg=""
  [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && msg+=" uncommitted-changes"
  if git -C "$repo" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    [[ -n "$(git -C "$repo" log '@{u}..' --oneline 2>/dev/null)" ]] && msg+=" unpushed-commits"
  else
    msg+=" no-upstream"
  fi
  if [[ -n "$msg" ]]; then echo "$repo:$msg"; dirty=1; fi
done < <(find "$HOME/work" -maxdepth 3 -name .git 2>/dev/null)

exit "$dirty"
