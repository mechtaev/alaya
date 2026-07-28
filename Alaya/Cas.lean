import Alaya.Cas.Core
import Alaya.Cas.Sha256
import Alaya.Cas.Store
import Alaya.Cas.Workspace

/-!
A content-addressed store with git-style Merkle snapshots.

- `Cas.Store.create` opens a store; `putBytes`/`getBytes` are the blob layer.
- `Store.snapshot` captures a directory (stat-cached, parallel-hashed, ignore-filtered,
  symlink- and exec-bit-aware); `Store.materialize` writes a snapshot back out
  incrementally by diffing against the destination's previous checkout.
- `Store.readPath`/`writePath`/`removePath`/`listPaths` edit snapshots purely — cheap
  branching without touching the working directory.
- `Store.setRef` pins snapshots by name; `Store.gc` collects everything unreachable.
-/
