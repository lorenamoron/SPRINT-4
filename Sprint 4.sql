-- Nivel 1: Entorno e ingesta híbrida (Code-First)
-- Ejercicio 1: Consulta sobre una tabla no optimizada (diagnóstico)

SELECT
  tc.transaction_id,
  tc.`timestamp`,
  cc.company_id,
  cc.company_name,
  tc.amount
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_clean` AS tc
JOIN `sprint3-analytics-lorena-moron.sprint3_silver.companies_clean`   AS cc
  ON tc.business_id = cc.company_id
WHERE DATE(tc.`timestamp`) = '2022-03-12'
  AND cc.country = 'Germany';

-- Ejercicio 2: Rediseño y optimización del almacenamiento (Partition & Cluster)
-- Paso 1: Tabla intermedia con modif de `timestamp`

CREATE OR REPLACE TABLE `sprint3-analytics-lorena-moron.sprint3_silver.transactions_recent` AS
SELECT * EXCEPT(`timestamp`),
  TIMESTAMP_SUB(
    CURRENT_TIMESTAMP(),
    INTERVAL CAST(RAND() * 50 AS INT64) DAY) AS `timestamp`
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_clean`;

-- Paso 2: tabla optimizada (Partitioning & Clustering)

CREATE OR REPLACE TABLE `sprint3-analytics-lorena-moron.sprint3_gold.fact_transactions_optimized`
PARTITION BY DATE(`timestamp`)
CLUSTER BY business_id
AS
SELECT *
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_recent`;

-- Ejercicio 3: La prueba de fuego (Benchmark)

-- Paso 1: codigo para tabla NO optimizada)
SELECT *
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_recent`
WHERE DATE(`timestamp`) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 29 DAY)
                            AND CURRENT_DATE();

-- Paso 2: codigo para tabla OPTIMIZADA
SELECT *
FROM `sprint3-analytics-lorena-moron.sprint3_gold.fact_transactions_optimized`
WHERE DATE(`timestamp`) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 29 DAY)
                            AND CURRENT_DATE();
                            
-- Ejercicio 4: Smart Caching (vistas materializadas)

--Creación de la vista materializada
CREATE MATERIALIZED VIEW `sprint3-analytics-lorena-moron.sprint3_gold.mv_daily_sales` AS
SELECT DATE(fto.`timestamp`) AS `data`, SUM(fto.amount) AS total_ventas
FROM `sprint3-analytics-lorena-moron.sprint3_gold.fact_transactions_optimized` AS fto
WHERE declined = 0
GROUP BY `data`;   

-- Consulta de la VM
SELECT
  data,
  ROUND(total_ventas, 2) AS total_ventas
FROM `sprint3-analytics-lorena-moron.sprint3_gold.mv_daily_sales`
ORDER BY data;

-- Nivel 2: SQL analítico avanzado

-- Ejercicio 1: Perfilado de clientes VIP (métricas agregadas con CTE)

WITH vip_stats AS(
  SELECT
    fto.user_id,
    ROUND(SUM(fto.amount), 2) AS total_gasto, 
    COUNT(fto.transaction_id) AS n_transacciones, 
    ROUND(AVG(fto.amount), 2) AS ticket_medio, 
    MAX(fto.amount) AS compra_maxima
  FROM `sprint3-analytics-lorena-moron.sprint3_gold.fact_transactions_optimized` AS fto
  WHERE fto.declined = 0 
  GROUP BY fto.user_id
  HAVING SUM(fto.amount) > 500)

  SELECT vs.user_id, 
   CONCAT(uc.name, ' ', uc.surname) AS nombre_cliente, 
    uc.email,
    vs.n_transacciones, 
    vs.ticket_medio,
    vs.compra_maxima,
    vs.total_gasto
  FROM vip_stats AS vs
  JOIN `sprint3-analytics-lorena-moron.sprint3_silver.users_combined` AS uc
    ON vs.user_id = uc.user_id
  ORDER BY vs.total_gasto DESC;

  -- Ejercicio 2: Análisis de tendencias (Window Functions sobre vistas)

WITH ventas_diarias AS (
  SELECT
    ds.data,
    ds.total_ventas                                AS ventas_hoy,
    LAG(ds.total_ventas) OVER (ORDER BY ds.data)   AS ventas_ayer
  FROM `sprint3-analytics-lorena-moron.sprint3_gold.mv_daily_sales` AS ds
)
SELECT
  vd.data,
  ROUND(vd.ventas_hoy, 2)  AS ventas_hoy,
  ROUND(vd.ventas_ayer, 2) AS ventas_ayer,
  ROUND(SAFE_DIVIDE(vd.ventas_hoy - vd.ventas_ayer, vd.ventas_ayer) * 100, 2) AS dif_porcentual
