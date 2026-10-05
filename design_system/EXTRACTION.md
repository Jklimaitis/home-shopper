# Extração e verificação — design system do home_shopper

Registro do que foi **medido**, de onde, e o que **não** foi obtido. Este arquivo é a
evidência da camada visual; sem ele, os valores de `tokens.css` são só afirmação.

## Fonte

O `DESIGN.md` do home_shopper foi derivado da análise do sistema Meta disponibilizada em
`getdesign.md/design-md/meta/DESIGN.md`, cujas páginas de origem são as quatro abaixo:

| # | Página | Papel |
|---|---|---|
| 1 | `meta.com/` | homepage — hero, grids de 3-4 colunas, cards fotográficos |
| 2 | `meta.com/ai-glasses/ray-ban-meta-skyler-gen-2/` | PDP — galeria + rail sticky, swatches |
| 3 | `meta.com/quest/quest-3s/buy-now/` | configurador — painel de compra, radio, CTA cobalto |
| 4 | `meta.com/ai-glasses/prescription/` | página de acessório — grid de cards |

Medição feita no navegador real em **2026-10-05**, sobre
`https://www.meta.com/br/en/quest/quest-3s/buy-now/`.

## Medições confirmadas na fonte

### Fontes

```
resolved: document.fonts → "Optimistic VF 200 800 loaded"
fallback: "Optimistic VF", Montserrat, Helvetica, Arial, "Noto Sans", sans-serif
body:     font-family: Helvetica, Arial, sans-serif
```

Eixo variável **200–800** confirmado — é o que sustenta o peso 300 do `heading-md` e o
700 do `subtitle-lg` na mesma família.

### Cores (frequência na página, entre as mais usadas)

| Medido | Token | Ocorrências |
|---|---|---|
| `rgb(28, 30, 33)` = `#1c1e21` | `--color-ink` | 1317 |
| `rgb(93, 108, 123)` = `#5d6c7b` | `--color-steel` | 427 |
| `rgb(10, 19, 23)` = `#0a1317` | `--color-ink-deep` | 280 |
| `rgb(4, 87, 203)` = `#0457cb` | `--color-primary-deep` | 135 |
| `rgb(0, 0, 0)` | `--color-ink-button` | 103 |
| `rgb(56, 88, 152)` = `#385898` | link legado (não portado) | 64 |
| `rgba(10, 19, 23, 0.12)` | borda ghost | 29 |
| `rgb(241, 244, 247)` = `#f1f4f7` | `--color-surface-soft` | 9 |
| body background `rgb(255, 255, 255)` | `--color-canvas` | — |

O cobalto (`#0457cb`) aparecer densamente **na página de compra** confirma a regra do
sistema: cobalto vive no fluxo de compra, não na superfície de marketing.

### Raios

Tally real de `border-radius` na página (valores ≠ 0):

```
100px (13) · 24px (11) · 32px (9) · 40px (7) · 6px (6) · 16px (6) · 50% (4) · 999px (4) · 12px (2) · 120px (1)
```

Confere com a escala do `DESIGN.md` (`full` 100 · `xxl` 24 · `xxxl` 32 · `feature` 40 ·
`md` 6 · `xl` 16 · `circle`) e com a regra "botão nunca é quadrado" — 100px é o valor
mais frequente de toda a página.

## Verificação local do deliverable

Servido de `design_system/` (`python3 -m http.server 8765`) e inspecionado via
`getComputedStyle`:

| Verificação | Esperado | Medido |
|---|---|---|
| atributos `style=""` no HTML | 0 | **0** |
| `section[id]` | 7 | 7 |
| âncoras na nav fixa | 7 | 7 |
| `body` font-family | cadeia Optimistic VF | confere |
| `.btn-primary` radius | 100px | **100px** |
| `.btn-buy-cta` background | `#0064e0` | `rgb(0, 100, 224)` |
| `.price-tag` font-size | 32px | **32px** |
| `.t-hero-display` font-size | 64px | **64px** |
| `.card-product` radius | 32px | **32px** |
| `.store-row--best` border-top-width | 2px | **2px** |
| `.badge--price-drop` background | `#31a24c` | `rgb(49, 162, 76)` |
| anel de foco | `#1876f2` | `rgb(24, 118, 242)` |
| `.grid--4` em 390px | 1 coluna | `358px` (1 col) |
| `.t-hero-display` em 390px | 36px | **36px** |
| `.nav-top__links` em 390px | oculto | `display: none` |
| `.store-row` em 390px | coluna | `flex-direction: column` |

## O que NÃO foi obtido — e por quê

- **Optimistic VF (arquivo).** Fonte proprietária da Meta, não distribuída. Não há
  webfont baixada nem embutida. A cadeia de fallback é declarada igual à da origem, então
  o layout é o nativo onde a fonte licenciada estiver instalada e degrada para
  Montserrat/Helvetica/Arial onde não estiver. **Isto é uma diferença real de renderização,
  não uma equivalência.**
- **Complexidade do site de origem.** As páginas usam CSS atômico gerado com nomes
  hasheados (`x1motxo8`, `x1dg8jwx`…). Reaproveitar essas classes seria inútil fora do
  bundle da Meta; o que foi preservado são os **valores** medidos, não os nomes.
- **Estados de hover na origem.** O design system da Meta não publica hover; por isso o
  guia mostra *default / pressed / focused / disabled*, e os estados extras do
  `design-system.css` são derivados dos tokens (não inventam cor nova).
- **Timings de animação e dark mode.** Não existem na origem; estão declarados como
  proposta em `DESIGN.md` § Known Gaps e centralizados em `tokens.css`.

## Reproduzir

```bash
cd design_system && python3 -m http.server 8765
# abrir http://127.0.0.1:8765/design-system.html
```
