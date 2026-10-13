from fastapi import FastAPI, HTTPException, Query, Depends, Request
from fastapi.exceptions import RequestValidationError
from fastapi.exception_handlers import http_exception_handler, request_validation_exception_handler
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, SecretStr
from database import get_connection
from datetime import date, datetime
from typing import Literal, Any, cast
from auth import (
    verify_password, create_access_token, create_refresh_token,
    get_current_user_id, require_catalog_admin,
)
import json
import psycopg2
import psycopg2.errors
import uuid
from decimal import Decimal

app = FastAPI()


def _is_login_request(request: Request) -> bool:
    # Route identity also works when the application is mounted under a prefix.
    return getattr(request.scope.get("route"), "path", None) == "/login"


@app.exception_handler(RequestValidationError)
async def login_validation_error_handler(request: Request, exc: RequestValidationError):
    if _is_login_request(request):
        return JSONResponse(status_code=422, content={"detail": "Dados de login invalidos"})
    return await request_validation_exception_handler(request, exc)


@app.exception_handler(StarletteHTTPException)
async def login_http_error_handler(request: Request, exc: StarletteHTTPException):
    if _is_login_request(request) and exc.status_code in (400, 422):
        return JSONResponse(
            status_code=exc.status_code, content={"detail": "Dados de login invalidos"},
            headers=exc.headers,
        )
    return await http_exception_handler(request, exc)

# Tabela de conversão
UNIT_CONVERSION = {
    "KG": "G", "G": "G", "MG": "G",
    "L": "ML", "ML": "ML",
    "UN": "UN", "PCT": "UN", "CX": "UN",
}

# Parse para validar o cursor de pagina
def parse_cursor(cursor: str) -> tuple[date,str]:
    try:
        raw_date, raw_id = cursor.split(",", 1)
        return date.fromisoformat(raw_date), str(uuid.UUID(raw_id))
    except ValueError:
        raise HTTPException(status_code=422, detail="Cursor Inválido")

# Model Pydantic - define a "base" do produto - Estou usando para validar e aprender
class Product(BaseModel):
    id: str
    name: str
    brand: str | None = None
    base_unit: str

class ProductCreate(BaseModel):
    name: str
    brand: str | None = None
    sale_unit: str

@app.exception_handler(psycopg2.OperationalError)
def db_operational_error_handler(request, exc):
    return JSONResponse(
        status_code=503,
        content={"detail": "Banco de dados temporariamente indisponível"},
    )

@app.get("/")
def home():
    return {"message": "API do home_shopper funcionando!"}

@app.get("/products", response_model=list[Product])
def list_products():
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, name, brand, base_unit FROM products ORDER BY name")
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()

@app.get("/products/search", response_model=list[Product])
def search_products(q: str):
    # Escapa os curingas do ILIKE para que o texto digitado seja buscado literalmente
    escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT id, name, brand, base_unit FROM products WHERE name ILIKE %s ORDER BY name",
            (f"%{escaped}%",),
        )
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()

@app.get("/products/{product_id}", response_model=Product)
def get_product(product_id: str):
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT id, name, brand, base_unit FROM products WHERE id = %s",
            (product_id,),
        )
        product = cur.fetchone()
    except psycopg2.errors.InvalidTextRepresentation:
        # Caso o Postgres reclame que o texto não é UUID valido -> tratar como 404
        raise HTTPException(status_code=404, detail="Produto não encontrado")
    finally:   
        cur.close()
        conn.close()

    if product is None:
        raise HTTPException(status_code=404, detail="Produto não encontrado")
    
    return product

@app.post("/products", response_model=Product, status_code=201, dependencies=[Depends(require_catalog_admin)])
def create_product(product: ProductCreate):
    #Validar unidade de conversão
    unit = product.sale_unit.upper()
    if unit not in UNIT_CONVERSION:
        raise HTTPException(
            status_code=400,
            detail=f"Unidade '{product.sale_unit}' inválida. Use uma das opções: {','.join(UNIT_CONVERSION.keys())}"
        )
    #Converter a unidade que o usuario digitou para a unidade de base
    base_unit = UNIT_CONVERSION[unit]
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "INSERT INTO products (name, brand, base_unit) VALUES (%s, %s, %s) RETURNING id, name, brand, base_unit",
            (product.name, product.brand, base_unit),
        )
        new_product = cur.fetchone()
        conn.commit() # SALVA NO BANCO!
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise HTTPException(status_code=409, detail="Produto já cadastrado")
    except psycopg2.IntegrityError:
        conn.rollback()
        raise HTTPException(status_code=400, detail="Dados inválidos")
    finally:
        cur.close()
        conn.close()
    return new_product

