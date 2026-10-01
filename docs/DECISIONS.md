# Decisões arquiteturais do home_shopper

Este índice reúne registros de decisões arquiteturais (ADRs). Cada documento explica o
contexto, as alternativas e as consequências de uma escolha relevante. **Status `draft` não
significa que a decisão esteja aceita** — significa que o documento existe para revisão.

## Registros

| Registro | Tema | Status |
|---|---|---|
| [ADR-0001](adr/0001-product-identity-and-presentations.md) | Identidade de produtos e apresentações | Proposta, aguardando revisão do documento |
| [ADR-0002](adr/0002-association-review-and-consolidation.md) | Associação de itens, revisão humana e consolidação | Proposta |
| [ADR-0003](adr/0003-units-base-price-and-aggregation.md) | Unidades de comparação, base price e agregação de preços | Rascunho — implementada no código, ainda não revisada |
| [ADR-0004](adr/0004-shared-catalogue-and-data-isolation.md) | Catálogo compartilhado e isolamento de dados de compra | Rascunho |
| [ADR-0005](adr/0005-privacy-minimisation-and-erasure.md) | Minimização, retenção e exclusão de dados (LGPD) | Rascunho — parcialmente implementada |
| [ADR-0006](adr/0006-ingestion-idempotency-and-pipeline.md) | Ingestão assíncrona, idempotência e fronteira da compra | Rascunho — não implementada |

As definições de domínio estão em [CONTEXT.md](../CONTEXT.md). O estado implementado do banco
está documentado no [ERD](ERD.md).

## Leitura por estado, não por número

Os registros 0003 a 0006 estão em `draft` e misturam três situações que valem caminhos de
revisão diferentes:

| Tipo | Registros | Significado |
|---|---|---|
| **Proposta** | 0001, 0002 | A direção foi discutida; o código pode não segui-la |
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

## Próximos temas para discussão

Ainda sem numeração, portanto ainda sem registro:

- Autorização de escrita no catálogo global compartilhado: quem cria produto, apresentação e
  sinônimo, e se a criação de um usuário vale para os outros.
- Procedimento para um item do catálogo compartilhado que se revela errado.
- A camada de comunicação: como uma queda de preço vira mensagem para o usuário, com
  deduplicação de envio e janela de silêncio.
- Migração de `presentations.factor_base` quando a embalagem muda sem mudar o produto.
