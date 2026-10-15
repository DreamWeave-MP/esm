# TES3 benchmarks

`bench/bench.jsl` times the spine through `@tes3`, the way a tool reaches it: framing a content
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
function), and marking costs at every load: with every module marked, compiling them was 73% of
what requiring `@tes3` cost past starting the process (0.084 s of 0.115 s). So a module is marked
only where a row below needs it, and a large module only on the functions the row spends its
time in.

Measured 2026-10-14 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load between 1.08 and 1.31 at the start of each round.
Each column is the median of three fresh runs of `bench/bench.jsl`, each run's row the median of
its seven batches. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package jpk/tes3 --package-path
jpk` of a script that only requires `@tes3`, median of five after one warm-up; the same command
requiring nothing takes 0.049 s.

| | All marked | Unmarked | Final |
| --- | ---: | ---: | ---: |
| Requiring `@tes3` | 0.164 s | 0.080 s | 0.097 s |

| Row | All marked (ms) | Unmarked (ms) | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| open | 0.9700 | 1.355 | 0.9481 | 0.977× |
| open, keeping CELL headers and LAND | 0.9001 | 2.323 | 0.9014 | 1.001× |
| open, keeping every record | 2.444 | 7.743 | 2.395 | 0.980× |
| save, untouched | 1.113 | 1.837 | 1.063 | 0.955× |
| save, one record in sixteen edited | 1.582 | 2.252 | 1.599 | 1.011× |
| check a round trip | 4.288 | 5.517 | 4.401 | 1.026× |
| tag and id of every record | 6.651 | 18.50 | 6.361 | 0.956× |
| id span of every record | 3.562 | 12.25 | 3.350 | 0.941× |
| subrecords of every record | 14.89 | 26.70 | 14.38 | 0.966× |
| string fields of every record | 23.84 | 51.34 | 23.27 | 0.976× |
| object keys | 14.10 | 28.88 | 13.65 | 0.968× |
| validate as tes3 | 10.60 | 33.69 | 9.938 | 0.938× |
| retain every other record and save | 2.139 | 3.733 | 2.079 | 0.972× |
| replace a subrecord of 1,000 records | 3.142 | 5.387 | 3.030 | 0.964× |
| delete no subrecord of 1,000 records by tag | 0.2982 | 0.8081 | 0.2862 | 0.960× |
| decode a record of every type | 0.3456 | 0.6709 | 0.4013 | **1.161×** |
| encode a record of every type | 0.7125 | 1.128 | 0.8092 | **1.136×** |
| display a record of every type | 0.6227 | 1.339 | 0.6857 | **1.101×** |
| set an edited NPC_, there and back | 0.3175 | 0.6672 | 0.3942 | **1.241×** |
| decode a CELL of 2,000 references | 2.694 | 5.597 | 2.595 | 0.963× |
| encode a CELL of 2,000 references | 3.126 | 6.259 | 3.721 | **1.190×** |
| group a CELL of 2,000 references | 0.2866 | 0.7469 | 0.2792 | 0.974× |
| set a moved reference in a CELL of 500, there and back | 12.50 | 24.47 | 12.99 | 1.039× |
| delete 200 references of a CELL of 2,000 | 1.895 | 3.404 | 1.837 | 0.969× |
| read 64 LANDs as buffers | 1.982 | 10.84 | 1.924 | 0.971× |
| read the heights of 64 LANDs | 1.546 | 10.26 | 1.547 | 1.001× |
| decode 64 LANDs | 2.041 | 2.173 | 1.966 | 0.963× |
| write the heights of a LAND, there and back | 1.599 | 1.969 | 1.576 | 0.986× |
| encode a Lua payload of 2,000 entries | 0.8589 | 1.484 | 0.8254 | 0.961× |
| decode a Lua payload of 2,000 entries | 0.8037 | 1.540 | 0.7699 | 0.958× |
| collect the references of a Lua payload of 2,000 entries | 0.1960 | 0.2710 | 0.1894 | 0.966× |
| display a Lua payload of 2,000 entries | 1.386 | 2.413 | 1.358 | 0.979× |

What carries the directive, and the rows that earned it:

- `tags`, `text`, `writer`, whole: tag names, the string decode (`plainUntil`), and the byte
  writer, under every open, id, string-field, decode, and encode row.
- `records`, whole: tag and id, id span, object keys, string fields.
- `land`, whole: reading 64 LANDs as buffers (5.5x unmarked) and their heights (6.6x), and the
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

The five rows still more than 5% slower than all marked decode, encode, or display one record of
each type, and their time is a long tail of per-type code no profile line dominates. Marking
`decode`, `encode`, and `display` whole brings every row within 5% of all marked, and costs
0.151 s to require `@tes3` against 0.097 s. On the three load-order tools that load `@tes3`
(the jess side of `tools/bench/showcase.jsl`, `--no-native`, median of five), all marked ran
tes3merge in 1.00 s, S3LightFixes in 0.86 s, and Merged Lands in 3.44 s; the three modules whole
1.02 s, 0.83 s, and 3.45 s; and this 0.95 s, 0.81 s, and 3.42 s. So they stay marked by
function: a run that decodes every record of a plugin pays up to those rows' ratio on that part
of its work, and every run that requires `@tes3` pays 0.05 s less.
