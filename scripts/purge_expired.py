#!/usr/bin/env python3
"""
Expurgo do que a politica de retencao registra como vencido (internal task).

O que ele faz
-------------
Le `v_retention_due` (derivada de `retention_policy`, db/010) e executa DUAS
acoes, cada uma so quando a politica correspondente esta registrada:

  (a) `audit_log.before_data` / `after_data` -- descarta o payload JSONB
      (`SET ... = NULL`). O rastro continua: `table_name`, `operation`,
      `record_id`, `occurred_at` e `user_id` ficam. E a anonimizacao que o
      art. 16, IV da LGPD exige para conservar dado do proprio controlador.
  (b) `data_erasure_requests.email` -- `NULL` no e-mail, depois da janela
      contada de `executed_at`. O registro da exclusao (art. 37) sobrevive sem
      o endereco de contato do titular.

O que ele NAO faz, por decisao registrada
-----------------------------------------
  * NAO apaga `purchase_notes` / `line_items` / `users.email`. As tres tem
    `retention_days IS NULL` no registro ("sem prazo fixo"): enquanto a
    comparacao de home_shopper for a finalidade, o dado e necessario (art. 15, I), e
    apaga-lo quebraria o produto em vez de proteger alguem. Elas aparecem no
    relatorio, com a data de revisao registrada, e nao no expurgo.
  * NAO apaga arquivo de cupom. Isso e `scripts/purge_coupon_image.py`, porque a
    exclusao envolve o disco (o banco nao sabe se o arquivo existe -- ADR-0004,
    secao 4). A fila de arquivos vencidos e reportada aqui.

Idempotencia
------------
O script nao decide nada por conta propria: toda janela vem de
`retention_policy`, e o alvo de cada `UPDATE` e exatamente o que `v_retention_due`
projeta. Rodar `--apply` duas vezes na sequencia nao altera NADA na segunda vez
(0 registros expurgados e nenhum `last_purged_at` reescrito). Ao final de
`--apply`, o script RE-CONSULTA a fila e falha se sobrou algo que ele deveria
ter expurgado -- a prova de que os comandos e a view concordam.

Dry-run e o padrao
------------------
Sem `--apply`, o script so LE: nenhum UPDATE, nenhuma transacao implicita. O
plano sai na tela com as contagens exatas.

Uso
---
    python3 scripts/purge_expired.py                 # plano (dry-run)
    python3 scripts/purge_expired.py --apply         # executa
    python3 scripts/purge_expired.py --apply \\
        --psql "docker exec -i home_shopper-db psql"  # sem psql no host

Exit code
---------
0  plano impresso, senha ok, ou expurgo concluido
1  expurgo executado mas sobrou fila para as acoes deste script
2  erro de ambiente / de SQL
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retention_common as rc  # noqa: E402

ACOES_DESTE_SCRIPT = ("ANONYMIZE_PAYLOAD", "NULL_EMAIL")
ACAO_DE_ARQUIVO = "DELETE_FILE"

# Afirmacao de idempotencia: a segunda execucao nao altera nada.
SQL_FILA = """
SELECT purge_action, table_name, column_name, count(*)
  FROM v_retention_due
 GROUP BY purge_action, table_name, column_name
 ORDER BY purge_action, table_name, column_name;
"""


def sql_audit(coluna: str) -> str:
    """Descarta UMA coluna de payload, dentro da janela do registro."""
    coluna = rc.ident(coluna)
    alvo = f"audit_log.{coluna}"
    return f"""
WITH upd AS (
    UPDATE audit_log a
       SET {coluna} = NULL
      FROM retention_policy rp
     WHERE rp.table_name  = 'audit_log'
       AND rp.column_name = '{coluna}'
       AND rp.retention_days IS NOT NULL
       AND a.{coluna} IS NOT NULL
       AND a.occurred_at <= now() - make_interval(days => rp.retention_days)
    RETURNING 1
)
INSERT INTO _purge_report (target, action, purged)
SELECT '{alvo}', '{ACOES_DESTE_SCRIPT[0]}', count(*) FROM upd;"""


def sql_email() -> str:
    return f"""
