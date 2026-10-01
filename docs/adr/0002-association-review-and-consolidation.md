---
status: proposed
---

# ADR-0002: Associação de itens, revisão humana e consolidação

O home_shopper deve reconhecer variações de escrita sem transformar semelhança textual em equivalência de produtos. A direção alinhada é reutilizar associações sustentadas por evidências, manter dúvidas pendentes de revisão humana e preservar os dados originais. Este documento permanece proposto; não aceita a ADR-0001 nem autoriza implementação, migração ou alteração de dados.

## Contexto

Descrições de cupons podem variar em capitalização, espaços, palavras concatenadas e abreviações. Revisar repetidamente diferenças apenas de escrita gera trabalho desnecessário; associar itens por nome parecido pode misturar cortes, marcas, variantes e apresentações.

A identidade segue os critérios da [ADR-0001](0001-product-identity-and-presentations.md). Identificar o produto não implica identificar a apresentação ou conhecer a conversão necessária para comparar seu preço.

## Direção alinhada na conversa

1. Havendo dúvida, contradição ou informação insuficiente, exigir revisão humana. O sistema deve poder responder que não conseguiu identificar o item, em vez de forçar uma associação.
2. Diferenças de capitalização e espaços podem ser normalizadas para pesquisa sem mudar o significado. A descrição original permanece preservada. Separação de palavras concatenadas só é aproveitada quando reconhecida com segurança; não se exige um parser genérico para qualquer texto.
3. Abreviações e descrições equivalentes já validadas podem ser reutilizadas automaticamente dentro do escopo em que são válidas, desde que os atributos relevantes continuem compatíveis e não haja candidatos conflitantes. Semelhança textual isolada serve para sugerir candidatos, não para confirmar equivalência.
4. Uma associação de descrição completa não implica uma substituição universal de cada palavra. Por exemplo, uma associação validada de `CX FRG` com coxa de frango no contexto de um emissor não autoriza interpretar `CX` como coxa em todos os cupons.
5. Produto, apresentação e unidade de venda precisam de verificações próprias. O produto pode estar identificado enquanto embalagem, quantidade de conteúdo ou conversão continuam pendentes. Um vínculo com produto, sozinho, não torna o preço comparável.
6. Usar `snake_case` nos identificadores técnicos não exige converter os valores textuais para esse formato. Manter descrição original, nome canônico legível e representação normalizada com finalidades distintas. Relacionamentos usam identificadores, não nomes formatados. A forma da chave textual não constitui uma garantia de desempenho.
7. Permitir correção posterior dos dados e associações de uma nota já consolidada, por usuário autorizado e com revalidação. Consolidado significa aprovado no estado atual, não imutável. Corrigir o registro no home_shopper não altera o documento fiscal emitido.

A tela de confirmação após o processamento da nota foi sugerida pelo usuário. As regras de aprovação final e tratamento de pendências abaixo são recomendações a revisar, não decisões já aceitas.

## Fluxo recomendado para o MVP

`Importação → extração → staging → identificação e sugestões → revisão e confirmação → consolidação → histórico e comparação`

- Upload concluído significa documento recebido, não nota aprovada. Dados provisórios não alimentam comparações ou alertas.
- Apresentar uma tela final com resumo da nota, valores originais, interpretações propostas e motivos das pendências. Itens com associação segura vêm preenchidos; itens ambíguos exigem intervenção individual.
- Recomendar confirmação final da nota mesmo quando todos os itens já estejam identificados, sem exigir confirmação individual repetitiva de associações seguras. Preencher automaticamente não equivale a consolidar automaticamente.
- Permitir salvar o progresso e retomar a revisão. A confirmação geral não resolve silenciosamente pendências nem substitui informações necessárias à conversão.
- Recomendar consolidação parcial dos itens resolvidos e aprovados, sem bloquear os demais apenas por dúvidas de identificação em uma linha. Preservar itens pendentes para revisão posterior e indicar a incompletude da nota. Essa recomendação substitui a preferência anterior por consolidação integral; permanece proposta até a revisão do documento. Pendências gerais que comprometam a confiabilidade da nota podem bloquear todos os itens.
- Conferir totais sem substituir silenciosamente os valores fiscais por cálculos derivados. Tolerâncias, descontos e critérios de divergência serão definidos na decisão sobre preços e cálculos.
- Implementar futuramente autorização no servidor, prevenção de duplicidade e transação por lote de itens aprovados. Repetir a confirmação não deve duplicar notas nem linhas; uma falha deve reverter o lote, sem afetar lotes anteriormente consolidados. Parcialidade intencional não deve ser confundida com uma gravação incompleta causada por erro.
- Registrar a origem da associação e as revisões necessárias sem publicar dados privados. Não promover uma correção individual a regra global automaticamente. Acesso, retenção e correções de histórico dependem das decisões específicas de privacidade e catálogo.

