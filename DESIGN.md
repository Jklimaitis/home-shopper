---
version: alpha
name: home-shopper-design
description: Design system for home_shopper — a supermarket price comparison dashboard. Adapted from Meta's commerce design language for the Brazilian grocery context.
colors:
  primary: "#0064e0"
  primary-deep: "#0457cb"
  primary-soft: "#0091ff"
  on-primary: "#ffffff"
  ink-button: "#000000"
  on-ink-button: "#ffffff"
  fb-blue: "#1876f2"
  success: "#31a24c"
  success-soft: "#e8f5e9"
  attention: "#f2a918"
  attention-soft: "#fff8e1"
  warning: "#f7b928"
  critical: "#e41e3f"
  critical-soft: "#ffebee"
  canvas: "#ffffff"
  surface-soft: "#f1f4f7"
  ink-deep: "#0a1317"
  ink: "#1c1e21"
  charcoal: "#444950"
  slate: "#4b4c4f"
  steel: "#5d6c7b"
  stone: "#8595a4"
  hairline: "#ced0d4"
  hairline-soft: "#dee3e9"
  disabled-text: "#bcc0c4"
  price-drop: "#31a24c"
  price-rise: "#e41e3f"
  price-stable: "#5d6c7b"
  best-price: "#0064e0"
  store-a: "#0064e0"
  store-b: "#f2a918"
  store-c: "#31a24c"
  store-d: "#a121ce"

typography:
  hero-display:
    fontFamily: Optimistic VF
    fontSize: 64px
    fontWeight: 500
    lineHeight: 1.16
    fontFeature: "ss01, ss02"
  display-lg:
    fontFamily: Optimistic VF
    fontSize: 48px
    fontWeight: 500
    lineHeight: 1.17
    fontFeature: "ss01, ss02"
  heading-lg:
    fontFamily: Optimistic VF
    fontSize: 36px
    fontWeight: 500
    lineHeight: 1.28
    fontFeature: "ss01, ss02"
  heading-md:
    fontFamily: Optimistic VF
    fontSize: 28px
    fontWeight: 300
    lineHeight: 1.21
    fontFeature: "ss01, ss02"
  heading-sm:
    fontFamily: Optimistic VF
    fontSize: 24px
    fontWeight: 500
    lineHeight: 1.25
    fontFeature: "ss01, ss02"
  subtitle-lg:
    fontFamily: Optimistic VF
    fontSize: 18px
    fontWeight: 700
    lineHeight: 1.44
  subtitle-md:
    fontFamily: Optimistic VF
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.44
  body-md-bold:
    fontFamily: Optimistic VF
    fontSize: 16px
    fontWeight: 700
    lineHeight: 1.50
    letterSpacing: "-0.16px"
  body-md:
    fontFamily: Optimistic VF
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: "-0.16px"
  body-sm-bold:
    fontFamily: Optimistic VF
    fontSize: 14px
    fontWeight: 700
    lineHeight: 1.43
    letterSpacing: "-0.14px"
  body-sm:
    fontFamily: Optimistic VF
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "-0.14px"
  caption-bold:
    fontFamily: Optimistic VF
    fontSize: 12px
    fontWeight: 700
    lineHeight: 1.33
  caption:
    fontFamily: Optimistic VF
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.33
  button-md:
    fontFamily: Optimistic VF
    fontSize: 14px
    fontWeight: 700
    lineHeight: 1.43
    letterSpacing: "-0.14px"
  link-md:
    fontFamily: Optimistic VF
    fontSize: 16px
    fontWeight: 700
    lineHeight: 1.50
    letterSpacing: "-0.16px"
  price-display:
    fontFamily: Optimistic VF
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.20
    letterSpacing: "-0.32px"
  price-unit:
    fontFamily: Optimistic VF
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "-0.14px"

rounded:
  xs: 2px
  sm: 4px
  md: 6px
  lg: 8px
  xl: 16px
  xxl: 24px
  xxxl: 32px
  feature: 40px
  full: 100px
  circle: 9999px

