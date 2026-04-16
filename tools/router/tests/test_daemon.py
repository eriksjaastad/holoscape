"""Tests for RouterDaemon lifecycle."""

import os
from pathlib import Path
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import RouterDaemon, LOCK_FILE


class TestDaemonLifecycle:
    def test_acquire_lock(self, tmp_path):
        lock = tmp_path / "router.lock"
        with patch("router.LOCK_FILE", lock):
            daemon = RouterDaemon()
            assert daemon.acquire_lock()
            assert lock.exists()
            assert lock.read_text().strip() == str(os.getpid())

    def test_stale_lock_cleared(self, tmp_path):
        lock = tmp_path / "router.lock"
        lock.write_text("999999\n")  # PID that doesn't exist
        with patch("router.LOCK_FILE", lock):
            daemon = RouterDaemon()
            assert daemon.acquire_lock()

    def test_active_lock_blocks(self, tmp_path):
        lock = tmp_path / "router.lock"
        lock.write_text(f"{os.getpid()}\n")  # Our own PID — looks "active"
        with patch("router.LOCK_FILE", lock):
            daemon = RouterDaemon()
            assert not daemon.acquire_lock()

    def test_release_lock(self, tmp_path):
        lock = tmp_path / "router.lock"
        lock.write_text(f"{os.getpid()}\n")
        with patch("router.LOCK_FILE", lock):
            daemon = RouterDaemon()
            daemon.release_lock()
            assert not lock.exists()

    def test_watermark_set_on_init(self):
        from datetime import datetime
        daemon = RouterDaemon()
        daemon._set_watermark()
        assert daemon.watermark is not None
        # Verify it's a valid ISO-8601 timestamp
        parsed = datetime.fromisoformat(daemon.watermark)
        assert parsed.year >= 2026

    def test_signal_sets_running_false(self):
        daemon = RouterDaemon()
        daemon.running = True
        daemon._handle_signal(2, None)
        assert daemon.running is False
