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
#           (Edit header passes {searchText:new_string||old_string, searchTextAlt:old_string}).
#   D (HOST) Clicking a Write/new-file card opens its content in a separate editor
#           tab with NO syntax highlighting. The host (extension.js) names that
#           virtual doc `<fileName> (<rand>)`, so the path ends in e.g. `.php (a1b2c3)`
#           -> no valid extension -> VS Code can't detect the language. Move the
#           `(<rand>)` BEFORE the extension so highlighting works.
#   E (HOST) The filename click (fix C) landed on line 1 instead of the edit. The host
#           resolves {searchText} with a single plain indexOf and does NOTHING when it
#           misses — and it missed constantly, because fix C sent old_string first, the
#           one text that is GONE from the file once the edit is applied. Now openFile
#           tries searchText then searchTextAlt, then falls back to the longest non-blank
#           line of the edit matched on trimmed document lines (so it still lands after
#           the file has been reformatted or re-edited). D and E are applied independently.
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

// Minification renames identifiers between releases (e.g. the diff component was
// "vXe" in 2.1.169, "MXe" in 2.1.172; the Edit tool tag was "r8" then "s8"). So we
// DISCOVER those names from the bundle instead of hardcoding them. The structural
// shapes (the destructuring, the createElement signature) are stable; only the
// identifiers move. $openFn is a collision-safe added param name (the single
// letters b,f,g,i,n,o,r,s,v,w,x,y are already bound inside the diff component).
// This includes the SHORT LOCALS inside those shapes (e,t,i,n,...): they are minified
// too, so they are capture groups below, never typed out. Hardcoding one is what
// silently killed fix D on 2.1.224 (its fileName local went from `n` to `i`).
const ID = "[A-Za-z0-9_$]+";
const reEsc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, (c) => "\\" + c);

// The fileOpener object: 1..3 = openContent params, 4 = its connection local.
const openerM = s.match(new RegExp(`openContent:\\((${ID}),(${ID}),(${ID})\\)=>\\{let (${ID})=this\\.comms\\.connection\\.value;if\\(\\4\\)return \\4\\.openContent\\(\\1,\\2,\\3\\);return Promise\\.resolve\\(void 0\\)\\}\\};startNewConversationTab`));
// Diff component: function NAME({original:_,modified:_,language:_="plaintext",filePath:_})
const diffM  = s.match(new RegExp(`function (${ID})\\(\\{original:(${ID}),modified:(${ID}),language:(${ID})="plaintext",filePath:(${ID})\\}\\)`));
const diffFn = diffM ? diffM[1] : null;
// Edit tool tag: the Edit body renders the diff via <jsxHelper>(<diffFn>,{original:t.old_string...});
// the Edit header is `name=<TAG>;header(_,t){return this.fileToolHeader(this.name,t.file_path,{searchText:t.new_string})}`
const editHdr = s.match(new RegExp(`name=(${ID});header\\((${ID}),(${ID})\\)\\{return this\\.fileToolHeader\\(this\\.name,\\3\\.file_path,\\{searchText:\\3\\.new_string\\}\\)\\}`));
const editTag = editHdr ? editHdr[1] : null;
// The Edit body's diff call; 1 = the local holding the tool input.
const bodyM = diffFn ? s.match(new RegExp(`\\(${reEsc(diffFn)},\\{original:(${ID})\\.old_string\\|\\|"",modified:\\1\\.new_string\\|\\|"",filePath:\\1\\.file_path\\|\\|""\\}\\)`)) : null;
// The diff component's click overlay calls a modal-open helper. Both the handler var and
// the helper are minified and rename across releases (was `v=()=>{p(...)}` in older builds,
// `C=()=>{p(...)}` in 2.1.191), so DISCOVER both instead of hardcoding. The destructured
// arg shape {original:_,modified:_,language:_,filePath:_} is the stable anchor.
const clickH = s.match(new RegExp(`(${ID})=\\(\\)=>\\{(${ID})\\(\\{original:(${ID}),modified:(${ID}),language:(${ID}),filePath:(${ID})\\}\\)\\}`));
const clickVar = clickH ? clickH[1] : null;
const modalFn  = clickH ? clickH[2] : null;

