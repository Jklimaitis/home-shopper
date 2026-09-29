# home_shopper

Monitor de preços de supermercados: catálogo canônico, comparação de preços
entre redes e dashboard analítico.

> **Status:** fase de modelagem de dados. O schema e os testes de domínio estão
> prontos e verificados; a API ainda não existe.

---

## O problema

Comparar o preço do mesmo produto entre redes é enganoso por três motivos, e
este projeto resolve os três:

**1. O mesmo produto tem nomes diferentes em cada mercado.**
`LEITE UHT HERCULES 1000ML` e `LT INT HERC 1L` são o mesmo leite. Normalizar
texto não resolve: `HERC` nunca vira `HERCULES` por regra de texto.
Equivalência é **fato aprendido**, e fato aprendido mora em tabela
(`sinonimo`, `apresentacao`), não em código.

**2. O mesmo produto é vendido em unidades diferentes.**
R$ 5,49 por `UN` e R$ 59,88 por `CX` de 12 não são 10× diferentes — são o
mesmo preço. Todo preço é reexpresso na **unidade base** do produto
(`preco_base`) antes de qualquer comparação.

**3. Produto fresco não tem código de barras.**
Em uma nota real analisada, **0 de 14 itens tinham EAN** — o código impresso
é interno da rede. A identidade real é `marca + nome normalizado + tamanho`.

---

## Estado atual

```
14 tabelas · 4 views · 48 índices · 14 triggers · 4 enums
```

Tudo criado em PostgreSQL 16 e verificado por um smoke test que usa uma NFC-e
real (anonimizada) como fixture.

| Verificação | Resultado |
|---|---|
| Checksum contábil da nota | `337,00 = 337,00`, divergência 0 |
| Preço canônico (250 g vs 1 kg) | Kani `0,043600/g` · Cupim `0,039900/g` |
| Trigger recusa item sem apresentação | PASS |
| Idempotência por chave de acesso | PASS |
| `NUMERIC` vs `float` | float erra `5,5e-17` · NUMERIC erra `0` |
| Fila de revisão humana | 8 de 14 itens sem match |
| Views | 4 respondem |

---

## Rodar

```bash
docker compose up -d          # Postgres 16
psql -h localhost -U home_shopper -d home_shopper \
     -v ON_ERROR_STOP=1 -f db/001_schema.sql
```

Testes:

```bash
psql -h localhost -U home_shopper -d home_shopper \
     -v ON_ERROR_STOP=1 -f tests/smoke_test.sql
```

---

## Dados sensíveis

A **chave de acesso da NFC-e é dado pessoal**, não um id interno: quem a tem
consulta a nota na SEFAZ sem autenticação e obtém CPF do consumidor,
endereço e histórico de compras.

Por isso o repositório contém **apenas fixtures anonimizados**, e existe um
guard que impede o vazamento:

```bash
python scripts/guard_dados_sensiveis.py          # varre tudo
python scripts/guard_dados_sensiveis.py --staged # só o que vai pro commit
```

Ele roda no pre-commit e na CI. Anonimizar preserva o **formato** (44 dígitos
viram 44 zeros), então o checksum e as validações continuam funcionando de
verdade.

Segredos de verdade ficam em `.env` (veja `.env.example`), nunca no código.

---

## Documentação

- [`docs/ERD.md`](docs/ERD.md) — diagrama Mermaid e as três decisões centrais
- `docs/DECISOES.md` — ADRs (planejado)

---

## Pipeline planejado

```
FastAPI → PostgreSQL → Celery (fila) → PostgreSQL → dashboard
```

O ganho próprio sobre um "price tracker" genérico está na última etapa:
detectar queda de preço e **acionar a comunicação** — que é o terreno de
MarTech/CRM, onde já existe experiência.
