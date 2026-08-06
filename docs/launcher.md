# One-command macOS launcher

A personal, clickable `.command` file that starts or attaches a single Herdr-backed Pi primary for one Firstmate checkout, pinned to a captain-chosen model, and then attaches the visible Herdr client.
It is a convenience wrapper around already-supported Herdr and Pi entry points, not a new control plane: it never repairs, closes, or replaces anything it cannot positively identify, and it never stops, deletes, restarts, or updates the shared Herdr server or session.

## Install

1. Copy [`examples/launcher.conf`](examples/launcher.conf) to `config/launcher.conf` in this checkout and fill in every required field: `model`, `thinking`, `pi_bin`, `quota_provider`.
   `config/launcher.conf` is local and gitignored; the installer refuses to run without it, and never guesses a captain-specific model, reasoning level, executable, or quota provider on your behalf.
2. Run `bin/fm-install-launcher.sh <destination-directory>`, for example `bin/fm-install-launcher.sh ~/Desktop`.
   It resolves this exact checkout's own root as the installed launcher's Firstmate home - never relative to the destination - and writes `fm-launcher.command` (mode `0700`) plus a generated `fm-launcher.conf` (mode `0600`) recording that home and your configured choices.
   The destination directory, and this checkout's own path, may contain spaces; both are resolved exactly, never derived by splitting on whitespace.
3. Re-run the same command any time to reinstall in place, for example after editing `config/launcher.conf` or moving the destination.
4. First use: macOS Gatekeeper may ask to confirm running a downloaded/unsigned script; approve once via System Settings > Privacy & Security if it's blocked outright.
5. On the very first real `pi` launch in this checkout, Pi prompts to trust the project so `.pi/extensions/*.ts` auto-load; grant that once per clone (see the README).

## Usage

- Double-click `fm-launcher.command` (or run it from Terminal): start-or-attach for real.
- `./fm-launcher.command --check` - run every dependency/config/model/quota/ambiguity check with zero mutation.
- `./fm-launcher.command --dry-run` - print the exact one-line action it would take, zero mutation.
- `./fm-launcher.command --adopt-current` - first-install only, run FROM INSIDE an already-live Herdr Pi primary pane to record its identity without renaming, closing, launching, or spending quota.
- `./fm-launcher.command --help` - full flag reference.

## Safety boundaries

- **Identity is exclusively an exact recorded journal** (workspace/tab/pane/terminal id), never a scan for "any Pi agent at this cwd" - an ordinary crewmate or secondmate Pi pane can legitimately share the same working directory as the primary, and the launcher never treats that as a duplicate or foreign endpoint.
- **A live primary is only focused and attached**, never restarted; a proven idle husk (a childless shell, verified through Herdr's own process-info, at the exact recorded pane) is recovered in place, never by closing or replacing the pane; anything less certain is reported, never destructively repaired.
- **Quota is enforced only on actions that can start or recover a model process** - a new primary or dead-primary recovery - never on attaching an already-live primary or on `--adopt-current`, which only records an identity that already exists and never starts, resumes, or spends quota.
- **The quota gate requires fresh first-party OAuth** for the configured provider (never API-key routing) and refuses below the configured reserve percent, never falling back to paid or extra usage.
- **Any ambiguity - a duplicate label, an unreadable pane, a mismatched identity, a foreign live session-lock owner - is always a refusal**, never a guess; the launcher prints the exact Herdr session to inspect by hand.
- **Concurrent launches serialize** through a single-flight, home-scoped lock distinct from Firstmate's own session lock (which the launcher only ever reads, never writes or clears).
- **Logging is bounded and redacted**: `state/.fm-launcher.log`, mode `0600`, trimmed once it exceeds roughly 200KB; every line is a fixed human-authored string plus small identifiers, never raw quota JSON, environment, credentials, or prompts.

## Config reference

`config/launcher.conf` fields, their requirements, and their defaults are documented inline in [`examples/launcher.conf`](examples/launcher.conf), the copyable starting point.
`bin/fm-install-launcher.sh` validates every field before installing and refuses on a missing, malformed, or unrecognized one rather than silently accepting it.

## Rollback / removal

Delete the installed `fm-launcher.command` and `fm-launcher.conf` from the destination directory to remove the artifact entirely.
It owns no other state outside `state/.fm-launcher.log`, `state/.fm-launcher.lock`, and `state/.fm-launcher-primary-identity` in the Firstmate home, all safe to delete any time no launch is in progress.
Removing it does not affect any existing Herdr workspace/tab/pane, any Firstmate task, or the primary itself - it only stops offering the one-click entry point.
