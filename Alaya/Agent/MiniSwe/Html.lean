import Alaya.Agent.MiniSwe.Session

/-!
A standalone HTML report of a whole trajectory forest.

Everything a data directory holds — the tree, each state's metadata, the messages it appended,
the workspace changes it made, and any verdict recorded against it — is serialized into one
self-contained file: the data as JSON in a `<script>` tag, with the page that renders it. No
network, no assets, so a report can be mailed, archived, or opened from a container.

Workspace changes carry the text of the files they touch when that is cheap (small, textual, and
not obviously machine-generated), so the report can show a line diff rather than just a list of
paths. The limits below keep a report from growing with an agent's virtual environment.
-/

namespace Alaya.Agent.MiniSwe.Html

open Alaya (Result Error)
open Alaya.Cas (Hash Store Change)

/-- Paths under these are listed but never carried, and never diffed line by line. -/
private def uninteresting : Array String :=
  #[".venv/", "__pycache__/", ".pytest_cache/", ".git/", "node_modules/", ".mypy_cache/"]

private def isUninteresting (path : String) : Bool :=
  uninteresting.any fun prefix' => (path.splitOn prefix').length > 1

/-- Largest file whose content is carried into the report, in bytes. -/
private def contentLimit : Nat := 60000

/-- Most changed paths listed for one state. -/
private def changeLimit : Nat := 300

private def jsonText? (bytes? : Option ByteArray) : Option String :=
  match bytes? with
  | none => none
  | some bytes =>
    if bytes.size > contentLimit then none
    else match String.fromUTF8? bytes with
      | some text => if text.any (· == '\x00') then none else some text
      | none => none

private def readText? (store : Store) (root? : Option Hash) (path : String) :
    Result (Option String) := do
  match root? with
  | none => pure none
  | some root => pure (jsonText? (← store.readPath root path))

/-- One workspace change, with the before and after text when both are cheap to carry. -/
private def changeJson (store : Store) (before? : Option Hash) (after? : Option Hash)
    (change : Change) : Result Lean.Json := do
  let path := change.path
  let kind := match change with
    | .added .. => "added" | .removed .. => "removed" | .modified .. => "modified"
  let carry := !isUninteresting path
  let old ← if carry then readText? store before? path else pure none
  let new ← if carry then readText? store after? path else pure none
  pure <| .mkObj [
    ("path", path), ("kind", kind),
    ("old", old.map Lean.Json.str |>.getD .null),
    ("new", new.map Lean.Json.str |>.getD .null)]

private def messageJson (message : Chat.Message) : Lean.Json :=
  match message with
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? calls =>
    .mkObj [
      ("role", "assistant"),
      ("content", content?.map Lean.Json.str |>.getD .null),
      ("calls", .arr (calls.map fun call =>
        .mkObj [
          ("name", call.name),
          ("command", match call.arguments.getObjVal? "command" with
            | .ok (.str command) => command
            | _ => call.invalidArguments?.getD call.arguments.compress)]))]
  | .tool _ content => .mkObj [("role", "tool"),
      ("content", match content with | .str text => text | other => other.compress)]

