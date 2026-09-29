#!/usr/bin/env python3
"""
Guard de dados sensiveis.

Falha (exit 1) se qualquer arquivo versionado contiver dado que identifica
pessoa fisica. Roda no pre-commit e na CI: o erro nao pode depender de
alguem lembrar de rodar.

O que e considerado sensivel:
  - chave de acesso de NFC-e (44 digitos) nao composta so de zeros
  - CPF: 11 digitos, nao composto so de zeros
  - CNPJ: 14 digitos, nao composto so de zeros

Por que chave de acesso e dado pessoal
--------------------------------------
A chave de acesso e o identificador natural da NFC-e. Quem a possui
consulta a nota na SEFAZ sem autenticacao e obtem CPF do consumidor,
endereco de entrega, itens e valores. E a porta de entrada para os dados
do consumidor, nao um id interno do sistema. Por isso nunca versionada.

O que NAO e considerado sensivel aqui
-------------------------------------
CNPJ de supermercado e dado publico de empresa (visivel no cupom e no
cadastro da Receita). Este guard ainda assim o sinaliza, porque num
projeto pessoal o custo de revisar e zero e o risco de publishar um
fixture com dados de terceiro nao vale. Ajuste a lista se precisar.

Uso
---
    python scripts/guard_dados_sensiveis.py            # varre o repo
    python scripts/guard_dados_sensiveis.py --staged   # so o que vai pro commit
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Extensoes que nunca contem dado de negocio
IGNORAR_SUFIXOS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".woff", ".woff2", ".ttf", ".eot", ".mp4", ".mp3",
}

# Extensoes varridas
VARRER = {
    ".py", ".sql", ".json", ".yaml", ".yml", ".md", ".txt", ".env",
    ".example", ".sh", ".toml", ".ini", ".cfg", ".html", ".js", ".ts",
}

# Padroes. Cada um: (nome, regex, funcao de predicao do falso positivo)
PADROES: list[tuple[str, re.Pattern[str], object]] = [
    (
        "chave de acesso NFC-e (44 digitos)",
        re.compile(r"(?<![\d.])\d{44}(?![\d.])"),
        lambda m: set(m.group()) != {"0"},
    ),
    (
        "CPF (11 digitos)",
        re.compile(r"(?<![\d.])\d{11}(?![\d.])"),
        # Filtra sequencias obviousemente sinteticas
        lambda m: set(m.group()) != {"0"}
        and not (m.group().isdigit() and len(set(m.group())) == 1),
    ),
    (
        "CNPJ (14 digitos)",
        re.compile(r"(?<![\d.])\d{14}(?![\d.])"),
        lambda m: set(m.group()) != {"0"},
    ),
]

# Chaves de ambiente nao entram no guard: e o lugar LEGITIMO de um segredo.
ARQUIVOS_PERMITIDOS_SENHA = {".env.example", ".gitignore"}


class Achado:
    __slots__ = ("arquivo", "linha", "regra", "trecho")

    def __init__(self, arquivo: str, linha: int, regra: str, trecho: str):
        self.arquivo = arquivo
        self.linha = linha
        self.regra = regra
        self.trecho = trecho

    def __str__(self) -> str:
        # Mascarado: o guard existe para nao REPETIR o dado no log.
        mascarado = self.trecho[:4] + "*" * max(0, len(self.trecho) - 8) + self.trecho[-4:]
        return f"  {self.arquivo}:{self.linha}  {self.regra}  -> {mascarado}"


def varrer_texto(nome: str, texto: str) -> list[Achado]:
    achados: list[Achado] = []
    for num, linha in enumerate(texto.splitlines(), start=1):
        for regra, regex, e_falso_positivo in PADROES:
            for m in regex.finditer(linha):
                if e_falso_positivo(m):
                    achados.append(Achado(nome, num, regra, m.group()))
    return achados


def arquivos_staged(repo: Path) -> list[Path]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
        cwd=repo, capture_output=True, text=True, check=True,
    )
    return [repo / linha for linha in out.stdout.splitlines() if linha.strip()]


def arquivos_do_repo(repo: Path) -> list[Path]:
    alvos = []
    for p in repo.rglob("*"):
        if not p.is_file():
            continue
        partes = set(p.parts)
        if partes & {".git", "node_modules", ".venv", "__pycache__"}:
            continue
        if p.name in ARQUIVOS_PERMITIDOS_SENHA:
            continue
        if p.suffix.lower() in IGNORAR_SUFIXOS:
            continue
        if p.suffix.lower() in VARRER or p.name in {".env", ".gitignore"}:
            alvos.append(p)
    return alvos


def main() -> int:
    ap = argparse.ArgumentParser(description="Bloqueia dado pessoal no repositorio")
    ap.add_argument("--staged", action="store_true", help="verifica so o staged")
    ap.add_argument("--repo", default=".", help="raiz do repositorio")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists() and not (repo / ".git").is_file():
        print(f"guard: '{repo}' nao e um repositorio git", file=sys.stderr)
        return 2

    arquivos = arquivos_staged(repo) if args.staged else arquivos_do_repo(repo)
    achados: list[Achado] = []
    for p in arquivos:
        try:
            texto = p.read_text(encoding="utf-8", errors="strict")
        except (UnicodeDecodeError, OSError):
            continue
        achados.extend(varrer_texto(str(p.relative_to(repo)), texto))

    if not achados:
        print(f"guard: OK -- {len(arquivos)} arquivo(s) verificado(s), nenhum dado pessoal")
        return 0

    print("guard: FALHOU -- dado pessoal encontrado no que seria versionado\n")
    for a in achados[:50]:
        print(a)
    if len(achados) > 50:
        print(f"  ... e mais {len(achados) - 50}")
    print(
        "\nComo resolver:\n"
        "  1. Mova o dado real para fora do repo (.env, dados_reais/ -- ver .gitignore)\n"
        "  2. Substitua por um valor anonimo preservando o FORMATO\n"
        "     (ex.: chave de 44 digitos -> 44 zeros; CPF -> 11 zeros)\n"
        "  3. Se a forma anonima quebrar um teste, o teste esta verificando\n"
        "     o dado em vez da logica. Corrija o teste."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
