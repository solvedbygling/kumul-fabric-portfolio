/* =====================================================================
   KUMUL — GOLD LAYER (Fabric Warehouse: WH_Gold)
   Run each BLOCK on its own: paste one block into a query tab, Run,
   then replace it with the next block. Don't run the whole file at once.

   Assumes your silver lakehouse is called LH_Silver. If not, use
   Find & Replace on "LH_Silver" before running.

   Fabric Warehouse notes (why the code looks the way it does):
   - No nvarchar/tinyint/datetime types  -> varchar, int, datetime2(6)
   - No enforced primary keys / IDENTITY -> surrogate keys via ROW_NUMBER
   - Silver is read with 3-part names: LH_Silver.dbo.<table>
   - Silver table names are lower case (Spark stores them that way) and
     the warehouse is case-sensitive, so they must be written in lower case
   ===================================================================== */


/* =====================================================================
   BLOCK 1 — Schemas  (run once)
   ===================================================================== */
IF SCHEMA_ID('dim')  IS NULL EXEC('CREATE SCHEMA dim');
IF SCHEMA_ID('fact') IS NULL EXEC('CREATE SCHEMA fact');
IF SCHEMA_ID('etl')  IS NULL EXEC('CREATE SCHEMA etl');


/* =====================================================================
   BLOCK 2 — Tables + Date dimension  (run once)
   WARNING: re-running this wipes dim.Customer history.
   ===================================================================== */
DROP TABLE IF EXISTS dim.[Date];
CREATE TABLE dim.[Date] (
    DateKey          int          NOT NULL,   -- 20250131
    [Date]           date         NOT NULL,
    [Year]           smallint     NOT NULL,
    [Quarter]        varchar(2)   NOT NULL,   -- Q1
    MonthNumber      smallint     NOT NULL,
    [MonthName]      varchar(10)  NOT NULL,
    MonthStart       date         NOT NULL,
    YearMonth        varchar(8)   NOT NULL,   -- 2025-Jan
    DayOfWeekNumber  smallint     NOT NULL,   -- 1=Mon … 7=Sun
    [DayName]        varchar(10)  NOT NULL,
    IsWeekend        bit          NOT NULL,
    AUFinancialYear  varchar(9)   NOT NULL    -- FY2025-26 (Jul–Jun)
);

INSERT INTO dim.[Date]
SELECT
    CAST(CONVERT(char(8), x.dt, 112) AS int),
    x.dt,
    YEAR(x.dt),
    CONCAT('Q', DATEPART(QUARTER, x.dt)),
    MONTH(x.dt),
    DATENAME(MONTH, x.dt),
    DATEFROMPARTS(YEAR(x.dt), MONTH(x.dt), 1),
    CONCAT(YEAR(x.dt), '-', LEFT(DATENAME(MONTH, x.dt), 3)),
    DATEDIFF(DAY, '19000101', x.dt) % 7 + 1,
    DATENAME(WEEKDAY, x.dt),
    CASE WHEN DATEDIFF(DAY, '19000101', x.dt) % 7 >= 5 THEN 1 ELSE 0 END,
    CONCAT('FY', fy.y, '-', RIGHT(CAST(fy.y + 1 AS varchar(4)), 2))
