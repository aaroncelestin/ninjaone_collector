# NinjaOne Activity Log Collector

Pulls activity logs from the NinjaOne API (`/v2/activities`) and writes them as JSON lines to a new file every day, so a SIEM agent can pick them up.

- **No gaps, no duplicates:** remembers the last activity ID it collected and only saves it after the logs are safely on disk.
- **Oldest first:** each batch is sorted by `activityTime`, so the newest entries land at the bottom of the file.
- **Daily files:** `/var/log/ninjaone/YYYYMMDD.log` by default (the date comes from when the logs are collected, in local time).
- **Runs as a locked-down systemd timer** under its own service account (every 5 minutes by default).

## Contents

| File | Purpose |
|---|---|
| `ninjaone_collector.py` | The collector |
| `install_ninjaone_collector.sh` | Installer and uninstaller (systemd service, timer, service account) |
| `.env.example` | Template for your API credentials |
| `.gitignore` | Keeps `.env`, `.auth.env`, virtualenvs and local logs out of git |

## Requirements

- Linux with **systemd** (for the installer). Running the collector by hand only needs Python.
- **Python 3.8+** and the `requests` package. The installer installs `python3-requests` with apt, or builds its own virtualenv if apt isn't available.
- A NinjaOne API client app (see below).

### WSL

systemd is off by default in WSL. Turn it on by adding this to `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then run `wsl --shutdown` from Windows PowerShell and reopen your distro.

Keep the project (and especially `.env`) in your Linux home folder, not under `/mnt/c/...`. Windows drives ignore `chmod`, so the credentials file can't be locked down there. If you edit files in a Windows editor, convert them back to Unix line endings before running:

```bash
sed -i 's/\r$//' install_ninjaone_collector.sh ninjaone_collector.py
```

---

## Setting up the `.env` file

The collector reads its NinjaOne API credentials from a file named `.env` in the **same folder as `ninjaone_collector.py`**. The installer reads the same file and copies the credentials into a secure location (see [What gets installed](#what-gets-installed)).

### 1. Create a NinjaOne API client app

In NinjaOne, go to **Administration → Apps → API → Client App IDs → Add** and set:

| Setting | Value |
|---|---|
| Application platform | API Services (machine-to-machine) |
| Scopes | **Monitoring** |
| Allowed grant types | **Client Credentials** |

Save it, then copy the **Client ID** and **Client Secret**. The secret is only shown once.

> Menu names can differ slightly between NinjaOne versions. The parts that matter are a machine-to-machine app with the Monitoring scope and the client credentials grant.

### 2. Create the file

```bash
cd ~/workspace/ninjaone_python
cp .env.example .env
nano .env
```

```ini
CLIENT_ID=C85xcd...
CLIENT_SECRET=-VRbL69...
```

Format rules:

- One `KEY=value` per line. No spaces around `=` are needed, and none are kept.
- Quotes are optional: `CLIENT_SECRET="abc"` and `CLIENT_SECRET='abc'` both work.
- Lines starting with `#` are comments. `export KEY=value` is also accepted.
- A secret that starts with `-` is fine as-is.

### 3. Lock it down

```bash
chmod 600 .env
ls -l .env     # should show -rw-------
```

The collector logs a warning if other users can read the file.

### 4. Keep it out of git

`.env` and `.auth.env` are already listed in `.gitignore`. If one was committed before the ignore rule existed, stop tracking it, then **rotate the secret in NinjaOne**:

```bash
git rm --cached .env
git commit -m "Stop tracking .env"
```

---

## Quick start

```bash
# 1. put these files in one folder with your .env
chmod +x install_ninjaone_collector.sh

# 2. install (interactive: it confirms each setting)
sudo ./install_ninjaone_collector.sh

# 3. watch it work
systemctl list-timers ninjaone-collector.timer
journalctl -u ninjaone-collector.service -f
tail -f /var/log/ninjaone/$(date +%Y%m%d).log
```

Non-interactive example:

```bash
sudo ./install_ninjaone_collector.sh -y --interval 5min --initial-offset 20
```

---

## Installer

```
sudo ./install_ninjaone_collector.sh [options]
```

The installer is safe to re-run. It updates the collector, config and systemd files and **keeps your saved last activity ID**, so changing a setting never collects the same logs twice.

### Options

**Credentials** (if none are given, it uses the `.env` next to the installer, then any already-installed credentials, then asks you)

| Option | Description |
|---|---|
| `--env-file PATH` | Read `CLIENT_ID` / `CLIENT_SECRET` from this file |
| `--client-id ID` | NinjaOne API client ID |
| `--client-secret SECRET` | Client secret. Avoid this one: command-line arguments show up in shell history and `ps`. Use `.env` or the hidden prompt instead. |

