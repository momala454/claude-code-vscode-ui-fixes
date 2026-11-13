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
#   F (CSS) A user message is a sticky header, which is fine collapsed — but "Show more"
#           removes its height cap entirely, so the message grows past the viewport while
#           STAYING pinned, painting over every following message until you collapse it
#           again. Un-stick it only while expanded, so the rest of the transcript sits
#           after it in normal flow. Upstream, nothing to do with the other fixes.
#   E (HOST) The filename click (fix C) landed on line 1 instead of the edit. The host
#           resolves {searchText} with a single plain indexOf and does NOTHING when it
#           misses — and it missed constantly, because fix C sent old_string first, the
#           one text that is GONE from the file once the edit is applied. Now openFile
#           tries searchText then searchTextAlt, then falls back to the longest non-blank
#           line of the edit matched on trimmed document lines (so it still lands after
#           the file has been reformatted or re-edited). D and E are applied independently.
#   G (HOST) Fix B's native diff never worked on an ALREADY-APPLIED edit — i.e. on most
#           cards you click. The host builds the diff's right-hand side by re-applying the
#           edit to the file on disk, so once the edit is in, old_string is gone, the apply
#           throws "String not found in file" and the click falls back to the small in-panel
#           diff. For a card click the diff that matters is "file before the edit" vs "file
#           as it is now", so reconstruct the before-content by applying the edit REVERSED
#           and diff that against the real file. Opt-in via a marker diffToken sent by B1,
#           so the CLI's own open_diff keeps failing as before (it relies on that error).
#   H (JS)  A card only shows the file's basename, so a same-named file elsewhere (a plan in
#           the /tmp scratchpad vs the repo) can't be told apart before clicking. Hovering the
#           name now shows the full path (native title tooltip on the shared file-name link).
#           Independent of B/C: if either breaks, the other is still applied.
#
# Why local patches instead of waiting for upstream: the relevant GitHub issues
# (#59305, #59078, #3143, #48258, #65311) were all auto-closed by
# github-actions[bot] as duplicate/stale/not-planned with no human triage, so
# self-patching is the only reliable path. See conversation notes.

set -euo pipefail

# Modes: (none) patch now · --if-needed patch only what is not already patched, silently
# (the login hook) · --restore put every build back to its pristine backup, for "before"
# screenshots. An unknown argument used to be treated as "patch now", which silently did the
# opposite of what a typo asked for.
mode="${1:-}"
case "$mode" in
  "" | --if-needed | --restore) ;;
  *) echo "usage: $(basename "$0") [--if-needed|--restore]" >&2; exit 2 ;;
esac

# Put back every file we kept a pristine backup of; sets `restored` to 1 when something
# actually changed, so callers can stay quiet otherwise. Restoring a build that is already
# pristine would rewrite three multi-MB bundles and print a line on every single login.
# `return 0` is deliberate: the && chain above it ends non-zero when the last file was
# already pristine, which under `set -e` would abort the script at the call site.
# A truncated or corrupt install fails both ways — its anchors cannot match AND it cannot
# parse — so "bundle shape changed" and "syntax FAILED" would both point at the wrong
# culprit. Returns 0, and explains, when the PRISTINE backup is itself unparseable. Called
# only on failure paths, so a normal run pays no extra parse.
pristine_broken() {
  [ -f "$1.orig" ] || return 1
  # Through stdin, not by path: node picks the module format from the file EXTENSION and
  # refuses `.orig` outright (ERR_UNKNOWN_FILE_EXTENSION), which made every pristine backup
  # look corrupt and sent each JS abort down the "reinstall the extension" red herring.
  node --check < "$1.orig" 2>/dev/null && return 1
  echo "    NOTE: $(basename "$1") does not parse before any edit of ours ($(stat -c %s "$1.orig") bytes)."
  echo "    That is a corrupt install, not a patch problem — reinstall the extension."
  return 0
}

restore_build() {
  local f
  restored=0
  for f in "$@"; do
    [ -f "$f.orig" ] && ! cmp -s "$f" "$f.orig" && { cp "$f.orig" "$f"; restored=1; }
  done
  return 0
}

