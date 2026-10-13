import argparse
import json
import os
import sys
import uuid
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Adiciona a raiz do projeto ao sys.path para permitir imports relativos
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import psycopg2
from dotenv import load_dotenv
from services.matcher import MatchResult, match_staging_line

# A configuração privada só é carregada na execução da CLI, nunca no import.
_env_path = Path(__file__).resolve().parent.parent / ".env"

def connect_database():
    """Conecta sem interpolar credenciais em uma string de parâmetros."""
    if "DATABASE_URL" in os.environ:
        url = os.environ["DATABASE_URL"]
        if not url.strip():
            raise ValueError("Configuração de conexão inválida.")
        return psycopg2.connect(url)
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "home_shopper"),
        user=os.getenv("DB_USER", "home_shopper"),
        password=os.getenv("DB_PASSWORD", ""),
    )


DEFAULT_USER_ID = os.getenv("DEFAULT_USER_ID", "00000000-0000-0000-0000-000000000001")


# ─── Funções auxiliares ─────────────────────────────────────────

def parse_decimal(value: Any, default: str = "0.00") -> Decimal: #Converte valores float, int ou str (inclusive com vírgula) para Decimal com segurança.
    if value is None:
        return Decimal(default)
    if isinstance(value, (int, float)):
        return Decimal(str(value))
    clean_val = str(value).strip().replace(",", ".")
    return Decimal(clean_val) if clean_val else Decimal(default)


def parse_note(payload: dict) -> dict: # Normaliza o JSON da NFC-e para o formato interno aderente ao schema.
    header = payload.get("header") or payload.get("nota") or payload
    items_raw = payload.get("items") or payload.get("itens") or []

    # Extrai chave de acesso (44 dígitos para source_ref)
    access_key = (
        header.get("access_key")
        or header.get("chave_acesso")
        or header.get("chave")
        or header.get("source_ref")
    )
    if access_key:
        access_key = "".join(filter(str.isdigit, str(access_key)))

    store_cnpj = (
        header.get("store_cnpj")
        or header.get("cnpj")
        or header.get("emitente_cnpj")
    )
    if store_cnpj:
        store_cnpj = "".join(filter(str.isdigit, str(store_cnpj)))

    store_name = (
        header.get("store_name")
        or header.get("razao_social")
        or header.get("nome_fantasia")
        or header.get("emitente_nome")
        or "Estabelecimento Desconhecido"
    )

    # Valores financeiros
    total_gross = parse_decimal(
        header.get("total_gross")
        or header.get("valor_bruto")
        or header.get("valor_total")
        or header.get("total_amount")
        or header.get("total")
    )

    discount = parse_decimal(
        header.get("discount")
        or header.get("desconto")
        or header.get("valor_desconto")
    )

    amount_paid_raw = (
        header.get("amount_paid")
        or header.get("valor_pago")
        or header.get("total_liquido")
    )
    if amount_paid_raw is not None:
        amount_paid = parse_decimal(amount_paid_raw)
    else:
        amount_paid = total_gross - discount if discount else total_gross

    items: List[Dict[str, Any]] = []
    for idx, it in enumerate(items_raw, start=1):
        items.append({
            "line_no": it.get("line_no") if it.get("line_no") is not None else (it.get("numero_item") or idx),
            "description_raw": it.get("description_raw") or it.get("description") or it.get("descricao") or it.get("nome") or "",
            "store_code": str(it.get("store_code") or it.get("code") or it.get("codigo") or "").strip() or None,
            "sale_unit": (it.get("sale_unit") or it.get("unit") or it.get("unidade") or "UN").strip().upper(),
            "quantity": parse_decimal(it.get("quantity") or it.get("quantidade"), default="1.000"),
            "unit_price": parse_decimal(it.get("unit_price") or it.get("valor_unitario")),
            "line_total": parse_decimal(it.get("line_total") or it.get("total_price") or it.get("valor_total"))
        })

    return {
        "source_ref": access_key,
        "store_cnpj": store_cnpj,
        "store_name": store_name,
        "total_gross": total_gross,
        "amount_paid": amount_paid,
        "items": items
    }


def resolve_or_create_store(conn, cnpj: Optional[str], store_name: str) -> Optional[uuid.UUID]: # Obtém store_id existente por CNPJ ou cadastra nova loja preliminarmente.
    if not cnpj:
        return None

    with conn.cursor() as cur:
        cur.execute("SELECT id FROM stores WHERE cnpj = %s LIMIT 1;", (cnpj,))
        row = cur.fetchone()
        if row:
            return row[0]

        # Cria loja automaticamente se não existir
        cur.execute("""
            INSERT INTO stores (name, cnpj)
            VALUES (%s, %s)
            RETURNING id;
        """, (store_name, cnpj))
        return cur.fetchone()[0]


def insert_staging_receipt(
    conn,
    note: dict,
    user_id: str,
    source: str,
    file_path: Optional[str] = None
) -> uuid.UUID: # Insere em staging_receipts e retorna o receipt_id (UUID).
    with conn.cursor() as cur:
        # O índice decide a duplicata atomicamente por usuário, origem e
        # referência normalizada; não consultar referências de outros titulares.
        store_id = resolve_or_create_store(conn, note.get("store_cnpj"), note.get("store_name"))

        cur.execute("""
            INSERT INTO staging_receipts (
                user_id, source, source_ref, store_id, total_gross, amount_paid, file_path
            ) VALUES (
                %s, %s, %s, %s, %s, %s, %s
            )
            ON CONFLICT (user_id, source, source_ref_norm)
                WHERE source_ref_norm <> ''
                DO NOTHING
            RETURNING id;
        """, (
            user_id,
            source,
            note.get("source_ref"),
            store_id,
            note["total_gross"],
            note["amount_paid"],
            file_path
        ))
        row = cur.fetchone()
        if row is None:
            raise ValueError("Cupom já importado para este usuário e origem.")
        return row[0]