**Collector settings**

| Option | Default | Description |
|---|---|---|
| `--source PATH` | `./ninjaone_collector.py` | Collector script to install |
| `--base-url URL` | `https://us2.ninjarmm.com` | Your NinjaOne instance URL |
| `--interval SPAN` | `5min` | How often to run, as a systemd time span (`60s`, `5min`, `15min`, `1h`) |
| `--initial-offset N` | `20` | On the first run, also collect the last N activities |
| `--page-size N` | `500` | Activities requested per API call |
| `--add-iso` | off | Add an `activityTimeISO` (UTC) field to each line |
| `--user NAME` | `ninjaone` | Service account name |
| `--reset-state` | | Delete the saved last activity ID. The next run starts again using `--initial-offset`. |

**Log files**

| Option | Default | Description |
|---|---|---|
| `--log-name PATTERN` | `%Y%m%d.log` | Daily file name. strftime codes are filled in when logs are written. Must end in `.log`. |
| `--retention DAYS` | `14` | Delete daily files older than this after each successful run. `0` keeps them forever. |

**Other**

| Option | Description |
|---|---|
| `--no-start` | Install and enable, but don't run the first collection now. The timer still starts about 1 minute later. |
| `-y`, `--yes` | Don't ask; use the defaults plus whatever options you passed |
| `--uninstall` | Remove the service, timer, collector and config. **Keeps** logs, state and the service account. |
| `--purge` | Use with `--uninstall`: also delete logs, state and the service account |
| `-h`, `--help` | Show help |

### What gets installed

| Path | Owner / mode | Purpose |
|---|---|---|
| `/usr/bin/ninja-collector` | root, 0755, **immutable** (`chattr +i`) | The collector |
| `/etc/ninjaone/ninjaone.env` | root, 0600 | API credentials. systemd passes a copy to the service (`LoadCredential`), so the service account never reads this file itself. |
| `/etc/ninjaone/collector.conf` | root, 0644 | Collector settings (`NINJA_*` variables) |
| `/var/lib/ninjaone/` | `ninjaone`, 0750 | Saved last activity ID and lock file |
| `/var/log/ninjaone/` | `ninjaone`, 0750 | Daily log files |
| `/etc/systemd/system/ninjaone-collector.service` | root | Runs the collector once (hardened) |
| `/etc/systemd/system/ninjaone-collector.timer` | root | Runs the service every `--interval` |
| `/opt/ninjaone/venv/` | root | Only created if `python3-requests` couldn't be installed with apt |

The `ninjaone` service account is a system account with no home folder, a `nologin` shell and a locked password.

The service is locked down: it can only write to `/var/lib/ninjaone` and `/var/log/ninjaone`, can only open network connections, and gets no extra privileges.

> **SIEM agent access:** the log folder is `0750 ninjaone:ninjaone`. If your SIEM agent runs as a different user, add that user to the group (`sudo usermod -aG ninjaone <agent-user>`) and restart the agent.

### Common tasks

```bash
# Change how often it runs
sudo ./install_ninjaone_collector.sh -y --interval 15min

# Rotate the API secret: update .env, then re-run the installer
sudo ./install_ninjaone_collector.sh -y --env-file ./.env

# Run a collection right now
sudo systemctl start ninjaone-collector.service

# Pause / resume collection
sudo systemctl stop ninjaone-collector.timer
sudo systemctl start ninjaone-collector.timer

# Start over from the newest 50 activities
sudo ./install_ninjaone_collector.sh -y --reset-state --initial-offset 50

# Uninstall (keep logs + state) / remove everything
sudo ./install_ninjaone_collector.sh --uninstall
sudo ./install_ninjaone_collector.sh --uninstall --purge
```

To change settings without re-running the installer, edit `/etc/ninjaone/collector.conf`, then run `sudo systemctl restart ninjaone-collector.timer`. The service can only write inside `/var/lib/ninjaone` and `/var/log/ninjaone`, so keep log and state paths there.

---

## Collector

```
ninjaone_collector.py [options]
```

You can run the collector by hand for testing (`python ninjaone_collector.py -v`), or use the installed `/usr/bin/ninja-collector`. A command-line flag overrides its environment variable.

### Options

