from fastapi import FastAPI, HTTPException, Query, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from database import get_connection
from datetime import date, datetime
from typing import Literal, Any, cast
from auth import verify_password, create_access_token, create_refresh_token, get_current_user_id
import psycopg2
import psycopg2.errors
import uuid

app = FastAPI()

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

@app.post("/products", response_model=Product, status_code=201)
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

@app.put("/products/{product_id}", response_model=Product)
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

@app.delete("/products/{product_id}", status_code=204)
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
    email: str

@app.get("/users", response_model=list[User])
def list_users():
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, email FROM users ORDER BY email")
    users = cur.fetchall()
    cur.close()
    conn.close()
    return users

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
    password: str

@app.post("/login")
def login(data: LoginRequest):
    #1. Buscar usuário pelo email
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, email FROM users WHERE email = %s", (data.email)) # Selecionando EMAIL
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
    if not verify_password(data.password, credential["password_hash"]):
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

