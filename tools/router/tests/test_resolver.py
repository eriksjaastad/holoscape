"""Tests for ChannelResolver."""

from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from router import ChannelResolver, Channel


def make_channel(label="holoscape", id="abc-123", is_active=False, notification_type=None, state="running"):
    return Channel(id=id, label=label, type="shell", state=state, notification_type=notification_type, is_active=is_active)


class TestChannelResolver:
    def test_exact_match(self):
        resolver = ChannelResolver(aliases={})
        channels = [make_channel(label="ai-memory"), make_channel(label="holoscape")]
        result = resolver.resolve("holoscape", channels)
        assert result is not None
        assert result.label == "holoscape"

    def test_case_insensitive(self):
        resolver = ChannelResolver(aliases={})
        channels = [make_channel(label="AI-Memory")]
        result = resolver.resolve("ai-memory", channels)
        assert result is not None
        assert result.label == "AI-Memory"

    def test_alias_resolution(self):
        resolver = ChannelResolver(aliases={"architect": "projects"})
        channels = [make_channel(label="projects")]
        result = resolver.resolve("architect", channels)
        assert result is not None
        assert result.label == "projects"

    def test_partial_match(self):
        resolver = ChannelResolver(aliases={})
        channels = [make_channel(label="ai-memory 2")]
        result = resolver.resolve("ai-memory", channels)
        assert result is not None

    def test_no_match_returns_none(self):
        resolver = ChannelResolver(aliases={})
        channels = [make_channel(label="holoscape")]
        result = resolver.resolve("nonexistent", channels)
        assert result is None

    def test_foreground_detection(self):
        resolver = ChannelResolver(aliases={})
        ch = make_channel(label="holoscape", is_active=True)
        channels = [ch]
        result = resolver.resolve("holoscape", channels)
        assert result is not None
        assert result.is_active is True
