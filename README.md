# ccusage for Docker Sandboxes

See what your coding agents cost across every Docker sandbox, in one place on your own machine.

The kit installs [ccusage](https://github.com/ccusage/ccusage) inside each sandbox and syncs the usage it finds
to a small hub on your computer. The hub keeps every sandbox's usage, adds it up, and serves a local dashboard
with an overall view and a per-sandbox view. Usage stays after a sandbox is removed.

```
 host                                              sandbox (one per sbx)
 ----                                              ---------------------
 ccusage-sbx-hub (service)  <---- HTTP + token ---- ccusage sync run, every few minutes
   |  ccusage sync serve         via the sbx proxy    reads ~/.claude, ~/.codex, ...
   v
 ~/.ccusage-sbx/data
   |
   v
 ccusage-sbx-hub dashboard  -> http://127.0.0.1:8787
```

What leaves a sandbox, and only to the hub on your own machine: token counts, costs, session ids and project paths
(hashed if you pass `--kit-arg project-names=hashed`). Prompts, responses and file contents are never read into the
store.

## Requirements

- Docker Sandboxes (`sbx`).
- A macOS or Linux computer (arm64 or x64), with `bash` and `curl`. Nothing else: the host program is downloaded, not
  built, so no Rust or Docker is needed.
- Network access to `github.com` from the computer (to download) and from each sandbox when it is created.

## Set up

Do the steps in this order. The hub has to exist, with its token registered with sbx, before the first sandbox is
created.

**1. Let sbx load the kit from this repository (once).** sbx only loads kits from sources it has been told to trust
(`sbx settings get kit.allowedSources`). Add this repository's prefix, keeping what is already there:

```bash
sbx settings set kit.allowedSources '["docker.io/","github.com/docker/","github.com/krisfoster/"]'
```

If your organisation manages that setting, ask for the prefix to be added, or use a clone with `--kit ./ccusage-kit`
in step 5. Without it, sbx refuses the kit and says so, naming `kit.allowedSources`.

**2. Get this repository.** The host tooling (the `host/` and `scripts/` directories) runs from a clone.

```bash
git clone https://github.com/krisfoster/ccusage-sbx.git
cd ccusage-sbx
```

**3. Install the host program.** `scripts/install-host-binary.sh` downloads the `ccusage` build for this computer
(macOS or Linux, arm64 or x64) from the release this checkout pins, refuses it unless its SHA-256 matches the
committed one, and puts it in `~/.local/share/ccusage-sbx/bin/`. The published ccusage cannot run a hub, so this
build of the [fork](https://github.com/krisfoster/ccusage) is needed on the host as well as in the sandboxes. To build
it from source instead, `scripts/build-host-binary.sh <path-to-fork>` (needs Rust).

```bash
scripts/install-host-binary.sh
```

**4. Start the hub.** This creates a random token (`~/.config/ccusage-sbx/hub-token`, readable only by you), a data
directory (`~/.ccusage-sbx`), starts the hub now and at every login, and registers the token with sbx so that
sandboxes can use it without ever seeing it. Run it with `--dry-run` first to see exactly what it would do.

```bash
host/ccusage-sbx-hub install
```

The hub listens on `127.0.0.1:8777`, so only this computer can reach it. If that port is taken, set
`CCUSAGE_SBX_PORT=<port>` for this step and pass `--kit-arg hub-port=<port>` in step 5.

- **macOS:** it runs as a launchd agent (`~/Library/LaunchAgents/com.docker.ccusage-sbx-hub.plist`).
- **Linux:** it runs as a systemd user service (`~/.config/systemd/user/ccusage-sbx-hub.service`). To keep it
  running when you are not logged in, run `loginctl enable-linger "$USER"`. Without systemd, run
  `host/ccusage-sbx-hub run` yourself, in a terminal or under whatever you use to supervise processes; the
  `--skip-service` option leaves the service out.

**5. Create sandboxes with the kit.** Any agent; the kit is a mixin.

```bash
sbx create claude . --kit "git+https://github.com/krisfoster/ccusage-sbx.git#dir=ccusage-kit"
```

To pin a version, name a commit: `#ref=<commit>&dir=ccusage-kit`. From a clone, `--kit ./ccusage-kit` works too. The
kit only works when a sandbox is created: `sbx kit add` refuses kits that have startup commands, so an existing
sandbox has to be recreated to get it. When it is created, the sandbox downloads and checks its `ccusage` (see
below), then starts syncing.

**6. Check that it works.** A sandbox syncs a few minutes after it starts, and again as soon as an agent finishes a
turn.

```bash
host/ccusage-sbx-hub status               # hub reachable? secret registered? how many sandboxes have synced?
host/ccusage-sbx-hub flush <sandbox>      # don't want to wait: sync that sandbox now
host/ccusage-sbx-hub dashboard --open     # overall and per-sandbox usage, in your browser
```

The dashboard has nothing to show until one sandbox has synced; until then it says so. If `status` does not show
the hub as reachable or a sandbox never appears, see Troubleshooting.

**7. Optional: a command for the dashboard.** `scripts/install-command.sh` writes a `ccusage-sbx-dashboard` command
into `~/.local/bin` that opens the dashboard (`--uninstall` removes it).

Everything stays on your computer. Nothing is sent to a cloud service or bucket: the hub stores its data as
ordinary files under `~/.ccusage-sbx/data`.

### The binaries in the kit

The sandbox needs a `ccusage` that can sync, and the published one cannot, so the kit installs a static build of the
fork (Linux arm64 and x64). The same release also holds the macOS builds and the Linux ones that step 3 installs on
the host. When a sandbox is created, `install.sh` downloads the build named in
`ccusage-kit/files/home/.local/share/ccusage-sbx/release.env` from this repository's GitHub releases, and runs it only
if its SHA-256 matches `SHA256SUMS` in the same directory. Both files are committed, so a given version of the kit
installs exactly one set of bytes, whatever is on the release page later. This needs the sandbox to reach `github.com`
and GitHub's two content hosts, which the kit's network rules allow.

The binaries are built by the `Build and publish ccusage binaries` workflow (run by hand from the Actions tab). It
checks out the fork commit named in `fork.lock`, builds each architecture on a native runner, and publishes a release
with `SHA256SUMS`, `BUILD-INFO` and a build provenance attestation. To update them:

```bash
# edit fork.lock (the fork commit must be on GitHub), run the workflow, then
scripts/pin-release.sh <release-tag>     # checks the attestation, rewrites SHA256SUMS and release.env
git add -A ccusage-kit && git commit
```

To try a change without a release, `scripts/build-binaries.sh` builds into the kit directory (git ignores the
result), and `install.sh` uses it, checked against `SHA256SUMS.local`. `binary-url` and `binary-sha256` kit arguments
install a binary from anywhere else, still checked.

## The dashboard

`host/ccusage-sbx-hub dashboard --open` serves a page that you can filter and drill into, all on your machine.

- **Filters** in one row: date range (7, 30, 90 days or a custom range), sandbox, agent and model. Click a row in a
  table, or an entry in the chart legend, to filter to it; the choice is in the address, so a view can be bookmarked.
- **Stack the daily chart** by sandbox, agent or model, with a table view of the same numbers. A sandbox keeps its
  colour whatever you filter, because colour follows its rank over all your data.
- **Projects and Sessions** show which project and session spent what: cost only, since tokens are not recorded per
  session. Projects appear as the agent recorded them with the default `project-names=plain` (Claude Code names a project by
  its path with slashes turned into dashes), and as `hashed ...` otherwise.
- **Machines** names each sandbox by its label and shows whether it is active or retired.

## Day to day

| Command | What it does |
|---|---|
| `host/ccusage-sbx-hub status` | Hub reachable, secret registered, how many sandboxes have synced |
| `host/ccusage-sbx-hub machines` | Every sandbox that has synced: label, active or retired, last sync, days of usage |
| `host/ccusage-sbx-hub dashboard --open` | The local dashboard, with a per-sandbox panel |
| `host/ccusage-sbx-hub flush NAME...` | Sync those sandboxes now. Do this before `sbx rm` (see below) |
| `host/ccusage-sbx-hub doctor` | Check the store: write, read back, compare-and-swap, clock |
| `host/ccusage-sbx-hub repair` | Rebuild the totals from each sandbox's raw records |
| `host/ccusage-sbx-hub uninstall` | Stop the hub and remove the secret. Your data is kept |

Inside a sandbox, `~/.local/state/ccusage-sbx/sync.log` shows what the loop has been doing.

## Kit arguments

Pass with `sbx create ... --kit ./ccusage-kit --kit-arg name=value`.

| Argument | Default | Meaning |
|---|---|---|
| `hub-port` | `8777` | Port the hub listens on. Set `CCUSAGE_SBX_PORT` to match on the host |
| `sync-interval` | `300` | Seconds between syncs. Up to a minute of random delay is added so sandboxes started together do not collide |
| `project-names` | `plain` | `plain` syncs each session's project path so the dashboard can name projects. `hashed` replaces it with a salted hash. It only goes to the hub on your machine |
| `agent-hooks` | `on` | `off` stops the kit touching the agents' settings (see below) and leaves syncing to the timer |
| `token-placeholder` | `ccusage-hub-token` | The placeholder registered with sbx. Change both sides or neither |

## Syncing as soon as a turn ends

The timer alone would leave the last few minutes of a session unsynced for up to five minutes, and a sandbox can
stop first. So the kit also registers a small hook with the agents it knows how to. When a turn ends, the hook
tells the sync loop to sync now, and the loop does it, at least 20 seconds after the last sync. The hook itself
returns at once, because agents run hooks in line with their own work and kill slow ones.

| Agent | What the kit registers | Checked |
|---|---|---|
| Claude Code | `Stop` and `SessionEnd` hooks, merged into `~/.claude/settings.json` | Yes, with real turns |
| Codex | the `notify` setting at the top of `~/.codex/config.toml` | Yes, with real turns |
| Gemini CLI | `AfterAgent` and `SessionEnd` hooks, merged into `~/.gemini/settings.json` | `SessionEnd` yes (it makes the loop sync even when the turn fails). `AfterAgent` is registered as documented but needs a successful turn, which needs Google credentials, so it was not run |
| GitHub Copilot CLI | its own file, `~/.copilot/hooks/ccusage-sync.json` (`agentStop` and `sessionEnd`) | The file is written and nothing else is touched, but whether Copilot fires it was **not verified**: Copilot will not start a session without GitHub credentials |
| Anything else (OpenCode, Droid, ...) | nothing | Synced by the timer only |

This happens on every sandbox start and is safe to repeat: your own hooks and settings are kept, and a Codex
`notify` you already set is left alone (the timer covers that sandbox). Pass `--kit-arg agent-hooks=off` to leave
the agents' settings untouched.

Codex's own hooks need an interactive approval nobody can give in a sandbox, which is why `notify` is used.
Copilot gets a file of its own because it reads every file in its hooks directory, so none of yours is edited.

To verify the two that could not be: store credentials with `sbx secret set google` and `sbx secret set github`,
then run `tests/hooks.sh`. It makes one tiny request per agent that has credentials, and fails if a hook does not
fire. Without them it says so and skips, rather than passing.

OpenCode, Droid, Cursor and Kiro have hooks or plugins too and are not registered. A new agent is a few lines in
`install-hooks.sh`, and `tests/hooks.sh` is the pattern for proving it works.

## How the token stays out of the sandbox

The sandbox holds only a placeholder in `CCUSAGE_SYNC_TOKEN`. When a request to the hub passes through the sbx
proxy, the proxy swaps in the real token. `host/ccusage-sbx-hub install` registers that swap with
`sbx secret set-custom`, reading the token from a file on the host.

Two details worth knowing:

- The secret has to name the host `localhost`, not `host.docker.internal`. The proxy rewrites the name before it
  matches secrets, and sbx does not accept a port in the host. So the swap applies to a request to any port on the
  host's loopback, if the sandbox sends the placeholder there. The kit's network rule only lets the sandbox reach
  the hub's port, so with a restrictive sbx policy that is the only port it can use.
- Secrets can be scoped to one sandbox with `--sandbox`. The installer registers a global one so every new
  sandbox works. The hub has a single token for all sandboxes.

## Things to know

- **Removing a sandbox.** `sbx stop` does not give the sync loop a chance to run a last time. The agent hooks
  above make that gap small for the agents they cover, but for the others the final few minutes can still be
  inside a stopped sandbox. If it is started again it catches up. If you are about to remove it, run
  `host/ccusage-sbx-hub flush NAME` first. Usage already synced is kept after removal.
- **Recreated containers keep their identity.** `sbx kit add` recreates a sandbox's container, and the sandbox
  keeps its ID, its sync config and its place on the list, so nothing is counted twice. A sandbox removed and
  created again with the same name is a new machine. The old one stays on the list and is marked retired after 14
  days without a sync (`machines --retired-after N` changes that). Its usage stays in the totals.
- **Deleted transcripts do not lower the totals.** Claude Code deletes old session files by age. Syncing keeps
  whatever was already uploaded for a day, so a total never goes down because a log was cleaned up.
- **Idle sandboxes stop by themselves**, and the loop stops with them. That is fine: usage only accrues while an
  agent runs.
- **Costs are worked out inside the sandbox**, from prices built into the binary. A model released after the
  binary was built has no price and shows as zero or unpriced. Update `PRICES_COMMIT` in
  `fork.lock`, publish new binaries (see above) and recreate sandboxes to refresh.
- **The same session seen by two sandboxes is counted once**, when one sandbox's day is wholly inside another's.
  If two sandboxes share only part of a day, the overlap is counted twice and flagged `duplicateSuspected` in the
  rollup. This happens if you copy transcripts between sandboxes or mount the same `~/.claude/projects` in two.
- **One misbehaving sandbox can write wrong numbers** into the totals, because they share a token and the totals
  are shared. It cannot read outside the data directory or delete anything. `repair` rebuilds the totals.
- **Many sandboxes starting together** can occasionally collide on the shared totals. The loop retries after a
  short random delay and nothing is lost.

## Troubleshooting

Start with `host/ccusage-sbx-hub status`, then look at the sandbox's own log:
`sbx exec NAME tail -20 ~/.local/state/ccusage-sbx/sync.log`.

| What you see | What it means |
|---|---|
| `CONNECT proxy failed: proxy server responded 502` | The sandbox cannot reach the hub. It is not running, or its port is not the kit's `hub-port` (the host side is `CCUSAGE_SBX_PORT`). |
| `credentials from CCUSAGE_SYNC_TOKEN were rejected` | The token secret is missing or stale. Run `host/ccusage-sbx-hub install` again, which re-registers it. |
| `could not join the hub` repeating | Both of the above are logged this way. The error line above it says which. |
| sbx refuses the kit URL and names `kit.allowedSources` | The source is not on sbx's allow-list. See Set up. |
| The sandbox does not appear in `machines` | It was created without the kit, or before the secret existed and has not retried yet. Recreate it with the kit. |
| A sandbox shows $0 in the dashboard | Everything it reported was also reported by another sandbox, and is counted there. |
| Usage is a few minutes late | Agents with a hook (see the table above) sync when a turn ends. The rest wait for the timer. Run `flush NAME` to sync now. |

If your organisation restricts sandbox network access, allow `host.docker.internal:<hub-port>` for the sandboxes.
The kit declares it, but that was only exercised under a permissive policy.

To rotate the token, delete `~/.config/ccusage-sbx/hub-token`, run `host/ccusage-sbx-hub install` and restart the hub.
sbx reads the token from that file when it needs it, so sandboxes pick the new one up.

## Uninstall

```bash
host/ccusage-sbx-hub uninstall                       # stops the hub and removes the service and the sbx secret
sbx rm NAME                                          # remove the sandboxes you created with the kit
rm -rf ~/.ccusage-sbx ~/.config/ccusage-sbx          # your usage data and the token
rm -rf ~/.local/share/ccusage-sbx                    # the host binary
```

The first command leaves your data in place on purpose. The last three are what actually delete it.

## Not tested yet

- A restrictive sbx network policy. The kit declares `host.docker.internal:<port>`, and it validates, but it was
  only exercised under the permissive policy on the development machine.
- Linux hosts with sbx. The hub script was exercised on Linux in a Debian container (install, run, status, doctor, the
  systemd unit it would write), but not as a real systemd service, and no sandboxes were synced into it from Linux.
  macOS Apple silicon is the only platform run end to end. The Intel macOS and Linux x64 binaries were built and
  pinned but never run.
- `host/ccusage-sbx-hub install` as a real launchd service at login (checked with `--dry-run` and `plutil -lint`; the
  hub itself was run in the foreground).
- Cloud sandboxes (`sbx --cloud`).

## Tests

```bash
tests/e2e.sh 3        # creates 3 sandboxes, syncs synthetic usage, checks the totals and the flush command
tests/recreate.sh     # what survives sbx kit add and a remove-and-create with the same name
tests/rotate.sh       # rotating the hub token, with a sandbox that is already syncing
tests/hooks.sh        # the agent hooks, with one tiny real request to each agent that has credentials
(cd tests/dashboard && npm install && node run.js)   # the dashboard in a real browser, against fixture data
```

The sandbox tests pass `--kit ./ccusage-kit` themselves, from this checkout, and call the real `sbx` binary rather than
any wrapper script on your PATH (for example one that adds a default kit to every `sbx create`). Set `SBX_REAL=<path>`
to choose it.

It runs its own hub on another port and uses secrets scoped to its own sandboxes, so it leaves nothing behind.

## Layout

```
ccusage-kit/                  the sbx kit (mixin)
  spec.yaml
  files/home/.local/share/ccusage-sbx/
    install.sh                downloads the binary for the architecture from the release and checks its checksum
    release.env, SHA256SUMS  which release, and the checksums it must match (scripts/pin-release.sh writes both)
    sync-loop.sh              joins the hub, then syncs on a schedule and on request, retrying failures
    install-hooks.sh          registers the agent hooks (Claude Code, Codex, Gemini, Copilot), idempotently
    sync-now.sh               the hook itself: tells the loop to sync, and returns at once
host/ccusage-sbx-hub          install / run / status / flush / dashboard on the host
scripts/                      install the host binary, build binaries, pin a release, install the dashboard command
.github/workflows/            builds and publishes the binaries
fork.lock                     the fork and price-file commits the binaries are built from
tests/                        end-to-end checks against real sandboxes, and the dashboard in a browser
```
