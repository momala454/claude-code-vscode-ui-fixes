#!/usr/bin/env bash
# Temporarily restore the PRISTINE Claude Code extension bundle (undo the UI
# patches) — for taking "before" screenshots. Re-apply with claude-ext-repatch.sh.
set -euo pipefail
target="$(ls -d "${HOME}"/.vscode-server/extensions/anthropic.claude-code-*-linux-x64 2>/dev/null | sort -V | tail -1)"
[ -n "$target" ] || { echo "no extension found"; exit 1; }
for x in index.js index.css; do
  f="$target/webview/$x"
  if [ -f "$f.orig" ]; then cp "$f.orig" "$f"; echo "restored pristine: $x"; else echo "no backup for $x (already pristine?)"; fi
done
echo "Done. Reload VS Code (Developer: Reload Window) to see the UNPATCHED state."
