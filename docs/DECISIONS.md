# Decisões arquiteturais do home_shopper

Este índice reúne registros de decisões arquiteturais (ADRs). Cada documento explica o
contexto, as alternativas e as consequências de uma escolha relevante. **Status `draft`/`proposed`
não significa que a decisão esteja aceita** — significa que o documento existe para revisão.

## Registros

| Registro | Tema | Status |
|---|---|---|
| [ADR-0001](adr/0001-product-identity-and-presentations.md) | Identidade de produtos e apresentações | **Aceita** (2026-10-01) — direção de domínio; critérios por categoria em [spec](../superpowers/specs/2026-10-01-product-equivalence-by-category.md) |
| [ADR-0002](adr/0002-association-review-and-consolidation.md) | Associação de itens, revisão humana e consolidação | Proposta |
| [ADR-0003](adr/0003-units-base-price-and-aggregation.md) | Unidades de comparação, base price e agregação de preços | Rascunho — implementada no código, ainda não revisada |
| [ADR-0004](adr/0004-shared-catalogue-and-data-isolation.md) | Catálogo compartilhado e isolamento de dados de compra | Rascunho |
| [ADR-0005](adr/0005-privacy-minimisation-and-erasure.md) | Minimização, retenção e exclusão de dados (LGPD) | Rascunho — parcialmente implementada |
| [ADR-0006](adr/0006-ingestion-idempotency-and-pipeline.md) | Ingestão assíncrona, idempotência e fronteira da compra | Rascunho — não implementada |

As definições de domínio estão em [CONTEXT.md](../CONTEXT.md). O estado implementado do banco
está documentado no [ERD](ERD.md).

## Decisões de infraestrutura e operação (não são ADRs de domínio)

| Documento | Tema | Status |
|---|---|---|
| [2026-10-05 — qual banco é canônico](decisions/2026-10-05-canonical-database.md) | Dois bancos com dados divergentes (`home_shopper-db` vazio vs `postgres`/`home_shopper` com 15 notas); loader e input. Card `internal task` | **Aceita** (2026-10-05) — (A) `home_shopper-db` canônico + (c) os 4 inputs faltantes reconstruídos de `home_shopper`; base carregada e verificada 15/573 |

## Leitura por estado, não por número

Os registros 0002 a 0006 misturam situações que valem caminhos de revisão diferentes:

| Tipo | Registros | Significado |
|---|---|---|
| **Aceita** | 0001 | A direção foi revisada e aceita; o código ainda pode não segui-la |
| **Proposta** | 0002 | A direção foi discutida; o código pode não segui-la |
| **Registro retroativo** | 0003 | O schema **já** decide isto; o documento explica a decisão para revisão |
| **Proposta com lacuna conhecida** | 0004, 0005, 0006 | Parte implementada, parte propositalmente aberta |

Um registro retroativo (0003) deve ser lido como "o código fez isto — está certo?": a revisão
pode levar a **mudar o código**, não só o documento. Os demais devem ser lidos como "isto
será feito — está certo?".

## Processo

Discutir a decisão, registrar a proposta, revisar o documento e só então atualizar o status
para aceita. Alterações de implementação e migrações precisam de escopo e validação
próprios. Se uma decisão aceita for substituída, preservar o registro e apontar a decisão
sucessora.

## Revisão de tabelas (2026-10-03)

- [Regras aprovadas de stores, categories e presentations](reviews/2026-10-03-table-review.md)
  com decisões incrementais de domínio; nenhum DDL ou dado foi alterado. As colunas finais
  da apresentação e do mapeamento de origem continuam pendentes.
- [Avaliação do recorte brasileiro do Open Food Facts](research/2026-10-03-openfoodfacts-brazil.md)
  com síntese verificada, sem versionar o dump ou o recorte de produtos.

A aprovação dessas regras não aceita automaticamente outros ADRs, PRDs ou planos locais.

## Integrações externas em avaliação

| Tema | Status | Condição para retomada |
|---|---|---|
| Enriquecimento de alimentos pela API do Open Food Facts | **On Hold** | Retomar apenas após nova decisão do usuário, considerando declaração de uso/autorização do fornecedor e condições da licença. |

A integração não foi implementada. Enquanto estiver **On Hold**, não iniciar a integração,
não enviar solicitação ao fornecedor e não realizar novas consultas de produtos pela API.
Um dump JSONL local foi recebido e analisado; a avaliação offline não autoriza carga automática
no catálogo nem resolve as condições de reutilização. Os artefatos de referência foram
preservados localmente fora do Git; consulte a síntese acima.

## Lacunas conhecidas e registradas

Estas estão documentadas nos ADRs e são candidatas a trabalho, não a esquecimento:

1. **A exclusão LGPD deixa resíduo.** A imagem do cupom vive no disco e o `DELETE FROM users`
   não a apaga. Enquanto não houver expurgo, uma exclusão não é completa. → ADR-0005
2. **O isolamento por `user_id` é disciplina, não restrição.** Nenhuma view nova é impedida de
   omitir o filtro. → ADR-0004
3. **`price_refs.min_30d` / `max_30d` não têm número mínimo de amostras.** Um alerta de queda
   sobre uma única compra é ficção. → ADR-0003
4. **Os mapeamentos de unidade não se propagam entre emissores.** Uma filial nova do mesmo
   Supermarket G exigiu revisão separada, corretamente. → ADR-0003
5. **`audit_log` retém JSONB e não tem política de expurgo.** → ADR-0005
6. **O peso drenado é um caso nomeado, não uma classe.** `ERVILHA 1KG` ≠ `ERVILHA 800G`, e nada
   mais: as demais conservas com peso declarado diferente caem na regra de apresentação. Como
   representar esse caso sem criar uma classe artificial ainda está aberto. → ADR-0001

## Próximos temas para discussão

Ainda sem numeração, portanto ainda sem registro:

- Autorização de escrita no catálogo global compartilhado: quem cria produto, apresentação e
  sinônimo, e se a criação de um usuário vale para os outros.
- Procedimento para um item do catálogo compartilhado que se revela errado.
- A camada de comunicação: como uma queda de preço vira mensagem para o usuário, com
  deduplicação de envio e janela de silêncio.
- Migração de `presentations.factor_base` quando a embalagem muda sem mudar o produto.