## Consolidação parcial recomendada

- Uma linha elegível precisa de identidade, apresentação, unidade e conversão suficientes, valores coerentes e aprovação conforme a política de confirmação. Resolver apenas o nome do produto não basta.
- Dúvidas locais de identificação não bloqueiam linhas independentes já resolvidas. Extração incompleta, possível duplicidade, falta de estabelecimento ou data, ou divergências gerais não esclarecidas podem bloquear a consolidação da nota como um todo. A classificação exata dessas condições ainda exige revisão.
- Preservar todos os itens originais, inclusive os pendentes. A conferência financeira considera a nota completa extraída; não compara o total fiscal apenas com a soma do subconjunto consolidado.
- O total pago da nota não é reduzido ao valor dos itens identificados. Quando o cabeçalho e os totais estiverem validados, o gasto total pode ser registrado uma única vez, enquanto comparações e análises por produto usam apenas as linhas elegíveis e indicam sua cobertura incompleta. Regras de desconto e preço efetivo permanecem na decisão de cálculos.
- Exibir progresso por itens, diferenciando resolvidos, consolidados e pendentes. Não chamar de concluída uma nota com pendências nem apresentar um relatório parcial como completo.
- Após revisão dos itens restantes, incorporá-los à mesma compra, sem recriar o cabeçalho, duplicar linhas ou contar novamente o total pago. Atualizar os resultados derivados afetados conforme a política de preços e correções.
- A opção de excluir explicitamente um item da comparação, os critérios para encerrar uma nota com itens não comparáveis e o momento de aprovação do gasto total continuam pendentes. Esta proposta não autoriza apagar dados originais.

## Correção após a consolidação

A pessoa autorizada pode corrigir associações de produto e apresentação, interpretações de unidade e erros de extração dos dados da compra. A alteração corrige o registro interno, não a NFC-e emitida; não oferece edição do documento fiscal nem autoriza ajustar valores arbitrariamente para eliminar divergências.

- Preservar a fonte original e distinguir dado extraído, interpretação aprovada e correção posterior. Correções de quantidade, preço, data, estabelecimento ou totais precisam de justificativa e evidência pertinente; valores fiscais não são substituídos silenciosamente por cálculos derivados.
- Registrar autor, momento, motivo e alterações relevantes, com controle de acesso, minimização e retenção definidos na decisão de privacidade. Esta regra não autoriza guardar snapshots completos ou dados pessoais indefinidamente.
- Apresentar a alteração para revisão e aplicar as mesmas validações da consolidação. Se a nova interpretação continuar ambígua, manter o item em revisão; uma interpretação já reconhecida como inválida deixa de alimentar comparações até ser resolvida.
- Preservar a identidade da compra e da linha na correção ordinária, sem criar outra nota, duplicar compras ou contar novamente o total pago. Correções que alterem a identidade da nota, como estabelecimento ou chave de acesso, exigem tratamento específico de conflito e não são uma edição genérica irrestrita.
- Uma correção local de produto ou apresentação não muda o catálogo nem aliases globais automaticamente. Alterar um cadastro compartilhado tem escopo e autorização próprios.
- Aplicar a correção aprovada em transação e detectar edições concorrentes para evitar perda silenciosa de alterações. O mecanismo técnico de versionamento ou bloqueio será definido na implementação.
- Recalcular ou invalidar os resultados derivados afetados, incluindo as referências do vínculo anterior e do novo vínculo quando produto, loja ou data mudarem. Enquanto houver atualização pendente, resultados reconhecidamente desatualizados não são apresentados como atuais. A política de cálculos continua fora desta ADR.
- Preservar o histórico de alertas já enviados: uma correção não desfaz uma comunicação entregue e não deve provocar reenvio automático indiscriminado. A política de eventual aviso corretivo será definida antes de implementar alertas.

