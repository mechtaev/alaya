import Test.Framework
import Alaya.Cas

/-! Per-feature suites for the content-addressed store: blob/tree objects, Merkle structure
sharing and diffing, the stat cache, incremental and linked materialization, exec/symlink
metadata, ignore rules, refs and garbage collection, parallel hashing, and pure path ops. -/

namespace CasTests

open Testing
open Alaya
open Alaya.Cas

private def isStorage : Error -> Bool
  | .storage _ => true
  | _ => false

private def withStore : TestM Store := do
  assertOk <| Store.create ((← scratch) / "store")

/-- A small tree with nesting, duplicate content (`c.txt` = `dup.txt`), and a sibling
directory that most tests leave untouched. -/
private def baseSpec : Array (String × String) := #[
  ("a/b/c.txt", "content-c"), ("a/b/d.txt", "content-d"), ("a/e.txt", "content-e"),
  ("dup.txt", "content-c"), ("shared/s.txt", "content-s")]

private def sourceDir : TestM System.FilePath := return (← scratch) / "source"

private def snapshotSpec (store : Store) (spec : Array (String × String))
    (config : CaptureConfig := {}) : TestM Hash := do
  let source ← sourceDir
  writeSpec source spec
  assertOk <| store.snapshot source config

private def metricsOf (store : Store) : TestM Metrics :=
  assertOk store.metrics

private def reset (store : Store) : TestM Unit := do
  assertOk store.resetMetrics

/-! ## Objects and blobs -/

def objectSuite : Suite := suite "cas.objects" #[
  test "blob roundtrip and dedup" do
    let store ← withStore
    let bytes := "hello blobs".toUTF8
    let hash ← assertOk <| store.putBytes bytes
    assertEqual "roundtrip" ((← assertOk <| store.getBytes hash).map (·.toList))
      (some bytes.toList)
    let again ← assertOk <| store.putBytes bytes
    assertEqual "stable address" again hash
    let m ← metricsOf store
    assertEqual "written once" m.blobsWritten 1
    assertEqual "reused once" m.blobsReused 1
    assertEqual "missing blob" (← assertOk <| store.getBytes ⟨String.ofList
      (List.replicate 64 'a')⟩) none,

  test "tree roundtrip preserves entries and types" do
    let store ← withStore
    let blob ← assertOk <| store.putBytes "x".toUTF8
    let tree := Tree.ofEntries #[
      { name := "z.txt", type := .file, hash := blob },
      { name := "run.sh", type := .executable, hash := blob },
      { name := "link", type := .symlink, hash := blob }]
    let hash ← assertOk <| store.putTree tree
    let loaded ← assertOk <| store.getTree hash
    assertEqual "canonical order survives" loaded tree
    assertEqual "sorted by name" (loaded.entries.map (·.name)) #["link", "run.sh", "z.txt"],

  test "tree parsing rejects hostile input" do
    let bad (json : String) : TestM Unit := do
      match Lean.Json.parse json with
      | .error _ => fail "test fixture is not JSON"
      | .ok json =>
        match Tree.fromJson json with
        | .ok _ => fail s!"accepted hostile tree: {json}"
        | .error _ => pure ()
    let hex := String.ofList (List.replicate 64 'a')
    let entry (name type hash : String) : String :=
      "{\"name\": \"" ++ name ++ "\", \"type\": \"" ++ type ++ "\", \"hash\": \"" ++ hash ++ "\"}"
    bad ("[" ++ entry "../x" "file" hex ++ "]")
    bad ("[" ++ entry "a/b" "file" hex ++ "]")
    bad ("[" ++ entry "x" "file" "../escape" ++ "]")
    bad ("[" ++ entry "x" "weird" hex ++ "]")
    bad ("[" ++ entry "x" "file" hex ++ ", " ++ entry "x" "dir" hex ++ "]"),

  test "missing tree is a storage error" do
    let store ← withStore
    assertError "getTree" (store.getTree ⟨String.ofList (List.replicate 64 'b')⟩) isStorage
]

/-! ## Feature 2: Merkle trees -/

