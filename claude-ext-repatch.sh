#!/usr/bin/env bash
#
# claude-ext-repatch.sh
#
# Re-applies local UI fixes to the Claude Code VS Code extension's webview bundle.
# The extension ships a minified, closed-source bundle, so these (not-yet-upstream)
# fixes must be re-applied after every extension update.
#
# Idempotent and safe to run repeatedly:
#   - patches EVERY installed anthropic.claude-code-*-linux-x64 version it finds
#   - keeps a one-time pristine backup per file (index.js.orig / index.css.orig)
#   - always re-derives the patch from the pristine .orig, so runs never stack /
#     corrupt, and a freshly-installed extension version starts from clean
#   - matches code by UNIQUE ANCHOR strings; a missing/ambiguous anchor is skipped
#     with a notice rather than damaging the bundle (e.g. after an upstream rewrite)
#   - verifies index.js still parses (node --check); rolls that file back if not
#
# After running, reload VS Code (Cmd/Ctrl+Shift+P -> Developer: Reload Window).
#
# Fixes:
#   A (CSS) Write-tool new-file preview was clipped to ~60px with no scroll.
#           Make the Write tool body (class .toolBodyWrapper_fKyNXw) a scrollable,
#           taller preview instead of a hidden one. Scoped to Write only.
#   B (JS)  Edit-tool diff card: clicking it now opens VS Code's NATIVE diff
#           (open_diff -> vscode.diff), which diffs the real on-disk file against
#           the file-with-edit-applied -> full file context + real line numbers.
#           Because open_diff re-applies the edit and throws "String not found in
#           file" when the edit is ALREADY applied, the click handler falls back to
#           the original in-webview Monaco modal on failure. Adds openDiff() to the
#           webview fileOpener and threads an onOpenFile callback (returning the
#           openDiff promise) into vXe.
#   C (JS)  Clicking the Edit card's FILENAME opens the file at the changed line
#           (Edit header passes {searchText:old_string||new_string}).
#
# Why local patches instead of waiting for upstream: the relevant GitHub issues
# (#59305, #59078, #3143, #48258, #65311) were all auto-closed by
# github-actions[bot] as duplicate/stale/not-planned with no human triage, so
# self-patching is the only reliable path. See conversation notes.

set -euo pipefail

EXT_GLOB="${HOME}/.vscode-server/extensions/anthropic.claude-code-*-linux-x64"

js_patch() {
  FILE="$1" node - <<'NODE'
const fs = require("fs");
const FILE = process.env.FILE;
let s = fs.readFileSync(FILE, "utf8");

// $openFn: collision-safe identifier (single letters b,f,g,i,n,o,r,s,v,w,x,y are
// already bound inside vXe's scope, which is why a plain "d" broke parsing).
const edits = [
  { name: "fileOpener +openDiff",
    from: `openContent:(e,t,i)=>{let n=this.comms.connection.value;if(n)return n.openContent(e,t,i);return Promise.resolve(void 0)}};startNewConversationTab`,
    to:   `openContent:(e,t,i)=>{let n=this.comms.connection.value;if(n)return n.openContent(e,t,i);return Promise.resolve(void 0)},openDiff:(e,t)=>{let n=this.comms.connection.value;if(n)return n.openDiff(e,e,t,!1);return Promise.reject(Error("no connection"))}};startNewConversationTab` },
  { name: "vXe signature +onOpenFile",
    from: `function vXe({original:e,modified:t,language:i="plaintext",filePath:n})`,
    to:   `function vXe({original:e,modified:t,language:i="plaintext",filePath:n,onOpenFile:$openFn})` },
  // Overlay tries the native diff (returns a promise); on reject — which happens
  // when the edit is ALREADY applied and open_diff can't find old_string on disk —
  // fall back to the original in-webview Monaco modal (p) instead of doing nothing.
  { name: "vXe overlay -> onOpenFile + modal fallback",
    from: `v=()=>{p({original:e,modified:t,language:i,filePath:n})}`,
    to:   `v=()=>{let $m=()=>p({original:e,modified:t,language:i,filePath:n});if($openFn){let $r=$openFn();if($r&&$r.catch)$r.catch($m);else if(!$r)$m()}else $m()}` },
  // Edit body returns the openDiff promise from onOpenFile so the overlay can catch.
  { name: "Edit body -> native diff",
    from: `createElement(vXe,{original:t.old_string||"",modified:t.new_string||"",filePath:t.file_path||""})`,
    to:   `createElement(vXe,{original:t.old_string||"",modified:t.new_string||"",filePath:t.file_path||"",onOpenFile:()=>this.opener.openDiff?this.opener.openDiff(t.file_path,[{oldString:t.old_string||"",newString:t.new_string||"",replaceAll:!!t.replace_all}]):void 0})` },
  // C: filename click jumps to the changed line. Target the EDIT tool's OWN header
  // (class vN, "name=r8;header..."), NOT the generic z2.header — z2 is shared by
  // Read/Write whose inputs have no old_string, so patching z2 misfires. Edit's
  // header already passes {searchText:t.new_string}; widen to old_string||new_string
  // so it works whether the edit is pending (old_string in file) or applied
  // (new_string in file). Falls back to line 1 only if neither text is present.
  { name: "Edit header -> jump to changed line",
    from: `name=r8;header(e,t){return this.fileToolHeader(this.name,t.file_path,{searchText:t.new_string})}`,
    to:   `name=r8;header(e,t){return this.fileToolHeader(this.name,t.file_path,{searchText:t.old_string||t.new_string})}` },
];

let applied = 0; const skipped = [];
for (const e of edits) {
  const n = s.split(e.from).length - 1;
  if (n === 1) { s = s.replace(e.from, e.to); applied++; }
  else { skipped.push(`${e.name} (anchor x${n})`); }
}
fs.writeFileSync(FILE, s);
console.log(`  JS:  ${applied}/${edits.length} edits` + (skipped.length ? `; SKIPPED: ${skipped.join(", ")}` : ""));
NODE
}

