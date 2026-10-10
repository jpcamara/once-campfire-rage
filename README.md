# Campfire on Rage

[Campfire](https://github.com/basecamp/once-campfire) reimplemented on
[Rage](https://github.com/rage-rb/rage) (with its Iodine server) and Sequel. It runs on the Rails
app's SQLite schema, storage layout and frontend assets unchanged, and keeps its signed and
encrypted cookies compatible, so sessions carry over. From the outside it behaves like the Rails
app. That's checked with the Playwright parity harness from DHH's
[once-campfire-rust](https://github.com/basecamp/once-campfire-rust).

One of four Ruby implementations benchmarked together. The benchmark notes, harness changes,
per-change measurements and raw results are on the
[`benchmarks` branch](https://github.com/jpcamara/once-campfire-sinatra/tree/benchmarks) of the
Sinatra repo.

| Implementation | Code |
|---|---|
| Rails, optimized | [jpcamara/once-campfire, branch `perf`](https://github.com/jpcamara/once-campfire/tree/perf) |
| Sinatra + Falcon | [jpcamara/once-campfire-sinatra](https://github.com/jpcamara/once-campfire-sinatra) |
| Rage + Sequel | this repo |
| Roda + Sequel (Falcon) | [jpcamara/once-campfire-roda](https://github.com/jpcamara/once-campfire-roda) |

## Design

- **Web:** Rage controllers on Iodine's C HTTP server, four processes. The process count follows
  the [TechEmpower rage-sequel](https://github.com/TechEmpower/FrameworkBenchmarks/tree/master/frameworks/Ruby/rage-sequel)
  setup.
- **Database:** Sequel over SQLite, with every query a named prepared statement.
- **Views:** shared with the Sinatra app (ERB views ported to Erubi), so the two apps compare as
  frameworks and data layers.
- **Action Cable:** a custom protocol on Rage::Cable, delivered by Iodine's pub/sub in C.

## Performance

Final run, Oct 8 2026, after the precedent audit: DHH's `bench/run` on a Hetzner Ryzen 7 PRO
8700GE. Each app gets four hardware threads and the load generator four others. YJIT and jemalloc
are on. The numbers are medians of 3 runs in rotating order (HTTP and Action Cable), measured
alongside the other implementations, stock Rails and the Rust port, with 0 errors. Upload and
cold-start times are from the Oct 7 run; the audit's reverts don't touch those paths.

| Workload | Rails (stock) | Rage |
|---|---:|---:|
| Room page (req/s, 16 clients) | 221 | 10,094 |
| Messages page | 370 | 24,763 |
| Sidebar | 482 | 33,951 |
| Search | 381 | 16,900 |
| Post a message | 195 | 1,643 |
| Avatar | 61,938 | 178,292 |
| Action Cable, 1,000 clients: p50 delivery | 44.1 ms | 5.0 ms |
| Action Cable, 1,000 clients: saturated | 12 msg/s | 184 msg/s |
| Idle memory (anon) | 283 MB | 170 MB |
| Upload + thumbnail (505 KB), Oct 7 run | 67 ms | 134 ms |
| Cold start, Oct 7 run | 3.6 s | 1.6 s |

Uploads are about 2× slower than in Rails (134 ms vs 67 ms). It's not fixed yet.

The precedent audit (Oct 8) reverted the optimizations with no Rust or Elixir counterpart. Posting fell
from 1,833 to 1,643 req/s; the read routes didn't move.

**Room-page reads while posts arrive** (reads/sec at 16 clients, the median of 3 reps, each on a
fresh seed). The read routes above never see a write, so this shows what the caches do under real
traffic:

| Posts/sec in the background | 0 | 20 | 100 |
|---|---:|---:|---:|
| Rails (stock), Oct 7 run | 228 | 214 | 194 |
| Rage | 10,100 | 9,361 | 6,558 |

The per-change table below comes from the A/B run for each step. Each step was measured against
the commit just before it, so the percentages don't multiply exactly into the totals.

## Finished-page cache (Oct 10)

Upstream Rails now keeps finished private pages until the database changes
([ac73267](https://github.com/basecamp/once-campfire/commit/ac73267),
[0f5d0b2](https://github.com/basecamp/once-campfire/commit/0f5d0b2),
[8d02540](https://github.com/basecamp/once-campfire/commit/8d02540)), following the C port. The Rust
port added the same thing
([d09811c](https://github.com/basecamp/once-campfire-rust/commit/d09811c),
`crates/campfire/src/response_cache.rs`). So this app does it too (`lib/campfire/page_cache.rb`):

- **What's kept:** the room, messages, sidebar and search pages of a signed-in user, body and gzip.
- **When it's dropped:** any SQLite commit from any process clears it (`PRAGMA data_version`). The
  version is captured before authentication and checked again at lookup and admission, so a commit
  during a render can't leave a stale page under the new version. Entries also expire after 15
  seconds, as Rust's do.
- **What still runs on every request:** authentication, the room access check and cookies.
- **Not kept:** pages with a flash, conditional requests, and responses that set a cookie.
- **Bounds:** `CAMPFIRE_RESPONSE_CACHE_MB` per process (default 64, 0 turns it off), 1 MB per page.
  Concurrent renders of one page collapse into one.
- **`CAMPFIRE_CACHING=rust`** keeps this cache on, since the Rust port has it.

**Checks:** every Playwright cell on every seed passes (default 874, crowd 25, custom_styles 33,
first_run 16, restricted 8). Server HTML matches the reference on 128 of 128 pages, fresh and
cached. All 24 write flows match. With the cache on and off, 60 requests across these scenarios
give identical statuses: foreign writes to a message body and to a user's name, a revoked
membership, a banned user, a deleted session. Every read after a foreign write shows it. Check mode
(`CAMPFIRE_CHECK_CACHES=1`) found 0 mismatches across reads, posts and foreign writes from all 4
processes.

Measured with DHH's verification harness
([basecamp/once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
`ec02deb`) on the Hetzner box: app on CPUs 4-7, load generator on 0-3, 3 rounds, 8-second samples.
Upstream Rails `0aa339d` and Rust `6dae2fd` ran in the same session. Every response passed the
harness's route checks, and every write passed its audit, with 0 errors or invalid responses.

| Requests/sec, 16 clients | Rage before | **Rage with page cache** | Rails (upstream) | Rust |
|---|---:|---:|---:|---:|
| Room page | 7,870 | **21,106** | 3,189 | 42,282 |
| Messages page | 23,400 | **28,381** | 3,206 | 40,615 |
| Sidebar | 32,880 | **31,245** | 3,568 | 48,314 |
| Search | 16,311 | **29,798** | 3,450 | 47,564 |
| Post a message | 2,013 | **1,985** | 282 | 4,792 |

Mixed profile (16 readers plus one writer at 10 posts/sec, read requests/sec):

| Read requests/sec | Rage before | **Rage with page cache** | Rails (upstream) | Rust |
|---|---:|---:|---:|---:|
| Room page | 9,810 | **20,501** | 1,545 | 39,564 |
| Messages page | 23,237 | **28,234** | 1,875 | 37,997 |
| Sidebar | 31,796 | **29,963** | 2,838 | 46,939 |
| Search | 16,017 | **29,955** | 2,580 | 46,151 |

"Before" is the same harness earlier on Oct 10, without this cache.

## Compared with Rust on the same box

DHH's [Rust port](https://github.com/basecamp/once-campfire-rust) (`ccece30`) was built and run on the
same Hetzner box, in the same Oct 8 session as stock Rails and the three Ruby apps. Settings: 16 clients,
four hardware threads per app, median of 3 runs in rotating order. Each app ran with its default caching.

| HTTP workload (requests/sec) | Rails | Rails (optimized) | Sinatra | Rage | Rust |
|---|---:|---:|---:|---:|---:|
| Room page | 221 | 529 | 11,349 | 10,094 | 21,155 |
| Messages page | 370 | 1,985 | 16,256 | 24,763 | 23,515 |
| Sidebar | 482 | 3,557 | 22,613 | 33,951 | 20,769 |
| Search | 381 | 862 | 14,523 | 16,900 | 21,361 |
| Post a message | 195 | 259 | 1,799 | 1,643 | 4,109 |
| Avatar | 61,938 | 62,671 | 72,664 | 178,292 | 196,428 |
| Cable p50, 1,000 clients | 44.1 ms | 41.1 ms | 8.2 ms | 5.0 ms | 4.4 ms |
| Idle memory | 283 MB | 613 MB | 200 MB | 170 MB | 13 MB |

With only the caching Rust does (`CAMPFIRE_CACHING=rust`), the Ruby apps read at roughly a quarter to
two-fifths of Rust's rate, and post at about 40–45% of it. The extra caches all come from Elixir's port,
and they're what let Ruby match Rust on the messages page and sidebar.

**Hardware.** This box is slower than DHH's. On it, Rust runs at about 60% of his published numbers
(room 21,155 vs 36,260). Stock Rails runs at 73–93% of his. So comparing these numbers with his table
overstates the gap between Ruby and Rust by about 1.7×.

## Caching

The rule here: only cache what the Rust or Elixir ports cache, checked against their source.

**What the Rust port caches** (from its source):

| Cache | What it holds | Rust source |
|---|---|---|
| Message fragments | Rails' own `cache message do` fragments, in memory, bounded by bytes | `views/src/fragment_cache.rs` |
| Compressed pieces | Each fragment's deflate block, the text between fragments, and a whole body's gzip by digest | `kit/src/deflater/splice.rs` |
| Public responses | `Cache-Control: public` responses such as avatars and assets | `kit/src/front/cache.rs` |
| Prepared statements | 256 per connection | `db` crate |
| Finished private pages (added Oct 7) | Room, messages, sidebar and search pages, until a commit or 15 s | `campfire/src/response_cache.rs` (d09811c) |

Rust caches no query results, sidebars or page shells. Since Oct 7 it keeps finished private pages
until the next commit, as upstream Rails and the C port do; on a miss it renders the whole page.

**What this app caches**, with each cache's precedent and its effect in a per-step A/B:

| Cache | Precedent | Measured effect |
|---|---|---|
| Message fragments in memory | Rust | built in |
| Compressed pieces | Rust | room and search +44% |
| Whole-body gzip by digest | Rust, Elixir | sidebar +56% |
| Public responses (avatars, assets) | Rust, Thruster | avatars 8.8× |
| Prepared statements (Sequel, named) | Rust | room +17%, sidebar +23%, post +24% |
| Finished private pages until the database changes | Rust (d09811c), upstream Rails (ac73267), C | room 2.7×, search 1.8×, messages 1.2× |
| Read cache (`PRAGMA data_version`) | Elixir only | +26–47% on every read route |
| Finished sidebar until its data changes | Elixir only | sidebar 3.4× |
| Messages page per ETag | Elixir only | messages 1.9× |
| Room and search shell, memoized by its inputs | Elixir only | not measured alone |
| Memoized avatar tokens | Elixir only (`mentions.ex`) | not measured alone |

**Rust-level caching only.** `CAMPFIRE_CACHING=rust` turns off every cache that only the Elixir port
has, and keeps the rest. It ran on Oct 8 with the same harness, box, CPUs and images as the full
run: 3 runs in rotating order, HTTP suite, 0 errors. Rails (stock) is from the full run.

| Workload (req/s, 16 clients) | Rails (stock) | Full caching | Rust-level caching only | Full ÷ Rust-level |
|---|---:|---:|---:|---:|
| Room page | 221 | 10,094 | 4,743 | 2.1× |
| Messages page | 370 | 24,763 | 9,486 | 2.6× |
| Sidebar | 482 | 33,951 | 6,475 | 5.2× |
| Search | 381 | 16,900 | 7,558 | 2.2× |
| Post a message | 195 | 1,643 | 1,608 | 1.0× |

The same mixed read/write run (3 reps, fresh seed each):

| Room reads/sec while posts arrive at | 0/s | 20/s | 100/s |
|---|---:|---:|---:|
| Rails (stock), Oct 7 run | 228 | 214 | 194 |
| Rage, full caching | 10,100 | 9,361 | 6,558 |
| Rage, Rust-level caching only | 4,720 | 4,339 | 3,192 |

## Where the gains come from

Each change was measured with an A/B against the commit before it. Every change is a fix of our own
bug, something the Rust port does, or a cache the Elixir port has. Changes with neither precedent
were reverted, as listed in
[the precedent audit](https://github.com/jpcamara/once-campfire-sinatra/blob/benchmarks/notes/precedent-audit.md).

| Change | Source | Room | Messages | Sidebar | Search | Post |
|---|---|---:|---:|---:|---:|---:|
| Sequel prepared statements run by name | Rust (prepared statements everywhere) | +17% | — | +23% | — | +24% |
| Split pages by byte offset | Bug fix | +23% | +2% | — | +10% | — |
| Keep each page segment's gzip | Rust (2947c64) | +44% | — | — | +44% | — |
| Keep a body's gzip by its ETag | Rust (2f755bf), Elixir | | | +56% | | |
| Read cache cleared on `PRAGMA data_version` | Elixir (`db.ex`) | +26% | +34% | +39% | +47% | 0% |
| Keep the finished sidebar until its data changes | Elixir (`sidebar.ex`) | | | +240% | | |
| Keep finished messages pages by ETag | Elixir (`messages.ex`) | | +90% | | | |
| Room / search shell memoized, messages spliced per request | Elixir (`room_page.ex`, `searches.ex`) | | | | | |
| Audit fixes, mostly random-token page markers (cause not isolated) | — | +26% | — | −8% | +34% | — |
| Public-response cache (avatars 8.8×) | Rust (`front/cache.rs`), Thruster | | | | | |

**Reverted for lack of precedent.** Each was measured as a gain when it was added:

| Reverted change | Gain it had | Why |
|---|---|---|
| Keep finished room / search pages whole | about 2.3× on both | neither port keeps whole pages |
| Build a new message's view and push payload from the request | post +13% | Rust reads them back through its presenter |
| Memoized signed stream names and blob ids, initials SVGs | not measured alone | Rust generates each per use |

## Differences from Rails

Only the ones the Rust port documents in its README under "Known differences":

- `Sec-Fetch-Site` replaces CSRF tokens, and `file_uploader.js` is overridden to match.
- Jobs run in-process.
- Cookies are written only when they change.
- ETags are built from cached page parts.

A few known gaps are disclosed in the
[notes](https://github.com/jpcamara/once-campfire-sinatra/blob/benchmarks/notes/rage.md):

- Downloads are read into memory instead of streamed.
- The unsupported-browser check runs before sign-in.
- Range requests report `X-Cache: miss`.

## Status

**Parity:** Playwright passed every cell on every seed before the precedent audit. After the audit's
reverts, the groups they touch passed again, 408 of 408 (auth, realtime, composer, users, messages).
Server HTML matches the reference on 128 of 128 pages (fresh and cached), and all 24 write flows match.

| Seed | Cells passing |
|---|---:|
| default | 874 / 874 |
| crowd | 25 / 25 |
| custom_styles | 33 / 33 |
| first_run | 16 / 16 |
| restricted | 8 / 8 |

**Security:** every finding from the independent audit is fixed, and 30 of 30 checks pass from
outside the app. The audit covered stored XSS through uploads, the `/cable` Origin check, the bot
API forgery check, fragment-marker injection, HTTPS mode, and others.

**Iodine:** two Iodine/Rage behaviors needed workarounds, described in the notes:

- `rack.input` strings arrive with a stale encoding flag.
- File reads stall on an idle server.

An upstream issue draft is in `notes/iodine-rack-input-coderange-issue.md` on the benchmarks branch.

## Running it

It needs the reference image `campfire-reference:app`, built with `parity/bin/reference build` in
once-campfire-rust, for the digested assets.

```sh
docker build -t campfire-rage:app .
docker run -p 3000:80 --env-file path/to/once-campfire-rust/parity/.env.reference \
  -v $PWD/storage/db:/rails/storage/db -v $PWD/storage/files:/rails/storage/files campfire-rage:app
```

For local development, `bin/dev [PORT]` runs it against a fresh copy of the parity seed, with
once-campfire-rust checked out next to this repo.
