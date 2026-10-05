#!/usr/bin/env python3
"""
NinjaOne activity log collector.

- Authenticates with client_credentials (scope=monitoring)
- Pulls /v2/activities newer than the last collected activity ID
- Pages until no new activities remain
- Sorts ascending by activityTime (then id) so newest lines land at the bottom
- Appends one JSON object per line to a daily log file (default
  /var/log/ninjaone/YYYYMMDD.log; the path accepts strftime codes)
- Saves the highest collected activity ID to a state file ONLY after the
  log write has been flushed to disk, so a failed run is simply retried
  on the next run without skipping or duplicating logs.

Credentials are read from a .env file in the same folder as this script:
    CLIENT_ID=...
    CLIENT_SECRET=...

Run from cron / systemd timer, or with --interval to loop as a daemon.
Requires: Python 3.8+, `requests`  (pip install requests)
"""

import argparse
import fcntl
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

import requests

# ----------------------------------------------------------------------------
# Defaults (override with CLI flags or environment variables)
# ----------------------------------------------------------------------------
# The log file path may contain strftime codes; they are expanded (local time)
# each time activities are written, so a new file starts every day.
DEFAULT_BASE_URL = os.environ.get("NINJA_BASE_URL", "https://us2.ninjarmm.com")
DEFAULT_LOG_FILE = os.environ.get("NINJA_LOG_FILE", "/var/log/ninjaone/%Y%m%d.log")
DEFAULT_STATE_FILE = os.environ.get("NINJA_STATE_FILE", "/var/lib/ninjaone/last_activity_id")
DEFAULT_PAGE_SIZE = int(os.environ.get("NINJA_PAGE_SIZE", "500"))
DEFAULT_MAX_PAGES = int(os.environ.get("NINJA_MAX_PAGES", "200"))
REQUEST_TIMEOUT = 30
MAX_RETRIES = 5

log = logging.getLogger("ninja_collector")


