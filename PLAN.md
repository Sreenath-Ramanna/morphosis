# Plan — the catalogue

Morphosis remembers the frames it has worked on: what they were called, what
they are (by content, not by path), when they were taken, what keywords the
photographer gave them, and what adjustments were applied.

The store is SQLite, behind an interface that does not mention SQL, so it can
be replaced later without touching anything that uses it.

Implemented. Phases A–D are done; E remains unscheduled. This document is the
*what and why*; the phases at the end record where each one landed.

---

## 0. Terminology

A few words are used differently below than in the request, so that the
document and the code agree. Nothing is wrong with the originals; these are
just the terms the rest of the codebase already uses.

| request | used here | why |
|---|---|---|
| SHA256 sum | **SHA-256 digest** | "sum" belongs to checksums, which are error-detecting; a digest is cryptographic, which is what makes it usable as an identity |
| the manipulations done by the user | **the adjustments**, or **the edit** | `Edit` is already the name of that value in the code |
| a user input keywords | **the keywords** | |
| cataloguing | unchanged | correct as written; "cataloging" is the American spelling of the same word |

---

## 1. What already exists

**The edit is already one value.** `Edit` in `lib/src/model/edit.dart` holds
every adjustment — temperature, four zones, brightness, contrast, sharpness,
rolloff — and `Geometry` holds rotation and crop. It is immutable, has value
equality, and is already the single thing that changes when a control moves.
Serialising it is a matter of writing `toJson`/`fromJson`, not of gathering
state from across the app.

**The capture date is decoded but thrown away.** `ria_metadata.timestamp`
(seconds since the Unix epoch) is read by the C library and is present in the
FFI struct in `bindings.dart`, but `RawMetadata` in `ria.dart` does not carry
it. One field on each, and it is available.

**Nothing hashes anything.** New.

**SQLite is already on the machine** — `sqlite-libs 3.51.2`, providing
`/usr/lib64/libsqlite3.so.0`. `package:crypto` is already in the pub cache.

---

## 2. The storage interface

The requirement is that SQLite can be swapped out later. That is a constraint
on *what the rest of the app is allowed to know*, and it is met by one rule:

> Nothing outside `lib/src/catalog/sqlite/` may import a SQLite package, and
> the interface must never expose SQL, a row, a connection, a transaction, or
> a generated id.

Concretely:

```
lib/src/catalog/
  catalog.dart              the port: CatalogStore and its value types
  catalog_entry.dart        CatalogEntry, KeywordSet — plain values
  memory_catalog.dart       an in-memory implementation, for tests
  sqlite/
    sqlite_catalog.dart     the only file that imports package:sqlite3
    migrations.dart         schema versions, forward-only
```

The port, in terms of what the application actually needs to ask:

```dart
abstract interface class CatalogStore {
  Future<void> open();
  Future<void> close();

  /// The catalogued image with this content, wherever it lives.
  Future<CatalogEntry?> byDigest(String sha256);

  /// The fast path: has this exact file been seen before, at this size and
  /// modification time? Answers without hashing. Null means "do not know" —
  /// never "no".
  Future<CatalogEntry?> byPathHint(String path, int sizeBytes, DateTime mtime);

  /// Record or update. Idempotent on the digest.
  Future<void> put(CatalogEntry entry);

  /// Every path this content has been seen at, most recently seen first.
  Future<List<SeenAt>> locationsOf(String sha256);

  Future<List<CatalogEntry>> search({
    String? keyword,
    DateTimeRange? captured,
    int limit,
    int offset,
  });

  /// Every keyword used so far, with counts — for autocomplete.
  Future<List<KeywordCount>> keywords();
}
```

Notice what is absent: no `execute`, no `query`, no id column, no cursor. A
replacement backed by Postgres, a document store, or a flat file on a NAS
implements the same nine methods.

`MemoryCatalog` is not a throwaway. It is what the tests run against, and
keeping it correct is what proves the interface is not secretly
SQLite-shaped.