const edits = [
  openerM && { name: "B1 fileOpener +openDiff",
    from: openerM[0],
    to:   openerM[0].replace(/\}\};startNewConversationTab$/, () => `},openDiff:($a,$b)=>{let $c=this.comms.connection.value;if($c)return $c.openDiff($a,$a,$b,!1);return Promise.reject(Error("no connection"))}};startNewConversationTab`) },
  diffM && { name: "B2 diff component +onOpenFile",
    from: diffM[0],
    to:   diffM[0].slice(0, -2) + ",onOpenFile:$openFn})" },
  // Overlay tries the native diff (returns a promise); on reject — which happens when
  // the edit is ALREADY applied and open_diff can't find old_string on disk — fall
  // back to the original in-webview Monaco modal (modalFn) instead of doing nothing.
  clickH && { name: "B3 overlay -> onOpenFile + modal fallback",
    from: clickH[0],
    to:   `${clickVar}=()=>{let $m=()=>${modalFn}({original:${clickH[3]},modified:${clickH[4]},language:${clickH[5]},filePath:${clickH[6]}});if(typeof $openFn=="function"){let $r=$openFn();if($r&&$r.catch)$r.catch($m);else if(!$r)$m()}else $m()}` },
  // Edit body returns the openDiff promise from onOpenFile so the overlay can catch.
  // Anchor on `(<diffFn>,{...})` only — NOT the jsx helper before it. That helper used to
  // be `createElement(` (React classic runtime) and is now `b(` (automatic jsx runtime);
  // leaving it outside the anchor makes this robust to that structural compile change.
  bodyM && { name: "B4 Edit body -> native diff",
    from: bodyM[0],
    to:   bodyM[0].slice(0, -2) + `,onOpenFile:()=>this.opener.openDiff?this.opener.openDiff(${bodyM[1]}.file_path,[{oldString:${bodyM[1]}.old_string||"",newString:${bodyM[1]}.new_string||"",replaceAll:!!${bodyM[1]}.replace_all}]):void 0})` },
  // C: filename click jumps to the changed line. Target the EDIT tool's OWN header
  // (tag discovered above), NOT the generic shared header. Send BOTH sides of the edit:
  // the host does a plain indexOf and does nothing at all when it misses, so the primary
  // must be the text that is actually IN the file at click time. That is new_string --
  // by the time you click a card, the edit is normally already applied; old_string only
  // still exists while the edit is pending, so it is the fallback (see fix E, host side).
  editHdr && { name: "C  Edit header -> jump to changed line",
    from: editHdr[0],
    to:   `name=${editTag};header(${editHdr[2]},${editHdr[3]}){return this.fileToolHeader(this.name,${editHdr[3]}.file_path,{searchText:${editHdr[3]}.new_string||${editHdr[3]}.old_string,searchTextAlt:${editHdr[3]}.old_string||""})}` },
].filter(Boolean);

// ALL-OR-NOTHING: every expected edit must apply. A partial JS patch is worse than
// none (e.g. openDiff present but the diff component never receives onOpenFile -> the
// click does nothing). If discovery fails or any anchor doesn't match exactly once,
// we abort WITHOUT writing, leaving the pristine bundle (the caller already restored
// it from .orig).
const failures = [];
if (!openerM)  failures.push("fileOpener not found (B1)");
if (!diffFn)   failures.push("diff component not found (B2)");
if (!bodyM)    failures.push("Edit body diff call not found (B4)");
if (!editTag)  failures.push("Edit header not found (C)");
if (!clickVar) failures.push("diff click overlay handler not found (B3)");
// The overlay must live in the diff component's scope, else the $openFn param B2 adds is
// not visible where B3 reads it. Same destructured locals => same scope; if they ever
// drift apart, abort rather than inject a ReferenceError.
if (diffM && clickH && diffM.slice(2, 6).join() !== clickH.slice(3, 7).join()) {
  failures.push(`overlay locals [${clickH.slice(3, 7)}] outside diff component [${diffM.slice(2, 6)}] (B3)`);
}
if (bodyM && !s.includes("this.opener")) failures.push("this.opener not found (B4)");

let work = s;
for (const e of edits) {
  const n = work.split(e.from).length - 1;
  // Function replacer: a literal `$` in `to` must never be read as a substitution pattern.
  if (n === 1) { work = work.replace(e.from, () => e.to); }
  else { failures.push(`${e.name} (anchor x${n})`); }
}