# Where VS Code keeps its extensions. Several roots can be live at once, and which one is
# in play depends on how the project was opened: over Remote-WSL the extension runs INSIDE
# wsl (~/.vscode-server, linux-x64 build), while a project opened from a WINDOWS folder runs
# it on the Windows side (%USERPROFILE%\.vscode, win32-x64 build) and never touches
# ~/.vscode-server at all — which is why those windows kept showing unpatched cards. Same
# bundles, same anchors, different tree; both are writable from wsl, so patch every root.
#
# The Windows profiles are found through the drives wsl already mounts for us, read out of
# /proc/mounts (fstype drvfs on wsl1, 9p with aname=drvfs on wsl2), so no drive letter is
# assumed; a mount with no Users directory is not a drive root and is skipped. Every profile
# that has the extension installed gets patched — set CLAUDE_EXT_WIN_HOME to a single
# Windows home to skip the search and restrict it to that one.
ext_roots() {
  local r p mp
  for r in "${HOME}/.vscode-server" "${HOME}/.vscode-server-insiders"; do
    [ -d "$r/extensions" ] && printf '%s\n' "$r/extensions"
  done
  if [ -n "${CLAUDE_EXT_WIN_HOME:-}" ]; then
    for p in "${CLAUDE_EXT_WIN_HOME}"/.vscode*/extensions; do
      [ -d "$p" ] && printf '%s\n' "$p"
    done
    return 0
  fi
  [ -r /proc/mounts ] || return 0
  local me="${USER:-}" mine=() other=() prof
  me="${me,,}"
  while read -r mp; do
    [ -d "$mp/Users" ] || continue
    for p in "$mp"/Users/*/.vscode*/extensions; do
      [ -d "$p" ] || continue
      prof="$(basename "$(dirname "$(dirname "$p")")")"
      if [ -n "$me" ] && [ "${prof,,}" = "$me" ]; then
        mine+=( "$p" )
      else
        # Someone else's profile: only worth touching if the extension is really installed
        # there, and only when we could not find our own (see below).
        compgen -G "$p/anthropic.claude-code-*" >/dev/null && other+=( "$p" )
      fi
    done
  done < <(awk '$3=="drvfs"||($3=="9p"&&$4~/aname=drvfs/){print $2}' /proc/mounts)
  # Prefer the Windows profile whose name matches this login name — writing into another
  # account's profile (a second user, or an old Users tree left on a secondary drive) would
  # patch bundles and drop ~11 MB of .orig backups somewhere nobody asked for. Fall back to
  # the profiles that do have the extension only when no name matches, which is the case of
  # a Windows account named differently from the wsl one; CLAUDE_EXT_WIN_HOME settles it.
  if [ ${#mine[@]} -gt 0 ]; then
    printf '%s\n' "${mine[@]}"
  elif [ ${#other[@]} -gt 0 ]; then
    printf '%s\n' "${other[@]}"
  fi
}

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
// `language` is OPTIONAL: 2.1.319 dropped that prop (the component now derives the language
// from filePath itself), and requiring it is what broke B2/B3/B4 there. Group 4 is then
// undefined, here and in the click handler alike, so the scope cross-check still holds.
const diffM  = s.match(new RegExp(`function (${ID})\\(\\{original:(${ID}),modified:(${ID}),(?:language:(${ID})="plaintext",)?filePath:(${ID})\\}\\)`));
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
// Searched INSIDE the diff component only (from its signature on), not across the bundle:
// without `language` the shape is just three locals that are the commonest minified names
// (e,t,n), so an unrelated `x=()=>{f({original:e,modified:t,filePath:n})}` earlier in the
// bundle would pass the scope cross-check below, get patched instead, and leave the real
// handler untouched while the script reports success (the injected `typeof $openFn` cannot
// throw, so nothing would even break). The handler sits ~2.1 KB into the component on
// 2.1.318/319; the 10 KB window fails CLOSED (B3 not found, abort) if it ever moves further.
const clickH = diffM ? s.slice(diffM.index, diffM.index + 10000).match(new RegExp(`(${ID})=\\(\\)=>\\{(${ID})\\(\\{original:(${ID}),modified:(${ID}),(?:language:(${ID}),)?filePath:(${ID})\\}\\)\\}`)) : null;
const clickVar = clickH ? clickH[1] : null;
const modalFn  = clickH ? clickH[2] : null;

// The connection's openDiff takes POSITIONAL arguments, and we need to pass a diffToken in
// the right slot (see fix G, host side) — so the POSITIONS are discovered too, not assumed:
// read the client method's signature and map each request key back to the parameter index it
// comes from. Hardcoding "the 7th argument" is the same mistake as hardcoding a minified
// name, just one level up. If this shape ever changes we fall back to the plain 4-argument
// call: fix B keeps working, only G's already-applied case goes back to the in-panel diff.
const clientM = s.match(new RegExp(`async openDiff\\(((?:${ID},){0,12}${ID})\\)\\{return\\(await this\\.sendRequest\\(\\{type:"open_diff",originalFilePath:(${ID}),newFilePath:(${ID}),edits:(${ID}),supportMultiEdits:(${ID}),channelId:(${ID}),diffToken:(${ID})\\}`));
const openDiffCall = (() => {
  if (!clientM) return null;
  const params = clientM[1].split(",");
  const idx = [2, 3, 4, 5, 7].map((i) => params.indexOf(clientM[i]));
  if (idx.includes(-1)) return null;
  const args = new Array(Math.max(...idx) + 1).fill("void 0");
  const [iOrig, iNew, iEdits, iMulti, iToken] = idx;
  args[iOrig] = "$a"; args[iNew] = "$a"; args[iEdits] = "$b"; args[iMulti] = "!1";
  args[iToken] = '"claude-ext-repatch:applied-edit/4"';
  return `$c.openDiff(${args.join(",")})`;
})();

const edits = [
  // The marker goes in the diffToken slot. It carries no meaning to upstream (an unknown
  // token only ever makes a later accept_diff return false, and we never send one), but it
  // lets host fix G recognise a click coming from a card and show the before/after diff of
  // an already-applied edit. Without G the marker is simply ignored.
  openerM && { name: "B1 fileOpener +openDiff",
    from: openerM[0],
    to:   openerM[0].replace(/\}\};startNewConversationTab$/, () => `},openDiff:($a,$b)=>{let $c=this.comms.connection.value;if($c)return ${openDiffCall || "$c.openDiff($a,$a,$b,!1)"};return Promise.reject(Error("no connection"))}};startNewConversationTab`) },
  diffM && { name: "B2 diff component +onOpenFile",
    from: diffM[0],
    to:   diffM[0].slice(0, -2) + ",onOpenFile:$openFn})" },
  // Overlay tries the native diff (returns a promise); on reject — which happens when
  // the edit is ALREADY applied and open_diff can't find old_string on disk — fall
  // back to the original in-webview Monaco modal (modalFn) instead of doing nothing.
  clickH && { name: "B3 overlay -> onOpenFile + modal fallback",
    from: clickH[0],
    to:   `${clickVar}=()=>{let $m=()=>${modalFn}({original:${clickH[3]},modified:${clickH[4]},${clickH[5] ? `language:${clickH[5]},` : ""}filePath:${clickH[6]}});if(typeof $openFn=="function"){let $r=$openFn();if($r&&$r.catch)$r.catch($m);else if(!$r)$m()}else $m()}` },
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

// B/C are all-or-nothing among themselves; on failure they are dropped as a unit, but H below
// does not depend on them and is still applied on the pristine text.
const bcOk = failures.length === 0;
if (!bcOk) {
  console.log(`  JS:  B/C ABORTED, not applied — bundle shape changed. Failed: ${failures.join("; ")}`);
  work = s;
}

// H: hovering a card's file name shows the FULL path as a native tooltip. The card only shows
// the basename, so a file of the same name elsewhere (a plan in the session's /tmp scratchpad
// vs one in the repo) is indistinguishable until you click it. Every card renders that name
// through one link component, `({onAction,className,style,children}) => <a href="#">`, which
// passes no title through; each call site's onAction is `()=>this.opener.open(<path>, ...)`,
// so the path to show is already the first argument there. Both the component and its call
// sites are found by source-level names (onAction, opener.open); the component name and the
// path expressions are captured. Independent of B/C: a break here only loses the tooltip.
const linkM = s.match(new RegExp(`function (${ID})\\(\\{onAction:(${ID}),className:(${ID}),style:(${ID}),children:(${ID})\\}\\)\\{return (${ID})\\("a",\\{href:"#",className:\\3,style:\\4,`));
const linkSite = linkM ? new RegExp(`\\(${reEsc(linkM[1])},\\{onAction:\\(\\)=>this\\.opener\\.open\\(([A-Za-z0-9_$.]+)(?=[,)])`, "g") : null;
const linkSites = linkSite ? work.match(linkSite) || [] : [];
let hNote;
if (!linkM || linkSites.length === 0) {
  hNote = `H SKIPPED — ${!linkM ? "file-name link component" : "its opener.open call sites"} not found (full-path tooltip)`;
} else if (work.split(linkM[0]).length - 1 !== 1) {
  hNote = `H SKIPPED — link component anchor x${work.split(linkM[0]).length - 1} (full-path tooltip)`;
} else {
  const [whole, fn, onA, cls, sty, kids, jsx] = linkM;
  work = work.replace(whole, () => `function ${fn}({onAction:${onA},className:${cls},style:${sty},children:${kids},title:$hoverPath}){return ${jsx}("a",{href:"#",className:${cls},style:${sty},title:$hoverPath,`);
  work = work.replace(linkSite, (_, p) => `(${fn},{title:${p},onAction:()=>this.opener.open(${p}`);
  hNote = `H full-path tooltip [link=${fn}, ${linkSites.length} call sites]`;
}

if (!bcOk && hNote.startsWith("H SKIPPED")) {
  console.log(`  JS:  ${hNote}`);
  process.exit(3); // nothing applied: signal the shell wrapper to leave the file pristine
}

fs.writeFileSync(FILE, work);
console.log(bcOk
  ? `  JS:  ${edits.length}/${edits.length} B/C edits applied [diff=${diffFn}, edit=${editTag}, click=${clickVar}->${modalFn}]; ${hNote}`
    + (openDiffCall ? "" : "\n  JS:  note — openDiff client signature not recognised, marker not sent (host fix G will stay idle)")
  : `  JS:  ${hNote}`);
// 4 = B/C dropped but H written: the shell keeps the file and still checks its syntax.
if (!bcOk) process.exit(4);
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
// A and F are independent blocks with their own marker, accumulated then written once.
let out = s;
const notes = [];

if (out.includes(marker)) {
  notes.push("A already present");
} else if (!row || !wrap) {
  notes.push(`A SKIPPED — ${!row ? "clipped preview rule" : "Write tool wrapper class"} not found`);
} else {
  out += marker +
    `.${wrap[1]} .${row[1]}{mask-image:none;overflow:auto;max-height:240px;}` +
    `.${wrap[1]} .${row[1]} pre{overflow:visible;}`;
  notes.push(`A appended [wrap=${wrap[1]}, row=${row[1]}]`);
}

// Fix F: a user message is a STICKY header (position:sticky; top:0; z-index:2) so you can
// still see your question while reading the answer. Harmless while the message is
// collapsed; but "Show more" drops the height cap entirely (the component sets no
// max-height when expanded), so the message becomes taller than the viewport AND stays
// pinned — it then paints over every following message and nothing after it is reachable
// until you collapse again. Un-stick it exactly while it is expanded: the "Show less"
// button only exists in the DOM in that state, so `:has()` on it is a precise flag. The
// expanded message then sits in normal flow and the rest of the transcript comes AFTER it,
// which is the point — no height cap, no inner scrollbar. Collapsed, it stays sticky.
// `:has()` is already used 16x by upstream's own CSS here, so support is not a question.
// Both hashes are discovered: the sticky one from the CSS rule that must really be
// position:sticky (self-validating), the button from the expandable module's own object,
// with a backreference so both keys have to share one hash.
const markerF = "/* claude-ext-repatch: expanded-message-unstick */";
const sticky = [...new Set([...out.matchAll(/\.stickyHeader_([\w-]+)\{[^}]*position:sticky[^}]*\}/g)].map((m) => m[1]))];
const exp = js.match(/\{expandableContainer:"expandableContainer_([\w-]+)"[^{}]*collapseButton:"collapseButton_\1"\}/);

if (out.includes(markerF)) {
  notes.push("F already present");
} else if (sticky.length !== 1 || !exp) {
  notes.push(`F SKIPPED — ${sticky.length !== 1 ? `sticky message rule x${sticky.length}` : "expandable module"} not found`);
} else {
  out += markerF + `.stickyHeader_${sticky[0]}:has(.collapseButton_${exp[1]}){position:static;}`;
  notes.push(`F appended [sticky=stickyHeader_${sticky[0]}, button=collapseButton_${exp[1]}]`);
}

if (out !== s) fs.writeFileSync(FILE, out);
console.log(`  CSS: ${notes.join("; ")}`);
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
// reformatted or re-edited since the card was produced), fall back to a single line of the
// edit matched against trimmed document lines. Only the reveal is rewritten; the `heading`
// and `startLine` branches after it are untouched.
// The fallback must not jump somewhere plausible and wrong (same rule as G's gate). It used
// to pool the lines of BOTH sides and take the longest one present anywhere: on a card that
// turned a `for (const item of this.items.values()) {` loop into a reduce, that removed loop
// line still existed in another method, and the click landed there (seen 2026-11-09). So:
// the inserted side (searchText = new_string) is tried before the removed one, and a line
// only counts when it occurs EXACTLY ONCE in the document — an ambiguous line is skipped for
// the next one. When nothing is certain the file opens without a jump, as upstream does.
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
    + `if($at===-1)for(let $s of [${loc}.searchText,${loc}.searchTextAlt]){if(typeof $s!="string")continue;`
    + `let $c=[];for(let $l of $s.split("\\n")){let $t=$l.trim();if($t.length>=8&&!$c.includes($t))$c.push($t)}`
    + `$c.sort(($a,$b)=>$b.length-$a.length);`
    + `for(let $t of $c){let $hit=-1,$n=0;for(let $i=0;$i<$doc.lineCount;$i++)if($doc.lineAt($i).text.trim()===$t){$n++;if($n>1)break;$hit=$i}`
    + `if($n===1){$at=$doc.offsetAt(new ${ns}.Position($hit,0)),$len=$doc.lineAt($hit).text.length;break}}`
    + `if($at!==-1)break}`
    + `if($at!==-1){let $p=$doc.positionAt($at),$q=$doc.positionAt($at+$len),$r=new ${ns}.Range($p,$q);`
    + `$ed.revealRange($r,${ns}.TextEditorRevealType.InCenter),$ed.selection=new ${ns}.Selection($p,$q)}}`;
})();
const eN = eFrom === null ? 0 : s.split(eFrom).length - 1;