### Recommended package

**`package:sqlite3`** — a thin FFI binding to `libsqlite3`, synchronous, no
code generation.

- *drift* is rejected: it is an ORM with its own abstraction and codegen, and
  building a second abstraction on top of it to satisfy the swap-out
  requirement would mean two layers doing one job.
- *sqflite_common_ffi* is rejected: it wraps `package:sqlite3` to present the
  mobile `sqflite` API, which buys nothing on desktop.

Whether to link the system `libsqlite3` or bundle one is a packaging question,
not a design one. Linking the system library matches how LibRaw is already
handled and keeps the bundle small; bundling removes a runtime dependency.
Start with the system library and revisit only if a target platform lacks it.

---

## 3. Where things live

```
~/.local/share/com.morphosis.morphosis/catalog.db    the catalogue
~/.config/com.morphosis.morphosis/                   preferences, when there are any
~/.local/lib/morphosis/                              the application bundle
~/.local/bin/morphosis                               symlink to it
```

XDG paths throughout, honouring `XDG_DATA_HOME`, `XDG_CONFIG_HOME` and
`XDG_BIN_HOME` where set. The catalogue is user data — keywords typed and
edits made, which nothing can regenerate — so it sits in the data directory
under the application id, not in the config directory.

**`scripts/install.sh` has to move the bundle out of
`~/.local/share/com.morphosis.morphosis/` before Phase B.** It installs there
today and begins by deleting that directory, so a catalogue written to the
path above would be destroyed by every install. Moving the bundle to
`~/.local/lib/morphosis/` frees the data directory and is the prerequisite,
not a nicety.

---

## 4. Identity: what the digest does and does not do

The premise in the request is correct: **a SHA-256 digest identifies the file
after it is copied elsewhere**, because a copy is byte-identical and hashing is
deterministic. Copy a NEF to a NAS, open it from there, and the catalogue finds
the same entry with the same keywords.

It is worth being precise about the edges, because the failure mode is silent —
a frame that quietly appears uncatalogued:

**It matches, correctly:** copies, moves, renames, restores from backup, the
same card copied to two machines.

**It does not match:**

- a file converted to DNG, or to any other format — different bytes;
- a file some other tool has written into. Several cataloguing programs embed
  XMP sidecar data *inside* the RAW rather than beside it, which changes the
  digest. Morphosis never writes to a RAW, so it will not do this to itself,
  but another program in the same workflow can;
- two exposures of the same scene, which are different photographs and should
  not match;
- a truncated or partially copied file, which is the case worth surfacing —
  see the size check below.

**Two files with the same digest are the same bytes**, so the digest is the
primary key of an image's identity, and a path is merely somewhere it has been
seen. That shapes the schema in §5: one row per image, many rows per location.

### The cost, measured

Pure-Dart SHA-256 through `package:crypto`, on this machine:

| file | size | hashed | throughput |
|---|---|---|---|
| Canon CR3 | 22.3 MB | 257 ms | 87 MB/s |
| Nikon NEF | 29.8 MB | 336 ms | 89 MB/s |

Streaming the file rather than reading it whole costs about the same
(272 ms / 369 ms) and does not hold 30 MB in memory, so stream.

`sha256sum` does the same work in 21 ms because it uses the CPU's SHA-NI
instructions, which Dart's implementation does not. **A factor of fifteen is
not worth ignoring**: if hashing ever needs to be fast, the right answer is a
small addition to `raw_images_api` calling OpenSSL, not a faster Dart loop.
That is Phase E, and only if measurement justifies it.

### What this cost rules out

**Hashing a folder on open is not viable.** Three hundred frames is 90 seconds
of CPU; a thousand is five minutes. The folder list must appear instantly, as
it does today.

So identity is established lazily, in this order:

1. **On folder load** — no hashing. Look each file up by
   `(path, size, mtime)`. A hit gives the entry immediately; a miss means only
   "not known by that hint".
