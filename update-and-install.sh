#!/usr/bin/env bash
#
# update-and-install.sh - VoiceInk one-shot updater
#
# 1. Merges the latest from upstream Beingpax/VoiceInk into the current branch
#    (auto-adds an 'upstream' remote if missing; keeps local commits like Vertex).
# 2. Builds the local app via 'make local' - ad-hoc signed, and LOCAL_BUILD
#    disables CloudKit so it runs without an Apple Developer cert.
#    (Plain 'make build'/'make all' produce an unsigned, CloudKit-enabled app
#     that crashes on launch - see project memory.)
#    Note: 'make local' also drops a copy at ~/Downloads/VoiceInk.app itself.
# 3. Installs the fresh build to /Applications and relaunches it.
#
# Safe to re-run any time. Local tracked changes are auto-stashed across the
# merge and re-applied after, so it never clobbers local work. On merge or
# stash-pop conflicts it stops with instructions (your work is preserved).
# Does NOT push; push the merged result to your fork (origin) yourself.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="VoiceInk.app"
BUILT_APP="$REPO_DIR/.local-build/Build/Products/Debug/$APP_NAME"
DEST="/Applications/$APP_NAME"

cd "$REPO_DIR"
echo "==> Repo: $REPO_DIR"

# 1) Sync with upstream (Beingpax) -------------------------------------------
# Ensure an 'upstream' remote pointing at Beingpax exists, then merge its main
# into the current branch (keeping local commits). Local tracked changes are
# auto-stashed across the merge and re-applied after; untracked files (this
# script, new sources, build artifacts) are left in place.
UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/Beingpax/VoiceInk.git"
UPSTREAM_BRANCH="main"

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "==> Adding '$UPSTREAM_REMOTE' remote -> $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

STASHED=0
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "==> Stashing local changes before sync..."
  git stash push --message "update-and-install auto-stash" >/dev/null
  STASHED=1
fi

restore_stash() {
  if [ "$STASHED" -eq 1 ]; then
    echo "==> Re-applying stashed changes..."
    if ! git stash pop; then
      echo "ERROR: stash pop hit conflicts. Resolve them, then re-run." >&2
      echo "       Your changes are safe in 'git stash list'." >&2
      exit 1
    fi
  fi
}

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Syncing '$BRANCH' with $UPSTREAM_REMOTE/$UPSTREAM_BRANCH..."
git fetch "$UPSTREAM_REMOTE"
if ! git merge --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  echo "ERROR: merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH hit conflicts." >&2
  git merge --abort 2>/dev/null || true
  echo "       Aborted the merge to keep your tree clean. Resolve manually:" >&2
  echo "         git fetch $UPSTREAM_REMOTE && git merge $UPSTREAM_REMOTE/$UPSTREAM_BRANCH" >&2
  echo "       fix conflicts, commit, then re-run this script." >&2
  restore_stash
  exit 1
fi

restore_stash

# 2) Build (local target) -----------------------------------------------------
echo "==> Building (make local)..."
make local

if [ ! -d "$BUILT_APP" ]; then
  echo "ERROR: build did not produce $BUILT_APP" >&2
  exit 1
fi

# 2b) Stable signing (optional) ----------------------------------------------
# If a self-signed "VoiceInk-Local" Code Signing identity exists, re-sign with
# it so macOS keeps Input Monitoring/Accessibility grants across rebuilds (the
# grant binds to a stable identity instead of the volatile ad-hoc cdhash).
# Without the cert the app stays ad-hoc and those permissions reset on every
# rebuild. Create the cert once: Keychain Access > Certificate Assistant >
# Create a Certificate > Name "VoiceInk-Local", Self-Signed Root, Code Signing.
SIGN_ID="VoiceInk-Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> Re-signing with stable identity '$SIGN_ID' (permissions persist across rebuilds)..."
  codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$REPO_DIR/VoiceInk/VoiceInk.local.entitlements" \
    "$BUILT_APP"
else
  echo "==> Note: ad-hoc signed; Input Monitoring/Accessibility grants will reset on rebuild."
  echo "    To make them stick, create a '$SIGN_ID' Code Signing cert in Keychain Access"
  echo "    (Certificate Assistant > Create a Certificate > Self-Signed Root > Code Signing)."
fi

# 3) Reinstall to /Applications ----------------------------------------------
echo "==> Quitting any running VoiceInk..."
osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
pkill -x VoiceInk 2>/dev/null || true
sleep 1

echo "==> Installing to ${DEST}..."
# /Applications usually is not user-writable - elevate only when needed.
SUDO=""
if [ ! -w "$(dirname "$DEST")" ]; then
  SUDO="sudo"
  echo "    (need admin rights for /Applications - you may be prompted for your password)"
fi
$SUDO rm -rf "$DEST"
$SUDO ditto "$BUILT_APP" "$DEST"
# sudo ditto leaves the bundle root-owned, which can confuse TCC attribution;
# hand it back to the current user.
if [ -n "$SUDO" ]; then
  $SUDO chown -R "$(id -un):staff" "$DEST" 2>/dev/null || true
fi
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Launching..."
open "$DEST"
echo "Done - VoiceInk updated, built, and installed to ${DEST}"
