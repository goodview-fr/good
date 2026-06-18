#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
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


class TestResolveConflicts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("resolve_conflicts", os.path.join(PY, "resolve_conflicts.py"))
        cls.markers = load_module("conflict_markers", os.path.join(PY, "conflict_markers.py"))

    def test_list_conflict_files_empty_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
            self.assertEqual(self.mod.list_conflict_files(tmp), [])

    def test_resolve_no_conflicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
            ok, msg = self.mod.resolve_all(tmp, lambda p: "")
            self.assertTrue(ok)
            self.assertIn("Aucun conflit", msg)


class TestToolArgs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = load_module("tools", os.path.join(PY, "tools.py"))

    def test_normalize_run_git_list(self):
        n = self.tools.normalize_tool_args
        self.assertEqual(n("run_git", ["add", "-A"]), {"args": ["add", "-A"]})

    def test_format_tool_args_list(self):
        s = self.tools.format_tool_args(["status", "-s"])
        self.assertIn("status", s)

    def test_normalize_read_file_list(self):
        n = self.tools.normalize_tool_args
        self.assertEqual(n("read_file", ["src/main.py"]), {"path": "src/main.py"})


class TestClassifyIntent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module("classify_intent", os.path.join(PY, "classify_intent.py"))

    def test_git_intent(self):
        self.assertEqual(self.mod.classify("committe et pousse"), "git")
        self.assertEqual(self.mod.classify("résous les conflits"), "git")

    def test_start_intent(self):
        self.assertEqual(self.mod.classify("lance le projet"), "start")

    def test_diagnose_intent(self):
        self.assertEqual(self.mod.classify("connection refused sur le port 8000"), "diagnose")

    def test_edit_intent(self):
        self.assertEqual(self.mod.classify("modifier routes/api.php"), "edit")

    def test_deploy_intent(self):
        self.assertEqual(self.mod.classify("déploie en production"), "deploy")
        self.assertEqual(self.mod.classify("mise en prod clever cloud"), "deploy")

    def test_search_intent(self):
        self.assertEqual(self.mod.classify("cherche sur le web la doc Laravel"), "search")

    def test_start_before_edit(self):
        self.assertEqual(self.mod.classify("lance le projet et modifie routes"), "start")

    def test_diagnose_before_edit(self):
        self.assertEqual(self.mod.classify("connection refused port 8000"), "diagnose")

    def test_is_file_action_excludes_explain(self):
        self.assertFalse(self.mod.is_file_action("explique le projet"))
        self.assertFalse(self.mod.is_file_action("comment fonctionne routes/api.php"))

    def test_is_file_action_detects_edit(self):
        self.assertTrue(self.mod.is_file_action("modifie routes/api.php"))
        self.assertTrue(self.mod.is_file_action("ajoute un fichier test.py"))


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
