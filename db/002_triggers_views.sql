
-- -----------------------------------------------------------------------------
-- CAMADA 2 -- INGESTAO (staging: dado bruto, nao confiavel)
--
-- Fluxo: upload/QR/import --> staging_nota + staging_item --> [revisao humana]
--        --> nota + item_nota (confiavel) --> analise
--
-- A nota real mostrou a razao da revisao humana ser obrigatoria:
-- 0 de 14 itens tem EAN, 13 de 14 tem tamanho parseavel, e o unico sem
-- tamanho (CUPIM COMBO kg) e justamente o item a peso. O caminho
-- automatico resolve ~93%; a revisao trata a cauda.
-- -----------------------------------------------------------------------------

CREATE TABLE staging_nota (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
    origem         origem_ingestao NOT NULL,
    origem_ref     TEXT,
    ref_norm       TEXT GENERATED ALWAYS AS
        (lower(coalesce(origem_ref, ''))) STORED,
    mercado_id     UUID REFERENCES supermercado(id) ON DELETE SET NULL,
    status         status_consol NOT NULL DEFAULT 'PENDENTE',
    filepath_cupom TEXT,
    total_declarado NUMERIC(12,2),
    total_calculado NUMERIC(12,2),
    divergencia_cents INTEGER,
    erro_ingestao  TEXT,
    tentativas     INTEGER NOT NULL DEFAULT 0,
    criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging_item (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nota_id         UUID NOT NULL REFERENCES staging_nota(id) ON DELETE CASCADE,
    linha           SMALLINT NOT NULL,
    descricao_bruta TEXT NOT NULL,
    codigo_loja     TEXT,
    unidade_obs     TEXT NOT NULL,
    quantidade      NUMERIC(12,3) NOT NULL CHECK (quantidade >= 0),
    valor_unitario  NUMERIC(12,4) NOT NULL CHECK (valor_unitario >= 0),
    desconto_item   NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_linha     NUMERIC(12,2) NOT NULL,
    produto_id      UUID REFERENCES produto(id) ON DELETE SET NULL,
    apres_id        UUID REFERENCES apresentacao(id) ON DELETE SET NULL,
    fonte           fonte_match NOT NULL DEFAULT 'NENHUM',
    msg_match       TEXT,
    conferido       BOOLEAN NOT NULL DEFAULT FALSE,
    descartado      BOOLEAN NOT NULL DEFAULT FALSE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT stg_item_unico UNIQUE (nota_id, linha)
);

-- -----------------------------------------------------------------------------
-- CAMADA 3 -- TRANSACOES (confiavel, consolidada)
--
-- chave_acesso tem indice unico parcial: uma NFC-e por usuario. Reprocessar
-- a mesma nota (retry de job, re-importacao) nao duplica.
-- -----------------------------------------------------------------------------

CREATE TABLE nota (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
    mercado_id   UUID NOT NULL REFERENCES supermercado(id) ON DELETE RESTRICT,
    staging_id   UUID REFERENCES staging_nota(id) ON DELETE SET NULL,
    chave_acesso CHAR(44),
    data_compra  DATE NOT NULL,
    valor_total  NUMERIC(12,2) NOT NULL CHECK (valor_total > 0),
    pagamento    TEXT,
    criado_em    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- apres_id e NOT NULL: sem ele nao existe base de conversao, e o trigger
-- levanta excecao em vez de gravar preco silenciosamente errado.
CREATE TABLE item_nota (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nota_id        UUID NOT NULL REFERENCES nota(id) ON DELETE CASCADE,
    produto_id     UUID NOT NULL REFERENCES produto(id) ON DELETE RESTRICT,
    apres_id       UUID NOT NULL REFERENCES apresentacao(id) ON DELETE RESTRICT,
    linha          SMALLINT NOT NULL,
    valor_unitario NUMERIC(12,4) NOT NULL CHECK (valor_unitario >= 0),
    quantidade     NUMERIC(12,3) NOT NULL CHECK (quantidade > 0),
    desconto_item  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_linha    NUMERIC(12,2) NOT NULL,
    preco_base     NUMERIC(14,8) NOT NULL CHECK (preco_base >= 0),
    unidade_base   unidade_base NOT NULL,
    criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT item_unico UNIQUE (nota_id, linha)
);

-- -----------------------------------------------------------------------------
-- CAMADA 4 -- ANALISE
-- -----------------------------------------------------------------------------

CREATE TABLE preco_ref (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    produto_id    UUID NOT NULL REFERENCES produto(id) ON DELETE CASCADE,
    mercado_id    UUID NOT NULL REFERENCES supermercado(id) ON DELETE CASCADE,
    data_ref      DATE NOT NULL,
    preco_base    NUMERIC(14,8) NOT NULL,
    min_30d       NUMERIC(14,8),
    max_30d       NUMERIC(14,8),
    var_pct_30d   NUMERIC(8,2),
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preco_ref_unico UNIQUE (produto_id, mercado_id, data_ref)
);

CREATE TABLE alerta_preco (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
    produto_id  UUID NOT NULL REFERENCES produto(id) ON DELETE CASCADE,
    preco_ref_id UUID REFERENCES preco_ref(id) ON DELETE CASCADE,
    tipo        TEXT NOT NULL CHECK (tipo IN ('QUEDA', 'ALTA', 'MELHOR_PRECO')),
    var_pct     NUMERIC(8,2) NOT NULL,
    mensagem    TEXT,
    lido        BOOLEAN NOT NULL DEFAULT FALSE,
    gerado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- CAMADA 5 -- LGPD E AUDITORIA
-- -----------------------------------------------------------------------------

-- usuario_id SEM FK de proposito: este registro precisa sobreviver ao
-- DELETE do titular (LGPD art. 18 -- comprovacao de exclusao).
CREATE TABLE exclusao_titular (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id    UUID NOT NULL,
    email         TEXT NOT NULL,
    notas_remov   INTEGER NOT NULL DEFAULT 0,
    itens_remov   INTEGER NOT NULL DEFAULT 0,
    solicitado_em TIMESTAMPTZ NOT NULL DEFAULT now(),
    executado_em  TIMESTAMPTZ,
    motivo        TEXT
);

CREATE TABLE auditoria (
    id           BIGSERIAL PRIMARY KEY,
    user_id      UUID REFERENCES usuario(id) ON DELETE SET NULL,
    tabela       TEXT NOT NULL,
    operacao     TEXT NOT NULL CHECK (operacao IN ('INSERT', 'UPDATE', 'DELETE')),
    registro_id  UUID,
    dados_antes  JSONB,
    dados_depois JSONB,
    em           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- TRIGGERS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION touch_atualizado() RETURNS TRIGGER AS $$
BEGIN
    NEW.atualizado_em := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_usuario_touch BEFORE UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION touch_atualizado();
CREATE TRIGGER trg_produto_touch BEFORE UPDATE ON produto
    FOR EACH ROW EXECUTE FUNCTION touch_atualizado();
CREATE TRIGGER trg_stg_nota_touch BEFORE UPDATE ON staging_nota
    FOR EACH ROW EXECUTE FUNCTION touch_atualizado();

-- -----------------------------------------------------------------------------
-- CHECKSUM CONTABIL
--
-- A nota real (SEARA, R$ 337,00) provou que a formula correta e
-- SUM(total_linha) -- e nao SUM(quantidade * valor_unitario).
-- Motivo: o fisco ARREDONDA A LINHA, nao o produto.
--   1,446 kg x 39,90 = 57,6954  --> gravado como 57,70
-- Somar produtos brutos e comparar com totais arredondados gera falso
-- positivo em qualquer nota com item a peso.
-- A comparacao final usa TOLERANCIA, nunca igualdade exata.
--
-- O trigger vive em staging_item (a linha muda) mas escreve em
-- staging_nota (o agregado), entao atualiza o pai explicitamente por chave.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calc_divergencia() RETURNS TRIGGER AS $$
DECLARE
    v_nota  UUID;
    v_soma  NUMERIC(14,2);
BEGIN
    -- Em DELETE, NEW e nulo: usa OLD.
    v_nota := coalesce(NEW.nota_id, OLD.nota_id);

    SELECT coalesce(sum(total_linha), 0) INTO v_soma
      FROM staging_item
     WHERE nota_id = v_nota;

    UPDATE staging_nota
       SET total_calculado  = round(v_soma, 2),
           divergencia_cents = CASE
               WHEN total_declarado IS NULL THEN NULL
               ELSE round((total_declarado - v_soma) * 100)::INTEGER
           END,
           atualizado_em = now()
     WHERE id = v_nota;

    RETURN coalesce(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stg_item_checksum
    AFTER INSERT OR UPDATE OR DELETE ON staging_item
    FOR EACH ROW EXECUTE FUNCTION calc_divergencia();

-- -----------------------------------------------------------------------------
-- PRECO BASE -- reexprime o preco na unidade de comparacao do produto.
--
--   preco_base = valor_unitario / fator_base
--
-- Exemplos com a nota real (base G):
--   CARNE MOIDA COMBO 1kg, apresentacao pc -> fator 1000
--     29,90 / 1000 = 0,029900 / g
--   CUPIM COMBO kg,     apresentacao kg -> fator 1000
--     39,90 / 1000 = 0,039900 / g
--   KANI KAMA SWIFT 250 g, apresentacao pc -> fator 250
--      10,90 / 250 = 0,043600 / g
-- Agora os tres sao comparáveis. Sem isto, o dashboard diria que a caixa
-- de 250g e mais cara que o kg, o que e absurdo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calc_preco_base() RETURNS TRIGGER AS $$
DECLARE
    v_fator NUMERIC(14,6);
BEGIN
    SELECT a.fator_base, p.unidade_base
      INTO v_fator, NEW.unidade_base
      FROM produto p
      JOIN apresentacao a ON a.produto_id = p.id AND a.id = NEW.apres_id
     WHERE p.id = NEW.produto_id;

    IF v_fator IS NULL THEN
        RAISE EXCEPTION
            'apres_id obrigatorio: sem fator de conversao nao ha preco base'
            USING ERRCODE = '23514';
    END IF;

    NEW.preco_base := round(NEW.valor_unitario / v_fator, 8);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_item_preco_base
    BEFORE INSERT OR UPDATE ON item_nota
    FOR EACH ROW EXECUTE FUNCTION calc_preco_base();

-- -----------------------------------------------------------------------------
-- AUDITORIA
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION registrar_audit() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO auditoria (user_id, tabela, operacao, registro_id, dados_antes)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'DELETE', OLD.id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        INSERT INTO auditoria (user_id, tabela, operacao, registro_id, dados_antes, dados_depois)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'UPDATE', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
    ELSE
        INSERT INTO auditoria (user_id, tabela, operacao, registro_id, dados_depois)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'INSERT', NEW.id, to_jsonb(NEW));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_nota AFTER INSERT OR UPDATE OR DELETE ON nota
    FOR EACH ROW EXECUTE FUNCTION registrar_audit();
CREATE TRIGGER trg_audit_item AFTER INSERT OR UPDATE OR DELETE ON item_nota
    FOR EACH ROW EXECUTE FUNCTION registrar_audit();

COMMIT;