spacing:
  xxs: 4px
  xs: 8px
  sm: 10px
  md: 12px
  base: 16px
  lg: 20px
  xl: 24px
  xxl: 32px
  xxxl: 40px
  section-sm: 48px
  section: 64px
  section-lg: 80px
  hero: 120px

components:
  button-primary:
    backgroundColor: "{colors.ink-button}"
    textColor: "{colors.on-ink-button}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "14px 30px"
  button-primary-pressed:
    backgroundColor: "{colors.charcoal}"
    textColor: "{colors.on-ink-button}"
  button-buy-cta:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "14px 30px"
  button-buy-cta-pressed:
    backgroundColor: "{colors.primary-deep}"
    textColor: "{colors.on-primary}"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink-deep}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "12px 28px"
    border: "2px solid {colors.ink-deep}"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink-deep}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "10px 22px"
    border: "2px solid rgba(10, 19, 23, 0.12)"
  button-pill-tab:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm-bold}"
    rounded: "{rounded.full}"
    padding: "8px 16px"
    border: "1px solid {colors.hairline}"
  button-pill-tab-active:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.canvas}"
  button-icon-circular:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    rounded: "{rounded.circle}"
    size: 40px
  card-product:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xxxl}"
    padding: "{spacing.xxl}"
    border: "1px solid {colors.hairline-soft}"
  card-product-featured:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xxxl}"
    padding: "0"
    border: "none"
  card-price-comparison:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xxxl}"
    padding: "{spacing.xxl}"
    border: "1px solid {colors.hairline-soft}"
  card-promo-strip:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.canvas}"
    rounded: "{rounded.xxxl}"
    padding: "{spacing.section}"
  card-icon-feature:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xl}"
    padding: "{spacing.xl}"
    border: "1px solid {colors.hairline-soft}"
  card-checkout-summary:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xl}"
    padding: "{spacing.xl}"
    border: "1px solid {colors.hairline-soft}"
    designer: "rgba(20, 22, 26, 0.3) 0px 1px 4px 0px"
  card-stat:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xl}"
    padding: "{spacing.xl}"
    border: "1px solid {colors.hairline-soft}"
  card-chart:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.xxxl}"
    padding: "{spacing.xxl}"
    border: "1px solid {colors.hairline-soft}"
  product-thumbnail:
    backgroundColor: "{colors.surface-soft}"
    rounded: "{rounded.xl}"
    padding: "{spacing.base}"
    aspect-ratio: "1 / 1"
  text-input:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.md}"
    border: "1px solid {colors.hairline}"
    height: 44px
  text-input-focused:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    border: "2px solid {colors.fb-blue}"
  search-pill:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.steel}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.full}"
    padding: "{spacing.md} {spacing.lg}"
    height: 40px
  badge-price-drop:
    backgroundColor: "{colors.price-drop}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-price-rise:
    backgroundColor: "{colors.price-rise}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-price-stable:
    backgroundColor: "{colors.price-stable}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-best-price:
    backgroundColor: "{colors.best-price}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-attention:
    backgroundColor: "{colors.attention}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-critical:
    backgroundColor: "{colors.critical}"
    textColor: "{colors.canvas}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-store:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  price-tag:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink-deep}"
    typography: "{typography.price-display}"
  price-tag-unit:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.steel}"
    typography: "{typography.price-unit}"
  store-row:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
    border: "1px solid {colors.hairline-soft}"
  store-row-best:
    backgroundColor: "{colors.canvas}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
    border: "2px solid {colors.best-price}"
  chart-line:
    backgroundColor: "transparent"
    border: "none"
  chart-grid:
    backgroundColor: "transparent"
    border: "1px solid {colors.hairline-soft}"
  nav-top:
    backgroundColor: "{colors.canvas}"
    border: "1px solid {colors.hairline-soft}"
  nav-pill-tab:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm-bold}"
    rounded: "{rounded.full}"
    padding: "8px 16px"
    border: "1px solid {colors.hairline}"
  nav-pill-tab-active:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.canvas}"
  filter-chip:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.full}"
    padding: "6px 14px"
  filter-chip-active:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.canvas}"
  table-header:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.steel}"
    typography: "{typography.body-sm-bold}"
  table-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
  table-row-alt:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
  divider:
    backgroundColor: "transparent"
    border: "1px solid {colors.hairline-soft}"
  tooltip:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.canvas}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.lg}"
    padding: "{spacing.md}"
  empty-state:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.steel}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxxl}"
    padding: "{spacing.section}"
  skeleton:
    backgroundColor: "{colors.surface-soft}"
    rounded: "{rounded.lg}"