WITH upd AS (
    UPDATE data_erasure_requests r
       SET email = NULL
      FROM retention_policy rp
     WHERE rp.table_name  = 'data_erasure_requests'
       AND rp.column_name = 'email'
       AND rp.retention_days IS NOT NULL
       AND r.email IS NOT NULL
       AND r.executed_at IS NOT NULL
       AND r.executed_at <= now() - make_interval(days => rp.retention_days)
    RETURNING 1
)
INSERT INTO _purge_report (target, action, purged)
SELECT 'data_erasure_requests.email', '{ACOES_DESTE_SCRIPT[1]}', count(*) FROM upd;"""


def comandos_de_expurgo(politicas: list[dict]) -> list[str]:
    """Um comando por alvo REGISTRADO. Registro ausente = alvo nao expurgado."""
    registrados = {rc.chave(p) for p in politicas if p["days"] is not None}
    comandos = []
    for alvo in ("audit_log.before_data", "audit_log.after_data"):
        if alvo in registrados:
            comandos.append(sql_audit(alvo.split(".", 1)[1]))
    if "data_erasure_requests.email" in registrados:
        comandos.append(sql_email())
    return comandos


def relatorio_sem_prazo(args, politicas: list[dict]) -> list[list[str]]:
    """Contagem de linhas com valor nos alvos 'sem prazo fixo' (so leitura)."""
    sem_prazo = [p for p in politicas if p["days"] is None]
    if not sem_prazo:
        return []
    partes = [
        "SELECT '%s' AS target, count(*) FILTER (WHERE %s IS NOT NULL) AS rows_with_value,"
        "       '%s' AS basis, '%s' AS review_due"
        "  FROM %s"
        % (rc.chave(p), rc.ident(p["column"]), p["basis"],
           p["expires_at"] or "", rc.ident(p["table"]))
        for p in sem_prazo
    ]
    sql = "\nUNION ALL\n".join(partes) + "\nORDER BY target;"
    return rc.linhas(rc.rodar_sql(args, sql))


def imprimir_politicas(politicas: list[dict]) -> None:
    print("REGISTRO (retention_policy) -- o que existe, por que, ate quando")
    print("  %-34s %-20s %-9s %s" % ("ALVO", "FUNDAMENTO (art. 7)", "PRAZO", "REVISAO"))
    for p in politicas:
        prazo = f"{p['days']} dias" if p["days"] is not None else "sem prazo"
        revisao = (p["expires_at"] or "-")[:10]
        print("  %-34s %-20s %-9s %s" % (rc.chave(p), p["basis"], prazo, revisao))
    print()


def imprimir_fila(fila: list[list[str]]) -> None:
    print("FILA (v_retention_due) -- o que venceu agora")
    if not fila:
        print("  (vazia: nada vencido)")
        print()
        return
    for acao, tabela, coluna, n in fila:
        nota = "  -> rode scripts/purge_coupon_image.py" if acao == ACAO_DE_ARQUIVO else ""
        print("  %-18s %-34s %s%s" % (acao, f"{tabela}.{coluna}", n, nota))
    print()


def imprimir_sem_prazo(linhas: list[list[str]]) -> None:
    if not linhas:
        return
    print("SEM PRAZO FIXO -- nao expurgado por decisao registrada (art. 15, I)")
    for alvo, n, fundamento, revisao in linhas:
        print("  %-34s %-10s %-20s revisao: %s" % (alvo, n, fundamento, revisao[:10]))
    print()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="purge_expired.py",
        description=(
            "Executa a politica de retencao registrada em `retention_policy`: "
            "descarta o payload de `audit_log` e zera o e-mail de "
            "`data_erasure_requests` passados os prazos. Dry-run por padrao."
        ),
        epilog="exit 0 ok | 1 sobrou fila apos o expurgo | 2 erro de ambiente",
    )
    ap.add_argument("--apply", action="store_true",
                    help="executa o expurgo (sem esta flag, apenas imprime o plano)")
    rc.adicionar_argumentos(ap)
    args = ap.parse_args(argv)

    try:
        politicas = rc.ler_politicas(args)
        if not politicas:
            rc.aviso(
                "purge_expired: `retention_policy` esta vazia -- sem registro nao "
                "ha politica a executar (db/010_retention_policy.sql)"
            )
            return 2

        fila = rc.linhas(rc.rodar_sql(args, SQL_FILA))
        imprimir_politicas(politicas)
        imprimir_fila(fila)
        imprimir_sem_prazo(relatorio_sem_prazo(args, politicas))

        comandos = comandos_de_expurgo(politicas)
        if not comandos:
            rc.aviso("purge_expired: nenhum alvo deste script esta registrado")
            return 2

        if not args.apply:
            print("DRY-RUN -- nada foi alterado. Para executar: --apply")
            return 0

        sql = "\n".join([
            "BEGIN;",
            "CREATE TEMP TABLE _purge_report (target TEXT, action TEXT, purged BIGINT)"
            " ON COMMIT DROP;",
            *comandos,
            # last_purged_at so muda quando algo foi realmente expurgado: e o que
            # torna a segunda execucao um no-op verificavel.
            "UPDATE retention_policy rp SET last_purged_at = now()"
            " WHERE EXISTS (SELECT 1 FROM _purge_report p"
            "                WHERE p.target = rp.table_name || '.' || rp.column_name"
            "                  AND p.purged > 0);",
            "SELECT target, action, purged FROM _purge_report ORDER BY target;",
            "COMMIT;",
        ])
        saida = rc.rodar_sql(args, sql)

        print("EXPURGO EXECUTADO")
        total = 0
        for target, action, purged in rc.linhas(saida):
            n = int(purged)
            total += n
            print("  %-18s %-34s %s" % (action, target, n))
        if total == 0:
            print("  (0 registros: a politica ja estava cumprida -- "
                  "segunda execucao nao altera nada)")
        print()

        # Prova de concordancia: a fila das acoes deste script tem de ficar vazia.
        restante = rc.linhas(rc.rodar_sql(
            args,
            "SELECT coalesce(sum(n), 0) FROM ("
            "  SELECT count(*) AS n FROM v_retention_due"
            f"  WHERE purge_action IN ('{ACOES_DESTE_SCRIPT[0]}', '{ACOES_DESTE_SCRIPT[1]}')"
            ") s;",
        ))
        if restante and int(restante[0][0]) != 0:
            rc.aviso(
                "purge_expired: sobrou fila (%s) para as acoes deste script -- os "
                "comandos e v_retention_due divergiram" % restante[0][0]
            )
            return 1
        print("VERIFICACAO: v_retention_due sem fila para este script -- ok")
        return 0
    except rc.Erro as e:
        rc.aviso(f"purge_expired: {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
