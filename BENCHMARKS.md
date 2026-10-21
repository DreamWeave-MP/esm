# TES3 benchmarks

`bench/bench.jsl` times the spine through `@esm`, the way a tool reaches it: framing a content
file with and without a filter, saving, record identity, subrecords and string fields, profile
checks, the typed codec over a record of every type, CELL references, LAND terrain, write-back,
and OpenMW's Lua payloads. The inputs are the suite's `all_types.esp` and content built from it:
a 3.7 MB file of 16,161 records, CELLs of 500 and 2,000 references written out of order, and 64
LANDs. Each workload is warmed up, sized to a batch of about a tenth of a second, and reported
as the median of seven batches with a full collection between them. Every workload answers with
a number that says what it did (a count, a byte total, a round trip), and the bench stops if one
is wrong.

```sh
jess run --package jpk/tes3 --package-path jpk --capability filesystem.read \
  jpk/tes3/bench/bench.jsl [filter]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.1 (Luau 0.742), the same one for
  both sides.
- Base: `7518b55`, the package before the move, with this bench. Head: `78aa9f1`.
- Protocol: the whole bench run against base, then head, five times over, back to back under one
  lock; each cell is the median of its five runs. A difference under 5 percent is called no
  change.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| open | 932.6 | 869.5 | 1.07x |
| open, keeping CELL headers and LAND | 1190.7 | 830.8 | 1.43x |
| open, keeping every record | 2620.3 | 2238.7 | 1.17x |
| save, untouched | 984.9 | 915.3 | 1.08x |
| save, one record in sixteen edited | 1383.7 | 1317.0 | 1.05x |
| check a round trip | 3726.9 | 3674.6 | no change |
| tag and id of every record | 6508.3 | 5906.3 | 1.10x |
| id span of every record | 3329.6 | 3192.5 | no change |
| subrecords of every record | 16418.2 | 11793.9 | 1.39x |
| string fields of every record | 35712.3 | 19696.6 | 1.81x |
| object keys | 25016.3 | 12357.7 | 2.02x |
| validate as tes3 | 46570.2 | 9599.5 | 4.85x |
| retain every other record and save | 1934.0 | 1915.3 | no change |
| replace a subrecord of 1,000 records | 2521.0 | 2566.5 | no change |
| delete no subrecord of 1,000 records by tag | 1713.9 | 279.3 | 6.14x |
| decode a record of every type | 336.7 | 311.8 | 1.08x |
| encode a record of every type | 1217.7 | 648.3 | 1.88x |
| display a record of every type | 579.7 | 558.7 | no change |
| set an edited NPC_, there and back | 527.3 | 281.3 | 1.87x |
| decode a CELL of 2,000 references | 4811.3 | 2320.5 | 2.07x |
| encode a CELL of 2,000 references | 8281.0 | 2727.0 | 3.04x |
| group a CELL of 2,000 references | 241.7 | 245.4 | no change |
| set a moved reference in a CELL of 500, there and back | 20182.2 | 10903.3 | 1.85x |
| delete 200 references of a CELL of 2,000 | 1554.2 | 1598.3 | no change |
| read 64 LANDs as buffers | 1767.3 | 1799.5 | no change |
| read the heights of 64 LANDs | 1435.4 | 1434.8 | no change |
| decode 64 LANDs | 1838.0 | 1857.6 | no change |
| write the heights of a LAND, there and back | 1551.0 | 1482.2 | no change |
| encode a Lua payload of 2,000 entries | 963.5 | 781.3 | 1.23x |
| decode a Lua payload of 2,000 entries | 691.6 | 723.2 | no change |
| collect the references of a Lua payload of 2,000 entries | 454.9 | 184.5 | 2.47x |
| display a Lua payload of 2,000 entries | 1266.0 | 1284.9 | no change |

What moved, and why:

- **CELL references** (decode 2.1x, encode 3.0x, a typed edit of a cell 1.9x). A CELL's
  references were sorted by a comparator that read each side's persistence, master, and index
  through a function call per comparison. They're now one `f64` key each in a buffer and one
  stable `data.argsort`; a master or index no FRMR holds still goes the long way. Encoding a
  reference also built the names of its fields (`references[7].translation`) and a table of its
  optional string fields for every reference, to use them only in an error; it now builds the
  name when it refuses one.
- **Encoding** (1.9x over a record of every type). Per record it decoded an empty record to get
  the type's defaults and merged the value into a new table field by field; it parsed every
  flags text (`PERSISTENT | BLOCKED`) with patterns; it tested every string for non-ASCII with a
  character class; and every write called out to learn it had room. The defaults are now made
  once and frozen, a flags text is parsed once, ASCII is told by `utf8.len`, and a write checks
  its own room.
- **Profile checks** (4.9x) and **string fields** (1.8x) listed a record's subrecords as tables,
  twice for a check, to look at their tags. Both now read the tags where they are.
- **Subrecords** (1.4x): the list is made at its size, and a tag's string is kept instead of
  made from its bytes each time. That second change is also the 1.4x and 1.2x on the filtered
  opens, which hand the filter each record's tag, and the 1.1x on tags and ids.
- **Object keys** (2.0x) sort as strings of type, NUL, and id, which orders them as the
  comparator did with nothing to call.
- **A typed edit** of an NPC_ (1.9x) encodes twice, so it has the faster encode twice over; the
  rest is a write-back alignment that scores pairs inline and pairs the leading subrecords an
  edit left alone before scoring what follows.
- **Deleting by tag** from a record without it (6.1x) no longer lists the record's subrecords
  first. **Collecting a Lua payload's references** (2.5x) and the integer check before encoding
  one (1.2x) no longer make an empty list to walk for every value that has none.

What did not move: the comprehensions, reducers, slices, and record patterns the loops became
lower to the loops they replaced, and the rows that only they touch read no change. `open` and
`save` are a native frame and a copy, and LAND is base64 and a prefix sum of `i8` deltas into
`i32` heights, which the data plane has no operation for (`data.add` takes one kind for all three
of its spans, and there is no scan), so `land.read` stays a native Luau loop. The 1.05x to 1.08x
on `open`, the two `save` rows, and the decode of every type have at most a presized table
behind them, and are the size of this machine's noise.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-14 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.15 and 0.78 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@esm`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@esm` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.155 s | 0.078 s |
| Final | 0.156 s | 0.095 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| open | 0.8587 | **1.396×** | 0.8806 | 1.025× |
| open, keeping CELL headers and LAND | 0.8720 | **2.637×** | 0.8870 | 1.017× |
| open, keeping every record | 2.308 | **3.179×** | 2.299 | 0.996× |
| save, untouched | 0.8370 | **1.866×** | 0.8737 | 1.044× |
| save, one record in sixteen edited | 1.354 | **1.452×** | 1.326 | 0.980× |
| check a round trip | 3.811 | **1.250×** | 3.638 | 0.954× |
| tag and id of every record | 6.250 | **2.758×** | 6.178 | 0.989× |
| id span of every record | 3.271 | **3.492×** | 3.397 | 1.038× |
| subrecords of every record | 12.21 | **1.844×** | 12.45 | 1.019× |
| string fields of every record | 20.55 | **2.313×** | 20.68 | 1.006× |
| object keys | 12.48 | **2.088×** | 12.75 | 1.022× |
| validate as tes3 | 9.562 | **3.206×** | 9.714 | 1.016× |
| retain every other record and save | 1.921 | **1.760×** | 1.942 | 1.011× |
| replace a subrecord of 1,000 records | 2.739 | **1.817×** | 2.677 | 0.978× |
| delete no subrecord of 1,000 records by tag | 0.2828 | **2.698×** | 0.2859 | 1.011× |
| decode a record of every type | 0.3169 | **1.949×** | 0.3857 | **1.217×** |
| encode a record of every type | 0.6675 | **1.572×** | 0.7562 | **1.133×** |
| display a record of every type | 0.5762 | **2.082×** | 0.6549 | **1.136×** |
| set an edited NPC_, there and back | 0.2863 | **2.060×** | 0.3826 | **1.336×** |
| decode a CELL of 2,000 references | 2.386 | **2.190×** | 2.362 | 0.990× |
| encode a CELL of 2,000 references | 2.754 | **1.985×** | 3.544 | **1.287×** |
| group a CELL of 2,000 references | 0.2512 | **2.775×** | 0.2487 | 0.990× |
| set a moved reference in a CELL of 500, there and back | 11.28 | **1.955×** | 12.09 | **1.072×** |
| delete 200 references of a CELL of 2,000 | 1.694 | **1.841×** | 1.661 | 0.980× |
| read 64 LANDs as buffers | 1.806 | **5.312×** | 1.803 | 0.998× |
| read the heights of 64 LANDs | 1.455 | **6.381×** | 1.444 | 0.992× |
| decode 64 LANDs | 1.894 | **1.057×** | 1.879 | 0.992× |
| write the heights of a LAND, there and back | 1.530 | **1.231×** | 1.520 | 0.993× |
| encode a Lua payload of 2,000 entries | 0.7818 | **1.689×** | 0.7893 | 1.010× |
| decode a Lua payload of 2,000 entries | 0.7430 | **1.864×** | 0.7311 | 0.984× |
| collect the references of a Lua payload of 2,000 entries | 0.1805 | **1.330×** | 0.1840 | 1.019× |
| display a Lua payload of 2,000 entries | 1.268 | **1.735×** | 1.254 | 0.989× |

What carries the directive, and the rows that earned it:

- `tags`, `text`, `writer`, whole: tag names, the string decode (`plainUntil`), and the byte
  writer, under every open, id, string-field, decode, and encode row.
- `records`, whole: tag and id, id span, object keys, string fields.
- `land`, whole: reading 64 LANDs as buffers and their heights (5.5x and 6.6x unmarked), and the
  height write.
- `references`, whole: decoding a CELL of 2,000 references.
- `writeback`, whole: the NPC_ edit and the moved reference, there and back.
- `plugin`, by function: `walk` and `parse` (the opens), `Plugin.save` (the saves, the round
  trip), `Plugin.subrecords`, `Plugin.findSubrecord`, `Plugin.span`, `Plugin.code`, `Plugin.tag`,
  `Plugin.range`, `Plugin.retain`, `pieces`, `rebuild`, `newPiece`, `asBuffer`,
  `Plugin.replaceSubrecord`, `codesOf`, `Plugin.cellGroups`, `Plugin.deleteCellReferences`,
  `Plugin.deleteSubrecordsByTag`, `lossyUtf8`, `vanillaDiagnostics`, `Plugin.validateProfile`.
- `decode`, by function: `text`, `stringField`'s handler, `reference`, `cell`, `landscape`,
  `decode`.
- `encode`, by function: `isList`, `merge`, `tag`, `writeString`, `header`, `vector`.
- `display`, by function: `emptyOrUnset`, `tidyField`, `tidy`, `lossy`, `luaValue`.
- `save`, by function: `f64s`, `decodeUserdata`, `decodeValue`, `encodeValue`, `hasInteger`,
  `luaRefs` (the four Lua payload rows).
- `schema`, by function: `flagText`, `base64` (decoding 64 LANDs).
- `init` is unmarked.

The rows still more than 5% slower than all marked decode, encode, or display one record of each
type, or edit one there and back, and their time is a long tail of per-type code no profile line
dominates: marking more of `decode` and `encode` by function (`sub`, `numberAt`, `u8List`,
`nameOf`, the next handler) moved none of them. Marking `decode`, `encode`, and `display` whole
brought every row within 5% of all marked in a session of its own, and made requiring `@esm`
0.151 s against 0.164 s all marked and 0.097 s for this state in that session: those three are
most of what marking costs. The three load-order tools that load `@esm` ran within this
machine's drift of each other either way (tes3merge 1.00 s all marked, 1.02 s with the three
whole, 0.95 s like this, in consecutive sessions), so the per-type rows give and the load wins:
a run that decodes every record of a plugin pays up to those rows' ratio on that part of its
work, and every run that requires `@esm` pays about 0.05 s less.