@app.put("/products/{product_id}", response_model=Product, dependencies=[Depends(require_catalog_admin)])
def update_product(product_id: str, product: ProductCreate):
    # Converter a Unidade (Sim, mesmo esquema do POST para o usuario não precisar escrever tudo em G ou ML)
    unit = product.sale_unit.upper()
    if unit not in UNIT_CONVERSION:
        raise HTTPException(
            status_code=400,
            detail=f"Unidade '{product.sale_unit}' inválida. Use: {', '.join(UNIT_CONVERSION.keys())}"
        )

    base_unit = UNIT_CONVERSION[unit]

    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "UPDATE products SET name= %s, brand = %s, base_unit = %s WHERE id = %s RETURNING id, name, brand, base_unit",
            (product.name, product.brand, base_unit, product_id),
        )
        updated_product = cur.fetchone()

        if updated_product is None:
            raise HTTPException(status_code=404, detail="Produto não encontrado")

        conn.commit()
        return updated_product

    except psycopg2.errors.InvalidTextRepresentation:
        conn.rollback()
        raise HTTPException(status_code=404, detail="Produto não encontrado")


    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise HTTPException(
            status_code=409,
            detail="Já existe outro produto cadastrado com esse nome e marca."
            )
    finally:
        cur.close()
        conn.close()

@app.delete("/products/{product_id}", status_code=204, dependencies=[Depends(require_catalog_admin)])
def delete_product(product_id: str):
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("DELETE FROM products WHERE id = %s", (product_id,))

        # Se não tiver linha afetada, ou seja produto não existe no banco
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Produto não encontrado")
        
        conn.commit()

    except psycopg2.errors.InvalidTextRepresentation:
        conn.rollback()
        raise HTTPException(status_code=404, detail="Produto não encontrado")

    
    except psycopg2.errors.ForeignKeyViolation:
        conn.rollback() #Desfaz a ação de deleção
        raise HTTPException(
            status_code=409,
            detail="Não é possível excluir esse produto pois ele já possui itens ou compras vinculados."
        )

    finally:
        cur.close()
        conn.close()

class Store(BaseModel):
    id: str
    name: str
    cnpj: str | None = None
    ibge_code: str | None = None
    trade_name: str | None = None

class Category(BaseModel):
    id: str
    name: str
    parent_id: str | None = None

@app.get("/stores", response_model=list[Store])
def list_stores():
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, name, cnpj, ibge_code, trade_name FROM stores ORDER BY name")
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()

@app.get("/categories", response_model=list[Category])
def list_categories():
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, name, parent_id FROM categories ORDER BY name")
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()

class PriceRef(BaseModel):
    id: str
    user_id: str
    product_id: str
    store_id: str
    ref_date: date
    base_price: float
    base_unit: Literal["UN", "G", "ML"]
    updated_at: datetime | None = None
    price_change_pct: float | None = None

# Colunas fixas (nunca vêm do usuário), compartilhadas entre as rotas de price_refs
PRICE_REF_COLUMNS = """
    id, user_id, product_id, store_id, ref_date,
    base_price, base_unit, updated_at, price_change_pct
"""

class User(BaseModel):
    id: str

@app.get("/users", response_model=list[User])
def list_users(user_id: str = Depends(get_current_user_id)):
    conn = get_connection()
    try:
        cur = conn.cursor()
        try:
            cur.execute("SELECT id FROM users WHERE id = %s", (user_id,))
            return cur.fetchall()
        finally:
            cur.close()
    finally:
        conn.close()

class PriceRefPage(BaseModel): #Classe para termos o scroll "infinito"
    data: list[PriceRef]
    has_more: bool
    next_cursor: str | None = None