css_patch() {
  FILE="$1" node - <<'NODE'
const fs = require("fs");
const FILE = process.env.FILE;
let s = fs.readFileSync(FILE, "utf8");
const marker = "/* claude-ext-repatch: write-preview-scroll */";
if (s.includes(marker)) {
  console.log("  CSS: already present");
} else if (!s.includes("toolBodyWrapper_fKyNXw")) {
  console.log("  CSS: write wrapper class not found, SKIPPED");
} else {
  const css = marker +
    ".toolBodyWrapper_fKyNXw .toolBodyRowContent_ZUQaOA{mask-image:none;overflow:auto;max-height:240px;}" +
    ".toolBodyWrapper_fKyNXw .toolBodyRowContent_ZUQaOA pre{overflow:visible;}";
  fs.writeFileSync(FILE, s + css);
  console.log("  CSS: write-preview-scroll appended");
}
NODE
}

shopt -s nullglob
dirs=( $EXT_GLOB )
shopt -u nullglob
[ ${#dirs[@]} -eq 0 ] && { echo "No Claude Code extension found under ${EXT_GLOB}"; exit 1; }

# VS Code runs the highest-versioned build. Patch only that one; restore any other
# installed version to pristine (if we ever backed it up) so stale patched copies
# don't linger. Versions are sortable by `sort -V` on the dir name.
target="$(printf '%s\n' "${dirs[@]}" | sort -V | tail -1)"

for d in "${dirs[@]}"; do
  ver="$(basename "$d")"
  js="$d/webview/index.js"
  css="$d/webview/index.css"
  [ -f "$js" ] && [ -f "$css" ] || { echo "-> $ver (no webview bundle, skipping)"; continue; }

  if [ "$d" != "$target" ]; then
    # Not the active build: restore pristine if we have backups, then leave it.
    [ -f "$js.orig" ]  && cp "$js.orig"  "$js"
    [ -f "$css.orig" ] && cp "$css.orig" "$css"
    echo "-> $ver (not active build; restored to pristine if patched)"
    continue
  fi

  # --if-needed: skip silently when the active build already carries our patches
  # (avoids rewriting the bundle on every shell login). A patched bundle has the
  # openDiff method AND the CSS marker; if both are present we're done.
  if [ "${1:-}" = "--if-needed" ]; then
    if grep -q 'openDiff:(e,t)=>' "$js" 2>/dev/null && grep -q 'write-preview-scroll' "$css" 2>/dev/null; then
      exit 0
    fi
  fi

  echo "-> $ver (active build)"
  # One-time pristine backups, then re-derive from them so runs are idempotent.
  [ -f "$js.orig" ]  || cp "$js"  "$js.orig"
  [ -f "$css.orig" ] || cp "$css" "$css.orig"
  cp "$js.orig"  "$js"
  cp "$css.orig" "$css"

  js_patch "$js"
  css_patch "$css"

  if node --check "$js" 2>/dev/null; then
    echo "  syntax: OK"
  else
    echo "  syntax: FAILED -> rolling back index.js to pristine"
    cp "$js.orig" "$js"
  fi
done

echo
echo "Done. Reload VS Code (Cmd/Ctrl+Shift+P -> Developer: Reload Window) to apply."
