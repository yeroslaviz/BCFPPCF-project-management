"""Dependency-free checks for PPSV operator notification behavior."""

import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "healthcheck.py"
SPEC = importlib.util.spec_from_file_location("ppsv_healthcheck", SCRIPT)
healthcheck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(healthcheck)


class HealthcheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings = {
            "PPSV_DATA_ROOT": str(self.root),
            "PPSV_DB_FILE": str(self.root / "database" / "ppsv_projects.db"),
            "PPSV_POOL_ROOT": str(self.root / "pool"),
            "PPSV_POOL_EXPECTED_SOURCE": "server:/pool",
            "PPSV_FALLBACK_ROOT": str(self.root / "uploads_pending_pool"),
            "PPSV_BACKUP_DIR": str(self.root / "db-backups"),
            "PPSV_ALERT_TO": "omicsdesk@biochem.mpg.de",
            "PPSV_MAIL_FROM": "ppsv-service@biochem.mpg.de",
            "PPSV_SMTP_HOST": "msx.biochem.mpg.de",
            "PPSV_SMTP_PORT": "25",
            "PPSV_SMTP_SECURITY": "none",
            "PPSV_SMTP_USER": "",
            "PPSV_SMTP_PASSWORD": "",
        }

    def test_detects_pool_backup_and_failed_mail(self):
        (self.root / "database").mkdir()
        (self.root / "uploads_pending_pool").mkdir()
        with sqlite3.connect(self.settings["PPSV_DB_FILE"]) as connection:
            connection.execute("CREATE TABLE mail_outbox(status TEXT)")
            connection.execute("INSERT INTO mail_outbox VALUES ('failed')")
        with patch.object(healthcheck, "command_output", return_value="active"):
            issues = healthcheck.collect_issues(self.settings)
        self.assertIn("pool", issues)
        self.assertIn("backup", issues)
        self.assertIn("mail_outbox", issues)
        self.assertNotIn("database", issues)

    def test_local_backup_is_healthy_only_with_matching_archive(self):
        (self.root / "database").mkdir()
        (self.root / "pool").mkdir()
        (self.root / "uploads_pending_pool").mkdir()
        db_backup = self.root / "db-backups" / "database" / "ppsv_projects_20261018T000000Z.sqlite"
        db_backup.parent.mkdir(parents=True)
        db_backup.touch()
        db_backup.with_name(db_backup.name + ".sha256").touch()
        fallback = self.root / "db-backups" / "fallback" / "uploads_pending_pool_20261018T000000Z.tar.gz"
        fallback.parent.mkdir()
        fallback.touch()
        fallback.with_name(fallback.name + ".sha256").touch()
        with sqlite3.connect(self.settings["PPSV_DB_FILE"]) as connection:
            connection.execute("CREATE TABLE mail_outbox(status TEXT)")

        def output(*args):
            if args[0] == "findmnt":
                return "server:/pool"
            return "active" if args[1] == "is-active" else ""

        with patch.object(healthcheck, "command_output", side_effect=output):
            issues = healthcheck.collect_issues(self.settings, now=time.time())
        self.assertEqual(issues, {})

    def test_missing_project_file_is_reported(self):
        (self.root / "database").mkdir()
        (self.root / "uploads_pending_pool").mkdir()
        with sqlite3.connect(self.settings["PPSV_DB_FILE"]) as connection:
            connection.execute("CREATE TABLE mail_outbox(status TEXT)")
            connection.execute("CREATE TABLE request_files(absolute_path TEXT, archived_at TEXT)")
            connection.execute(
                "INSERT INTO request_files VALUES (?, NULL)",
                (str(self.root / "missing-file.dat"),),
            )
        with patch.object(healthcheck, "command_output", return_value="active"):
            issues = healthcheck.collect_issues(self.settings)
        self.assertIn("project_files", issues)

    def test_notifications_are_sent_only_on_change_and_recovery(self):
        with patch.object(healthcheck, "send_alert") as send:
            with patch.object(healthcheck, "collect_issues", return_value={"pool": "unavailable"}):
                self.assertEqual(healthcheck.run(self.settings), 0)
                self.assertEqual(healthcheck.run(self.settings), 0)
            with patch.object(healthcheck, "collect_issues", return_value={}):
                self.assertEqual(healthcheck.run(self.settings), 0)
        self.assertEqual(send.call_count, 2)
        self.assertIn("NEW pool", send.call_args_list[0].args[2])
        self.assertIn("RESOLVED pool", send.call_args_list[1].args[2])

    def test_failed_send_remains_pending_for_next_check(self):
        with patch.object(healthcheck, "collect_issues", return_value={"backup": "overdue"}):
            with patch.object(healthcheck, "send_alert", side_effect=OSError("relay down")):
                with self.assertRaises(OSError):
                    healthcheck.run(self.settings)
            with patch.object(healthcheck, "send_alert") as send:
                healthcheck.run(self.settings)
        send.assert_called_once()

    def test_anonymous_smtp_uses_no_login(self):
        class Relay:
            def __init__(self, host, port, timeout):
                self.host, self.port, self.timeout = host, port, timeout
                self.message = None

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def login(self, *_):
                raise AssertionError("Anonymous SMTP must not authenticate")

            def starttls(self):
                raise AssertionError("Plain port-25 SMTP must not start TLS")

            def send_message(self, message):
                self.message = message

        with patch.object(healthcheck.smtplib, "SMTP", Relay):
            healthcheck.send_alert(self.settings, "Pool alert", "Pool unavailable")


if __name__ == "__main__":
    unittest.main()
