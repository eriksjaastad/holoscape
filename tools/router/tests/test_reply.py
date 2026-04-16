"""Tests for ReplyRouter."""

from pathlib import Path
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import ReplyRouter, PT_CMD


class TestReplyRouter:
    def test_send_reply_calls_pt_message(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = ReplyRouter.send_reply("agent-a", "response text")
        assert result is True
        cmd = mock_run.call_args[0][0]
        assert cmd == [str(PT_CMD), "message", "send", "response text", "--to", "agent-a"]

    def test_send_reply_with_reply_to(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            ReplyRouter.send_reply("agent-a", "response", reply_to=5)
        cmd = mock_run.call_args[0][0]
        assert "--reply-to" in cmd
        assert "5" in cmd

    def test_send_bounce(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = ReplyRouter.send_bounce("agent-a", "agent-b", "offline")
        assert result is True
        body = mock_run.call_args[0][0][3]
        assert "bounced" in body
        assert "agent-b" in body

    def test_returns_false_on_failure(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1)
            result = ReplyRouter.send_reply("agent-a", "test")
        assert result is False
