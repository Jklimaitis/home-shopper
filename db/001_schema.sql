-- =============================================================================
-- Monitor de Precos de Supermercados
-- Schema bootstrap v1 -- PostgreSQL 16
--
-- Escrito em arquivo unico, sem concatenacao, com a nota real
-- 00000000000000000000000000000000000000000000 (SEARA ALIMENTOS, R$ 337,00)
-- como evidencia de cada decisao. Ver docs/ERD.md e docs/DECISOES.md.
--
-- Regras que NAO se negociam:
--   1. Dinheiro e NUMERIC, nunca float.
--   2. Preco so e comparavel apos reexpresso na unidade base do produto.
--   3. Dado extraido (staging) nunca escreve direto na camada de confianca.
--   4. user_id em toda tabela de negocio: multi-tenancy e LGPD.
--   5. Sem BLOB de imagem: apenas filepath.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- -----------------------------------------------------------------------------
-- ENUMS
-- -----------------------------------------------------------------------------
CREATE TYPE origem_ingestao AS ENUM
    ('MANUAL', 'QRCODE', 'SEFAZ', 'OCR', 'IMPORTACAO');

-- Unidade de COMPARACAO. G e KG coexistem de proposito: o enum registra
-- o que o mercado escreveu, a conversao para base e feita por fator.
CREATE TYPE unidade_base AS ENUM ('UN', 'G', 'KG', 'ML', 'L');

CREATE TYPE status_consol AS ENUM
    ('PENDENTE', 'EM_REVISAO', 'CONCLUIDO', 'DESCARTADO');

CREATE TYPE fonte_match AS ENUM
    ('EAN_EXATO', 'DESCRICAO', 'SINONIMO', 'MANUAL', 'NENHUM');

-- -----------------------------------------------------------------------------
-- CAMADA 1 -- CADASTROS
-- -----------------------------------------------------------------------------

