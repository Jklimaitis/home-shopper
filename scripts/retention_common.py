#!/usr/bin/env python3
"""
Plumbing shared by the LGPD purge scripts (internal task).

Por que existe
--------------
`scripts/purge_expired.py` e `scripts/purge_coupon_image.py` precisam das duas
mesmas coisas: falar com o Postgres e ler o registro `retention_policy` sem
inventar uma janela propria. O codigo fica aqui, uma vez, em vez de duplicado
com pequenas divergencias.

Como a conexao e feita (e por que o script nao guarda senha)
------------------------------------------------------------
O script NAO fala com o banco por driver: `psycopg`/`psycopg2` nao sao
dependencia deste repositorio. Ele chama o client `psql`, que resolve host,
porta e senha pelo ambiente padrao do Postgres (`PGHOST`, `PGPORT`,
`PGPASSWORD`, `PGDATABASE`) ou por `~/.pgpass`. Usuario e base vem de
`DB_USER` / `DB_NAME` (default `home_shopper`, o mesmo do `docker-compose.yml`)
ou das flags `--user` / `--dbname`.

Nenhum valor de senha passa por este modulo: ele nao le, nao imprime e nao
repassa senha. Quem autentica e o `psql` do operador.

Quando o banco roda em container e nao ha `psql` no host, o prefixo do comando
e o caminho:

    python3 scripts/purge_expired.py \\
        --psql "docker exec -i home_shopper-db psql"

O client roda DENTRO do container e a conexao local usa o socket unix (trust no
`pg_hba.conf` gerado pela imagem oficial), sem senha. As flags `-U` e `-d`
continuam sendo anexadas ao final, e o `docker exec` as repassa ao `psql`.

Identificador vindo do banco NAO entra em SQL por concatenacao
--------------------------------------------------------------
`retention_policy.table_name` / `column_name` alimentam o relatorio das
politicas sem prazo fixo. Antes de qualquer identificador chegar ao SQL ele e
revalidado com a MESMA expressao do CHECK de `db/010_retention_policy.sql`
(`^[a-z_][a-z0-9_]*$`). Sem isso, um valor gravado na tabela viraria SQL.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

# A mesma forma exigida por ck_retention_policy_table_name / _column_name.
IDENT_RE = re.compile(r"^[a-z_][a-z0-9_]*$")

USUARIO_DEFAULT = "home_shopper"
BASE_DEFAULT = "home_shopper"

PREFIXO_ENV = "PURGE_PSQL"


class Erro(Exception):
    """Erro de ambiente ou de execucao -- exit code 2."""


def ident(nome: str) -> str:
    """Valida um identificador antes de usa-lo em SQL. Levanta Erro."""
    if not IDENT_RE.match(nome or ""):
        raise Erro(
            f"identificador invalido vindo do banco: {nome!r} -- a politica "
            "so aceita ^[a-z_][a-z0-9_]*$ (db/010_retention_policy.sql)"
        )
    return nome


def usuario(args) -> str:
    return getattr(args, "user", None) or os.environ.get("DB_USER") or USUARIO_DEFAULT


def base(args) -> str:
    return getattr(args, "dbname", None) or os.environ.get("DB_NAME") or BASE_DEFAULT


def prefixo_psql(args) -> list[str]:
    """O comando `psql`, antes das flags de conexao."""
    bruto = getattr(args, "psql", None) or os.environ.get(PREFIXO_ENV) or "psql"
    partes = shlex.split(bruto)
    if not partes:
        raise Erro(f"prefixo de psql vazio (--psql / {PREFIXO_ENV})")
    return partes


def comando(args, *, colunas: bool) -> list[str]:
    """`psql` com as flags de conexao. `-t -A -F '|'` para saida parseavel."""
    cmd = [*prefixo_psql(args), "-X", "-q", "-v", "ON_ERROR_STOP=1",
           "-U", usuario(args), "-d", base(args)]
    if colunas:
        cmd += ["-t", "-A", "-F", "|"]
    return cmd


def rodar_sql(args, sql: str, *, colunas: bool = True) -> str:
    """Executa `sql` pelo psql. Erro de SQL (ou de conexao) levanta Erro."""
    cmd = comando(args, colunas=colunas)
    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if proc.returncode != 0:
        detalhe = (proc.stderr or proc.stdout).strip()
        raise Erro(
            "psql falhou (exit %d)\n  comando: %s\n%s"
            % (proc.returncode, " ".join(shlex.quote(c) for c in cmd), detalhe)
        )
    return proc.stdout


def linhas(saida: str) -> list[list[str]]:
    """Quebra a saida `-t -A -F '|'` em linhas/campos, ignorando vazio."""
    return [linha.split("|") for linha in saida.splitlines() if linha.strip()]


def ler_politicas(args) -> list[dict]:
    """O registro inteiro, em memoria. `v_retention_due` deriva disto."""
    sql = (
        "SELECT table_name, column_name, legal_basis, "
        "       coalesce(retention_days::text, ''), "
        "       coalesce(expires_at::text, ''), "
        "       coalesce(last_purged_at::text, '') "
        "  FROM retention_policy "
        " ORDER BY table_name, column_name;"
    )
    politicas = []
    for campos in linhas(rodar_sql(args, sql)):
        if len(campos) != 6:
            raise Erro(f"linha inesperada do registro de politicas: {campos!r}")
        politicas.append({
            "table": ident(campos[0]),
            "column": ident(campos[1]),
            "basis": campos[2],
            "days": int(campos[3]) if campos[3] else None,
            "expires_at": campos[4] or None,
            "last_purged_at": campos[5] or None,
        })
    return politicas


def chave(politica: dict) -> str:
    return f"{politica['table']}.{politica['column']}"


def adicionar_argumentos(ap) -> None:
    """As flags de conexao comuns aos dois scripts."""
    ap.add_argument(
        "--psql",
        metavar="CMD",
        help="prefixo do client (default: $%s ou `psql`); ex.: "
             "'docker exec -i home_shopper-db psql'" % PREFIXO_ENV,
    )
    ap.add_argument("--user", help="usuario do banco (default: $DB_USER)")
    ap.add_argument("--dbname", help="base do banco (default: $DB_NAME)")


def raiz_do_repo() -> Path:
    """Raiz do worktree que contem este arquivo (funciona em git worktree)."""
    return Path(__file__).resolve().parent.parent


def aviso(msg: str) -> None:
    # Ordem na tela: sem o flush, o erro (stderr, sem buffer) aparece ANTES do
    # plano (stdout, com buffer) quando a saida e canalizada.
    sys.stdout.flush()
    print(msg, file=sys.stderr)
    sys.stderr.flush()