Recomenda-se correção rastreável com revalidação, em vez de bloquear toda edição após consolidação ou permitir sobrescrita livre. Exclusão de compra, cancelamento fiscal, reversão de uma correção e mesclagem de duplicatas não são autorizados implicitamente por essa possibilidade.

## Exemplos ilustrativos

| Situação | Tratamento proposto |
|---|---|
| `COXA FRANGO`, `coxa frango` e `Coxa Frango`, com os mesmos atributos relevantes | Normalizar capitalização e espaços; não pedir revisão apenas pela escrita. |
| `CoxaFrango` | Aproveitar separação reconhecida e validada; não prometer segmentação genérica de qualquer palavra concatenada. |
| `COXA FRG`, com abreviação validada no contexto e candidato compatível único | Reutilizar a associação sem revisão individual repetida. |
| `CX FRG`, com descrição completa validada para o emissor | Reutilizar o vínculo no escopo confirmado, sem criar a regra global `CX → coxa`. |
| `CX FRG` em contexto desconhecido ou com candidatos conflitantes | Manter pendente de revisão. |
| Coxa com osso e coxa sem osso | Não eliminar o atributo na normalização nem associar apenas pelo corte. |
| Carne identificada, vendida em `UN`, sem conteúdo conhecido | Produto pode estar resolvido; apresentação e conversão permanecem pendentes. |

Os exemplos não são associações reais cadastradas nem regras globais prontas para execução.

## Alternativas e consequências

- **Consolidar automaticamente e corrigir depois:** reduz esforço inicial, mas permite que erros influenciem histórico e alertas antes da revisão. Não é a direção recomendada para o MVP.
- **Confirmar cada item em toda importação:** aumenta o controle individual, mas repete trabalho sobre associações já conhecidas.
- **Reutilizar associações seguras e revisar pendências, com confirmação dos itens elegíveis:** equilibra esforço e controle. É a recomendação, mas exige distinguir sugestão, identificação e aprovação, além de oferecer explicações compreensíveis.
- **Esperar a resolução de todos os itens:** simplifica o fluxo de consolidação, mas uma única dúvida impede o uso de dados já confiáveis.
- **Consolidar os itens aprovados e manter os demais pendentes:** entrega valor antes e permite revisão gradual, mas exige controle de progresso, proteção contra duplicidade e indicação de cobertura incompleta nos relatórios. É a recomendação atual para o MVP.

## Relação com o estado atual

O schema já possui `synonyms`, `presentations`, `staging_receipts`, `staging_lines`, `purchase_notes` e `line_items`. Há campos de origem da associação e revisão, além de uma fila de revisão. Isso oferece estruturas de apoio, não um matcher, uma tela ou um serviço completo de confirmação.

`presentations` atualmente combina descrição, loja e conversão. A separação entre alias de descrição e apresentação comercial precisa de desenho próprio. Campos booleanos de revisão, constraints e comentários não garantem, por si só, que toda consolidação passe pela autorização e aprovação propostas. O fluxo parcial também precisa de representação de progresso e vínculo sem duplicidade entre a importação e a compra; a existência das tabelas não garante esse comportamento.

## Pontos pendentes de revisão

- Aprovar ou ajustar a política de confirmação dos itens elegíveis e a consolidação parcial recomendadas para o MVP.
- Definir bloqueios gerais versus pendências locais, aprovação do cabeçalho e total pago, representação do progresso e critérios para encerrar notas com itens não comparáveis.
- Definir vínculo único entre nota importada e compra consolidada, inclusão posterior de linhas e atualização dos resultados derivados, sem duplicidade.
- Definir escopo, manutenção e revogação de aliases; autorização para transformar uma revisão em associação reutilizável; comportamento diante de conflitos.
- Definir critérios verificáveis de associação segura por categoria.
- Detalhar campos corrigíveis, evidências e aprovação de correções, controle de concorrência e rastreabilidade compatível com privacidade.
- Definir tratamento de conflitos na identidade da nota e atualização ou invalidação de resultados derivados, incluindo eventual comunicação sobre alertas afetados.

Não há definição de algoritmo de matching, percentual de confiança, interface visual, API ou alteração de schema nesta ADR. Após a revisão do documento, a implementação terá planejamento e validação próprios.
