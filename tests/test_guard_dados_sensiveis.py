"""Guard regression tests: scan index bytes, never unstaged/private files.

All identifier-shaped controls are deliberately synthetic and assembled in memory.
Each CLI case uses its own temporary Git repository, never the project index.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts/guard_dados_sensiveis.py"
CONTROL_KEY = "1" * 43 + "2"


class GuardIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="guard-index-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")

    def git(self, *args, input=None):
        return subprocess.run(
            ["git", *args], cwd=self.repo, input=input,
            capture_output=True, check=True,
        ).stdout

    def stage(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        self.git("add", "--", name)
        return path

    def guard(self, staged=True, repo=None):
        args = [sys.executable, "-B", str(GUARD), "--repo", str(repo or self.repo)]
        if staged:
            args.append("--staged")
        return subprocess.run(args, capture_output=True, text=True)

    def test_sensitive_index_is_blocked_even_when_disk_is_clean(self):
        path = self.stage("control.py", 'value = "' + CONTROL_KEY + '"\n')
        path.write_text("# clean unstaged copy\n")
        result = self.guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("control.py:1", result.stdout)

    def test_clean_index_ignores_sensitive_unstaged_copy(self):
        path = self.stage("control.py", "# clean staged copy\n")
        path.write_text('value = "' + CONTROL_KEY + '"\n')
        result = self.guard()
        self.assertEqual(result.returncode, 0)

    def test_missing_disk_file_does_not_hide_index_content(self):
        path = self.stage("control.py", 'value = "' + CONTROL_KEY + '"\n')
        path.unlink()
        self.assertEqual(self.guard().returncode, 1)

    def test_default_mode_uses_index_not_disk(self):
        path = self.stage("control.py", 'value = "' + CONTROL_KEY + '"\n')
        path.write_text("# clean unstaged copy\n")
        self.assertEqual(self.guard(staged=False).returncode, 1)


    def test_four_sensitive_formats_are_blocked(self):
        cpf = "1" * 10 + "2"
        formatted_cpf = cpf[:3] + "." + cpf[3:6] + "." + cpf[6:9] + "-" + cpf[9:]
        groups, offset = [], 0
        for width in (2, 4, 14, 2, 3, 9, 9, 1):
            groups.append(CONTROL_KEY[offset:offset + width])
            offset += width
        for index, value in enumerate((cpf, formatted_cpf, CONTROL_KEY, "-".join(groups))):
            with self.subTest(format=index):
                self.stage("formats.json", json.dumps({"control": value}))
                self.assertEqual(self.guard().returncode, 1)

    def test_zero_placeholders_and_public_cnpj_are_not_blocked(self):
        self.stage("synthetic.json", json.dumps({
            "cpf": "0" * 11, "key": "0" * 44, "cnpj": "00.000.000/0001-00",
        }))
        self.assertEqual(self.guard().returncode, 0)

    def test_untracked_and_ignored_private_files_do_not_enter_default_scan(self):
        self.stage("clean.py", "# synthetic clean data\n")
        (self.repo / ".env").write_text(CONTROL_KEY)
        (self.repo / "untracked.json").write_text(json.dumps({"control": CONTROL_KEY}))
        (self.repo / ".gitignore").write_text(".env\n")
        self.assertEqual(self.guard(staged=False).returncode, 0)

    def test_environment_example_is_not_exempt_from_personal_data_scan(self):
        self.stage(".env.example", "CONTROL=" + CONTROL_KEY)
        self.assertEqual(self.guard(staged=False).returncode, 1)

    def test_default_mode_scans_text_extensions_outside_legacy_allowlist(self):
        self.stage("control.csv", "control," + CONTROL_KEY)
        self.assertEqual(self.guard(staged=False).returncode, 1)

    def test_space_and_newline_filenames_are_handled_with_nul_separators(self):
        for name in ("space name.py", "line\nbreak.py"):
            with self.subTest(filename_kind="newline" if "\n" in name else "space"):
                path = self.stage(name, CONTROL_KEY)
                path.unlink()
                self.assertEqual(self.guard().returncode, 1)
                self.git("rm", "--cached", "--", name)

    def test_symlink_is_scanned_as_index_blob_not_target_file(self):
        (self.repo / "target.txt").write_text(CONTROL_KEY)
        os.symlink("target.txt", self.repo / "link.py")
        self.git("add", "--", "link.py")
        self.assertEqual(self.guard().returncode, 0)

    def test_git_worktree_and_subdirectory_are_supported(self):
        self.stage("clean.py", "# synthetic clean data\n")
        self.git("-c", "user.name=synthetic-test", "-c", "user.email=synthetic@example.com",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "synthetic baseline")
        worktree = self.repo / "linked"
        self.git("worktree", "add", "-q", "-b", "synthetic-branch", str(worktree))
        path = worktree / "control.py"
        path.write_text(CONTROL_KEY)
        subprocess.run(["git", "add", "--", "control.py"], cwd=worktree, check=True,
                       capture_output=True)
        path.write_text("# clean unstaged copy\n")
        nested = worktree / "nested"
        nested.mkdir()
        self.assertEqual(self.guard(repo=nested).returncode, 1)

    def test_staged_deletion_is_not_read_from_disk(self):
        self.stage("removed.py", CONTROL_KEY)
        self.git("-c", "user.name=synthetic-test", "-c", "user.email=synthetic@example.com",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "synthetic baseline")
        self.git("rm", "--cached", "--", "removed.py")
        self.assertEqual(self.guard().returncode, 0)

    def test_staged_rename_reads_destination_blob(self):
        self.stage("old.py", "# synthetic clean data\n")
        self.git("-c", "user.name=synthetic-test", "-c", "user.email=synthetic@example.com",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "synthetic baseline")
        self.git("mv", "old.py", "renamed.py")
        self.stage("renamed.py", CONTROL_KEY)
        (self.repo / "renamed.py").write_text("# clean unstaged copy\n")
        self.assertEqual(self.guard().returncode, 1)

    def test_invalid_utf8_fails_closed(self):
        (self.repo / "bad.py").write_bytes(b"\xff\xfe")
        self.git("add", "--", "bad.py")
        self.assertEqual(self.guard().returncode, 2)

    def test_unmerged_index_fails_closed(self):
        oid = self.git("hash-object", "-w", "--stdin", input=b"# synthetic content\n").strip()
        records = b"".join(b"100644 " + oid + b" " + str(stage).encode() + b"\tconflict.py\n"
                           for stage in (1, 2, 3))
        self.git("update-index", "--index-info", input=records)
        self.assertEqual(self.guard().returncode, 2)

    def test_empty_index_and_missing_repository(self):
        self.assertEqual(self.guard().returncode, 0)
        self.assertEqual(self.guard(staged=False).returncode, 0)
        self.assertEqual(self.guard(repo=self.repo / "missing").returncode, 2)

    def test_reports_do_not_echo_identifier_fragments(self):
        self.stage("control.py", CONTROL_KEY)
        result = self.guard()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(CONTROL_KEY, result.stdout)
        finding_line = next(line for line in result.stdout.splitlines() if "control.py:1" in line)
        self.assertNotIn("->", finding_line)
        self.assertNotIn(CONTROL_KEY[:4], finding_line)
        self.assertNotIn(CONTROL_KEY[-4:], finding_line)
        self.assertIn("valor omitido", result.stdout)


    def test_index_change_during_scan_fails_closed(self):
        self.stage("clean.py", "# synthetic clean data\n")
        spec = importlib.util.spec_from_file_location("guard_test_module", GUARD)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_git = module._git
        reads = 0

        def changed_snapshot(repo, *args):
            nonlocal reads
            value = real_git(repo, *args)
            if args[0] == "ls-files":
                reads += 1
                if reads > 1:
                    return value + b"\0"
            return value

        with patch.object(module, "_git", side_effect=changed_snapshot), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = module.main(["--repo", str(self.repo), "--staged"])
        self.assertEqual(result, 2)


    def test_sensitive_utf8_text_cannot_hide_under_binary_extension(self):
        self.stage("control.png", CONTROL_KEY)
        self.assertEqual(self.guard().returncode, 1)


    def synthetic_commit(self):
        self.git("-c", "user.name=synthetic-test", "-c", "user.email=synthetic@example.com",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "synthetic baseline")
        return self.git("rev-parse", "HEAD").decode().strip()

    def test_added_gitlink_is_skipped_consistently_in_both_modes(self):
        oid = self.synthetic_commit()
        self.git("update-index", "--add", "--cacheinfo", "160000," + oid + ",synthetic-module")
        self.assertEqual(self.guard(staged=False).returncode, 0)
        self.assertEqual(self.guard().returncode, 0)

    def test_modified_gitlink_is_skipped_consistently_in_both_modes(self):
        first = self.synthetic_commit()
        self.git("update-index", "--add", "--cacheinfo", "160000," + first + ",synthetic-module")
        second = self.synthetic_commit()
        self.git("update-index", "--cacheinfo", "160000," + second + ",synthetic-module")
        self.assertEqual(self.guard(staged=False).returncode, 0)
        self.assertEqual(self.guard().returncode, 0)


    def test_cpf_in_environment_example_is_blocked(self):
        self.stage(".env.example", "CONTROL=" + "1" * 10 + "2")
        self.assertEqual(self.guard(staged=False).returncode, 1)
        self.assertEqual(self.guard().returncode, 1)

    def test_formatted_zero_placeholders_are_allowed(self):
        cpf = "0" * 3 + "." + "0" * 3 + "." + "0" * 3 + "-" + "0" * 2
        fiscal = "-".join("0" * width for width in (2, 4, 14, 2, 3, 9, 9, 1))
        self.stage("zeros.json", json.dumps({"cpf": cpf, "fiscal": fiscal}))
        self.assertEqual(self.guard().returncode, 0)

    def test_recognized_binary_with_invalid_utf8_is_outside_text_scan(self):
        (self.repo / "synthetic.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00")
        self.git("add", "--", "synthetic.png")
        self.assertEqual(self.guard().returncode, 0)

    def load_guard_module(self):
        spec = importlib.util.spec_from_file_location("guard_failure_tests", GUARD)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_blob_read_failure_fails_closed_without_echoing_error_data(self):
        self.stage("clean.py", "# synthetic clean data\n")
        module = self.load_guard_module()
        real_git = module._git

        def unreadable_blob(repo, *args):
            if args[0] == "cat-file":
                raise subprocess.CalledProcessError(1, ["git", "cat-file"], stderr=CONTROL_KEY.encode())
            return real_git(repo, *args)

        out, err = io.StringIO(), io.StringIO()
        with patch.object(module, "_git", side_effect=unreadable_blob), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = module.main(["--repo", str(self.repo), "--staged"])
        self.assertEqual(result, 2)
        self.assertNotIn(CONTROL_KEY, out.getvalue() + err.getvalue())

    def test_unexpected_missing_index_entry_still_fails_closed(self):
        self.stage("clean.py", "# synthetic clean data\n")
        module = self.load_guard_module()
        snapshot = module._git(self.repo, "ls-files", "--stage", "-z")
        with patch.object(module, "indice_git", return_value=(snapshot, {}, set())), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = module.main(["--repo", str(self.repo), "--staged"])
        self.assertEqual(result, 2)


if __name__ == "__main__":
    unittest.main()