// Fix G (host): make the native diff (fix B) work on an ALREADY-APPLIED edit. The host
// builds the right-hand side by re-applying the edit to the file on disk — fine for a
// PENDING edit, impossible once the edit is in the file: old_string is gone, the apply
// throws "String not found in file" and the webview falls back to the in-panel diff. (In
// the rarer case where new_string still contains old_string verbatim, the apply does not
// throw and produces a DOUBLE-applied right-hand side — a diff of a file that never
// existed.) For a card click the diff that matters is "before the edit" vs "as it is now",
// so: reconstruct the before-content by applying the edit REVERSED, and prove it really is
// the before-state by re-applying the edit forward and demanding the current file back
// verbatim (that round-trip is what tells an applied edit from a merely similar pending
// one). Then diff it against the REAL file, so the right-hand side has the file's own line
// numbers. Strictly opt-in on the marker diffToken B1 sends: the CLI's own open_diff calls
// keep throwing exactly as today, because the CLI needs that error.
//
// The anchor is the diff helper from its signature through the apply call. Every name in it
// is minified — the 12 parameters included — so all of them are capture groups. Matching
// the whole prologue VERBATIM broke on 2.1.318, which only reshuffled it (title split into
// its own local, a new "file not read" branch), so the prologue is now a lazy span checked
// piece by piece below: what G needs from it is found by its source-level literals ("diff
// from", .Uri.file, .getText(), "leftTempFileProvider.createFile"), not by its layout.
// 1=fn, 2..13=params (output, leftProvider, rightProvider, originalFilePath, newFilePath,
// edits, supportMultiEdits, acceptEvent, abortSignal, panelRegistry, channelId, diffToken),
// 14=the prologue, 15=applied content, 16=the apply function, 17=left content.
// The token is the contract between B1 (webview) and G (host), so it carries a REVISION:
// bump it on every change to either side's logic. It is also what --if-needed greps for, so
// bumping it is what makes an install patched by an older revision of this script look
// unpatched and get redone. Without that, a changed injection silently never reaches a
// machine that only ever runs --if-needed from its login hook.
const MARK = "claude-ext-repatch:applied-edit/4";
const reEsc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, (c) => "\\" + c);
const g = s.match(new RegExp(
  `async function (${ID})\\(${Array.from({ length: 12 }, () => `(${ID})`).join(",")}\\)\\{`
  + `((?:(?!async function )[\\s\\S]){0,2500}?)`
  + `let (${ID})=(${ID})\\((${ID}),\\7\\),`));
