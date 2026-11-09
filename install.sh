#!/usr/bin/env bash
#
# install.sh — set up claude-ext-repatch.sh and an auto-reapply hook on login.
#
# What it does:
#   1. copies claude-ext-repatch.sh to ~/.local/bin/ (creating it if needed)
#   2. runs the patcher once
#   3. adds a backgrounded, no-op-when-already-patched call to ~/.profile so the
#      patches are re-applied automatically after a Claude Code extension update.
#      Its output goes to ~/.claude-ext-repatch.log rather than /dev/null: the patcher is
#      silent when there is nothing to do, so the log only holds actual failures.
#
# To disable the hook: chmod -x ~/.local/bin/claude-ext-repatch.sh (the hook tests -x).
# The hook lives in ~/.profile, not ~/.bashrc.
#
# Idempotent: re-running won't duplicate the .profile hook. Uninstall with
# `./install.sh --uninstall` (removes the hook line and the installed script;
# leaves your *.orig backups and the extension bundle untouched).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
DST="${BIN_DIR}/claude-ext-repatch.sh"
PROFILE="${HOME}/.profile"
HOOK_MARKER="# claude-code-vscode-ui-fixes: auto re-apply on login"

uninstall() {
  if [ -f "$PROFILE" ]; then
    # delete the marker line and the following block (up to and including the closing fi)
    awk -v m="$HOOK_MARKER" '
      $0==m {skip=1}
      skip && /^fi$/ {skip=0; next}
      !skip {print}
    ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    echo "Removed login hook from $PROFILE"
  fi
  [ -f "$DST" ] && { rm -f "$DST"; echo "Removed $DST"; }
  echo "Uninstalled. (Backups *.orig and the extension bundle were left untouched.)"
  echo "If patches are currently applied and you want them gone, reinstall the"
  echo "extension or restore each webview/index.{js,css}.orig manually, then reload VS Code."
}

if [ "${1:-}" = "--uninstall" ]; then uninstall; exit 0; fi

# 1. install the patcher
mkdir -p "$BIN_DIR"
cp "$SRC_DIR/claude-ext-repatch.sh" "$DST"
chmod +x "$DST"
echo "Installed patcher -> $DST"

# 2. run it once now
"$DST" || true

# 3. add the login hook (once)
if grep -qF "$HOOK_MARKER" "$PROFILE" 2>/dev/null; then
  echo "Login hook already present in $PROFILE"
else
  {
    echo ""
    echo "$HOOK_MARKER"
    echo "if [ -x \"\$HOME/.local/bin/claude-ext-repatch.sh\" ]; then"
    echo "    ( \"\$HOME/.local/bin/claude-ext-repatch.sh\" --if-needed >>\"\$HOME/.claude-ext-repatch.log\" 2>&1 & )"
    echo "fi"
  } >> "$PROFILE"
  echo "Added login hook to $PROFILE"
fi

echo
echo "Done. Reload VS Code (Cmd/Ctrl+Shift+P -> Developer: Reload Window) to see the patches."
echo "Note: ~/.local/bin must be on your PATH (most distros add it via ~/.profile)."