---

## Overview

home_shopper is a Brazilian supermarket price comparison dashboard. The design system adapts Meta's commerce language — stark white canvas, Optimistic VF typography, pill-shaped buttons, generous card rounding — to the grocery analytics context. The core user need is **comparing prices across stores**, so the system emphasizes price visualization, store comparison rows, and trend indicators.

The visual hierarchy is data-first: prices are the largest elements on screen, store names are secondary, and product context is tertiary. Color is reserved for semantic meaning — green for price drops, red for increases, blue for best-price highlights — never decoration.

**Executable layer.** This spec is the source; `design_system/` is the deliverable derived from it — `design_system/design-system.html` (navigable guide, 7 anchored sections), `design_system/tokens.css` (every token above as a custom property) and `design_system/design-system.css` (components with default/pressed/focused/disabled states). `design_system/EXTRACTION.md` holds the evidence: what was measured live on `meta.com`, and what was not obtained. The two layers are complementary, not substitutes — the deliverable is regenerated from this spec, never the reverse.

## Colors

### Brand & Accent
- **Cobalt Primary** ({colors.primary}): Best-price CTAs, "buy here" buttons, and the primary action in comparison views. Used sparingly — its weight comes from scarcity.
- **Deep Cobalt** ({colors.primary-deep}): Pressed state for cobalt buttons.
- **Facebook Blue** ({colors.fb-blue}): Focus states, selected form controls, active filters.

### Semantic Price Colors
- **Price Drop** ({colors.price-drop}): Green badge and chart line when a price decreased. Always paired with a downward arrow.
- **Price Rise** ({colors.price-rise}): Red badge and chart line when a price increased. Always paired with an upward arrow.
- **Price Stable** ({colors.price-stable}): Gray badge when variation is within ±2%.
- **Best Price** ({colors.best-price}): Blue highlight for the cheapest store in a comparison row.

### Store Identity Colors
- **Store A** ({colors.store-a}): Blue — first store in comparison.
- **Store B** ({colors.store-b}): Amber — second store.
- **Store C** ({colors.store-c}): Green — third store.
- **Store D** ({colors.store-d}): Purple — fourth store.
These are used in chart legends and store chips, never as fills.

### Surface
- **Canvas White** ({colors.canvas}): Page background, card surfaces.
- **Soft Cloud** ({colors.surface-soft}): Table headers, skeleton loaders, filter chips, search background.
- **Hairline Gray** ({colors.hairline}): Input borders, table row separators.
- **Hairline Soft** ({colors.hairline-soft}): Card borders, section dividers.

### Text
- **Deep Ink** ({colors.ink-deep}): Headlines, prices, primary text.
- **Ink** ({colors.ink}): Body text, product names.
- **Charcoal** ({colors.charcoal}): Secondary text, store names.
- **Steel** ({colors.steel}): Captions, timestamps, units.
- **Stone** ({colors.stone}): Disabled text, placeholders.

## Typography

### Font Family
Optimistic VF is the universal face. Fallbacks: Montserrat, Helvetica, Arial, Noto Sans. All headings carry `ss01, ss02` stylistic sets.

### Hierarchy

