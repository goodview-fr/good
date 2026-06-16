#!/usr/bin/env python3
import importlib.util
import json
import os
import sys
import tempfile
import unittest


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PY = os.path.join(ROOT, "lib", "py")


class TestClassifyIntent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("classify_intent", os.path.join(PY, "classify_intent.py"))

    def test_start_intent(self):
        self.assertEqual(self.mod.classify("lance le projet"), "start")

    def test_diagnose_intent(self):
        self.assertEqual(self.mod.classify("connection refused sur le port 8000"), "diagnose")

    def test_edit_intent(self):
        self.assertEqual(self.mod.classify("modifier routes/api.php"), "edit")


class TestConflictMarkers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("conflict_markers", os.path.join(PY, "conflict_markers.py"))

    def test_detects_markers(self):
        content = "line\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> branch\n"
        self.assertTrue(self.mod.has_conflict_markers(content))

    def test_clean_content(self):
        self.assertFalse(self.mod.has_conflict_markers("hello\nworld\n"))


class TestValidateTask(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("validate_task", os.path.join(PY, "validate_task.py"))

    def test_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = json.dumps({"files": [{"path": "../etc/passwd", "action": "modify", "content": "x"}]})
            with self.assertRaises(SystemExit):
                self.mod.validate(tmp, payload)

    def test_accepts_valid_modify(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "foo.txt")
            with open(path, "w") as f:
                f.write("old")
            payload = json.dumps({"files": [{"path": "foo.txt", "action": "modify", "content": "new"}]})
            result = self.mod.validate(tmp, payload)
            self.assertEqual(result["files"][0]["content"], "new")


class TestConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("config", os.path.join(PY, "config.py"))

    def test_invalid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("{invalid")
            path = f.name
        try:
            val, code = self.mod.load_value(path, "token")
            self.assertEqual(code, 2)
        finally:
            os.unlink(path)

    def test_reads_key(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"token": "abc"}, f)
            path = f.name
        try:
            val, code = self.mod.load_value(path, "token")
            self.assertEqual(val, "abc")
            self.assertEqual(code, 0)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