// Each piece G relies on must be found in the prologue, tied to the captured parameters:
// the title passed to the "diff from" log, the vscode namespace from Uri.file(originalPath),
// the left content being the open document's text, the left provider's createFile fallback.
// 2.1.318 added a "file not read" flag: the left content is then NOT the file but the
// old_strings joined — reverting an edit against that would diff a file that never existed,
// so when that flag exists G stays out of the way while it is set.
const gPro = g ? g[14] : "";
const gTitle = g ? gPro.match(new RegExp(`${reEsc(g[2])}\\.info\\("diff from",${reEsc(g[5])},"to",${reEsc(g[6])},"as",(${ID})\\)`)) : null;
const gNs = g ? gPro.match(new RegExp(`(${ID})\\.Uri\\.file\\(${reEsc(g[5])}\\)`)) : null;
const gNotRead = g ? gPro.match(new RegExp(`if\\((${ID})\\)throw ${reEsc(g[17])}=`)) : null;
// The node fs module, taken from upstream's own dirty-document branch (`b=fs.readFileSync(path,
// "utf8")`). Optional: without it G falls back to the document text, i.e. to its old behaviour.
const gFs = g ? gPro.match(new RegExp(`(${ID})\\.readFileSync\\(${reEsc(g[5])},"utf8"\\)`)) : null;
// The call site proves the first three arguments really are output/left/right provider,
// hence that the positional reading of the other nine holds. If the shapes ever disagree,
// skip G rather than inject code reading the wrong parameters.
const gTail = g ? `let ${g[15]}=${g[16]}(${g[17]},${g[7]}),` : null;
const gOk = !!g && !!gTitle && !!gNs
  && s.includes(`${g[1]}(this.output,this.leftTempFileProvider,this.rightTempFileProvider,`)
  && new RegExp(`${reEsc(g[17])}=${ID}\\.getText\\(\\)`).test(gPro)
  && gPro.includes(`${g[2]}.info("leftTempFileProvider.createFile",${g[5]}`)
  && gPro.includes(`${g[3]}.createFile(${g[5]},`)
  && g[0].endsWith(gTail);
