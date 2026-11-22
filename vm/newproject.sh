#!/usr/bin/env bash
# ailab-newproject <name> <github-owner/repo>
# Scaffolds ~/work/<name> with CI/release workflows, creates a repo-scoped GitHub
# deploy key and wires the git remote to it.
set -Eeuo pipefail

name="${1:-}"; slug="${2:-}"
[[ -n "$name" && "$slug" == */* ]] || { echo "usage: ailab-newproject <name> <github-owner/repo>" >&2; exit 2; }
[[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "invalid project name" >&2; exit 2; }

tpl=/opt/ailab/templates
dir="$HOME/work/$name"
key="$HOME/.ssh/deploy_$name"
alias_host="github-$name"

[[ ! -e "$dir" ]] || { echo "$dir already exists" >&2; exit 1; }
mkdir -p "$dir/.github/workflows" "$dir/tools" "$dir/tofu" "$dir/ansible" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

cp "$tpl/ci.yml"                "$dir/.github/workflows/ci.yml"
cp "$tpl/release.yml"           "$dir/.github/workflows/release.yml"
cp "$tpl/operator-fetch.sh"     "$dir/tools/operator-fetch.sh"
cp "$tpl/pre-commit-config.yaml" "$dir/.pre-commit-config.yaml"
cp "$tpl/gitignore"             "$dir/.gitignore"
chmod +x "$dir/tools/operator-fetch.sh"
sed -i "s#__REPO__#$slug#g" "$dir/tools/operator-fetch.sh"
cat >"$dir/README.md" <<EOF
# $name

Infrastructure provisioning code. Built and verified by GitHub Actions
(\`.github/workflows\`); applied manually by an operator with \`tools/operator-fetch.sh\`.

- \`tofu/\`     OpenTofu configuration
- \`ansible/\`  Ansible playbooks/roles
EOF

[[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C "ailab deploy key $slug" -f "$key"

# Dedicated ssh alias so this key is only ever used for this repo.
if ! grep -q "^Host $alias_host\$" "$HOME/.ssh/config" 2>/dev/null; then
  cat >>"$HOME/.ssh/config" <<EOF
Host $alias_host
  HostName github.com
  User git
  IdentityFile $key
  IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
fi

cd "$dir"
git init -q -b main
git remote add origin "git@$alias_host:$slug.git"
ssh-keyscan -t ed25519 github.com 2>/dev/null >>"$HOME/.ssh/known_hosts" || true

cat <<EOF

Project created: $dir

One-time GitHub setup (you, in the browser) for https://github.com/$slug :
  1. Settings -> Deploy keys -> Add deploy key -> tick "Allow write access"
     Title: ailab    Key:
$(cat "$key.pub")
  2. Settings -> Actions -> General -> Workflow permissions: "Read repository contents"
     (the workflows request the extra permissions they need themselves).

Then:  cd $dir && git add -A && git commit -m "init" && git push -u origin main
EOF
