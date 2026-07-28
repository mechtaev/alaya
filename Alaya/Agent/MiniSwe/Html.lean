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
#tree{width:420px;min-width:260px;max-width:60vw;overflow:auto;border-right:1px solid #ddd;
padding:10px 8px;background:#fafafa;resize:horizontal}
#detail{flex:1;overflow:auto;padding:18px 22px}
h1{font-size:14px;margin:0 0 10px;letter-spacing:.02em;text-transform:uppercase;color:#666}
h2{font-size:13px;margin:22px 0 8px;text-transform:uppercase;letter-spacing:.03em;color:#666;
border-bottom:1px solid #eee;padding-bottom:4px}
.node{display:block;width:100%;text-align:left;border:0;background:none;padding:3px 6px;
border-radius:4px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.node:hover{background:#eef1f5}
.node.on{background:#dce7f5;font-weight:600}
.hash{color:#8a6d3b}
.kind{display:inline-block;min-width:52px;padding:0 5px;margin-right:6px;border-radius:3px;
font-size:10px;text-transform:uppercase;letter-spacing:.04em;text-align:center;color:#fff}
.k-root{background:#555}.k-agent{background:#3a6ea5}.k-format_error{background:#a55}
.k-intervention{background:#7a5aa5}.k-evaluation{background:#2f7d4f}
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

function buildTree() {
  const kids = new Map();
  for (const s of data.states) {
    const key = s.parent || '';
    if (!kids.has(key)) kids.set(key, []);
    kids.get(key).push(s);
  }
  const box = document.getElementById('tree');
  const walk = (hash, depth) => {
    for (const s of kids.get(hash) || []) {
      const b = el('button', 'node');
      b.style.paddingLeft = (6 + depth * 14) + 'px';
      b.dataset.hash = s.hash;
      const k = el('span', 'kind k-' + s.kind, s.kind === 'format_error' ? 'error' :
        s.kind === 'intervention' ? 'commit' : s.kind === 'evaluation' ? 'eval' : s.kind);
      b.append(k, el('span', 'hash', short(s.hash) + ' '), document.createTextNode(summary(s)));
      const rc = (s.commands || []).length ? s.commands[s.commands.length - 1].returncode : null;
      if (rc !== null && rc !== 0) b.append(el('span', 'chip bad', 'rc ' + rc));
      if (s.outcome) b.append(el('span', 'chip', s.outcome.status));
      if (s.evaluation) b.append(el('span', 'chip ' + (s.evaluation.passed ? 'ok' : 'bad'),
        s.evaluation.passed ? 'pass' : 'fail'));
      b.onclick = () => select(s.hash);
      box.append(b);
      walk(s.hash, depth + 1);
    }
  };
  walk('', 0);
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

function select(hash) {
  const state = byHash.get(hash);
  location.hash = short(hash);
  for (const node of document.querySelectorAll('.node'))
    node.classList.toggle('on', node.dataset.hash === hash);
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

buildTree();
const wanted = data.states.find(s => short(s.hash) === location.hash.slice(1));
select((wanted || data.states[0]).hash);"

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
    "<div id=\"layout\"><div id=\"tree\"></div><div id=\"detail\"></div></div>\n" ++
    "<script id=\"data\" type=\"application/json\">" ++ safe ++ "</script>\n" ++
    "<script>\n" ++ script ++ "\n</script>\n</body></html>\n"

end Alaya.Agent.MiniSwe.Html