CREATE TABLE usuario (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome          TEXT NOT NULL,
    email         TEXT NOT NULL UNIQUE,
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE supermercado (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome      TEXT NOT NULL,
    cnpj      CHAR(14) NOT NULL UNIQUE,
    regiao    TEXT,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE categoria (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome      TEXT NOT NULL UNIQUE,
    parent_id UUID REFERENCES categoria(id) ON DELETE SET NULL
);

-- -----------------------------------------------------------------------------
-- Produto canonico -- a identidade do que e comprado.
--
-- A nota real mostrou: 0 de 14 itens tem EAN. O codigo impresso (7 digitos)
-- e interno da rede e muda entre lojas. Entao EAN e opportunistico, nunca
-- a chave. A identidade real e (marca + nome normalizado + tamanho).
--
-- qtde_base e o tamanho estruturado, SEPARADO da descricao. Sem ele,
-- "LEITE 1L" e "LEITE 900ML" viram o mesmo produto indevidamente.
-- -----------------------------------------------------------------------------
CREATE TABLE produto (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome_canonico TEXT NOT NULL,
    categoria_id  UUID REFERENCES categoria(id) ON DELETE SET NULL,
    marca         TEXT,
    ean           TEXT,
    unidade_base  unidade_base NOT NULL DEFAULT 'UN',
    qtde_base     NUMERIC(14,6) NOT NULL DEFAULT 1 CHECK (qtde_base > 0),
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- NULLS NOT DISTINCT: sem isso, 'CUPIM COMBO' com marca NULL pode
    -- existir N vezes (NULLs sao distintos em UNIQUE no Postgres). Como
    -- produto e o PK logico de apresentacao/item_nota/preco_ref, cada
    -- duplicata carrega um fator_base diferente e o dashboard passa a
    -- comparar home_shopper que nao sao comparaveis.
    CONSTRAINT produto_unico UNIQUE NULLS NOT DISTINCT (nome_canonico, marca)
);

-- -----------------------------------------------------------------------------
-- Sinonimo -- palavra parcial --> palavra canonica.
--
-- A nota real mostrou por que: cada mercado trunca o nome a 30 caracteres
-- ("LT INT HERC 1L"). Normalizar nao resolve, porque HERC nunca vira
-- HERCULES por regra de texto. Equivalencia e FATO APRENDIDO, e fato
-- aprendido mora em tabela, nao em codigo.
--
-- Diferenca em relacao ao de-para (apresentacao): o sinonimo liga
-- PALAVRA --> PALAVRA. O de-para liga DESCRICAO COMPLETA --> PRODUTO.
-- Granularidades distintas, ambas necessarias.
-- -----------------------------------------------------------------------------
CREATE TABLE sinonimo (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    termo       TEXT NOT NULL,
    expande_para TEXT NOT NULL,
    escopo      TEXT,
    criado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- NULLS NOT DISTINCT: escopo NULL (global) e o caso mais comum, e
    -- sem isso o constraint nunca protege.
    CONSTRAINT sinonimo_unico UNIQUE NULLS NOT DISTINCT (termo, escopo)
);

-- -----------------------------------------------------------------------------
-- Apresentacao = de-para + conversao de unidade. Sao a mesma coisa.
--
-- Insight: a descricao truncada ("LEITE UHT HERC CX 12UN") ja carrega
-- quantas unidades base tem aquela caixa. Separar de-para de conversao
-- duplica dado e permite divergencia. Aqui ficam juntos por construcao.
--
-- Item a peso (CUPIM COMBO kg): unidade_venda='kg' significa VENDIDO A PESO,
-- nao "preco por kg". O fator e a REFERENCIA de preco (1 kg = 1000 g);
-- a quantidade pesada (1,446) fica em item_nota.quantidade.
-- -----------------------------------------------------------------------------
CREATE TABLE apresentacao (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    produto_id     UUID NOT NULL REFERENCES produto(id) ON DELETE CASCADE,
    unidade_venda  TEXT NOT NULL,
    fator_base     NUMERIC(14,6) NOT NULL CHECK (fator_base > 0),
    descricao_fiscal TEXT NOT NULL,
    -- Versao normalizada: minuscula, sem acento, sem pontuacao. E o que
    -- a busca casa.
    descricao_norm TEXT NOT NULL,
    -- Chave de matching.
    --
    -- A ORDEM das funcoes importa: lower() ANTES de regexp_replace.
    -- Invertido, o regex [^a-z0-9 ] apaga toda letra MAIUSCULA (as
    -- descricoes fiscais vem em caixa alta) e sobra so o numero:
    --   'COXA DE FRANGO SWIFT 1 kg' -> '    1 kg'  (17 de 25 chars)
    -- Na nota real, COXA DE FRANGO e MOELA FRANGO -- dois produtos
    -- diferentes -- colidiam nessa mesma chave.
    --
    -- '[^a-z0-9]+' -> ' ' colapsa qualquer sequencia de nao-alfanumericos
    -- num espaco unico, para que '1 kg', '1kg' e '1  kg' gerem a mesma chave.
    chave          TEXT GENERATED ALWAYS AS
        (regexp_replace(lower(descricao_norm), '[^a-z0-9]+', ' ', 'g')) STORED,
    loja_id        UUID REFERENCES supermercado(id) ON DELETE CASCADE,
    criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- NULLS NOT DISTINCT: loja_id NULL significa 'global', que e o caso
    -- mais frequente, e justamente onde o constraint sem esta opcao
    -- deixa de valer.
    CONSTRAINT apres_unico UNIQUE NULLS NOT DISTINCT (produto_id, chave, loja_id),
    -- Alvo da FK composta de staging_item e item_nota: garante no BANCO
    -- que a apresentacao pertence ao produto informado. Sem isto, a
    -- coerencia dependeria so do trigger, e o staging -- que e onde o
    -- matcher erra -- aceitaria o par inconsistente.
    CONSTRAINT apres_id_produto UNIQUE (id, produto_id)
);

COMMIT;