def merkleSuite : Suite := suite "cas.merkle" #[
  test "snapshot is deterministic and content dedupes" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let again ← assertOk <| store.snapshot (← sourceDir)
    assertEqual "same root hash" again root
    let c ← assertOk <| store.entryAt? root "a/b/c.txt"
    let dup ← assertOk <| store.entryAt? root "dup.txt"
    assertEqual "identical content shares a blob" (c.map (·.hash)) (dup.map (·.hash)),

  test "unchanged subtrees keep their hash across snapshots" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    writeSpec (← sourceDir) #[("a/b/c.txt", "changed-c")]
    let v2 ← assertOk <| store.snapshot (← sourceDir)
    check (v1 != v2) "root must change"
    let sharedBefore ← assertOk <| store.entryAt? v1 "shared"
    let sharedAfter ← assertOk <| store.entryAt? v2 "shared"
    assertEqual "sibling subtree shared" sharedAfter sharedBefore
    let changedBefore ← assertOk <| store.entryAt? v1 "a"
    let changedAfter ← assertOk <| store.entryAt? v2 "a"
    check (changedBefore != changedAfter) "changed spine must differ",

  test "a one-file change writes only the blob and its spine" do
    let store ← withStore
    let _ ← snapshotSpec store baseSpec
    writeSpec (← sourceDir) #[("a/b/c.txt", "changed-c")]
    reset store
    let _ ← assertOk <| store.snapshot (← sourceDir)
    let m ← metricsOf store
    -- One content blob plus the three trees on the changed path: a/b, a, and the root.
    assertEqual "objects written" m.blobsWritten 4,

  test "empty directories are preserved" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("keep.txt", "k")]
    IO.FS.createDirAll (source / "empty" / "nested")
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    check (← (destination / "empty" / "nested").isDir) "nested empty dir restored"
]

/-! ## Feature 1: stat cache -/

def statCacheSuite : Suite := suite "cas.statcache" #[
  test "an unchanged capture re-hashes nothing" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    reset store
    let again ← assertOk <| store.snapshot (← sourceDir)
    let m ← metricsOf store
    assertEqual "same root" again root
    assertEqual "no misses" m.cacheMisses 0
    assertEqual "all hits" m.cacheHits baseSpec.size,

  test "a changed file is the only re-hash" do
    let store ← withStore
    let _ ← snapshotSpec store baseSpec
    IO.sleep 10
    writeSpec (← sourceDir) #[("a/e.txt", "changed-content-e")]
    reset store
    let root ← assertOk <| store.snapshot (← sourceDir)
    let m ← metricsOf store
    assertEqual "one miss" m.cacheMisses 1
    assertEqual "others hit" m.cacheHits (baseSpec.size - 1)
    assertEqual "new content visible" ((← assertOk <| store.readPath root "a/e.txt").map
      (String.fromUTF8? ·)) (some (some "changed-content-e")),

  test "disabling the cache re-hashes everything" do
    let store ← withStore
    let config : CaptureConfig := { statCache := false }
    let root ← snapshotSpec store baseSpec config
    reset store
    let again ← assertOk <| store.snapshot (← sourceDir) config
    let m ← metricsOf store
    assertEqual "same root without cache" again root
    assertEqual "no hits" m.cacheHits 0
    assertEqual "all misses" m.cacheMisses baseSpec.size,

  test "caches are keyed per workspace" do
    let store ← withStore
    let _ ← snapshotSpec store baseSpec
    let other := (← scratch) / "other"
    writeSpec other baseSpec
    reset store
    let _ ← assertOk <| store.snapshot other
    assertEqual "sibling workspace misses" (← metricsOf store).cacheMisses baseSpec.size,

  test "the cache survives reopening the store" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let reopened ← assertOk <| Store.create ((← scratch) / "store")
    let again ← assertOk <| reopened.snapshot (← sourceDir)
    let m ← assertOk reopened.metrics
    assertEqual "same root after reopen" again root
    assertEqual "no misses after reopen" m.cacheMisses 0,

  test "a hit is rejected when the blob was collected" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let _ ← assertOk store.gc  -- nothing is pinned: every blob goes
    reset store
    let again ← assertOk <| store.snapshot (← sourceDir)
    assertEqual "same root rebuilt" again root
    assertEqual "hits rejected" (← metricsOf store).cacheHits 0
    let bytes ← assertOk <| store.readPath again "a/b/c.txt"
    assertEqual "content restored" (bytes.map (String.fromUTF8? ·)) (some (some "content-c"))
]

/-! ## Feature 2: diff -/

