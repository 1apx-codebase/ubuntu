#!/usr/bin/env bash
# Set up SSH access to GitHub and push this repo to it.
# Run as vaviles (not root): ./setup-github.sh
# Safe to re-run: each step is skipped if it's already done.
set -euo pipefail

GH_ACCOUNT=1apx-codebase
GH_REPO=ubuntu
GIT_NAME="Virgil Aviles"
GIT_EMAIL="virgil.aviles@proton.me"
KEY=~/.ssh/id_ed25519
KEY_COPY=~/github-ssh-key.txt
REMOTE_URL="git@github.com:$GH_ACCOUNT/$GH_REPO.git"
REPO_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root, so the key and repo stay owned by you." >&2
  exit 1
fi

# 1. SSH key
if [ ! -f "$KEY" ]; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -q -t ed25519 -N "" -C "$GIT_EMAIL ($(hostname))" -f "$KEY"
  echo "Created $KEY"
fi
ssh-keygen -lf "$KEY.pub"

# 2. Check that GitHub accepts the key; if not, wait until it's added
github_ok() {
  # ssh -T always exits 1 on GitHub, so check its message instead of its exit code
  GH_GREETING=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -T git@github.com 2>&1 </dev/null || true)
  [[ $GH_GREETING == *"successfully authenticated"* ]]
}
if ! github_ok; then
  cp "$KEY.pub" "$KEY_COPY"
  cat <<EOF

Add this public key on GitHub: Settings -> SSH and GPG keys -> New SSH key
(title: $(hostname), type: Authentication Key)

$(cat "$KEY.pub")

It is also saved to $KEY_COPY. To fetch it from another computer:
  scp $(whoami)@$(hostname -I | awk '{print $1}'):$(basename "$KEY_COPY") .

EOF
  until github_ok; do
    read -r -p "Press Enter once the key is added (Ctrl+C to quit)... "
  done
  rm -f "$KEY_COPY"
fi
echo "$GH_GREETING"

# 3. Local repo and commit identity
cd "$REPO_DIR"
if [ ! -d .git ]; then
  git init -q -b main
fi
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
if ! git rev-parse -q --verify HEAD >/dev/null; then
  git add -A
  git commit -q -m "Document $(hostname) Ubuntu post-install changes"
fi

# 4. Remote
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

# 5. Check the GitHub repo exists; if not, wait until it's created
until git ls-remote origin >/dev/null 2>&1; do
  cat <<EOF

GitHub can't find $GH_ACCOUNT/$GH_REPO.
Create it at https://github.com/new: owner $GH_ACCOUNT, name $GH_REPO, Private,
and leave out the README, .gitignore and license.
EOF
  read -r -p "Press Enter once the repo is created (Ctrl+C to quit)... "
done

# 6. Push
git push -u origin main

# 7. Verify
git status -sb | head -1
code=$(curl -s -o /dev/null -w "%{http_code}" "https://github.com/$GH_ACCOUNT/$GH_REPO" || true)
case "$code" in
  404) echo "Repo is private." ;;
  200) echo "WARNING: repo is PUBLIC. Change it under Settings -> General -> Danger Zone." ;;
  *)   echo "Couldn't check visibility (HTTP $code)." ;;
esac
