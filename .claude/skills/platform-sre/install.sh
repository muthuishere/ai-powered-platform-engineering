#!/usr/bin/env bash
# Install platform-sre into the user's agent skills dir by symlink, so edits in the
# repo are picked up live. Mirrors the install pattern of the user's other skills.
set -euo pipefail

SKILL_NAME="platform-sre"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${HOME}/.claude/skills"
DEST="${DEST_DIR}/${SKILL_NAME}"

mkdir -p "$DEST_DIR"
if [ -L "$DEST" ] || [ -e "$DEST" ]; then
  echo "removing existing $DEST"
  rm -rf "$DEST"
fi
ln -s "$SRC" "$DEST"
echo "linked $DEST -> $SRC"
echo "restart your agent session so it discovers SKILL.md"
