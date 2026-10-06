#!/usr/bin/env python3
"""
Expurgo da imagem de cupom no disco (internal task).

O furo que ele fecha
--------------------
`staging_receipts.file_path` guarda o caminho da foto do cupom; o arquivo vive
no disco, nunca no banco (ADR-0005, secao 2). O `DELETE FROM users` da exclusao
LGPD nao apaga arquivo nenhum, e o banco NAO SABE se o arquivo existe: as duas
coisas sao independentes (ADR-0004, secao 4). Enquanto nao houver expurgo do
disco, uma exclusao LGPD deixa residuo -- e o cupom mostra CPF, endereco e a
cesta da pessoa.

O que ele faz, por alvo vencido em `v_retention_due` (acao `DELETE_FILE`)
------------------------------------------------------------------------
1. apaga o arquivo do disco;
2. zera `staging_receipts.file_path`;
3. registra o evento em `audit_log` -- SEM o caminho e SEM o conteudo.

A ordem importa e tem consequencia declarada: se o processo morrer entre (1) e
(2), o caminho fica apontando para um arquivo que nao existe. Isso e visivel e
auto-corrigivel -- a proxima execucao ve o arquivo ausente, registra
`file_existed: false` e zera o caminho mesmo assim. O contrario (zerar o caminho
e deixar o arquivo) seria pior: o arquivo ficaria orfao, sem referencia alguma.

Por que o caminho NAO vai para `audit_log.before_data`
------------------------------------------------------
O payload de auditoria existe para provar o que mudou, e ele mesmo e expurgado
por prazo (db/010). Gravar ali o caminho do cupom -- ou o proprio arquivo -- 
seria recriar o dado pessoal que o expurgo acabou de remover, num lugar que
ninguem consulta para conferir. O registro guarda o FATO (`file_existed`), nao o
alvo.

Guarda de contencao (por que o caminho do banco nao e obedecido cegamente)
-------------------------------------------------------------------------
O caminho vem de uma coluna do banco. Apagar um caminho arbitrario a partir
disso seria um jeito silencioso de transformar dado em comando. Por isso o alvo
tem de resolver DENTRO da raiz de armazenamento (`STORAGE_DIR` no ambiente,
`--storage-dir`, ou `./storage` na raiz do repo). Fora dela: recusa, nada e
apagado e nada e zerado para aquele alvo (zerar sem apagar deixaria o arquivo
orfao).

Dry-run e o padrao: sem `--apply` o script so LE o banco e faz `stat` no disco.

Dois modos
----------
  * **fila de retencao** (default): os alvos vencidos em `v_retention_due`
    (acao `DELETE_FILE`) -- art. 15, I (a revisao acabou / o prazo acabou).
  * **`--user <uuid>`**: TODAS as imagens de um titular, AGORA, sem janela --
    art. 18, VI (eliminacao a pedido). E o modo da exclusao LGPD, e ele tem de
    rodar ANTES do `DELETE FROM users`: `fk_staging_receipts_user` e
    ON DELETE CASCADE, entao apagar a pessoa apaga as LINHAS que guardam os
    caminhos, e com elas a unica referencia para o arquivo em disco. Ordem
    errada = arquivo orfao, sem prova e sem como achar de novo.
    Por isso o registro de auditoria desse modo usa `reason` diferente
    (`lgpd_erasure` vs `lgpd_retention_purge`): um e pedido do titular, o outro
    e o fim do prazo, e o rastro precisa distinguir os dois.

Uso
---
    python3 scripts/purge_coupon_image.py                      # plano (dry-run)
    python3 scripts/purge_coupon_image.py --apply
    python3 scripts/purge_coupon_image.py --user <uuid> --apply   # art. 18, VI
    python3 scripts/purge_coupon_image.py --apply --storage-dir /srv/cupons \\
        --psql "docker exec -i home_shopper-db psql"

Exit code
---------
0  nada a fazer, ou expurgo concluido sem recusa
1  houve recusa (alvo fora da raiz de armazenamento, ou caminho nao e arquivo)
2  erro de ambiente / de SQL
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retention_common as rc  # noqa: E402

ENV_STORAGE = "STORAGE_DIR"
ACAO = "DELETE_FILE"

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

SQL_FILA = f"""
SELECT record_id, target_value, table_name, column_name
  FROM v_retention_due
 WHERE purge_action = '{ACAO}'
 ORDER BY due_at, record_id;
