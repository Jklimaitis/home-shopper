#!/usr/bin/env python3
"""
Guard de dados sensiveis.

Bloqueia (exit 1) os padroes de CPF e chave fiscal no indice Git.
O modo padrao verifica todos os arquivos indexados; --staged limita aos
adicionados/modificados. Nao le copias unstaged e nao instala hooks.
Erros de leitura, conflitos ou indice alterado retornam 2, nunca aprovacao.
Este controle textual nao substitui scanner de segredos nem auditoria de toda PII.

O que e considerado sensivel:
  - chave de acesso de NFC-e (44 digitos) nao composta so de zeros
  - CPF: 11 digitos, nao composto so de zeros

Por que chave de acesso e dado pessoal
--------------------------------------
A chave de acesso e o identificador natural da NFC-e. Quem a possui
consulta a nota na SEFAZ sem autenticacao e obtem CPF do consumidor,
endereco de entrega, itens e valores. E a porta de entrada para os dados
do consumidor, nao um id interno do sistema. Por isso nunca versionada.

O formato da chave EMBUTE o CNPJ do emitente (posicoes 7-20), mas isso
nao muda a conclusao: a chave carrega tambem os dados do consumidor, e
por isso continua bloqueada. Ver "Por que CNPJ nao e sensivel" abaixo.

Por que CNPJ NAO e sensivel
----------------------------
CNPJ identifica uma PESSOA JURIDICA, nao uma pessoa fisica. O cadastro
e publico: qualquer um consulta na Receita Federal sem autenticacao, o
numero esta impresso no cupom de compra e na fachada do estabelecimento.
A LGPD protege dado pessoal -- e dado de empresa nao e dado pessoal.

Um CNPJ de supermercado, portanto, nao e segredo. Sanitiza-lo nao
protegia ninguem: o mesmo numero pode ser buscado em segundos. Guardar
um CNPJ real em fixture e normal, e o dado fica util para o portfolio
(um `stores` com redes reais e o que da credibilidade ao projeto).

Isto NAO se aplica a um CNPJ de MEI ou de pessoa fisica em que o
proprietario e o proprio titular -- nesse caso o CNPJ funciona como
identificador individual. O guard sinaliza CPF e chave de acesso, que
cobrem esse risco.

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

# Formatos binarios fora desta verificacao textual (nao e um scanner OCR).
IGNORAR_SUFIXOS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".woff", ".woff2", ".ttf", ".eot", ".mp4", ".mp3",
}

# Padroes. Cada um: (nome, regex, funcao de predicao do falso positivo)
#
# NAO ha padrao de CNPJ aqui, de proposito. CNPJ identifica pessoa juridica
# e o cadastro e publico -- sanitiza-lo nao protege ninguem. Um CNPJ real de
# supermercado em fixture e legivel e correto. O que protege a pessoa fisica
# (CPF, chave de acesso) segue bloqueado abaixo.
#
# IMPORTANTE: chave e CPF sao checadas nas DUAS formas, com e sem
# pontuacao. Um guard que so enxerga 44 digitos seguidos deixa passar a
# chave escrita no formato oficial, que e como a pessoa copia do app
# da SEFAZ -- ou seja, como ela chega na pratica.
PADROES: list[tuple[str, re.Pattern[str], object]] = [
    (
        "chave de acesso NFC-e (44 digitos)",
        re.compile(r"(?<![\d.])\d{44}(?![\d.])"),
        lambda m: set(m.group()) != {"0"},
    ),
    (
        "chave de acesso NFC-e (formatada, com hifens)",
        # Layout oficial: 2-4-14-2-3-9-9-1 = 44 digitos em 8 grupos.
        re.compile(r"(?<![\d-])\d{2}-\d{4}-\d{14}-\d{2}-\d{3}-\d{9}-\d{9}-\d(?![\d-])"),
        lambda m: set(m.group().replace("-", "")) != {"0"},
    ),
    (
        "CPF (11 digitos)",
        re.compile(r"(?<![\d.])\d{11}(?![\d.])"),
        # Filtra sequencias obviousemente sinteticas
        lambda m: set(m.group()) != {"0"}
        and not (m.group().isdigit() and len(set(m.group())) == 1),
    ),
    (
        "CPF (formatado, com pontos e hifen)",
        re.compile(r"(?<![\d.])\d{3}\.\d{3}\.\d{3}-\d{2}(?![\d.-])"),
        lambda m: set(m.group().replace(".", "").replace("-", "")) != {"0"},
    ),
]


# Only a complete packaging SHA-256 token classifies its 64 hex digits as
# checksum data. Never exempt a whole line/file or arbitrary hexadecimal text.
HASH_SHA256 = re.compile(r"(?<!\S)--hash=sha256:([a-fA-F0-9]{64})(?=\s|$)")


class Achado:
    __slots__ = ("arquivo", "linha", "regra", "trecho")

    def __init__(self, arquivo: str, linha: int, regra: str, trecho: str):
        self.arquivo = arquivo
        self.linha = linha
        self.regra = regra
        self.trecho = trecho

    def __str__(self) -> str:
        # Report location and rule, never identifier values or fragments.
        arquivo = repr(self.arquivo) if any(char in self.arquivo for char in "\n\r\t") else self.arquivo
        return f"  {arquivo}:{self.linha}  {self.regra}  (valor omitido)"


def varrer_texto(nome: str, texto: str) -> list[Achado]:
    achados: list[Achado] = []
    for num, linha in enumerate(texto.splitlines(), start=1):
        checksums = [match.span(1) for match in HASH_SHA256.finditer(linha)]
        for regra, regex, e_falso_positivo in PADROES:
            for m in regex.finditer(linha):
                if regra == "CPF (11 digitos)" and any(
                    start <= m.start() and m.end() <= end for start, end in checksums
                ):
                    continue
                if e_falso_positivo(m):
                    achados.append(Achado(nome, num, regra, m.group()))
    return achados


def _git(repo: Path, *args: str) -> bytes:
    return subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, check=True,
    ).stdout


def indice_git(repo: Path) -> tuple[bytes, dict[str, str], set[str]]:
    snapshot = _git(repo, "ls-files", "--stage", "-z")
    arquivos: dict[str, str] = {}
    gitlinks: set[str] = set()
    for entry in snapshot.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, oid, stage = metadata.decode("ascii").split()
        if stage != "0":
            raise ValueError("Indice com conflitos nao resolvidos")
        decoded_name = name.decode("utf-8", errors="surrogateescape")
        if mode == "160000":  # Submodule content belongs to its own repository.
            gitlinks.add(decoded_name)
            continue
        arquivos[decoded_name] = oid
    return snapshot, arquivos, gitlinks


def arquivos_staged(repo: Path) -> list[str]:
    out = _git(repo, "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    return [name.decode("utf-8", errors="surrogateescape")
            for name in out.split(b"\0") if name]


def arquivos_do_repo(repo: Path) -> list[str]:
    return list(indice_git(repo)[1])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Bloqueia dado pessoal no repositorio")
    ap.add_argument("--staged", action="store_true", help="verifica so o staged")
    ap.add_argument("--repo", default=".", help="raiz do repositorio")
    args = ap.parse_args(argv)

    achados: list[Achado] = []
    verificados = 0
    try:
        initial = Path(args.repo).resolve()
        repo = Path(_git(initial, "rev-parse", "--show-toplevel").decode("utf-8").strip())
        snapshot, indice, gitlinks = indice_git(repo)
        arquivos = arquivos_staged(repo) if args.staged else list(indice)
        for name in arquivos:
            if name in gitlinks:
                continue
            # Read the immutable indexed blob, not the mutable working copy.
            blob = _git(repo, "cat-file", "blob", indice[name])
            try:
                texto = blob.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                if Path(name).suffix.lower() in IGNORAR_SUFIXOS:
                    continue  # Recognized binary format; no OCR/content extraction here.
                raise
            verificados += 1
            achados.extend(varrer_texto(name, texto))
        if _git(repo, "ls-files", "--stage", "-z") != snapshot:
            raise ValueError("Indice mudou durante a verificacao")
    except (OSError, subprocess.CalledProcessError, UnicodeError, ValueError, KeyError):
        print("guard: ERRO -- nao foi possivel verificar integralmente o indice Git", file=sys.stderr)
        return 2

    if not achados:
        print(f"guard: OK -- {verificados} arquivo(s) do indice verificado(s), nenhum padrao bloqueado")
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
        "     o dado em vez da logica. Corrija o teste.\n"
        "\n"
        "  CNPJ de pessoa juridica NAO e sinalizado: e dado publico e\n"
        "  sanitiza-lo nao protege ninguem. Ele nao pertence a esta lista."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