| Token | Size | Weight | Line Height | Use |
|---|---|---|---|---|
| `{typography.hero-display}` | 64px | 500 | 1.16 | Dashboard hero, empty states |
| `{typography.display-lg}` | 48px | 500 | 1.17 | Section openers |
| `{typography.heading-lg}` | 36px | 500 | 1.28 | Page titles |
| `{typography.heading-md}` | 28px | 300 | 1.21 | Editorial subheads |
| `{typography.heading-sm}` | 24px | 500 | 1.25 | Card titles, section headers |
| `{typography.subtitle-lg}` | 18px | 700 | 1.44 | Store names, product names |
| `{typography.subtitle-md}` | 18px | 400 | 1.44 | Lead paragraphs |
| `{typography.body-md}` | 16px | 400 | 1.50 | Body text |
| `{typography.body-md-bold}` | 16px | 700 | 1.50 | Emphasis, links |
| `{typography.body-sm}` | 14px | 400 | 1.43 | Secondary text, table cells |
| `{typography.body-sm-bold}` | 14px | 700 | 1.43 | Pill tabs, badges |
| `{typography.caption-bold}` | 12px | 700 | 1.33 | Badge labels, timestamps |
| `{typography.caption}` | 12px | 400 | 1.33 | Fine print, units |
| `{typography.button-md}` | 14px | 700 | 1.43 | Button labels |
| `{typography.price-display}` | 32px | 700 | 1.20 | Large price figures |
| `{typography.price-unit}` | 14px | 400 | 1.43 | "/kg", "/un", "/L" |

### Principles
- Prices use `{typography.price-display}` at 32px/700 — they are the primary data point.
- Store names use `{typography.subtitle-lg}` — they are the comparison axis.
- Product names use `{typography.body-md}` — context, not focus.
- Negative letter-spacing on body roles tightens the metric for dense data tables.

## Layout

### Spacing System
Base unit: 4px. Dominant step: 8px.

| Token | Value | Use |
|---|---|---|
| `{spacing.xxs}` | 4px | Badge padding, icon gaps |
| `{spacing.xs}` | 8px | Inline element gaps |
| `{spacing.sm}` | 10px | Compact table cells |
| `{spacing.md}` | 12px | Input padding |
| `{spacing.base}` | 16px | Card internal padding |
| `{spacing.lg}` | 20px | Section gaps |
| `{spacing.xl}` | 24px | Card padding |
| `{spacing.xxl}` | 32px | Large card padding |
| `{spacing.xxxl}` | 40px | Section spacing |
| `{spacing.section-sm}` | 48px | Compact sections |
| `{spacing.section}` | 64px | Standard sections |
| `{spacing.section-lg}` | 80px | Hero sections |

### Grid & Container
- Max-width: 1280px with 32px gutters.
- Dashboard grid: 12-column, 24px gap.
- Product cards: 4-up on desktop, 2-up on tablet, 1-up on mobile.
- Comparison table: full-width with sticky first column.

### Whitespace Philosophy
Data-dense but breathable. Cards carry `{spacing.xxl}` padding. Sections separate at `{spacing.section}`. Price figures get `{spacing.base}` breathing room around them.

## Elevation & Depth

The system is flat. Elevation is reserved for interactive layers:

| Level | Treatment | Use |
|---|---|---|
| 0 (flat) | No designer, `{rounded.xxxl}` + `{colors.hairline-soft}` border | Default cards |
| 1 (subtle) | `rgba(0, 0, 0, 0.2) 1px 1px 0px` | Active pill indicator |
| 2 (sticky) | `rgba(20, 22, 26, 0.3) 0px 1px 4px 0px` | Sticky comparison rail, mobile bottom bar |

## Shapes

### Border Radius Scale

| Token | Value | Use |
|---|---|---|
| `{rounded.xs}` | 2px | Fine UI corners |
| `{rounded.sm}` | 4px | Tags, micro-controls |
| `{rounded.md}` | 6px | Thumbnail rounding |
| `{rounded.lg}` | 8px | Form inputs, table rows |
| `{rounded.xl}` | 16px | Standard cards, stat cards |
| `{rounded.xxl}` | 24px | Feature tiles |
| `{rounded.xxxl}` | 32px | Product cards, chart containers |
| `{rounded.feature}` | 40px | Hero panels |
| `{rounded.full}` | 100px | Buttons, badges, pills |
| `{rounded.circle}` | 9999px | Avatars, icon buttons |