@app.get("/price_refs", response_model=PriceRefPage)
def list_price_refs(
    user_id: str = Depends(get_current_user_id),
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
):
    # Valida o cursor antes de abrir a conexão (cursor mal formado -> 422, não 500)
    cursor_date, cursor_id = parse_cursor(cursor) if cursor else (None, None)

    conn = get_connection()
    cur = conn.cursor()
    try:
        # A ordem (ref_date DESC, id DESC) precisa bater com a comparação (ref_date, id) < (%s, %s)
        if cursor:
            cur.execute(f"""
                SELECT {PRICE_REF_COLUMNS}
                FROM price_refs
                WHERE user_id = %s
                  AND (ref_date, id) < (%s, %s)
                ORDER BY ref_date DESC, id DESC
                LIMIT %s
            """, (user_id, cursor_date, cursor_id, limit + 1))
        else:
            cur.execute(f"""
                SELECT {PRICE_REF_COLUMNS}
                FROM price_refs
                WHERE user_id = %s
                ORDER BY ref_date DESC, id DESC
                LIMIT %s
            """, (user_id, limit + 1))

        rows = cur.fetchall()
    except psycopg2.errors.InvalidTextRepresentation:
        raise HTTPException(status_code=422, detail="user_id inválido")
    finally:
        cur.close()
        conn.close()

    # Se retornou limit+1 linhas, tem mais
    has_more = len(rows) > limit
    data = rows[:limit]  # esconde a linha extra

    # Cursor da próxima página = (ref_date, id) da última linha devolvida
    next_cursor = None
    if has_more:
        last = cast(dict[str, Any], data[-1])
        next_cursor = f"{last['ref_date'].isoformat()},{last['id']}"

    return {"data": data, "has_more": has_more, "next_cursor": next_cursor}

@app.get("/price_refs/product/{product_id}", response_model=PriceRefPage)
def get_price_refs_by_product(product_id: str, user_id: str = Depends(get_current_user_id)):
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(f"""
            SELECT {PRICE_REF_COLUMNS}
            FROM price_refs
            WHERE product_id = %s AND user_id = %s
            ORDER BY ref_date DESC, id
        """, (product_id, user_id))
        rows = cur.fetchall()
    except psycopg2.errors.InvalidTextRepresentation:
        raise HTTPException(status_code=422, detail="UUID inválido")
    finally:
        cur.close()
        conn.close()
    
    return {"data": rows, "has_more": False}

class LoginRequest(BaseModel):
    email: str
    password: SecretStr = Field(min_length=1)

@app.post("/login")
def login(data: LoginRequest):
    #1. Buscar usuário pelo email
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, email FROM users WHERE email = %s", (data.email,)) # Selecionando EMAIL
        user= cast(dict[str, Any] | None, cur.fetchone())

        # 3. Buscar credencial do usuario
        credential: dict[str, Any] | None = None
        if user is not None:
            cur.execute(
                "SELECT password_hash FROM user_credentials WHERE user_id = %s", # Selecionando HASH
                (user["id"],),
            )
            credential = cast(dict[str, Any] | None, cur.fetchone())
    finally:
        cur.close()
        conn.close()

    # Mesma mensagem para "Não existe" e "senha errada" para não revelar quais e-maisl existem
    if user is None or credential is None:
        raise HTTPException(status_code=401, detail="Email ou senha incorretos")

    # 4. Verificar senha com verify_password
    if not verify_password(data.password.get_secret_value(), credential["password_hash"]):
        raise HTTPException(status_code=401, detail="Email ou senha incorretos")

    # 5. Gerar access_token e refresh_token
    access_token = create_access_token(user["id"])
    refresh_token= create_refresh_token(user["id"])
    # 7. Retornar os dois tokens
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer",
    }


# ─── Staging: a fila de revisão do titular ───────────────────────────────────
#
# Duas rotas de leitura. Nenhuma escreve: decidir (confirmar, recusar, pular) e
# consolidar são passos posteriores.
#
# O escopo é do titular e vai no SQL como parâmetro -- não é filtro aplicado
# depois de ler. Sem isso, um id de recibo alheio devolveria a fila de outra
# pessoa: é a lição do achado ING-01.


class StagingReceiptSummary(BaseModel):
    staging_receipt_id: str
    source: str
    status: str
    store_name: str | None = None
    issued_at: date | None = None
    total_gross: Decimal | None = None
    discount_total: Decimal | None = None
    amount_paid: Decimal | None = None
    total_computed: Decimal | None = None
    divergence_cents: int | None = None
    total_lines: int
    lines_to_review: int
    lines_skipped: int
    unmatched_lines: int


