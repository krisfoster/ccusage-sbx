# Plan: ccusage for Docker Sandboxes (sbx)

Goal: run ccusage inside every sbx sandbox on a schedule, sync the usage back to the user's computer, and give an aggregate view (all sandboxes, all time) plus a per-sandbox view, with a local dashboard to explore it.

Status: all five phases complete (results in sections 3a, 3c, 3d, 3e, 3g and 3h). This repository is committed; nothing is pushed. Phase 1 is committed (4 signed commits) on branch `feat/local-sync-provider` in `../ccusage`, not pushed. Phase 2 (the kit) is built and passes its end-to-end test; its files here are not yet committed. Phase 3 is built, verified and committed in the fork (7 signed commits on the branch, not pushed). Facts marked (verified) were checked on this machine on 2026-10-10. Facts marked (to verify) are assumptions the phase 0 spike must confirm.

## 1. Facts that shape the design

| # | Fact | Consequence |
|---|---|---|
| 1 | The fork at `../ccusage` (krisfoster/ccusage) already has `ccusage sync`: one machine identity per writer, 15-minute UTC shards per agent per day, cross-machine dedup (`rust/crates/ccusage-sync/src/duplicates.rs`), rollups, `sync status/doctor/repair/forget`, and `ccusage sync dashboard` served on 127.0.0.1 (verified, docs/guide/cloud-sync.md and dashboard.md). | Reuse it. Do not write a second stats pipeline. |
| 2 | GCS is the only provider. `config.rs:255` validates `sync.provider` against `["gcs"]`; `GcsStore` in `rust/crates/ccusage/src/gcs.rs:426` is the only real `ObjectStore` impl (verified). | Cloud is not wanted here. A local provider is the main code change. |
| 3 | `ObjectStore` (`ccusage-objectstore/src/store.rs`) is four methods: `get`, `put`, `list`, `delete`, with `Precondition::{None, IfAbsent, IfGenerationMatch}` (verified). A `MemoryStore` test double exists in `ccusage-test-support`. | A filesystem-backed store is small. CAS semantics are the only subtle part. |
| 4 | `ccusage sync doctor` requires that the store honours CAS, because two writers syncing at once would otherwise overwrite each other (verified, docs). | The host store must serialise writers. This favours a single host hub process over many VMs writing a shared mount. |
| 5 | Inside a sandbox: `SANDBOX_NAME`, `SANDBOX_ID`, `HTTPS_PROXY=gateway.docker.internal:3128` are set; `host.docker.internal` resolves; node/npm exist; no cron; user is `agent` (uid 1000) (verified on `se-skills-claude`). | Machine id from `SANDBOX_ID`, label from `SANDBOX_NAME`. Scheduling is a background loop. |
| 6 | Claude logs live in `~/.claude/projects` on an ext4 block volume inside the VM, not on the host (verified via `mount`). Codex uses `~/.codex` (absent until used). | The host cannot read them without going through the sandbox. |
| 7 | Kit `setup.startup` runs on every container start and must be idempotent; kit `volumes` are creation-time only; kits cannot mount host directories (SPEC-v2 5.6, 5.7). The `code-server` kit shows the `nohup ... &` pattern. | A start-up loop works. A shared host dir needs user action at `sbx create`, so use the network instead. Spike result: `sbx kit add` rejects kits with `setup.startup`, so the kit is create-time only. |
| 8 | `sbx exec` starts a stopped sandbox (verified, help text). | A host-side poller would wake every sandbox. Push from inside, do not pull from the host. |
| 9 | Some sandboxes mount the host's `~/.claude/projects` as a workspace (e.g. `ccui-claudecodeui-*`, verified in `sbx ls`). | Those sandboxes would double-count host usage. Needs dedup handling and a note in the docs. |
| 10 | `sbx rm` destroys the VM and its logs; Claude Code also prunes old transcripts. | The host store must be append-only and keep retired sandboxes, or history is lost. |

## 2. Architecture

```
  Host (macOS/Linux)                                   Sandbox VM (one per sbx)
  ------------------                                   ------------------------
  ccusage sync serve  (hub, 127.0.0.1:PORT)  <------   kit: ccusage + sync loop
    |  ObjectStore over HTTP, token auth        HTTP    machineId = SANDBOX_ID
    v                                                   machineLabel = SANDBOX_NAME
  ~/.ccusage-sbx/  (FsStore, CAS via lock+rename)       reads ~/.claude, ~/.codex
    |
    v
  ccusage sync dashboard  (127.0.0.1, local)
    aggregate | per sandbox | per agent | per model
```

Three deliverables:

1. **Fork changes** (in `../ccusage`): `fs` provider, `http` provider, `sync serve` hub, config and dashboard support for them.
2. **The kit** (this repo): a v2 mixin that installs ccusage, opens egress to the hub, writes config, starts the loop.
3. **Host tooling** (this repo): install/run script for the hub (launchd on macOS, systemd user unit on Linux, or a container), token issuance, a thin wrapper for `status`.

## 3. Key design decisions