const gFrom = gOk ? g[0] : null;
const gTo = gFrom === null ? null : (() => {
  const [, , , lprov, , opath, , edits, , , , , , tok] = g;
  const title = gTitle[1], ns = gNs[1];
  // Everything below works on $L, the file AS IT IS ON DISK, not on upstream's left content.
  // For a clean document upstream takes the text of the document VS Code has open, and that
  // copy can be stale: a file outside the workspace is not watched, so after the CLI edited
  // it the extension host still held the pre-edit text 13 s later (seen 2026-11-09). The
  // edit then looked PENDING, the gate rightly declined, and the first click showed
  // upstream's diff; it only worked once the tab had been closed and reopened. Disk is
  // also what upstream itself reads for a DIRTY document, so this changes nothing there.
  // The right pane stays Uri.file: opening an editor on it makes VS Code reload a clean,
  // stale model from disk, so both panes agree. A read failure keeps upstream's content.
  const lcontent = "$L";
  const base = `let $L=${g[17]};` + (gFs ? `try{$L=${gFs[1]}.readFileSync(${opath},"utf8")}catch{}` : "");
  // $b = the reconstructed before-content; left pane = a temp doc keyed on the real path
  // (so it keeps the extension, hence the highlighting), right pane = the file itself.
  // Then put the cursor on the first line that differs, so a 2000-line file does not open
  // at line 1 — same intent as fix E, and a no-op if the diff editor already got there.
  // Decide FIRST whether the edit is already applied, and let old_string decide it: while
  // old_string is still in the file the edit is pending, upstream's forward apply is right,
  // and we must keep out of the way. The one exception is an old_string that is only there
  // because it is part of the new_string that WAS applied (old_string a substring of
  // new_string) — an occurrence covered by an occurrence of new_string does not count as
  // "still there". Skipping this test is not harmless: for a PENDING edit whose new_string
  // also appears earlier in the file (the same ALTER TABLE line in a migration's up() and
  // down(), say), reverting the first occurrence yields a before-state that round-trips
  // perfectly and shows the change at the wrong occurrence. For the same reason new_string
  // must occur EXACTLY ONCE: if it occurs twice, nothing in the card says which one was
  // edited, and reverting either produces a before-state that round-trips — so refuse to
  // guess and let the click fall back to the in-panel diff rather than point somewhere
  // plausible and wrong. That uniqueness demand is waived for a `replace_all` edit, where
  // every occurrence WAS edited: there is nothing to disambiguate, reverting them all
  // rebuilds the before-state exactly, and requiring one occurrence would just cost those
  // cards their diff.
  const inj = `if(${tok}===${JSON.stringify(MARK)}${gNotRead ? `&&!${gNotRead[1]}` : ""}){`
    + base
    + `let $ap=${edits}.length>0;`
    + `for(let $x of ${edits}){let $o=$x.oldString,$nw=$x.newString;`
    + `if(typeof $o!="string"||typeof $nw!="string"||$o===""||$nw===""){$ap=!1;break}`
    + `let $f=${lcontent}.indexOf($nw);if($f===-1){$ap=!1;break}`
    + `if(!$x.replaceAll&&${lcontent}.indexOf($nw,$f+1)!==-1){$ap=!1;break}`
    + `let $i=-1;while(($i=${lcontent}.indexOf($o,$i+1))!==-1){let $cv=!1,$j=-1;`
    + `while(($j=${lcontent}.indexOf($nw,$j+1))!==-1)if($i>=$j&&$i+$o.length<=$j+$nw.length){$cv=!0;break}`
    + `if(!$cv)break}`
    + `if($i!==-1){$ap=!1;break}}`
    + `if($ap){`
    + `let $r=[...${edits}].reverse().map(($x)=>({oldString:$x.newString,newString:$x.oldString,replaceAll:$x.replaceAll})),$b=null;`
    + `try{$b=${g[16]}(${lcontent},$r)}catch{}`
    + `if($b!==null&&$b!==${lcontent}){let $ok=!1;try{$ok=${g[16]}($b,${edits})===${lcontent}}catch{}`
    + `if($ok){let $lu=${lprov}.createFile(${opath},$b).uri,$ru=${ns}.Uri.file(${opath});`
    + `await ${ns}.commands.executeCommand("vscode.diff",$lu,$ru,${title}+" (before ↔ current)",{preview:!1});`
    + `try{let $k=0;while($k<$b.length&&$k<${lcontent}.length&&$b.charCodeAt($k)===${lcontent}.charCodeAt($k))$k++;`
    + `let $ln=${lcontent}.slice(0,$k).split("\\n").length-1,$te=${ns}.window.activeTextEditor;`
    // Compare the Uris, not the raw paths: on Windows fsPath comes back with backslashes and
    // its own drive-letter casing, so a string compare against the path the card sent never
    // matches and the reveal silently never happens. Uri.file() normalises both sides.
    + `if($te&&$te.document.uri.toString()===$ru.toString()){let $pp=new ${ns}.Position($ln,0),$rr=new ${ns}.Range($pp,$pp);`
    + `$te.revealRange($rr,${ns}.TextEditorRevealType.InCenter),$te.selection=new ${ns}.Selection($pp,$pp)}}catch{}`
    + `return}}}}`;
  return gFrom.slice(0, gFrom.length - gTail.length) + inj + gTail;
})();
const gN = gFrom === null ? 0 : s.split(gFrom).length - 1;