def diffSuite : Suite := suite "cas.diff" #[
  test "identical snapshots have an empty diff" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertEqual "no changes" (← assertOk <| store.diff root root) #[],

  test "add, remove, and modify are reported with paths" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let source ← sourceDir
    IO.FS.removeFile (source / "a" / "e.txt")
    writeSpec source #[("a/b/c.txt", "changed-c"), ("new/n.txt", "brand new")]
    let v2 ← assertOk <| store.snapshot source
    let changes ← assertOk <| store.diff v1 v2
    let names := (changes.map (·.path)).qsort (compare · · == .lt)
    assertEqual "changed paths" names #["a/b/c.txt", "a/e.txt", "new"]
    for change in changes do
      match change with
      | .modified path type _ =>
        assertEqual "modified path" path "a/b/c.txt"
        assertEqual "modified type" type .file
      | .removed path type =>
        assertEqual "removed path" path "a/e.txt"
        assertEqual "removed type" type .file
      | .added path type _ =>
        assertEqual "added path" path "new"
        assertEqual "added dir stands for its subtree" type .directory,

  test "a type change is a removal plus an addition" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("x", "i was a file")]
    let v1 ← assertOk <| store.snapshot source
    IO.FS.removeFile (source / "x")
    writeSpec source #[("x/inner.txt", "now a directory")]
    let v2 ← assertOk <| store.snapshot source
    let changes ← assertOk <| store.diff v1 v2
    assertEqual "two changes" changes.size 2
    check (changes.any fun c => c matches .removed "x" .file) "file removed"
    check (changes.any fun c => c matches .added "x" .directory _) "directory added"
]

/-! ## Feature 3: incremental, linked materialize -/

def materializeSuite : Suite := suite "cas.materialize" #[
  test "roundtrip reproduces the source exactly" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "specs equal" (← readSpec destination) (← readSpec (← sourceDir)),

  test "a second materialize touches only the changes" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    let source ← sourceDir
    IO.FS.removeFile (source / "dup.txt")
    writeSpec source #[("a/b/c.txt", "changed-c")]
    let v2 ← assertOk <| store.snapshot source
    reset store
    assertOk <| store.materialize v2 destination
    let m ← metricsOf store
    assertEqual "one file rewritten" m.filesWritten 1
    assertEqual "one path deleted" m.filesDeleted 1
    assertEqual "destination matches v2" (← readSpec destination) (← readSpec source),

  test "an untracked non-empty destination errors when asked to" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "do not delete")]
    assertError "materialize" (store.materialize root destination { onExisting := .error })
      isStorage
    assertEqual "destination untouched"
      (← IO.FS.readFile (destination / "precious.txt")) "do not delete"
    -- The default replaces it.
    assertOk <| store.materialize root destination
    assertEqual "replaced" (← readSpec destination) (← readSpec (← sourceDir)),

  test "verify falls back to a full write when the checkout was tampered with" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    IO.FS.writeFile (destination / "shared" / "s.txt") "tampered"
    -- Without verify, the tampered file sits at an unchanged path, so trust leaves it alone.
    assertOk <| store.materialize v1 destination
    assertEqual "trusted checkout untouched"
      (← IO.FS.readFile (destination / "shared" / "s.txt")) "tampered"
    assertOk <| store.materialize v1 destination { verify := true }
    assertEqual "verified checkout repaired"
      (← IO.FS.readFile (destination / "shared" / "s.txt")) "content-s",

  test "a collected previous tree falls back to a full write" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    let _ ← assertOk store.gc  -- v1 is unpinned: its trees vanish
    -- Change a file so the new snapshot does not resurrect v1's root tree.
    writeSpec (← sourceDir) #[("a/b/c.txt", "revived-c")]
    let v2 ← assertOk <| store.snapshot (← sourceDir)
    check (v2 != v1) "snapshots differ"
    assertOk <| store.materialize v2 destination
    assertEqual "full rewrite succeeded" (← readSpec destination) (← readSpec (← sourceDir)),

  test "clone mode produces independent, editable copies" do
    if !System.Platform.isOSX then return ()
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination { linkMode := .clone }
    assertEqual "content via clone" (← readSpec destination) (← readSpec (← sourceDir))
    let cloned ← (destination / "a" / "e.txt").metadata
    assertEqual "clone owns its inode" cloned.numLinks 1
    -- Editing the checkout must not disturb the stored blob (the agent-workspace contract).
    IO.FS.writeFile (destination / "a" / "e.txt") "agent edited this"
    let entry ← assertOk <| store.entryAt? root "a/e.txt"
    let blob ← assertOk <| store.getBytes (entry.map (·.hash)).get!
    assertEqual "blob unchanged after edit" (blob.map (String.fromUTF8? ·))
      (some (some "content-e"))
]

/-! ## Feature 5: metadata -/

