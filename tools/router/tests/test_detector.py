"""Tests for ResponseDetector."""

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import ResponseDetector


def mock_channels_response(channel_id, notification_type=None):
    data = json.dumps([{"id": channel_id, "label": "test", "type": "shell", "state": "running", "notification_type": notification_type, "is_active": False}]).encode()
    resp = MagicMock()
    resp.read.return_value = data
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


class TestResponseDetector:
    def test_detects_idle_prompt(self):
        detector = ResponseDetector(timeout=10)
        with patch("urllib.request.urlopen") as mock_open, patch("time.sleep"):
            mock_open.return_value = mock_channels_response("chan-1", "idle_prompt")
            result = detector.wait_for_completion("chan-1")
        assert result == "complete"

    def test_timeout_when_no_idle(self):
        detector = ResponseDetector(timeout=3)
        with patch("urllib.request.urlopen") as mock_open, patch("time.sleep"), patch("time.monotonic") as mock_time:
            # Simulate time passing beyond timeout
            mock_time.side_effect = [0, 1, 2, 4]  # start, check, check, exceeds 3s
            mock_open.return_value = mock_channels_response("chan-1", None)
            result = detector.wait_for_completion("chan-1")
        assert result == "timeout"
