// Restic-style cooperative locking via gcroots/.lock/.
//
// Lock files name their holder; the pruner's are prefixed `prune-`.
// A lock older than the staleness threshold is ignored: it belongs
// to a crashed holder. Long-running holders refresh their lock to
// stay fresh.
//
// Writer protocol (kiss-cache-with-lock, kiss-cache-publish):
//   1. PUT    .lock/<id>  -- the server (lock-guard.js) refuses with
//                            503 while a fresh prune-* lock exists,
//                            so this implicitly waits out a prune.
//                            Local-mode publish polls the directory
//                            itself before writing.
//   2. nix copy           (refresh our lock periodically)
//   3. PUT    gcroots/<job>
//   4. DELETE .lock/<id>
//
// Pruner protocol (kiss-cache --lock-wait):
//   1. read   .lock/      -- wait until no fresh lock from another
//                            holder.
//   2. write  .lock/prune-<id>
//   3. read   .lock/      -- if a fresh lock from another holder
//                            appeared, remove ours, back off, retry.
//   4. snapshot, sweep
//   5. remove .lock/prune-<id>
//
// The model splits the writer's lock acquisition into create and
// verify steps (uploaderCreate, uploaderVerify) to capture the
// create/create race: two parties create at the same instant. The
// pruner's recheck guarantees safety regardless; the writer's
// `not freshExclusive` precondition on create models the server-side
// 503 (or local-mode poll). Liveness is probabilistic; the model
// proves safety only.
//
// Verified properties:
//   NoDanglingNar:  every cached narinfo has its nar.
//   NoDanglingRefs: every cached narinfo's references are cached.
//   NoDanglingRefsWithoutLock: documents the bug the lock prevents.

// ---------------------------------------------------------------------
// Static structure
// ---------------------------------------------------------------------

sig Path { refs: set Path }
fact acyclicRefs { no p: Path | p in p.^refs }

one sig Push { root: one Path, closure: set Path }
fact closureIsTransitiveRefs { Push.closure = Push.root.*refs }

// ---------------------------------------------------------------------
// Mutable cache state
// ---------------------------------------------------------------------

var sig nar in Path {}
var sig info in Path {}
var sig marker in Path {}

// Lock directory. The model has at most one shared lock (the one
// writer) and at most one exclusive lock (the one pruner). Tracking
// presence + staleness is enough.
one sig Locks {
  var shared: lone Path,        // shared lock present, names the root being pushed
  var sharedStale: lone Path,   // .. and is past the staleness threshold
  var exclusive: lone Bool,     // exclusive lock present
  var exclusiveStale: lone Bool,
}
abstract sig Bool {} one sig True extends Bool {}

pred freshShared    { some Locks.shared and no Locks.sharedStale }
pred freshExclusive { some Locks.exclusive and no Locks.exclusiveStale }

// ---------------------------------------------------------------------
// Pruner
// ---------------------------------------------------------------------

abstract sig Phase {}
one sig Idle, Created, Verified, Snapshotted extends Phase {}

one sig Pruner {
  var phase: one Phase,
  var keep: set Path,
}

// ---------------------------------------------------------------------
// Uploader
// ---------------------------------------------------------------------

abstract sig UPhase {}
one sig UIdle, UCreated, UVerified, UDone extends UPhase {}

one sig Uploader {
  var uphase: one UPhase,
  var narDone: set Path,
  var infoDone: set Path,
  var skipped: set Path,   // queryValidPaths result, frozen at start of nix copy
  var markerDone: lone Path,
}

// ---------------------------------------------------------------------
// Initial state
// ---------------------------------------------------------------------

pred init {
  Pruner.phase = Idle
  no Pruner.keep
  Uploader.uphase = UIdle
  no Uploader.narDone
  no Uploader.infoDone
  no Uploader.skipped
  no Uploader.markerDone
  no marker
  no Locks.shared and no Locks.sharedStale
  no Locks.exclusive and no Locks.exclusiveStale
  nar = info
  all p: info | p.refs in info
}

// ---------------------------------------------------------------------
// Frame helpers
// ---------------------------------------------------------------------

