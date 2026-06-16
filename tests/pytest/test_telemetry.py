#!/usr/bin/env python3
"""Tests for telemetry module."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest


def load_telemetry():
    path = os.path.join(os.path.dirname(__file__), "..", "..", "lib", "py", "telemetry.py")
    spec = importlib.util.spec_from_file_location("telemetry", os.path.abspath(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestTelemetry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = load_telemetry()

    def test_append_and_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            activity = os.path.join(tmp, "activity.jsonl")
            ev = self.t.append_event(activity, "commit", "ok", 100, tmp, {"ai_used": True})
            self.assertTrue(os.path.isfile(activity))
            events = self.t.load_events(activity)
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["id"], ev["id"])
            self.assertFalse(events[0]["synced"])

    def test_aggregate_stats(self):
        events = [
            {"cmd": "commit", "status": "ok", "ts": "2026-06-16T10:00:00+00:00",
             "developer_email": "a@test.com", "developer_name": "Alice",
             "meta": {"ai_used": True}, "duration_ms": 100},
            {"cmd": "push", "status": "ok", "ts": "2026-06-16T11:00:00+00:00",
             "developer_email": "a@test.com", "developer_name": "Alice",
             "meta": {}, "duration_ms": 50},
        ]
        agg = self.t.aggregate_stats(events)
        self.assertEqual(agg["total_events"], 2)
        self.assertEqual(agg["by_cmd"]["commit"], 1)
        self.assertEqual(agg["ai_commits"], 1)

    def test_mark_synced(self):
        with tempfile.TemporaryDirectory() as tmp:
            activity = os.path.join(tmp, "activity.jsonl")
            ev = self.t.append_event(activity, "commit", "ok", 10, tmp)
            self.t.mark_synced(activity, [ev["id"]])
            events = self.t.load_events(activity)
            self.assertTrue(events[0]["synced"])

    def test_compute_health_score(self):
        with tempfile.TemporaryDirectory() as tmp:
            health = self.t.compute_health(tmp, tmp)
            self.assertIn("score", health)
            self.assertIn("level", health)
            self.assertGreaterEqual(health["score"], 0)


if __name__ == "__main__":
    unittest.main()
