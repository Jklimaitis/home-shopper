-- =============================================================================
-- home_shopper -- seed: classificação dos 384 produtos do catálogo nas 8 categorias
-- PostgreSQL 16
--
-- internal task (card internal task).
--
-- STATUS: PROPOSTA. NÃO APLICADO ao canônico (`home_shopper-db`) e NÃO mergeado.
--   A aplicação no canônico é passo separado, com go do Jonas.
--
-- O QUE ESTE ARQUIVO FAZ
--   Atribui `products.category_id` para CADA UM dos 384 produtos do catálogo, a partir
--   da evidência verbatim do cupom (`presentation_sources.description_raw`), e registra
--   — na própria linha da tabela de mapeamento — a justificativa de cada decisão.
--   Os 384 saem classificados: NÃO há categoria vazia tolerada. O seed ABORTA se algum
--   produto ficar sem categoria, se o mapeamento não cobrir o catálogo inteiro ou se o
--   resultado não bater com a contagem por categoria.
--
-- POR QUE ISTO NÃO ESTÁ EM db/
--   Mesmo motivo do seed de categorias (`seeds/2026-10-05-categories-and-attributes.sql`):
--   a CI aplica `db/*.sql` em ordem e depois `tests/smoke_test.sql`, que lê
--   `(SELECT id FROM categories)` como escalar. Um seed é DADO, não schema, e não pode
--   quebrar o teste de domínio. Fica fora do glob `db/` e é aplicado à mão:
--
--     docker exec -i home_shopper-db psql -U home_shopper -d home_shopper \
--         -v ON_ERROR_STOP=1 -f - < seeds/2026-10-06-product-category-classification.sql
--
-- DEPENDÊNCIA (aplicar nesta ordem)
--   1. `db/` na íntegra (na `main` atual, `db/001`..`db/014`).
--   2. `seeds/2026-10-05-categories-and-attributes.sql` na versão D7 — 8 categorias /
--      14 declarações. Essa versão JÁ ESTÁ na `main` (<internal PR>, commit `d7265db`), e o
--      canônico está nela desde 2026-10-06. Se a sua cópia for a antiga (6 categorias /
--      10 declarações), você está num branch cortado antes do <internal PR>: use a da `main`.
--      Este seed ABORTA com mensagem explícita se as 8 categorias não existirem: sem
--      elas a classificação seria silenciosamente parcial.
--   3. este arquivo.
--
-- DECISÕES DE FRONTEIRA DE 2026-10-06 CITADAS NAS LINHAS DE PRODUTO
--   (a) Ovos: os 5 produtos de ovo entram em `Carnes` por decisão do Jonas (card
--       `internal task`): "Ovo é considerado Proteína - entra junto com Bovinos, Aves".
--       A consequência de modelagem (Carnes declara `species`, `cut` e `seasoning`, e
--       `cut`/`seasoning` não se aplicam a ovo) está registrada no relatório, §4.1.
--   (b) Os 20 produtos que estavam sem categoria pela decisão D7 §4 receberam destino
--       do Jonas em 2026-10-06: 11 → `Mercearia`, 9 → `Limpeza`. Zero NULL. Tabela
--       completa no relatório, §4.3. O ajuste posterior do dono manteve os DOIS
--       protetores de fogão (`PROT FOG FACILI C/12` e `PROT WYDA MOL 27X27`) em
--       `Limpeza`.
--   (c) `ALCOOL COOPER 1L CLA` → `Limpeza`: "esse é considerado produto de Limpeza.
--       Álcool para bebidas NUNCA vem escrito dessa forma" (o cupom traz `1L` e `CLA`,
--       grafia de álcool cristal doméstico).
--   (d) `PROVOLETA` NÃO é ovo: o casamento com OVO é substring dentro da palavra
--       ("pr-o-v-o-leta"), a grafia verbatim do cupom é a palavra nua, e é queijo fresco —
--       fica em `Laticínios`. São 5 ovos, não 6.
--
-- FONTE DA FRONTEIRA DE CLASSIFICAÇÃO
--   `docs/decisions/2026-10-05-escopo-8-categorias-limpeza-higiene.md` (decisão D7, ACEITA
--   por Jonas): Limpeza = limpeza e cuidado doméstico; Higiene = higiene pessoal e cuidados
--   corporais; repelente de ambiente (inclusive de tomada) e odorizador de ambiente →
--   Limpeza; repelente corporal → Higiene. O balde de 14 descrições de Higiene medido por
--   aquela decisão §4 é a corroboração independente da fronteira usada aqui. O §4 dela
--   também listava itens "fora das 8" e casos-limite: as decisões de 2026-10-06 acima
--   deram destino a todos eles (nenhum NULL). O caso-limite do triplo `TOALHA HIP` ×
--   `TOALHA PAP` × `PAP TOAL` se sustenta no texto do cupom ("HIP" = higiênica → Higiene;
--   "PAP"/"PAPEL" → papel-toalha → Mercearia).
--   `PRD.md` §6.2.2 + `docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md`
--   dão os critérios das 6 categorias alimentares.
--
-- REGRA QUE NÃO FOI VIOLADA (correção do Jonas, 2026-10-06)
--   Nada foi fundido por semelhança de nome. `MAMAO PAPAYA KG` e `MAMAO FORMOSA KG`
--   continuam dois produtos, e `CEBOLA KG` e `CEBOLA ROXA KG` também — todos em
--   Hortifruti, cada um com a sua linha e a sua grafia de cupom. O mesmo vale para
--   `PAP TOAL SNOB CLA 2U` e `TOALHA PAP SNOB C/2`: duas linhas distintas que foram para
--   Mercearia pela MESMA regra de classe de produto (papel-toalha), não por serem
--   parecidas entre si.
--
-- IDEMPOTÊNCIA E AUTO-CHECK
--   O seed converge os 384 nomes para o estado decidido e ABORTA se o resultado não
--   bater: contagem por categoria, 384 classificados, 0 sem categoria, e — antes de
--   escrever — presença das 8 categorias, cobertura do catálogo inteiro pelo mapeamento
--   (nenhum produto de fora) e unicidade de cada nome em `products`. Reexecutar não
--   altera nada.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE tmp_product_category_classification (
    name          TEXT NOT NULL,
    category_name TEXT NOT NULL,  -- nesta rodada todo produto tem categoria
    rationale     TEXT NOT NULL   -- por que, a partir do texto do cupom
) ON COMMIT DROP;

