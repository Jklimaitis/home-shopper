"""API security regressions using synthetic settings and a database stub.

HTTP calls exercise the ASGI application directly; no extra HTTP client dependency,
private .env, server socket or database is needed.
"""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import types
import unittest
from unittest.mock import patch

import bcrypt

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = {
    "JWT_SECRET_KEY": os.urandom(32).hex(),
    "AUTH_PEPPER": os.urandom(8).hex(),
}
USER_ID = "00000000-0000-4000-8000-000000000001"
OTHER_ID = "00000000-0000-4000-8000-000000000002"
PRODUCT_ID = "00000000-0000-4000-8000-000000000003"


def load_auth(overrides=None):
    settings = dict(SETTINGS)
    for key, value in (overrides or {}).items():
        if value is None:
            settings.pop(key, None)
        else:
            settings[key] = value
    spec = importlib.util.spec_from_file_location("hs_test_auth", ROOT / "api/auth.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, settings, clear=True):
        spec.loader.exec_module(module)
    return module


def load_app(auth):
    database = types.ModuleType("database")

    def forbidden_connection():
        raise AssertionError("Database access must be stubbed by the test")

    setattr(database, "get_connection", forbidden_connection)
    spec = importlib.util.spec_from_file_location("hs_test_main", ROOT / "api/main.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    with patch.dict("sys.modules", {"database": database, "auth": auth, "hs_test_main": module}):
        spec.loader.exec_module(module)
    return module


def request(app, method, path, body=None, token=None, raw_body=None, root_path=""):
    payload = raw_body if raw_body is not None else (
        json.dumps(body).encode() if body is not None else b""
    )
    headers = [(b"content-type", b"application/json")]
    if token is not None:
        headers.append((b"authorization", ("Bearer " + token).encode()))
    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": method, "scheme": "http", "path": path,
        "raw_path": path.encode(), "query_string": b"", "root_path": root_path,
        "headers": headers, "client": ("127.0.0.1", 12345), "server": ("testserver", 80),
    }
    messages = []

    async def invoke():
        sent = False

        async def receive():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": payload, "more_body": False}
            return {"type": "http.disconnect"}

        async def send(message):
            messages.append(message)

        await app(scope, receive, send)

    asyncio.run(invoke())
    status = next(m["status"] for m in messages if m["type"] == "http.response.start")
    content = b"".join(m.get("body", b"") for m in messages if m["type"] == "http.response.body")
    return status, json.loads(content) if content else None


class PasswordHashTests(unittest.TestCase):
    def test_short_and_unicode_passwords_hash_and_verify(self):
        auth = load_auth()
        for password in ("x", "short-test", "senha-curta-á"):
            with self.subTest(case_length=len(password)):
                try:
                    hashed = auth.hash_password(password)
                    valid = auth.verify_password(password, hashed)
                except ValueError:
                    self.fail("Password backend rejected a valid short synthetic password")
                self.assertTrue(hashed.startswith("$2b$"))
                self.assertTrue(valid)
                self.assertFalse(auth.verify_password(password + "different", hashed))

    def test_password_limit_counts_utf8_bytes_including_pepper(self):
        auth = load_auth()
        budget = 72 - len(auth.PEPPER.encode("utf-8"))
        boundary = "x" * budget
        stored = auth.hash_password(boundary)
        self.assertTrue(auth.verify_password(boundary, stored))
        for password in (boundary + "x", "á" * budget):
            with self.subTest(byte_length=len(password.encode("utf-8"))):
                with self.assertRaises(ValueError):
                    auth.hash_password(password)
                self.assertFalse(auth.verify_password(password, stored))

    def test_empty_password_is_not_hashed_or_accepted(self):
        auth = load_auth()
        with self.assertRaises(ValueError):
            auth.hash_password("")
        self.assertFalse(auth.verify_password("", "not-a-hash"))

    def test_non_ascii_or_missing_stored_hash_is_rejected(self):
        auth = load_auth()
        for stored in ("inválido", None):
            self.assertFalse(auth.verify_password("synthetic", stored))

    def test_same_password_has_independent_salts(self):
        auth = load_auth()
        try:
            first = auth.hash_password("synthetic-password")
            second = auth.hash_password("synthetic-password")
        except ValueError:
            self.fail("Password backend failed while generating independent salts")
        self.assertTrue(first != second)

    def test_existing_bcrypt_hashes_remain_compatible(self):
        auth = load_auth()
        for prefix in (b"2a", b"2b"):
            with self.subTest(prefix=prefix.decode()):
                encoded = ("legacy-synthetic" + SETTINGS["AUTH_PEPPER"]).encode()
                legacy = bcrypt.hashpw(encoded, bcrypt.gensalt(rounds=12, prefix=prefix)).decode()
                try:
                    accepted = auth.verify_password("legacy-synthetic", legacy)
                except ValueError:
                    self.fail("Password backend rejected a compatible bcrypt hash")
                self.assertTrue(accepted)

    def test_malformed_stored_hash_is_rejected_without_exception(self):
        auth = load_auth()
        try:
            accepted = auth.verify_password("synthetic", "not-a-password-hash")
        except ValueError:
            self.fail("Malformed stored hash escaped password verification")
        self.assertFalse(accepted)


class AuthenticationConfigurationTests(unittest.TestCase):
    def test_missing_empty_or_whitespace_settings_abort_import(self):
        for key in ("JWT_SECRET_KEY", "AUTH_PEPPER"):
            for value in (None, "", "   "):
                with self.subTest(variable=key, state="absent" if value is None else "blank"):
                    with self.assertRaises(RuntimeError):
                        load_auth({key: value})

    def test_short_signing_key_is_rejected(self):
        with self.assertRaises(RuntimeError):
            load_auth({"JWT_SECRET_KEY": os.urandom(8).hex()})

    def test_pepper_must_leave_room_for_password_bytes(self):
        with self.assertRaises(RuntimeError):
            load_auth({"AUTH_PEPPER": os.urandom(36).hex()})

    def test_config_errors_do_not_include_supplied_values(self):
        value = os.urandom(8).hex()
        with self.assertRaises(RuntimeError) as raised:
            load_auth({"JWT_SECRET_KEY": value})
        self.assertNotIn(value, str(raised.exception))

    def test_configured_values_are_preserved_not_normalized(self):
        padded = " " + SETTINGS["AUTH_PEPPER"] + " "
        self.assertEqual(load_auth({"AUTH_PEPPER": padded}).PEPPER, padded)


class FakeCursor:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.rowcount = 1
        self.row = {"id": PRODUCT_ID, "name": "synthetic-product", "brand": None, "base_unit": "UN"}
        self.users = [{"id": USER_ID, "email": "synthetic-owner@example.com"},
                      {"id": OTHER_ID, "email": "synthetic-other@example.com"}]

    def execute(self, query, params=None):
        if params is not None and not isinstance(params, (tuple, list, dict)):
            raise AssertionError("Database parameters must be a sequence or mapping, not a scalar")
        self.calls.append((query, params))

    def fetchone(self):
        return self.row

    def fetchall(self):
        query, params = self.calls[-1]
        if "FROM users" in query:
            return [row for row in self.users if not params or row["id"] == params[0]]
        return []

    def close(self):
        self.closed = True


class FakeConnection:
    def __init__(self):
        self.cur = FakeCursor()
        self.closed = False
        self.commits = 0

    def cursor(self):
        return self.cur

    def commit(self):
        self.commits += 1

    def rollback(self):
        pass

    def close(self):
        self.closed = True


class EndpointAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.auth = load_auth({"CATALOG_ADMIN_USER_IDS": USER_ID})
        self.main = load_app(self.auth)

    def test_mutations_and_user_listing_reject_anonymous_requests_before_database(self):
        endpoints = (("POST", "/products"), ("PUT", "/products/" + PRODUCT_ID),
                     ("DELETE", "/products/" + PRODUCT_ID), ("GET", "/users"))
        for method, path in endpoints:
            with self.subTest(method=method):
                with patch.object(self.main, "get_connection", return_value=FakeConnection()) as connect:
                    status, _ = request(self.main.app, method, path,
                                        {"name": "synthetic", "sale_unit": "UN"})
                    self.assertIn(status, (401, 403))
                    connect.assert_not_called()

    def test_invalid_bearer_is_rejected_before_database(self):
        with patch.object(self.main, "get_connection", return_value=FakeConnection()) as connect:
            status, _ = request(self.main.app, "GET", "/users", token="invalid-synthetic-token")
            self.assertEqual(status, 401)
            connect.assert_not_called()

    def test_authenticated_nonadmin_cannot_mutate_catalog(self):
        token = self.auth.create_access_token(OTHER_ID)
        for method, path in (("POST", "/products"), ("PUT", "/products/" + PRODUCT_ID),
                             ("DELETE", "/products/" + PRODUCT_ID)):
            with self.subTest(method=method):
                with patch.object(self.main, "get_connection", return_value=FakeConnection()) as connect:
                    status, _ = request(self.main.app, method, path,
                                        {"name": "synthetic", "sale_unit": "UN"}, token=token)
                    self.assertEqual(status, 403)
                    connect.assert_not_called()

    def test_explicit_admin_can_mutate_catalog(self):
        token = self.auth.create_access_token(USER_ID)
        for method, path, expected in (("POST", "/products", 201),
                                       ("PUT", "/products/" + PRODUCT_ID, 200),
                                       ("DELETE", "/products/" + PRODUCT_ID, 204)):
            with self.subTest(method=method):
                conn = FakeConnection()
                with patch.object(self.main, "get_connection", return_value=conn):
                    status, _ = request(self.main.app, method, path,
                                        {"name": "synthetic", "sale_unit": "UN"}, token=token)
                self.assertEqual(status, expected)
                self.assertEqual(conn.commits, 1)
                self.assertTrue(conn.closed and conn.cur.closed)

    def test_empty_admin_list_denies_authenticated_mutation(self):
        auth = load_auth()
        main = load_app(auth)
        with patch.object(main, "get_connection", return_value=FakeConnection()) as connect:
            status, _ = request(main.app, "POST", "/products",
                                {"name": "synthetic", "sale_unit": "UN"},
                                token=auth.create_access_token(USER_ID))
            self.assertEqual(status, 403)
            connect.assert_not_called()

    def test_user_listing_is_scoped_and_omits_email(self):
        conn = FakeConnection()
        with patch.object(self.main, "get_connection", return_value=conn):
            status, body = request(self.main.app, "GET", "/users",
                                   token=self.auth.create_access_token(USER_ID))
        self.assertEqual(status, 200)
        self.assertEqual(body, [{"id": USER_ID}])
        query, params = conn.cur.calls[-1]
        self.assertIn("WHERE id = %s", query)
        self.assertNotIn("email", query)
        self.assertEqual(params, (USER_ID,))
        self.assertTrue(conn.closed and conn.cur.closed)

    def test_user_listing_closes_resources_on_database_failure(self):
        import psycopg2
        conn = FakeConnection()
        with patch.object(conn.cur, "execute", side_effect=psycopg2.OperationalError()), \
                patch.object(self.main, "get_connection", return_value=conn):
            status, _ = request(self.main.app, "GET", "/users",
                                token=self.auth.create_access_token(USER_ID))
        self.assertEqual(status, 503)
        self.assertTrue(conn.closed and conn.cur.closed)

    def test_user_listing_closes_connection_when_cursor_creation_fails(self):
        import psycopg2
        conn = FakeConnection()
        with patch.object(conn, "cursor", side_effect=psycopg2.OperationalError()), \
                patch.object(self.main, "get_connection", return_value=conn):
            status, _ = request(self.main.app, "GET", "/users",
                                token=self.auth.create_access_token(USER_ID))
        self.assertEqual(status, 503)
        self.assertTrue(conn.closed)

    def test_openapi_exposes_auth_requirements(self):
        schema = self.main.app.openapi()
        for route, method in (("/products", "post"), ("/products/{product_id}", "put"),
                              ("/products/{product_id}", "delete"), ("/users", "get")):
            self.assertTrue(schema["paths"][route][method].get("security"))
        self.assertNotIn("email", schema["components"]["schemas"]["User"]["properties"])

    def test_public_catalog_reads_remain_available(self):
        for path in ("/products", "/categories", "/stores"):
            with self.subTest(route=path):
                with patch.object(self.main, "get_connection", return_value=FakeConnection()):
                    status, body = request(self.main.app, "GET", path)
                self.assertEqual(status, 200)
                self.assertEqual(body, [])

    def test_invalid_admin_configuration_is_fatal(self):
        with self.assertRaises(RuntimeError):
            load_auth({"CATALOG_ADMIN_USER_IDS": "not-a-uuid"})


class LoginPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.auth = load_auth()
        self.main = load_app(self.auth)
        self.password = os.urandom(8).hex()

    def assert_private_error(self, status, body, expected=422):
        self.assertEqual(status, expected)
        self.assertFalse(self.password in json.dumps(body), "Sensitive login input was echoed")
        self.assertNotIn("input", json.dumps(body))

    def test_missing_email_does_not_echo_password(self):
        with patch.object(self.main, "get_connection") as connect:
            status, body = request(self.main.app, "POST", "/login", {"password": self.password})
            self.assert_private_error(status, body)
            connect.assert_not_called()

    def test_bad_email_type_does_not_echo_password(self):
        status, body = request(self.main.app, "POST", "/login",
                               {"email": [], "password": self.password})
        self.assert_private_error(status, body)

    def test_bad_password_type_does_not_echo_nested_input(self):
        status, body = request(self.main.app, "POST", "/login",
                               {"email": "synthetic@example.com", "password": {"nested": self.password}})
        self.assert_private_error(status, body)

    def test_malformed_json_does_not_echo_password(self):
        raw = ('{"password":' + json.dumps(self.password) + ',').encode()
        status, body = request(self.main.app, "POST", "/login", raw_body=raw)
        self.assert_private_error(status, body)

    def test_validation_redaction_survives_application_root_path(self):
        status, body = request(self.main.app, "POST", "/login",
                               {"password": self.password}, root_path="/api")
        self.assert_private_error(status, body)

    def test_model_representation_hides_password(self):
        data = self.main.LoginRequest(email="synthetic@example.com", password=self.password)
        self.assertFalse(self.password in repr(data), "Login model representation included password")

    def test_http_400_login_error_is_redacted(self):
        from fastapi import HTTPException
        conn = FakeConnection()
        with patch.object(conn.cur, "execute", side_effect=HTTPException(
            status_code=400, detail={"password": self.password, "message": self.password},
        )), patch.object(self.main, "get_connection", return_value=conn):
            status, body = request(self.main.app, "POST", "/login",
                                   {"email": "synthetic@example.com", "password": self.password})
        self.assert_private_error(status, body, expected=400)
        self.assertTrue(conn.closed and conn.cur.closed)

    def test_empty_password_is_redacted_validation_error(self):
        with patch.object(self.main, "get_connection") as connect:
            status, body = request(self.main.app, "POST", "/login",
                                   {"email": "synthetic@example.com", "password": ""})
        self.assertEqual(status, 422)
        self.assertEqual(body, {"detail": "Dados de login invalidos"})
        connect.assert_not_called()

    def test_incorrect_credentials_return_generic_401(self):
        conn = FakeConnection()
        conn.cur.fetchone = lambda: None
        with patch.object(self.main, "get_connection", return_value=conn):
            status, body = request(self.main.app, "POST", "/login",
                                   {"email": "synthetic@example.com", "password": self.password})
        self.assertEqual(status, 401)
        self.assertFalse(self.password in json.dumps(body))
        self.assertTrue(conn.closed and conn.cur.closed)

    def test_http_422_login_exception_is_redacted(self):
        from fastapi import HTTPException
        conn = FakeConnection()
        with patch.object(conn.cur, "execute", side_effect=HTTPException(
            status_code=422, detail={"password": self.password},
        )), patch.object(self.main, "get_connection", return_value=conn):
            status, body = request(self.main.app, "POST", "/login",
                                   {"email": "synthetic@example.com", "password": self.password})
        self.assert_private_error(status, body)

    def test_actual_parent_mount_keeps_login_redaction(self):
        from fastapi import FastAPI
        parent = FastAPI()
        parent.mount("/api", self.main.app)
        status, body = request(parent, "POST", "/api/login", {"password": self.password})
        self.assert_private_error(status, body)

    def test_nonlogin_validation_response_keeps_standard_structure(self):
        auth = load_auth({"CATALOG_ADMIN_USER_IDS": USER_ID})
        main = load_app(auth)
        status, body = request(main.app, "POST", "/products", {"sale_unit": "UN"},
                               token=auth.create_access_token(USER_ID))
        self.assertEqual(status, 422)
        assert isinstance(body, dict)
        self.assertIsInstance(body["detail"], list)

    def test_nonlogin_http_error_keeps_existing_detail(self):
        auth = load_auth({"CATALOG_ADMIN_USER_IDS": USER_ID})
        main = load_app(auth)
        status, body = request(main.app, "POST", "/products",
                               {"name": "synthetic", "sale_unit": "invalid-unit"},
                               token=auth.create_access_token(USER_ID))
        self.assertEqual(status, 400)
        assert isinstance(body, dict)
        self.assertIn("Unidade", body["detail"])

    def test_valid_login_still_issues_access_and_refresh_tokens(self):
        conn = FakeConnection()
        stored = self.auth.hash_password(self.password)
        conn.cur.fetchone = lambda: (
            {"password_hash": stored} if "user_credentials" in conn.cur.calls[-1][0]
            else {"id": USER_ID, "email": "synthetic@example.com"}
        )
        with patch.object(self.main, "get_connection", return_value=conn):
            status, body = request(self.main.app, "POST", "/login",
                                   {"email": "synthetic@example.com", "password": self.password})
        self.assertEqual(status, 200)
        self.assertEqual(conn.cur.calls[0][1], ("synthetic@example.com",))
        assert isinstance(body, dict)
        self.assertEqual(self.auth.verify_access_token(body["access_token"]), USER_ID)
        self.assertEqual(self.auth.verify_refresh_token(body["refresh_token"]), USER_ID)
        self.assertFalse(self.password in json.dumps(body))
        self.assertTrue(conn.closed and conn.cur.closed)


class TokenValidationTests(unittest.TestCase):
    def test_signature_from_different_key_is_rejected(self):
        from fastapi import HTTPException
        auth = load_auth()
        other = load_auth({"JWT_SECRET_KEY": os.urandom(32).hex()})
        with self.assertRaises(HTTPException) as raised:
            auth.verify_access_token(other.create_access_token(USER_ID))
        self.assertEqual(raised.exception.status_code, 401)

    def test_unconfigured_signing_algorithm_is_rejected(self):
        from fastapi import HTTPException
        from jose import jwt
        auth = load_auth()
        payload = jwt.get_unverified_claims(auth.create_access_token(USER_ID))
        token = jwt.encode(payload, auth.SECRET_KEY, algorithm="HS384")
        with self.assertRaises(HTTPException) as raised:
            auth.verify_access_token(token)
        self.assertEqual(raised.exception.status_code, 401)

    def test_invalid_claim_types_are_rejected(self):
        from fastapi import HTTPException
        from jose import jwt
        auth = load_auth()
        for claim, value in (("sub", []), ("exp", None), ("exp", "not-a-timestamp")):
            with self.subTest(claim=claim, invalid_type=type(value).__name__):
                payload = jwt.get_unverified_claims(auth.create_access_token(USER_ID))
                payload[claim] = value
                token = jwt.encode(payload, auth.SECRET_KEY, algorithm=auth.ALGORITHM)
                with self.assertRaises(HTTPException) as raised:
                    auth.verify_access_token(token)
                self.assertEqual(raised.exception.status_code, 401)

    def test_refresh_verifier_rejects_access_token(self):
        from fastapi import HTTPException
        auth = load_auth()
        with self.assertRaises(HTTPException) as raised:
            auth.verify_refresh_token(auth.create_access_token(USER_ID))
        self.assertEqual(raised.exception.status_code, 401)

    def test_access_and_refresh_require_expiration_and_subject(self):
        from fastapi import HTTPException
        from jose import jwt
        auth = load_auth()
        for kind, create, verify in (
            ("access", auth.create_access_token, auth.verify_access_token),
            ("refresh", auth.create_refresh_token, auth.verify_refresh_token),
        ):
            for claim in ("exp", "sub"):
                with self.subTest(kind=kind, missing=claim):
                    payload = jwt.get_unverified_claims(create(USER_ID))
                    payload.pop(claim)
                    token = jwt.encode(payload, auth.SECRET_KEY, algorithm=auth.ALGORITHM)
                    try:
                        verify(token)
                    except HTTPException as exc:
                        self.assertEqual(exc.status_code, 401)
                    except KeyError:
                        self.fail("Missing claim caused an internal exception instead of 401")
                    else:
                        self.fail("Required token claim was not enforced")

    def test_non_uuid_subject_is_rejected(self):
        from fastapi import HTTPException
        auth = load_auth()
        for create, verify in ((auth.create_access_token, auth.verify_access_token),
                               (auth.create_refresh_token, auth.verify_refresh_token)):
            with self.assertRaises(HTTPException) as raised:
                verify(create("not-a-user-uuid"))
            self.assertEqual(raised.exception.status_code, 401)

    def test_expired_or_wrong_token_type_is_rejected(self):
        from fastapi import HTTPException
        from jose import jwt
        auth = load_auth()
        expired = jwt.encode({"sub": USER_ID, "exp": 1, "type": "access"},
                             auth.SECRET_KEY, algorithm=auth.ALGORITHM)
        for token in (expired, auth.create_refresh_token(USER_ID)):
            with self.assertRaises(HTTPException) as raised:
                auth.verify_access_token(token)
            self.assertEqual(raised.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main()
