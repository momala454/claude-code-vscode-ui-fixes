#!/usr/bin/env bash
#
# Temporarily restore the PRISTINE Claude Code extension bundles (undo the UI patches) — for
# taking "before" screenshots. Re-apply by running claude-ext-repatch.sh with no argument.
#
# This is a thin wrapper on purpose. Where the extensions live and which files carry patches
# is knowledge the patcher already owns, and keeping a second copy of it here is exactly how
# this script rotted: it only knew ~/.vscode-server/…-linux-x64, so it left a Windows-side
# install fully patched, and it only put back webview/index.{js,css}, so the host fixes
# (D/E/G) stayed in effect — a "before" screenshot that was not one.
set -euo pipefail

self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [ -x "$self_dir/claude-ext-repatch.sh" ]; then
  exec "$self_dir/claude-ext-repatch.sh" --restore
fi
exec claude-ext-repatch.sh --restore   # installed copy, via PATH