"""

# Modo art. 18, VI: sem janela. O gatilho e o pedido do titular, nao o prazo.
SQL_POR_TITULAR = """
SELECT id, file_path
  FROM staging_receipts
 WHERE user_id = '{user_id}'::uuid
   AND file_path IS NOT NULL
 ORDER BY id;
"""

MOTIVO_RETENCAO = "lgpd_retention_purge"
MOTIVO_ERASURE = "lgpd_erasure"


def literal(texto: str) -> str:
    """Literal SQL de texto. `'` dobrado; nada mais e interpretado."""
    return "'" + texto.replace("'", "''") + "'"


def raiz_armazenamento(args) -> Path:
    bruto = args.storage_dir or os.environ.get(ENV_STORAGE) or "storage"
    caminho = Path(bruto)
    raiz = caminho if caminho.is_absolute() else rc.raiz_do_repo() / caminho
    return Path(os.path.normpath(raiz))


def resolver(alvo_bruto: str, raiz: Path) -> Path:
    alvo = Path(alvo_bruto)
    return alvo if alvo.is_absolute() else raiz / alvo


def dentro(caminho: Path, raiz: Path) -> bool:
    try:
        return caminho.resolve().is_relative_to(raiz.resolve())
    except (OSError, ValueError):
        return False


def sql_expurgo(record_id: str, caminho: str, existia: bool, motivo: str) -> str:
    """Zera o caminho e registra o evento -- SO se o UPDATE realmente ocorrer."""
    if not UUID_RE.match(record_id):
        raise rc.Erro(f"record_id que nao e UUID: {record_id!r}")
    if motivo not in (MOTIVO_RETENCAO, MOTIVO_ERASURE):
        raise rc.Erro(f"motivo de expurgo desconhecido: {motivo!r}")
    return f"""
WITH upd AS (
    UPDATE staging_receipts
       SET file_path = NULL
     WHERE id = {literal(record_id)}::uuid
       AND file_path = {literal(caminho)}
    RETURNING id, user_id
)
INSERT INTO audit_log (user_id, table_name, operation, record_id,
                       before_data, after_data)
SELECT user_id, 'staging_receipts', 'UPDATE', id,
       jsonb_build_object('reason', {literal(motivo)},
                          'file_path', 'redacted',
                          'file_existed', {str(existia).lower()}::boolean),
       jsonb_build_object('file_path', NULL)
  FROM upd;