| Option | Env variable | Default | Description |
|---|---|---|---|
| `--env-file PATH` | | `.env` next to the script | File holding `CLIENT_ID` / `CLIENT_SECRET` |
| `--client-id ID` | `NINJA_CLIENT_ID` | from `.env` | Overrides `CLIENT_ID` from the `.env` file |
| `--secret-cmd CMD` | `NINJA_SECRET_CMD` | | Shell command that prints the secret (e.g. a vault lookup) |
| `--secret-file PATH` | `NINJA_SECRET_FILE` | | File containing only the secret |
| | `NINJA_CLIENT_SECRET` | | Secret as an environment variable |
| `--base-url URL` | `NINJA_BASE_URL` | `https://us2.ninjarmm.com` | NinjaOne instance URL |
| `--log-file PATH` | `NINJA_LOG_FILE` | `/var/log/ninjaone/%Y%m%d.log` | Log file path. strftime codes are filled in each time logs are written, so a new file starts every day. |
| `--state-file PATH` | `NINJA_STATE_FILE` | `/var/lib/ninjaone/last_activity_id` | Where the last collected activity ID is saved |
| `--page-size N` | `NINJA_PAGE_SIZE` | `500` | Activities per API call |
| `--max-pages N` | `NINJA_MAX_PAGES` | `200` | Maximum API calls per run (200 × 500 = 100,000 activities) |
| `--initial {latest,all}` | | `latest` | First run with no saved state: `latest` starts from the newest activity; `all` pulls the full history |
| `--initial-offset N` | `NINJA_INITIAL_OFFSET` | `0` (installer: `20`) | With `latest`, also collect the last N activities on the first run |
| `--add-iso` | `NINJA_ADD_ISO` | off | Add `activityTimeISO` (UTC, e.g. `2025-09-10T22:48:03.000Z`) to each line |
| `--interval SECONDS` | | `0` | Keep running and collect every N seconds. `0` runs once and exits (what the timer uses). |
| `-v`, `--verbose` | | off | Debug logging, including each HTTP request |

**Where the secret comes from**, first match wins: `CLIENT_SECRET` in `.env`, then `--secret-cmd`, then `NINJA_CLIENT_SECRET`, then `--secret-file`.

### Output format

One JSON object per line, sorted by `activityTime`, then `id`:

```json
{"id":450086,"activityTime":1757544483.0,"deviceId":107,"activityType":"NINJA_REMOTE","status":"Session terminated","activityResult":"SUCCESS","message":"NinjaOne Remote session terminated, session handle: 2727763341","type":"NinjaOne Remote","data":"@{message=}"}
```

### How collection works

1. Reads the last collected activity ID from the state file.
2. Requests activities newer than that ID. NinjaOne returns the newest page first, so if a full page comes back, it keeps paging back with `olderThan` until it reaches the saved ID. NinjaOne rejects `newerThan` and `olderThan` in the same request.
3. Checks again for anything that arrived while it was paging.
4. Sorts the batch, appends it to today's file, and flushes it to disk.
5. **Only then** saves the new highest ID. If a run fails at any step, the next run collects the same range again.

A lock file stops two runs from overlapping. If the backlog is bigger than `--max-pages × --page-size`, the run writes nothing and logs an error rather than skipping the missing range. Raise `NINJA_MAX_PAGES` to catch up.

> **Timestamps don't always follow ID order.** NinjaOne sometimes gives a higher ID an earlier `activityTime`. Each batch is sorted, but an activity that arrives late can appear after entries with later timestamps from an earlier run.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No module named 'requests'` | Use the right Python: `python -m pip install requests` inside your venv. The installed service handles this itself. |
| `error: externally-managed-environment` while in a venv | The venv was created without pip. Run `sudo apt install python3-venv python3-full`, then `rm -rf .venv && python3 -m venv .venv`. |
| `systemd is not running` | On WSL, enable systemd (see [WSL](#wsl)). |
| `CLIENT_ID not found` | Check `.env` is next to the script, or pass `--env-file`. |
| `401` / auth errors | Wrong secret, or the app lacks the **Monitoring** scope or **Client Credentials** grant. |
| `HTTP 400 ... olderThan` | You're running an old version of the collector. Update `ninjaone_collector.py` and re-run the installer. |
| `Hit --max-pages` | Backlog too large for one run. Raise `NINJA_MAX_PAGES` in `/etc/ninjaone/collector.conf`, or start fresh with `--reset-state`. |
| `bash\r: No such file or directory` | Windows line endings: `sed -i 's/\r$//' install_ninjaone_collector.sh` |
| Can't replace `/usr/bin/ninja-collector` | It's immutable by design. Re-run the installer, or `sudo chattr -i /usr/bin/ninja-collector` first. |

Logs from the collector itself (not the activities) go to the journal:

```bash
journalctl -u ninjaone-collector.service --since today
```
