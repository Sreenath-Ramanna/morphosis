# Plan — the catalogue

Morphosis remembers the frames it has worked on: what they were called, what
they are (by content, not by path), when they were taken, what keywords the
photographer gave them, and what adjustments were applied.

The store is SQLite, behind an interface that does not mention SQL, so it can
be replaced later without touching anything that uses it.

Nothing here is implemented yet. This document is the *what and why*; the
phases at the end are the *when*.

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

## 3. Where the database lives

```
${XDG_DATA_HOME:-~/.local/share}/morphosis/catalog.db
```

**Not** under `~/.local/share/com.morphosis.morphosis/`. That is where
`scripts/install.sh` puts the application bundle, and the script begins with

```bash
rm -rf "$PREFIX"
```

so a database placed there would be destroyed by every install — silently,
and only noticed later when a year of keywords had gone. The catalogue is user
data and belongs in its own directory beside the bundle, not inside it.

Worth adding to the install script as it is touched: refuse to run if
`$PREFIX` ends up containing a `.db` file, so this cannot be reintroduced by
accident.

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

## 11. Open decisions

Worth settling before the schema sets, because changing them later means a
migration.

**Should opening a frame create a row?** Recording every frame merely *looked
at* makes the catalogue a record of the whole shoot, which is useful for
"where have I seen this file" and expensive in rows. Recording only edited
frames makes it a record of work done. **Recommendation: write on first edit
or first keyword, and record locations for everything.** That keeps
"where have I seen this" working without a row per glance.

**Should a catalogued edit be restored when the frame is reopened?** Storing
adjustments and then ignoring them is strange, but frames currently open
neutral and changing that silently would surprise. **Recommendation: restore
it, and say so** — a line in the panel reading "edited 2 September, restored"
with a one-click revert to neutral. Needs deciding before Phase D, because it
changes what `_select` does.

**What happens when the same digest is found at a second path?** Add a
location; do not warn. Duplicates across a card and a NAS are normal. A
*conflict* — same path, different digest — is worth surfacing, because it
means the file was replaced.

**Should the catalogue be exportable?** A sidecar JSON per image, or a single
dump, would make the data portable and survive a corrupted database. Not
required, cheap to add later, out of scope now.

---

## 12. Risks

**The install script deletes its own prefix.** §3. This is the one that
destroys user data rather than merely annoying, and it is easy to get wrong,
because putting the database next to the binary looks tidy.

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

| | | effort |
|---|---|---|
| **A** | `CatalogStore`, `CatalogEntry`, `KeywordSet`, `MemoryCatalog`, and the tests they share | 1 |
| **B** | `SqliteCatalogStore`, migrations, `CatalogService` isolate. Phase A's tests run against both | 1.5 |
| **C** | `Edit.toJson`/`fromJson` with versioning; `timestamp` through to `RawMetadata`; streaming digest on an isolate | 1 |
| **D** | The keyword panel, the wider column, autocomplete, and the write policy in §8 | 1.5 |
| **E** | *Unscheduled.* A native SHA-256 in `raw_images_api`, only if measurement asks for it | 0.5 |

*(Sittings, not days.)*

A before B is not negotiable: writing the in-memory implementation first is
what stops the interface being shaped by SQLite. If `MemoryCatalog` is awkward
to write, the interface is wrong, and that is much cheaper to learn before
there is a schema.

C is independent of A and B and can be done in any order. D needs all of them.

**Ships as one feature.** A catalogue that stores adjustments but has no
keyword control, or one that has the control but forgets on restart, is not
worth putting in front of anyone.