// D, E and G are INDEPENDENT (different functions, no shared injected symbol), so each is
// applied or skipped on its own: a future build breaking one anchor must not also cost the
// others. Each also degrades gracefully — without E the host still honours the new_string
// that fix C sends as searchText, it just loses the fallbacks; without G a card click on an
// applied edit falls back to the in-panel diff, as it did before G existed.
if (n !== 1 && eN !== 1 && gN !== 1) {
  console.log(`  HOST: ABORTED, no changes written — anchors D x${n} / E x${eN} / G x${gN} (bundle shape changed)`);
  process.exit(3);
}

let work = s;
const applied = [];
if (n === 1) { work = work.replace(from, () => to); applied.push(`D new-file view [fileName=${m[1]}]`); }
else { console.log(`  HOST: D SKIPPED — anchor x${n} (new-file view highlighting)`); }
if (eN === 1) { work = work.replace(eFrom, () => eTo); applied.push(`E openFile jump [loc=${e[1]}, ns=${e[8]}]`); }
else { console.log(`  HOST: E SKIPPED — anchor x${eN} (openFile jump-to-edit)`); }
if (gN === 1) { work = work.replace(gFrom, () => gTo); applied.push(`G applied-edit diff [fn=${g[1]}, apply=${g[16]}, token=${g[13]}${gNotRead ? `, notRead=${gNotRead[1]}` : ""}${gFs ? `, fs=${gFs[1]}` : ", NO fs: base = document text, may be stale"}]`); }
else { console.log(`  HOST: G SKIPPED — anchor x${gN} (native diff of an already-applied edit)`); }