private def stateJson (store : Store) (hash : Hash) : Result Lean.Json := do
  let state ← Session.getState store hash
  let parentEnv? ← match state.parent? with
    | some parent => pure (some (← Session.getState store parent).env)
    | none => pure none
  let changes ← match parentEnv? with
    | none => pure #[]
    | some before => store.diff before state.env
  let shown := changes.extract 0 changeLimit
  let changesJson ← shown.mapM (changeJson store parentEnv? (some state.env))
  let evaluation := match state.evaluation? with
    | none => Lean.Json.null
    | some e => .mkObj [
        ("command", e.command), ("returncode", (e.returncode : Lean.Json)),
        ("elapsedMs", (e.elapsedMs : Lean.Json)), ("output", e.output),
        ("passed", e.passed)]
  pure <| .mkObj [
    ("hash", hash.hex),
    ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("kind", state.kind.toString),
    ("env", state.env.hex),
    ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("image", state.image?.map Lean.Json.str |>.getD .null),
    ("base", state.baseCommit?.map Lean.Json.str |>.getD .null),
    ("outcome", match state.outcome? with
      | none => .null
      | some o => .mkObj [("status", o.status), ("submission", o.submission)]),
    ("evaluation", evaluation),
    ("commands", .arr (state.commands.map fun command =>
      .mkObj [
        ("command", match command.command with
          | .str text => text | other => other.compress),
        ("returncode", (command.returncode : Lean.Json))])),
    ("messages", .arr (state.appended.map messageJson)),
    ("changes", .arr changesJson),
    ("changeCount", (changes.size : Lean.Json))]

