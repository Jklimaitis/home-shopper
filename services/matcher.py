import unicodedata
from dataclasses import dataclass
from typing import Optional
import psycopg2.extensions


@dataclass
class MatchResult:
    product_id: Optional[str]        # UUID como string
    presentation_id: Optional[str]   # UUID como string
    match_source: str                # 'BARCODE', 'DESCRIPTION', 'ALIAS', 'MANUAL', 'NONE'
    confidence: float
    note: Optional[dict] = None      # auditoria do motivo; a persistência serializa


def normalize_text(text: str) -> str: # remover acentos, tudo minuscilo e espaços excedentes
    if not text:
        return ""
    nfkd = unicodedata.normalize("NFKD", text)
    cleaned = "".join([c for c in nfkd if not unicodedata.combining(c)])
    return " ".join(cleaned.lower().split())


def match_staging_line(
    conn: psycopg2.extensions.connection,
    raw_description: str,
    barcode: Optional[str] = None,
    *,
    store_id: Optional[str] = None,
    sale_unit: Optional[str] = None,
) -> MatchResult:
    with conn.cursor() as cur:
        # 1. Match por GTIN / Codigo de barra em presentation_identifiers
        if barcode and barcode.strip():
            cur.execute("""
                SELECT pi.presentation_id, pr.product_id
                FROM presentation_identifiers pi
                JOIN presentations pr ON pr.id = pi.presentation_id
                WHERE pi.gtin = %s
                LIMIT 1
            """, (barcode.strip(),))
            row = cur.fetchone()
            if row:
                return MatchResult(
                    presentation_id=str(row[0]),
                    product_id=str(row[1]),
                    match_source="BARCODE",
                    confidence=1.0
                )

        # 2. Match por descrição em presentation_sources
        # Candidatos distintos (loja e global) em conflito não são desempatados
        # por conta própria: escolher um gravaria o preço no produto errado.
        normalized_desc = normalize_text(raw_description)
        if normalized_desc:
            cur.execute("""
                SELECT DISTINCT ps.presentation_id, pr.product_id
                FROM presentation_sources ps
                JOIN presentations pr ON pr.id = ps.presentation_id
                WHERE ps.description_search = %s
                  AND (ps.store_id = %s OR ps.store_id IS NULL)
                  AND upper(btrim(ps.sale_unit)) = upper(btrim(%s))
                ORDER BY 1
                LIMIT 2
            """, (normalized_desc, store_id, sale_unit))
            rows = cur.fetchall()
            if len(rows) > 1:
                return MatchResult(
                    product_id=None,
                    presentation_id=None,
                    match_source="NONE",
                    confidence=0.0,
                    note={
                        "reason": "ambiguous_description",
                        "candidates": [
                            {"presentation_id": str(r[0]), "product_id": str(r[1])}
                            for r in rows
                        ],
                    },
                )
            if rows:
                row = rows[0]
                return MatchResult(
                    presentation_id=str(row[0]),
                    product_id=str(row[1]),
                    match_source="DESCRIPTION",
                    confidence=0.9
                )

    # 3. Nenhum match encontrado
    return MatchResult(
        product_id=None,
        presentation_id=None,
        match_source="NONE",
        confidence=0.0
    )