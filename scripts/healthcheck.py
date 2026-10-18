#!/usr/bin/env python3
"""Independent PPSV operator alerts; never depends on the Shiny app or SQLite outbox."""

import fcntl
import json
import os
from pathlib import Path
import shutil
import smtplib
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
from email.message import EmailMessage


def command_output(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=8, check=False)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def collect_issues(settings, now=None):
    now = time.time() if now is None else now
    issues = {}
    data_root = Path(settings["PPSV_DATA_ROOT"])
    db_file = Path(settings["PPSV_DB_FILE"])
    pool_root = Path(settings["PPSV_POOL_ROOT"])
    fallback_root = Path(settings["PPSV_FALLBACK_ROOT"])
    backup_dir = Path(settings["PPSV_BACKUP_DIR"])

    if not db_file.is_file():
        issues["database"] = "SQLite database is missing."
    else:
        try:
            connection = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True, timeout=3)
            try:
                if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    issues["database"] = "SQLite quick_check failed."
                elif connection.execute("SELECT count(*) FROM mail_outbox WHERE status='failed'").fetchone()[0]:
                    issues["mail_outbox"] = "At least one ticket, acknowledgement, or acceptance message has a delivery failure."
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if "request_files" in tables:
                    missing = 0
                    for (stored_path,) in connection.execute(
                        "SELECT absolute_path FROM request_files WHERE archived_at IS NULL"
                    ):
                        if not stored_path or not Path(stored_path).is_file():
                            missing += 1
                            if missing >= 5:
                                break
                    if missing:
                        issues["project_files"] = "At least one active project file is missing from its recorded storage path."
            finally:
                connection.close()
        except (sqlite3.Error, OSError) as error:
            issues["database"] = f"SQLite cannot be read: {error.__class__.__name__}."

    actual_source = command_output("findmnt", "-n", "-o", "SOURCE", "-T", str(pool_root))
    expected_source = settings.get("PPSV_POOL_EXPECTED_SOURCE", "")
    if (not pool_root.is_dir() or pool_root.is_symlink() or not expected_source
            or expected_source.startswith("REQUIRED") or actual_source != expected_source
            or not os.access(pool_root, os.W_OK)):
        issues["pool"] = "Facility project pool is unavailable or its mount source changed; uploads must use the local fallback."
    if not fallback_root.is_dir() or fallback_root.is_symlink() or not os.access(fallback_root, os.W_OK):
        issues["fallback"] = "Local fallback upload directory is unavailable or not writable; submissions with files cannot be accepted."

    db_backups = list((backup_dir / "database").glob("ppsv_projects_*.sqlite"))
    recent = [path for path in db_backups if path.is_file() and not path.is_symlink()
              and -300 <= now - path.stat().st_mtime <= 8 * 86400]
    if not recent:
        issues["backup"] = "No verified database backup file is newer than eight days."
    else:
        latest = max(recent, key=lambda path: path.stat().st_mtime)
        stamp = latest.name.removeprefix("ppsv_projects_").removesuffix(".sqlite")
        companion = backup_dir / "fallback" / f"uploads_pending_pool_{stamp}.tar.gz"
        if not latest.with_name(latest.name + ".sha256").is_file() or not companion.is_file() or not companion.with_name(companion.name + ".sha256").is_file():
            issues["backup"] = "The latest database backup has no complete matching fallback archive and checksum files."

    if command_output("systemctl", "is-active", "shiny-server.service") != "active":
        issues["shiny"] = "Shiny Server is not active."
    if command_output("systemctl", "is-active", "apache2.service") != "active":
        issues["apache"] = "Apache is not active."
    if command_output("systemctl", "is-active", "ppsv-mail-outbox.timer") != "active":
        issues["mail_timer"] = "Ticket mail retry timer is not active."
    if command_output("systemctl", "is-active", "ppsv-backup.timer") != "active":
        issues["backup_timer"] = "Weekly backup timer is not active."
    if command_output("systemctl", "is-failed", "ppsv-backup.service") == "failed":
        issues["backup_job"] = "The most recent weekly backup service run failed."
    if command_output("systemctl", "is-failed", "ppsv-mail-outbox.service") == "failed":
        issues["mail_worker"] = "The ticket mail worker service failed."
    if not data_root.is_dir():
        issues["data_root"] = "Persistent application data root is missing."
    else:
        try:
            usage = shutil.disk_usage(data_root)
            if usage.free < 1024**3 or usage.free / usage.total < 0.05:
                issues["disk_space"] = "Persistent data filesystem has less than 1 GiB or 5% free space."
        except OSError:
            issues["disk_space"] = "Persistent data filesystem capacity cannot be read."
    return issues