fs.writeFileSync(FILE, work);
console.log(`  HOST: ${applied.length}/3 edits applied — ${applied.join("; ")}`);
NODE
}

# One run at a time. The login hook fires on every shell, so two terminals opened together
# ran two patchers over the same files — one copying .orig over index.js while the other was
# reading it — which produced spurious anchor failures and interleaved logs. The second run
# waits, then finds everything patched and (under --if-needed) does nothing.
exec 9>"${HOME}/.claude-ext-repatch.lock"
flock 9

shopt -s nullglob
mapfile -t roots < <(ext_roots | awk '!seen[$0]++')
dirs=()
for root in "${roots[@]}"; do dirs+=( "$root"/anthropic.claude-code-* ); done
shopt -u nullglob
[ ${#dirs[@]} -eq 0 ] && {
  echo "No Claude Code extension found. Looked under:"
  printf '  %s\n' "${roots[@]:-(no extensions directory at all)}"
  exit 1
}

# Patch the TWO highest-versioned builds, not just the newest one, and restore anything
# older. Patching only the newest silently broke the RUNNING VS Code window whenever an
# extension update landed mid-session: the update installs the new build, this script (from
# the login hook) then reverts the build the window is still executing, and the webview
# re-reads it from disk the next time the panel is hidden and shown. The fixes vanish with
# no message, and the only clue is that clicking a card stops sending its RPC at all. Two
# builds covers it — the running window is on the previous version, the next reload lands on
# the new one — without leaving patched copies behind for every version ever installed.
# Per ROOT, not overall: the wsl-side and the Windows-side installs update independently, so
# the newest two of one must not supersede the other's.
keep=""
for root in "${roots[@]}"; do
  shopt -s nullglob
  rdirs=( "$root"/anthropic.claude-code-* )
  shopt -u nullglob
  [ ${#rdirs[@]} -eq 0 ] && continue
  keep+="$(printf '%s\n' "${rdirs[@]}" | sort -V | tail -2)"$'\n'
done
touched=0

for d in "${dirs[@]}"; do
  # Several roots can hold the same version, so name the side — and, on the Windows side, the
  # profile — otherwise two lines read identically and a failure can't be attributed.
  case "$d" in
    "$HOME"/*) ver="$(basename "$d") [wsl]" ;;
    *)         ver="$(basename "$d") [windows:$(basename "${d%/.vscode*/extensions/*}")]" ;;
  esac
  js="$d/webview/index.js"
  css="$d/webview/index.css"
  host="$d/extension.js"
  [ -f "$js" ] && [ -f "$css" ] || { echo "-> $ver (no webview bundle, skipping)"; continue; }

  # --restore applies to EVERY build, patched or not, and undoes all three bundles — the
  # webview pair and the host, which is the whole point: with the host left patched the
  # "before" state is not one (D/E/G would still be in effect).
  if [ "$mode" = "--restore" ]; then
    restore_build "$js" "$css" "$host"
    if [ "$restored" = 1 ]; then echo "-> $ver (restored to pristine)"; touched=1; fi
    continue
  fi

  if ! printf '%s\n' "$keep" | grep -qxF "$d"; then
    # Older than the two builds we keep patched: undo our edits, once.
    restore_build "$js" "$css" "$host"
    if [ "$restored" = 1 ]; then echo "-> $ver (superseded; restored to pristine)"; fi
    continue
  fi

  # --if-needed: skip silently when this build already carries our patches
  # (avoids rewriting the bundle on every shell login). A fully patched install has
  # the webview openDiff method, the CSS marker, AND the host new-file-view fix.
  # Each marker is a fragment of code WE inject, never a minified name from the bundle,
  # so it stays valid across builds (the old host marker embedded the local `n`).
  if [ "${1:-}" = "--if-needed" ]; then
    if grep -qF 'openDiff:($a,$b)=>' "$js" 2>/dev/null \
       && grep -qF ',title:$hoverPath}' "$js" 2>/dev/null \
       && grep -qF 'write-preview-scroll' "$css" 2>/dev/null \
       && grep -qF 'expanded-message-unstick' "$css" 2>/dev/null \
       && { [ ! -f "$host" ] || grep -qF '$z=$q.lastIndexOf(".")' "$host" 2>/dev/null; } \
       && { [ ! -f "$host" ] || grep -qF 'if($n===1){$at=$doc.offsetAt(new' "$host" 2>/dev/null; } \
       && { [ ! -f "$host" ] || grep -qF 'claude-ext-repatch:applied-edit/4' "$host" 2>/dev/null; }; then
      continue  # not `exit`: the other kept build may still need patching
    fi
  fi

  echo "-> $ver (patching)"
  touched=1
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

  if [ "$js_rc" -eq 4 ]; then
    pristine_broken "$js" || true
  fi
  if [ "$js_rc" -ne 0 ] && [ "$js_rc" -ne 4 ]; then
    echo "  -> leaving webview bundle PRISTINE (JS patch aborted; CSS not applied)"
    pristine_broken "$js" || true
    cp "$js.orig"  "$js"
    cp "$css.orig" "$css"
  elif ! node --check "$js" 2>/dev/null; then
    cp "$js.orig"  "$js"
    cp "$css.orig" "$css"
    echo "  syntax: FAILED -> rolled back BOTH webview files to pristine"
    pristine_broken "$js" || true
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
      pristine_broken "$host" || true
      cp "$host.orig" "$host"
    elif ! node --check "$host" 2>/dev/null; then
      cp "$host.orig" "$host"
      echo "  host syntax: FAILED -> rolled back extension.js to pristine"
      pristine_broken "$host" || true
    else
      echo "  host syntax: OK"
    fi
  else
    echo "  HOST: extension.js not found, SKIPPED"
  fi
done

# Stay silent when there was nothing to do (nothing patched, nothing to put back): --if-needed
# runs from the login hook on every
# shell, and a reload reminder that reloading would not change anything is just noise.
if [ "$touched" = 1 ]; then
  echo
  if [ "$mode" = "--restore" ]; then
    echo "Done — bundles are pristine again. Reload VS Code (Cmd/Ctrl+Shift+P -> Developer:"
    echo "Reload Window) to see the UNPATCHED extension; re-run without --restore to patch."
  else
    echo "Done. Reload VS Code (Cmd/Ctrl+Shift+P -> Developer: Reload Window) to apply."
  fi
fi
