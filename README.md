# claude-code-vscode-ui-fixes

Local patches for three diff/preview UX shortcomings in the **Claude Code VS Code extension**.

These are applied to the extension's webview bundle on *your own machine*. The repo
contains **only the patch script** — never any of Anthropic's code (see
[Legal](#legal)).

## The problems it fixes

When the Claude Code extension shows tool activity in its panel:

| # | Symptom | Fix |
|---|---------|-----|
| **A** | A **Write** (new file) preview is clipped to ~2–3 lines with no way to scroll. | Make the Write preview a scrollable, taller box. |
| **B** | Clicking an **Edit** diff card shows a tiny in-panel diff with no surrounding context. | Clicking it now opens VS Code's **native diff** (real file ↔ file-with-edit), with full context and real line numbers. Falls back to the original in-panel diff if the edit is already applied. |
| **C** | Clicking the Edit card's **filename** opens the file at line 1. | It now jumps to the changed line. |

### Why patch locally instead of waiting for upstream?

The matching GitHub issues
([#59305](https://github.com/anthropics/claude-code/issues/59305),
[#59078](https://github.com/anthropics/claude-code/issues/59078),
[#3143](https://github.com/anthropics/claude-code/issues/3143),
[#48258](https://github.com/anthropics/claude-code/issues/48258),
[#65311](https://github.com/anthropics/claude-code/issues/65311))
were all auto-closed by `github-actions[bot]` as duplicate/stale/not-planned — none
got human triage. Self-patching is currently the only reliable path.

## How it works

The extension ships a **minified, closed-source** webview bundle
(`webview/index.{js,css}`). Fix B reuses an RPC the extension **already implements**
internally (`open_diff` → `vscode.diff`) but never wires to the diff card's click.
The script:

- patches **only the highest-versioned** installed build;
- keeps a one-time pristine backup (`index.js.orig` / `index.css.orig`);
- always re-derives from that backup, so it's **idempotent**;
- matches code by unique anchor strings — if an anchor is missing (e.g. after a big
  upstream rewrite) it **skips that fix and prints `SKIPPED`** rather than corrupting
  the bundle;
- verifies `node --check` and rolls the JS back if it somehow doesn't parse.

## Install

```bash
git clone https://github.com/<you>/claude-code-vscode-ui-fixes.git
cd claude-code-vscode-ui-fixes
./install.sh
```

Then **fully reload VS Code**: `Cmd/Ctrl+Shift+P` → *Developer: Reload Window*
(a plain window reload doesn't always reload the extension host — a full restart is
the safe bet).

`install.sh` copies the patcher to `~/.local/bin/`, runs it once, and adds a
backgrounded login hook to `~/.profile` so the patches are **re-applied automatically
after an extension update** (it's a no-op when already patched).

### Manual use

```bash
claude-ext-repatch.sh            # patch the active build now
claude-ext-repatch.sh --if-needed  # only patch if not already patched (used by the hook)
```

### Uninstall

```bash
./install.sh --uninstall
```

Removes the login hook and the installed script. To drop the patches themselves,
reinstall the extension (or restore each `webview/index.{js,css}.orig`) and reload
VS Code.

## Limitations (honest)

- **Linux / WSL2 only** right now (paths under `~/.vscode-server/extensions/`).
  macOS/Windows paths differ and aren't handled.
- After an extension **update during a running VS Code session**, the patch is
  re-applied at your next login, but you still need to reload/restart VS Code to
  load the new bundle.
- Fix B's native diff needs the edit's "before" text to still exist in the file. For
  an **already-applied** edit it can't reconstruct it, so it falls back to the
  original in-panel diff. The full-file-context diff is best on a **pending** edit.
- Anchor strings are tied to the minified bundle. A major upstream rewrite will make
  some fixes `SKIPPED` — that's the signal to re-locate them, not a breakage.
- The webview never receives the full file content (only the changed hunk), so an
  *inline* context preview is structurally impossible; only the host-side native diff
  (fix B) has real context.

## Legal

The Claude Code extension is `© Anthropic PBC. All rights reserved.` This repository
**does not contain or redistribute any of Anthropic's code**. It only ships a script
that edits, in place, a bundle you have already installed yourself. Run it at your own
risk; it backs up the original files before touching them. Not affiliated with or
endorsed by Anthropic.

## License

MIT — applies to the contents of this repository (the script and docs) only.