def insert_staging_lines(conn, receipt_id: uuid.UUID, items: list[dict]) -> dict:
    """Insere em staging_lines rodando o matcher para cada linha."""
    stats = {"BARCODE": 0, "DESCRIPTION": 0, "ALIAS": 0, "NONE": 0}

    with conn.cursor() as cur:
        for item in items:
            raw_desc = item["description_raw"]
            raw_code = item["store_code"]

            # Matching preliminar
            match: MatchResult = match_staging_line(conn, raw_description=raw_desc, barcode=raw_code)
            stats[match.match_source] = stats.get(match.match_source, 0) + 1

            cur.execute("""
                INSERT INTO staging_lines (
                    receipt_id, line_no, description_raw, store_code,
                    sale_unit, quantity, unit_price, line_total,
                    product_id, presentation_id, match_source, match_note,
                    reviewed
                ) VALUES (
                    %s, %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s, %s, FALSE
                );
            """, (
                receipt_id,
                item["line_no"],
                raw_desc,
                raw_code,
                item["sale_unit"],
                item["quantity"],
                item["unit_price"],
                item["line_total"],
                match.product_id,
                match.presentation_id,
                match.match_source,
                f"confidence={match.confidence}"
            ))

    return stats


def print_review_instructions(receipt_id: uuid.UUID) -> None:
    """Imprime queries formatadas para inspeção e revisão via psql."""
    print("\n" + "=" * 65)
    print("📋 SQL PARA REVISÃO EM STAGING")
    print("=" * 65)
    print(f"""-- 1. Inspecionar todas as linhas do cupom ingerido:
SELECT 
    id, line_no, description_raw, store_code, 
    match_source, product_id, presentation_id, reviewed
FROM staging_lines
WHERE receipt_id = '{receipt_id}'
ORDER BY line_no;

-- 2. Linhas pendentes de match (match_source = 'NONE'):
SELECT id, line_no, description_raw, store_code, line_total
FROM staging_lines
WHERE receipt_id = '{receipt_id}' AND match_source = 'NONE';

-- 3. Atualizar/revisar linha manualmente:
-- UPDATE staging_lines
-- SET product_id = '<UUID_PRODUCT>',
--     presentation_id = '<UUID_PRESENTATION>',
--     match_source = 'MANUAL',
--     reviewed = TRUE
-- WHERE id = '<UUID_STAGING_LINE>';
""")


# ─── Main ───────────────────────────────────────────────────────

def main():
    try:
        load_dotenv(dotenv_path=_env_path, override=False)
    except Exception:
        print("[!] Não foi possível carregar a configuração da importação.")
        sys.exit(1)
    default_user_id = os.getenv("DEFAULT_USER_ID", DEFAULT_USER_ID)
    parser = argparse.ArgumentParser(description="Ingestão de NFC-e em staging para conferência e matching.")
    parser.add_argument("file", type=Path, help="Caminho do arquivo JSON da NFC-e")
    parser.add_argument("--user-id", default=default_user_id, help=f"UUID do usuário (default: {default_user_id})")
    parser.add_argument(
        "--source",
        choices=["MANUAL", "QRCODE", "SEFAZ", "OCR", "IMPORT"],
        default="QRCODE",
        help="Canal de origem (enum ingestion_source, default: QRCODE)"
    )

    args = parser.parse_args()

    if not args.file.is_file():
        print("[!] Arquivo de entrada não encontrado.")
        sys.exit(1)

    try:
        with open(args.file, "r", encoding="utf-8") as f:
            raw_data = json.load(f)
        parsed_note = parse_note(raw_data)
    except json.JSONDecodeError:
        print("[!] Arquivo JSON inválido.")
        sys.exit(1)
    except Exception:
        print("[!] Não foi possível ler ou interpretar a entrada.")
        sys.exit(1)

    conn = None
    try:
        conn = connect_database()
        with conn:  # Bloco transacional atômico (BEGIN / COMMIT)
            receipt_id = insert_staging_receipt(
                conn=conn,
                note=parsed_note,
                user_id=args.user_id,
                source=args.source,
                file_path=str(args.file.resolve())
            )
            stats = insert_staging_lines(conn, receipt_id, parsed_note["items"])

        print(f"\n[✓] Ingestão realizada com sucesso!")
        print(f"    - Staging Receipt ID: {receipt_id}")
        print(f"    - Estabelecimento: {parsed_note.get('store_name')}")
        print(f"    - Total Bruto: R$ {parsed_note['total_gross']:.2f} | Pago: R$ {parsed_note['amount_paid']:.2f}")
        print(f"    - Itens ingeridos: {len(parsed_note['items'])}")
        print(f"    - Match por Barcode: {stats.get('BARCODE', 0)}")
        print(f"    - Match por Descrição: {stats.get('DESCRIPTION', 0)}")
        print(f"    - Sem match (NONE): {stats.get('NONE', 0)}")

        print_review_instructions(receipt_id)

    except psycopg2.Error:
        print("\n[!] Erro de banco de dados. A importação não foi concluída.")
        sys.exit(1)
    except ValueError:
        print("\n[!] Dados inválidos ou cupom já importado para este usuário e origem.")
        sys.exit(1)
    except Exception:
        print("\n[!] Falha inesperada. A importação não foi concluída.")
        sys.exit(1)
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                print("[!] Não foi possível encerrar a conexão de banco.")
                sys.exit(1)


if __name__ == "__main__":
    main()