def metadataSuite : Suite := suite "cas.metadata" #[
  test "the executable bit survives a roundtrip" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("run.sh", "#!/bin/sh\necho hi\n"), ("plain.txt", "text")]
    setExecutable (source / "run.sh")
    let root ← assertOk <| store.snapshot source
    assertEqual "captured as executable"
      ((← assertOk <| store.entryAt? root "run.sh").map (·.type)) (some .executable)
    assertEqual "plain stays a file"
      ((← assertOk <| store.entryAt? root "plain.txt").map (·.type)) (some .file)
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    check (← isExecutable (destination / "run.sh")) "restored executable"
    check (!(← isExecutable (destination / "plain.txt"))) "restored non-executable",

  test "exec detection can be disabled" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("run.sh", "#!/bin/sh\n")]
    setExecutable (source / "run.sh")
    let root ← assertOk <| store.snapshot source { execBits := false }
    assertEqual "recorded as a plain file"
      ((← assertOk <| store.entryAt? root "run.sh").map (·.type)) (some .file),

  test "symlinks roundtrip as links, including dangling and cyclic ones" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("target.txt", "pointed at")]
    createSymlink "target.txt" (source / "alias")
    createSymlink "does-not-exist" (source / "dangling")
    createSymlink "." (source / "self")  -- would recurse forever if followed
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "relative link" (← readSymlink (destination / "alias")) "target.txt"
    assertEqual "dangling link" (← readSymlink (destination / "dangling")) "does-not-exist"
    assertEqual "cyclic link" (← readSymlink (destination / "self")) ".",

  test "the reject policy refuses symlinks" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("a.txt", "x")]
    createSymlink "a.txt" (source / "alias")
    assertError "snapshot" (store.snapshot source { symlinks := .reject }) isStorage
]

/-! ## Feature 6: ignore rules -/

def ignoreSuite : Suite := suite "cas.ignore" #[
  test "the ignoring matcher implements its documented rules" do
    let matcher := ignoring #["node_modules", "*.log", "build/", "docs/internal"]
    check (matcher "node_modules") "bare component at root"
    check (matcher "a/node_modules") "bare component nested"
    check (!matcher "node_modules_2") "component must match exactly"
    check (matcher "debug.log") "extension at root"
    check (matcher "a/b/debug.log") "extension nested"
    check (!matcher "log") "suffix pattern needs the suffix"
    check (matcher "build") "trailing-slash prunes the directory"
    check (!matcher "build.rs") "trailing-slash is not a prefix of names"
    check (matcher "docs/internal") "embedded slash matches the path"
    check (matcher "docs/internal/notes.md") "embedded slash matches below"
    check (!matcher "docs/internals") "embedded slash is path-exact",

  test "ignored paths are absent from the snapshot" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[
      ("src/main.c", "int main;"), ("src/junk.log", "noise"),
      ("build/out.bin", "artifact"), ("node_modules/dep/index.js", "js")]
    let root ← assertOk <| store.snapshot source
      { ignore := ignoring #["*.log", "build/", "node_modules"] }
    let paths := (← assertOk <| store.listPaths root).map (·.1)
    assertEqual "kept only sources" paths #["src", "src/main.c"],

  test "a custom predicate prunes directories before they are read" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("keep.txt", "k"), ("skip/deep/file.txt", "s")]
    reset store
    let root ← assertOk <| store.snapshot source { ignore := (· == "skip") }
    assertEqual "kept paths" ((← assertOk <| store.listPaths root).map (·.1)) #["keep.txt"]
    assertEqual "pruned files never hashed" (← metricsOf store).cacheMisses 1
]

/-! ## Feature 7: refs and garbage collection -/

def gcSuite : Suite := suite "cas.gc" #[
  test "refs roundtrip and validate their names" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "main" root
    assertEqual "read back" (← assertOk <| store.getRef? "main") (some root)
    assertEqual "absent ref" (← assertOk <| store.getRef? "other") none
    assertOk <| store.setRef "v1.0" root
    assertEqual "listed sorted" ((← assertOk store.listRefs).map (·.1)) #["main", "v1.0"]
    assertOk <| store.deleteRef "v1.0"
    assertEqual "deleted" (← assertOk <| store.getRef? "v1.0") none
    for bad in ["", "..", "a/b", "with space"] do
      assertError s!"ref name {bad}" (store.setRef bad root) isStorage,

  test "gc keeps everything reachable from refs and drops the rest" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "keep" root
    let orphan ← assertOk <| store.putBytes "orphaned bytes".toUTF8
    let stats ← assertOk store.gc
    check (stats.deletedBlobs >= 1) "the orphan went"
    check (stats.keptBlobs >= 1) "the snapshot stayed"
    assertEqual "orphan unreadable" (← assertOk <| store.getBytes orphan) none
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "snapshot fully intact" (← readSpec destination) (← readSpec (← sourceDir)),

  test "deleting the ref releases the snapshot" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "main" root
    let _ ← assertOk store.gc
    assertOk <| store.deleteRef "main"
    let stats ← assertOk store.gc
    check (stats.deletedBlobs >= 1) "snapshot collected"
    assertError "tree gone" (store.getTree root) isStorage,

  test "gc clears leftover temp files" do
    let store ← withStore
    let stray := (← scratch) / "store" / "tmp" / "stray.tmp"
    IO.FS.writeFile stray "leftover"
    let _ ← assertOk store.gc
    check (!(← stray.pathExists)) "tmp swept"
]

