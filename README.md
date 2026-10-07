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

Requests/sec with 16 clients, four hardware threads per app, on a Hetzner Ryzen 7 PRO 8700GE.
The harness is DHH's `bench/run`. YJIT and jemalloc are on. These are the latest A/B numbers; a
final run of all three apps together will replace them.

| HTTP workload (requests/sec) | Rails (stock) | Rage |
|---|---:|---:|
| Room page | 223 | 10,086 |
| Messages page | 371 | 24,347 |
| Sidebar | 475 | 33,190 |
| Search | 377 | 16,966 |
| Post a message | 199 | 1,836 |

Action Cable fan-out at 1,000 clients had a p50 delivery of 4.9 ms at 192 messages/sec, with every
message delivered.

**Where the gains come from.** Each change was measured with an A/B against the commit before it.

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
