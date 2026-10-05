#!/usr/bin/env python3
"""
Prepara o `.env` de UM worktree a partir do modelo versionado.

Por que existe
--------------
`.env` nunca e versionado (segredo nao entra no git), mas `docker compose`
exige `DB_PASSWORD`. Um worktree novo nasce sem `.env` e o caminho
documentado no README para ate alguem repetir a mao o passo:

    cp .env.example .env   # e editar DB_PASSWORD

Este comando faz esse passo de forma repetivel, sem inventar nem copiar
segredo e sem imprimir valor de variavel.

O que ele faz
-------------
1. Acha a raiz do worktree (`git rev-parse --show-toplevel`), entao rodar de
   dentro de qualquer subdiretorio escreve no lugar certo.
2. Confere que `.env` esta fora do controle de versao (`.gitignore` e
   `git check-ignore`) antes de escrever qualquer coisa.
3. Se `.env` NAO existe, copia `.env.example` -> `.env` byte a byte. O
   arquivo nasce com os valores do modelo; nenhum segredo e gerado.
4. Se `.env` JA existe, nao toca no arquivo. Rodar varias vezes e seguro.
5. Compara com `.env.example` e diz, chave por chave, o que ainda esta no
   valor do modelo e como resolver.

O que ele NAO faz
-----------------
- Nao procura, nao le e nao copia `.env` de outro worktree. Credencial nao
  atravessa worktree: gerar e gravar o valor e passo do operador.
- Nao imprime valor de variavel (nem mascarado): a saida pode ir para card
  ou log sem vazar segredo.
- Nao sobrescreve `.env` existente -- nem em `--check`.
- Nao altera `docker-compose.yml`, nome de projeto Compose, volume ou
  container.

Exit code
---------
0  ambiente preparado, sem pendencia obrigatoria
1  `.env` garantido (ou diagnosticado em `--check`), mas falta configuracao
   obrigatoria -- acao humana pendente
2  erro de ambiente: nao e worktree git, `.env` versionado ou nao ignorado,
   `.env.example` ausente, `.env` como symlink

Uso
---
    python scripts/prepare_env.py             # prepara o worktree atual
    python scripts/prepare_env.py --check     # so confere; nao escreve
    python scripts/prepare_env.py --repo <dir> --check
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

MODELO = ".env.example"
ARQUIVO = ".env"

# Sem esta o caminho documentado nao sobe: docker-compose.yml usa
# ${DB_PASSWORD:?defina DB_PASSWORD no .env -- veja .env.example}.
OBRIGATORIAS: tuple[str, ...] = ("DB_PASSWORD",)

# Ainda no valor do modelo, mas exigidas so nas fases seguintes (a API e a
# ingestao de NFC-e nao existem). Ficam visiveis para nao virarem surpresa.
FASES_SEGUINTES: tuple[str, ...] = ("SECRET_KEY", "SEFAZ_CSC_POR_LOJA")

MOTIVO = {
    "DB_PASSWORD": "obrigatoria -- `docker compose up` falha sem ela",
    "SECRET_KEY": "fase seguinte (API) -- assinatura de sessao, min. 32 bytes",
    "SEFAZ_CSC_POR_LOJA": 'fase seguinte (NFC-e) -- CSC por loja, JSON {"<CNPJ>": "<CSC>"}',
}

COMO_GERAR = {
    "DB_PASSWORD": "openssl rand -base64 32",
    "SECRET_KEY": "openssl rand -base64 32",
}


class Erro(Exception):
    """Erro de ambiente -- exit code 2."""


def raiz_do_worktree(inicio: Path) -> Path:
    """Raiz do worktree que contem `inicio` (funciona em git worktree linkado)."""
    if not inicio.is_dir():
        raise Erro(f"'{inicio}' nao existe")
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=inicio, capture_output=True, text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise Erro(f"'{inicio}' nao e um worktree git (git rev-parse --show-toplevel falhou)")
    return Path(out.stdout.strip())


def checar_fora_do_git(raiz: Path) -> str | None:
    """None se `.env` esta fora do controle de versao; senao, o motivo."""
    versionado = subprocess.run(
        ["git", "ls-files", "--error-unmatch", ARQUIVO],
        cwd=raiz, capture_output=True, text=True,
    )
    if versionado.returncode == 0:
        return (
            f"{ARQUIVO} esta versionado no git -- credencial nunca entra no "
            "repositorio; remova do indice antes de preparar o worktree"
        )
    ignorado = subprocess.run(["git", "check-ignore", "-q", ARQUIVO], cwd=raiz)
    if ignorado.returncode != 0:
        return (
            f"{ARQUIVO} nao esta ignorado pelo .gitignore -- sem isso o git "
            "pode versionar a credencial"
        )
    return None


def ler_env(texto: str) -> dict[str, str]:
    """Le `chave=valor` de um arquivo de ambiente, ignorando comentario e vazio."""
    valores: dict[str, str] = {}
    for linha in texto.splitlines():
        s = linha.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        chave, _, valor = s.partition("=")
        valores[chave.strip()] = valor.strip()
    return valores


def pendente(valores: dict[str, str], modelo: dict[str, str], chave: str) -> bool:
    """True se a chave esta ausente, vazia ou ainda com o valor do modelo."""
    valor = valores.get(chave)
    if valor is None or valor == "":
        return True
    return chave in modelo and valor == modelo[chave]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="prepare_env.py",
        description=(
            "Prepara o .env de um worktree a partir do .env.example. "
            "Nunca versiona credencial, nunca copia .env de outro worktree e "
            "nunca imprime valor de variavel."
        ),
        epilog="exit 0 pronto | 1 falta configuracao obrigatoria | 2 erro de ambiente",
    )
    ap.add_argument("--repo", default=".", help="worktree alvo (default: o diretorio atual)")
    ap.add_argument("--check", action="store_true", help="nao escreve nada; so confere e orienta")
    args = ap.parse_args(argv)

    try:
        raiz = raiz_do_worktree(Path(args.repo).resolve())
        modelo_path = raiz / MODELO
        env_path = raiz / ARQUIVO

        if not modelo_path.is_file():
            raise Erro(f"{MODELO} nao existe em {raiz} -- sem o modelo nao ha o que copiar")
        problema = checar_fora_do_git(raiz)
        if problema:
            raise Erro(problema)
        if env_path.is_symlink():
            raise Erro(
                f"{ARQUIVO} e um symlink para '{os.readlink(env_path)}' -- segredo "
                "compartilhado entre worktrees nao e suportado; remova o link e rode de novo"
            )
    except Erro as e:
        print(f"prepare_env: {e}", file=sys.stderr)
        return 2

    modelo = ler_env(modelo_path.read_text(encoding="utf-8"))
    faltam_no_modelo = [c for c in OBRIGATORIAS + FASES_SEGUINTES if c not in modelo]
    if faltam_no_modelo:
        print(
            f"prepare_env: {MODELO} nao declara {', '.join(faltam_no_modelo)} -- "
            "modelo e o comando estao divergentes",
            file=sys.stderr,
        )
        return 2

    tinha_arquivo = env_path.exists()
    criado = False
    if not tinha_arquivo and not args.check:
        env_path.write_bytes(modelo_path.read_bytes())
        try:
            os.chmod(env_path, 0o600)
        except OSError:
            pass  # /mnt/c (drvfs) ignora chmod; la o ACL do Windows e que vale
        criado = True

    existe_agora = env_path.exists()
    if existe_agora:
        valores = ler_env(env_path.read_text(encoding="utf-8"))
        digest = hashlib.sha256(env_path.read_bytes()).hexdigest()[:12]
    else:
        valores = {}
        digest = None

    print(f"prepare_env: worktree {raiz}")
    if criado:
        print(
            f"prepare_env: {ARQUIVO} criado a partir de {MODELO} "
            "(byte a byte: valores do modelo, nenhum segredo gerado ou copiado)"
        )
    elif tinha_arquivo:
        print(f"prepare_env: {ARQUIVO} ja existia -- preservado sem alteracao (sha256 {digest})")
    else:
        print(f"prepare_env: {ARQUIVO} ausente (--check: nada foi escrito)")

    pendentes_obrigatorias = [c for c in OBRIGATORIAS if pendente(valores, modelo, c)]
    pendentes_futuras = [c for c in FASES_SEGUINTES if pendente(valores, modelo, c)]

    print("\nVALIDACAO (valor nunca e impresso)")
    for chave in OBRIGATORIAS + FASES_SEGUINTES:
        estado = "PENDENTE" if pendente(valores, modelo, chave) else "ok"
        print(f"  {chave:<20} {estado:<9} {MOTIVO[chave]}")

    todas_pendentes = pendentes_obrigatorias + pendentes_futuras
    if todas_pendentes:
        print("\nCOMO RESOLVER (edite o arquivo; nao cole segredo em card, log ou chat)")
        for chave in todas_pendentes:
            etiqueta = "  [obrigatoria]" if chave in OBRIGATORIAS else ""
            print(f"  {chave}{etiqueta}")
            if chave in COMO_GERAR:
                print(f"    gere:  {COMO_GERAR[chave]}")
            print(f"    grave: abra {env_path} e substitua o valor de {chave}")
    if criado:
        print(
            "\nNOTA  a senha do Postgres vale na criacao do volume `pgdata`: se o projeto "
            "Compose deste worktree ja subiu com outra senha, o login falha -- recriar o "
            "volume apaga os dados (docker compose down -v)."
        )
        print(
            "NOTA  o container e fixo em `home_shopper-db` (docker-compose.yml), o mesmo do "
            "checkout principal: os dois bancos nao sobem ao mesmo tempo. Nao remova o "
            "container canonico para abrir espaco."
        )

    if pendentes_obrigatorias:
        print(f"\nSTATUS: pendente ({len(pendentes_obrigatorias)} obrigatoria) -- exit 1")
        return 1
    print("\nSTATUS: pronto -- exit 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