/-! ## Feature 4: parallel hashing -/

private def wideSpec : Array (String × String) := Id.run do
  let mut spec := #[]
  for i in [0:40] do
    spec := spec.push (s!"dir{i % 5}/file{i}.txt",
      s!"content-{i}-" ++ String.ofList (List.replicate (16 + i) 'x'))
  return spec

def parallelSuite : Suite := suite "cas.parallel" #[
  test "concurrency does not change the snapshot" do
    let store1 ← assertOk <| Store.create ((← scratch) / "store1")
    let store2 ← assertOk <| Store.create ((← scratch) / "store2")
    let source ← sourceDir
    writeSpec source wideSpec
    let serial ← assertOk <| store1.snapshot source { concurrency := 1, statCache := false }
    let parallel ← assertOk <| store2.snapshot source { concurrency := 8, statCache := false }
    assertEqual "same root either way" parallel serial,

  test "zero concurrency is clamped rather than dividing by zero" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source wideSpec
    let root ← assertOk <| store.snapshot source { concurrency := 0 }
    assertEqual "all files captured"
      ((← assertOk <| store.listPaths root).filter (·.2 == .file)).size wideSpec.size
]

/-! ## Pure path operations (cheap branching) -/

def pathOpsSuite : Suite := suite "cas.pathops" #[
  test "writePath forks a snapshot without touching the original" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "a/b/c.txt" "forked".toUTF8
    check (forked != root) "fork has a new root"
    assertEqual "fork sees the write"
      ((← assertOk <| store.readPath forked "a/b/c.txt").map (String.fromUTF8? ·))
      (some (some "forked"))
    assertEqual "original unchanged"
      ((← assertOk <| store.readPath root "a/b/c.txt").map (String.fromUTF8? ·))
      (some (some "content-c"))
    assertEqual "sibling entry shared"
      (← assertOk <| store.entryAt? forked "shared") (← assertOk <| store.entryAt? root "shared"),

  test "writePath creates missing directories" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "brand/new/leaf.txt" "deep".toUTF8
    assertEqual "deep read"
      ((← assertOk <| store.readPath forked "brand/new/leaf.txt").map (String.fromUTF8? ·))
      (some (some "deep"))
    assertEqual "intermediate is a directory"
      ((← assertOk <| store.entryAt? forked "brand/new").map (·.type)) (some .directory),

  test "writePath refuses to descend through a file" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertError "descend through file" (store.writePath root "dup.txt/inner" "x".toUTF8)
      isStorage
    assertError "unsafe path" (store.writePath root "../escape" "x".toUTF8) isStorage
    assertError "directory type" (store.writePath root "d" "x".toUTF8 (type := .directory))
      isStorage,

  test "removePath removes and is idempotent" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let removed ← assertOk <| store.removePath root "a/b/c.txt"
    assertEqual "gone" (← assertOk <| store.readPath removed "a/b/c.txt") none
    assertEqual "sibling kept"
      ((← assertOk <| store.readPath removed "a/b/d.txt").map (String.fromUTF8? ·))
      (some (some "content-d"))
    assertEqual "absent removal is the identity"
      (← assertOk <| store.removePath removed "no/such/path") removed,

  test "a forked snapshot materializes like any other" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "new.sh" "#!/bin/sh\n".toUTF8 (type := .executable)
    let destination := (← scratch) / "out"
    assertOk <| store.materialize forked destination
    check (← isExecutable (destination / "new.sh")) "pure write carries its type"
    assertEqual "rest intact" (← IO.FS.readFile (destination / "dup.txt")) "content-c",

  test "readPath and entryAt? answer none for absent paths and directories" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertEqual "absent" (← assertOk <| store.readPath root "nope.txt") none
    assertEqual "directory read" (← assertOk <| store.readPath root "a/b") none
    assertEqual "listPaths types" ((← assertOk <| store.listPaths root).filter
      (·.2 == .directory)).size 3
]

def suites : Array Suite := #[
  objectSuite, merkleSuite, statCacheSuite, diffSuite, materializeSuite,
  metadataSuite, ignoreSuite, gcSuite, parallelSuite, pathOpsSuite]

end CasTests
