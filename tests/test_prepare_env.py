#!/usr/bin/env python3
"""
Testes de `scripts/prepare_env.py`.

Rodam sem Docker e sem segredo real: cada caso cria um repositorio git
temporario com o modelo `.env.example` e chama `prepare_env.main()`.

    python -m unittest discover -s tests -p 'test_*.py'
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import prepare_env  # noqa: E402  (precisa do sys.path acima)

MODELO = """\
# modelo de teste -- espelha .env.example nas chaves obrigatorias
DB_HOST=localhost
DB_PORT=5432
DB_NAME=home_shopper
DB_USER=home_shopper
DB_PASSWORD=troque-esta-senha
SEFAZ_CSC_POR_LOJA=
SECRET_KEY=gere-com-openssl-rand-base64-32
LOG_LEVEL=INFO
"""

SENHA_REAL = "senha-local-do-teste"


def rodar(repo: Path, *args: str) -> tuple[int, str, str]:
    """Chama main() capturando stdout/stderr."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        codigo = prepare_env.main(["--repo", str(repo), *args])
    return codigo, out.getvalue(), err.getvalue()


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


class BaseWorktree(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="prepare_env_")
        self.repo = Path(self._tmp.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".env.example").write_text(MODELO, encoding="utf-8")
        self.ignorar(".env")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def ignorar(self, padrao: str) -> None:
        (self.repo / ".gitignore").write_text(padrao + "\n", encoding="utf-8")

    def env(self) -> Path:
        return self.repo / ".env"


class Preparacao(BaseWorktree):
    def test_cria_env_byte_a_byte_e_reprova_sem_senha(self):
        codigo, out, _ = rodar(self.repo)
        self.assertEqual(codigo, 1, "sem DB_PASSWORD o ambiente nao esta pronto")
        self.assertTrue(self.env().exists(), ".env deveria ter sido criado")
        self.assertEqual(
            self.env().read_bytes(), (self.repo / ".env.example").read_bytes(),
            ".env tem que nascer igual ao modelo -- nenhum segredo inventado",
        )
        self.assertIn("STATUS: pendente", out)
        self.assertIn("openssl rand -base64 32", out, "guia de DB_PASSWORD acionavel")

    def test_nao_imprime_valor_de_variavel(self):
        self.env().write_text(f"DB_PASSWORD={SENHA_REAL}\n", encoding="utf-8")
        codigo, out, err = rodar(self.repo)
        self.assertEqual(codigo, 0)
        for stream in (out, err):
            self.assertNotIn(SENHA_REAL, stream)
            self.assertNotIn("troque-esta-senha", stream)

    def test_execucoes_repetidas_preservam_o_env(self):
        self.env().write_text(f"DB_PASSWORD={SENHA_REAL}\n", encoding="utf-8")
        antes = sha256(self.env())
        for _ in range(3):
            codigo, out, _ = rodar(self.repo)
            self.assertEqual(codigo, 0)
            self.assertIn("preservado sem alteracao", out)
        self.assertEqual(sha256(self.env()), antes, ".env nao pode mudar entre execucoes")

    def test_check_nao_escreve_nada(self):
        codigo, out, _ = rodar(self.repo, "--check")
        self.assertEqual(codigo, 1, "--check reprova ambiente nao preparado")
        self.assertFalse(self.env().exists(), "--check nao pode criar arquivo")
        self.assertIn("nada foi escrito", out)

    def test_pronto_quando_a_obrigatoria_esta_definida(self):
        self.env().write_text(
            f"DB_PASSWORD={SENHA_REAL}\nSEFAZ_CSC_POR_LOJA=\n"
            "SECRET_KEY=gere-com-openssl-rand-base64-32\n",
            encoding="utf-8",
        )
        codigo, out, _ = rodar(self.repo)
        self.assertEqual(codigo, 0)
        self.assertIn("STATUS: pronto", out)
        self.assertIn("SECRET_KEY", out, "pendencia de fase seguinte continua visivel")

    def test_roda_de_subdiretorio_e_acha_a_raiz(self):
        sub = self.repo / "db"
        sub.mkdir()
        codigo, out, _ = rodar(sub)
        self.assertEqual(codigo, 1)
        self.assertTrue(self.env().exists(), ".env pertence a raiz do worktree")
        self.assertIn(str(self.repo), out)