if (failures.length) {
  console.log(`  JS:  ABORTED, no changes written — bundle shape changed. Failed: ${failures.join("; ")}`);
  process.exit(3); // signal the shell wrapper to leave the file pristine
}

fs.writeFileSync(FILE, work);
console.log(`  JS:  ${edits.length}/${edits.length} edits applied [diff=${diffFn}, edit=${editTag}, click=${clickVar}->${modalFn}]`);
NODE
}

css_patch() {
  FILE="$1" JSFILE="$2" node - <<'NODE'
const fs = require("fs");
const FILE = process.env.FILE;
let s = fs.readFileSync(FILE, "utf8");
const marker = "/* claude-ext-repatch: write-preview-scroll */";
// Both class names are CSS-module GENERATED hashes (like the minified identifiers, they
// move between builds), so both are DISCOVERED — and both must be, or the appended rule
// silently matches nothing. The clipped row comes from its own mask rule; the wrapper
// comes from the JS side, since SEVERAL components define a toolBodyWrapper_* and only
// the one on the class whose static toolName is "Write" is ours.
const js  = fs.readFileSync(process.env.JSFILE, "utf8");
const row = s.match(/\.(toolBodyRowContent_[\w-]+):not\([^)]*\)\{[^}]*max-height:60px[^}]*\}/);
const tag = js.match(/([A-Za-z0-9_$]+)="Write"/);
// Follow the DATA dependency rather than textual adjacency: the Write class body renders
// `className:`...${<styleVar>.toolBodyWrapper}`` -> then resolve that var's hash. Anchoring
// on "style object immediately followed by the class" broke on 2.1.267, which inserts a
// `k();` call between the two.
const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, (c) => "\\" + c);
const body = tag ? js.match(new RegExp(`class [A-Za-z0-9_$]+ extends [A-Za-z0-9_$]+\\{static toolName=${esc(tag[1])};[\\s\\S]{0,2000}?\\$\\{([A-Za-z0-9_$]+)\\.toolBodyWrapper\\}`)) : null;
const wrap = body ? js.match(new RegExp(`${esc(body[1])}=\\{toolBodyWrapper:"(toolBodyWrapper_[\\w-]+)"\\}`)) : null;
if (s.includes(marker)) {
  console.log("  CSS: already present");
} else if (!row || !wrap) {
  console.log(`  CSS: SKIPPED — ${!row ? "clipped preview rule" : "Write tool wrapper class"} not found`);
} else {
  const css = marker +
    `.${wrap[1]} .${row[1]}{mask-image:none;overflow:auto;max-height:240px;}` +
    `.${wrap[1]} .${row[1]} pre{overflow:visible;}`;
  fs.writeFileSync(FILE, s + css);
  console.log(`  CSS: write-preview-scroll appended [wrap=${wrap[1]}, row=${row[1]}]`);
}
NODE
}