## Components

### Buttons

**`button-primary`** — Black pill for primary actions ("Add to list", "View details").
- Background `{colors.ink-button}`, text `{colors.on-ink-button}`, padding `14px 30px`, rounded `{rounded.full}`.

**`button-buy-cta`** — Cobalt pill for "buy here" / "best price" actions.
- Background `{colors.primary}`, text `{colors.on-primary}`, padding `14px 30px`, rounded `{rounded.full}`.
- Only appears in comparison contexts where a store is highlighted as cheapest.

**`button-secondary`** — Outlined ghost for secondary actions.
- Transparent, text `{colors.ink-deep}`, border `2px solid {colors.ink-deep}`, padding `12px 28px`.

**`button-pill-tab`** + **`button-pill-tab-active`** — Category and filter navigation.
- Inactive: `{colors.canvas}` bg, `{colors.ink}` text, `1px solid {colors.hairline}`.
- Active: `{colors.ink-deep}` bg, `{colors.canvas}` text, no border.

**`button-icon-circular`** — 40×40px circular utility buttons (refresh, share, expand).

### Cards

**`card-product`** — Product card with image, name, brand, price range.
- Background `{colors.canvas}`, rounded `{rounded.xxxl}`, padding `{spacing.xxl}`, border `1px solid {colors.hairline-soft}`.

**`card-price-comparison`** — Core component: product header + store-by-store price rows.
- Background `{colors.canvas}`, rounded `{rounded.xxxl}`, padding `{spacing.xxl}`, border `1px solid {colors.hairline-soft}`.
- Contains: product thumbnail, name, brand, category chip, then a list of `store-row` elements.

**`card-stat`** — KPI card for dashboard (total spent, avg savings, alerts).
- Background `{colors.canvas}`, rounded `{rounded.xl}`, padding `{spacing.xl}`, border `1px solid {colors.hairline-soft}`.

**`card-chart`** — Price history chart container.
- Background `{colors.canvas}`, rounded `{rounded.xxxl}`, padding `{spacing.xxl}`, border `1px solid {colors.hairline-soft}`.

**`card-promo-strip`** — Dark full-width banner for alerts and promotions.
- Background `{colors.ink-deep}`, text `{colors.canvas}`, rounded `{rounded.xxxl}`, padding `{spacing.section}`.

### Badges & Status

**`badge-price-drop`** — Green pill with downward arrow: "−12%".
- Background `{colors.price-drop}`, text `{colors.canvas}`, rounded `{rounded.full}`, padding `4px 10px`.

**`badge-price-rise`** — Red pill with upward arrow: "+8%".
- Background `{colors.price-rise}`, text `{colors.canvas}`, rounded `{rounded.full}`, padding `4px 10px`.

**`badge-price-stable`** — Gray pill: "estável".
- Background `{colors.price-stable}`, text `{colors.canvas}`, rounded `{rounded.full}`, padding `4px 10px`.

**`badge-best-price`** — Blue pill: "melhor preço".
- Background `{colors.best-price}`, text `{colors.canvas}`, rounded `{rounded.full}`, padding `4px 10px`.

**`badge-store`** — Neutral pill with store initial: "P", "E", "C".
- Background `{colors.surface-soft}`, text `{colors.ink}`, rounded `{rounded.full}`, padding `4px 10px`.

### Price Display

**`price-tag`** — Large price figure.
- Typography `{typography.price-display}` (32px/700), color `{colors.ink-deep}`.

**`price-tag-unit`** — Unit suffix.
- Typography `{typography.price-unit}` (14px/400), color `{colors.steel}`.
- Examples: "/kg", "/un", "/L", "/100g".

### Store Comparison

**`store-row`** — Single store entry in a comparison list.
- Background `{colors.canvas}`, rounded `{rounded.lg}`, padding `{spacing.lg}`, border `1px solid {colors.hairline-soft}`.
- Contains: store name, price, variation badge, "buy here" CTA (if best price).

