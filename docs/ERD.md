# ERD — Monitor de Preços de Supermercados

Diagrama gerado a partir do schema aplicado em PostgreSQL 16.
13 tabelas, 4 views, 24 índices, 9 triggers.

```mermaid
erDiagram
    %% ---------- CADASTROS ----------
    usuario {
        uuid    id PK
        text    nome
        text    email UK
        timestamptz criado_em
        timestamptz atualizado_em
    }

    supermercado {
        uuid    id PK
        text    nome
        char14  cnpj UK
        text    regiao
        timestamptz criado_em
    }

    categoria {
        uuid    id PK
        text    nome UK
        uuid    parent_id FK "self-ref: subcategoria"
    }

    produto {
        uuid    id PK
        text    nome_canonico
        uuid    categoria_id FK
        text    ean UK "nullable: hortifruti nao tem"
        enum    unidade_base "ML, G, UN..."
        text    marca
    }

    apresentacao {
        uuid    id PK
        uuid    produto_id FK
        text    unidade_venda "UN, CX, KG"
        numeric fator_para_base "quantas unidades_base em 1 unidade_venda"
        text    descricao_fiscal "como veio no cupom"
        text    descricao_norm
        text    chave_match "generated"
        uuid    loja_id FK "null = global"
    }

    %% ---------- INGESTAO (staging) ----------
    staging_nota {
        uuid    id PK
        uuid    user_id FK
        enum    origem "MANUAL, QRCODE, SEFAZ, OCR"
        text    origem_ref "chave 44 digitos"
        text    origem_ref_norm "generated"
        uuid    supermercado_id FK
        enum    status "PENDENTE, EM_REVISAO, CONCLUIDO"
        text    filepath_cupom "so caminho, nunca BLOB"
        numeric valor_total_declarado "total do cupom"
        numeric valor_total_calculado "soma calculada"
        integer divergencia_centavos "checksum"
        text    erro_ingestao
        integer tentativas
    }

    staging_item {
        uuid    id PK
        uuid    staging_nota_id FK
        smallint linha "ordem na nota"
        text    descricao_bruta
        text    codigo_barras
        text    unidade_observada
        numeric quantidade
        numeric valor_unitario
        numeric desconto_item
        numeric total_linha
        uuid    produto_id FK "null = nao casou"
        uuid    apresentacao_id FK
        enum    fonte_match "EAN_EXATO, DESCRICAO, MANUAL, NENHUM"
        text    mensagem_match "bitacora do learning loop"
        boolean conferido
        boolean descartado
    }

    %% ---------- TRANSACOES ----------
    nota {
        uuid    id PK
        uuid    user_id FK
        uuid    supermercado_id FK
        uuid    staging_nota_id FK
        char44  chave_acesso UK "idempotencia"
        date    data_compra
        numeric valor_total
        text    forma_pagamento
    }

    item_nota {
        uuid    id PK
        uuid    nota_id FK
        uuid    produto_id FK
        uuid    apresentacao_id FK
        smallint linha
        numeric valor_unitario
        numeric quantidade
        numeric desconto_item
        numeric total_linha
        numeric preco_canonico "por unidade_base"
        enum    unidade_base "derivado"
    }

    %% ---------- ANALISE ----------
    preco_referencia {
        uuid    id PK
        uuid    produto_id FK
        uuid    supermercado_id FK
        date    data_ref
        numeric preco_canonico
        numeric preco_min_30d
        numeric preco_max_30d
        numeric variacao_pct_30d
    }

    alerta_preco {
        uuid    id PK
        uuid    user_id FK
        uuid    produto_id FK
        uuid    preco_ref_id FK
        text    tipo "QUEDA, ALTA, MELHOR_PRECO"
        numeric variacao_pct
        text    mensagem
        boolean lido
        timestamptz gerado_em
    }

    %% ---------- LGPD E AUDITORIA ----------
    exclusao_titular {
        uuid    id PK
        uuid    usuario_id "sem FK: sobrevive ao DELETE"
        text    email
        integer notas_removidas
        integer itens_removidos
        timestamptz solicitado_em
        timestamptz executado_em
        text    motivo
    }

    auditoria {
        bigserial id PK
        uuid    user_id FK
        text    tabela
        text    operacao "INSERT, UPDATE, DELETE"
        uuid    registro_id
        jsonb   dados_antes
        jsonb   dados_depois
        timestamptz em
    }

    %% ---------- RELACIONAMENTOS ----------
    usuario ||--o{ nota : "compra"
    usuario ||--o{ staging_nota : "envia cupom"
    usuario ||--o{ alerta_preco : "recebe"
    usuario ||--o{ auditoria : "executa"

    supermercado ||--o{ nota : "emite"
    supermercado ||--o{ staging_nota : "identifica"
    supermercado ||--o{ apresentacao : "nomenclatura propria"
    supermercado ||--o{ preco_referencia : "preco praticado"

    categoria ||--o{ categoria : "contem"
    categoria ||--o{ produto : "classifica"

    produto ||--o{ apresentacao : "vendido como"
    produto ||--o{ item_nota : "comprado"
    produto ||--o{ staging_item : "casado em"
    produto ||--o{ preco_referencia : "monitorado"
    produto ||--o{ alerta_preco : "alerta de"

    apresentacao ||--o{ item_nota : "unidade cobrada"
    apresentacao ||--o{ staging_item : "unidade observada"

    staging_nota ||--o{ staging_item : "linhas brutas"
    staging_nota |o--o| nota : "vira nota revisada"

    nota ||--|{ item_nota : "contem"
    nota }o--|| preco_referencia : "alimenta"
    preco_referencia ||--o{ alerta_preco : "dispara"
```

## As três decisões que o diagrama revela

**1. `apresentacao` funde de-para com conversão de unidade.**
A descrição truncada do cupom (`LEITE UHT HERC CX 12UN`) já carrega quantas unidades base tem aquela caixa. Separar "de-para" de "fator de conversão" em duas tabelas duplicaria o dado e permitiria que divergissem. Aqui ficam juntos por construção, e `loja_id` nulo = global resolve o caso de cada rede nomear o produto de um jeito.

**2. O `preco_canonico` é derivado, não digitado.**
O trigger `trg_item_nota_canonico` divide `valor_unitario` por `fator_para_base` e **recusa** gravar a linha se a apresentação não estiver resolvida. É o que impede a comparação entre redes de ser ruído — a caixa de 12 unidades e a unidade solta viram o mesmo número.

**3. O staging tem ciclo de vida próprio.**
`staging_nota` → `staging_item` → [revisão humana] → `nota` → `item_nota`. Nada entra na tabela de análise sem passar pela conferência, e a `staging_nota` original é preservada (`ON DELETE SET NULL` em `nota.staging_nota_id`) para auditoria.

## Pontos de atenção para quando você implementar

| Ponto | Por quê |
|---|---|
| `item_nota.apresentacao_id` é `NOT NULL` | Sem ela não existe base de conversão. O trigger levanta exceção em vez de gravar preço errado. |
| `chave_acesso` com índice único parcial | Uma NFC-e por usuário. Reprocessar a mesma nota não duplica. |
| `uq_produto_ean` é parcial (`WHERE ean IS NOT NULL`) | Permite vários produtos sem EAN — o caso do hortifruti a granel. |
| `exclusao_titular.usuario_id` **sem** FK | Intencional: o registro precisa sobreviver ao `DELETE` do titular. |
| `user_id` em `staging_nota`, `nota`, `alerta_preco` | Isolamento multi-tenant. Toda query da API filtra por ele. |