private def styles : String :=
"*{box-sizing:border-box}
body{margin:0;font:13px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;
color:#1a1a1a;background:#fff}
code,pre,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px}
#layout{display:flex;height:100vh}
#side{width:440px;min-width:280px;max-width:65vw;display:flex;flex-direction:column;
border-right:1px solid #ddd;background:#fafafa;resize:horizontal;overflow:hidden}
#tools{display:flex;gap:5px;padding:8px;border-bottom:1px solid #e6e6e6;background:#f2f3f5}
#find{flex:1;min-width:0;padding:3px 7px;border:1px solid #ccc;border-radius:3px;font:inherit}
#found{align-self:center;font-size:11px;color:#777;white-space:nowrap}
button.tool{font-size:11px;padding:2px 8px;border:1px solid #ccc;background:#fff;
border-radius:3px;cursor:pointer;color:#444;white-space:nowrap}
button.tool:hover{background:#eef1f5}
#tree{flex:1;overflow:auto;padding:8px 8px 40vh}
#detail{flex:1;overflow:auto;padding:18px 22px}
h1{font-size:14px;margin:0 0 10px;letter-spacing:.02em;text-transform:uppercase;color:#666}
h2{font-size:13px;margin:22px 0 8px;text-transform:uppercase;letter-spacing:.03em;color:#666;
border-bottom:1px solid #eee;padding-bottom:4px}
/* A chain grows straight down at the same indentation; a fork is the only thing that indents,
   and only a fork draws a rail, so a line on the left always marks a set of siblings. */
.branch{border-left:2px solid #c3cbd4;margin-left:9px;padding-left:13px}
.forks{margin-top:2px}
.forks>.branch+.branch{margin-top:6px}
/* An elbow from the rail into the row that starts a branch, so the first state of a sibling
   cannot be mistaken for one more row of the branch above it. */
.branch>.node:first-child::before{content:'';position:absolute;left:-13px;top:11px;width:11px;
border-top:2px solid #c3cbd4}
.br{flex:none;margin-right:5px;padding:0 4px;border-radius:3px;background:#dde3ea;color:#4a5560;
font-size:10px;font-family:ui-monospace,monospace}
.hide{display:none}
.node{position:relative;display:flex;align-items:baseline;width:100%;text-align:left;border:0;
background:none;padding:2px 5px;border-radius:4px;cursor:pointer;font:inherit;color:inherit}
.node:hover{background:#eef1f5}
.node.on{background:#dce7f5;font-weight:600}
.node.hit{outline:1px solid #c8a02a;background:#fdf6e0}
.tw{flex:none;display:inline-flex;align-items:center;justify-content:center;width:16px;
height:14px;color:#5a6570;cursor:pointer;user-select:none}
.tw:hover{color:#000}
.tw.leaf{color:#b3bcc5;cursor:default}
.sum{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.count{flex:none;color:#8a94a0;font-size:11px;margin-left:6px}
.hash{color:#8a6d3b}
.ic{flex:none;display:inline-flex;align-items:center;justify-content:center;width:16px;
height:14px;margin-right:5px}
.i-root{color:#4a4a4a}.i-agent{color:#3a6ea5}.i-format_error{color:#b04a4a}
.i-intervention{color:#7a5aa5}.i-pass{color:#2f7d4f}.i-fail{color:#b02020}
.chip{display:inline-block;padding:0 6px;border-radius:9px;font-size:11px;margin-left:6px;
background:#eee;color:#444}
.chip.ok{background:#d8f0dd;color:#1c5c33}.chip.bad{background:#f7dcdc;color:#8a2b2b}
table.meta{border-collapse:collapse;margin-bottom:4px}
table.meta td{padding:2px 14px 2px 0;vertical-align:top}
table.meta td:first-child{color:#777;white-space:nowrap}
.msg{border:1px solid #e3e3e3;border-radius:5px;margin:8px 0;overflow:hidden}
.msg>.head{padding:4px 9px;background:#f4f6f8;font-size:11px;text-transform:uppercase;
letter-spacing:.04em;color:#555;border-bottom:1px solid #e3e3e3}
.msg>.body{padding:8px 10px}
pre{margin:0;white-space:pre-wrap;word-break:break-word}
.cmd{background:#1f2430;color:#e6e6e6;padding:8px 10px;border-radius:4px;margin:6px 0}
.cmd .rc{float:right;color:#9fb3c8}
.fold{position:relative}
.fold.closed .clip{max-height:16em;overflow:hidden}
.fold.closed .clip:after{content:'';position:absolute;left:0;right:0;bottom:26px;height:40px;
background:linear-gradient(transparent,#fff)}
.fold>button{margin-top:6px;font-size:11px;padding:2px 8px;border:1px solid #ccc;background:#fff;
border-radius:3px;cursor:pointer;color:#444}
.file{border:1px solid #e3e3e3;border-radius:5px;margin:6px 0}
.file>summary{padding:5px 9px;cursor:pointer;background:#f7f8fa;border-radius:4px}
.file[open]>summary{border-bottom:1px solid #e3e3e3}
.path{font-family:ui-monospace,monospace}
.tag{display:inline-block;width:14px;text-align:center;font-weight:700;margin-right:6px}
.added{color:#1c7c3c}.removed{color:#b02020}.modified{color:#8a6d00}
.stat{float:right;color:#777;font-size:11px}
.diff{padding:0;margin:0;overflow-x:auto}
.diff div{padding:0 9px;white-space:pre;font-family:ui-monospace,monospace;font-size:12px}
.diff .plus{background:#e6f6ea}.diff .minus{background:#fdeaea}.diff .gap{background:#f5f5f5;
color:#999;text-align:center}
.muted{color:#888}
.big{color:#888;font-style:italic;padding:6px 9px}"

private def script : String :=
"const data = JSON.parse(document.getElementById('data').textContent);
const byHash = new Map(data.states.map(s => [s.hash, s]));
const short = h => h.slice(0, 12);
const el = (tag, cls, text) => { const n = document.createElement(tag);
  if (cls) n.className = cls; if (text !== undefined) n.textContent = text; return n; };

function summary(state) {
  if (state.kind === 'root') return state.note || 'root';
  if (state.kind === 'evaluation') {
    const e = state.evaluation || {};
    return (e.passed ? 'pass' : 'fail ' + e.returncode) + '  ' + (e.command || '');
  }
  if (state.kind === 'intervention') return state.note || 'commit';
  if (state.kind === 'format_error') return 'format error';
  const c = (state.commands || [])[0];
  return c ? c.command.replace(/\\s+/g, ' ') : '(no command)';
}

/* --- the tree ---------------------------------------------------------
   A state's children are drawn below it, at the same indentation, for as long as the line does
   not branch: a run of a hundred turns reads as one column instead of a staircase off the right
   edge. A fork indents, one railed branch per child. Subtrees are built the first time they are
   opened and kept afterwards, so the page opens at the same speed whatever the forest weighs. */

const kids = new Map();
for (const s of data.states) {
  const key = s.parent || '';
  if (!kids.has(key)) kids.set(key, []);
  kids.get(key).push(s);
}
const childrenOf = hash => kids.get(hash) || [];

/** Number of states at or below `hash`, for the count on a collapsed node. */
const sizes = new Map();
function subtreeSize(hash) {
  if (sizes.has(hash)) return sizes.get(hash);
  let total = 1;
  for (const child of childrenOf(hash)) total += subtreeSize(child.hash);
  sizes.set(hash, total);
  return total;
}

const nodes = new Map();     // hash -> {row, rest, twisty, built, open}
const ROWS_AT_ONCE = 300;    // how much of a chain one expansion follows
const ROWS_AT_START = 300;   // how much of the forest is open when the page loads

/* A glyph per kind, on a 14x14 grid: a seed for a root, a prompt for an agent turn, a warning
   for a format error, a diamond for a hand-made commit, and a tick or cross for a verdict. */
const GLYPHS = {
  root: '<circle cx=\"7\" cy=\"7\" r=\"2.6\"/><circle cx=\"7\" cy=\"7\" r=\"5.6\" fill=\"none\"/>',
  agent: '<path d=\"M2.5 3.5L6 7l-3.5 3.5\" fill=\"none\"/><path d=\"M7.5 10.5h4\" fill=\"none\"/>',
  format_error: '<path d=\"M7 1.8L13 12H1z\" fill=\"none\"/><path d=\"M7 5.4v3\" fill=\"none\"/>' +
    '<circle cx=\"7\" cy=\"10.4\" r=\".8\" stroke=\"none\"/>',
  intervention: '<path d=\"M7 1.6L12.4 7 7 12.4 1.6 7z\" fill=\"none\"/>',
  pass: '<path d=\"M2.2 7.4l3.3 3.3L11.8 4\" fill=\"none\"/>',
  fail: '<path d=\"M3.2 3.2l7.6 7.6M10.8 3.2l-7.6 7.6\" fill=\"none\"/>'
};

function glyphOf(state) {
  if (state.kind !== 'evaluation') return state.kind;
  return state.evaluation && state.evaluation.passed ? 'pass' : 'fail';
}

function icon(state) {
  const key = glyphOf(state);
  const holder = el('span', 'ic i-' + key);
  holder.title = state.kind === 'evaluation'
    ? 'evaluation: ' + (key === 'pass' ? 'passed' : 'failed') : state.kind;
  holder.innerHTML = '<svg viewBox=\"0 0 14 14\" width=\"13\" height=\"13\" ' +
    'stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" ' +
    'stroke-linejoin=\"round\" fill=\"currentColor\">' + (GLYPHS[key] || GLYPHS.agent) +
    '</svg>';
  return holder;
}

/* Expanded, collapsed, and leaf, drawn rather than typed: a filled triangle is legible at this
   size in a way that a text arrow is not. */
const TWISTIES = {
  open: '<path d=\"M3 5h8l-4 4.5z\" stroke=\"none\"/>',
  closed: '<path d=\"M5 3v8l4.5-4z\" stroke=\"none\"/>',
  leaf: '<circle cx=\"7\" cy=\"7\" r=\"1.6\" stroke=\"none\"/>'
};

function twistyMarkup(which) {
  return '<svg viewBox=\"0 0 14 14\" width=\"12\" height=\"12\" fill=\"currentColor\">' +
    TWISTIES[which] + '</svg>';
}

function rowFor(state, sibling) {
  const row = el('div', 'node');
  row.dataset.hash = state.hash;
  const leaf = !childrenOf(state.hash).length;
  const twisty = el('span', 'tw' + (leaf ? ' leaf' : ''));
  twisty.innerHTML = twistyMarkup(leaf ? 'leaf' : 'open');
  const text = el('span', 'sum');
  text.append(el('span', 'hash', short(state.hash) + ' '), document.createTextNode(summary(state)));
  row.append(twisty);
  // Which way this is, out of the ways the parent forked.
  if (sibling) {
    const badge = el('span', 'br', (sibling.index + 1) + '/' + sibling.total);
    badge.title = 'branch ' + (sibling.index + 1) + ' of ' + sibling.total;
    row.append(badge);
  }
  row.append(icon(state), text);
  const commands = state.commands || [];
  const rc = commands.length ? commands[commands.length - 1].returncode : null;
  if (rc !== null && rc !== 0) row.append(el('span', 'chip bad', 'rc ' + rc));
  if (state.outcome) row.append(el('span', 'chip', state.outcome.status));
  const count = el('span', 'count');
  row.append(count);
  row.onclick = () => select(state.hash);
  twisty.onclick = event => { event.stopPropagation(); toggle(state.hash); };
  return { row, twisty, count };
}

/** Places one state's row, and an empty holder for everything below it. `sibling` is set when
the row starts one branch of a fork, which is what the elbow and the badge mark. */
function place(hash, container, sibling) {
  const { row, twisty, count } = rowFor(byHash.get(hash), sibling);
  const rest = el('div', 'rest');
  container.append(row, rest);
  const entry = { row, rest, twisty, count, built: false, open: false };
  nodes.set(hash, entry);
  return entry;
}

function mark(hash) {
  const entry = nodes.get(hash);
  const children = childrenOf(hash);
  if (!children.length) {
    entry.twisty.className = 'tw leaf';
    entry.twisty.innerHTML = twistyMarkup('leaf');
    entry.count.textContent = '';
    return;
  }
  entry.twisty.innerHTML = twistyMarkup(entry.open ? 'open' : 'closed');
  entry.count.textContent = entry.open ? '' : '+' + (subtreeSize(hash) - 1);
}

/** Opens `hash`, following a straight line down until it forks or the budget runs out. */
function open(hash, budget = ROWS_AT_ONCE) {
  let current = hash;
  while (current) {
    const entry = nodes.get(current);
    const children = childrenOf(current);
    entry.open = true;
    entry.rest.classList.remove('hide');
    if (!entry.built) {
      entry.built = true;
      if (children.length === 1) {
        place(children[0].hash, entry.rest);   // one child: same level, the line just continues
      } else if (children.length > 1) {        // two or more: every one of them a level deeper
        const forks = el('div', 'forks');
        entry.rest.append(forks);
        children.forEach((child, index) => {
          const branch = el('div', 'branch');
          forks.append(branch);
          place(child.hash, branch, { index, total: children.length });
          mark(child.hash);
        });
      }
    }
    mark(current);
    if (children.length !== 1 || --budget <= 0) break;
    current = children[0].hash;   // same indentation: the line has not branched
  }
}

function close(hash) {
  const entry = nodes.get(hash);
  entry.open = false;
  entry.rest.classList.add('hide');
  mark(hash);
}

function toggle(hash) {
  const entry = nodes.get(hash);
  entry.open ? close(hash) : open(hash);
}

/** Opens every ancestor of `hash`, so a selection is always visible. */
function reveal(hash) {
  const path = [];
  for (let at = byHash.get(hash); at && at.parent; at = byHash.get(at.parent)) path.push(at.parent);
  for (const ancestor of path.reverse()) {
    if (!nodes.has(ancestor)) continue;
    const entry = nodes.get(ancestor);
    if (!entry.open || !entry.built) open(ancestor, 1);
  }
}

/** Opens outward from what is already placed until `limit` rows exist, so a forest that forks
early still shows a screenful, and one that forks a thousand times does not build all of it. */
function seed(limit) {
  for (let grew = true; grew && nodes.size < limit;) {
    grew = false;
    for (const [hash, entry] of [...nodes]) {
      if (nodes.size >= limit) break;
      if (!entry.built) { open(hash, limit - nodes.size); grew = true; }
    }
  }
}

function buildTree() {
  const box = document.getElementById('tree');
  box.textContent = '';
  nodes.clear();
  for (const root of childrenOf('')) {
    place(root.hash, box);   // a root starts flush: a rail would mean a fork that is not there
    open(root.hash);
  }
  seed(ROWS_AT_START);
}

/* --- search ----------------------------------------------------------- */

let hits = [], hitAt = -1;

function matchesOf(query) {
  const needle = query.toLowerCase();
  return data.states.filter(s =>
    (short(s.hash) + ' ' + s.kind + ' ' + summary(s) + ' ' + (s.note || ''))
      .toLowerCase().includes(needle));
}

function search(query, step) {
  const found = document.getElementById('found');
  for (const entry of nodes.values()) entry.row.classList.remove('hit');
  if (!query) { hits = []; hitAt = -1; found.textContent = ''; return; }
  const fresh = matchesOf(query).map(s => s.hash);
  if (fresh.join() !== hits.join()) { hits = fresh; hitAt = -1; }
  if (!hits.length) { found.textContent = '0'; return; }
  hitAt = (hitAt + (step || 1) + hits.length) % hits.length;
  const hash = hits[hitAt];
  found.textContent = (hitAt + 1) + '/' + hits.length;
  reveal(hash);
  select(hash);
  nodes.get(hash).row.classList.add('hit');
}

function wireTools() {
  const find = document.getElementById('find');
  find.oninput = () => { hitAt = -1; search(find.value, 0); };
  find.onkeydown = event => {
    if (event.key === 'Enter') { event.preventDefault(); search(find.value, event.shiftKey ? -1 : 1); }
  };
  // Placing a node creates entries for its children, so sweeping until nothing new appears
  // builds the whole forest however deep it is.
  document.getElementById('expand').onclick = () => {
    for (let grew = true; grew;) {
      grew = false;
      for (const s of data.states) {
        const entry = nodes.get(s.hash);
        if (entry && !(entry.built && entry.open)) { open(s.hash, 1); grew = true; }
      }
    }
  };
  // Only a row's descendants live inside its holder, so closing everything leaves the roots.
  document.getElementById('collapse').onclick = () => {
    for (const hash of [...nodes.keys()]) close(hash);
  };
}

/** Wraps a node so anything tall collapses to a clip with a toggle. */
function foldable(node, label) {
  const wrap = el('div', 'fold closed');
  const clip = el('div', 'clip');
  clip.append(node);
  const button = el('button', null, 'Show all' + (label ? ' (' + label + ')' : ''));
  button.onclick = () => {
    const closed = wrap.classList.toggle('closed');
    button.textContent = closed ? 'Show all' + (label ? ' (' + label + ')' : '') : 'Collapse';
  };
  wrap.append(clip, button);
  requestAnimationFrame(() => {
    if (clip.scrollHeight <= clip.clientHeight + 4) { wrap.classList.remove('closed');
      button.remove(); }
  });
  return wrap;
}

/** A line diff: the longest common subsequence, with runs of context elided. */
function lineDiff(oldText, newText) {
  const a = oldText.split('\\n'), b = newText.split('\\n');
  const n = a.length, m = b.length;
  const lcs = Array.from({length: n + 1}, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const rows = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { rows.push([' ', a[i]]); i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { rows.push(['-', a[i]]); i++; }
    else { rows.push(['+', b[j]]); j++; }
  }
  while (i < n) rows.push(['-', a[i++]]);
  while (j < m) rows.push(['+', b[j++]]);
  return rows;
}

function renderDiff(rows) {
  const box = el('div', 'diff');
  const keep = new Set();
  rows.forEach((row, index) => {
    if (row[0] !== ' ') for (let k = index - 3; k <= index + 3; k++) keep.add(k);
  });
  let elided = 0;
  rows.forEach((row, index) => {
    if (!keep.has(index)) { elided++; return; }
    if (elided) { box.append(el('div', 'gap', '\\u22ef ' + elided + ' unchanged lines'));
      elided = 0; }
    const cls = row[0] === '+' ? 'plus' : row[0] === '-' ? 'minus' : '';
    box.append(el('div', cls, row[0] + ' ' + row[1]));
  });
  if (elided) box.append(el('div', 'gap', '\\u22ef ' + elided + ' unchanged lines'));
  return box;
}

function section(parent, title) {
  parent.append(el('h2', null, title));
  const box = el('div');
  parent.append(box);
  return box;
}

function renderChanges(parent, state) {
  const box = section(parent, 'Workspace changes (' + state.changeCount + ')');
  if (!state.changes.length) { box.append(el('div', 'muted', 'none')); return; }
  for (const change of state.changes) {
    const file = el('details', 'file');
    const head = el('summary');
    head.append(el('span', 'tag ' + change.kind,
      change.kind === 'added' ? '+' : change.kind === 'removed' ? '\\u2212' : '~'));
    head.append(el('span', 'path', change.path));
    const hasText = change.old !== null || change.new !== null;
    if (hasText) {
      const rows = lineDiff(change.old || '', change.new || '');
      const plus = rows.filter(r => r[0] === '+').length;
      const minus = rows.filter(r => r[0] === '-').length;
      head.append(el('span', 'stat', '+' + plus + ' \\u2212' + minus));
      file.append(head, foldable(renderDiff(rows), plus + minus + ' changed lines'));
    } else {
      head.append(el('span', 'stat', 'not shown'));
      file.append(head, el('div', 'big',
        'content omitted: too large, binary, or under a generated directory'));
    }
    box.append(file);
  }
  if (state.changeCount > state.changes.length)
    box.append(el('div', 'muted',
      (state.changeCount - state.changes.length) + ' further paths not listed'));
}

/** A tool observation is mini's JSON envelope; show its fields, not its escaping. */
function renderObservation(text) {
  let parsed = null;
  try { parsed = JSON.parse(text); } catch (e) { parsed = null; }
  if (!parsed || typeof parsed !== 'object') return foldable(el('pre', null, text));
  const box = el('div');
  const rc = parsed.returncode;
  if (rc !== undefined) box.append(el('div', 'muted', 'returncode ' + rc));
  const body = parsed.output !== undefined ? parsed.output :
    [parsed.output_head, '\\u22ef ' + parsed.elided_chars + ' characters elided \\u22ef',
     parsed.output_tail].join('\\n');
  box.append(el('pre', null, body));
  if (parsed.exception_info) box.append(el('pre', 'removed', parsed.exception_info));
  return foldable(box, (body.split('\\n').length) + ' lines');
}

function renderMessages(parent, state) {
  const box = section(parent, 'Turn (' + state.messages.length + ' message(s))');
  if (!state.messages.length) { box.append(el('div', 'muted', 'none')); return; }
  for (const message of state.messages) {
    const card = el('div', 'msg');
    card.append(el('div', 'head', message.role));
    const body = el('div', 'body');
    if (message.role === 'tool') body.append(renderObservation(message.content));
    else {
      if (message.content) body.append(foldable(el('pre', null, message.content)));
      for (const call of message.calls || []) {
        const cmd = el('div', 'cmd');
        cmd.append(el('pre', null, call.command));
        body.append(cmd);
      }
    }
    card.append(body);
    box.append(card);
  }
}

function renderEvaluation(parent, state) {
  const e = state.evaluation;
  if (!e) return;
  const box = section(parent, 'Evaluation');
  const meta = el('table', 'meta');
  for (const [k, v] of [['command', e.command],
                        ['verdict', (e.passed ? 'pass' : 'fail') + ' (rc ' + e.returncode + ')'],
                        ['elapsed', e.elapsedMs + ' ms']]) {
    const row = el('tr');
    row.append(el('td', null, k), el('td', 'mono', v));
    meta.append(row);
  }
  box.append(meta, foldable(el('pre', null, e.output), e.output.split('\\n').length + ' lines'));
}

/** The hashes currently on screen, top to bottom, for keyboard movement. */
function visibleOrder() {
  const order = [];
  const walk = hash => {
    order.push(hash);
    const entry = nodes.get(hash);
    if (!entry || !entry.open) return;
    for (const child of childrenOf(hash)) if (nodes.has(child.hash)) walk(child.hash);
  };
  for (const root of childrenOf('')) if (nodes.has(root.hash)) walk(root.hash);
  return order;
}

let selected = null;

function select(hash) {
  const state = byHash.get(hash);
  location.hash = short(hash);
  reveal(hash);
  if (selected && nodes.has(selected)) nodes.get(selected).row.classList.remove('on');
  selected = hash;
  if (nodes.has(hash)) nodes.get(hash).row.classList.add('on');
  const detail = document.getElementById('detail');
  detail.textContent = '';
  detail.append(el('h1', null, state.kind + '  ' + short(hash)));
  const meta = el('table', 'meta');
  const rows = [['hash', hash], ['parent', state.parent || '(root)'], ['workspace', state.env]];
  if (state.note) rows.push(['note', state.note]);
  if (state.image) rows.push(['image', state.image]);
  if (state.base) rows.push(['base commit', state.base]);
  if (state.outcome) rows.push(['outcome', state.outcome.status]);
  for (const [k, v] of rows) {
    const row = el('tr');
    row.append(el('td', null, k), el('td', 'mono', v));
    meta.append(row);
  }
  detail.append(meta);
  if (state.outcome && state.outcome.submission)
    detail.append(foldable(el('pre', null, state.outcome.submission)));
  renderEvaluation(detail, state);
  renderMessages(detail, state);
  renderChanges(detail, state);
  detail.scrollTop = 0;
}

document.onkeydown = event => {
  if (event.target.tagName === 'INPUT' || !selected) return;
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  const order = visibleOrder();
  const at = order.indexOf(selected);
  const next = order[at + (event.key === 'ArrowDown' ? 1 : -1)];
  if (next) { select(next); nodes.get(next).row.scrollIntoView({block: 'nearest'}); }
};

buildTree();
wireTools();
const wanted = data.states.find(s => short(s.hash) === location.hash.slice(1));
select((wanted || childrenOf('')[0] || data.states[0]).hash);"

/-- Renders every state in the store as one standalone page. -/
def report (store : Store) (title : String) : Result String := do
  let hashes ← Session.allStates store
  let states ← hashes.mapM (stateJson store)
  let json := (Lean.Json.mkObj [("states", .arr states)]).compress
  -- `</` cannot appear inside a script element; the JSON parser does not mind the escape.
  let safe := json.replace "</" "<\\/"
  pure <|
    "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" ++
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n" ++
    "<title>" ++ title ++ "</title>\n<style>\n" ++ styles ++ "\n</style></head>\n<body>\n" ++
    "<div id=\"layout\"><div id=\"side\"><div id=\"tools\">" ++
    "<input id=\"find\" placeholder=\"find (enter for next)\" spellcheck=\"false\">" ++
    "<span id=\"found\"></span>" ++
    "<button class=\"tool\" id=\"expand\">expand</button>" ++
    "<button class=\"tool\" id=\"collapse\">collapse</button></div>" ++
    "<div id=\"tree\"></div></div><div id=\"detail\"></div></div>\n" ++
    "<script id=\"data\" type=\"application/json\">" ++ safe ++ "</script>\n" ++
    "<script>\n" ++ script ++ "\n</script>\n</body></html>\n"

end Alaya.Agent.MiniSwe.Html