# ----------------------------------------------------------------------------
# Credentials
# ----------------------------------------------------------------------------
def app_dir():
    """Folder containing this script (or the binary, if frozen with PyInstaller)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.realpath(sys.executable))
    return os.path.dirname(os.path.realpath(__file__))


def load_env_file(path):
    """
    Minimal .env parser (no extra dependency). Supports:
      KEY=value, KEY="value", KEY='value', `export KEY=value`, # comments.
    Returns a dict; does not modify os.environ.
    """
    values = {}
    if not os.path.isfile(path):
        return values

    mode = os.stat(path).st_mode
    if mode & 0o007:
        log.warning("%s is accessible by other users; consider: chmod 600 %s", path, path)

    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            if "=" not in line:
                log.warning("%s:%d ignored (no '=')", path, lineno)
                continue
            key, value = line.split("=", 1)
            key, value = key.strip(), value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            elif " #" in value:
                value = value.split(" #", 1)[0].rstrip()   # inline comment
            values[key] = value
    return values


def get_client_secret(args):
    """
    Secret sources, in priority order:
      1. CLIENT_SECRET from the .env file next to this script
      2. --secret-cmd : a shell command whose stdout is the secret
      3. NINJA_CLIENT_SECRET environment variable
      4. --secret-file : file containing the plain secret
    """
    if args.env.get("CLIENT_SECRET"):
        return args.env["CLIENT_SECRET"]
    if args.secret_cmd:
        out = subprocess.run(args.secret_cmd, shell=True, check=True,
                             capture_output=True, text=True)
        return out.stdout.strip()
    if os.environ.get("NINJA_CLIENT_SECRET"):
        return os.environ["NINJA_CLIENT_SECRET"]
    if args.secret_file:
        with open(args.secret_file) as fh:
            return fh.read().strip()
    raise SystemExit("No client secret provided (use --secret-cmd, "
                     "NINJA_CLIENT_SECRET, or --secret-file).")


# ----------------------------------------------------------------------------
# API client
# ----------------------------------------------------------------------------
class NinjaClient:
    def __init__(self, base_url, client_id, client_secret, scope="monitoring"):
        self.base_url = base_url.rstrip("/")
        self.client_id = client_id
        self.client_secret = client_secret
        self.scope = scope
        self.session = requests.Session()
        self._token = None
        self._token_expiry = 0.0

    def _authenticate(self):
        resp = self.session.post(
            f"{self.base_url}/ws/oauth/token",
            data={
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "grant_type": "client_credentials",
                "scope": self.scope,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=REQUEST_TIMEOUT,
        )
        resp.raise_for_status()
        body = resp.json()
        self._token = body["access_token"]
        # refresh 60s early to avoid using a token that expires mid-request
        self._token_expiry = time.time() + int(body.get("expires_in", 3600)) - 60
        log.debug("Obtained new auth token (expires in %ss)", body.get("expires_in"))

    def _token_valid(self):
        return self._token and time.time() < self._token_expiry

    def get(self, path, params):
        """GET with auth refresh, 429 / 5xx backoff."""
        for attempt in range(1, MAX_RETRIES + 1):
            if not self._token_valid():
                self._authenticate()
            try:
                resp = self.session.get(
                    f"{self.base_url}{path}",
                    params=params,
                    headers={"Accept": "application/json",
                             "Authorization": f"Bearer {self._token}"},
                    timeout=REQUEST_TIMEOUT,
                )
            except requests.RequestException as exc:
                wait = min(2 ** attempt, 60)
                log.warning("Request error (%s), retry %d/%d in %ss",
                            exc, attempt, MAX_RETRIES, wait)
                time.sleep(wait)
                continue

            if resp.status_code == 401:
                log.info("401 received, refreshing token")
                self._token = None
                continue
            if resp.status_code == 429 or resp.status_code >= 500:
                wait = int(resp.headers.get("Retry-After", min(2 ** attempt, 60)))
                log.warning("HTTP %s, retry %d/%d in %ss",
                            resp.status_code, attempt, MAX_RETRIES, wait)
                time.sleep(wait)
                continue
            if resp.status_code >= 400:
                log.error("HTTP %s from %s: %s", resp.status_code, resp.url, resp.text[:500])
            resp.raise_for_status()
            return resp.json()
        raise RuntimeError(f"GET {path} failed after {MAX_RETRIES} attempts")

    def activities(self, **params):
        body = self.get("/v2/activities", {k: v for k, v in params.items() if v is not None})
        return body.get("lastActivityId"), body.get("activities", []) or []


# ----------------------------------------------------------------------------
# State handling
# ----------------------------------------------------------------------------
def read_state(path):
    try:
        with open(path) as fh:
            value = fh.read().strip()
            return int(value) if value else None
    except FileNotFoundError:
        return None


def write_state(path, activity_id):
    """Atomic write: temp file + fsync + rename."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".state.")
    with os.fdopen(fd, "w") as fh:
        fh.write(f"{activity_id}\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


# ----------------------------------------------------------------------------
# Collection
# ----------------------------------------------------------------------------
class GapNotFilled(RuntimeError):
    pass


def collect_new(client, last_id, page_size, max_pages):
    """
    Return every activity with id > last_id, de-duplicated.

    NinjaOne returns the NEWEST `pageSize` activities first and rejects
    newerThan + olderThan in the same request (HTTP 400). So when more than a
    page is waiting, we page backwards with olderThan alone until we reach
    last_id, then repeat with newerThan=<highest seen> to pick up anything
    that arrived while we were paging.

    If max_pages is hit before reaching last_id, we raise instead of writing:
    advancing the bookmark past an unfilled gap would lose those activities.
    """
    found = {}
    pages = 0

    def fetch(**params):
        nonlocal pages
        if pages >= max_pages:
            raise GapNotFilled(
                f"Hit --max-pages={max_pages} ({max_pages * page_size} activities) before "
                f"catching up to id {last_id}; nothing written. Raise --max-pages "
                f"(NINJA_MAX_PAGES) or lower the backlog with --initial-offset.")
        pages += 1
        _, items = client.activities(pageSize=page_size, **params)
        return items

    floor = last_id
    while True:
        items = fetch(newerThan=floor)
        new = [a for a in items if a.get("id") is not None and a["id"] > floor]
        if not new:
            break
        for a in new:
            found[a["id"]] = a

        # Full page -> there may be more between `floor` and the lowest id seen
        lowest = min(a["id"] for a in new)
        while len(items) >= page_size and lowest > floor + 1:
            items = fetch(olderThan=lowest)
            older = [a for a in items if a.get("id") is not None and a["id"] > floor]
            for a in older:
                found[a["id"]] = a
            if not older or len(older) < len(items):
                break                          # reached the bookmark
            new_lowest = min(a["id"] for a in older)
            if new_lowest >= lowest:
                break                          # no progress; avoid looping
            lowest = new_lowest

        floor = max(found)                     # look for anything newer still

    log.debug("Collected %d activities in %d API calls", len(found), pages)
    return list(found.values())


def sort_key(activity):
    return (float(activity.get("activityTime") or 0), activity.get("id") or 0)


def resolve_log_path(template, when=None):
    """Expand strftime codes (e.g. %Y%m%d) in the log path using local time."""
    return (when or datetime.now()).strftime(template)


def write_activities(path, activities, add_iso):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        for a in activities:
            if add_iso and a.get("activityTime") is not None:
                a = dict(a)
                a["activityTimeISO"] = datetime.fromtimestamp(
                    float(a["activityTime"]), tz=timezone.utc
                ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            fh.write(json.dumps(a, separators=(",", ":"), ensure_ascii=False) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def run_once(client, args):
    last_id = read_state(args.state_file)

    if last_id is None:
        if args.initial == "all":
            log.info("No state file; collecting full history")
            last_id = 0
        else:
            # Bookmark (newest activity id - initial_offset) and collect from there.
            newest_id, items = client.activities(pageSize=1)
            newest_id = newest_id or (items[0]["id"] if items else 0)
            last_id = max(0, int(newest_id) - max(0, args.initial_offset))
            write_state(args.state_file, last_id)
            log.info("No state file; newest activity id is %s, starting after id %s "
                     "(initial offset %s)", newest_id, last_id, args.initial_offset)
            if last_id >= newest_id:
                return 0

    activities = collect_new(client, last_id, args.page_size, args.max_pages)
    if not activities:
        log.info("No new activities since id %s", last_id)
        return 0

    activities.sort(key=sort_key)
    new_last_id = max(a["id"] for a in activities)

    log_path = resolve_log_path(args.log_file)
    write_activities(log_path, activities, args.add_iso)
    write_state(args.state_file, new_last_id)   # only after successful write

    log.info("Wrote %d activities (ids %s..%s) to %s; last id now %s",
             len(activities), min(a["id"] for a in activities), new_last_id,
             log_path, new_last_id)
    return len(activities)


# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="Collect NinjaOne activity logs")
    p.add_argument("--base-url", default=DEFAULT_BASE_URL)
    p.add_argument("--env-file", default=os.path.join(app_dir(), ".env"),
                   help="Path to .env with CLIENT_ID / CLIENT_SECRET "
                        "(default: .env next to this script)")
    p.add_argument("--client-id", default=None,
                   help="Overrides CLIENT_ID from the .env file")
    p.add_argument("--secret-cmd", default=os.environ.get("NINJA_SECRET_CMD"),
                   help="Shell command that prints the client secret to stdout")
    p.add_argument("--secret-file", default=os.environ.get("NINJA_SECRET_FILE"))
    p.add_argument("--log-file", default=DEFAULT_LOG_FILE,
                   help="Log path; strftime codes are expanded per write, e.g. "
                        "/var/log/ninjaone/%%Y%%m%%d.log (the default)")
    p.add_argument("--state-file", default=DEFAULT_STATE_FILE)
    p.add_argument("--page-size", type=int, default=DEFAULT_PAGE_SIZE)
    p.add_argument("--max-pages", type=int, default=DEFAULT_MAX_PAGES,
                   help="Safety cap on API pages per run")
    p.add_argument("--initial", choices=["latest", "all"], default="latest",
                   help="First run with no state: 'latest' starts from the newest "
                        "activity (minus --initial-offset), 'all' pulls full history")
    p.add_argument("--initial-offset", type=int,
                   default=int(os.environ.get("NINJA_INITIAL_OFFSET", "0")),
                   help="With --initial latest: also collect this many activity IDs "
                        "back from the newest on the first run (e.g. 20)")
    p.add_argument("--add-iso", action="store_true",
                   default=os.environ.get("NINJA_ADD_ISO", "").lower() in ("1", "true", "yes"),
                   help="Add an activityTimeISO field (UTC) to each line")
    p.add_argument("--interval", type=int, default=0,
                   help="Seconds between runs; 0 = run once and exit")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    args.env = load_env_file(args.env_file)
    if args.env:
        log.debug("Loaded %d values from %s", len(args.env), args.env_file)
    args.client_id = (args.client_id or args.env.get("CLIENT_ID")
                      or os.environ.get("NINJA_CLIENT_ID"))
    if not args.client_id:
        raise SystemExit(f"CLIENT_ID not found in {args.env_file} "
                         "(or --client-id / NINJA_CLIENT_ID)")

    # Prevent overlapping runs (e.g. slow run + next cron tick)
    lock_path = args.state_file + ".lock"
    os.makedirs(os.path.dirname(os.path.abspath(lock_path)), exist_ok=True)
    lock_fh = open(lock_path, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.warning("Another collector instance is running; exiting")
        return 0

    client = NinjaClient(args.base_url, args.client_id, get_client_secret(args))

    while True:
        try:
            run_once(client, args)
        except GapNotFilled as exc:
            log.error("%s", exc)
            if not args.interval:
                return 1
        except Exception:
            log.exception("Collection run failed; state not advanced")
            if not args.interval:
                return 1
        if not args.interval:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())