FROM ventas_diarias AS vd
ORDER BY vd.data;

-- Ejercicio 3: Totales acumulados (Running Totals sobre vistas)

SELECT
  ds.data,
  ROUND(ds.total_ventas, 2) AS ventas_dia,
  ROUND(
    SUM(ds.total_ventas) OVER (
      PARTITION BY EXTRACT(YEAR FROM ds.data)   
      ORDER BY ds.data
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2)  AS ventas_acumuladas_ytd
FROM `sprint3-analytics-lorena-moron.sprint3_gold.mv_daily_sales` AS ds
ORDER BY ds.data;

-- Ejercicio 4: Fidelización y valor del cliente (filtrado avanzado)

WITH primeras_compras AS (
  SELECT
    tc.user_id,
    tc.`timestamp`,
    tc.amount,
    ROW_NUMBER() OVER (
      PARTITION BY tc.user_id                     
      ORDER BY tc.`timestamp`, tc.transaction_id 
    ) AS n_compra
  FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_clean` AS tc
  WHERE tc.declined = 0
  QUALIFY n_compra <= 3
),
metricas AS (
  SELECT
    pc.user_id,
    MAX(IF(pc.n_compra = 3, pc.`timestamp`, NULL))   AS fecha_3a_compra,
    MAX(IF(pc.n_compra = 3, pc.amount, NULL))        AS importe_3a_compra,
    ROUND(AVG(pc.amount), 2)                         AS media_3_primeras
  FROM primeras_compras AS pc
  GROUP BY pc.user_id
  HAVING COUNT(*) = 3
)
SELECT
  m.user_id,
  CONCAT(uc.name, ' ', uc.surname) AS nombre_completo,
  uc.email,
  m.fecha_3a_compra,
  m.importe_3a_compra,
  m.media_3_primeras
FROM metricas AS m
JOIN `sprint3-analytics-lorena-moron.sprint3_silver.users_combined` AS uc
  ON m.user_id = uc.user_id
ORDER BY m.media_3_primeras DESC;

-- Nivel 3: Analytics Engineering (Arrays y automatización)

-- Ejercicio 1: Desanidado y aplanado de datos (Unnesting)

CREATE OR REPLACE TABLE `sprint3-analytics-lorena-moron.sprint3_gold.dim_transactions_flat` AS
SELECT
  tc.transaction_id,
  tc.`timestamp`,
  tc.amount              AS total_ticket,
  id_product             AS product_sku,    
  pc.name                 AS product_name,
  pc.price                AS product_price
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_clean` AS tc
CROSS JOIN UNNEST(tc.product_ids) AS id_product
JOIN `sprint3-analytics-lorena-moron.sprint3_silver.products_clean` AS pc
  ON id_product = pc.product_id
WHERE tc.declined = 0;       

-- Ejercicio 2: El ranking de ventas (agregación simple)

SELECT dtf.product_sku,
  dtf.product_name,
  COUNT (dtf.product_sku) AS q_sales
FROM `sprint3-analytics-lorena-moron.sprint3_gold.dim_transactions_flat` AS dtf
GROUP By dtf.product_sku, dtf.product_name
ORDER BY q_sales DESC
LIMIT 5;

-- Ejercicio 3: Automatización del pipeline y visualización
-- Paso 1: Creación de UDF

CREATE OR REPLACE FUNCTION `sprint3-analytics-lorena-moron.sprint3_gold.calculate_tax`(amount FLOAT64)
RETURNS FLOAT64
AS (
  amount * 1.21
);

-- Paso 2: Modificación de la tabla dim_transactions_flat

CREATE OR REPLACE TABLE `sprint3-analytics-lorena-moron.sprint3_gold.dim_transactions_flat` AS
SELECT
  tc.transaction_id,
  tc.`timestamp`,
  tc.amount              AS total_ticket,
  id_product             AS product_sku,    
  pc.name                 AS product_name,
  pc.price                AS product_price,
  ROUND(`sprint3-analytics-lorena-moron.sprint3_gold.calculate_tax`(pc.price) - pc.price,2) AS product_tax_amount,
  ROUND(`sprint3-analytics-lorena-moron.sprint3_gold.calculate_tax`(pc.price),2)            AS product_price_tax_inc
FROM `sprint3-analytics-lorena-moron.sprint3_silver.transactions_clean` AS tc
CROSS JOIN UNNEST(tc.product_ids) AS id_product
JOIN `sprint3-analytics-lorena-moron.sprint3_silver.products_clean` AS pc
  ON id_product = pc.product_id
WHERE tc.declined = 0;       
