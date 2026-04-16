"""Tests for MessagePoller."""

import json
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import MessagePoller, Message


@pytest.fixture
def tmp_processed(tmp_path):
    return tmp_path / "processed_ids.json"


def make_pt_output(messages):
    return json.dumps({"messages": messages})


def sample_message(id=1, sender="agent-a", recipient="agent-b", body="hello", ts="2026-04-16T10:00:00Z"):
    return {"id": id, "sender": sender, "recipient": recipient, "body": body, "ts": ts, "priority": "normal", "reply_to": None, "metadata": {}}


class TestMessagePoller:
    def test_poll_returns_directed_messages(self, tmp_processed):
        poller = MessagePoller(processed_file=tmp_processed)
        msgs = [
            sample_message(id=1, recipient="agent-b"),
            sample_message(id=2, recipient=None),  # broadcast — skipped
            sample_message(id=3, recipient="agent-c"),
        ]
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=make_pt_output(msgs))
            result = poller.poll()
        assert len(result) == 2
        assert result[0].id == 1
        assert result[1].id == 3

    def test_poll_skips_processed(self, tmp_processed):
        tmp_processed.write_text(json.dumps({"ids": [1]}))
        poller = MessagePoller(processed_file=tmp_processed)
        msgs = [sample_message(id=1), sample_message(id=2)]
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=make_pt_output(msgs))
            result = poller.poll()
        assert len(result) == 1
        assert result[0].id == 2

    def test_mark_processed_persists(self, tmp_processed):
        poller = MessagePoller(processed_file=tmp_processed)
        poller.mark_processed(42)
        assert poller.is_processed(42)
        data = json.loads(tmp_processed.read_text())
        assert 42 in data["ids"]

    def test_poll_sorted_by_timestamp(self, tmp_processed):
        poller = MessagePoller(processed_file=tmp_processed)
        msgs = [
            sample_message(id=2, ts="2026-04-16T10:05:00Z"),
            sample_message(id=1, ts="2026-04-16T10:00:00Z"),
        ]
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=make_pt_output(msgs))
            result = poller.poll()
        assert result[0].id == 1
        assert result[1].id == 2

    def test_poll_handles_subprocess_failure(self, tmp_processed):
        poller = MessagePoller(processed_file=tmp_processed)
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            result = poller.poll()
        assert result == []

    def test_poll_handles_timeout(self, tmp_processed):
        poller = MessagePoller(processed_file=tmp_processed)
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("pt", 10)):
            result = poller.poll()
        assert result == []