FROM (
    SELECT DATEADD(DAY, n.i, CAST('2024-01-01' AS date)) AS dt
    FROM (
        SELECT TOP (1461) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM       (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) a(n)
        CROSS JOIN (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) b(n)
        CROSS JOIN (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) c(n)
        CROSS JOIN (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(n)
    ) n
) x
CROSS APPLY (SELECT CASE WHEN MONTH(x.dt) >= 7 THEN YEAR(x.dt) ELSE YEAR(x.dt) - 1 END AS y) fy;

DROP TABLE IF EXISTS dim.Entity;
CREATE TABLE dim.Entity (
    EntityKey     int           NOT NULL,
    EntityCode    varchar(3)    NOT NULL,
    EntityName    varchar(100)  NOT NULL,
    CountryName   varchar(50)   NOT NULL,
    BaseCurrency  varchar(3)    NOT NULL
);

DROP TABLE IF EXISTS dim.Warehouse;
CREATE TABLE dim.Warehouse (
    WarehouseKey   int           NOT NULL,
    EntityKey      int           NOT NULL,
    WarehouseName  varchar(100)  NOT NULL,
    City           varchar(50)   NOT NULL
);

DROP TABLE IF EXISTS dim.Product;
CREATE TABLE dim.Product (
    ProductKey      int            NOT NULL,
    SKU             varchar(20)    NOT NULL,
    ProductName     varchar(150)   NOT NULL,
    Category        varchar(50)    NOT NULL,
    PackSize        varchar(30)    NOT NULL,
    UnitCostAUD     decimal(10,2)  NOT NULL,
    ListPriceAUD    decimal(10,2)  NOT NULL,
    IsActive        bit            NOT NULL,
    IsPriceMissing  bit            NOT NULL
);

DROP TABLE IF EXISTS dim.Customer;
CREATE TABLE dim.Customer (
    CustomerKey    bigint         NOT NULL,   -- surrogate key (one per version)
    CustomerID     int            NOT NULL,   -- business key from the ERP
    CustomerCode   varchar(12)    NOT NULL,
    EntityKey      int            NOT NULL,
    CustomerName   varchar(150)   NOT NULL,   -- Type 1 (overwrite)
    CustomerType   varchar(30)    NOT NULL,   -- Type 2 (history)
    City           varchar(50)    NULL,       -- Type 2
    StateProvince  varchar(50)    NULL,       -- Type 2
    CreditLimit    decimal(12,2)  NULL,       -- Type 2
    IsActive       bit            NOT NULL,   -- Type 1
    ValidFrom      datetime2(6)   NOT NULL,
    ValidTo        datetime2(6)   NOT NULL,
    IsCurrent      bit            NOT NULL
);

-- "Unknown" member so a fact row never loses its customer link
INSERT INTO dim.Customer VALUES
 (-1, -1, 'UNKNOWN', 0, 'Unknown customer', 'Unknown', NULL, NULL, NULL, 1,
  '1900-01-01', '9999-12-31', 1);

DROP TABLE IF EXISTS fact.Sales;
CREATE TABLE fact.Sales (
    SalesOrderLineID      int            NOT NULL,
    SalesOrderID          int            NOT NULL,
    OrderNumber           varchar(20)    NOT NULL,
    LineNumber            smallint       NOT NULL,
    OrderDateKey          int            NOT NULL,
    RequiredDateKey       int            NULL,
    ShippedDateKey        int            NULL,
    CustomerKey           bigint         NOT NULL,
    ProductKey            int            NOT NULL,
    WarehouseKey          int            NOT NULL,
    EntityKey             int            NOT NULL,
    OrderStatus           varchar(15)    NOT NULL,
    CurrencyCode          varchar(3)     NOT NULL,
    Quantity              int            NOT NULL,
    UnitPriceLocal        decimal(12,2)  NOT NULL,
    DiscountPct           decimal(5,2)   NOT NULL,
    SalesAmountLocal      decimal(18,2)  NOT NULL,
    FxRateToAUD           decimal(12,6)  NULL,
    SalesAmountAUD        decimal(18,2)  NULL,
    CostAmountAUD         decimal(18,2)  NOT NULL,
    GrossMarginAUD        decimal(18,2)  NULL,
    DaysToShip            int            NULL,
    IsShippedLate         bit            NULL,
    IsReturn              bit            NOT NULL,
    IsOrderDateCorrected  bit            NOT NULL,
    IsShipDateImputed     bit            NOT NULL
);

DROP TABLE IF EXISTS etl.LoadLog;
CREATE TABLE etl.LoadLog (
    LoadStep      varchar(50)   NOT NULL,
    RowsInTable   int           NULL,
    LoadedAt      datetime2(6)  NOT NULL
);


/* =====================================================================
   BLOCK 3 — Procedure: load dimensions (incl. SCD2 customer)
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_Load_Dimensions
AS
BEGIN
    /* ---- Type 1 dimensions: small, so full refresh ---- */
    DELETE FROM dim.Entity;
    INSERT INTO dim.Entity (EntityKey, EntityCode, EntityName, CountryName, BaseCurrency)
    SELECT EntityID, EntityCode, EntityName, CountryName, BaseCurrency
    FROM LH_Silver.dbo.entity;

    DELETE FROM dim.Warehouse;
    INSERT INTO dim.Warehouse (WarehouseKey, EntityKey, WarehouseName, City)
    SELECT WarehouseID, EntityID, WarehouseName, City
    FROM LH_Silver.dbo.warehouse;

    DELETE FROM dim.Product;
    INSERT INTO dim.Product (ProductKey, SKU, ProductName, Category, PackSize, UnitCostAUD, ListPriceAUD, IsActive, IsPriceMissing)
    SELECT ProductID, SKU, ProductName, Category, PackSize, UnitCostAUD, ListPriceAUD, IsActive, IsPriceMissing
    FROM LH_Silver.dbo.product;

    /* ---- Customer: SCD Type 2 ---- */

    -- Step 1: Type 1 attributes (name, active) overwrite every version
    UPDATE d
       SET d.CustomerName = s.CustomerName,
           d.IsActive     = s.IsActive
      FROM dim.Customer AS d
      JOIN LH_Silver.dbo.customer AS s ON s.CustomerID = d.CustomerID
     WHERE d.CustomerName <> s.CustomerName
        OR d.IsActive     <> s.IsActive;

    -- Step 2: close off the current version where a tracked attribute changed
    UPDATE d
       SET d.ValidTo   = s.ModifiedAt,
           d.IsCurrent = 0
      FROM dim.Customer AS d
      JOIN LH_Silver.dbo.customer AS s ON s.CustomerID = d.CustomerID
     WHERE d.IsCurrent = 1
       AND (   d.CustomerType                <> s.CustomerType
            OR ISNULL(d.City, '')            <> ISNULL(s.City, '')
            OR ISNULL(d.StateProvince, '')   <> ISNULL(s.StateProvince, '')
            OR ISNULL(d.CreditLimit, -1)     <> ISNULL(s.CreditLimit, -1));

    -- Step 3: insert a new current version for changed + brand-new customers
    DECLARE @MaxKey bigint = (SELECT ISNULL(MAX(CustomerKey), 0) FROM dim.Customer);

    INSERT INTO dim.Customer
        (CustomerKey, CustomerID, CustomerCode, EntityKey, CustomerName, CustomerType, City,
         StateProvince, CreditLimit, IsActive, ValidFrom, ValidTo, IsCurrent)
    SELECT
        @MaxKey + ROW_NUMBER() OVER (ORDER BY s.CustomerID),
        s.CustomerID, s.CustomerCode, s.EntityID, s.CustomerName, s.CustomerType, s.City,
        s.StateProvince, s.CreditLimit, s.IsActive,
        CASE WHEN EXISTS (SELECT 1 FROM dim.Customer x WHERE x.CustomerID = s.CustomerID)
             THEN s.ModifiedAt                          -- new version of a known customer
             ELSE CAST('1900-01-01' AS datetime2(6))     -- first version covers all history
        END,
        CAST('9999-12-31' AS datetime2(6)),
        1
    FROM LH_Silver.dbo.customer AS s
    WHERE NOT EXISTS (SELECT 1 FROM dim.Customer d
                      WHERE d.CustomerID = s.CustomerID AND d.IsCurrent = 1);
END;


/* =====================================================================
   BLOCK 4 — Procedure: load fact.Sales (inside a transaction)
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_Load_FactSales
AS
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM fact.Sales;

        INSERT INTO fact.Sales
            (SalesOrderLineID, SalesOrderID, OrderNumber, LineNumber,
             OrderDateKey, RequiredDateKey, ShippedDateKey,
             CustomerKey, ProductKey, WarehouseKey, EntityKey,
             OrderStatus, CurrencyCode, Quantity, UnitPriceLocal, DiscountPct,
             SalesAmountLocal, FxRateToAUD, SalesAmountAUD, CostAmountAUD, GrossMarginAUD,
             DaysToShip, IsShippedLate, IsReturn, IsOrderDateCorrected, IsShipDateImputed)
        SELECT
            l.SalesOrderLineID,
            l.SalesOrderID,
            h.OrderNumber,
            l.LineNumber,
            CAST(CONVERT(char(8), h.OrderDate, 112) AS int),
            CAST(CONVERT(char(8), h.RequiredDate, 112) AS int),
            CAST(CONVERT(char(8), h.ShippedDate, 112) AS int),
            ISNULL(c.CustomerKey, -1),
            l.ProductID,
            h.WarehouseID,
            h.EntityID,
            h.OrderStatus,
            h.CurrencyCode,
            l.Quantity,
            l.UnitPrice,
            l.DiscountPct,
            l.LineAmountLocal,
            fx.AUDPerUnit,
            CAST(l.LineAmountLocal * fx.AUDPerUnit AS decimal(18,2)),
            CAST(l.Quantity * p.UnitCostAUD AS decimal(18,2)),
            CAST(l.LineAmountLocal * fx.AUDPerUnit - l.Quantity * p.UnitCostAUD AS decimal(18,2)),
            DATEDIFF(DAY, h.OrderDate, h.ShippedDate),
            CASE WHEN h.ShippedDate IS NULL THEN NULL
                 WHEN h.ShippedDate > h.RequiredDate THEN 1 ELSE 0 END,
            ISNULL(l.IsReturn, 0),
            ISNULL(h.IsOrderDateCorrected, 0),
            ISNULL(h.IsShipDateImputed, 0)
        FROM LH_Silver.dbo.salesorderline   AS l
        JOIN LH_Silver.dbo.salesorderheader AS h ON h.SalesOrderID = l.SalesOrderID
        JOIN dim.Product                    AS p ON p.ProductKey   = l.ProductID
        -- point-in-time customer: the version that was current when the order was created
        LEFT JOIN dim.Customer AS c
               ON c.CustomerID = h.CustomerID
              AND h.CreatedAt >= c.ValidFrom
              AND h.CreatedAt <  c.ValidTo
        -- monthly FX rate for the order's currency
        LEFT JOIN LH_Silver.dbo.fxrate AS fx
               ON fx.CurrencyCode = h.CurrencyCode
              AND fx.RateMonth    = DATEFROMPARTS(YEAR(h.OrderDate), MONTH(h.OrderDate), 1);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;


/* =====================================================================
   BLOCK 5 — Procedure: master load (this is what the pipeline calls)
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_Load_Gold
AS
BEGIN
    EXEC etl.usp_Load_Dimensions;
    EXEC etl.usp_Load_FactSales;

    INSERT INTO etl.LoadLog (LoadStep, RowsInTable, LoadedAt)
    SELECT 'dim.Customer', COUNT(*), SYSUTCDATETIME() FROM dim.Customer
    UNION ALL
    SELECT 'fact.Sales',   COUNT(*), SYSUTCDATETIME() FROM fact.Sales;
END;


/* =====================================================================
   BLOCK 6 — Run it and sanity-check
   ===================================================================== */
EXEC etl.usp_Load_Gold;

-- Row counts (fact.Sales should equal silver SalesOrderLine)
SELECT 'fact.Sales' AS TableName, COUNT(*) AS [Rows] FROM fact.Sales
UNION ALL SELECT 'dim.Customer', COUNT(*) FROM dim.Customer
UNION ALL SELECT 'dim.Product',  COUNT(*) FROM dim.Product
UNION ALL SELECT 'dim.Date',     COUNT(*) FROM dim.[Date];

-- Revenue by entity: local currency vs AUD
SELECT e.EntityCode,
       f.CurrencyCode,
       SUM(f.SalesAmountLocal) AS SalesLocal,
       SUM(f.SalesAmountAUD)   AS SalesAUD,
       SUM(f.GrossMarginAUD)   AS MarginAUD
FROM fact.Sales f
JOIN dim.Entity e ON e.EntityKey = f.EntityKey
GROUP BY e.EntityCode, f.CurrencyCode;

-- Data checks: should all be 0
SELECT
    SUM(CASE WHEN CustomerKey = -1        THEN 1 ELSE 0 END) AS UnmatchedCustomers,
    SUM(CASE WHEN SalesAmountAUD IS NULL  THEN 1 ELSE 0 END) AS MissingFxRate
FROM fact.Sales;