**`store-row-best`** — Highlighted store row (cheapest).
- Same as `store-row` but border `2px solid {colors.best-price}`.
- Contains `badge-best-price` and `button-buy-cta`.

### Navigation

**`nav-top`** — Sticky white bar with logo, search, filters.
- Background `{colors.canvas}`, border `1px solid {colors.hairline-soft}`, height 64px.

**`nav-pill-tab`** + **`nav-pill-tab-active`** — Category navigation.
- Same as `button-pill-tab` but in nav context.

### Filters

**`filter-chip`** + **`filter-chip-active`** — Horizontal filter bar.
- Inactive: `{colors.surface-soft}` bg, `{colors.ink}` text, rounded `{rounded.full}`, padding `6px 14px`.
- Active: `{colors.ink-deep}` bg, `{colors.canvas}` text.

### Tables

**`table-header`** — Table header row.
- Background `{colors.surface-soft}`, text `{colors.steel}`, typography `{typography.body-sm-bold}`.

**`table-row`** + **`table-row-alt`** — Table body rows with zebra striping.
- Row: `{colors.canvas}` bg. Alt: `{colors.surface-soft}` bg.
- Text `{colors.ink}`, typography `{typography.body-sm}`.

### Data Visualization

**`chart-line`** — Price trend line.
- 2px stroke, colors from store identity palette.

**`chart-grid`** — Chart grid lines.
- `1px solid {colors.hairline-soft}`.

### Feedback

**`tooltip`** — Hover tooltip for chart data points.
- Background `{colors.ink-deep}`, text `{colors.canvas}`, rounded `{rounded.lg}`, padding `{spacing.md}`.

**`empty-state`** — No data available.
- Background `{colors.surface-soft}`, text `{colors.steel}`, rounded `{rounded.xxxl}`, padding `{spacing.section}`.

**`skeleton`** — Loading placeholder.
- Background `{colors.surface-soft}`, rounded `{rounded.lg}`.

## Page Designs

### 1. Dashboard (Homepage)

**Purpose**: Overview of price comparisons, alerts, and quick actions.

**Layout**:
- Top nav: logo, search-pill, filter chips (category, store, period).
- Hero section: greeting + key stats (3 `card-stat` in a row).
- Main content: 12-column grid.
  - Left 8 cols: `card-chart` with price trends (top 5 products by variation).
  - Right 4 cols: `card-promo-strip` with alerts summary.
- Below: "Comparações recentes" — grid of `card-product` (4-up).
- Empty state: `empty-state` with CTA to add first receipt.

**Key Interactions**:
- Click product card → product detail page.
- Click store row → store detail page.
- Filter chips update all data on page.

### 2. Product Comparison Page

**Purpose**: Detailed price comparison for a single product across all stores.

**Layout**:
- Breadcrumb: Category › Product Name.
- Product header: thumbnail, name, brand, category chip, base unit.
- Price comparison card (`card-price-comparison`):
  - List of `store-row` elements, one per store.
  - Each row: store name, price, variation badge, last updated timestamp.
  - Best price row highlighted with `store-row-best` + `button-buy-cta`.
- Price history chart (`card-chart`): line chart with all stores overlaid.
- Similar products: horizontal scroll of `card-product` (same category).

**Key Interactions**:
- Click store name → store detail.
- Click "buy here" → external link or add to list.
- Time range selector: 7d, 30d, 90d, 12m.

### 3. Store Detail Page

**Purpose**: All products available at a single store, with price positioning.

**Layout**:
- Store header: name, CNPJ, location, store chip.
- Stats row: total products, avg price vs market, last visit.
- Product list: table with product name, category, price, variation, comparison to avg.
- Filter by category, sort by price/variation/name.

**Key Interactions**:
- Click product → product comparison page.
- Sort table by column.
- Export comparison data.

### 4. Review Queue (Staging)

**Purpose**: Human review of unmatched receipt lines.

