"""Regression checks for public defaults and synthetic fixture hygiene.

Only synthetic expectations are stored here. No private data or database access.
"""
import ast
from decimal import Decimal
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WaveOnePrivacyTests(unittest.TestCase):
    def test_receipt_loaders_use_generic_default_user(self):
        files = (
            "scripts/load_receipts.py",
            "scripts/legacy/generate_sql.py",
            "scripts/legacy/populate_db.py",
        )
        for name in files:
            with self.subTest(script=name):
                tree = ast.parse((ROOT / name).read_text(encoding="utf-8"))
                if name == "scripts/load_receipts.py":
                    defaults = [
                        node.value.value
                        for node in ast.walk(tree)
                        if isinstance(node, ast.Assign)
                        and any(isinstance(t, ast.Name) and t.id == "DEFAULT_USER_NAME"
                                for t in node.targets)
                        and isinstance(node.value, ast.Constant)
                    ]
                    self.assertEqual(defaults, ["default_user"])
                else:
                    statements = [
                        node.value for node in ast.walk(tree)
                        if isinstance(node, ast.Constant)
                        and isinstance(node.value, str)
                        and "INSERT INTO users" in node.value
                    ]
                    self.assertEqual(len(statements), 1)
                    self.assertRegex(
                        statements[0],
                        r"VALUES\s*\(\s*'[^']+'\s*,\s*'default_user'\s*,",
                    )


    def test_receipt_fixture_is_entirely_synthetic_and_reconciled(self):
        fixture = json.loads((ROOT / "fixtures/nfce_exemplo.json").read_text())
        self.assertEqual(fixture["emitente"]["nome"], "Supermercado Teste Ltda")
        self.assertEqual(fixture["emitente"]["cnpj"], "00.000.000/0001-00")
        self.assertEqual(fixture["emitente"]["municipio"], "Municipio Ficticio")
        self.assertEqual(fixture["chave_acesso"], "0" * 44)
        self.assertEqual(fixture["consumidor"], {"cpf": "0" * 11})
        self.assertEqual(fixture["nota"]["numero"], "1")
        self.assertEqual(fixture["nota"]["serie"], "1")
        self.assertEqual(fixture["nota"]["emissao"], "2000-01-01T00:00:00-03:00")
        self.assertEqual(fixture["nota"]["forma_pagamento"], "PAGAMENTO FICTICIO")
        items = fixture["itens"]
        self.assertEqual(len(items), 3)
        self.assertEqual([item["descricao"] for item in items],
                         ["ITEM FICTICIO A", "ITEM FICTICIO B", "ITEM FICTICIO C"])
        self.assertEqual([item["codigo"] for item in items],
                         ["TESTE-A", "TESTE-B", "TESTE-C"])
        self.assertEqual(fixture["nota"]["itens_total"], len(items))
        self.assertEqual([item["linha"] for item in items], list(range(1, len(items) + 1)))
        total = Decimal("0")
        for item in items:
            with self.subTest(line=item["linha"]):
                self.assertTrue(item["descricao"].startswith("ITEM FICTICIO "))
                self.assertTrue(item["codigo"].startswith("TESTE-"))
                line_total = Decimal(item["total"])
                self.assertEqual(
                    (Decimal(item["quantidade"]) * Decimal(item["valor_unitario"])).quantize(Decimal("0.01")),
                    line_total,
                )
                total += line_total
        self.assertEqual(total, Decimal(str(fixture["nota"]["valor_total"])))


    def test_local_exports_and_build_outputs_are_ignored(self):
        ignored = (
            "backups/local.sql", "dumps/local.sql", "receipt-imports/local.sql",
            "local.dump", "local.backup", "local.sql.gz", "local.sql.bz2", "local.sql.xz",
            "build/output.txt", "dist/output.txt", "htmlcov/index.html",
            ".coverage", ".coverage.test", ".env", "api/.env.local",
        )
        visible = (".env.example", "api/.env.example", "db/001_schema.sql",
                   "seeds/categories.sql", "fixtures/synthetic.json", "tests/test_wave1_privacy.py")
        for paths, expected in ((ignored, 0), (visible, 1)):
            for name in paths:
                with self.subTest(path=name):
                    result = subprocess.run(
                        ["git", "check-ignore", "--no-index", "-q", "--", name],
                        cwd=ROOT, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, expected)


    def test_environment_example_declares_empty_secret_fields(self):
        text = (ROOT / ".env.example").read_text(encoding="utf-8")
        values = {}
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            self.assertNotIn(key, values, "duplicate environment key")
            values[key] = value.strip()
        for key in ("DB_PASSWORD", "SECRET_KEY", "JWT_SECRET_KEY", "AUTH_PEPPER",
                    "SEFAZ_CSC_POR_LOJA", "SENTRY_DSN"):
            with self.subTest(variable=key):
                self.assertIn(key, values)
                self.assertEqual(values.get(key), "")


if __name__ == "__main__":
    unittest.main()
