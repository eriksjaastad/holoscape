"""Tests for ResponseCapture."""

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import ResponseCapture


def mock_output_response(lines):
    data = json.dumps({"lines": lines, "channel": "test"}).encode()
    resp = MagicMock()
    resp.read.return_value = data
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


class TestResponseCapture:
    def test_captures_lines_as_joined_string(self):
        capture = ResponseCapture()
        with patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value = mock_output_response(["line 1", "line 2", "line 3"])
            result = capture.capture("chan-1")
        assert result == "line 1\nline 2\nline 3"

    def test_empty_lines_returns_empty_message(self):
        capture = ResponseCapture()
        with patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value = mock_output_response([])
            result = capture.capture("chan-1")
        assert result == "[Router: empty response]"

    def test_truncates_at_max_chars(self):
        capture = ResponseCapture()
        long_lines = ["x" * 1000] * 5  # 5000 chars total
        with patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value = mock_output_response(long_lines)
            result = capture.capture("chan-1", max_chars=100)
        assert len(result) < 200
        assert "[...truncated" in result

    def test_returns_error_on_connection_failure(self):
        import urllib.error
        capture = ResponseCapture()
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("refused")):
            result = capture.capture("chan-1")
        assert result == "[Router: failed to capture response]"
