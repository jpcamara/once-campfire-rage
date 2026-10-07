# Campfire on Rage

[Campfire](https://github.com/basecamp/once-campfire) reimplemented on
[Rage](https://github.com/rage-rb/rage) (with its Iodine server) and Sequel. It runs on the Rails
app's SQLite schema, storage layout and frontend assets unchanged, and keeps its signed and
encrypted cookies compatible, so sessions carry over. From the outside it behaves like the Rails
app. That's checked with the Playwright parity harness from DHH's
[once-campfire-rust](https://github.com/basecamp/once-campfire-rust).

One of three Ruby implementations benchmarked together. The benchmark notes, harness changes,
per-change measurements and raw results are on the
[`benchmarks` branch](https://github.com/jpcamara/once-campfire-sinatra/tree/benchmarks) of the
Sinatra repo.

| Implementation | Code |
|---|---|
| Rails, optimized | [jpcamara/once-campfire, branch `perf`](https://github.com/jpcamara/once-campfire/tree/perf) |
| Sinatra + Falcon | [jpcamara/once-campfire-sinatra](https://github.com/jpcamara/once-campfire-sinatra) |
| Rage + Sequel | this repo |

## Design

- **Web:** Rage controllers on Iodine's C HTTP server, four processes. The process count follows
  the [TechEmpower rage-sequel](https://github.com/TechEmpower/FrameworkBenchmarks/tree/master/frameworks/Ruby/rage-sequel)
  setup.
- **Database:** Sequel over SQLite, with every query a named prepared statement.
- **Views:** shared with the Sinatra app (ERB views ported to Erubi), so the two apps compare as
  frameworks and data layers.
- **Action Cable:** a custom protocol on Rage::Cable, delivered by Iodine's pub/sub in C.

## Performance

Final run, Oct 7 2026: DHH's `bench/run` on a Hetzner Ryzen 7 PRO 8700GE. Each app gets four
hardware threads and the load generator four others. YJIT and jemalloc are on. The numbers are
medians of 3 runs in rotating order, measured alongside the other implementations and stock
Rails, with 0 errors.

| Workload | Rails (stock) | Rage |
|---|---:|---:|
| Room page (req/s, 16 clients) | 225 | 10,127 |
| Messages page | 364 | 24,569 |
| Sidebar | 482 | 34,134 |
| Search | 378 | 16,837 |
| Post a message | 198 | 1,848 |
| Avatar | 62,491 | 165,748 |
| Action Cable, 1,000 clients: p50 delivery | 42.8 ms | 5.0 ms |
| Action Cable, 1,000 clients: saturated | 13 msg/s | 194 msg/s |
| Upload + thumbnail (505 KB) | 67 ms | 134 ms |
| Idle memory (anon) | 284 MB | 170 MB |
| Cold start | 3.6 s | 1.6 s |

Uploads are about 2× slower than in Rails (134 ms vs 67 ms). It's not fixed yet.

**Room-page reads while posts arrive** (reads/sec at 16 clients, the median of 3 reps, each on a
fresh seed). The read routes above never see a write, so this shows what the caches do under real
traffic:

| Posts/sec in the background | 0 | 20 | 100 |
|---|---:|---:|---:|
| Rails (stock) | 228 | 214 | 194 |
| Rage | 10,074 | 9,309 | 6,697 |

The per-change table below comes from the A/B run for each step. Each step was measured against
the commit just before it, so the percentages don't multiply exactly into the totals.

## Caching

The rule here: only cache what the Rust or Elixir ports cache, checked against their source.

**What the Rust port caches** (from its source):

| Cache | What it holds | Rust source |
|---|---|---|
| Message fragments | Rails' own `cache message do` fragments, in memory, bounded by bytes | `views/src/fragment_cache.rs` |
| Compressed pieces | Each fragment's deflate block, the text between fragments, and a whole body's gzip by digest | `kit/src/deflater/splice.rs` |
| Public responses | `Cache-Control: public` responses such as avatars and assets | `kit/src/front/cache.rs` |
| Prepared statements | 256 per connection | `db` crate |

Rust caches no query results and no pages, sidebars or page shells. It renders every page on every
request.

**What this app caches**, with each cache's precedent and its effect in a per-step A/B:

| Cache | Precedent | Measured effect |
|---|---|---|
| Message fragments in memory | Rust | built in |
| Compressed pieces | Rust | room and search +44% |
| Whole-body gzip by digest | Rust, Elixir | sidebar +56% |
| Public responses (avatars, assets) | Rust, Thruster | avatars 8.8× |
| Prepared statements (Sequel, named) | Rust | room +17%, sidebar +23%, post +24% |
| Read cache (`PRAGMA data_version`) | Elixir only | +26–47% on every read route |
| Finished sidebar until its data changes | Elixir only | sidebar 3.4× |
| Messages page per ETag | Elixir only | messages 1.9× |
| Room and search shell, memoized by its inputs | Elixir only | not measured alone |
| Memoized avatar tokens, signed ids, stream names, initials | This app | not measured alone |

**Rust-level caching only.** `CAMPFIRE_CACHING=rust` turns off every cache that only the Elixir port
(or this app) has, and keeps the rest. The run used the same harness, box and CPUs as the full
run, on images built from the commit that adds the switch: 3 reps, 0 errors. Rails (stock) is from the full run; in this run it measured 221 / 365 / 467 /
368 / 196.

| Workload (req/s, 16 clients) | Rails (stock) | Full caching | Rust-level caching only | Full ÷ Rust-level |
|---|---:|---:|---:|---:|
| Room page | 225 | 10,127 | 4,752 | 2.1× |
| Messages page | 364 | 24,569 | 9,402 | 2.6× |
| Sidebar | 482 | 34,134 | 6,618 | 5.2× |
| Search | 378 | 16,837 | 7,536 | 2.2× |
| Post a message | 198 | 1,848 | 1,780 | 1.0× |

The same mixed read/write run (3 reps, fresh seed each):

| Room reads/sec while posts arrive at | 0/s | 20/s | 100/s |
|---|---:|---:|---:|
| Rails (stock) | 228 | 214 | 194 |
| Rage, full caching | 10,074 | 9,309 | 6,697 |
| Rage, Rust-level caching only | 4,763 | 4,401 | 3,164 |

## Where the gains come from

Each change was measured with an A/B against the commit before it.

| Change | Source | Room | Messages | Sidebar | Search | Post |
|---|---|---:|---:|---:|---:|---:|
| Sequel prepared statements run by name | Rust | +17% | — | +23% | — | +24% |
| Split pages by byte offset | Ours (bug in shared code) | +23% | +2% | — | +10% | — |
| Keep each page segment's gzip | Rust | +44% | — | — | +44% | — |
| Keep a body's gzip by its ETag | Rust, Elixir | | | +56% | | |
| Read cache cleared on `PRAGMA data_version` | Elixir | +26% | +34% | +39% | +47% | 0% |
| Keep the finished sidebar until its data changes | Elixir | | | +240% | | |
| Keep finished messages pages by ETag | Elixir | | +90% | | | |
| Room / search shell memoized, messages spliced per request | Elixir | | | | | |
| Audit fixes, mostly random-token page markers (cause not isolated) | — | +26% | — | −8% | +34% | — |
| Build the new message from the request's own data | Ours | | | | | +13% |
| Public-response cache (avatars 8.8×) | Rust, Thruster | | | | | |

An earlier version kept finished room and search pages whole, which was worth about 2.3×. Neither
the Rust nor the Elixir port does that, so it was removed. The table above reflects pages built on
every request. "Ours" changes have no reference precedent; they're internal and invisible from
outside.

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

**Parity:** Playwright passes every cell on every seed.

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