"""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="purge_coupon_image.py",
        description=(
            "Apaga a imagem de cupom do disco para os alvos vencidos em "
            "v_retention_due (acao DELETE_FILE), zera `staging_receipts.file_path` "
            "e registra em `audit_log`. Dry-run por padrao."
        ),
        epilog="exit 0 ok | 1 recusa de alvo | 2 erro de ambiente",
    )
    ap.add_argument("--apply", action="store_true",
                    help="executa (apaga o arquivo e grava no banco); sem a flag, so o plano")
    ap.add_argument("--storage-dir", metavar="DIR",
                    help=f"raiz do armazenamento (default: ${ENV_STORAGE} ou ./storage)")
    ap.add_argument("--user-id", metavar="UUID",
                    help="modo art. 18, VI: todas as imagens do titular, sem janela. "
                         "Rode ANTES do DELETE FROM users (o cascade apaga os caminhos)")
    rc.adicionar_argumentos(ap)
    args = ap.parse_args(argv)

    try:
        raiz = raiz_armazenamento(args)

        if args.user_id:
            if not UUID_RE.match(args.user_id):
                raise rc.Erro(f"--user-id nao e UUID: {args.user_id!r}")
            motivo = MOTIVO_ERASURE
            bruto = SQL_POR_TITULAR.format(user_id=args.user_id)
            print(f"MODO: eliminacao a pedido do titular (art. 18, VI) -- {args.user_id}")
            print("FILA (todas as imagens do titular, sem janela)")
            # Duas colunas aqui, quatro na fila de retencao: normaliza.
            fila = [[record_id, caminho, "", ""] for record_id, caminho in rc.linhas(rc.rodar_sql(args, bruto))]
        else:
            motivo = MOTIVO_RETENCAO
            print(f"FILA (v_retention_due, acao {ACAO})")
            fila = rc.linhas(rc.rodar_sql(args, SQL_FILA))

        print(f"RAIZ DE ARMAZENAMENTO: {raiz}")
        if not fila:
            print("  (vazia)")
            print()
            print("DRY-RUN -- nada foi alterado." if not args.apply else
                  "Nada a fazer: a politica ja estava cumprida.")
            return 0

        plano: list[tuple[str, str, Path, str]] = []  # (id, caminho bruto, alvo, situacao)
        recusas: list[str] = []
        for campos in fila:
            if len(campos) != 4:
                raise rc.Erro(f"linha inesperada de v_retention_due: {campos!r}")
            record_id, caminho, _tabela, _coluna = campos
            if not caminho.strip():
                # Caminho vazio nao e arquivo: normalizar e zerar e a correcao.
                plano.append((record_id, caminho, Path(), "vazio"))
                continue
            alvo = resolver(caminho, raiz)
            if not dentro(alvo, raiz):
                recusas.append(
                    f"{record_id}: {caminho!r} resolve para fora de {raiz} -- "
                    "recusado (nada apagado, caminho NAO zerado)"
                )
                continue
            if alvo.is_dir():
                recusas.append(f"{record_id}: {caminho!r} e um diretorio -- recusado")
                continue
            plano.append((record_id, caminho, alvo, "existe" if alvo.is_file() else "ausente"))

        for record_id, caminho, alvo, situacao in plano:
            print("  %s  %-8s %s" % (record_id, situacao, caminho))
        for recusa in recusas:
            rc.aviso(f"RECUSA  {recusa}")
        print()

        if not args.apply:
            print("DRY-RUN -- nenhum arquivo apagado, nenhum caminho zerado.")
            return 1 if recusas else 0

        comandos: list[str] = ["BEGIN;"]
        apagados = ausentes = 0
        for record_id, caminho, alvo, situacao in plano:
            if situacao == "vazio":
                existia = False
            elif situacao == "existe":
                alvo.unlink()
                apagados += 1
                existia = True
            else:
                ausentes += 1
                existia = False
            comandos.append(sql_expurgo(record_id, caminho, existia, motivo))
        comandos.append("COMMIT;")
        rc.rodar_sql(args, "\n".join(comandos))

        print("EXPURGO EXECUTADO")
        print(f"  arquivos apagados do disco : {apagados}")
        print(f"  caminhos sem arquivo       : {ausentes}")
        print(f"  caminhos zerados no banco  : {len(plano)}")
        if recusas:
            print(f"  recusas                    : {len(recusas)}")
        print()

        if args.user_id:
            print("VERIFICACAO: o titular nao deve mais ter caminho de imagem")
            restante = rc.linhas(rc.rodar_sql(args, SQL_POR_TITULAR.format(user_id=args.user_id)))
            if restante and not recusas:
                rc.aviso("purge_coupon_image: o titular continua com caminho de imagem")
                return 1
            print("  nenhum caminho de imagem restante -- ok"
                  if not restante else "  restam apenas os alvos recusados")
            return 1 if recusas else 0

        print("VERIFICACAO: a fila nao deve mais conter estes alvos")
        restante = rc.linhas(rc.rodar_sql(args, SQL_FILA))
        if restante and not recusas:
            rc.aviso("purge_coupon_image: a fila continua com alvos vencidos")
            return 1
        print("  v_retention_due sem alvos vencidos -- ok"
              if not restante else "  restam apenas os alvos recusados")
        return 1 if recusas else 0
    except rc.Erro as e:
        rc.aviso(f"purge_coupon_image: {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