1. **Push from the sandbox, not pull from the host.** Fact 8.
2. **Sandbox = machine.** `machineId` derives from `SANDBOX_ID` (names get reused after `rm`), `machineLabel` is `SANDBOX_NAME`. Per-sandbox view falls out of the existing per-machine view. Aggregate is the existing all-machines rollup. Recreating a sandbox with the same name creates a new machine, so history stays separate and the aggregate stays correct.
3. **Hub over HTTP, backed by an `FsStore`.** The hub is the only process that touches the directory, so CAS can be implemented in one place (per-key mutex plus write-temp-then-rename, generation = a monotonic counter or content hash stored in a sidecar). The sandbox side uses an `HttpStore` client. The same `FsStore` is what the local dashboard reads.
4. **Never delete on the host.** `sync forget` and `--prune` stay available but are never invoked by the kit. A removed sandbox shows as retired (last sync older than N days and no heartbeat), not removed.
5. **Auth.** The hub requires a bearer token. The token is stored as an sbx custom secret (`sbx secret set-custom`, same placeholder-swap trick as `../codex_bedrock_kit_demo`) so the real token never enters the VM. Treat all bodies as untrusted: validate keys with the existing `Key` constructor rules, cap body and per-machine size, reject keys outside the machine's own prefix so one sandbox cannot overwrite another's shards.
6. **Salt.** One salt for the whole store, created by the hub on first start and handed to each sandbox at first sync (the fork already adopts the bucket's salt on a second machine). Different salts would double-count.
7. **Privacy.** Only numbers leave the VM (token counts, costs, hashed project names). Prompts and file contents are never read into the store (fork docs). Keep that property and say so in the README.
8. **Scheduling.** A single shell loop started by `setup.startup`, guarded by a pidfile so restarts are idempotent. Interval default 10 minutes, jittered. Plus a sync on SIGTERM so a stop flushes. The loop retries with backoff when the hub is down (laptop asleep, hub not running) and never blocks the agent.
9. **Scope of agents.** `ccusage sync run` already covers every supported agent, so the kit works as a mixin on claude, codex and others with no per-agent code. `requires: agent:` is left unset if the schema allows, otherwise ship one mixin per base agent.

## 3a. Phase 0 results (2026-10-10)

Spike run on this machine (sbx, Docker Desktop aarch64, Allow_All org policy). Throwaway sandbox and test server removed afterwards.

| Question | Result |
|---|---|
| Can a sandbox reach a service on the host? | Yes. A server bound to `127.0.0.1:8765` on the host was reachable from the VM at `http://host.docker.internal:8765`, both through the sandbox proxy (the default, since `NO_PROXY` does not list it) and direct. `localhost` inside the VM does not reach the host. `host.docker.internal` resolves to `fe80::1`. Caveat: the org policy here is Allow_All, so this does not prove the kit's `permissions.network.allow` entry is sufficient under a restrictive policy. The kit declares `host.docker.internal:<port>` and validates, but enforcement is untested. |
| Does the published ccusage have `sync`? | No. npm `ccusage` (20.0.26 to 20.0.28) has no `sync` command. The fork (20.0.21 in `../ccusage`) does. The kit must ship a binary built from the fork. |
| Can we build that binary here? | Yes. Static linux-arm64 binary, 4.7 MB, built in `rust:1.97-alpine` in about 35 s once the image is pulled. Needs the whole repo mounted (the build script reads the root `package.json`) and `CCUSAGE_PRICING_JSON_PATH` pointing at a LiteLLM `model_prices_and_context_window.json` (pricing is embedded at build time). Recipe in section 3b. linux-x64 has not been built. |
| Do sandbox and host agree? | Token counts are identical across the host (npm 20.0.26), the sandbox (npm 20.0.28) and the fork binary in the sandbox, on 6 real transcripts (205,939 cache-create, 1,966,805 cache-read, 85 input, 23,862 output). Cost differs by version because pricing is embedded: 20.0.26 reported `claude-sonnet-5-5` as unpriced ($1.92) while 20.0.28 and the fork built today priced it ($2.46). |
| Does the kit validate without `requires.agent`? | Yes (`sbx kit validate`: VALID). |
| Env visible to `setup.startup`? | Yes: runs as `agent` (uid 1000), `SANDBOX_ID` and `SANDBOX_NAME` are set, HOME is `/home/agent`. |
| Can the kit be added to an existing sandbox? | No. `sbx kit add` refuses: "declares setup.startup, which the kit-add recreate flow does not yet apply". The kit only works at `sbx create --kit`. |
| Can `sync setup` run non-interactively with our identity? | `--non-interactive` exists but `setup` has no machine-id/label flags and is GCS-only. `machineId` and `machineLabel` are plain config fields and `machineId` can be pinned (`IdentityOrigin::Configured`, max 64 chars, a 36-char `SANDBOX_ID` fits), so the kit writes the config file directly and skips `setup`. |
| Double count when a sandbox mounts host session data | Not tested. It needs a working store; moved to phase 3. |

Consequences for the plan:

1. Ship our own binary, pinned by version and checksum. Build linux-arm64 and linux-x64 (CI or the container recipe) and attach to a release of the fork, or bake into the kit `files/`.
2. Kit install is create-time only. Document `sbx create --kit`, and offer a helper that recreates an existing sandbox. Existing sandboxes need a rebuild, so say so in the README.
3. Do not trust the cost embedded in each sandbox's binary. Sandboxes created at different times will price new models differently (and show zero for unpriced ones). Sync tokens, and compute cost once on the host from one price table, or flag `unpricedModels` in the dashboard. Check how the fork's rollups store cost before deciding (phase 1).
4. Skip `sync setup` in the kit. Write the config file directly with `machineId = $SANDBOX_ID`, `machineLabel = $SANDBOX_NAME`.
5. Copying files into a sandbox with `sbx cp` keeps the host uid (502) and mode 0600, so the `agent` user cannot read them. Irrelevant to the kit, but remember it for test fixtures (`sbx exec -u root ... chown`).

### 3b. Build recipe for the linux binary

```
curl -fsSL -o model_prices.json \
  https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
docker run --rm \
  -v <fork-repo>:/src:ro -v <scratch>/target:/target -v <scratch>/out:/out \
  -v <scratch>/model_prices.json:/pricing.json:ro \
  -e CARGO_TARGET_DIR=/target -e CCUSAGE_PRICING_JSON_PATH=/pricing.json \
  -w /src/rust rust:1.97-alpine \
  sh -c 'apk add --no-cache musl-dev && cargo build --release -p ccusage --locked \
         && cp /target/release/ccusage /out/ccusage-linux-arm64'
```

### 3c. Phase 1 results (2026-10-10)

Verification: `cargo fmt --check` clean, `cargo clippy --workspace --all-targets` zero warnings, 1,385 tests pass. Two tests fail (`compare::...every_equivalent_in_the_shipped_map_has_a_shipped_price` and `sync::dashboard::...every_comparison_target_has_a_published_price_and_a_source`). Both fail identically on untouched `main` with the LiteLLM snapshot I downloaded, because it no longer lists `moonshot/kimi-k2-*`. They are unrelated to this branch.

End to end with the real binary, one hub, simulated sandboxes:

- Aggregate over sandboxes equals the ground truth from the host's own report for 6 real transcripts, and every day matches. A session visible to two sandboxes is counted once (the shared cell is marked `duplicateSuppressed`). Consumers of `rollup/daily.json` must skip rows with a `suppressed` field.
- The daily rollup rows carry `machine`, so the per-sandbox view needs no extra work.
- Doctor passes over fs and over http (hub reachable, write, read back, CAS, clock).

Bugs found and fixed while doing it, both of which only appear when sandboxes start together:

1. **User-id race in setup.** Machines that set up at the same moment each minted their own user id, and only one could create the manifest, so the rest kept their own and filed usage under users nobody reads (six sandboxes gave six disjoint datasets, and the rollup held one machine). Setup now adopts the manifest's user id when its own was minted. Covered by a test that failed before the fix.
2. **CAS starvation on the shared manifest and rollups.** Five immediate retries are not enough when many writers collide on a fast local hub. Added a jittered backoff after a lost CAS. It does not remove the limit (the engine's five-attempt contract is pinned by existing tests), so the kit's sync loop must retry a failed run after a short random delay. Shards are already uploaded, so a retry is cheap and loses nothing.

Design consequences for the kit (phase 2):

- Use `sync setup --provider http --machine-id "$SANDBOX_ID" --machine-label "$SANDBOX_NAME" --non-interactive` on first start, and retry it on failure. Do not write the config file by hand.
- The kit must set `CCUSAGE_SYNC_TOKEN`. With `sbx secret set-custom` the sandbox holds a placeholder and the proxy swaps the real token, as in `../codex_bedrock_kit_demo`. Not yet tested with the hub.
- The hub's shared token and shared rollups mean one sandbox can write wrong numbers into the aggregate. `sbx secret set-custom` is host-wide, so per-sandbox tokens are not available. A stronger design, if needed later: sandboxes upload shards only and the hub computes rollups itself.
- The data directory root holds a `~lock` file. Back up or inspect the directory freely, but do not delete that file while the hub runs.
- The host owner's config for reading is `{"sync":{"provider":"fs","dir":"..."}}`. `sync status` on it reports "not yet assigned" for user and machine, which is correct but could read better.
- The dashboard server reads the rollups once at startup, so a long-running dashboard does not refresh. Phase 4 should make it re-read per request.

### 3d. Phase 2 results (2026-10-10)

`tests/e2e.sh 3` passes: three sandboxes created at the same moment with the kit, all synced within 39 seconds, host totals equal the sum of the synthetic usage given to each (378 / 3789 / 36018 / 180009), one user, three machines, and `flush` makes new usage appear on the host immediately. An earlier manual run with the real binary showed a Codex-based sandbox joining the same hub as three Claude ones.

Facts learned, several correcting earlier assumptions:

- **Token swap works, with a catch.** The sbx proxy swaps the placeholder over plain HTTP, but only when the secret names `localhost`. The proxy rewrites `host.docker.internal` to `localhost` (and the Host header with it) before matching. Ports are not accepted in a secret's host. So the swap applies to any host loopback port a sandbox sends the placeholder to, and the kit's network rule is what narrows it.
- **Correction:** `sbx secret set-custom --sandbox NAME` exists, so per-sandbox tokens ARE possible. My earlier note that secrets are host-wide was wrong. A per-sandbox token would need the hub to know which token belongs to which sandbox. Not done.
- **Env var is not injected into existing sandboxes** when a secret is added later, even after a restart. The kit therefore sets `CCUSAGE_SYNC_TOKEN` itself to a fixed placeholder, and the secret uses the same fixed placeholder.
- **`files/home` is placed before `setup.install` runs**, binaries survive intact through arg substitution, and the exec bit is not relied on (the installer uses `install -m 0755`). A 9.8 MB kit with both binaries.
- **`SANDBOX_ID` and `SANDBOX_NAME`** are available to the background startup entry, and a UUID is a valid machine id.
- **`sbx stop` does not signal the loop.** The SIGTERM handler works when signalled, but a stop never triggered it, so the "final sync on stop" idea does not hold. Stopped sandboxes catch up on restart. For removal, `flush` closes the gap. A session-end hook is the proper fix (deferred).
- **Idle sandboxes stop by themselves** within a couple of minutes unless a session is attached. The tests keep them awake with periodic `sbx exec`.
- **The Claude parser skips lines that lack the exact bytes `"usage":{`**, so synthetic transcripts must be compact JSON.
- **A sandbox's usage stays after `sbx rm`**, because the host store never deletes. If transcripts are copied between sandboxes, partially overlapping days are counted twice and flagged `duplicateSuspected`.
- `sbx create` accepts `--kit-arg name=value`. Concurrent `sbx create` of four sandboxes worked.
- Mistakes worth not repeating: a bare `wait` also waits for background services, and a nested heredoc delimiter ends an outer one early.

### 3e. Phase 3 results (2026-10-10)

**A real data loss in the sync engine, now fixed.** Claude Code deletes old session files by age, and a day is made of entries from several files. A day that outlived some of its own files was recomputed smaller and replaced the larger uploaded shard (a test showed 300 becoming 100). The engine already kept days that vanish entirely, but not days that shrink. The fix merges the fresh fold into the uploaded shard cell by cell (`Shard::retaining`): a cell with every entry the old one had wins, a cell with only some leaves the old one, and cells that each hold something the other lacks keep the larger total. Verified with the real binary: two sessions on one day uploaded 3,306 input tokens, one file deleted, the local view fell to 3,003, the bucket stayed at 3,306, and later syncs reported nothing to do. It matters for sandboxes in particular because the loop runs inside the sandbox binary, so the kit binaries must be rebuilt to get it.

Other findings:

- `sync machines` text output and the dashboard Machines panel were checked, the latter by screenshot with an active, a retired and a never-synced machine. Machines whose usage is all counted elsewhere now appear with zero instead of being hidden.
- `tests/recreate.sh` passes. `sbx kit add` (which recreates the container) keeps `SANDBOX_ID`, the sync config and the machine, restarts the loop, and adds no second machine. Removing a sandbox and creating one with the same name gives a new `SANDBOX_ID` and so a new machine; the old one stays on the roster.
- A negative `--retired-after` is rejected as "Missing value" because the parser reads the dash as a flag.
- Gates: fmt clean, clippy zero warnings, 1,409 tests pass and the same two pre-existing pricing-snapshot failures.

Open points left for later:

- Partial overlap between machines is flagged, not resolved. Exact handling would need per-message token amounts in the shard schema.
- A merged cell that unions two disjoint sets of entries (pruned entries plus new ones in the same 15-minute window) keeps the larger total and so under-counts a little. Rare, and the alternative is a schema change.
- Costs for already uploaded days keep the pricing of the binary that uploaded them.

### 3f. Agent hooks (2026-10-10)

The kit now registers a hook with Claude Code, Codex, Gemini CLI and GitHub Copilot CLI so a finished turn syncs at once, instead of waiting up to five minutes. `tests/hooks.sh` passes: with the timer set to 300 seconds, usage from a real Claude turn and a real Codex turn reached the host one second after each turn finished.

How it works: the hook script (`sync-now.sh`) only sends SIGUSR1 to the running sync loop and returns. The loop treats that as "sync now", keeps syncs at least 20 seconds apart, and syncs once more if asked again during a sync. `install-hooks.sh` runs on every container start before the loop, and is idempotent. A kit argument `agent-hooks=off` leaves the agents' settings alone (verified).

Facts, several found only by testing:

- **Hooks run in line with the agent.** A 4 second Stop hook added about 4 seconds to a Claude turn, so the hook must return at once.
- **Claude `SessionEnd` hooks are killed after about 2 seconds** (a 6 second one never finished). So the sync cannot be done in the hook; signalling the loop is.
- **Claude** (2.1.280): `Stop` after every response, `SessionEnd` at exit, both also under `claude -p`, both with `session_id` and `transcript_path` on stdin. Registered with a `jq` merge that removes an earlier copy of the hook before adding it, so a user's own hooks survive (tested).
- **Codex** (0.149.1): its own hooks fire (`Stop`, `SessionEnd`, with `transcript_path`) but only with `--dangerously-bypass-hook-trust`; without persisted trust, which needs an interactive approval, they do not run. The `notify` setting needs no trust and fires `agent-turn-complete` under `codex exec`. The kit adds it as the first line of `config.toml` (it must precede any table), and leaves a user's own `notify` alone. The research summary said Codex hooks carry no transcript path, which the real run contradicted.
- **The start-up environment has a clean `PATH`.** `claude` (in `~/.local/bin`) and `codex` (in the npm-global directory) were both missing from it, so the first version silently registered nothing. The installer extends `PATH` and uses Codex's config file as the sign that it is present.
- Mistake caught by the test itself: a manual `sync-now.sh` call earlier in the test script could have explained the quick sync, so the real turn now comes first.

Gemini and Copilot were added afterwards, from the official schemas (Gemini: `hooks` in `settings.json`, timeouts in milliseconds, a hook must print JSON on stdout; Copilot: a drop-in file in `~/.copilot/hooks/` with `"version": 1`), so `sync-now.sh` now prints `{}`. The install logic was tested locally on awkward configs (user hooks kept, repeat runs, invalid JSON left alone, agent absent, opt-out) and then on real sandboxes. What could and could not be verified, because sbx holds no Google or GitHub credentials here:

- **Gemini 0.60.0:** the config is accepted, and `SessionEnd` fires on exit with `session_id`, `transcript_path` and `reason` even when the model call fails (invalid key, HTTP 400). `AfterAgent` needs a successful turn and was NOT exercised.
- **Copilot 1.0.95:** the file is written and Copilot's own `config.json` is untouched, but Copilot stops at authentication before a session starts, so none of its hooks (not even `sessionStart`) could fire. Firing is NOT verified. The test reports it as SKIPPED.
- The first Gemini/Copilot test run gave a false positive: a stopped sandbox restarted by the test syncs on its own. The loop now logs "an agent asked for a sync" and the test looks for that line.
- Verification path for both: `sbx secret set google` and `sbx secret set github` (needs Copilot entitlement), then `tests/hooks.sh`.

Remaining agents (documentation only, NOT tested here, so not implemented):

- OpenCode: a JS plugin in `~/.config/opencode/plugins/` using the `session.idle` event.
- Droid: `Stop` and `SessionEnd` in `~/.factory/hooks.json`.
- Cursor CLI: documented hooks, but forum reports say they are unreliable in the CLI and do not fire on Linux. Kiro: unclear. Devin and docker-agent: not researched.
- These sandboxes still sync by timer, and `ccusage sync run` covers every agent it supports regardless of hooks. I could only test agents whose credentials sbx has here (Claude, Codex).

### 3g. Phase 4 results (2026-10-10)

The dashboard (`ccusage-dashboard` assets, embedded in the binary) gained one filter row, clickable breakdowns, a stackable chart, and Projects and Sessions panels. The local server now also serves `data/sessions.json`, built from the shards (`sync/sessions.rs`): sessions merged across midnight, newest first, capped at 5,000, unreadable shards skipped.

Verification: `tests/dashboard/run.js` drives the real page in Chrome (via `puppeteer-core`) against deterministic fixtures with expected numbers worked out independently: 69 checks pass, covering unfiltered totals, URL filters (one sandbox, agent, model, date range, combinations), drill-down by click and by keyboard, presets, legend as filter, tooltip on hover and focus, table view, sessions and projects, a store with no sessions file, light and dark themes, and a 420px screen. `tests/e2e.sh` additionally checks, against the real server and real sandboxes, that `machines.json` names every sandbox, `sessions.json` has the sessions, and the project is a real name. The Rust gates pass (fmt, clippy, tests; plus the two pre-existing pricing failures), including two new guards in the dashboard crate.

Design decisions and findings:

- **Colour.** Eight categorical slots in the validated order, a neutral "Other" for the tail, assigned by an entity's rank over ALL data so a filter never repaints it. The palette was run through the validator on this page's real surfaces (`#ffffff` and `#171a21`): all hard checks pass in both modes; three light-mode colours (magenta, yellow, aqua) fall under 3:1 contrast, so the legend labels, the tooltip and a table view are the required relief.
- **Chart anatomy.** Bars capped at 24px, rounded only where the data ends, 2px surface gap between segments, hit areas as wide as the day's slot, focusable, one tooltip listing every series with the value leading.
- **Project names.** Claude Code records a project as its path with slashes turned into dashes (`-work-demo`); the panel shows that as recorded, because decoding it is ambiguous. New kit argument `project-names` (default `plain`; `hashed` restores the old behaviour), applied to the sandbox's sync config on every start. This changes the README's privacy line: project paths, not hashes, go to the hub by default, and only to the user's own machine.
- **Sessions carry cost only.** There are no per-session token counts in the data, so the Sessions and Projects panels show cost, and the model filter cannot apply to them (the page says so).
- **Layout bugs found by looking:** the Machines panel was too narrow for a name, status and three figures (now spans two columns on wide screens); the Sessions table clipped its Cost column (now twice the width of Projects); and the existing header controls row overflowed a 420px screen because it never wrapped (fixed).
- Published (bucket) dashboards are unchanged in what they can read: no machines or sessions file, so they show ids and no sessions.
- Not done: filters on a stack ('Other' cannot be clicked), a project filter that applies to spend (spend cells carry no project), per-session token counts.

### 3h. Phase 5 results (2026-10-10)

- **Git is the distribution channel.** The reference form is `git+https://github.com/<owner>/<repo>.git#ref=<ref>&dir=<subdir>`, so the kit stays in `ccusage-kit/`. The host tooling (hub script, build scripts) still comes from a clone, because it is not part of the kit.
- **The kit cannot do without binaries.** The published ccusage has no `sync`. This was first solved by committing the two static binaries (about 10 MB, each rebuild adding that to history); section 3i replaced that with CI-built release assets pinned by committed checksums.
- **Provenance.** `scripts/build-binaries.sh` now writes `BUILD-INFO` (fork URL, branch, commit, clean or dirty tree, build time, toolchain, and the hash of the price file embedded in the binary). The committed binaries were built from the clean fork commit `eeeb8a46`.
- **Token rotation is tested** (`tests/rotate.sh`): after deleting the token file, running `install` and restarting the hub, the old token is refused and an already-running sandbox syncs with the new one without being touched, because sbx replays the secret's command on demand.
- **sbx restricts kit sources, and loading from git was NOT tested end to end.** On this machine `kit.allowedSources` is `["docker.io/","github.com/docker/"]` (an override), so `git+https://github.com/krisfoster/...` would be refused until `github.com/krisfoster/` is added. I did not change the setting. Only `git+https` and `git+ssh` references parse (`git+file` and `git+http` do not), so I could not serve a local repository to try the fetch. What was checked: the reference format against the contrib kits' README, that the `https` form parses and reaches the allow-list check, and that the same kit content works as a directory (every test in this repo) and packs (`sbx kit pack`). The first real fetch will happen when the repository is pushed and the prefix allowed.
- The host side still needs a Rust toolchain and the fork checked out on branch `feat/local-sync-provider`. Running the hub from the Linux binary in a container is possible, but the dashboard binds loopback only and would not be reachable, so it was not done.
- No LICENSE file was added: that is the owner's choice. The shipped binaries are built from ccusage, which is MIT licensed.

## 4. Phases

### Phase 0: Spike (DONE 2026-10-10, see section 3a)

Answer the open questions before writing code.

- [x] Create a throwaway claude sandbox. Confirm the network policy allows a request to `host.docker.internal:<port>` and how to express it in a kit (`permissions.network.allow`). Compare with how `../litellm_demo/litellm-kit` reaches `localhost:4000`.
- [x] Find out how a linux ccusage binary gets into the VM: is the fork's `sync` in the npm `ccusage` package, or must we build the `ccusage-linux-{x64,arm64}` binary from the fork and host it (GitHub release of the fork, OCI layer, or `files/` in the kit)? Check the release workflow in `../ccusage/.github/workflows/release.yaml`. Decide.
- [x] Inside the sandbox run `ccusage claude daily --json --offline` and compare totals with the same sessions viewed from the host. Check pricing data works offline or needs an egress rule.
- [x] Confirm `sbx kit validate` accepts a mixin with no `requires.agent`.
- [x] Confirm what `SANDBOX_ID` looks like at startup hook time (env available to `setup.startup`?).
- [ ] (moved to phase 3) Hand-test the double-count case with a sandbox that mounts the host `~/.claude/projects`.

Exit: go. Binary distribution decided: ship a pinned binary built from the fork.

### Phase 1: Fork, local store and hub (DONE 2026-10-10, see section 3c)

Work is on branch `feat/local-sync-provider` in `../ccusage`: four signed commits (FsStore, CAS backoff, the fs/http providers and hub, docs). Not pushed.

- [x] `FsStore: ObjectStore` (`rust/crates/ccusage/src/fs_store.rs`). Generation is the SHA-256 of the body instead of a counter, so each object is a plain readable file with no sidecar. CAS via an advisory lock file plus write-temp-then-rename.
- [x] Contract tests, including 8 threads racing CAS increments through separate store instances, exactly one winner for `IfAbsent`, and the real `sync doctor` checks passing against the store.
- [x] `ccusage sync serve` hub (`sync/serve.rs`): plain HTTP/1.1 on `127.0.0.1:8777` by default, token file created owner-only on first run.
- [x] `HttpStore: ObjectStore` client (`http_store.rs`) reusing the GCS client's retry and status mapping, with a guard so a wrong URL is an error and not an empty store.
- [x] Config: `sync.provider` accepts `fs` and `http`; new `sync.dir` and `sync.url`. The token is read from `CCUSAGE_SYNC_TOKEN`, never from the config file (which rejects secret-looking keys). Schema artifact updated.
- [x] Non-interactive setup for both providers: `sync setup --provider http --url ... --machine-id ... --machine-label ... --non-interactive`. This replaces the plan to hand-write the config file in the kit, because setup also joins the store's user and salt.
- [x] `sync status`, `doctor`, `dashboard`, `run`, `repair` work against `fs` and `http`. `share`, `remove` and `dashboard --deploy` explain that they need a bucket.
- [x] Hub guards: bearer token, validated keys under one prefix, read-only dashboard prefix, body/connection/time limits, deletes refused by default. Per-sandbox authorization is NOT done (see 3c).

Exit met: six simulated sandboxes set up and synced concurrently through one hub, the dashboard served from the hub's directory, and the aggregate equals ground truth exactly (5 of 5 runs).

### 3i. Binaries published from CI (2026-10-11)

- Decision: build in GitHub Actions on native runners (`ubuntu-24.04-arm`, `ubuntu-24.04`), publish a GitHub release, and pin it by committing its SHA-256 sums. The binaries are no longer in git.
- `fork.lock` names the fork commit and the LiteLLM price-file commit; the workflow builds exactly those, so a build says exactly what it came from (builds of one commit are not byte-identical: the two Linux releases differ, hence the pin is on release checksums). Actions are pinned to commit SHAs. The workflow only runs by hand (`workflow_dispatch`).
- The release carries `SHA256SUMS`, `BUILD-INFO` and a build provenance attestation. `scripts/pin-release.sh <tag>` verifies the attestation, then writes `SHA256SUMS` and `release.env` into the kit. A kit version therefore installs one set of bytes, even if someone later edits the release.
- `install.sh` downloads from `release.env`, checks the checksum and refuses a mismatch. Local builds (`scripts/build-binaries.sh`) are git-ignored and used if present, checked against `SHA256SUMS.local`. `binary-url` and `binary-sha256` kit args install from elsewhere, still checked.
- The kit now needs egress to `github.com` and GitHub's release content hosts at sandbox creation. Added to `permissions.network.allow` (not tested under a restrictive policy).
- Tested locally: download over HTTP from the host with a matching checksum installs and runs; a wrong checksum fails sandbox creation with the mismatch message; an unpinned kit with no local binary fails with a clear message; `tests/e2e.sh` passes using local builds. 
- Published 2026-10-11: fork branch pushed to `krisfoster/ccusage`, kit repo created public at `krisfoster/ccusage-sbx`. The first workflow run failed in the smoke test (a `chmod` on a root-owned file from Docker); the second passed and released `binaries-eeeb8a46`. `pin-release.sh` verified the attestations and pinned it. A sandbox created from the local directory with no local binaries downloaded from GitHub, and `sha256sum` of the installed binary equals the pinned arm64 sum. x64 was built and pinned but not run. Loading the kit over `git+https` is still untested: `kit.allowedSources` refuses `github.com/krisfoster/` until the user adds it.

### 3j. Hub on macOS and Linux (2026-10-11)

- The host no longer needs Rust: the workflow also builds `ccusage-darwin-arm64` and `ccusage-darwin-x64` on native macOS runners (`macos-15`, `macos-15-intel`, deployment target 12.0), and `scripts/install-host-binary.sh` downloads the right one for the host (the Linux hosts use the same static binaries as the sandboxes), checking the committed SHA-256. Release `binaries-eeeb8a46-2` holds all four; the arm64 macOS one was installed and run here.
- The hub script was run on Linux in a Debian arm64 container: install, run, status, doctor and the systemd unit text. Not a real systemd service, and no sbx on Linux.
- `host/ccusage-sbx-hub dashboard` now says so when nothing has synced, instead of the engine's error.
- On this machine `~/.local/bin/sbx` is a wrapper (set up by the user in another session) that adds this kit to every `sbx create` and `sbx run`. Tests that pass `--kit` themselves hit "duplicate kit name ccusage-sync", so `tests/sbx-real.sh` makes them call the real sbx binary. The wrapper also showed that loading the kit over `git+https` works end to end, including the release download.
- Rewrote the README's set-up section as ordered steps with a verify step.

### 3k. Dashboard went stale (2026-10-12)

- Report: a new sandbox (`claude-bedrock-demo`) ran a command and exited, and the dashboard did not show it. The hub had the data (`machines` listed the sandbox as synced today). The dashboard process had been started a day earlier and served the rollups it read at startup: `serve_locally` loaded them once. The comment next to `Cache-Control: no-store` said a later sync would show on reload, which was false.
- Fix in the fork (`dc0105b8`): reload the store when the last read is over two seconds old, and keep the last good read if a reload fails. `tests/e2e.sh` now keeps a dashboard running across a flush and fails on the old binary (checked) and passes on the new one. Released as `binaries-dc0105b8` and pinned.
- Still true: an open browser tab does not refresh itself; reload the page to see new usage.
- To get the fix: `scripts/install-host-binary.sh`, then restart the hub and the dashboard. Sandboxes keep their old binary until recreated (the fix does not touch sandbox code).

### Phase 2: The kit (DONE 2026-10-10, see section 3d)

Files are in this repo, uncommitted (this directory is not under version control yet).

```
ccusage-kit/spec.yaml, files/home/.local/share/ccusage-sbx/{install.sh, sync-loop.sh, release.env, SHA256SUMS}
host/ccusage-sbx-hub          install | uninstall | status | run | flush | dashboard | doctor | repair
scripts/build-binaries.sh     static linux arm64 + x64 binaries from the fork (Docker)
scripts/build-host-binary.sh  the fork's ccusage for the host (cargo)
tests/e2e.sh                  creates N sandboxes with the kit and checks exact totals
README.md
```

- [x] `spec.yaml` (mixin, no `requires.agent`, so it layers onto claude and codex): args for hub port, interval and token placeholder; network allow for `host.docker.internal:<port>`; env vars; install and background startup entries.
- [x] Binaries: first shipped inside the kit, now downloaded from a release at install and checksum-checked (3i). Egress after install is only the hub.
- [x] Loop script in POSIX `sh`: single instance, joins with `sync setup --provider http`, jittered first sync, `sync run` every interval plus up to a minute, up to six retries with short random pauses, log rotation, a last sync on SIGTERM.
- [x] Host tooling: token creation, launchd and systemd units (dry run and `plutil -lint` only), sbx secret registration, `flush`, `dashboard`.
- [x] End-to-end test with sandboxes created concurrently.
- [x] Agent hooks that sync right after a turn ends, for Claude Code and Codex (section 3f).
- [ ] Deferred: testing on Linux hosts, under a restrictive sbx policy, and as a real launchd service.

### Phase 3: Aggregation correctness and per-sandbox views (DONE 2026-10-10, see section 3e)

Fork work is on `feat/local-sync-provider`: three more signed commits (the shrink fix, `sync machines` with the dashboard panel, docs). Not pushed.

- [x] Aggregate equals the sum of sandboxes: covered by `tests/e2e.sh` (exact totals over three sandboxes, two days, synthetic usage) and the fork's merge matrix.
- [x] Double counting: the engine suppresses a cell wholly contained in another machine's and flags partial overlaps (`duplicateSuspected`) rather than guess. The dashboard already lists both under Notices. Left as is, and documented. A partial overlap cannot be resolved exactly because a cell stores one total, not one per message.
- [x] Retirement: `ccusage sync machines [--json] [--retired-after N]` (default 14 days), a `machines` command in the host script, and a `data/machines.json` that the local dashboard uses to label machines and show active or retired and the last sync.
- [x] Pruned transcripts: a real data loss was found and fixed (3e).
- [x] Machine identity across container recreation: verified with `tests/recreate.sh`.

### Phase 4: Local dashboard and explorer (DONE 2026-10-10, see section 3g)

Fork changes are committed as three signed commits (sessions data, the dashboard explorer, docs). Not pushed.

- [x] Machines panel labels sandboxes by `machineLabel` (done in phase 3, checked by screenshot).
- [x] Filters: date range with presets, sandbox, agent, model; project and session drill-down for the local dashboard. Row and legend clicks filter; state lives in the URL.
- [x] Group-by: the daily chart stacks by sandbox, agent or model. "Base agent" is the agent filter and stack. Project and workspace path are covered by the Projects panel (cost only).
- [x] Loopback and offline as before: no new network requests, no external assets.

### Phase 5: Packaging and docs (DONE 2026-10-10, see section 3h)

Scope changed by decision: the kit is loaded straight from git (`git+https://...#dir=ccusage-kit`), so there is no registry, no signing, and no release.

- [x] README: what leaves the sandbox, install from git, troubleshooting (hub down, token rejected, policy), token rotation, uninstall.
- [x] Binaries: built and released by a workflow, pinned by committed checksums (3i). An interim version committed them to git; that is gone.
- [x] Everything committed. `ccusage-sbx` is now its own git repository (it was untracked inside an unrelated outer repo that has no commits and holds other projects' files, which was left alone).
- [-] Not done, by decision: `sbx kit push`/`sign` (no registry), an upstream PR to ccusage.

## 5. Risks

| Risk | Mitigation |
|---|---|
| Sandbox network policy blocks the host, or the host address differs by platform | Reachable on this machine under Allow_All (phase 0). Still untested under a restrictive policy; document per-platform address; fall back to a published port plus `sbx ports` if needed |
| The fork's `sync` is not in a published binary | Decide in phase 0; worst case the kit downloads a binary built from the fork |
| CAS bugs in `FsStore` corrupt rollups | Mitigated: contract and concurrency tests pass, and a six-way concurrent end-to-end run matched ground truth. `sync repair` rebuilds rollups from shards |
| Many sandboxes starting together starve each other's shared writes | Backoff added in phase 1; the kit's loop must retry a failed run after a random delay (shards are already durable) |
| A compromised agent writes false stats | Token held outside the VM, validated keys, size caps, deletes refused. One shared token and shared rollups mean it can skew the aggregate, not just its own numbers. `sync repair` rebuilds rollups; per-sandbox authorization is future work |
| Hub down, usage unsynced, then sandbox removed | Final sync on stop; retry with backoff; document that unsynced usage is lost on `rm` |
| Double counting from host-mounted session data | Phase 3 tests and docs |
| Divergence from upstream ccusage | Keep the provider changes isolated behind the trait, upstream them if accepted |

## 6. Out of scope for v1

Cloud storage, share links and published dashboards (keep GCS path untouched), multi-user or team aggregation, cost alerts, sandboxes running on Docker Cloud (`--cloud`), Windows hosts.

## 7. Open questions

1. Where to host the pinned binaries: GitHub release of the fork, or baked into the kit `files/` (4.7 MB per arch).
2. Does the user want the host's own Claude usage as a separate machine in the store? Default: yes, as an opt-in `host` machine added by `install-hub.sh`.
3. Hub as launchd/systemd service or as a container? Default: service on the host; container as an alternative.
4. Default sync interval: proposed 10 minutes.
