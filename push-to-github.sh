#!/bin/bash
# Pushes this patched tree to your own GitHub repo, so the workflow in
# .github/workflows/build-ipa.yml can build Aria.ipa on GitHub's macOS runners.
#
#   ./push-to-github.sh git@github.com:<you>/aria-ipa.git
#   ./push-to-github.sh https://github.com/<you>/aria-ipa.git
#
# Create the repo first (empty, no README) at github.com/new.
set -euo pipefail

cd "$(dirname "$0")"

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
    echo "usage: $0 <git-remote-url>" >&2
    exit 1
fi

if [ -z "$(git config user.email || true)" ]; then
    echo "Set a git identity first:" >&2
    echo "  git config --global user.name  \"Your Name\"" >&2
    echo "  git config --global user.email \"you@example.com\"" >&2
    exit 1
fi

# The upstream clone is shallow; make it a full history so the push is clean.
if [ -f .git/shallow ]; then
    echo "==> Unshallowing"
    git fetch --unshallow origin 2>/dev/null || true
fi

git remote remove push-target 2>/dev/null || true
git remote add push-target "$REMOTE"

echo "==> Committing the decibel volume fader and the build workflow"
git add -A
git commit -m "Add a decibel volume fader and a CI build for an unsigned IPA" \
    --author "Aria build <build@localhost>" 2>/dev/null || echo "    (nothing new to commit)"

echo "==> Pushing"
git push push-target HEAD:main

echo
echo "Done. Watch the build at:"
echo "  ${REMOTE%.git}/actions"
echo
echo "When it finishes, download the 'Aria-unsigned-ipa' artifact and feed"
echo "build/Aria.ipa to Sideloadly (sideloadly.io) with your Apple ID."