INSERT INTO tmp_product_category_classification (name, category_name, rationale) VALUES
    ('abacate avocado kg', 'Hortifruti', 'fruta in natura; cupom "ABACATE AVOCADO KG"'),
    ('abacate kg', 'Hortifruti', 'fruta in natura; cupom "ABACATE KG" / "ABACATE kg"'),
    ('abob cabotia cort kg', 'Hortifruti', 'legume in natura (abóbora cabotiá cortada); cupom "ABOB CABOTIA CORT KG"'),
    ('abob italiana kg', 'Hortifruti', 'legume in natura (abóbora italiana); cupom "ABOB ITALIANA KG"'),
    ('alface crespa hidro', 'Hortifruti', 'folha in natura hidropônica; cupom "ALFACE CRESPA HIDRO"'),
    ('alface crespa un', 'Hortifruti', 'folha in natura; cupom "ALFACE CRESPA UN"'),
    ('alho poro pura 150g', 'Hortifruti', 'hortaliça folha in natura embalada (Pura); cupom "ALHO PORO PURA 150G"'),
    ('alho roxo kg', 'Hortifruti', 'hortaliça in natura; cupom "ALHO ROXO KG"'),
    ('ameixa importada kg', 'Hortifruti', 'fruta in natura; cupom "AMEIXA IMPORTADA KG"'),
    ('amora bd 100gr', 'Hortifruti', 'fruta in natura em bandeja; cupom "AMORA BD 100GR"'),
    ('banana maca kg', 'Hortifruti', 'fruta in natura (variedade maçã); cupom "BANANA MACA KG"'),
    ('banana nanica fava kg', 'Hortifruti', 'fruta in natura (variedade nanica); cupom "BANANA NANICA FAVA kg"'),
    ('banana prata kg', 'Hortifruti', 'fruta in natura (variedade prata); cupom "BANANA PRATA KG"'),
    ('batata baroa kg', 'Hortifruti', 'tubérculo in natura; cupom "BATATA BAROA KG"'),
    ('batata lavada kg', 'Hortifruti', 'tubérculo in natura; cupom "BATATA LAVADA KG"'),
    ('berinjela kg', 'Hortifruti', 'legume in natura; cupom "BERINJELA KG"'),
    ('beterraba kg', 'Hortifruti', 'legume in natura; cupom "BETERRABA KG"'),
    ('brocolis ninja pu un', 'Hortifruti', 'hortaliça in natura (brócolis ninja); cupom "BROCOLIS NINJA PU UN"'),
    ('brocolis suguim.ninja bd.200g', 'Hortifruti', 'hortaliça in natura em bandeja; cupom "BROCOLIS SUGUIM.NINJA BD.200g"'),
    ('caqui fuyu kg', 'Hortifruti', 'fruta in natura (variedade fuyu); cupom "CAQUI FUYU KG"'),
    ('cebola kg', 'Hortifruti', 'hortaliça in natura; cupom "CEBOLA KG" / "CEBOLA kg"'),
    ('cebola nac kg', 'Hortifruti', 'hortaliça in natura (nacional); cupom "CEBOLA NAC kg"'),
    ('cebola roxa kg', 'Hortifruti', 'hortaliça in natura — linha de catálogo própria, distinta de CEBOLA KG; cupom "CEBOLA ROXA KG"'),
    ('cebolinha pura h 60g', 'Hortifruti', 'erva fresca embalada; cupom "CEBOLINHA PURA H 60G"'),
    ('cebolinha pura ho mc', 'Hortifruti', 'erva fresca embalada; cupom "CEBOLINHA PURA HO MC"'),
    ('cenoura kg', 'Hortifruti', 'legume in natura; cupom "CENOURA KG" / "CENOURA kg"'),
    ('cereja kg', 'Hortifruti', 'fruta in natura; cupom "CEREJA KG"'),
    ('chuchu kg', 'Hortifruti', 'legume in natura; cupom "CHUCHU kg"'),
    ('coentro pura hort un', 'Hortifruti', 'erva fresca embalada; cupom "COENTRO PURA HORT UN"'),
    ('cog 200g shimeji bco', 'Hortifruti', 'cogumelo fresco embalado; cupom "COG 200G SHIMEJI BCO"'),
    ('espinafre pura ho un', 'Hortifruti', 'folha in natura embalada; cupom "ESPINAFRE PURA HO UN"'),
    ('gengibre kg', 'Hortifruti', 'raiz in natura; cupom "GENGIBRE KG"'),
    ('goiaba verm pp kg', 'Hortifruti', 'fruta in natura (goiaba vermelha); cupom "GOIABA VERM PP KG"'),
    ('hortela pura hort mc', 'Hortifruti', 'erva fresca embalada; cupom "HORTELA PURA HORT MC"'),
    ('kiwi importado 600gr', 'Hortifruti', 'fruta in natura; cupom "KIWI IMPORTADO 600GR"'),
    ('laranja bahia kg', 'Hortifruti', 'fruta in natura (variedade bahia); cupom "LARANJA BAHIA kg"'),
    ('laranja lima kg', 'Hortifruti', 'fruta in natura (variedade lima); cupom "LARANJA LIMA kg"'),
    ('laranja pera kg', 'Hortifruti', 'fruta in natura (variedade pera); cupom "LARANJA PERA KG"'),
    ('limao tahiti kg', 'Hortifruti', 'fruta in natura (variedade tahiti); cupom "LIMAO TAHITI KG"'),
    ('limao thaiti kg', 'Hortifruti', 'fruta in natura (variedade tahiti, grafia do cupom); cupom "LIMAO THAITI kg"'),
    ('maca gala kg', 'Hortifruti', 'fruta in natura (variedade gala); cupom "MACA GALA KG"'),
    ('mamao formosa kg', 'Hortifruti', 'fruta in natura — linha de catálogo própria, distinta de MAMAO PAPAYA; cupom "MAMAO FORMOSA KG"'),
    ('mamao papaya kg', 'Hortifruti', 'fruta in natura — linha de catálogo própria, distinta de MAMAO FORMOSA; cupom "MAMAO PAPAYA KG"'),
    ('mandioca vacuo 1kg', 'Hortifruti', 'raiz in natura embalada a vácuo (EAN 631430489037); cupom "MANDIOCA VACUO 1KG"'),
    ('manga', 'Hortifruti', 'fruta in natura, sem variedade no cupom; cupom "MANGA"'),
    ('manga palmer kg', 'Hortifruti', 'fruta in natura (variedade palmer); cupom "MANGA PALMER KG"'),
    ('manga tommy kg', 'Hortifruti', 'fruta in natura (variedade tommy); cupom "MANGA TOMMY KG"'),
    ('maracuja azedo kg', 'Hortifruti', 'fruta in natura; cupom "MARACUJA AZEDO kg"'),
    ('melao orange cort kg', 'Hortifruti', 'fruta in natura cortada; cupom "MELAO ORANGE CORT KG"'),
    ('mexerica carioca kg', 'Hortifruti', 'fruta in natura (variedade carioca); cupom "MEXERICA CARIOCA KG"'),
    ('mexerica morgot kg', 'Hortifruti', 'fruta in natura (variedade morgot); cupom "MEXERICA MORGOT KG"'),
    ('mexerica ponkan kg', 'Hortifruti', 'fruta in natura (variedade ponkan); cupom "MEXERICA PONKAN KG"'),
    ('mexerica rio kg', 'Hortifruti', 'fruta in natura (variedade rio); cupom "MEXERICA RIO kg"'),
    ('milho verde 750g', 'Hortifruti', 'milho verde; no cupom o código interno da loja (8226) cai na faixa dos hortifruti (CEBOLA 7832, CENOURA 8133, MAMAO 8215)'),
    ('mix pimentao bd 500g', 'Hortifruti', 'legumes in natura em bandeja; cupom "MIX PIMENTAO BD 500G"'),
    ('mlancia cepi cort kg', 'Hortifruti', 'fruta in natura cortada (melancia); cupom "MLANCIA CEPI CORT KG"'),
    ('morango bd 200gr', 'Hortifruti', 'fruta in natura em bandeja; cupom "MORANGO BD 200GR"'),
    ('morango bd 250gr org', 'Hortifruti', 'fruta in natura em bandeja (orgânico); cupom "MORANGO BD 250GR ORG"'),
    ('pepino jap.kg', 'Hortifruti', 'legume in natura; cupom "PEPINO JAP.kg"'),
    ('pepino japones kg', 'Hortifruti', 'legume in natura; cupom "PEPINO JAPONES KG"'),
    ('pera importada kg', 'Hortifruti', 'fruta in natura; cupom "PERA IMPORTADA kg"'),
    ('pera willians kg', 'Hortifruti', 'fruta in natura (variedade williams); cupom "PERA WILLIANS KG"'),
    ('pessego nac miudo kg', 'Hortifruti', 'fruta in natura (pêssego nacional miúdo); cupom "PESSECO NAC MIUDO KG"'),
    ('pessego nacional kg', 'Hortifruti', 'fruta in natura; cupom "PESSECO NACIONAL kg"'),
    ('pimentao verde kg', 'Hortifruti', 'legume in natura; cupom "PIMENTAO VERDE KG"'),
    ('rucula hidroponic un', 'Hortifruti', 'folha in natura hidropônica; cupom "RUCULA HIDROPONIC UN"'),
    ('salada mix hidrop un', 'Hortifruti', 'folhas in natura hidropônicas; cupom "SALADA MIX HIDROP UN"'),
    ('salsa pic pura h 60g', 'Hortifruti', 'erva fresca embalada; cupom "SALSA PIC PURA H 60G"'),
    ('shitake sprout fat.100 liv.200g', 'Hortifruti', 'cogumelo fresco embalado; cupom "SHITAKE SPROUT FAT.100 LIV.200G"'),
    ('tomate grape 300gr', 'Hortifruti', 'fruta in natura embalada (tomate grape); cupom "TOMATE GRAPE 300GR"'),
    ('tomate italiano kg', 'Hortifruti', 'legume in natura; cupom "TOMATE ITALIANO KG"'),
    ('tomilho limao pu 20g', 'Hortifruti', 'erva fresca embalada (Pura); cupom "TOMILHO LIMAO PU 20G"'),
    ('uva crinson ssem kg', 'Hortifruti', 'fruta in natura (crimson sem semente); cupom "UVA CRINSON SSEM kg"'),
    ('uva niagara kg', 'Hortifruti', 'fruta in natura (niágara); cupom "UVA NIAGARA kg"'),
    ('uva nubia kg', 'Hortifruti', 'fruta in natura (núbia); cupom "UVA NUBIA kg"'),
    ('uva thompson 500gr', 'Hortifruti', 'fruta in natura embalada (thompson); cupom "UVA THOMPSON 500GR"'),
    ('uva verm.500g', 'Hortifruti', 'fruta in natura embalada; cupom "UVA VERM.500g"'),
    ('uva vitoria bd 500gr', 'Hortifruti', 'fruta in natura em bandeja (vitória); cupom "UVA VITORIA BD 500GR"'),
    ('vagem 300g', 'Hortifruti', 'legume in natura embalado; cupom "VAGEM 300G"'),
    ('vagem mac.emb.kg', 'Hortifruti', 'legume in natura por kg; cupom "VAGEM MAC.EMB.kg"'),
    ('cr leite italac 200g', 'Laticínios', 'creme de leite; cupom "CR LEITE ITALAC 200G"'),
    ('cr leite piraca 200g', 'Laticínios', 'creme de leite Piracanjuba; cupom "CR LEITE PIRACA 200G"'),
    ('creme qjo.quata trad.cp.180g', 'Laticínios', 'creme de queijo Quatá; cupom "CREME QJO.QUATA TRAD.CP.180g"'),
    ('doce leite mumu 350g', 'Laticínios', 'doce de leite; cupom "DOCE LEITE MUMU 350G"'),
    ('f lac nestle 210g', 'Laticínios', 'farinha láctea Nestlé — produto à base de leite (fat_content/lactose_free aplicáveis); cupom "F LAC NESTLE 210G"'),
    ('fondue polenghi 400g', 'Laticínios', 'fondue de queijo Polenghi (EAN 7896207613296); cupom "FONDUE POLENGHI 400G"'),
    ('iog batav nat 450g i', 'Laticínios', 'iogurte natural; cupom "IOG BATAV NAT 450G I"'),
    ('iog danone 160g desn', 'Laticínios', 'iogurte Danone desnatado; cupom "IOG DANONE 160G DESN"'),
    ('iog danone 160g int', 'Laticínios', 'iogurte Danone integral; cupom "IOG DANONE 160G INT"'),
    ('iog verde whe 250g m', 'Laticínios', 'iogurte (linha Verde/whey); cupom "IOG VERDE WHE 250G M"'),
    ('iog vigor viv 150g n', 'Laticínios', 'iogurte Vigor; cupom "IOG VIGOR VIV 150G N"'),
    ('iog whey 21 250g coc', 'Laticínios', 'iogurte com whey; cupom "IOG WHEY 21 250G COC"'),
    ('iogurte bat.nat.int.160g', 'Laticínios', 'iogurte batido natural integral; cupom "IOGURTE BAT.NAT.INT.160g"'),
    ('iogurte bat.nat.int.170g', 'Laticínios', 'iogurte batido natural integral; cupom "IOGURTE BAT.NAT.INT.170g"'),
    ('iogurte faz.b.vista nat.desn.170g', 'Laticínios', 'iogurte de fazenda natural desnatado; cupom "IOGURTE FAZ.B.VISTA NAT.DESN.170g"'),
    ('l cond moca la 395g', 'Laticínios', 'leite condensado Moça lata; cupom "L COND MOCA LA 395G"'),
    ('leite cond.moca int.pr.esp.lt.395g', 'Laticínios', 'leite condensado Moça; cupom "LEITE COND.MOCA INT.PR.ESP.LT.395g"'),
    ('leite hercules 1l in', 'Laticínios', 'leite UHT integral; cupom "LEITE HERCULES 1L IN"'),
    ('leite jussara 1l int', 'Laticínios', 'leite UHT integral; cupom "LEITE JUSSARA 1L INT"'),
    ('leite l v aurora 1l', 'Laticínios', 'leite longa vida; cupom "LEITE L V AURORA 1L"'),
    ('leite letti a2 1l in', 'Laticínios', 'leite A2 integral; cupom "LEITE LETTI A2 1L IN"'),
    ('leite muai a2 1l int', 'Laticínios', 'leite A2 integral; cupom "LEITE MUAI A2 1L INT"'),
    ('leite parm.desn.1l', 'Laticínios', 'leite desnatado Parmalat; cupom "LEITE PARM.DESN.1l"'),
    ('leite past.faz.tp.a 1l', 'Laticínios', 'leite pasteurizado tipo A; cupom "LEITE PAST.FAZ.TP.A 1l"'),
    ('leite po molico 280g', 'Laticínios', 'leite em pó; cupom "LEITE PO MOLICO 280G"'),
    ('leite tirol 1l integ', 'Laticínios', 'leite UHT integral; cupom "LEITE TIROL 1L INTEG"'),
    ('lte conds moco 395g', 'Laticínios', 'leite condensado; cupom "LTE CONDS MOCO 395G"'),
    ('lte desn jus edge 1l', 'Laticínios', 'leite desnatado; cupom "LTE DESN JUS EDGE 1L"'),
    ('lte int tirol 1l', 'Laticínios', 'leite UHT integral; cupom "LTE INT TIROL 1L"'),
    ('lte italac zero 1l', 'Laticínios', 'leite zero lactose; cupom "LTE ITALAC ZERO 1L"'),
    ('mant itambe pt 500g', 'Laticínios', 'manteiga Itambé; cupom "MANT ITAMBE PT 500G"'),
    ('manteiga d or sel.c sal tabl.200g', 'Laticínios', 'manteiga sem sal; cupom "MANTEIGA D OR SEL.C SAL TABL.200g"'),
    ('muss lactopar ft', 'Laticínios', 'mussarela fatiada Lactopar; cupom "MUSS LACTOPAR FT"'),
    ('muss mont castelo ft', 'Laticínios', 'mussarela fatiada Monte Castelo; cupom "MUSS MONT CASTELO FT"'),
    ('provoleta', 'Laticínios', 'queijo provoleta; cupom "PROVOLETA"'),
    ('qj min pad dor 400g', 'Laticínios', 'queijo minas padrão; cupom "QJ MIN PAD DOR 400G"'),
    ('qj minas fre muai kg', 'Laticínios', 'queijo minas frescal; cupom "QJ MINAS FRE MUAI KG"'),
    ('qj minas pad la c kg', 'Laticínios', 'queijo minas padrão; cupom "QJ MINAS PAD LA C KG"'),
    ('qj minas pad paio kg', 'Laticínios', 'queijo minas padrão; cupom "QJ MINAS PAD PAIO KG"'),
    ('qj mus presiden 150g', 'Laticínios', 'queijo mussarela Presidente; cupom "QJ MUS PRESIDEN 150G"'),
    ('qj muss el maes 280g', 'Laticínios', 'queijo mussarela; cupom "QJ MUSS EL MAES 280G"'),
    ('qj muss t milk 1kg', 'Laticínios', 'queijo mussarela; cupom "QJ MUSS T MILK 1KG"'),
    ('qj ral hercules 40g', 'Laticínios', 'queijo ralado; cupom "QJ RAL HERCULES 40G"'),
    ('queijo cruzilia minas pad.pc.kg', 'Laticínios', 'queijo minas padrão; cupom "QUEIJO CRUZILIA MINAS PAD.PC.kg"'),
    ('queijo tirolez muss.ped.kg', 'Laticínios', 'queijo mussarela; cupom "QUEIJO TIROLEZ MUSS.PED.kg"'),
    ('req crioulo 220g tra', 'Laticínios', 'requeijão; cupom "REQ CRIOULO 220G TRA"'),
    ('req pocos ca 200g tr', 'Laticínios', 'requeijão Poços de Caldas; cupom "REQ POCOS CA 200G TR"'),
    ('req tania cr 400g tr', 'Laticínios', 'requeijão Tânia; cupom "REQ TANIA CR 400G TR"'),
    ('req tirolez 400g tra', 'Laticínios', 'requeijão Tirolez; cupom "REQ TIROLEZ 400G TRA"'),
    ('requeijao vigor crem.trad.200g', 'Laticínios', 'requeijão Vigor; cupom "REQUEIJAO VIGOR CREM.TRAD.200g"'),
    ('acem ped.kg', 'Carnes', 'carne bovina (acém) em pedaços; cupom "ACEM PED.kg"'),
    ('baby bife bd kg', 'Carnes', 'carne bovina (baby bife) em bandeja; cupom "BABY BIFE BD KG"'),
    ('bacon eder ped kg', 'Carnes', 'bacon em pedaços; cupom "BACON EDER PED KG"'),
    ('bacon prieto esp kg', 'Carnes', 'bacon (Prieto) em pedaços; cupom "BACON PRIETO ESP kg"'),
    ('bife contra co', 'Carnes', 'carne bovina (contrafilé); cupom "BIFE CONTRA CO"'),
    ('bife de panela', 'Carnes', 'carne bovina (bife de panela); cupom "BIFE DE PANELA"'),
    ('bisteca lombo', 'Carnes', 'carne suína (bisteca de lombo); cupom "BISTECA LOMBO"'),
    ('coracao alcatra kg', 'Carnes', 'carne bovina (coração de alcatra); cupom "CORACAO ALCATRA KG"'),
    ('costela gaucha', 'Carnes', 'carne bovina (costela); cupom "COSTELA GAUCHA"'),
    ('filepeicampos1k', 'Carnes', 'filé de pescado/ave 1 kg — conteúdo animal (espécie/corte); cupom "FILEPEICAMPOS1K"'),
    ('lombo aurora 180g', 'Carnes', 'carne suína (lombo); cupom "LOMBO AURORA 180G"'),
    ('miolo de alcatra', 'Carnes', 'carne bovina (miolo de alcatra); cupom "MIOLO DE ALCATRA"'),
    ('moida patinho 1', 'Carnes', 'carne moída de patinho; cupom "MOIDA PATINHO 1"'),
    ('patinho', 'Carnes', 'carne bovina (patinho); cupom "PATINHO"'),
    ('peito desfiado', 'Carnes', 'carne de ave (peito desfiado); cupom "PEITO DESFIADO"'),
    ('scoxa seara 1kg', 'Carnes', 'carne de ave (sobrecoxa Supermarket F); cupom "SCOXA SEARA 1kg"'),
    ('torresmo ureshi 135g', 'Carnes', 'carne suína preparada (torresmo); cupom "TORRESMO URESHI 135G"'),
    ('panco rosq co 500g', 'Padaria', 'rosca Panco 500 g (produto de padaria); cupom "PANCO ROSQ CO 500G"'),
    ('pao baguete parme kg', 'Padaria', 'pão baguete; cupom "PAO BAGUETE PARME KG"'),
    ('pao for pullman 480g', 'Padaria', 'pão de forma Pullman; cupom "PAO FOR PULLMAN 480G"'),
    ('pao for tr pull 480g', 'Padaria', 'pão de forma tradicional Pullman; cupom "PAO FOR TR PULL 480G"'),
    ('pao frances kg', 'Padaria', 'pão francês (vendido por kg); cupom "PAO FRANCES KG" / "PAO FRANCES kg"'),
    ('pao hamb/aust 320g', 'Padaria', 'pão para hambúrguer; cupom "PAO HAMB/AUST 320G"'),
    ('pao panco forma 500g', 'Padaria', 'pão de forma Panco; cupom "PAO PANCO FORMA 500G" / "PAO PANCO FORMA 500g"'),
    ('pao pullm.forma trad.480g', 'Padaria', 'pão de forma tradicional; cupom "PAO PULLM.FORMA TRAD.480g"'),
    ('pao pullman ham 520g', 'Padaria', 'pão de forma Pullman; cupom "PAO PULLMAN HAM 520G"'),
    ('pao qj f minas 400g', 'Padaria', 'pão de queijo Forno de Minas (produto de padaria); cupom "PAO QJ F MINAS 400G"'),
    ('pao sirio beiruthe', 'Padaria', 'pão sírio (EAN 7898909369020); cupom "PAO SIRIO BEIRUTHE"'),
    ('pao visconti 400g tr', 'Padaria', 'pão Visconti; cupom "PAO VISCONTI 400G TR"'),
    ('pao wick.hamb.do forno brioche prem.320g', 'Padaria', 'pão brioche para hambúrguer; cupom "PAO WICK.HAMB.DO FORNO BRIOCHE PREM.320G"'),
    ('pao wickbold 450g tr', 'Padaria', 'pão de forma Wickbold; cupom "PAO WICKBOLD 450G TR"'),
    ('achoc po nescau 350g', 'Mercearia', 'achocolatado em pó; cupom "ACHOC PO NESCAU 350G"'),
    ('achocolatado po nesc.550g', 'Mercearia', 'achocolatado em pó; cupom "ACHOCOLATADO PO NESC.550g"'),
    ('amido maizena 500g', 'Mercearia', 'amido de milho; cupom "AMIDO MAIZENA 500G"'),
    ('arr camil lf t1 1kg', 'Mercearia', 'arroz tipo 1; cupom "ARR CAMIL LF T1 1kg"'),
    ('arroz camil res.esp.t.1 1kg', 'Mercearia', 'arroz tipo 1; cupom "ARROZ CAMIL RES.ESP.T.1 1kg"'),
    ('arroz camil tp1 1kg', 'Mercearia', 'arroz tipo 1; cupom "ARROZ CAMIL TP1 1KG"'),
    ('arroz kangai gr.curto tp.1 1kg', 'Mercearia', 'arroz grão curto tipo 1; cupom "ARROZ KANGAI GR.CURTO TP.1 1kg"'),
    ('arroz momiji tp1 1kg', 'Mercearia', 'arroz tipo 1; cupom "ARROZ MOMIJI TP1 1KG"'),
    ('arroz yanagi tp1 1kg', 'Mercearia', 'arroz tipo 1; cupom "ARROZ YANAGI TP1 1KG"'),
    ('aveia nestle flocos finos 450g', 'Mercearia', 'aveia em flocos; cupom "AVEIA NESTLE FLOCOS FINOS 450g"'),
    ('aveia quak 450g fino', 'Mercearia', 'aveia em flocos; cupom "AVEIA QUAK 450G FINO"'),
    ('az andorinh ex 500ml', 'Mercearia', 'azeite de oliva extra virgem; cupom "AZ ANDORINH EX 500ML"'),
    ('az cocinero ex 500ml', 'Mercearia', 'azeite de oliva extra virgem; cupom "AZ COCINERO EX 500ML"'),
    ('azeite oliria ol.ex.vir.vd.500ml', 'Mercearia', 'azeite de oliva extra virgem; cupom "AZEITE OLIRIA OL.EX.VIR.VD.500ml"'),
    ('batata lays 62g sour', 'Mercearia', 'salgadinho de pacote; cupom "BATATA LAYS 62G SOUR"'),
    ('batata pal yoki 105g', 'Mercearia', 'batata palha embalada; cupom "BATATA PAL YOKI 105G"'),
    ('bis xtra oreo 45g', 'Mercearia', 'biscoito; cupom "BIS XTRA OREO 45G"'),
    ('bisc magia nata kg', 'Mercearia', 'biscoito a granel; cupom "BISC MAGIA NATA KG"'),
    ('bisc papapa 20g bet', 'Mercearia', 'biscoito infantil (beterraba); cupom "BISC PAPAPA 20G BET"'),
    ('bisc papapa 20g ceno', 'Mercearia', 'biscoito infantil (cenoura); cupom "BISC PAPAPA 20G CENO"'),
    ('bisc papapa 20g tom', 'Mercearia', 'biscoito infantil (tomate); cupom "BISC PAPAPA 20G TOM"'),
    ('bisc papapa 60g bana', 'Mercearia', 'biscoito infantil (banana); cupom "BISC PAPAPA 60G BANA"'),
    ('bisc papapa 60g lara', 'Mercearia', 'biscoito infantil (laranja); cupom "BISC PAPAPA 60G LARA"'),
    ('bisc papapa 60g maca', 'Mercearia', 'biscoito infantil (maçã); cupom "BISC PAPAPA 60G MACA"'),
    ('bisc papapa dent 36g', 'Mercearia', 'biscoito infantil; cupom "BISC PAPAPA DENT 36G"'),
    ('bisc rosq leite 500g', 'Mercearia', 'biscoito rosquinha de leite; cupom "BISC ROSQ LEITE 500G"'),
    ('biscoito biscovilho polv.salg.80g', 'Mercearia', 'biscoito salgado; cupom "BISCOITO BISCOVILHO POLV.SALG.80g"'),
    ('bombom garoto sort.g.20250g', 'Mercearia', 'bombom; cupom "BOMBOM GAROTO SORT.G.20250g"'),
    ('brownie favo d 50g c', 'Mercearia', 'brownie embalado 50 g (doce industrializado); cupom "BROWNIE FAVO D 50G C"'),
    ('caf tm br vac 500g', 'Mercearia', 'café torrado e moído a vácuo; cupom "CAF TM BR VAC 500G"'),
    ('cafe 3 cor vac 500g', 'Mercearia', 'café a vácuo; cupom "CAFE 3 COR VAC 500G"'),
    ('cafe melitta 500g tr', 'Mercearia', 'café torrado e moído; cupom "CAFE MELITTA 500G TR"'),
    ('cafe pilao 500g almo', 'Mercearia', 'café; cupom "CAFE PILAO 500G ALMO"'),
    ('cafe pilao trad.torr.moi.vac.500g', 'Mercearia', 'café torrado e moído a vácuo; cupom "CAFE PILAO TRAD.TORR.MOI.VAC.500g"'),
    ('catch heinz 567g', 'Mercearia', 'ketchup; cupom "CATCH HEINZ 567G"'),
    ('cer.nesc.nestle 210g', 'Mercearia', 'cereal matinal; cupom "CER.NESC.NESTLE 210G"'),
    ('cereal nesc.emb.econ.770g', 'Mercearia', 'cereal matinal; cupom "CEREAL NESC.EMB.ECON.770g"'),
    ('cereal nescau 210g', 'Mercearia', 'cereal matinal; cupom "CEREAL NESCAU 210G"'),
    ('ch kit kat 41,5g bco', 'Mercearia', 'chocolate; cupom "CH KIT KAT 41,5G BCO"'),
    ('choc dp snickers 42g', 'Mercearia', 'chocolate; cupom "CHOC DP SNICKERS 42G"'),
    ('choc hersheys 85g tr', 'Mercearia', 'chocolate; cupom "CHOC HERSHEYS 85G TR"'),
    ('choc kinder buen 39g', 'Mercearia', 'chocolate; cupom "CHOC KINDER BUEN 39G"'),
    ('choc kinder buen 43g', 'Mercearia', 'chocolate; cupom "CHOC KINDER BUEN 43G"'),
    ('choc nest alpino 80g', 'Mercearia', 'chocolate; cupom "CHOC NEST ALPINO 80G"'),
    ('choc neugebau 80g ao', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAU 80G AO"'),
    ('choc neugebau am 80g', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAU AM 80G"'),
    ('choc neugebaue 80g b', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAUE 80G B"'),
    ('choc neugebaue 80g f', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAUE 80G F"'),
    ('choc neugebaue 80g p', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAUE 80G P"'),
    ('choc neugebauer 80g', 'Mercearia', 'chocolate; cupom "CHOC NEUGEBAUER 80G"'),
    ('choc nissin 44g ao l', 'Mercearia', 'chocolate; cupom "CHOC NISSIN 44G AO L"'),
    ('choc snickers 45g or', 'Mercearia', 'chocolate; cupom "CHOC SNICKERS 45G OR"'),
    ('choc suflair 80g lei', 'Mercearia', 'chocolate; cupom "CHOC SUFLAIR 80G LEI"'),
    ('chocolate snickers branco 42g', 'Mercearia', 'chocolate; cupom "CHOCOLATE SNICKERS BRANCO 42g"'),
    ('ervilha pratig 1,02k', 'Mercearia', 'ervilha embalada 1,02 kg (EAN 7897497601277); cupom "ERVILHA PRATIG 1,02K"'),
    ('ervilha quero 170g', 'Mercearia', 'ervilha em conserva (EAN 7896102500493); cupom "ERVILHA QUERO 170G"'),
    ('ext elefan so t 300g', 'Mercearia', 'extrato de tomate; cupom "EXT ELEFAN SO T 300G"'),
    ('f tr d benta 1kg', 'Mercearia', 'farinha de trigo; cupom "F TR D BENTA 1kg"'),
    ('feijao kicaldo car.org.500g', 'Mercearia', 'feijão carioca orgânico; cupom "FEIJAO KICALDO CAR.ORG.500g"'),
    ('feijao kicaldo pto.1kg', 'Mercearia', 'feijão preto; cupom "FEIJAO KICALDO PTO.1kg"'),
    ('fj fradinh urba 500g', 'Mercearia', 'feijão fradinho; cupom "FJ FRADINH URBA 500G"'),
    ('folha lou kisabor 4g', 'Mercearia', 'folha de louro (tempero); cupom "FOLHA LOU KISABOR 4G"'),
    ('folha louro da terrinha 8g', 'Mercearia', 'folha de louro (tempero); cupom "FOLHA LOURO DA TERRINHA 8g"'),
    ('fuba p coz yoki 500g', 'Mercearia', 'fubá; cupom "FUBA P COZ YOKI 500G"'),
    ('gelat oetker d 12g a', 'Mercearia', 'gelatina em pó; cupom "GELAT OETKER D 12G A"'),
    ('guioza tsuru 360g sh', 'Mercearia', 'guioza congelado embalado; cupom "GUIOZA TSURU 360G SH"'),
    ('hersheys 82g m amarg', 'Mercearia', 'chocolate; cupom "HERSHEYS 82G M AMARG"'),
    ('hossom tinzushi 200g', 'Mercearia', 'prato pronto embalado (sushi, EAN 618341432857); cupom "HOSSOM TINZUSHI 200G"'),
    ('kani kama swift', 'Mercearia', 'kani kama (surimi de peixe industrializado); cupom "KANI KAMA SWIFT"'),
    ('kit paella noro 400g', 'Mercearia', 'kit de paella embalado; cupom "KIT PAELLA NORO 400G"'),
    ('leite coco da terrinha 200ml', 'Mercearia', 'leite de coco — não é lácteo animal; cupom "LEITE COCO DA TERRINHA 200ml"'),
    ('mac nissin cup 69g g', 'Mercearia', 'macarrão instantâneo; cupom "MAC NISSIN CUP 69G G"'),
    ('mac nissin lam 85g g', 'Mercearia', 'macarrão instantâneo; cupom "MAC NISSIN LAM 85G G"'),
    ('mac nissin mon 85g t', 'Mercearia', 'macarrão instantâneo; cupom "MAC NISSIN MON 85G T"'),
    ('mac petybon 500g n9', 'Mercearia', 'macarrão; cupom "MAC PETYBON 500G N9"'),
    ('mac urbano kids 500g', 'Mercearia', 'macarrão infantil (EAN 7896401183090); cupom "MAC URBANO KIDS 500G"'),
    ('maion hellmanns 500g', 'Mercearia', 'maionese; cupom "MAION HELLMANNS 500G"'),
    ('massa batie pastel rolo 500g', 'Mercearia', 'massa de pastel; cupom "MASSA BATIE PASTEL ROLO 500g"'),
    ('massa camil sem.c ov.penne 500g', 'Mercearia', 'massa penne; cupom "MASSA CAMIL SEM.C OV.PENNE 500g"'),
    ('massa tap.pronta beijub.500g', 'Mercearia', 'massa de tapioca pronta; cupom "MASSA TAP.PRONTA BEIJUB.500g"'),
    ('mel emporio m 300g e', 'Mercearia', 'mel; cupom "MEL EMPORIO M 300G E"'),
    ('mel nectar camp.bisnaga 210g', 'Mercearia', 'mel em bisnaga; cupom "MEL NECTAR CAMP.BISNAGA 210g"'),
    ('mn hellm 2x500g l+p-', 'Mercearia', 'maionese Hellmann''s 2x500 g; cupom "MN HELLM 2X500G L+P-"'),
    ('mol sakura tar 180ml', 'Mercearia', 'molho tarê; cupom "MOL SAKURA TAR 180ML"'),
    ('mol to fugini 300g t', 'Mercearia', 'molho de tomate; cupom "MOL TO FUGINI 300G T"'),
    ('molho heinz 240g tra', 'Mercearia', 'molho de tomate; cupom "MOLHO HEINZ 240G TRA"'),
    ('molho quero sc 240g', 'Mercearia', 'molho de tomate; cupom "MOLHO QUERO SC 240G"'),
    ('most heinz 220g mel', 'Mercearia', 'mostarda; cupom "MOST HEINZ 220G MEL"'),
    ('noz moscada kisabor bola 8g', 'Mercearia', 'noz-moscada (tempero); cupom "NOZ MOSCADA KISABOR BOLA 8g"'),
    ('nozes mariposa l kg', 'Mercearia', 'nozes a granel; cupom "NOZES MARIPOSA L KG"'),
    ('onigui samnk pr 100g', 'Mercearia', 'onigiri embalado (pronto); cupom "ONIGUI SAMNK PR 100G"'),
    ('oreg kitano 15g', 'Mercearia', 'orégano (tempero); cupom "OREG KITANO 15G"'),
    ('papinha papap 100g m', 'Mercearia', 'papinha infantil embalada; cupom "PAPINHA PAPAP 100G M"'),
    ('pastilha tic tac two menta fr.sv.38.5g', 'Mercearia', 'confeito (pastilha); cupom "PASTILHA TIC TAC TWO MENTA FR.SV.38.5G"'),
    ('pipoca tigrinho dc.75g', 'Mercearia', 'pipoca para fazer; cupom "PIPOCA TIGRINHO DC.75g"'),
    ('pipoca yoki 100g man', 'Mercearia', 'pipoca para fazer; cupom "PIPOCA YOKI 100G MAN"'),
    ('popcor yoki 100g man', 'Mercearia', 'pipoca para fazer; cupom "POPCOR YOKI 100G MAN"'),
    ('sal lebre ref.1kg', 'Mercearia', 'sal refinado; cupom "SAL LEBRE REF.1kg"'),
    ('sal seara italian kg', 'Mercearia', 'sal a granel (0,162 kg no cupom, vendido por KG); cupom "SAL SEARA ITALIAN KG"'),
    ('salg torcida 60g ceb', 'Mercearia', 'salgadinho; cupom "SALG TORCIDA 60G CEB"'),
    ('shoyu sakura 150ml t', 'Mercearia', 'shoyu; cupom "SHOYU SAKURA 150ML T"'),
    ('sob tartufo bont 90g', 'Mercearia', 'sobremesa embalada; cupom "SOB TARTUFO BONT 90G"'),
    ('sopa maggi 68g cebol', 'Mercearia', 'sopa desidratada; cupom "SOPA MAGGI 68G CEBOL"'),
    ('sushi prim prom 190g', 'Mercearia', 'sushi pronto embalado; cupom "SUSHI PRIM PROM 190G"'),
    ('temp ajinomot ho 60g', 'Mercearia', 'tempero Ajinomoto (EAN 7891132040018); cupom "TEMP AJINOMOT HO 60G"'),
    ('uva passa bca.s sem.eb.kg', 'Mercearia', 'uva-passa (fruta seca) a granel; cupom "UVA PASSA BCA.S SEM.EB.kg"'),
    ('uva passa sacol 160g', 'Mercearia', 'uva-passa (fruta seca) embalada; cupom "UVA PASSA SACOL 160G"'),
    ('ag crystal c/g 1,5l', 'Bebidas', 'água mineral com gás; cupom "AG CRYSTAL C/G 1,5L"'),
    ('ag crystal s/g 1,5lt', 'Bebidas', 'água mineral sem gás; cupom "AG CRYSTAL S/G 1,5LT"'),
    ('agua crystal c 500ml', 'Bebidas', 'água mineral com gás; cupom "AGUA CRYSTAL C 500ML"'),
    ('agua lindoya s 900ml', 'Bebidas', 'água mineral sem gás; cupom "AGUA LINDOYA S 900ML"'),
    ('beb haitai 235ml uva', 'Bebidas', 'bebida de uva 235 ml (EAN coreano 8801105909562); cupom "BEB HAITAI 235ML UVA"'),
    ('beb taichi 240ml lic', 'Bebidas', 'bebida 240 ml, sabor abreviado "LIC"; cupom "BEB TAICHI 240ML LIC"'),
    ('cerv heine 350 sleek', 'Bebidas', 'cerveja Heineken; cupom "CERV HEINE 350 SLEEK"'),
    ('cha b tea 1l c/lich', 'Bebidas', 'chá pronto; cupom "CHA B TEA 1L C/LICH"'),
    ('cha b tea 1l hibisco', 'Bebidas', 'chá pronto; cupom "CHA B TEA 1L HIBISCO"'),
    ('cha b tea 1l pitaya', 'Bebidas', 'chá pronto; cupom "CHA B TEA 1L PITAYA"'),
    ('cha nat.tea mag.lic.zero acuc.1l', 'Bebidas', 'chá pronto zero açúcar; cupom "CHA NAT.TEA MAG.LIC.ZERO ACUC.1l"'),
    ('cha natur tea b 1l l', 'Bebidas', 'chá pronto; cupom "CHA NATUR TEA B 1L L"'),
    ('cha natur tea b 1l p', 'Bebidas', 'chá pronto; cupom "CHA NATUR TEA B 1L P"'),
    ('cha yai hibisco 1l m', 'Bebidas', 'chá pronto; cupom "CHA YAI HIBISCO 1L M"'),
    ('cha yai ver zer 1l m', 'Bebidas', 'chá verde zero; cupom "CHA YAI VER ZER 1L M"'),
    ('cha yai verde 1l fru', 'Bebidas', 'chá verde; cupom "CHA YAI VERDE 1L FRU"'),
    ('cha yai verde 1l jab', 'Bebidas', 'chá verde; cupom "CHA YAI VERDE 1L JAB"'),
    ('cha yai verde 1l lic', 'Bebidas', 'chá verde; cupom "CHA YAI VERDE 1L LIC"'),
    ('coca cola s/ac 2lt', 'Bebidas', 'refrigerante; cupom "COCA COLA S/AC 2LT"'),
    ('coca original 2l', 'Bebidas', 'refrigerante; cupom "COCA ORIGINAL 2L"'),
    ('guarana antarcti 2lt', 'Bebidas', 'refrigerante; cupom "GUARANA ANTARCTI 2LT"'),
    ('nect maguary 1l caju', 'Bebidas', 'néctar; cupom "NECT MAGUARY 1L CAJU"'),
    ('nect marata 1l abaca', 'Bebidas', 'néctar; cupom "NECT MARATA 1L ABACA"'),
    ('nect marata 1l acero', 'Bebidas', 'néctar; cupom "NECT MARATA 1L ACERO"'),
    ('nect marata 1l manga', 'Bebidas', 'néctar; cupom "NECT MARATA 1L MANGA"'),
    ('nect marata 1l marac', 'Bebidas', 'néctar; cupom "NECT MARATA 1L MARAC"'),
    ('nect marata 1l pesse', 'Bebidas', 'néctar; cupom "NECT MARATA 1L PESSE"'),
    ('nect marata 1l tange', 'Bebidas', 'néctar; cupom "NECT MARATA 1L TANGE"'),
    ('nectar jal caju 1.5l', 'Bebidas', 'néctar; cupom "NECTAR JAL CAJU 1.5l"'),
    ('nectar mag.caju 1l', 'Bebidas', 'néctar; cupom "NECTAR MAG.CAJU 1l"'),
    ('pepsi black s/a 2l', 'Bebidas', 'refrigerante; cupom "PEPSI BLACK S/A 2L"'),
    ('pepsi blackg pet 2l', 'Bebidas', 'refrigerante; cupom "PEPSI BLACkg PET 2L"'),
    ('refresco mag.adoc.goiaba tp.1l', 'Bebidas', 'refresco líquido 1 L; cupom "REFRESCO MAG.ADOC.GOIABA TP.1l"'),
    ('refrig carmona tu 2l', 'Bebidas', 'refrigerante; cupom "REFRIG CARMONA TU 2L"'),
    ('refrig pepsi blac 2l', 'Bebidas', 'refrigerante; cupom "REFRIG PEPSI BLAC 2L"'),
    ('refrigerante sprite pet 2l', 'Bebidas', 'refrigerante; cupom "REFRIGERANTE SPRITE PET 2l"'),
    ('suco alianca 200ml u', 'Bebidas', 'suco; cupom "SUCO ALIANCA 200ML U"'),
    ('suco aurora 1,5l uva', 'Bebidas', 'suco; cupom "SUCO AURORA 1,5L UVA"'),
    ('suco garib.uva int.bco.1.5l', 'Bebidas', 'suco integral de uva; cupom "SUCO GARIB.UVA INT.BCO.1.5l"'),
    ('suco jal lar.1.5l', 'Bebidas', 'suco; cupom "SUCO JAL LAR.1.5l"'),
    ('suco oq int 1,5l uva', 'Bebidas', 'suco integral de uva; cupom "SUCO OQ INT 1,5L UVA"'),
    ('suco prats 1,5l lar', 'Bebidas', 'suco; cupom "SUCO PRATS 1,5L LAR"'),
    ('agua san candida 2l', 'Limpeza', 'água sanitária "SAN CANDIDA" 2 L — não é água mineral (D7 §4); cupom "AGUA SAN CANDIDA 2L"'),
    ('agua sani suprema 2l', 'Limpeza', 'água sanitária "SANI SUPREMA" 2 L (D7 §4); cupom "AGUA SANI SUPREMA 2L"'),
    ('amac com flor 900ml', 'Limpeza', 'amaciante; cupom "AMAC COM FLOR 900ML"'),
    ('amac downy 1l brisa', 'Limpeza', 'amaciante; cupom "AMAC DOWNY 1L BRISA"'),
    ('amac vida macia 1l g', 'Limpeza', 'amaciante; cupom "AMAC VIDA MACIA 1L G"'),
    ('desinf cif ant 500ml', 'Limpeza', 'desinfetante; cupom "DESINF CIF ANT 500ML"'),
    ('desinf pinho b 500ml', 'Limpeza', 'desinfetante Pinho; cupom "DESINF PINHO B 500ML"'),
    ('destac 750ml madeira', 'Limpeza', 'destacador de madeira; cupom "DESTAC 750ML MADEIRA"'),
    ('destac madeiras 750', 'Limpeza', 'destacador de madeira; cupom "DESTAC MADEIRAS 750"'),
    ('det limpo 500ml', 'Limpeza', 'detergente; cupom "DET LIMPO 500ML"'),
    ('det limpol 500ml coc', 'Limpeza', 'detergente Limpol (coco); cupom "DET LIMPOL 500ML COC"'),
    ('det limpol 500ml cri', 'Limpeza', 'detergente Limpol (cristal); cupom "DET LIMPOL 500ML CRI"'),
    ('det minuano 500ml cl', 'Limpeza', 'detergente Minuano; cupom "DET MINUANO 500ML CL"'),
    ('difusor coala 100ml', 'Limpeza', 'difusor de ambiente (D7: odorizador de ambiente → Limpeza); cupom "DIFUSOR COALA 100ML"'),
    ('esp limppano ray 1un', 'Limpeza', 'esponja de limpeza (D7 §4); cupom "ESP LIMPPANO RAY 1UN"'),
    ('evita mofo insp 180g', 'Limpeza', 'antimofo (cuidado doméstico); cupom "EVITA MOFO INSP 180G"'),
    ('inset raid ap 32,9ml', 'Limpeza', 'inseticida aerossol; cupom "INSET RAID AP 32,9ML"'),
    ('inseticida raid ae.ess.multi inset.420ml', 'Limpeza', 'inseticida; cupom "INSETICIDA RAID AE.ESS.MULTI INSET.420ml"'),
    ('la aco bombril c/6un', 'Limpeza', 'lã de aço; cupom "LA ACO BOMBRIL C/6UN"'),
    ('lava roup brilh 800g', 'Limpeza', 'sabão em pó para roupas; cupom "LAVA ROUP BRILH 800G"'),
    ('lava roup.liq.ola bebe 1l', 'Limpeza', 'lava-roupas líquido; cupom "LAVA ROUP.LIQ.OLA BEBE 1l"'),
    ('lava-rou vida mac 1l', 'Limpeza', 'lava-roupas; cupom "LAVA-ROU VIDA MAC 1L"'),
    ('limpa pedra reax 1l', 'Limpeza', 'limpa-pedra; cupom "LIMPA PEDRA REAX 1L"'),
    ('limpador azulim pisos lamin.750ml', 'Limpeza', 'limpador de pisos; cupom "LIMPADOR AZULIM PISOS LAMIN.750ml"'),
    ('limpador veja m.uso gold emb.econ.750ml', 'Limpeza', 'limpador multiuso (D7 §4); cupom "LIMPADOR VEJA M.USO GOLD EMB.ECON.750ml"'),
    ('lustra m ype 200ml l', 'Limpeza', 'lustra-móveis; cupom "LUSTRA M YPE 200ML L"'),
    ('lv roupas vida ma 1l', 'Limpeza', 'lava-roupas; cupom "LV ROUPAS VIDA MA 1L"'),
    ('lv rp surf 7l lav', 'Limpeza', 'lava-roupas 7 L; cupom "LV RP SURF 7L LAV"'),
    ('mr musc laran sch', 'Limpeza', 'limpa-forno/multiuso Mr. Músculo; cupom "MR MUSC LARAN SCH"'),
    ('odor glade 70g flora', 'Limpeza', 'odorizador de ambiente (D7 → Limpeza); cupom "ODOR GLADE 70G FLORA"'),
    ('pinho sol 1,75l natu', 'Limpeza', 'desinfetante Pinho Sol; cupom "PINHO SOL 1,75L NATU"'),
    ('repelente sbp elet.45 n.ap+rf.of.esp.', 'Limpeza', 'repelente de ambiente/elétrico (D7 → Limpeza); cupom "REPELENTE SBP ELET.45 N.AP+RF.OF.ESP."'),
    ('sc s fort 100lt c/13', 'Limpeza', 'saco de lixo 100 L c/13 — consumível doméstico; cupom "SC S FORT 100LT C/13"'),
    ('veja pesada 950ml cl', 'Limpeza', 'limpador Veja; cupom "VEJA PESADA 950ML CL"'),
    ('antitranspirante cr.dove prev.escur.50g', 'Higiene', 'antitranspirante; cupom "ANTITRANSPIRANTE CR.DOVE PREV.ESCUR.50g"'),
    ('cr den colg 90g', 'Higiene', 'creme dental Colgate (D7 §4); cupom "CR DEN COLG 90G"'),
    ('hastes flex.aponete 75un', 'Higiene', 'haste flexível (D7 §4); cupom "HASTES FLEX.APONETE 75un"'),
    ('palm sh+co 350ml det', 'Higiene', 'shampoo/condicionador Palmolive 350 ml; cupom "PALM SH+CO 350ML DET"'),
    ('papel hig.mili neutro f.d.30m 12un', 'Higiene', 'papel higiênico (D7 §4); cupom "PAPEL HIG.MILI NEUTRO F.D.30m 12un"'),
    ('sab granado be 90g e', 'Higiene', 'sabonete; cupom "SAB GRANADO BE 90G E"'),
    ('sab nivea cacau e ja', 'Higiene', 'sabonete (D7 §4); cupom "SAB NIVEA CACAU E JA"'),
    ('sab nivea karit e l.', 'Higiene', 'sabonete; cupom "SAB NIVEA KARIT E L."'),
    ('sab nivea oleo de ab', 'Higiene', 'sabonete; cupom "SAB NIVEA OLEO DE AB"'),
    ('sab protex 85g macad', 'Higiene', 'sabonete; cupom "SAB PROTEX 85G MACAD"'),
    ('sbt hid 400ml perf b', 'Higiene', 'sabonete/sabonete líquido hidratante 400 ml; cupom "SBT HID 400ML PERF B"'),
    ('sh pant 400ml bambu', 'Higiene', 'shampoo Pantene (D7 §4); cupom "SH PANT 400ML BAMBU"'),
    ('toal umed meu n 140u', 'Higiene', 'lenço umedecido (D7 lista lenço umedecido em Higiene); cupom "TOAL UMED MEU N 140U"'),
    ('toalha hip snob c/3r', 'Higiene', 'papel higiênico ("HIP" = higiênica); pela decisão D7 §4 o triplo TOALHA HIP × TOALHA PAP × PAP TOAL é caso-limite NÃO resolvido, então a categoria se sustenta no texto do cupom e no balde de 14 descrições de Higiene medido pela própria D7 §4; cupom "TOALHA HIP SNOB C/3R"'),
    ('alcool cooper 1l cla', 'Limpeza', 'álcool doméstico/cristal: decisão do Jonas de 2026-10-06 — "esse é considerado produto de Limpeza. Álcool para bebidas NUNCA vem escrito dessa forma"; cupom "ALCOOL COOPER 1L CLA" (1L + CLA = cristal doméstico)'),
    ('bicarbona kitano 80g', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): bicarbonato é item de mercearia; cupom "BICARBONA KITANO 80G"'),
    ('carvao 5kg', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): carvão é item de mercearia; cupom "CARVAO 5KG"'),
    ('chiksupre300gr', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): leitura do Jonas do texto do cupom — "Chiken Supreme 300GR" (nuggets); cupom "CHIKSUPRE300GR" (SEARA, 300 g, R$ 9,90)'),
    ('filtro aroma max 103', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): filtro de café é item de mercearia; cupom "FILTRO AROMA MAX 103"'),
    ('filtro melitta papel gde.103 30un', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): filtro de café é item de mercearia; cupom "FILTRO MELITTA PAPEL GDE.103 30un"'),
    ('guard kitch 22,7x22,', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): guardanapo é item de mercearia; cupom "GUARD KITCH 22,7X22,"'),
    ('hidrost blister 50ml', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sanitizante à base de hipoclorito de sódio para higienização de alimentos; cupom "HIDROST BLISTER 50ML"'),
    ('l.seki espatula b un', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): utensílio de cozinha é item de mercearia; cupom "L.SEKI ESPATULA B UN"'),
    ('ovo org c ftoca 20un', 'Carnes', 'proteína: decisão do Jonas (card internal task, 2026-10-06 01:55) — "Ovo é considerado Proteína - entra junto com Bovinos, Aves", e Bovinos/Aves estão em Carnes; cupom "OVO ORG C FTOCA 20UN"'),
    ('ovos faz.toca org.caip.tp.gde.verm.20un', 'Carnes', 'proteína: decisão do Jonas (card internal task, 2026-10-06 01:55) — ovo entra com Bovinos, Aves (= Carnes); cupom "OVOS FAZ.TOCA ORG.CAIP.TP.GDE.VERM.20un"'),
    ('ovos ito caip c/10', 'Carnes', 'proteína: decisão do Jonas (card internal task, 2026-10-06 01:55) — ovo entra com Bovinos, Aves (= Carnes); cupom "OVOS ITO CAIP C/10"'),
    ('ovos ito caip verm', 'Carnes', 'proteína: decisão do Jonas (card internal task, 2026-10-06 01:55) — ovo entra com Bovinos, Aves (= Carnes); cupom "OVOS ITO CAIP VERM"'),
    ('ovos raiar org.caip.t.gde.verm.20un', 'Carnes', 'proteína: decisão do Jonas (card internal task, 2026-10-06 01:55) — ovo entra com Bovinos, Aves (= Carnes); cupom "OVOS RAIAR ORG.CAIP.T.GDE.VERM.20un"'),
    ('pap mant faci 7,5x30', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): papel-manteiga é item de mercearia; cupom "PAP MANT FACI 7,5X30"'),
    ('pap toal snob cla 2u', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): papel-toalha é item de mercearia; cupom "PAP TOAL SNOB CLA 2U"'),
    ('pq premium 400g', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): leitura do Jonas do texto do cupom — "Pão de Queijo Premium 400g"; cupom "PQ PREMIUM 400G"'),
    ('prot fog facili c/12', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino; ajuste posterior do dono: os dois protetores de fogão ficam juntos em Limpeza): protetor de fogão; cupom "PROT FOG FACILI C/12"'),
    ('prot wyda mol 27x27', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino; ajuste posterior do dono: os dois protetores de fogão ficam juntos em Limpeza): protetor de boca de fogão; cupom "PROT WYDA MOL 27X27" (Wyda, 27x27)'),
    ('qa lv rp cc', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): "Lava Roupa Concentrado"; cupom "QA LV RP CC"'),
    ('sac 58x70cm cinza', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sacola/embalagem; cupom "SAC 58X70CM CINZA" (R$ 0,25 a unidade)'),
    ('sacola biopl.reut.cza.', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sacola/embalagem reutilizável; cupom "SACOLA BIOPL.REUT.CZA."'),
    ('sacola biopl.reut.vde.', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sacola/embalagem reutilizável; cupom "SACOLA BIOPL.REUT.VDE."'),
    ('sacola ret b4u 35x40', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sacola/embalagem; cupom "SACOLA RET B4U 35X40"'),
    ('sacola verde sp 48x5', 'Limpeza', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): sacola/embalagem; cupom "SACOLA VERDE SP 48X5"'),
    ('toalha pap snob c/2', 'Mercearia', 'decisão do Jonas de 2026-10-06 (os 20 que a decisão D7 §4 listava fora das 8 passam a ter destino): papel-toalha é item de mercearia — mesma classe de "PAP TOAL SNOB CLA 2U"; ⚠ este item NÃO estava nomeado na lista do coordenador e é a única inferência desta rodada (relatório §4.3); cupom "TOALHA PAP SNOB C/2"');

-- -----------------------------------------------------------------------------
-- 1. Pré-checagens -- o seed recusa começar num estado que produziria resultado parcial
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rows       INTEGER;
    v_prod       INTEGER;
    v_cats       INTEGER;
    v_missing    TEXT;
    v_unmapped   TEXT;
    v_dup        TEXT;
BEGIN
    SELECT count(*) INTO v_rows FROM tmp_product_category_classification;
    IF v_rows <> 384 THEN
        RAISE EXCEPTION 'mapeamento incompleto: % linhas (esperado 384)', v_rows;
    END IF;

    -- As 8 categorias da decisão D7 precisam existir.
    SELECT count(*) INTO v_cats
      FROM categories c
     WHERE lower(btrim(c.name)) IN
           ('laticínios', 'carnes', 'mercearia', 'bebidas',
            'hortifruti', 'padaria', 'limpeza', 'higiene');
    IF v_cats <> 8 THEN
        RAISE EXCEPTION 'as 8 categorias da decisão D7 não estão presentes (% encontradas): '
                        'aplique seeds/2026-10-05-categories-and-attributes.sql na versão D7 antes',
                        v_cats;
    END IF;

    -- Nenhum produto é tolerado sem categoria: o catálogo tem de estar inteiramente
    -- coberto pelo mapeamento deste seed.
    SELECT count(*) INTO v_prod FROM products;
    IF v_prod <> 384 THEN
        RAISE EXCEPTION 'o catálogo tem % produto(s) e este mapeamento cobre 384: '
                        'atualize o mapeamento antes de aplicar', v_prod;
    END IF;

    -- Todo nome do mapeamento tem de casar com exatamente um produto.
    SELECT string_agg(m.name, ', ' ORDER BY m.name) INTO v_missing
      FROM tmp_product_category_classification m
     WHERE NOT EXISTS (
           SELECT 1 FROM products p
            WHERE lower(btrim(p.name)) = lower(btrim(m.name)));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'nome(s) do mapeamento sem produto correspondente: %', v_missing;
    END IF;

    -- E nenhum produto pode ficar de fora do mapeamento.
    SELECT string_agg(p.name, ', ' ORDER BY p.name) INTO v_unmapped
      FROM products p
     WHERE NOT EXISTS (
           SELECT 1 FROM tmp_product_category_classification m
            WHERE lower(btrim(m.name)) = lower(btrim(p.name)));
    IF v_unmapped IS NOT NULL THEN
        RAISE EXCEPTION 'produto(s) do catálogo sem classificação no mapeamento: %', v_unmapped;
    END IF;

    SELECT string_agg(k, ', ') INTO v_dup
      FROM (SELECT lower(btrim(p.name)) AS k
              FROM products p
              JOIN tmp_product_category_classification m
                ON lower(btrim(p.name)) = lower(btrim(m.name))
             GROUP BY 1 HAVING count(*) > 1) d;
    IF v_dup IS NOT NULL THEN
        RAISE EXCEPTION 'nome ambíguo (mais de um produto): %', v_dup;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. A classificação (convergência: corrige qualquer categoria divergente)
-- -----------------------------------------------------------------------------
UPDATE products p
   SET category_id = c.id
  FROM tmp_product_category_classification m
  JOIN categories c
    ON lower(btrim(c.name)) = lower(btrim(m.category_name))
 WHERE lower(btrim(p.name)) = lower(btrim(m.name))
   AND p.category_id IS DISTINCT FROM c.id;

-- -----------------------------------------------------------------------------
-- 3. Auto-check -- o seed recusa terminar num estado diferente do decidido
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    r          RECORD;
    v_got      INTEGER;
    v_class    INTEGER;
    v_null     INTEGER;
    v_orphans  TEXT;
BEGIN
    -- Contagem por categoria, conferida uma a uma (independente de collation/ordem).
    FOR r IN
        SELECT * FROM (VALUES
            ('Laticínios', 50),
            ('Carnes', 22),
            ('Mercearia', 118),
            ('Bebidas', 42),
            ('Hortifruti', 80),
            ('Padaria', 14),
            ('Limpeza', 44),
            ('Higiene', 14)
        ) AS v(category_name, expected)
    LOOP
        SELECT count(*) INTO v_got
          FROM products p
          JOIN categories c ON c.id = p.category_id
         WHERE lower(btrim(c.name)) = lower(btrim(r.category_name));

        IF v_got <> r.expected THEN
            RAISE EXCEPTION 'categoria %: % produto(s) (esperado %)',
                r.category_name, v_got, r.expected;
        END IF;
    END LOOP;

    SELECT count(*) FILTER (WHERE category_id IS NOT NULL),
           count(*) FILTER (WHERE category_id IS NULL),
           string_agg(name, ', ' ORDER BY name) FILTER (WHERE category_id IS NULL)
      INTO v_class, v_null, v_orphans
      FROM products;

    -- Nenhuma categoria vazia é tolerada.
    IF v_null <> 0 THEN
        RAISE EXCEPTION 'ainda há % produto(s) sem categoria: %', v_null, v_orphans;
    END IF;
    IF v_class <> 384 THEN
        RAISE EXCEPTION 'produtos classificados: % (esperado 384)', v_class;
    END IF;

    RAISE NOTICE 'classificação OK: % classificados, 0 sem categoria, de % produtos no total',
        v_class, v_class;
END $$;

COMMIT;
