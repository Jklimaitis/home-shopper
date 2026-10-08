"""The API must locate project configuration after relocation."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


class ApiEnvironmentLocationTests(unittest.TestCase):
    def test_database_loads_env_from_its_project_not_a_machine_path(self):
        source = Path(__file__).resolve().parents[1] / "api" / "database.py"
        with tempfile.TemporaryDirectory(prefix="hs-env-test-") as folder:
            project = Path(folder) / "relocated-project"
            api = project / "api"
            api.mkdir(parents=True)
            shutil.copyfile(source, api / "database.py")
            (project / ".env").write_text(
                "HS_MIGRATION_ENV_LOCATION_TEST=relocated_project\n", encoding="utf-8"
            )
            env = dict(os.environ)
            env.pop("HS_MIGRATION_ENV_LOCATION_TEST", None)
            env["PYTHONPATH"] = str(api)
            code = (
                "import database, os; "
                "raise SystemExit(0 if os.environ.get('HS_MIGRATION_ENV_LOCATION_TEST') "
                "== 'relocated_project' else 7)"
            )
            result = subprocess.run(
                [sys.executable, "-c", code], cwd=folder, env=env,
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, "project-relative .env was not loaded")


if __name__ == "__main__":
    unittest.main()
