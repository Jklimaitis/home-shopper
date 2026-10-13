"""Regressões das rotas de staging (fila de revisão), em duas camadas.

Camada 1 (ASGI, banco stubado): autenticação, escopo por titular e o 404 que não
vaza a existência de recibo alheio -- a lição do achado ING-01.

Camada 2 (integração, banco descartável): as consultas de verdade. Aqui a função
da rota é chamada direto, com `database.get_connection` apontando para o banco
descartável, então o SQL exercitado é o mesmo que roda em produção -- não uma
cópia escrita no teste.

Dados sintéticos apenas.
"""
import asyncio
import importlib.util
import json
import os
import sys
import types
import unittest
import uuid
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import psycopg2
from psycopg2.extras import RealDictCursor

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = {"JWT_SECRET_KEY": os.urandom(32).hex(), "AUTH_PEPPER": os.urandom(8).hex()}
USER_ID = "00000000-0000-4000-8000-000000000001"
OTHER_ID = "00000000-0000-4000-8000-000000000002"
RECEIPT_ID = "00000000-0000-4000-8000-000000000003"


def load_auth():
    spec = importlib.util.spec_from_file_location("hs_staging_auth", ROOT / "api/auth.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, SETTINGS, clear=True):
        spec.loader.exec_module(module)
    return module


class FakeCursor:
    """Cursor que responde por conteúdo do SQL e registra o que recebeu."""

    def __init__(self, recorder):
        self.recorder = recorder
        self._rows = []
        self._last_sql = ""

    def execute(self, sql, params=None):
        self._last_sql = sql
        self.recorder.calls.append((sql, params))
        if "v_review_queue" in sql:
            self._rows = self.recorder.queue_rows
        elif "FROM staging_receipts" in sql:          # a checagem de dono
            self._rows = self.recorder.receipt_rows
        else:                                          # as linhas do recibo
            self._rows = self.recorder.line_rows

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return list(self._rows)

    def close(self):
        pass


class FakeConnection:
    def __init__(self, recorder):
        self.recorder = recorder

    def cursor(self):
        return FakeCursor(self.recorder)

    def close(self):
        pass


class Recorder:
    """Estado que o stub devolve, por rota.

    As linhas são dicionários, como o `RealDictCursor` de `api/database.py` entrega
    em produção -- não tuplas.

    `receipt_rows` vazio simula um recibo que não é do titular: a rota deve
    responder 404 e NÃO buscar as linhas.
    """

    def __init__(self, queue_rows=(), receipt_rows=(), line_rows=()):
        self.queue_rows = list(queue_rows)
        self.receipt_rows = list(receipt_rows)
        self.line_rows = list(line_rows)
        self.calls = []


def load_app(recorder):
    auth = load_auth()
    database = types.ModuleType("database")
    database.get_connection = lambda: FakeConnection(recorder)  # type: ignore[attr-defined]
    spec = importlib.util.spec_from_file_location("hs_staging_main", ROOT / "api/main.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"database": database, "auth": auth, "hs_staging_main": module}):
        spec.loader.exec_module(module)
    return module, auth


def request(module, method, path, token=None):
    """Dirige a aplicação ASGI diretamente (sem cliente HTTP, como o resto da suíte)."""
    headers = [(b"content-type", b"application/json")]
    if token is not None:
        headers.append((b"authorization", ("Bearer " + token).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method,
             "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"",
             "root_path": "", "headers": headers, "client": ("127.0.0.1", 12345),
             "server": ("testserver", 80)}
    messages = []

    async def invoke():
        sent = False

        async def receive():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": b"", "more_body": False}
            return {"type": "http.disconnect"}

        async def send(message):
            messages.append(message)

        await module.app(scope, receive, send)

    asyncio.run(invoke())
    status = next(m["status"] for m in messages if m["type"] == "http.response.start")
    content = b"".join(m.get("body", b"") for m in messages if m["type"] == "http.response.body")
    return status, (json.loads(content) if content else None)


class StagingRouteAccessTests(unittest.TestCase):
    """Camada ASGI: quem pode ver o quê."""

    def test_queue_requires_authentication(self):
        app, _ = load_app(Recorder())
        status, _ = request(app, "GET", "/staging/receipts")
        self.assertEqual(status, 401)

    def test_lines_require_authentication(self):
        app, _ = load_app(Recorder())
        status, _ = request(app, "GET", f"/staging/receipts/{RECEIPT_ID}/lines")
        self.assertEqual(status, 401)

    def test_queue_query_uses_the_callers_identity_as_a_parameter(self):
        # O escopo do titular tem de chegar ao banco como parâmetro, não como
        # filtro aplicado depois de ler.
        recorder = Recorder(queue_rows=[])
        app, auth = load_app(recorder)
        token = auth.create_access_token(USER_ID)
        status, body = request(app, "GET", "/staging/receipts", token=token)
        self.assertEqual(status, 200)
        self.assertEqual(body, [])
        consultas = [params for sql, params in recorder.calls if "v_review_queue" in sql]
        self.assertTrue(consultas, "a rota não consultou a fila")
        self.assertIn(USER_ID, consultas[0])

    def test_foreign_receipt_is_not_found_and_lines_are_not_read(self):
        # Recibo de outro titular: 404 (não 403, que confirmaria a existência) e a
        # segunda consulta não acontece -- nada do outro é lido.
        recorder = Recorder(receipt_rows=[], line_rows=[{"id": "linha-alheia"}])
        app, auth = load_app(recorder)
        token = auth.create_access_token(USER_ID)
        status, body = request(app, "GET", f"/staging/receipts/{RECEIPT_ID}/lines", token=token)
        self.assertEqual(status, 404)
        self.assertEqual(body, {"detail": "Recibo não encontrado"})
        self.assertEqual([sql for sql, _ in recorder.calls if "FROM staging_lines" in sql], [])


class StagingQueryIntegrationTests(unittest.TestCase):
    """Camada de integração: o SQL de verdade, contra banco descartável."""

    @classmethod
    def setUpClass(cls):
        cls.dsn = os.environ.get("HS_INGEST_TEST_DSN")
        if not cls.dsn:
            raise unittest.SkipTest("Disposable HS_INGEST_TEST_DSN required")
        conn = psycopg2.connect(cls.dsn)
        with conn.cursor() as cur:
            cur.execute("SELECT current_database()")
            row = cur.fetchone()
            assert row is not None
            if not row[0].startswith("hs_ingest_test_"):
                conn.close()
                raise RuntimeError("Refusing writes outside disposable database")
        conn.close()
        auth = load_auth()
        database = types.ModuleType("database")

        def get_connection():
            # Mesmo contrato do api/database.py de produção: linhas como dicionário.
            # Sem isso o teste exercitaria um cursor diferente do que a API usa.
            return psycopg2.connect(cls.dsn, cursor_factory=RealDictCursor)

        database.get_connection = get_connection  # type: ignore[attr-defined]
        spec = importlib.util.spec_from_file_location("hs_staging_main_db", ROOT / "api/main.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"database": database, "auth": auth, "hs_staging_main_db": module}):
            spec.loader.exec_module(module)
        cls.app = module
        cls.conn = psycopg2.connect(cls.dsn)

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.a, self.b = str(uuid.uuid4()), str(uuid.uuid4())
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("INSERT INTO users(id,name,email) VALUES(%s,%s,%s),(%s,%s,%s)",
                            (self.a, "A", self.a + "@example.invalid", self.b, "B", self.b + "@example.invalid"))
        self.receipt_a = self._receipt(self.a, lines=4)
        self.receipt_b = self._receipt(self.b, lines=1)

    def tearDown(self):
        self.conn.rollback()
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("DELETE FROM users WHERE id IN (%s,%s)", (self.a, self.b))

    def _receipt(self, user, lines):
        payload = {"header": {"store_cnpj": None, "total_gross": "10", "amount_paid": "10",
                              "issued_at": "2026-10-07"},
                   "items": [{"description_raw": f"ITEM {n}", "sale_unit": "UN", "quantity": "1",
                              "unit_price": "10", "line_total": "10"} for n in range(1, lines + 1)]}
        # A ingestão vive no script; aqui ela é usada só para semear linhas coerentes.
        spec = importlib.util.spec_from_file_location("hs_staging_ingest", ROOT / "scripts/ingest_receipt.py")
        assert spec is not None and spec.loader is not None
        ingest = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ingest)
        note = ingest.parse_note(payload)
        with self.conn:
            rid = ingest.insert_staging_receipt(self.conn, note, user, "IMPORT")
            ingest.insert_staging_lines(self.conn, rid, note["items"])
        return str(rid)

    def _state(self, receipt, state):
        """Leva a primeira linha PENDING do recibo para o estado pedido."""
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("""UPDATE staging_lines SET review_state = %s,
                                      reviewed = (%s IN ('CONFIRMED','NO_MATCH')),
                                      match_note = CASE WHEN %s = 'NO_MATCH' THEN '{"reason":"human_no_match"}' ELSE match_note END
                               WHERE id = (SELECT id FROM staging_lines
                                            WHERE receipt_id = %s AND review_state = 'PENDING'
                                            ORDER BY line_no LIMIT 1)""",
                            (state, state, state, receipt))

    def test_queue_lists_only_the_callers_receipts(self):
        ids_a = {row["staging_receipt_id"] for row in self.app.list_staging_receipts(user_id=self.a)}
        ids_b = {row["staging_receipt_id"] for row in self.app.list_staging_receipts(user_id=self.b)}
        # Controle positivo: cada recibo aparece na fila do SEU titular. Sem ele,
        # "B não está em A" passaria também se a consulta não devolvesse nada.
        self.assertIn(self.receipt_a, ids_a)
        self.assertIn(self.receipt_b, ids_b)
        self.assertNotIn(self.receipt_b, ids_a, "a fila de outro titular vazou")
        self.assertNotIn(self.receipt_a, ids_b, "a fila de outro titular vazou (inverso)")

    def test_discarded_lines_leave_the_progress_and_are_flagged(self):
        # `discarded` não é estado de revisão (o db/008 registra que ele é excluído
        # do cálculo do recibo): a linha sai da conta do progresso -- a mesma regra
        # que a view da fila usa -- e vem marcada na resposta, senão a tela não
        # distingue "fora da revisão" de "pendente".
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("""UPDATE staging_lines SET discarded = TRUE
                               WHERE id = (SELECT id FROM staging_lines WHERE receipt_id = %s
                                            ORDER BY line_no LIMIT 1)""", (self.receipt_a,))
        body = self.app.list_staging_lines(receipt_id=self.receipt_a, user_id=self.a)
        # `total` conta todas as linhas do recibo (como o `total_lines` da fila);
        # quem sai da conta da decisão é `in_review`.
        self.assertEqual(body["progress"]["total"], 4)
        self.assertEqual(body["progress"]["in_review"], 3)
        self.assertEqual(body["progress"]["discarded"], 1)
        self.assertTrue(body["lines"][0]["discarded"])

    def test_detail_counters_agree_with_the_queue_view(self):
        # A mesma grandeza medida em dois lugares tem de dar o mesmo número: a fila
        # (view do banco) e o detalhe (esta rota). Foi por uma regra diferente entre
        # os dois que uma divergência de contagem passou despercebida.
        self._state(self.receipt_a, "SKIPPED")
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("""UPDATE staging_lines SET discarded = TRUE
                               WHERE id = (SELECT id FROM staging_lines WHERE receipt_id = %s
                                            ORDER BY line_no DESC LIMIT 1)""", (self.receipt_a,))
        fila = next(row for row in self.app.list_staging_receipts(user_id=self.a)
                    if row["staging_receipt_id"] == self.receipt_a)
        progress = self.app.list_staging_lines(receipt_id=self.receipt_a, user_id=self.a)["progress"]
        self.assertEqual(progress["total"], fila["total_lines"])
        self.assertEqual(progress["pending"] + progress["skipped"], fila["lines_to_review"])
        self.assertEqual(progress["skipped"], fila["lines_skipped"])
        # Invariantes do detalhe, nas duas direções.
        self.assertEqual(progress["total"], progress["in_review"] + progress["discarded"])
        self.assertEqual(progress["in_review"],
                         progress["resolved"] + progress["pending"] + progress["skipped"])

    def test_queue_exposes_the_declared_date(self):
        rows = self.app.list_staging_receipts(user_id=self.a)
        alvo = next(row for row in rows if row["staging_receipt_id"] == self.receipt_a)
        self.assertEqual(alvo["issued_at"], date(2026, 10, 7))

    def test_foreign_receipt_raises_not_found(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as ctx:
            self.app.list_staging_lines(receipt_id=self.receipt_b, user_id=self.a)
        self.assertEqual(ctx.exception.status_code, 404)
        self.assertEqual(ctx.exception.detail, "Recibo não encontrado")

    def test_lines_and_progress_reflect_the_states(self):
        # Uma linha recusada (decisão) e uma pulada (deferral) entre as pendentes.
        # CONFIRMED não entra aqui: exige vínculo com produto, que é outro setup.
        self._state(self.receipt_a, "NO_MATCH")
        self._state(self.receipt_a, "SKIPPED")
        body = self.app.list_staging_lines(receipt_id=self.receipt_a, user_id=self.a)
        self.assertEqual(body["receipt_id"], self.receipt_a)
        progress = body["progress"]
        self.assertEqual(progress["total"], 4)
        self.assertEqual(progress["in_review"], 4)
        self.assertEqual(progress["resolved"], 1)
        self.assertEqual(progress["skipped"], 1)
        self.assertEqual(progress["pending"], 2)
        self.assertEqual(progress["discarded"], 0)
        self.assertEqual(progress["consolidated"], None)
        self.assertEqual(len(body["lines"]), 4)
        self.assertEqual(body["lines"][0]["line_no"], 1)

    def test_match_note_is_returned_raw_and_parsed(self):
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute("""UPDATE staging_lines SET match_note = '{"reason":"no_match"}'
                               WHERE id = (SELECT id FROM staging_lines WHERE receipt_id = %s
                                            ORDER BY line_no LIMIT 1)""", (self.receipt_a,))
        body = self.app.list_staging_lines(receipt_id=self.receipt_a, user_id=self.a)
        primeira = body["lines"][0]
        self.assertEqual(primeira["match_note"], '{"reason":"no_match"}')
        self.assertEqual(primeira["match_note_parsed"], {"reason": "no_match"})


if __name__ == "__main__":
    unittest.main()
