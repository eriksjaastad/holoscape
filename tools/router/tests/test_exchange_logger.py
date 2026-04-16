"""Tests for ExchangeLogger."""

from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import ExchangeLogger


class TestExchangeLogger:
    def test_creates_log_file(self, tmp_path):
        log_file = tmp_path / "test.log"
        ExchangeLogger(path=log_file)
        # Logger is configured but file created on first write
        assert not log_file.exists() or log_file.stat().st_size == 0

    def test_exchange_writes_to_log(self, tmp_path):
        log_file = tmp_path / "test.log"
        logger = ExchangeLogger(path=log_file)
        logger.exchange("agent-a", "agent-b", "hello", "hi back", 1.5, "complete")
        content = log_file.read_text()
        assert "EXCHANGE" in content
        assert "agent-a" in content
        assert "agent-b" in content

    def test_bounce_writes_to_log(self, tmp_path):
        log_file = tmp_path / "test.log"
        logger = ExchangeLogger(path=log_file)
        logger.bounce("agent-a", "agent-b", "offline")
        content = log_file.read_text()
        assert "BOUNCE" in content
        assert "offline" in content

    def test_hold_writes_to_log(self, tmp_path):
        log_file = tmp_path / "test.log"
        logger = ExchangeLogger(path=log_file)
        logger.hold("agent-a", "agent-b", "foreground")
        content = log_file.read_text()
        assert "HOLD" in content

    def test_lifecycle_writes_to_log(self, tmp_path):
        log_file = tmp_path / "test.log"
        logger = ExchangeLogger(path=log_file)
        logger.lifecycle("Router started")
        content = log_file.read_text()
        assert "LIFECYCLE" in content
        assert "Router started" in content

    def test_error_writes_to_log(self, tmp_path):
        log_file = tmp_path / "test.log"
        logger = ExchangeLogger(path=log_file)
        logger.error("inject", "connection refused")
        content = log_file.read_text()
        assert "ERROR" in content
        assert "inject" in content
