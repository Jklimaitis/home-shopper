import os
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import JWTError, jwt
import bcrypt

# ─── Configurações ───────────────────────────────────────────────────────────

def _required_setting(name: str) -> str:
    value = os.environ.get(name)
    if value is None or not value.strip():
        raise RuntimeError(f"Configuracao obrigatoria ausente ou vazia: {name}")
    return value


# Validate at import, before the application can serve any request.
PEPPER = _required_setting("AUTH_PEPPER")
SECRET_KEY = _required_setting("JWT_SECRET_KEY")
if len(SECRET_KEY.encode("utf-8")) < 32:
    raise RuntimeError("JWT_SECRET_KEY deve ter no minimo 32 bytes")
if len(PEPPER.encode("utf-8")) >= 72:
    raise RuntimeError("AUTH_PEPPER deve deixar espaco para a senha no limite do bcrypt")
ALGORITHM = "HS256"


def _configured_catalog_admins() -> frozenset[str]:
    raw = os.environ.get("CATALOG_ADMIN_USER_IDS", "")
    if not raw.strip():
        return frozenset()
    try:
        return frozenset(str(UUID(value.strip())) for value in raw.split(","))
    except ValueError:
        raise RuntimeError("CATALOG_ADMIN_USER_IDS deve conter UUIDs separados por virgula") from None


CATALOG_ADMIN_IDS = _configured_catalog_admins()

# Durações
ACCESS_TOKEN_EXPIRE_MINUTES = 60        # 1 hora
REFRESH_TOKEN_EXPIRE_DAYS = 30          # 30 dias

# ─── Hash de senha (bcrypt + salt automático + pepper) ──────────────────────

def _password_bytes(password: str) -> bytes:
    if not isinstance(password, str) or not password:
        raise ValueError("Senha deve ser uma string nao vazia")
    # Preserve the encoding of existing bcrypt(password + pepper) hashes.
    encoded = (password + PEPPER).encode("utf-8")
    if len(encoded) > 72:
        raise ValueError("Senha e pepper excedem o limite de 72 bytes do bcrypt")
    return encoded


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_password_bytes(password), bcrypt.gensalt(rounds=12)).decode("ascii")


def verify_password(password: str, hashed: str) -> bool:
    if not isinstance(hashed, str):
        return False
    try:
        return bcrypt.checkpw(_password_bytes(password), hashed.encode("ascii"))
    except ValueError:
        # Invalid input/hash is an authentication failure, never a leaked backend error.
        return False


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


def _verify_token(token: str, expected_type: str) -> str:
    try:
        payload = jwt.decode(
            token, SECRET_KEY, algorithms=[ALGORITHM],
            options={"require_exp": True, "require_sub": True},
        )
        if payload.get("type") != expected_type:
            raise JWTError("Unexpected token type")
        return str(UUID(payload["sub"]))
    except (JWTError, ValueError, TypeError):
        raise HTTPException(
            status_code=401, detail="Token invalido ou expirado",
            headers={"WWW-Authenticate": "Bearer"},
        ) from None


def verify_access_token(token: str) -> str:
    return _verify_token(token, "access")


def verify_refresh_token(token: str) -> str:
    return _verify_token(token, "refresh")


# ─── Dependência do FastAPI ─────────────────────────────────────────────────

security = HTTPBearer(auto_error=False)


def get_current_user_id(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> str:
    if credentials is None:
        raise HTTPException(
            status_code=401, detail="Autenticacao obrigatoria", headers={"WWW-Authenticate": "Bearer"},
        )
    return verify_access_token(credentials.credentials)


def require_catalog_admin(user_id: str = Depends(get_current_user_id)) -> str:
    # Authentication alone must not grant write access to the shared catalogue.
    if user_id not in CATALOG_ADMIN_IDS:
        raise HTTPException(status_code=403, detail="Escrita no catalogo nao autorizada")
    return user_id