def send_alert(settings, subject, body):
    recipient = settings.get("PPSV_ALERT_TO", "").strip()
    host = settings.get("PPSV_SMTP_HOST", "").strip()
    sender = settings.get("PPSV_MAIL_FROM", "").strip()
    if not recipient or not host or not sender:
        raise ValueError("PPSV_ALERT_TO, PPSV_SMTP_HOST and PPSV_MAIL_FROM are required for operator alerts")
    message = EmailMessage()
    message["From"] = sender
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(body)
    port = int(settings.get("PPSV_SMTP_PORT", "25"))
    security = settings.get("PPSV_SMTP_SECURITY", "none").lower()
    if security not in ("none", "ssl", "starttls"):
        raise ValueError("Invalid PPSV_SMTP_SECURITY")
    client_type = smtplib.SMTP_SSL if security == "ssl" else smtplib.SMTP
    kwargs = {"timeout": 10}
    if security == "ssl":
        kwargs["context"] = ssl.create_default_context()
    with client_type(host, port, **kwargs) as client:
        if security == "starttls":
            client.starttls(context=ssl.create_default_context())
        username = settings.get("PPSV_SMTP_USER", "")
        if username:
            client.login(username, settings.get("PPSV_SMTP_PASSWORD", ""))
        client.send_message(message)


def run(settings):
    data_root = Path(settings["PPSV_DATA_ROOT"])
    if not data_root.is_dir() or data_root.is_symlink():
        send_alert(settings, "PPSV operator alert: data root unavailable",
                   "The PPSV persistent data root is missing or unsafe. Check the VM immediately.\n")
        return 1
    state_dir = data_root / "alerts"
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state_dir.is_symlink():
        raise OSError("Alert state directory must not be a symbolic link")
    os.chmod(state_dir, 0o700)
    with (state_dir / "healthcheck.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state_file = state_dir / "last-state.json"
        if state_file.is_symlink():
            raise OSError("Alert state file must not be a symbolic link")
        try:
            previous = json.loads(state_file.read_text())
        except FileNotFoundError:
            previous = {}
        current = collect_issues(settings)
        if current == previous:
            return 0
        new = sorted(set(current) - set(previous))
        resolved = sorted(set(previous) - set(current))
        changed = sorted(key for key in set(current) & set(previous) if current[key] != previous[key])
        lines = ["PPSV health state changed on ppcf-vm.biochem.mpg.de.", ""]
        lines.extend(f"NEW {key}: {current[key]}" for key in new)
        lines.extend(f"CHANGED {key}: {current[key]}" for key in changed)
        lines.extend(f"RESOLVED {key}" for key in resolved)
        if not lines[2:]:
            return 0
        send_alert(settings, "PPSV operator alert: health state changed", "\n".join(lines) + "\n")
        fd, temporary = tempfile.mkstemp(prefix=".last-state.", dir=state_dir)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(current, stream, sort_keys=True)
            os.chmod(temporary, 0o600)
            os.replace(temporary, state_file)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(run(os.environ))
    except Exception as error:
        print(f"[PPSV] health alert failed: {error}", file=sys.stderr)
        sys.exit(1)
