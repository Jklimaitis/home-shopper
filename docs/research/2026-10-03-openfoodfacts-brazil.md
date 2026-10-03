# Open Food Facts: avaliação do recorte brasileiro

**Estado:** análise de referência concluída; integração via API **On Hold**.
**Escopo:** dump local, sem chamadas à API de produtos, carga no banco ou alteração do schema.

## Resultado verificado

O dump JSONL gzip foi percorrido integralmente, sem criar cópia integral descomprimida.
Foram lidos **4.787.849 registros** e selecionados **36.567 registros**, cada um com presença
exata de `en:brazil` em `countries_tags`. O recorte tem **36.567 códigos de origem distintos**.

Esse filtro representa associação de comercialização informada pela fonte. Não comprova
origem brasileira, disponibilidade atual em uma rede específica, correção do cadastro ou
cobertura completa dos produtos comprados por usuários do home_shopper.

A leitura completa verificou o CRC do gzip. Um controle adicional detectou mudança de `mtime`
na primeira passagem, com tamanho e inode iguais. Foi feita uma segunda leitura independente:
metadados estáveis, mesmas contagens, mesmo volume descomprimido e SHA-256 idêntico da projeção
brasileira. O primeiro alerta foi preservado nos arquivos de evidência, sem atribuir causa
não verificada à mudança de metadados.

- SHA-256 do gzip de origem: `84e2e6f8796362458d302489ffceb571278057d70b35133c61fb2ad26cca18b0`.
- SHA-256 do recorte JSONL descomprimido: `67fcb9d6fb551ccc0b825a553ad1d18703dda2536c7b9ed23ce016f6f3ef7d15`.
- Recorte compactado: **4.371.370 bytes**, aproximadamente **4,37 MB**.

A integridade da extração não certifica a correção comercial dos dados.

## Campos disponíveis

| Campo | Registros não vazios | Percentual do recorte |
|---|---:|---:|
| Nome do produto | 34.783 | 95,12% |
| Marca | 26.180 | 71,59% |
| Quantidade declarada | 16.771 | 45,86% |
| Categorias normalizadas | 9.391 | 25,68% |
| Componentes de embalagem | 3.040 | 8,31% |

Há **15.672 registros (42,86%)** com quantidade estruturada positiva e unidade `g` ou `ml`.
São candidatos a conferência, não apresentações automaticamente comparáveis.

Foram identificados valores numéricos/textuais misturados, dados de conteúdo incompletos,
marcas múltiplas e **333 códigos** não compatíveis com o teste aplicado de formato/DV de GTIN.
O campo `code` também pode conter identificações locais ou atribuídas pela fonte; um DV
compatível não comprova cadastro GS1. Categorias externas são hierárquicas e sobrepostas,
portanto suas frequências não devem ser somadas como grupos exclusivos.

## Consequências para o MVP

- A base serve para sugestões e enriquecimento, não para importação automática no catálogo.
- Categorias ausentes ou incompatíveis mantêm a revisão humana necessária.
- Não inferir conteúdo ou variante de um campo vazio, nem transformar ausência em zero/falso.
- Priorizar identidade, conteúdo confirmado e unidade de cobrança para a comparação.
- Manter componentes físicos de embalagem opcionais. Recipiente, tampa, selo e rótulo podem
  ser objetos separados em `packagings`; suas contagens não representam multipack de alimento.
- O recorte gerado não inclui preços por mercado. As observações de compra continuam sendo
  necessárias para o comparador.
- A licença e a autorização/declaração de uso para integração não foram resolvidas por esta
  análise. A disponibilidade de um arquivo local não elimina condições de reutilização.

As decisões aprovadas de modelagem estão em [Revisão de tabelas](<internal review>).

## Artefatos locais, fora do Git

Cópias duráveis de recorte, estatísticas, evidências e ferramentas de análise foram preservadas
em `<home>/data/home_shopper/openfoodfacts-br/2026-10-03/`. O manifest local registra
arquivos e hashes. Essa pasta não é um checkout nem uma fonte automaticamente confiável.

O dump original permanece em Downloads no Windows. Não versionar o dump, o recorte JSONL,
as notas fiscais reais ou o banco. Este documento publica apenas a síntese da análise.

## Referências

- [Open Food Facts](https://world.openfoodfacts.org/)
- [Dicionário dos campos do export](https://world.openfoodfacts.org/data/data-fields.txt)
- [Termos de uso e reutilização](https://world.openfoodfacts.org/terms-of-use)
- [Documentação da API](https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/)

Essas referências são externas e não substituem a conferência da fonte da compra.