2. **On opening a frame** — hash it, on a background isolate, while the decode
   is already running. The decode takes 1.9 s and the hash 0.3 s, so it is
   free in wall-clock terms.
3. **Never on a slider move.**

The `(path, size, mtime)` hint is a cache, not an identity. It can be wrong —
a file replaced in place within the same second, with the same size — so it is
only ever used to *avoid* recomputation, and the stored digest is refreshed
whenever a frame is actually opened. A size mismatch against the stored size is
worth reporting: it means the file at that path is no longer the file that was
catalogued.

---

## 5. Schema

Two tables, because an image and a place it has been seen are different
things.

```sql
CREATE TABLE image (
  sha256        TEXT PRIMARY KEY,      -- lowercase hex, 64 chars
  display_name  TEXT NOT NULL,         -- the name most recently seen
  size_bytes    INTEGER NOT NULL,
  captured_at   INTEGER,               -- Unix seconds, NULL if the file says nothing
  camera        TEXT,                  -- "Canon EOS R7", for a legible catalogue
  keywords      TEXT NOT NULL DEFAULT '',   -- comma-separated, as requested
  edit_json     TEXT,                  -- the adjustments, see §6
  edit_version  INTEGER,               -- schema version of edit_json
  first_seen    INTEGER NOT NULL,
  last_edited   INTEGER NOT NULL
);

CREATE TABLE location (
  sha256      TEXT NOT NULL REFERENCES image(sha256) ON DELETE CASCADE,
  path        TEXT NOT NULL,
  mtime       INTEGER NOT NULL,
  size_bytes  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL,
  PRIMARY KEY (sha256, path)
);

CREATE INDEX location_hint ON location(path, size_bytes, mtime);
CREATE INDEX image_captured ON image(captured_at);
```

`keywords` is stored as the single comma-separated string the request asks
for, and that is the right call for now: it is what the user types, it round
trips exactly, and it needs no join. Searching it means `LIKE '%,foo,%'`
against a normalised form, which is a table scan — fine for thousands of
images, wrong for a hundred thousand.

**When that stops being fine**, the fix is a `keyword` and `image_keyword`
pair, and the migration is mechanical because the interface returns
`List<KeywordCount>` rather than a string. The interface is already shaped for
the better schema; only the implementation is lazy. That is deliberate, and it
is the thing to remember if the store is ever swapped.

Migrations are forward-only, keyed on `PRAGMA user_version`, each an
idempotent function. There is no downgrade path; an older build refusing to
open a newer catalogue is better than one silently misreading it.

---

## 6. The adjustments as JSON

```json
{
  "v": 1,
  "temperatureK": 6400.0,
  "blackEv": -0.6, "shadowEv": 1.4, "highlightEv": -0.9, "whiteEv": 0.4,
  "brightnessEv": 0.3, "contrastEv": 0.7,
  "sharpness": 0.6, "highlightRolloff": true,
  "geometry": {
    "quarterTurns": 1, "straightenDegrees": 4.0,
    "crop": [0.15, 0.1, 0.85, 0.7], "aspect": "3:2"
  }
}
```

Three rules that matter more than the field names:

**Every document carries `v`.** The version is the whole reason a stored edit
survives the app changing. `fromJson` must accept every version it has ever
written and upgrade in memory; the alternative is a catalogue full of edits
that cannot be read back.

**Absent means default, never zero.** A field added in v2 will be missing from
every v1 document. `fromJson` fills from `Edit`'s own defaults, so an old
document reads as an old edit rather than as one with a black point of zero
that the photographer never chose.

**Only what the photographer chose.** No derived values — not the automatic
grey point, not the render time, not the preview size. Those are properties of
the decode and will be recomputed. Storing them invites a future reader to
trust a stale one.

---

## 7. Capture date

`ria_metadata.timestamp` already carries it. Add `timestamp` to
`RawMetadata`, convert to `DateTime` at the boundary, and treat 0 as unknown —
the C library zero-fills the struct on a failed read, and 1970 is not a
plausible capture date for a RAW file.