class Recusas(BaseWorktree):
    def test_recusa_env_versionado(self):
        self.env().write_text(f"DB_PASSWORD={SENHA_REAL}\n", encoding="utf-8")
        subprocess.run(["git", "add", "-f", ".env"], cwd=self.repo, check=True)
        codigo, _, err = rodar(self.repo)
        self.assertEqual(codigo, 2)
        self.assertIn("versionado", err)

    def test_recusa_env_fora_do_gitignore(self):
        self.ignorar("__pycache__/")
        codigo, _, err = rodar(self.repo)
        self.assertEqual(codigo, 2)
        self.assertIn("nao esta ignorado", err)
        self.assertFalse(self.env().exists(), "sem garantia de ignore, nao escreve")

    def test_recusa_env_como_symlink(self):
        alvo = self.repo / "outro-worktree.env"
        alvo.write_text(f"DB_PASSWORD={SENHA_REAL}\n", encoding="utf-8")
        os.symlink(alvo, self.env())
        codigo, _, err = rodar(self.repo)
        self.assertEqual(codigo, 2)
        self.assertIn("symlink", err)
        self.assertIn("nao e suportado", err)

    def test_recusa_fora_de_repositorio_git(self):
        # o TMPDIR desta sessao vive dentro de um repo; o ceiling impede o git
        # de subir ate ele, entao o diretorio fica de fato fora de qualquer repo
        with tempfile.TemporaryDirectory(prefix="nao_git_") as fora:
            (Path(fora) / ".env.example").write_text(MODELO, encoding="utf-8")
            anterior = os.environ.get("GIT_CEILING_DIRECTORIES")
            os.environ["GIT_CEILING_DIRECTORIES"] = str(Path(fora).parent)
            try:
                codigo, _, err = rodar(Path(fora))
            finally:
                if anterior is None:
                    os.environ.pop("GIT_CEILING_DIRECTORIES", None)
                else:
                    os.environ["GIT_CEILING_DIRECTORIES"] = anterior
        self.assertEqual(codigo, 2)
        self.assertIn("nao e um worktree git", err)

    def test_recusa_caminho_inexistente(self):
        codigo, _, err = rodar(self.repo / "nao-existe")
        self.assertEqual(codigo, 2)
        self.assertIn("nao existe", err)


class SenhaObrigatoria(BaseWorktree):
    """O caso "senha obrigatoria nao configurada": vazia ou no valor do modelo."""

    def test_senha_vazia_conta_como_pendente(self):
        self.env().write_text("DB_PASSWORD=\n", encoding="utf-8")
        antes = sha256(self.env())
        codigo, out, _ = rodar(self.repo)
        self.assertEqual(codigo, 1, "senha vazia nao configura o ambiente")
        self.assertIn("PENDENTE", out)
        self.assertIn("openssl rand -base64 32", out)
        self.assertEqual(sha256(self.env()), antes, ".env existente nao pode mudar")

    def test_valor_do_modelo_conta_como_pendente(self):
        codigo, _, _ = rodar(self.repo)  # cria a partir do modelo
        self.assertEqual(codigo, 1)
        codigo, out, _ = rodar(self.repo)  # segunda execucao: valor do modelo
        self.assertEqual(codigo, 1)
        self.assertIn("DB_PASSWORD", out)
        self.assertIn("PENDENTE", out)


@unittest.skipUnless(shutil.which("docker"), "docker nao disponivel")
class ComposeReal(unittest.TestCase):
    """Integracao: o `docker-compose.yml` real resolve a partir do .env.

    Nao sobe container, nao toca em `.env` e nao exige segredo real -- a senha
    entra pelo ambiente do subprocesso. Verifica o contrato que o README
    documenta (sem ela o `config` falha; com ela resolve).
    """

    COMPOSE = REPO / "docker-compose.yml"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="compose_config_")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def config(self, com_senha: bool) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env.pop("DB_PASSWORD", None)
        if com_senha:
            env["DB_PASSWORD"] = SENHA_REAL
        return subprocess.run(
            [
                "docker", "compose", "-f", str(self.COMPOSE),
                "--project-directory", self._tmp.name, "config", "--quiet",
            ],
            capture_output=True, text=True, env=env, timeout=60,
        )

    def test_falha_sem_db_password(self):
        r = self.config(com_senha=False)
        self.assertNotEqual(r.returncode, 0, "compose nao pode resolver sem DB_PASSWORD")
        self.assertIn("DB_PASSWORD", r.stderr)

    def test_resolve_com_db_password(self):
        r = self.config(com_senha=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(SENHA_REAL, r.stdout + r.stderr, "valor nunca e impresso")

    def test_container_name_fixo_esta_documentado(self):
        texto = self.COMPOSE.read_text(encoding="utf-8")
        self.assertIn(
            "container_name: home_shopper-db", texto,
            "o README depende deste nome fixo; se mudar, atualize a nota de colisao",
        )



if __name__ == "__main__":
    unittest.main()