**Layout**:
- List of `staging_receipts` with divergence info.
- Each receipt expandable to show `staging_lines`.
- Line actions: select product from dropdown, confirm match, discard.
- Side-by-side: raw description vs matched product.

**Key Interactions**:
- Search products by name.
- Keyboard navigation between lines.
- Bulk confirm for high-confidence matches.

## Do's and Don'ts

### Do
- Reserve `{colors.primary}` (cobalt) for best-price CTAs only — its weight comes from scarcity.
- Use `{colors.ink-button}` (black) for primary actions on dashboard and navigation.
- Apply `{rounded.full}` to every button, badge, and pill — squared corners signal "third-party widget".
- Apply `{rounded.xxxl}` to product and comparison cards, `{rounded.xl}` to stat cards.
- Use `{typography.price-display}` (32px/700) for all price figures — they are the primary data point.
- Pair every price variation badge with an arrow icon (↓ for drop, ↑ for rise).
- Highlight the best-price store with `store-row-best` border + `badge-best-price`.
- Use zebra striping (`table-row` / `table-row-alt`) for data tables.

### Don't
- Don't use `{colors.primary}` for non-best-price actions — it should only appear where a store is highlighted as cheapest.
- Don't use more than 4 store colors in a single chart — use patterns or direct labeling for additional stores.
- Don't display prices without units — always show "/kg", "/un", "/L" etc.
- Don't use red for anything other than price increases, green for anything other than price drops.
- Don't hide the variation badge — even "estável" is useful information.
- Don't use shadows on dashboard cards — elevation is reserved for sticky elements and tooltips.
- Don't truncate store names — they are the comparison axis and must be fully visible.

## Responsive Behavior

### Breakpoints

| Name | Width | Key Changes |
|---|---|---|
| Mobile (small) | < 480px | Single column. Hero drops to `{typography.heading-lg}`. Filter chips collapse to horizontal scroll. Store rows stack price above name. |
| Mobile (large) | 480–767px | Same as small but stat cards render 2-up. |
| Tablet | 768–1023px | 2-column grids. Filter bar returns. Comparison table shows 3 stores per row. |
| Desktop | 1024–1359px | Full 4-up product grids, 12-column dashboard, sticky comparison rail. |
| Wide Desktop | ≥ 1360px | Same as desktop with wider gutters and larger charts. |

### Touch Targets
- Pill buttons: 40–44px effective height.
- Icon buttons: 40×40px (44×44px on mobile).
- Store rows: minimum 56px tap height.
- Filter chips: 32px height with 8px horizontal padding.

### Collapsing Strategy
- **Filter chips**: horizontal scroll on mobile, wrap on desktop.
- **Store rows**: stack vertically on mobile (name → price → badge → CTA), inline on desktop.
- **Comparison table**: sticky first column on desktop, card-based list on mobile.
- **Charts**: reduce to sparklines on mobile, full line charts on desktop.
- **Stat cards**: 3-up on desktop, 2-up on tablet, 1-up on mobile.

## Iteration Guide

1. Focus on ONE component at a time — the system has high internal consistency.
2. Reference tokens directly (`{colors.primary}`, `{rounded.full}`) — never paraphrase.
3. Run `npx @google/design.md lint DESIGN.md` after edits.
4. Add new variants as separate component entries (`-pressed`, `-disabled`, `-focused`).
5. Default to `{typography.body-md}` for body, `{typography.subtitle-lg}` for emphasis.
6. Keep `{colors.primary}` scarce — if it appears on more than 2 elements per viewport, ask why.
7. Pill-shaped buttons always — squared buttons are filtered out.

## Known Gaps

- Dark mode tokens not defined — the system is light-only for now.
- Animation timings not specified — recommend 150–250ms ease-out for transitions.
- Chart library-specific tokens (tooltip, legend, axis) not formalized — use `tooltip` and `chart-line` as starting points.
- Mobile navigation pattern (drawer vs bottom nav) not decided — recommend bottom nav for dashboard, drawer for filters.