Store it as Unix seconds rather than as text. It is a point in time, it sorts
correctly as an integer, and no timezone question arises because none of the
answers the app gives depend on one. Rendering it for display is the UI's
business.

---

## 8. When a row is written

The request says "each time a RAW image is manipulated". Taken literally that
is every frame of every slider drag — ten writes a second, most of them
superseded a moment later.

What it should mean:

| event | what happens |
|---|---|
| a frame is opened | look up, hash, record the location, do **not** write an edit |
| an adjustment changes | mark dirty; start a 2-second timer, restarted on each further change |
| the timer expires | one write |
| the frame is closed or another is selected | flush immediately, cancel the timer |
| an export completes | flush immediately |
| the app is closing | flush immediately |
| keywords change | flush immediately — typing is deliberate and rare |

A frame opened and closed with nothing touched does not create an edit; it
records that the image was seen. Whether that alone should create an `image`
row is an open decision — see §11.

---

## 9. The keyword control

The left column is 210 px wide and holds the folder list at full height. The
request is for the bottom third to become a keyword editor.

```
┌──────────────────┐
│  folder list     │   flexible, takes what is left
│                  │
│                  │
├──────────────────┤   draggable divider
│  KEYWORDS        │   fixed, about a third, min 140 px
│  ┌────┐┌───────┐ │
│  │gull││coast ×│ │   chips, each removable
│  └────┘└───────┘ │
│  ┌──────────────┐│
│  │ add keyword… ││   text field, comma or Enter commits
│  └──────────────┘│
│  12 images share │
│  "coast"         │
└──────────────────┘
```

Four notes on the design:

**Widen the column to 260 px.** 210 px was chosen for a filename and a
thumbnail. A keyword field in it will wrap after one short word. This is a
change to an existing layout, so it wants checking against the golden test.

**Chips, with the comma-separated string underneath.** The stored form stays
exactly what the request specifies — one comma-separated string — but a text
field where a stray comma silently creates an empty keyword is unpleasant to
use. The control parses on input and joins on save; `KeywordSet` owns that
round trip and is worth a test of its own (trimming, case, duplicates, empty
segments, a comma typed inside a word).

**Autocomplete from `keywords()`.** The catalogue already knows every keyword
used. Offering them prevents the split between "coast", "Coast" and "coastal"
that makes a catalogue useless within a year. Recommendation: match
case-insensitively, store what the user typed the first time, and offer that
casing thereafter.

**Keywords belong to the image, not the file.** They are keyed by digest, so
they follow the photograph to the NAS — which is the point of the whole
feature.

---

## 10. Threading

The render worker must not touch the database. It owns 100–200 MB of pixels
and a blocking SQLite call in it would stall the canvas.

- **Hashing** runs on a short-lived isolate per file, started alongside the
  decode.
- **The catalogue** gets its own long-lived isolate, `CatalogService`, with
  the same request/reply shape as `Processor`. `package:sqlite3` is
  synchronous and FFI, so it must not run on the UI isolate.
- The UI holds only plain values.

One writer, one connection, `PRAGMA journal_mode = WAL`. Concurrency is not a
requirement here — one person, one window — and pretending otherwise would add
a locking design nobody needs.

---

## 11. Decisions

Settled before the schema set, because changing them later means a migration.

**Opening a frame writes a row.** Identity, display name, size, capture date and
camera; `edit_json` stays NULL and `keywords` empty. `edit_json IS NOT NULL` is
what "has been worked on" means, which keeps a frame merely looked at from
claiming an edit nobody made. The alternative in an earlier draft — locations
for everything, rows only for edited frames — cannot hold: `location.sha256`
references `image(sha256)`, so a location cannot exist without its row. A row is
about 200 bytes.

