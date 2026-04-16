"""Tests for MessageInjector."""

import json
import urllib.error
from pathlib import Path
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import MessageInjector, SAFETY_HEADER


class TestMessageInjector:
    def test_wraps_with_safety_header(self):
        injector = MessageInjector(api_url="http://localhost:9999")
        with patch("urllib.request.urlopen") as mock_open:
            mock_resp = MagicMock()
            mock_resp.status = 200
            mock_resp.__enter__ = MagicMock(return_value=mock_resp)
            mock_resp.__exit__ = MagicMock(return_value=False)
            mock_open.return_value = mock_resp

            injector.inject("chan-1", "agent-a", "do something")

            call_args = mock_open.call_args
            req = call_args[0][0]
            payload = json.loads(req.data)
            assert SAFETY_HEADER in payload["text"]
            assert "From: agent-a" in payload["text"]
            assert "do something" in payload["text"]

    def test_returns_false_on_failure(self):
        injector = MessageInjector(api_url="http://localhost:9999")
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("connection refused")):
            result = injector.inject("chan-1", "agent-a", "hello")
        assert result is False

    def test_posts_to_correct_endpoint(self):
        injector = MessageInjector(api_url="http://localhost:7865")
        with patch("urllib.request.urlopen") as mock_open:
            mock_resp = MagicMock()
            mock_resp.status = 200
            mock_resp.__enter__ = MagicMock(return_value=mock_resp)
            mock_resp.__exit__ = MagicMock(return_value=False)
            mock_open.return_value = mock_resp

            injector.inject("abc-123", "agent-a", "test")

            req = mock_open.call_args[0][0]
            assert req.full_url == "http://localhost:7865/channels/abc-123/input"
            assert req.method == "POST"
