# 🚚 Análise Logística — Olist E-commerce Dataset

> Projeto de análise em SQL puro investigando os gargalos logísticos da Olist, maior marketplace B2B do Brasil, com foco em diagnóstico de atrasos, atribuição de responsabilidade e recomendações quantificadas para o negócio.

---

## 📋 Índice

- [Contexto do Problema](#-contexto-do-problema)
- [Dataset](#-dataset)
- [Modelo de Dados](#-modelo-de-dados)
- [Estrutura do Projeto](#-estrutura-do-projeto)
- [Metodologia](#-metodologia)
- [Principais Achados](#-principais-achados)
- [Recomendações](#-recomendações)
- [Como Executar](#-como-executar)
- [Tecnologias](#-tecnologias)
- [Próximos Passos](#-próximos-passos)

---

## 🎯 Contexto do Problema

A Olist conecta vendedores de pequeno e médio porte a grandes marketplaces brasileiros. Por operar como intermediária logística, a empresa depende de transportadoras parceiras para cumprir os prazos prometidos ao cliente final — e qualquer falha nessa cadeia impacta diretamente a experiência de compra e o risco de churn.

Este projeto parte de uma pergunta de negócio central:

> **"Por que pedidos atrasam — e o que pode ser feito para reduzir esses atrasos?"**

A análise busca ir além do diagnóstico superficial ("X% dos pedidos atrasam") e identificar **quem** atrasa, **onde** atrasa e **quanto isso custa** financeiramente — fechando o ciclo com recomendações concretas e simulações quantificadas.

---

## 📦 Dataset

**Fonte:** [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — disponível no Kaggle.

O dataset contém ~100.000 pedidos realizados entre 2016 e 2018 em múltiplos marketplaces brasileiros, com informações sobre pedidos, itens, clientes, vendedores, produtos e avaliações.

**Tabelas utilizadas neste projeto:**

| Tabela | Descrição | Linhas (aprox.) |
|---|---|---|
| `olist_orders` | Ciclo de vida de cada pedido com todos os timestamps | ~99.000 |
| `olist_order_items` | Itens individuais de cada pedido (preço, frete, prazo) | ~112.000 |
| `olist_customers` | Dados cadastrais e geográficos dos clientes | ~99.000 |
| `olist_sellers` | Dados cadastrais e geográficos dos vendedores | ~3.000 |
| `olist_products` | Atributos dos produtos, incluindo peso | ~32.000 |

---

## 🗂️ Modelo de Dados

```
olist_customers          olist_orders              olist_order_items
─────────────────        ──────────────────────    ──────────────────────────
customer_id (PK) ───── ► customer_id (FK)          order_id (PK, FK) ◄─────┐
customer_unique_id       order_id (PK)             order_item_id (PK)       │
customer_city            order_status              seller_id (FK) ──────┐   │
customer_state           order_purchase_timestamp  product_id (FK)      │   │
                         order_approved_at         shipping_limit_date  │   │
                         order_delivered_carrier   price                │   │
                         order_delivered_customer  freight_value        │   │
                         order_estimated_delivery                       │   │
                                │                                       │   │
                                └───────────────────────────────────────┘   │
                                                                             │
olist_sellers                                      olist_orders ────────────┘
─────────────────
seller_id (PK)
seller_city
seller_state
```

**Relações importantes:**
- Um pedido (`order_id`) pode ter **múltiplos itens** em `olist_order_items` — esse é o principal desafio de granularidade do projeto, resolvido em `limpeza.sql`
- `customer_id` em `olist_customers` **não é único por pessoa física** — use `customer_unique_id` para análises de recorrência

---

## 📁 Estrutura do Projeto

```
olist-logistica-sql/
│
├── README.md                    ← você está aqui
│
├── criando_tabelas.sql          ← 1. DDL: criação do schema relacional
├── limpeza.sql                  ← 2. Tratamento de nulos, duplicatas e view master
├── analise_exploratoria.sql     ← 3. EDA: distribuições, KPIs e primeiros padrões
└── insights.sql                 ← 4. Deep dive nos 4 gaps + impacto financeiro
```

**Os arquivos devem ser executados nessa ordem.** Cada um depende do anterior.

---

## 🔬 Metodologia

### Etapa 1 — Modelagem (`criando_tabelas.sql`)
Criação das 4 tabelas base com tipagem adequada, chaves primárias e constraints de integridade referencial.

### Etapa 2 — Limpeza e Preparação (`limpeza.sql`)

**Tratamento de nulos:** das 3 colunas críticas para cálculo de atraso, apenas `order_delivered_customer_date` possui nulos. A estratégia foi filtrar `order_status = 'delivered'` — eliminando naturalmente pedidos cancelados e em trânsito — e descartar os registros remanescentes com nulo, que representam erros de sistema.

**Resolução de duplicatas:** `olist_order_items` tem granularidade de item, não de pedido. Um pedido com 3 itens gera 3 linhas com o mesmo `order_id`. A solução foi agregar para granularidade de pedido com as seguintes decisões:

| Campo | Função | Justificativa |
|---|---|---|
| `shipping_limit_date` | `MIN` | Prazo mais restritivo — o vendedor precisa postar todos os itens |
| `price` | `SUM` | Valor total do pedido |
| `freight_value` | `SUM` | Custo total de frete |
| `order_item_id` | `COUNT` | Quantidade de itens por pedido |

**View master:** `v_master_logistica` unifica todas as tabelas em uma estrutura única, já com as métricas derivadas calculadas:

| Métrica | Cálculo | Interpretação |
|---|---|---|
| `sla_prometido` | `estimated_delivery - purchase` | Prazo prometido ao cliente (em dias) |
| `lead_time_real` | `delivered_customer - purchase` | Tempo real de entrega (em dias) |
| `dias_atraso` | `delivered_customer - estimated_delivery` | Positivo = atrasou \| Negativo = adiantou |

### Etapa 3 — EDA (`analise_exploratoria.sql`)
Análise exploratória sistemática cobrindo distribuição estatística do SLA e lead time, concentração geográfica de vendedores e clientes, SLA hit rate global, classificação de severidade dos atrasos e diagnóstico inicial de responsabilidade (vendedor vs transportadora).

### Etapa 4 — Insights (`insights.sql`)
Deep dive em 4 gaps identificados na EDA, com investigações específicas por gap, impacto financeiro em GMV e simulação quantificada do impacto de ajustes de SLA.

---

## 🔍 Principais Achados

### Gap 1 — Nordeste: transportadora falha em 95% dos atrasos

A região Nordeste concentra ~10% do volume de pedidos e registra 12% de taxa de atraso. Ao isolar a responsabilidade, descobriu-se que **95% dos atrasos no Nordeste são causados pela transportadora**, não pelos vendedores — que postam dentro do prazo na esmagadora maioria dos casos.

A comparação entre SLA prometido e lead time real dos pedidos já atrasados confirma que o prazo está sendo subestimado para a malha da região: a transportadora simplesmente não consegue cumprir o tempo alocado para ela nas rotas que atravessam o Brasil.

---

### Gap 2 — Rio de Janeiro: o dobro do tempo de SP com metade da distância

O RJ registra ~12% de taxa de atraso, desproporcionalmente alto comparado a SP (~400km de distância). Para isolar a variável, analisamos exclusivamente pedidos com **origem em SP**, comparando os destinos SP e RJ:

> O tempo médio de transporte para RJ é significativamente maior do que para SP — muitas vezes o dobro ou o triplo — mesmo com a distância física sendo pequena entre as capitais.

Isso prova que o problema não é o vendedor do RJ: é a **capilaridade da transportadora no estado**, que não consegue circular com a mesma fluidez que em SP.

---

### Gap 3 — Malha logística: a transportadora é o gargalo nacional

A análise de performance por estado (filtrando apenas pedidos atrasados e com volume > 50) mostra que em todos os principais estados o **tempo de trânsito real supera o estimado**. O gap entre o que a transportadora prometeu e o que entregou é sistêmico, não isolado em uma região.

---

### Gap 4 — Efeito fim de semana: vendedores não operam sábado e domingo

Pedidos realizados na sexta-feira, sábado e domingo têm **maior tempo médio de postagem** (purchase → carrier) do que pedidos feitos em dias úteis. O tempo de transporte (carrier → customer) permanece estável — confirmando que o gargalo nesse caso é exclusivamente o vendedor, que concentra as postagens nos dias úteis.

---

## 💡 Recomendações

| Gap | Ação | Prazo | Impacto Esperado |
|---|---|---|---|
| Nordeste | Aumentar SLA prometido em +7 dias | Curto | +6,17 p.p. no hit rate do Nordeste (simulado) |
| Nordeste | Atrair vendedores regionais ou criar CD no Nordeste | Longo | Redução estrutural do lead time |
| RJ | Avaliar transportadora alternativa para rota SP→RJ | Médio | Redução do tempo de trânsito |
| Nacional | Renegociar contratos com SLAs de trânsito realistas por rota | Médio | Melhora do hit rate global |
| Fim de semana | SLA dinâmico: +1 ou +2 dias para pedidos de sex/sáb/dom | Curto | Redução de atrasos de pedidos de fim de semana |
| Fim de semana | Programa de incentivo à postagem em 24h | Médio | Redução do tempo de postagem |

### Simulação: ajuste de SLA no Nordeste

```
Cenário atual:     hit rate Nordeste = X%
Cenário simulado:  hit rate Nordeste = X + 6,17 p.p.
                   (SLA aumentado em 7 dias, lead time real inalterado)
```

> **Limitação:** a simulação assume que o comportamento dos clientes e da transportadora não muda com o novo SLA. Na prática, um prazo maior pode reduzir a taxa de conversão. O resultado representa o **ganho máximo potencial**, não o garantido.

---

## ▶️ Como Executar

### Pré-requisitos
- PostgreSQL 13+ (as queries utilizam funções como `PERCENTILE_CONT` e `MATERIALIZED VIEW`)
- Schema `olist_dataset` criado previamente: `CREATE SCHEMA IF NOT EXISTS olist_dataset;`
- Dados do dataset Olist carregados nas tabelas (disponíveis no [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce))

### Ordem de execução

```sql
-- 1. Criar as tabelas
\i criando_tabelas.sql

-- 2. Tratar os dados e criar a view master
\i limpeza.sql

-- 3. Rodar a análise exploratória
\i analise_exploratoria.sql

-- 4. Rodar os insights e simulações
\i insights.sql
```

### Objetos criados ao final da execução

| Objeto | Tipo | Arquivo | Descrição |
|---|---|---|---|
| `olist_sellers` | Table | criando_tabelas.sql | Dados dos vendedores |
| `olist_customers` | Table | criando_tabelas.sql | Dados dos clientes |
| `olist_orders` | Table | criando_tabelas.sql | Ciclo de vida dos pedidos |
| `olist_order_items` | Table | criando_tabelas.sql | Itens de cada pedido |
| `v_master_logistica` | View | limpeza.sql | Base unificada e tratada para análise |
| `mv_outliers_logistica` | Materialized View | analise_exploratoria.sql | Pedidos com atraso classificados por IQR por estado |

---

## 🛠️ Tecnologias

- **PostgreSQL 13+** — banco de dados principal
- **SQL puro** — sem uso de Python, R ou ferramentas de BI
  - Window Functions (`ROW_NUMBER`, `DENSE_RANK`, `SUM OVER`)
  - CTEs encadeadas (`WITH`)
  - Funções estatísticas (`PERCENTILE_CONT`, `STDDEV`)
  - Agregações condicionais (`SUM(CASE WHEN ...)`)
  - `ROLLUP` para subtotais automáticos
  - `MATERIALIZED VIEW` para persistência de cálculos custosos

---

## 🔭 Próximos Passos

Análises que complementariam este projeto e ficaram fora do escopo atual:

- **Correlação entre atraso e nota de avaliação do vendedor** — verificar se pedidos atrasados recebem avaliações menores e quantificar o impacto no NPS
- **Análise de sazonalidade** — investigar se há períodos do ano (Black Friday, Natal) com pico de atrasos e se o SLA é ajustado nesses períodos
- **Análise de reincidência por cliente** — clientes que receberam pedidos atrasados compram novamente? Qual a taxa de churn associada ao atraso?
- **Modelo de risco de atraso por pedido** — usando as variáveis disponíveis (estado de origem/destino, peso, dia da semana, seller_id), seria possível construir um score de risco de atraso no momento da compra para ajuste dinâmico do SLA

---

*Projeto desenvolvido como portfólio de análise de dados com SQL.*