**A stored edit is restored when the frame is reopened, and the editor says
so.** The Colors tab carries a line reading "Edited 4 September · restored" with
a one-click Revert. Storing adjustments and then ignoring them is the strange
option; restoring them silently would surprise, because frames used to open
neutral. Revert clears the stored edit rather than storing neutral — the
photographer never chose anything, as against choosing nothing.

**A second path for the same digest adds a location, with no warning.** A card
and a NAS holding one photograph is normal. The *conflict* — the same path now
holding different content — moves the location to the new digest, because the
file that was there has been replaced and the catalogue must stop claiming
otherwise. `location` is keyed on `path` alone so the schema enforces this
rather than every write having to.

**The catalogue is not exportable.** A sidecar JSON per image would make the
data portable and survive a corrupted database. Cheap to add later, out of scope
now.

## 12. Risks

**The install script deletes its own prefix.** Addressed: the bundle moved to
`~/.local/lib/morphosis/`, and `install.sh` now refuses to run if it finds a
`catalog.db` in the prefix. The guard stays because the failure loses user data
and is silent — nothing else in this document does both.

**Pure-Dart hashing is fifteen times slower than the hardware can do it.**
Tolerable at 0.3 s per frame in the background; not tolerable if a "hash this
whole library" feature is ever added. §4 names the fix.

**A digest is not a photograph.** Convert to DNG and the link is gone. If
format-independent identity is ever wanted, that is a different feature built
on capture time plus camera plus a perceptual hash, and it is much harder. Do
not let the catalogue imply it can do this.

**The comma-separated keyword column is a scan.** §5. Fine now, and the
interface already hides it, but it should not be discovered under a hundred
thousand images.

**Time in the store is UTC seconds and time on screen is local.** Convert at
exactly one boundary. Getting this wrong produces dates that are right most of
the year, which is the hardest kind of wrong to notice.

---

## 13. Phases

| | | |
|---|---|---|
| **A** | `CatalogStore`, `CatalogEntry`, `KeywordSet`, `MemoryCatalog`, and the tests they share | done |
| **B** | The bundle moved to `~/.local/lib/morphosis/` in `install.sh` (§3), then `SqliteCatalogStore`, migrations, `CatalogService` isolate | done |
| **C** | `Edit.toJson`/`fromJson` with versioning; the capture date through to `RawMetadata`; streaming digest on an isolate | done |
| **D** | The keyword panel, the wider column, autocomplete, and the write policy in §8 | done |
| **E** | *Unscheduled.* A native SHA-256 in `raw_images_api`, only if measurement asks for it | — |

Phase A's tests became `test/catalog/catalog_contract.dart`, and they run against
all three implementations: `MemoryCatalog`, `SqliteCatalogStore`, and
`CatalogService` down an isolate port. Not one assertion had to be relaxed for
any of them, which is the evidence that the interface is not SQLite-shaped.

Three things came out of building it that the design above did not anticipate:

- **`libsqlite3.so` is absent on a machine with only the runtime package** —
  there is just `libsqlite3.so.0`. `package:sqlite3` opens the former by
  default, so `sqlite_catalog.dart` carries a fallback chain. Choosing the
  system library over a bundled one (§2) is what costs this.
- **`sqlite3` is pinned to `^2.4.0`.** 3.x pulls twelve packages and a C
  toolchain to compile SQLite from source, which §2's choice makes dead weight.
- **The catalogue opens while the first frame is already decoding.** The hash
  starts immediately and meets the catalogue when both are ready; gating the
  hash on the database instead would leave the frame named on the command line
  uncatalogued for the whole session.

A before B is not negotiable: writing the in-memory implementation first is
what stops the interface being shaped by SQLite. If `MemoryCatalog` is awkward
to write, the interface is wrong, and that is much cheaper to learn before
there is a schema.

C is independent of A and B and can be done in any order. D needs all of them.

**Ships as one feature.** A catalogue that stores adjustments but has no
keyword control, or one that has the control but forgets on restart, is not
worth putting in front of anyone.
