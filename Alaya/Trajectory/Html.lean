import Alaya.Trajectory

/-!
A standalone HTML report of a whole trajectory forest.

Everything a data directory holds — the tree, each state's metadata, the events it appended, the
workspace changes it made, and any verdict recorded against it — is serialized into one
self-contained file: the data as JSON in a `<script>` tag, with the page that renders it. No
network, no assets, so a report can be mailed, archived, or opened from a container.

The page shows two things side by side and keeps them apart, as the agent API does: each
state's *events* — what happened, as recorded — and, on request, the *view* — the exact context
the model is sent from that state, produced by the agent's view function. The report depends on
the agent for nothing else: it takes the view and the tool list, and renders everything by its
generic shape.

Workspace changes carry the text of the files they touch when that is cheap (small, textual, and
not obviously machine-generated), so the report can show a line diff rather than just a list of
paths. The limits below keep a report from growing with an agent's virtual environment.
-/

namespace Alaya.Trajectory.Html

open Alaya (Result Error)
open Alaya.Agent (Event Log View)
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

/-- Whether `path` lies under one of the folded prefixes, and which. A trailing slash is
optional, and the directory's own entry counts as being under it. -/
private def foldedUnder? (hidden : Array String) (path : String) : Option String :=
  hidden.find? fun prefix' => path == prefix' || path.startsWith (prefix' ++ "/")

/-- Counts of what changed under one folded prefix. -/
private structure Fold where
  added : Nat := 0
  removed : Nat := 0
  modified : Nat := 0
  deriving Inhabited

private def Fold.total (fold : Fold) : Nat := fold.added + fold.removed + fold.modified

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

private def callJson (call : Chat.ToolCall) : Lean.Json :=
  .mkObj [
    ("id", call.id), ("name", call.name),
    ("arguments", call.invalidArguments?.map Lean.Json.str |>.getD call.arguments),
    ("summary", argumentsSummary call)]

/-- An event by its generic shape: who, what was said, which calls, what came back. -/
private def eventJson : Event -> Lean.Json
  | .message m =>
    match m with
    | .system c => .mkObj [("type", "message"), ("role", "system"), ("content", c)]
    | .user c => .mkObj [("type", "message"), ("role", "user"), ("content", c)]
    | .assistant c? calls reasoning? => .mkObj [
        ("type", "message"), ("role", "assistant"),
        ("content", c?.map Lean.Json.str |>.getD .null),
        ("reasoning", reasoning?.map Lean.Json.str |>.getD .null),
        ("calls", .arr (calls.map callJson))]
    | .tool id content => .mkObj [
        ("type", "message"), ("role", "tool"), ("callId", id), ("content", content)]
  | .response r => .mkObj [
      ("type", "response"),
      ("content", r.content?.map Lean.Json.str |>.getD .null),
      ("reasoning", r.reasoning?.map Lean.Json.str |>.getD .null),
      ("finishReason", r.finishReason?.map Lean.Json.str |>.getD .null),
      ("calls", .arr (r.toolCalls.map callJson))]
  | .observation id content => .mkObj [
      ("type", "observation"), ("callId", id), ("content", content)]

private def wireOf (dialogue : Array Chat.Message) : Array String :=
  dialogue.map fun m => m.toJson.compress

private def stateJson (store : Store) (view : View) (hidden : Array String) (hash : Hash) :
    Result Lean.Json := do
  let state ← getState store hash
  let parentEnv? ← match state.parent? with
    | some parent => pure (some (← getState store parent).env)
    | none => pure none
  let changes ← match parentEnv? with
    | none => pure #[]
    | some before => store.diff before state.env
  -- Folded prefixes are counted, never listed: a run that rebuilds a virtual environment
  -- changes hundreds of paths that say nothing, and they would otherwise crowd out the ones
  -- that do — the listing limit applies to what is left after folding.
  let mut folds : Std.HashMap String Fold := {}
  let mut listed : Array Change := #[]
  for change in changes do
    match foldedUnder? hidden change.path with
    | none => listed := listed.push change
    | some prefix' =>
      let fold := folds.getD prefix' {}
      folds := folds.insert prefix' <| match change with
        | .added .. => { fold with added := fold.added + 1 }
        | .removed .. => { fold with removed := fold.removed + 1 }
        | .modified .. => { fold with modified := fold.modified + 1 }
  let foldedJson := hidden.filterMap fun prefix' =>
    folds.get? prefix' |>.map fun fold =>
      Lean.Json.mkObj [
        ("prefix", prefix'), ("added", (fold.added : Lean.Json)),
        ("removed", (fold.removed : Lean.Json)), ("modified", (fold.modified : Lean.Json)),
        ("total", (fold.total : Lean.Json))]
  let shown := listed.extract 0 changeLimit
  let changesJson ← shown.mapM (changeJson store parentEnv? (some state.env))
  let evaluation := match state.evaluation? with
    | none => Lean.Json.null
    | some e => .mkObj [
        ("command", e.command), ("returncode", (e.returncode : Lean.Json)),
        ("elapsedMs", (e.elapsedMs : Lean.Json)), ("output", e.output),
        ("passed", e.passed)]
  -- The context the model is sent from this state, as the view makes it. A state carries only
  -- what its own turn added to the parent's context when the view extended it — the common
  -- case, and linear in the forest — and the whole context when the view rewrote earlier
  -- messages, which a view that elides old output does. The page assembles the rest.
  let full := view (← logOf store hash)
  let parentView ← match state.parent? with
    | some parent => pure (view (← logOf store parent))
    | none => pure #[]
  let extended := full.size >= parentView.size &&
    wireOf (full.extract 0 parentView.size) == wireOf parentView
  let wire := if extended then full.extract parentView.size full.size else full
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
    ("question", state.question?.map (fun q => Lean.Json.mkObj [("callId", q.callId), ("text", q.text)])
      |>.getD .null),
    ("intervention", state.intervention?.map (fun i => Lean.Json.mkObj [
      ("message", i.message), ("changed", .arr (i.changed.map Lean.Json.str))]) |>.getD .null),
    ("events", .arr (state.appended.map eventJson)),
    ("wire", .arr (wire.map Chat.Message.toJson)),
    ("wireFull", !extended),
    ("wireOwn", ((full.size - parentView.size) : Lean.Json)),
    ("changes", .arr changesJson),
    ("folded", .arr foldedJson),
    ("listedCount", (listed.size : Lean.Json)),
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
/* An elbow from the rail into the row that starts a branch, so the first state of a sibling
   cannot be mistaken for one more row of the branch above it. */
.branch>.node:first-child::before{content:'';position:absolute;left:-13px;top:11px;width:11px;
border-top:2px solid #c3cbd4}
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
.i-root{color:#4a4a4a}.i-turn{color:#3a6ea5}
.i-intervention{color:#7a5aa5}.i-pass{color:#2f7d4f}.i-fail{color:#b02020}
.i-message{color:#7a5aa5}.i-question{color:#c07a1a}.i-reply{color:#2f7d4f}
.chip{display:inline-block;padding:0 6px;border-radius:9px;font-size:11px;margin-left:6px;
background:#eee;color:#444}
.chip.ok{background:#d8f0dd;color:#1c5c33}.chip.bad{background:#f7dcdc;color:#8a2b2b}
.chip.wait{background:#fbe9cf;color:#7a4a08}
table.meta{border-collapse:collapse;margin-bottom:4px}
table.meta td{padding:2px 14px 2px 0;vertical-align:top}
table.meta td:first-child{color:#777;white-space:nowrap}
.msg{border:1px solid #e3e3e3;border-radius:5px;margin:8px 0;overflow:hidden}
.msg>.head{padding:4px 9px;background:#f4f6f8;font-size:11px;text-transform:uppercase;
letter-spacing:.04em;color:#555;border-bottom:1px solid #e3e3e3}
.msg>.body{padding:8px 10px}
.msg .head .id{margin-left:10px;color:#8a94a0;text-transform:none;letter-spacing:0}
pre{margin:0;white-space:pre-wrap;word-break:break-word}
.cmd{background:#1f2430;color:#e6e6e6;padding:8px 10px;border-radius:4px;margin:6px 0}
.cmd .rc{float:right;color:#9fb3c8}
.cmd .name{color:#9fb3c8;margin-right:8px}
.field{margin:4px 0}
.field .key{color:#777;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
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
.big{color:#888;font-style:italic;padding:6px 9px}
.file.folded{padding:5px 9px;background:#f7f8fa;color:#777}
.headbar{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.headbar h1{margin:0}
/* The model's context, in a modal over the page: what a continuation from the selected state
   is sampled from, in the form the provider receives. */
#modal{position:fixed;inset:0;z-index:10;display:flex;align-items:center;justify-content:center;
background:rgba(20,24,32,.55)}
#modal.hide{display:none}
#modal .win{width:min(1100px,94vw);height:min(90vh,1400px);display:flex;flex-direction:column;
background:#fff;border-radius:6px;box-shadow:0 10px 40px rgba(0,0,0,.35)}
#modal .bar{display:flex;gap:6px;align-items:center;padding:8px 12px;background:#f4f6f8;
border-bottom:1px solid #e3e3e3;border-radius:6px 6px 0 0}
#modal .ttl{flex:1;min-width:0;font-weight:600;overflow:hidden;text-overflow:ellipsis;
white-space:nowrap}
#modal-body{flex:1;overflow:auto;padding:12px 16px}
#modal-body .note{color:#666;font-size:12px;margin:0 0 10px}
.msg.mine{border-left:3px solid #3a6ea5}
.divider{margin:16px 0 6px;padding-top:4px;border-top:1px dashed #3a6ea5;color:#3a6ea5;
font-size:11px;text-transform:uppercase;letter-spacing:.04em}"

private def script : String :=
"const data = JSON.parse(document.getElementById('data').textContent);
const byHash = new Map(data.states.map(s => [s.hash, s]));
const short = h => h.slice(0, 12);
const el = (tag, cls, text) => { const n = document.createElement(tag);
  if (cls) n.className = cls; if (text !== undefined) n.textContent = text; return n; };
const flat = (s, n = 70) => { s = String(s).replace(/\\s+/g, ' '); return s.length > n ? s.slice(0, n - 3) + '...' : s; };

/** The first tool call of a state's turn, as `name  arguments`. */
function firstCall(state) {
  for (const e of state.events || []) {
    const calls = e.calls || [];
    if ((e.type === 'response' || e.role === 'assistant') && calls.length) return calls[0];
  }
  return null;
}

function summary(state) {
  if (state.kind === 'root') return state.note || 'root';
  if (state.kind === 'evaluation') {
    const e = state.evaluation || {};
    return (e.passed ? 'pass' : 'fail ' + e.returncode) + '  ' + (e.command || '');
  }
  if (state.kind === 'intervention') return state.note || 'commit';
  if (state.kind === 'message') return (state.intervention || {}).message || 'message';
  if (state.kind === 'reply') {
    const e = (state.events || [])[0];
    return 'reply: ' + (e && typeof e.content === 'string' ? e.content : JSON.stringify(e && e.content));
  }
  const call = firstCall(state);
  const asked = state.kind === 'question' ? ' ask: ' + ((state.question || {}).text || '') : '';
  return (call ? call.name + '  ' + flat(call.summary) : '(no tool call)') + asked;
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

/* A glyph per kind, on a 14x14 grid: a seed for a root, a prompt for a turn, a diamond for a
   hand-made commit, a bubble for a message, a question mark, a return arrow for a reply, and a
   tick or cross for a verdict. */
const GLYPHS = {
  root: '<circle cx=\"7\" cy=\"7\" r=\"2.6\"/><circle cx=\"7\" cy=\"7\" r=\"5.6\" fill=\"none\"/>',
  turn: '<path d=\"M2.5 3.5L6 7l-3.5 3.5\" fill=\"none\"/><path d=\"M7.5 10.5h4\" fill=\"none\"/>',
  intervention: '<path d=\"M7 1.6L12.4 7 7 12.4 1.6 7z\" fill=\"none\"/>',
  message: '<path d=\"M2 3h10v6H6l-3 2.5V9H2z\" fill=\"none\"/>',
  question: '<path d=\"M4.6 5.3a2.4 2.4 0 1 1 3.3 2.2c-.6.3-.9.7-.9 1.4\" fill=\"none\"/>' +
    '<circle cx=\"7\" cy=\"11.2\" r=\".8\" stroke=\"none\"/>',
  reply: '<path d=\"M6 3.5L2.5 7 6 10.5\" fill=\"none\"/><path d=\"M2.5 7h5.5a3 3 0 0 1 3 3v1.5\" fill=\"none\"/>',
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
    'stroke-linejoin=\"round\" fill=\"currentColor\">' + (GLYPHS[key] || GLYPHS.turn) +
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

function rowFor(state) {
  const row = el('div', 'node');
  row.dataset.hash = state.hash;
  const leaf = !childrenOf(state.hash).length;
  const twisty = el('span', 'tw' + (leaf ? ' leaf' : ''));
  twisty.innerHTML = twistyMarkup(leaf ? 'leaf' : 'open');
  const text = el('span', 'sum');
  text.append(el('span', 'hash', short(state.hash) + ' '), document.createTextNode(summary(state)));
  row.append(twisty, icon(state), text);
  if (state.outcome) row.append(el('span', 'chip', state.outcome.status));
  if (state.question && !childrenOf(state.hash).some(c => c.kind === 'reply'))
    row.append(el('span', 'chip wait', 'waiting'));
  const count = el('span', 'count');
  row.append(count);
  row.onclick = () => select(state.hash);
  twisty.onclick = event => { event.stopPropagation(); toggle(state.hash); };
  return { row, twisty, count };
}

/** Places one state's row, and an empty holder for everything below it. A row that starts a
branch is the first in its container, which is what the elbow marks. */
function place(hash, container) {
  const { row, twisty, count } = rowFor(byHash.get(hash));
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
        for (const child of children) {
          const branch = el('div', 'branch');
          forks.append(branch);
          place(child.hash, branch);
          mark(child.hash);
        }
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
  const folded = state.folded || [];
  if (!state.changes.length && !folded.length) {
    box.append(el('div', 'muted', 'none'));
    return;
  }
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
  const listed = state.listedCount === undefined ? state.changes.length : state.listedCount;
  if (listed > state.changes.length)
    box.append(el('div', 'muted', (listed - state.changes.length) + ' further paths not listed'));
  for (const fold of folded) {
    const parts = [];
    if (fold.added) parts.push('+' + fold.added);
    if (fold.removed) parts.push('−' + fold.removed);
    if (fold.modified) parts.push('~' + fold.modified);
    const row = el('div', 'file folded');
    row.append(el('span', 'tag', '≡'), el('span', 'path', fold.prefix + '/'),
      el('span', 'stat', fold.total + ' paths  ' + parts.join(' ')));
    box.append(row);
  }
}

/** A tool call, as the agent made it: its name and its arguments. */
function renderCall(call) {
  const cmd = el('div', 'cmd');
  cmd.append(el('span', 'rc', call.id));
  cmd.append(el('span', 'name', call.name));
  cmd.append(el('pre', null, call.summary));
  return cmd;
}

/** An observation's content by its shape: a text as is, an object field by field, anything
else as JSON. What the fields mean is the agent's business. */
function renderContent(content) {
  if (typeof content === 'string') return foldable(el('pre', null, content), content.split('\\n').length + ' lines');
  if (content && typeof content === 'object' && !Array.isArray(content)) {
    const box = el('div');
    for (const [key, value] of Object.entries(content)) {
      const field = el('div', 'field');
      field.append(el('div', 'key', key));
      if (typeof value === 'string') field.append(foldable(el('pre', null, value), value.split('\\n').length + ' lines'));
      else field.append(el('pre', 'mono', JSON.stringify(value)));
      box.append(field);
    }
    return box;
  }
  return el('pre', 'mono', JSON.stringify(content, null, 2));
}

/** One recorded event: a message placed verbatim, a model response, or a tool's observation. */
function renderEvent(event) {
  const card = el('div', 'msg');
  const head = el('div', 'head');
  const body = el('div', 'body');
  if (event.type === 'message') {
    head.append(document.createTextNode(event.role));
    if (event.callId) head.append(el('span', 'id', 'tool_call_id ' + event.callId));
    if (event.reasoning) { body.append(el('div', 'muted', 'reasoning')); body.append(foldable(el('pre', 'muted', event.reasoning))); }
    if (event.role === 'tool') body.append(renderContent(event.content));
    else if (event.content) body.append(foldable(el('pre', null, event.content)));
    for (const call of event.calls || []) body.append(renderCall(call));
  } else if (event.type === 'response') {
    head.append(document.createTextNode('response'));
    if (event.finishReason) head.append(el('span', 'id', 'finish_reason ' + event.finishReason));
    if (event.reasoning) { body.append(el('div', 'muted', 'reasoning')); body.append(foldable(el('pre', 'muted', event.reasoning))); }
    if (event.content) body.append(foldable(el('pre', null, event.content)));
    for (const call of event.calls || []) body.append(renderCall(call));
  } else {
    head.append(document.createTextNode('observation'));
    head.append(el('span', 'id', 'tool_call_id ' + event.callId));
    body.append(renderContent(event.content));
  }
  card.append(head, body);
  return card;
}

function renderEvents(parent, state) {
  const events = state.events || [];
  const box = section(parent, 'Events (' + events.length + ')');
  if (!events.length) { box.append(el('div', 'muted', 'none')); return; }
  for (const event of events) box.append(renderEvent(event));
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

/* --- the model's context -----------------------------------------------
   The request a continuation from a state is sampled from: the agent's view of the log at that
   state, in the wire form the provider receives, inside the envelope every sample sends. A state
   carries what its turn added to the parent's context, or the whole context when the view
   rewrote earlier messages; the page walks up to the nearest whole context and appends the
   additions below it. The messages the selected state itself contributed are marked: everything
   above them is what that state's own turn was sampled from. */

function contextOf(hash) {
  const chain = [];
  for (let at = byHash.get(hash); at; at = at.parent ? byHash.get(at.parent) : null) {
    chain.push(at);
    if (at.wireFull) break;
  }
  chain.reverse();
  const messages = [];
  for (const state of chain) for (const message of state.wire || []) messages.push(message);
  const own = Math.max(0, messages.length - (byHash.get(hash).wireOwn || 0));
  return { messages, own };
}

function requestFor(hash) {
  const request = JSON.parse(JSON.stringify(data.request || {}));
  request.messages = contextOf(hash).messages;
  return request;
}

/** One message exactly as sent: role, content verbatim, tool calls as name and argument string. */
function renderWireMessage(message, mine) {
  const card = el('div', 'msg' + (mine ? ' mine' : ''));
  const head = el('div', 'head', message.role);
  if (message.tool_call_id) head.append(el('span', 'id', 'tool_call_id ' + message.tool_call_id));
  card.append(head);
  const body = el('div', 'body');
  if (message.reasoning_content) {
    body.append(el('div', 'muted', 'reasoning_content'));
    body.append(el('pre', 'muted', message.reasoning_content));
  }
  if (message.content !== undefined && message.content !== null)
    body.append(el('pre', null, message.content));
  for (const call of message.tool_calls || []) {
    const cmd = el('div', 'cmd');
    cmd.append(el('span', 'rc', call.id));
    cmd.append(el('pre', null, (call.function || {}).name + ' ' + (call.function || {}).arguments));
    body.append(cmd);
  }
  card.append(body);
  return card;
}

let modalMode = 'readable';

function showContext(hash) {
  const modal = document.getElementById('modal');
  const body = document.getElementById('modal-body');
  const { messages, own } = contextOf(hash);
  const request = requestFor(hash);
  const json = JSON.stringify(request);
  document.getElementById('modal-title').textContent = 'Context at ' + short(hash) + ' \\u2014 ' +
    messages.length + ' message(s), ' + json.length + ' bytes of JSON';
  document.getElementById('modal-mode').textContent = modalMode === 'json' ? 'readable' : 'JSON';
  body.textContent = '';
  body.append(el('p', 'note', 'The request a continuation from this state is sampled from: the ' +
    'agent\\'s view of the log, as the provider receives it. The model name and temperature are ' +
    'added at request time and are not part of a state.'));
  if (modalMode === 'json') {
    body.append(el('pre', 'mono', JSON.stringify(request, null, 2)));
  } else {
    if (!messages.length) body.append(el('div', 'muted', 'empty'));
    if (own === messages.length && messages.length)
      body.append(el('div', 'muted', 'This state added nothing to the context; it is its parent\\'s.'));
    messages.forEach((message, index) => {
      if (index === own && own > 0)
        body.append(el('div', 'divider', 'added by this state \\u2193 \\u2014 everything above ' +
          'is what its turn was sampled from'));
      body.append(renderWireMessage(message, index >= own));
    });
  }
  modal.dataset.hash = hash;
  modal.classList.remove('hide');
  body.scrollTop = 0;
}

function hideContext() {
  document.getElementById('modal').classList.add('hide');
}

function wireModal() {
  const modal = document.getElementById('modal');
  modal.onclick = event => { if (event.target === modal) hideContext(); };
  document.getElementById('modal-close').onclick = hideContext;
  document.getElementById('modal-mode').onclick = () => {
    modalMode = modalMode === 'json' ? 'readable' : 'json';
    showContext(modal.dataset.hash);
  };
  const copy = document.getElementById('modal-copy');
  copy.onclick = () => {
    const text = JSON.stringify(requestFor(modal.dataset.hash), null, 2);
    const done = ok => { copy.textContent = ok ? 'copied' : 'copy failed';
      setTimeout(() => { copy.textContent = 'copy JSON'; }, 1200); };
    try { navigator.clipboard.writeText(text).then(() => done(true), () => done(false)); }
    catch (e) { done(false); }
  };
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
  const headbar = el('div', 'headbar');
  headbar.append(el('h1', null, state.kind + '  ' + short(hash)));
  // An evaluation is a leaf nothing continues from, so it has no context to show.
  if (state.kind !== 'evaluation') {
    const context = el('button', 'tool', 'view context');
    context.title = 'The request a continuation from this state is sampled from';
    context.onclick = () => showContext(hash);
    headbar.append(context);
  }
  detail.append(headbar);
  const meta = el('table', 'meta');
  const rows = [['hash', hash], ['parent', state.parent || '(root)'], ['workspace', state.env]];
  if (state.note) rows.push(['note', state.note]);
  if (state.image) rows.push(['image', state.image]);
  if (state.base) rows.push(['base commit', state.base]);
  if (state.outcome) rows.push(['outcome', state.outcome.status]);
  if (state.question) rows.push(['question', state.question.text]);
  if (state.intervention) rows.push(['message', state.intervention.message]);
  for (const [k, v] of rows) {
    const row = el('tr');
    row.append(el('td', null, k), el('td', 'mono', v));
    meta.append(row);
  }
  detail.append(meta);
  if (state.outcome && state.outcome.submission)
    detail.append(foldable(el('pre', null, state.outcome.submission)));
  renderEvaluation(detail, state);
  renderEvents(detail, state);
  renderChanges(detail, state);
  detail.scrollTop = 0;
}

document.onkeydown = event => {
  if (!document.getElementById('modal').classList.contains('hide')) {
    if (event.key === 'Escape') hideContext();
    return;
  }
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
wireModal();
const wanted = data.states.find(s => short(s.hash) === location.hash.slice(1));
select((wanted || childrenOf('')[0] || data.states[0]).hash);"

/-- The request every sample of an agent sends, minus its messages: the tools, the tool choice,
and the response format, exactly as `Chat.Request.toJson` lays them out. The page fills in
`messages` per state. The model name and temperature are added by the provider at request time
and are not recorded in a state, so they are not here either. -/
def requestEnvelope (tools : Array Chat.ToolDefinition) : Lean.Json :=
  ({ messages := #[], tools } : Chat.Request).toJson

/-- Everything the page renders, as one JSON document: the states (see `stateJson`) and the
request envelope. `view` and `tools` are the agent's; nothing else about it is needed. -/
def dataJson (store : Store) (view : View) (tools : Array Chat.ToolDefinition)
    (hidden : Array String := #[]) : Result Lean.Json := do
  let hidden := hidden.map fun prefix' =>
    if prefix'.endsWith "/" then (prefix'.dropEnd 1).toString else prefix'
  let hashes ← allStates store
  let states ← hashes.mapM (stateJson store view hidden)
  pure <| .mkObj [("states", .arr states), ("request", requestEnvelope tools)]

/-- Renders every state in the store as one standalone page. Paths under `hidden` are counted
rather than listed, so a directory that changes constantly and means nothing — a virtual
environment, a bytecode cache — is reported without burying the rest. -/
def report (store : Store) (title : String) (view : View) (tools : Array Chat.ToolDefinition)
    (hidden : Array String := #[]) : Result String := do
  let json := (← dataJson store view tools hidden).compress
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
    "<div id=\"modal\" class=\"hide\"><div class=\"win\"><div class=\"bar\">" ++
    "<span class=\"ttl\" id=\"modal-title\"></span>" ++
    "<button class=\"tool\" id=\"modal-mode\">JSON</button>" ++
    "<button class=\"tool\" id=\"modal-copy\">copy JSON</button>" ++
    "<button class=\"tool\" id=\"modal-close\">close</button></div>" ++
    "<div id=\"modal-body\"></div></div></div>\n" ++
    "<script id=\"data\" type=\"application/json\">" ++ safe ++ "</script>\n" ++
    "<script>\n" ++ script ++ "\n</script>\n</body></html>\n"

end Alaya.Trajectory.Html