class StagingLine(BaseModel):
    id: str
    line_no: int
    description_raw: str
    store_code: str | None = None
    sale_unit: str
    quantity: Decimal
    unit_price: Decimal
    discount_line: Decimal
    line_total: Decimal
    product_id: str | None = None
    presentation_id: str | None = None
    match_source: str
    review_state: str
    reviewed: bool
    match_note: str | None = None
    # `match_note` é texto do banco: o matcher grava JSON com o motivo e, na
    # ambiguidade, a lista de candidatos. Vai cru E interpretado, para a tela não
    # reimplementar o parsing e para o texto legado continuar legível.
    match_note_parsed: dict | None = None


class StagingReviewProgress(BaseModel):
    total: int
    resolved: int
    pending: int
    skipped: int
    consolidated: int | None = None  # chega junto com a consolidação (item 3)


class StagingReceiptLines(BaseModel):
    receipt_id: str
    progress: StagingReviewProgress
    lines: list[StagingLine]


STAGING_QUEUE_SQL = """
    SELECT vq.staging_receipt_id, vq.source, vq.status, vq.store_name, sr.issued_at,
           vq.total_gross, vq.discount_total, vq.amount_paid, vq.total_computed,
           vq.divergence_cents, vq.total_lines, vq.lines_to_review, vq.lines_skipped,
           vq.unmatched_lines
    FROM v_review_queue vq
    JOIN staging_receipts sr ON sr.id = vq.staging_receipt_id
    WHERE vq.user_id = %s
    ORDER BY abs(coalesce(vq.divergence_cents, 0)) DESC, vq.unmatched_lines DESC,
             sr.issued_at DESC NULLS LAST
"""

STAGING_LINES_SQL = """
    SELECT sl.id, sl.line_no, sl.description_raw, sl.store_code, sl.sale_unit,
           sl.quantity, sl.unit_price, sl.discount_line, sl.line_total,
           sl.product_id, sl.presentation_id, sl.match_source, sl.review_state,
           sl.reviewed, sl.match_note
    FROM staging_lines sl
    WHERE sl.receipt_id = %s
    ORDER BY sl.line_no
"""


def _match_note_parsed(text: str | None) -> dict | None:
    """O `match_note` como objeto quando ele é JSON; None quando é texto legado."""
    if not text:
        return None
    try:
        parsed = json.loads(text)
    except (TypeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


@app.get("/staging/receipts", response_model=list[StagingReceiptSummary])
def list_staging_receipts(user_id: str = Depends(get_current_user_id)):
    """Recibos deste titular ainda na fila de revisão, com os contadores.

    Reusa `v_review_queue` de propósito: o que é "estar na fila" é definição do
    banco, em um lugar só, e não uma segunda interpretação escrita aqui.
    """
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(STAGING_QUEUE_SQL, (user_id,))
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()


@app.get("/staging/receipts/{receipt_id}/lines", response_model=StagingReceiptLines)
def list_staging_lines(receipt_id: str, user_id: str = Depends(get_current_user_id)):
    """Linhas de um recibo deste titular: estado de revisão e candidatos.

    Confere primeiro se o recibo é deste titular e só então lê as linhas. Recibo
    de outro titular devolve 404 -- e não 403, que confirmaria que ele existe.
    """
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT 1 FROM staging_receipts WHERE id = %s AND user_id = %s",
                    (receipt_id, user_id))
        if cur.fetchone() is None:
            raise HTTPException(status_code=404, detail="Recibo não encontrado")
        cur.execute(STAGING_LINES_SQL, (receipt_id,))
        rows = cur.fetchall()
    except psycopg2.errors.InvalidTextRepresentation:
        # Id que nem UUID é: o mesmo 404, sem vazar o motivo.
        raise HTTPException(status_code=404, detail="Recibo não encontrado")
    finally:
        cur.close()
        conn.close()

    lines = [{**row, "match_note_parsed": _match_note_parsed(row.get("match_note"))} for row in rows]
    # Dict, não instância do modelo: a função devolve dados uniformes e quem valida
    # o contrato é o `response_model`, na borda HTTP.
    progress = {
        "total": len(lines),
        "resolved": sum(1 for row in lines if row["review_state"] in ("CONFIRMED", "NO_MATCH")),
        "pending": sum(1 for row in lines if row["review_state"] == "PENDING"),
        "skipped": sum(1 for row in lines if row["review_state"] == "SKIPPED"),
        "consolidated": None,
    }
    return {"receipt_id": receipt_id, "progress": progress, "lines": lines}