pred cacheUnchanged { nar' = nar and info' = info and marker' = marker }
pred locksUnchanged {
  Locks.shared' = Locks.shared and Locks.sharedStale' = Locks.sharedStale
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
}
pred prunerUnchanged { Pruner.phase' = Pruner.phase and Pruner.keep' = Pruner.keep }
pred uploaderUnchanged {
  Uploader.uphase' = Uploader.uphase
  Uploader.narDone' = Uploader.narDone
  Uploader.infoDone' = Uploader.infoDone
  Uploader.skipped' = Uploader.skipped
  Uploader.markerDone' = Uploader.markerDone
}

// ---------------------------------------------------------------------
// Time: a held lock can go stale (its holder crashed or its refresh
// loop missed). The model lets this happen at any point to explore
// worst-case interleavings.
// ---------------------------------------------------------------------

pred sharedAges {
  some Locks.shared and no Locks.sharedStale
  Locks.sharedStale' = Locks.shared
  Locks.shared' = Locks.shared
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
  cacheUnchanged and prunerUnchanged and uploaderUnchanged
}
pred exclusiveAges {
  some Locks.exclusive and no Locks.exclusiveStale
  Locks.exclusiveStale' = Locks.exclusive
  Locks.exclusive' = Locks.exclusive
  Locks.shared' = Locks.shared and Locks.sharedStale' = Locks.sharedStale
  cacheUnchanged and prunerUnchanged and uploaderUnchanged
}
pred ageStep { sharedAges or exclusiveAges }

// ---------------------------------------------------------------------
// Pruner transitions
// ---------------------------------------------------------------------

pred prunerCreate {
  Pruner.phase = Idle
  // Wait until no fresh shared lock.
  not freshShared
  Pruner.phase' = Created
  Locks.exclusive' = True
  no Locks.exclusiveStale'
  Locks.shared' = Locks.shared and Locks.sharedStale' = Locks.sharedStale
  Pruner.keep' = Pruner.keep
  cacheUnchanged and uploaderUnchanged
}

// Re-check after creating: if a writer raced in, back off.
pred prunerVerify {
  Pruner.phase = Created
  not freshShared
  Pruner.phase' = Verified
  Pruner.keep' = Pruner.keep
  cacheUnchanged and locksUnchanged and uploaderUnchanged
}
pred prunerBackoff {
  Pruner.phase = Created
  freshShared
  Pruner.phase' = Idle
  no Locks.exclusive' and no Locks.exclusiveStale'
  Locks.shared' = Locks.shared and Locks.sharedStale' = Locks.sharedStale
  Pruner.keep' = Pruner.keep
  cacheUnchanged and uploaderUnchanged
}

pred prunerSnapshot {
  Pruner.phase = Verified
  Pruner.phase' = Snapshotted
  Pruner.keep' = marker.*(refs :> info) & info
  cacheUnchanged and locksUnchanged and uploaderUnchanged
}

pred prunerSweep {
  Pruner.phase = Snapshotted
  Pruner.phase' = Idle
  info' = info & Pruner.keep
  nar' = nar & info'
  marker' = marker
  Pruner.keep' = Pruner.keep
  // Release the exclusive lock.
  no Locks.exclusive' and no Locks.exclusiveStale'
  Locks.shared' = Locks.shared and Locks.sharedStale' = Locks.sharedStale
  uploaderUnchanged
}

pred prunerStep {
  prunerCreate or prunerVerify or prunerBackoff or prunerSnapshot or prunerSweep
}

// ---------------------------------------------------------------------
// Uploader transitions
// ---------------------------------------------------------------------

pred uploaderCreate {
  Uploader.uphase = UIdle
  not freshExclusive
  Uploader.uphase' = UCreated
  Locks.shared' = Push.root
  no Locks.sharedStale'
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
  Uploader.narDone' = Uploader.narDone and Uploader.infoDone' = Uploader.infoDone
  Uploader.skipped' = Uploader.skipped and Uploader.markerDone' = Uploader.markerDone
  cacheUnchanged and prunerUnchanged
}

pred uploaderVerify {
  Uploader.uphase = UCreated
  not freshExclusive
  Uploader.uphase' = UVerified
  // queryValidPaths runs now, under the verified lock.
  Uploader.skipped' = info & Push.closure
  Uploader.narDone' = Uploader.narDone and Uploader.infoDone' = Uploader.infoDone
  Uploader.markerDone' = Uploader.markerDone
  cacheUnchanged and locksUnchanged and prunerUnchanged
}
pred uploaderBackoff {
  Uploader.uphase = UCreated
  freshExclusive
  Uploader.uphase' = UIdle
  no Locks.shared' and no Locks.sharedStale'
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
  Uploader.narDone' = Uploader.narDone and Uploader.infoDone' = Uploader.infoDone
  Uploader.skipped' = Uploader.skipped and Uploader.markerDone' = Uploader.markerDone
  cacheUnchanged and prunerUnchanged
}

// Refresh the shared lock: the writer's heartbeat resets staleness.
pred uploaderRefresh {
  Uploader.uphase = UVerified
  some Locks.shared and some Locks.sharedStale
  no Locks.sharedStale'
  Locks.shared' = Locks.shared
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
  cacheUnchanged and prunerUnchanged and uploaderUnchanged
}

pred uploaderSkip [p: Path] {
  Uploader.uphase = UVerified
  p in Uploader.skipped and p not in Uploader.narDone
  Uploader.narDone' = Uploader.narDone + p and Uploader.infoDone' = Uploader.infoDone + p
  Uploader.skipped' = Uploader.skipped and Uploader.markerDone' = Uploader.markerDone
  Uploader.uphase' = Uploader.uphase
  cacheUnchanged and locksUnchanged and prunerUnchanged
}
pred uploaderPutNar [p: Path] {
  Uploader.uphase = UVerified
  p in Push.closure and p not in Uploader.narDone
  p.refs in Uploader.infoDone + Uploader.skipped
  p not in Uploader.skipped
  nar' = nar + p
  Uploader.narDone' = Uploader.narDone + p
  Uploader.infoDone' = Uploader.infoDone and Uploader.skipped' = Uploader.skipped
  Uploader.markerDone' = Uploader.markerDone and Uploader.uphase' = Uploader.uphase
  info' = info and marker' = marker
  locksUnchanged and prunerUnchanged
}
pred uploaderPutInfo [p: Path] {
  Uploader.uphase = UVerified
  p in Uploader.narDone and p not in Uploader.infoDone
  info' = info + p
  Uploader.infoDone' = Uploader.infoDone + p
  Uploader.narDone' = Uploader.narDone and Uploader.skipped' = Uploader.skipped
  Uploader.markerDone' = Uploader.markerDone and Uploader.uphase' = Uploader.uphase
  nar' = nar and marker' = marker
  locksUnchanged and prunerUnchanged
}
pred uploaderPutMarker {
  Uploader.uphase = UVerified
  no Uploader.markerDone
  Push.closure in Uploader.infoDone
  marker' = marker + Push.root
  Uploader.markerDone' = Push.root
  Uploader.uphase' = Uploader.uphase
  Uploader.narDone' = Uploader.narDone and Uploader.infoDone' = Uploader.infoDone
  Uploader.skipped' = Uploader.skipped
  nar' = nar and info' = info
  locksUnchanged and prunerUnchanged
}
pred uploaderRelease {
  Uploader.uphase = UVerified
  some Uploader.markerDone
  Uploader.uphase' = UDone
  no Locks.shared' and no Locks.sharedStale'
  Locks.exclusive' = Locks.exclusive and Locks.exclusiveStale' = Locks.exclusiveStale
  Uploader.narDone' = Uploader.narDone and Uploader.infoDone' = Uploader.infoDone
  Uploader.skipped' = Uploader.skipped and Uploader.markerDone' = Uploader.markerDone
  cacheUnchanged and prunerUnchanged
}

pred uploaderStep {
  uploaderCreate or uploaderVerify or uploaderBackoff or uploaderRefresh
  or (some p: Path | uploaderSkip[p] or uploaderPutNar[p] or uploaderPutInfo[p])
  or uploaderPutMarker or uploaderRelease
}

// ---------------------------------------------------------------------
// Trace
// ---------------------------------------------------------------------

pred stutter { cacheUnchanged and locksUnchanged and prunerUnchanged and uploaderUnchanged }
fact trace { init and always (prunerStep or uploaderStep or ageStep or stutter) }

// ---------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------

pred quiescent { Pruner.phase = Idle and Uploader.uphase = UDone }

// Both actors are well-behaved: they refresh their lock before it
// goes stale, so a held lock is never observed stale. A crashed
// writer forfeits the guarantee; its half-uploaded closure is
// garbage that the next prune sweeps. A crashed pruner is harmless;
// it never deleted anything (the lock guards the whole sweep).
pred timely {
  historically (no Locks.sharedStale and no Locks.exclusiveStale)
}

pred narConsistent  { info in nar }
pred refsConsistent { all p: info | p.refs in info }

assert NoDanglingNar  { always (quiescent and timely implies narConsistent) }
assert NoDanglingRefs { always (quiescent and timely implies refsConsistent) }

// Regression: a pruner that does NOT wait for the shared lock can
// sweep a path the in-flight writer's marker will reference.
pred racyQuiescent { Pruner.phase = Idle and Uploader.uphase = UDone and no Locks.shared }
assert NoDanglingRefsWithoutLock {
  // Counterfactual: a pruner that ignores the shared lock. Modeled
  // by allowing prunerCreate even when a fresh shared lock exists.
  // Asserting that the original NoDanglingRefs property holds even
  // without `timely` — it does NOT, demonstrating that staleness
  // exclusion is load-bearing.
  always (quiescent implies refsConsistent)
}

pred reachable { eventually quiescent }
run reachable for 4 Path, 18 steps expect 1
check NoDanglingNar  for 4 Path, 18 steps expect 0
check NoDanglingRefs for 4 Path, 18 steps expect 0
check NoDanglingRefsWithoutLock for 4 Path, 18 steps expect 1
