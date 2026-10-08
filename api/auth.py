import os
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import JWTError, jwt
from passlib.context import CryptContext

# ─── Configurações ───────────────────────────────────────────────────────────

# Pepper: valor secreto global, fica no .env (fora do banco)
PEPPER = os.environ.get("AUTH_PEPPER", "")

# Secret key para assinar os JWTs
SECRET_KEY = os.environ.get("JWT_SECRET_KEY", "")
ALGORITHM = "HS256"

# Durações
ACCESS_TOKEN_EXPIRE_MINUTES = 60        # 1 hora
REFRESH_TOKEN_EXPIRE_DAYS = 30          # 30 dias

# ─── Hash de senha (bcrypt + salt automático + pepper) ──────────────────────

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    # Gera o hash bcrypt da senha + pepper.
    # O bcrypt gera um salt aleatório automaticamente e o inclui no hash.
    return pwd_context.hash(password + PEPPER)


def verify_password(password: str, hashed: str) -> bool:
    # Verifica se a senha digitada bate com o hash armazenado.
    return pwd_context.verify(password + PEPPER, hashed)


# ─── Criação de tokens ──────────────────────────────────────────────────────


def create_access_token(user_id: str) -> str:
    #Gera um JWT de acesso (1 hora).
    expire = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {
        "sub": user_id,
        "exp": expire,
        "type": "access",
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def create_refresh_token(user_id: str) -> str:
    #Gera um JWT de refresh (30 dias).
    expire = datetime.now(timezone.utc) + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": user_id,
        "exp": expire,
        "type": "refresh",
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


# ─── Validação de tokens ────────────────────────────────────────────────────


def verify_access_token(token: str) -> str:
    # Valida um access token e retorna o user_id.
    # Lança HTTPException 401 se o token for inválido ou expirado.
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("type") != "access":
            raise HTTPException(status_code=401, detail="Tipo de token inválido")
        return payload["sub"]
    except JWTError:
        raise HTTPException(status_code=401, detail="Token inválido ou expirado")


def verify_refresh_token(token: str) -> str:
    # Valida um refresh token e retorna o user_id.
    # Lança HTTPException 401 se o token for inválido ou expirado.
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("type") != "refresh":
            raise HTTPException(status_code=401, detail="Tipo de token inválido")
        return payload["sub"]
    except JWTError:
        raise HTTPException(status_code=401, detail="Token inválido ou expirado")


# ─── Dependência do FastAPI ─────────────────────────────────────────────────

security = HTTPBearer()


def get_current_user_id(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    """Dependência do FastAPI que extrai e valida o token do header.
    Uso: def rota_protegida(user_id: str = Depends(get_current_user_id))
    """
    return verify_access_token(credentials.credentials)