# Fix D (HOST bundle extension.js): syntax highlighting in the "open in editor"
# view of a Write/new-file card. The host opens that view as a single read-only
# doc whose virtual path is `/temp/readonly/<fileName> (<rand>)` — the disambiguator
# is appended AFTER the extension, so the path ends in e.g. `.php (a1b2c3)` and VS
# Code can't detect the language -> plaintext, no colors. We move the `(<rand>)`
# to BEFORE the extension (`<base> (<rand>).php`) so the path keeps a real
# extension and language detection (hence highlighting) works again. Independent
# of the webview patches A/B/C — patched/rolled back on its own.
host_patch() {
  FILE="$1" node - <<'NODE'
const fs = require("fs");
const FILE = process.env.FILE;
let s = fs.readFileSync(FILE, "utf8");
const ID = "[A-Za-z0-9_$]+";

// The temp doc name is built once as: `${<fileName>||"Claude Code"} (${rand})`. The local
// holding the fileName is minified, so it is DISCOVERED, never hardcoded: it was `n` on
// 2.1.191 and `i` on 2.1.224, and hardcoding it is exactly what made this fix silently
// abort (highlighting went back to plaintext). Replace that template literal with an IIFE
// that inserts the random id before the file extension instead of after it. Our own names
// are $-prefixed to avoid colliding with the minified locals (e,t,r,i,n,s,o,a,l,u,d,m,v).
const m = s.match(/`\$\{([A-Za-z0-9_$]+)\|\|"Claude Code"\} \(\$\{Math\.random\(\)\.toString\(36\)\.substring\(2,8\)\}\)`/);
const from = m ? m[0] : null;
const to   = m ? `(()=>{let $q=${m[1]}||"Claude Code",$g=Math.random().toString(36).substring(2,8),$z=$q.lastIndexOf(".");return $z>0?$q.slice(0,$z)+" ("+$g+")"+$q.slice($z):$q+" ("+$g+")"})()` : null;

const n = from === null ? 0 : s.split(from).length - 1;

// Fix E (host): make openFile actually land on the edit. The host resolves a card's
// {searchText} with ONE plain indexOf and, when it misses, silently does nothing — the
// file just opens at line 1, which is the whole "I can't tell where the change was"
// symptom. Fix C now sends new_string as searchText plus old_string as searchTextAlt, so
// here we (1) try each candidate in turn, and (2) if neither survived verbatim (file
// reformatted or re-edited since the card was produced), fall back to the longest
// non-blank line of the edit matched against trimmed document lines. Only the reveal is
// rewritten; the `heading` and `startLine` branches after it are untouched.
// Every minified local is a capture group: 1=location, 2=document, 3=editor, 4=index,
// 5/6=positions, 7=range, 8=the vscode namespace.
const e = s.match(new RegExp(
  `if\\((${ID})\\?\\.searchText\\)\\{let (${ID})=(${ID})\\.document,(${ID})=\\2\\.getText\\(\\)\\.indexOf\\(\\1\\.searchText\\);`
  + `if\\(\\4!==-1\\)\\{let (${ID})=\\2\\.positionAt\\(\\4\\),(${ID})=\\2\\.positionAt\\(\\4\\+\\1\\.searchText\\.length\\),`
  + `(${ID})=new (${ID})\\.Range\\(\\5,\\6\\);\\3\\.revealRange\\(\\7,\\8\\.TextEditorRevealType\\.InCenter\\),`
  + `\\3\\.selection=new \\8\\.Selection\\(\\5,\\6\\)\\}\\}`));
const eFrom = e ? e[0] : null;
const eTo = e === null ? null : (() => {
  const [, loc, , ed, , , , , ns] = e;
  return `if(${loc}?.searchText){let $ed=${ed},$doc=$ed.document,$txt=$doc.getText(),$at=-1,$len=0;`
    + `for(let $s of [${loc}.searchText,${loc}.searchTextAlt]){if(typeof $s!="string"||$s.length===0)continue;`
    + `let $i=$txt.indexOf($s);if($i!==-1){$at=$i,$len=$s.length;break}}`
    + `if($at===-1){let $c=[];for(let $s of [${loc}.searchText,${loc}.searchTextAlt]){`
    + `if(typeof $s=="string")for(let $l of $s.split("\\n")){let $t=$l.trim();if($t.length>=8)$c.push($t)}}`
    + `$c.sort(($a,$b)=>$b.length-$a.length);`
    + `for(let $t of $c){for(let $i=0;$i<$doc.lineCount;$i++){let $l=$doc.lineAt($i).text;`
    + `if($l.trim()===$t){$at=$doc.offsetAt(new ${ns}.Position($i,0)),$len=$l.length;break}}if($at!==-1)break}}`
    + `if($at!==-1){let $p=$doc.positionAt($at),$q=$doc.positionAt($at+$len),$r=new ${ns}.Range($p,$q);`
    + `$ed.revealRange($r,${ns}.TextEditorRevealType.InCenter),$ed.selection=new ${ns}.Selection($p,$q)}}`;
})();
const eN = eFrom === null ? 0 : s.split(eFrom).length - 1;

// D and E are INDEPENDENT (different functions, no shared injected symbol), so each is
// applied or skipped on its own: a future build breaking E's anchor must not also cost us
// D's highlighting. E also degrades on its own — without it the host still honours the
// new_string that fix C sends as searchText, it just loses the fallbacks.
if (n !== 1 && eN !== 1) {
  console.log(`  HOST: ABORTED, no changes written — anchors D x${n} / E x${eN} (bundle shape changed)`);
  process.exit(3);
}

let work = s;
const applied = [];
if (n === 1) { work = work.replace(from, () => to); applied.push(`D new-file view [fileName=${m[1]}]`); }
else { console.log(`  HOST: D SKIPPED — anchor x${n} (new-file view highlighting)`); }
if (eN === 1) { work = work.replace(eFrom, () => eTo); applied.push(`E openFile jump [loc=${e[1]}, ns=${e[8]}]`); }
else { console.log(`  HOST: E SKIPPED — anchor x${eN} (openFile jump-to-edit)`); }

fs.writeFileSync(FILE, work);
console.log(`  HOST: ${applied.length}/2 edits applied — ${applied.join("; ")}`);
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
  host="$d/extension.js"
  [ -f "$js" ] && [ -f "$css" ] || { echo "-> $ver (no webview bundle, skipping)"; continue; }

  if [ "$d" != "$target" ]; then
    # Not the active build: restore pristine if we have backups, then leave it.
    [ -f "$js.orig" ]   && cp "$js.orig"   "$js"
    [ -f "$css.orig" ]  && cp "$css.orig"  "$css"
    [ -f "$host.orig" ] && cp "$host.orig" "$host"
    echo "-> $ver (not active build; restored to pristine if patched)"
    continue
  fi

  # --if-needed: skip silently when the active build already carries our patches
  # (avoids rewriting the bundle on every shell login). A fully patched install has
  # the webview openDiff method, the CSS marker, AND the host new-file-view fix.
  # Each marker is a fragment of code WE inject, never a minified name from the bundle,
  # so it stays valid across builds (the old host marker embedded the local `n`).
  if [ "${1:-}" = "--if-needed" ]; then
    if grep -qF 'openDiff:($a,$b)=>' "$js" 2>/dev/null \
       && grep -qF 'write-preview-scroll' "$css" 2>/dev/null \
       && { [ ! -f "$host" ] || grep -qF '$z=$q.lastIndexOf(".")' "$host" 2>/dev/null; } \
       && { [ ! -f "$host" ] || grep -qF '$at=$doc.offsetAt(new' "$host" 2>/dev/null; }; then
      exit 0
    fi
  fi

  echo "-> $ver (active build)"
  # One-time pristine backups, then re-derive from them so runs are idempotent.
  [ -f "$js.orig" ]   || cp "$js"   "$js.orig"
  [ -f "$css.orig" ]  || cp "$css"  "$css.orig"
  cp "$js.orig"  "$js"
  cp "$css.orig" "$css"

  # All-or-nothing: only touch CSS if the JS patch fully succeeded, and verify the
  # JS parses afterwards. Any failure leaves BOTH files pristine, so we never end up
  # in a half-patched state (which is worse than unpatched — e.g. a dead click).
  js_rc=0
  js_patch "$js" || js_rc=$?

  if [ "$js_rc" -ne 0 ]; then
    echo "  -> leaving webview bundle PRISTINE (JS patch aborted; CSS not applied)"
    cp "$js.orig"  "$js"
    cp "$css.orig" "$css"
  elif ! node --check "$js" 2>/dev/null; then
    echo "  syntax: FAILED -> rolling back BOTH webview files to pristine"
    cp "$js.orig"  "$js"
    cp "$css.orig" "$css"
  else
    css_patch "$css" "$js.orig"
    echo "  syntax: OK"
  fi

  # Fix D (host bundle) — independent of the webview patches above. Back up, re-derive
  # from pristine, patch, verify it parses; roll back this file alone on any failure.
  if [ -f "$host" ]; then
    [ -f "$host.orig" ] || cp "$host" "$host.orig"
    cp "$host.orig" "$host"
    host_rc=0
    host_patch "$host" || host_rc=$?
    if [ "$host_rc" -ne 0 ]; then
      echo "  -> leaving host bundle PRISTINE (HOST patch aborted)"
      cp "$host.orig" "$host"
    elif ! node --check "$host" 2>/dev/null; then
      echo "  host syntax: FAILED -> rolling back extension.js to pristine"
      cp "$host.orig" "$host"
    else
      echo "  host syntax: OK"
    fi
  else
    echo "  HOST: extension.js not found, SKIPPED"
  fi
done

echo
echo "Done. Reload VS Code (Cmd/Ctrl+Shift+P -> Developer: Reload Window) to apply."
