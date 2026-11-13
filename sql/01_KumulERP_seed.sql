/* =====================================================================
   KUMUL TRADING GROUP — dummy ERP source database for Fabric portfolio
   Target : SQL Server Express (.\SQLEXPRESS)
   Run    : open in SSMS, change the password near the bottom, press F5.
            Safe to re-run — it drops and rebuilds KumulERP each time.

   Company: wholesale distributor of food, beverages, cleaning,
            catering disposables and site consumables.
            Entity 1 = Kumul Wholesale Pty Ltd        (AUS, AUD)
            Entity 2 = Kumul Wholesale (PNG) Ltd      (PNG, PGK)
   History: 1 Nov 2024 – 31 Oct 2026 (~12k orders, ~42k order lines)

   DELIBERATE DATA QUALITY ISSUES (your silver-layer to-do list):
     1. Customer names in SHOUTY CAPS with trailing spaces
     2. City variants: 'POM', 'Pt. Moresby', 'LAE', ' brisbane'
     3. NULL CustomerType on some customers
     4. Duplicate customers (code ends in 'D', name has 'Ltd.')
        that have orders posted against them from mid-2025
     5. OrderStatus casing/whitespace: 'shipped', 'SHIPPED '
     6. Orders marked Shipped with no ShippedDate
     7. NULL CurrencyCode on some orders
     8. Two fat-fingered order dates in the 2050s
     9. Negative quantities (returns posted as sales lines)
    10. Products with a $0 list price; product names in lowercase
        with trailing spaces; one discontinued product

   Also creates sales.usp_SimulateBusinessDay — run it between pipeline
   loads to generate new orders, ship old ones and change a couple of
   customers (proves incremental loads + SCD2 work).
   ===================================================================== */

USE master;
GO
IF DB_ID('KumulERP') IS NOT NULL
BEGIN
    ALTER DATABASE KumulERP SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE KumulERP;
END
GO
CREATE DATABASE KumulERP;
GO
ALTER DATABASE KumulERP SET RECOVERY SIMPLE;
GO
USE KumulERP;
GO
CREATE SCHEMA ref;
GO
CREATE SCHEMA inv;
GO
CREATE SCHEMA sales;
GO

/* ---------------------------------------------------------------------
   TABLES + DATA (single batch)
   --------------------------------------------------------------------- */
SET NOCOUNT ON;

DROP TABLE IF EXISTS #Num, #City, #CustType, #NamePart, #Cust, #Day, #Ord, #Line;

-- Reference: legal entities -------------------------------------------
CREATE TABLE ref.Entity (
    EntityID      tinyint       NOT NULL PRIMARY KEY,
    EntityCode    char(3)       NOT NULL UNIQUE,
    EntityName    nvarchar(100) NOT NULL,
    CountryName   nvarchar(50)  NOT NULL,
    BaseCurrency  char(3)       NOT NULL
);
INSERT ref.Entity VALUES
 (1, 'AUS', 'Kumul Wholesale Pty Ltd',   'Australia',        'AUD'),
 (2, 'PNG', 'Kumul Wholesale (PNG) Ltd', 'Papua New Guinea', 'PGK');

-- Warehouses ------------------------------------------------------------
CREATE TABLE inv.Warehouse (
    WarehouseID    tinyint       NOT NULL PRIMARY KEY,
    EntityID       tinyint       NOT NULL REFERENCES ref.Entity(EntityID),
    WarehouseName  nvarchar(100) NOT NULL,
    City           nvarchar(50)  NOT NULL
);
INSERT inv.Warehouse VALUES
 (1, 1, 'Brisbane DC',     'Brisbane'),
 (2, 1, 'Cairns Depot',    'Cairns'),
 (3, 2, 'Port Moresby DC', 'Port Moresby'),
 (4, 2, 'Lae Depot',       'Lae');

-- Products --------------------------------------------------------------
CREATE TABLE inv.Product (
    ProductID     int            IDENTITY(1,1) PRIMARY KEY,
    SKU           varchar(20)    NOT NULL UNIQUE,
    ProductName   nvarchar(150)  NOT NULL,
    Category      nvarchar(50)   NOT NULL,
    PackSize      nvarchar(30)   NOT NULL,
    UnitCostAUD   decimal(10,2)  NOT NULL,
    ListPriceAUD  decimal(10,2)  NOT NULL,
    IsActive      bit            NOT NULL DEFAULT 1,
    CreatedAt     datetime2(0)   NOT NULL DEFAULT '2024-10-01',
    ModifiedAt    datetime2(0)   NOT NULL DEFAULT '2024-10-01'
);

DECLARE @base TABLE (Category nvarchar(50), Item nvarchar(100), BaseCost decimal(10,2), Code varchar(4));
INSERT @base VALUES
 ('Beverages','Bottled Water 600ml',0.45,'BEV'),
 ('Beverages','Cola 375ml Can',0.70,'BEV'),
 ('Beverages','Instant Coffee 500g',9.50,'BEV'),
 ('Beverages','Black Tea Bags 100pk',3.20,'BEV'),
 ('Beverages','Orange Juice 2L',2.80,'BEV'),
 ('Beverages','Sports Drink 600ml',1.10,'BEV'),
 ('Packaged Food','Long Grain Rice 10kg',11.00,'PKF'),
 ('Packaged Food','Tinned Fish 425g',2.10,'PKF'),
 ('Packaged Food','Instant Noodles 5pk',2.40,'PKF'),
 ('Packaged Food','Cream Crackers 250g',1.60,'PKF'),
 ('Packaged Food','Corned Beef 340g',3.90,'PKF'),
 ('Packaged Food','Sugar 2kg',2.50,'PKF'),
 ('Frozen','Chicken Pieces 2kg',9.80,'FRZ'),
 ('Frozen','Lamb Flaps 5kg',18.00,'FRZ'),
 ('Frozen','Mixed Vegetables 2kg',4.60,'FRZ'),
 ('Frozen','Beef Mince 1kg',8.20,'FRZ'),
 ('Cleaning & Hygiene','Laundry Powder 5kg',12.50,'CLN'),
 ('Cleaning & Hygiene','Hand Sanitiser 5L',16.00,'CLN'),
 ('Cleaning & Hygiene','Toilet Paper 48pk',19.00,'CLN'),
 ('Cleaning & Hygiene','Bleach 5L',6.50,'CLN'),
 ('Catering Disposables','Foam Clamshells 250pk',14.00,'CAT'),
 ('Catering Disposables','Paper Cups 1000pk',38.00,'CAT'),
 ('Catering Disposables','Cutlery Packs 500pk',27.00,'CAT'),
 ('Catering Disposables','Napkins 2000pk',22.00,'CAT'),
 ('Site Consumables','Hi-Vis Vest',4.20,'SIT'),
 ('Site Consumables','Safety Gloves 12pr',9.00,'SIT'),
 ('Site Consumables','Earplugs 200pk',21.00,'SIT'),
 ('Site Consumables','Safety Glasses',3.10,'SIT');

INSERT inv.Product (SKU, ProductName, Category, PackSize, UnitCostAUD, ListPriceAUD)
SELECT
    b.Code + '-' + RIGHT('000' + CAST(ROW_NUMBER() OVER (ORDER BY b.Category, b.Item, p.Mult) AS varchar(3)), 3) + '-' + p.PackCode,
    b.Item,
    b.Category,
    p.PackSize,
    CAST(b.BaseCost * p.Mult * p.Disc AS decimal(10,2)),
    CAST(b.BaseCost * p.Mult * p.Disc * (1.25 + (ABS(CHECKSUM(NEWID())) % 36) / 100.0) AS decimal(10,2))
FROM @base b
CROSS JOIN (VALUES ('EA','Each',1,1.00), ('CT','Carton x12',12,0.94)) p(PackCode, PackSize, Mult, Disc)
ORDER BY b.Category, b.Item, p.Mult;

-- Product mess (before order lines so it flows through)
UPDATE inv.Product SET ProductName = LOWER(ProductName) + '  ' WHERE ProductID % 13 = 0;
UPDATE inv.Product SET ListPriceAUD = 0 WHERE ProductID IN (7, 30);
UPDATE inv.Product SET IsActive = 0, ModifiedAt = '2026-03-01' WHERE ProductID = 44;

DECLARE @ProdCount int = (SELECT COUNT(*) FROM inv.Product);

-- Helper tables ---------------------------------------------------------
SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
INTO #Num FROM sys.all_objects;

CREATE TABLE #City (EntityID tinyint, Seq int, City nvarchar(50), StateProvince nvarchar(50));
INSERT #City VALUES
 (1,1,'Brisbane','QLD'),(1,2,'Brisbane','QLD'),(1,3,'Brisbane','QLD'),
 (1,4,'Cairns','QLD'),(1,5,'Cairns','QLD'),(1,6,'Townsville','QLD'),
 (1,7,'Gold Coast','QLD'),(1,8,'Darwin','NT'),(1,9,'Sydney','NSW'),(1,10,'Sydney','NSW'),
 (2,1,'Port Moresby','National Capital District'),(2,2,'Port Moresby','National Capital District'),
 (2,3,'Port Moresby','National Capital District'),(2,4,'Port Moresby','National Capital District'),
 (2,5,'Lae','Morobe'),(2,6,'Lae','Morobe'),(2,7,'Mount Hagen','Western Highlands'),
 (2,8,'Madang','Madang'),(2,9,'Kokopo','East New Britain'),(2,10,'Alotau','Milne Bay');

CREATE TABLE #CustType (Seq int, CustomerType nvarchar(30), Suffix nvarchar(30));
INSERT #CustType VALUES
 (1,'Retail','Trading'),(2,'Retail','Supermarket'),(3,'Hospitality','Hotel'),
 (4,'Hospitality','Resort'),(5,'Mining & Resources','Camp Services'),(6,'Catering','Catering'),
 (7,'Wholesale','Wholesalers'),(8,'Construction','Constructions');

CREATE TABLE #NamePart (Seq int, Part nvarchar(30));
INSERT #NamePart VALUES
 (1,'Coral'),(2,'Highlands'),(3,'Harbourside'),(4,'Sepik'),(5,'Reef'),
 (6,'Tropic'),(7,'Kokoda'),(8,'Bayside'),(9,'Sunrise'),(10,'Paradise'),
 (11,'Southern Cross'),(12,'Markham'),(13,'Fly River'),(14,'Bougainville'),(15,'Cape York'),
 (16,'Golden'),(17,'Pacific'),(18,'Ela Beach'),(19,'Mango'),(20,'Frangipani'),
 (21,'Wewak'),(22,'Rabaul'),(23,'Daintree'),(24,'Mossman'),(25,'Hibiscus');

-- Customers -------------------------------------------------------------
CREATE TABLE sales.Customer (
    CustomerID     int            IDENTITY(1,1) PRIMARY KEY,
    CustomerCode   varchar(12)    NOT NULL UNIQUE,
    EntityID       tinyint        NOT NULL REFERENCES ref.Entity(EntityID),
    CustomerName   nvarchar(150)  NOT NULL,
    CustomerType   nvarchar(30)   NULL,
    City           nvarchar(50)   NULL,
    StateProvince  nvarchar(50)   NULL,
    CreditLimit    decimal(12,2)  NULL,
    IsActive       bit            NOT NULL DEFAULT 1,
    CreatedAt      datetime2(0)   NOT NULL,
    ModifiedAt     datetime2(0)   NOT NULL
);

;WITH n AS (
    SELECT TOP (400) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
SELECT n.n,
       CAST(CASE WHEN n.n <= 200 THEN 1 ELSE 2 END AS tinyint)  AS EntityID,
       (CASE WHEN n.n <= 200 THEN n.n ELSE n.n - 200 END) - 1   AS k0,
       DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 1000, CAST('2022-01-01' AS datetime2(0))) AS Created,
       (ABS(CHECKSUM(NEWID())) % 20 + 1) * 5000                AS CreditLimit
INTO #Cust
FROM n;

INSERT sales.Customer (CustomerCode, EntityID, CustomerName, CustomerType, City, StateProvince, CreditLimit, CreatedAt, ModifiedAt)
SELECT
    CASE c.EntityID WHEN 1 THEN 'AU' ELSE 'PG' END + RIGHT('00000' + CAST(c.k0 + 1 AS varchar(5)), 5),
    c.EntityID,
    np.Part + ' ' + ct.Suffix + CASE c.EntityID WHEN 1 THEN ' Pty Ltd' ELSE ' Ltd' END,
    ct.CustomerType,
    ci.City,
    ci.StateProvince,
    c.CreditLimit,
    c.Created,
    c.Created
FROM #Cust c
JOIN #NamePart np ON np.Seq = c.k0 % 25 + 1
JOIN #CustType ct ON ct.Seq = (c.k0 / 25) % 8 + 1
JOIN #City     ci ON ci.EntityID = c.EntityID AND ci.Seq = (c.k0 * 3 + c.k0 / 25) % 10 + 1
ORDER BY c.n;

-- Days with seasonality, growth trend and quiet weekends -----------------
CREATE TABLE #Day (DayDate date PRIMARY KEY, OrderCount int);

;WITH d AS (
    SELECT TOP (730) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT #Day (DayDate, OrderCount)
SELECT x.dt,
       CAST(
           ( 14 + 8.0 * d.i / 730
             + CASE MONTH(x.dt) WHEN 12 THEN 7 WHEN 1 THEN -3 ELSE 0 END
             + ABS(CHECKSUM(NEWID())) % 7 )
           * CASE DATEDIFF(DAY, '19000101', x.dt) % 7   -- 0=Mon … 6=Sun
                 WHEN 5 THEN 0.40
                 WHEN 6 THEN 0.15
                 ELSE 1.0 END
       AS int)
FROM d
CROSS APPLY (SELECT DATEADD(DAY, d.i, CAST('2024-11-01' AS date)) AS dt) x;

-- Orders (random values materialised once) ------------------------------
SELECT ROW_NUMBER() OVER (ORDER BY d.DayDate, n.n) AS rn,
       d.DayDate                              AS OrderDate,
       ABS(CHECKSUM(NEWID())) % 400 + 1       AS CustomerID,
       ABS(CHECKSUM(NEWID())) % 6 + 1         AS LineCount,
       ABS(CHECKSUM(NEWID())) % 100           AS StatusRnd,
       ABS(CHECKSUM(NEWID())) % 1000          AS ShipRnd,
       ABS(CHECKSUM(NEWID())) % 36000         AS SecRnd
INTO #Ord
FROM #Day d
JOIN #Num n ON n.n <= d.OrderCount;

CREATE TABLE sales.SalesOrderHeader (
    SalesOrderID   int            IDENTITY(1,1) PRIMARY KEY,
    OrderNumber    varchar(20)    NOT NULL UNIQUE,
    EntityID       tinyint        NOT NULL REFERENCES ref.Entity(EntityID),
    CustomerID     int            NOT NULL REFERENCES sales.Customer(CustomerID),
    WarehouseID    tinyint        NOT NULL REFERENCES inv.Warehouse(WarehouseID),
    OrderDate      date           NOT NULL,
    RequiredDate   date           NULL,
    ShippedDate    date           NULL,
    OrderStatus    varchar(15)    NOT NULL,
    CurrencyCode   char(3)        NULL,
    CreatedAt      datetime2(0)   NOT NULL,
    ModifiedAt     datetime2(0)   NOT NULL
);

INSERT sales.SalesOrderHeader
    (OrderNumber, EntityID, CustomerID, WarehouseID, OrderDate, RequiredDate, ShippedDate, OrderStatus, CurrencyCode, CreatedAt, ModifiedAt)
SELECT
    'SO-' + CASE c.EntityID WHEN 1 THEN 'A' ELSE 'P' END + '-' + RIGHT('0000000' + CAST(o.rn AS varchar(7)), 7),
    c.EntityID,
    c.CustomerID,
    CASE WHEN c.EntityID = 1 AND c.City IN ('Cairns','Townsville','Darwin') THEN 2
         WHEN c.EntityID = 1 THEN 1
         WHEN c.City IN ('Lae','Mount Hagen','Madang') THEN 4
         ELSE 3 END,
    o.OrderDate,
    DATEADD(DAY, CASE c.EntityID WHEN 1 THEN 4 ELSE 7 END, o.OrderDate),
    CASE WHEN o.StatusRnd < 3 THEN NULL
         WHEN s.ShipDate <= '2026-10-31' THEN s.ShipDate END,
    CASE WHEN o.StatusRnd < 3 THEN 'Cancelled'
         WHEN s.ShipDate <= '2026-10-31' THEN 'Shipped'
         WHEN o.OrderDate < '2026-10-30' THEN 'Picking'
         ELSE 'Open' END,
    e.BaseCurrency,
    DATEADD(SECOND, 28800 + o.SecRnd, CAST(o.OrderDate AS datetime2(0))),
    DATEADD(SECOND, 28800 + o.SecRnd,
            CAST(CASE WHEN o.StatusRnd >= 3 AND s.ShipDate <= '2026-10-31' THEN s.ShipDate ELSE o.OrderDate END AS datetime2(0)))
FROM #Ord o
JOIN sales.Customer c ON c.CustomerID = o.CustomerID
JOIN ref.Entity     e ON e.EntityID   = c.EntityID
CROSS APPLY (SELECT DATEADD(DAY,
                 CASE c.EntityID WHEN 1 THEN 1 + o.ShipRnd % 5 ELSE 2 + o.ShipRnd % 9 END,
                 o.OrderDate) AS ShipDate) s
ORDER BY o.rn;

-- Order lines -----------------------------------------------------------
CREATE TABLE sales.SalesOrderLine (
    SalesOrderLineID  int            IDENTITY(1,1) PRIMARY KEY,
    SalesOrderID      int            NOT NULL REFERENCES sales.SalesOrderHeader(SalesOrderID),
    LineNumber        smallint       NOT NULL,
    ProductID         int            NOT NULL REFERENCES inv.Product(ProductID),
    Quantity          int            NOT NULL,
    UnitPrice         decimal(12,2)  NOT NULL,   -- in the order's currency
    DiscountPct       decimal(5,2)   NOT NULL DEFAULT 0,
    ModifiedAt        datetime2(0)   NOT NULL
);

SELECT h.SalesOrderID,
       h.OrderDate,
       h.EntityID,
       h.ModifiedAt,
       n.n                                         AS LineNumber,
       ABS(CHECKSUM(NEWID())) % @ProdCount + 1     AS ProductID,
       ABS(CHECKSUM(NEWID())) % 1000               AS QtyRnd,
       ABS(CHECKSUM(NEWID())) % 10                 AS DiscRnd
INTO #Line
FROM #Ord o
JOIN sales.SalesOrderHeader h
  ON h.OrderNumber = 'SO-' + CASE h.EntityID WHEN 1 THEN 'A' ELSE 'P' END + '-' + RIGHT('0000000' + CAST(o.rn AS varchar(7)), 7)
JOIN #Num n ON n.n <= o.LineCount;

-- Price = AUD list price, +4% a year, PNG converted at a flat 2.65 PGK/AUD + 10% freight (2.915)
INSERT sales.SalesOrderLine (SalesOrderID, LineNumber, ProductID, Quantity, UnitPrice, DiscountPct, ModifiedAt)
SELECT l.SalesOrderID,
       l.LineNumber,
       p.ProductID,
       CASE WHEN p.PackSize = 'Each' THEN 5 + l.QtyRnd % 116 ELSE 1 + l.QtyRnd % 30 END,
       CAST(p.ListPriceAUD
            * (1 + 0.04 * DATEDIFF(DAY, '2024-11-01', l.OrderDate) / 365.0)
            * CASE l.EntityID WHEN 2 THEN 2.915 ELSE 1 END AS decimal(12,2)),
       CASE l.DiscRnd WHEN 0 THEN 10 WHEN 1 THEN 5 WHEN 2 THEN 5 ELSE 0 END,
       l.ModifiedAt
FROM #Line l
JOIN inv.Product p ON p.ProductID = l.ProductID
ORDER BY l.SalesOrderID, l.LineNumber;

/* ---------------------------------------------------------------------
   MAKE IT MESSY (see the to-do list at the top)
   --------------------------------------------------------------------- */
-- 1. Shouty names + trailing spaces
UPDATE sales.Customer SET CustomerName = UPPER(CustomerName) + '   ' WHERE CustomerID % 37 = 0;

-- 4. Duplicate customers (done before city mess so they copy clean cities)
INSERT sales.Customer (CustomerCode, EntityID, CustomerName, CustomerType, City, StateProvince, CreditLimit, IsActive, CreatedAt, ModifiedAt)
SELECT CustomerCode + 'D', EntityID, REPLACE(RTRIM(CustomerName), ' Ltd', ' Ltd.'), CustomerType, City, StateProvince,
       CreditLimit, 1, '2025-06-15 09:30', '2025-06-15 09:30'
FROM sales.Customer
WHERE CustomerID IN (12, 145, 233);

UPDATE h SET CustomerID = d.CustomerID
FROM sales.SalesOrderHeader h
JOIN sales.Customer o ON o.CustomerID = h.CustomerID
JOIN sales.Customer d ON d.CustomerCode = o.CustomerCode + 'D'
WHERE h.OrderDate >= '2025-06-15' AND h.SalesOrderID % 2 = 0;

-- 2. City spelling variants
UPDATE sales.Customer SET City = 'POM'         WHERE City = 'Port Moresby' AND CustomerID % 5 = 0;
UPDATE sales.Customer SET City = 'Pt. Moresby' WHERE City = 'Port Moresby' AND CustomerID % 7 = 0;
UPDATE sales.Customer SET City = 'LAE'         WHERE City = 'Lae'          AND CustomerID % 3 = 0;
UPDATE sales.Customer SET City = ' brisbane'   WHERE City = 'Brisbane'     AND CustomerID % 11 = 0;

-- 3. Missing customer type
UPDATE sales.Customer SET CustomerType = NULL WHERE CustomerID % 53 = 0;

-- 5. Status casing / whitespace
UPDATE sales.SalesOrderHeader SET OrderStatus = 'shipped'  WHERE OrderStatus = 'Shipped' AND SalesOrderID % 41 = 0;
UPDATE sales.SalesOrderHeader SET OrderStatus = 'SHIPPED ' WHERE OrderStatus = 'Shipped' AND SalesOrderID % 67 = 0;

-- 6. Shipped but no ship date
UPDATE sales.SalesOrderHeader SET ShippedDate = NULL WHERE OrderStatus = 'Shipped' AND SalesOrderID % 97 = 0;

-- 7. Missing currency
UPDATE sales.SalesOrderHeader SET CurrencyCode = NULL WHERE SalesOrderID % 113 = 0;

-- 8. Fat-fingered order dates
UPDATE sales.SalesOrderHeader SET OrderDate = DATEADD(YEAR, 26, OrderDate) WHERE SalesOrderID IN (1234, 5678);

-- 9. Returns posted as negative quantities
UPDATE sales.SalesOrderLine SET Quantity = -Quantity WHERE SalesOrderLineID % 211 = 0;
GO

/* ---------------------------------------------------------------------
   SIMULATOR — run between pipeline loads:
       EXEC sales.usp_SimulateBusinessDay;          -- 25 new orders
       EXEC sales.usp_SimulateBusinessDay @Orders = 60;
   Each run: adds the next business day's orders (status Open), moves
   older Open orders to Picking, ships orders 2+ days old, and changes
   two customers (type + credit limit) — all stamped with ModifiedAt = now.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE sales.usp_SimulateBusinessDay
    @Orders int = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now       datetime2(0) = SYSDATETIME();
    DECLARE @Day       date = (SELECT DATEADD(DAY, 1, MAX(OrderDate)) FROM sales.SalesOrderHeader WHERE OrderDate < '2030-01-01');
    DECLARE @MaxID     int  = (SELECT MAX(SalesOrderID) FROM sales.SalesOrderHeader);
    DECLARE @ProdCount int  = (SELECT COUNT(*) FROM inv.Product);

    -- 1. Progress existing orders
    UPDATE sales.SalesOrderHeader
       SET OrderStatus = 'Shipped', ShippedDate = @Day, ModifiedAt = @Now
     WHERE OrderStatus IN ('Open', 'Picking') AND OrderDate <= DATEADD(DAY, -2, @Day);

    UPDATE sales.SalesOrderHeader
       SET OrderStatus = 'Picking', ModifiedAt = @Now
     WHERE OrderStatus = 'Open' AND OrderDate < @Day;

    -- 2. New orders
    CREATE TABLE #NewOrd (rn int PRIMARY KEY, OrderNumber varchar(20), CustomerID int, EntityID tinyint, City nvarchar(50), LineCount int);

    INSERT #NewOrd (rn, CustomerID, EntityID, City, LineCount)
    SELECT ROW_NUMBER() OVER (ORDER BY c.CustomerID), c.CustomerID, c.EntityID, c.City, ABS(CHECKSUM(NEWID())) % 6 + 1
    FROM (SELECT TOP (@Orders) CustomerID, EntityID, City
          FROM sales.Customer WHERE IsActive = 1 ORDER BY NEWID()) c;

    UPDATE #NewOrd
       SET OrderNumber = 'SO-' + CASE EntityID WHEN 1 THEN 'A' ELSE 'P' END + '-' + RIGHT('0000000' + CAST(@MaxID + rn AS varchar(7)), 7);

    INSERT sales.SalesOrderHeader
        (OrderNumber, EntityID, CustomerID, WarehouseID, OrderDate, RequiredDate, ShippedDate, OrderStatus, CurrencyCode, CreatedAt, ModifiedAt)
    SELECT n.OrderNumber, n.EntityID, n.CustomerID,
           CASE WHEN n.EntityID = 1 AND n.City IN ('Cairns','Townsville','Darwin') THEN 2
                WHEN n.EntityID = 1 THEN 1
                WHEN n.City IN ('Lae','Mount Hagen','Madang') THEN 4
                ELSE 3 END,
           @Day,
           DATEADD(DAY, CASE n.EntityID WHEN 1 THEN 4 ELSE 7 END, @Day),
           NULL, 'Open', e.BaseCurrency, @Now, @Now
    FROM #NewOrd n
    JOIN ref.Entity e ON e.EntityID = n.EntityID
    ORDER BY n.rn;

    SELECT n.OrderNumber, n.EntityID, ln.LineNumber,
           ABS(CHECKSUM(NEWID())) % @ProdCount + 1 AS ProductID,
           ABS(CHECKSUM(NEWID())) % 1000           AS QtyRnd,
           ABS(CHECKSUM(NEWID())) % 10             AS DiscRnd
    INTO #NewLine
    FROM #NewOrd n
    CROSS APPLY (SELECT TOP (n.LineCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS LineNumber
                 FROM sys.all_objects) ln;

    INSERT sales.SalesOrderLine (SalesOrderID, LineNumber, ProductID, Quantity, UnitPrice, DiscountPct, ModifiedAt)
    SELECT h.SalesOrderID, x.LineNumber, p.ProductID,
           CASE WHEN p.PackSize = 'Each' THEN 5 + x.QtyRnd % 116 ELSE 1 + x.QtyRnd % 30 END,
           CAST(p.ListPriceAUD
                * (1 + 0.04 * DATEDIFF(DAY, '2024-11-01', @Day) / 365.0)
                * CASE x.EntityID WHEN 2 THEN 2.915 ELSE 1 END AS decimal(12,2)),
           CASE x.DiscRnd WHEN 0 THEN 10 WHEN 1 THEN 5 WHEN 2 THEN 5 ELSE 0 END,
           @Now
    FROM #NewLine x
    JOIN sales.SalesOrderHeader h ON h.OrderNumber = x.OrderNumber
    JOIN inv.Product p            ON p.ProductID   = x.ProductID;

    -- 3. Customer attribute changes (feeds SCD2 on DimCustomer)
    ;WITH x AS (SELECT TOP (2) * FROM sales.Customer WHERE IsActive = 1 ORDER BY NEWID())
    UPDATE x
       SET CustomerType = CASE WHEN CustomerType = 'Retail' THEN 'Wholesale' ELSE 'Retail' END,
           CreditLimit  = ISNULL(CreditLimit, 0) + 10000,
           ModifiedAt   = @Now;

    PRINT CONCAT('Simulated business day ', CONVERT(varchar(10), @Day, 23), ': ', @Orders, ' new orders at ', CONVERT(varchar(19), @Now, 120));
END
GO

/* ---------------------------------------------------------------------
   READ-ONLY LOGIN FOR THE FABRIC GATEWAY
   >>> Change the password below before running. Keep it — you'll
   >>> enter it in the Fabric connection (Basic authentication).
   Requires "SQL Server and Windows Authentication mode" on the server.
   --------------------------------------------------------------------- */
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'fabric_reader')
    CREATE LOGIN fabric_reader WITH PASSWORD = 'CHANGE_ME_Kumul#2026', CHECK_POLICY = ON, DEFAULT_DATABASE = KumulERP;
GO
USE KumulERP;
CREATE USER fabric_reader FOR LOGIN fabric_reader;
ALTER ROLE db_datareader ADD MEMBER fabric_reader;
GO

/* ---------------------------------------------------------------------
   SANITY CHECK — you should see roughly 400 customers, 56 products,
   ~12k orders and ~42k lines, dated Nov 2024 – Oct 2026.
   --------------------------------------------------------------------- */
SELECT 'Entities'  AS TableName, COUNT(*) AS Rows FROM ref.Entity
UNION ALL SELECT 'Warehouses', COUNT(*) FROM inv.Warehouse
UNION ALL SELECT 'Products',   COUNT(*) FROM inv.Product
UNION ALL SELECT 'Customers',  COUNT(*) FROM sales.Customer
UNION ALL SELECT 'Orders',     COUNT(*) FROM sales.SalesOrderHeader
UNION ALL SELECT 'OrderLines', COUNT(*) FROM sales.SalesOrderLine;

SELECT e.EntityCode,
       MIN(h.OrderDate) AS FirstOrder,
       MAX(CASE WHEN h.OrderDate < '2030-01-01' THEN h.OrderDate END) AS LastOrder,
       COUNT(DISTINCT h.SalesOrderID) AS Orders,
       CAST(SUM(l.Quantity * l.UnitPrice * (1 - l.DiscountPct / 100)) AS decimal(18,2)) AS RevenueLocalCcy
FROM sales.SalesOrderHeader h
JOIN sales.SalesOrderLine l ON l.SalesOrderID = h.SalesOrderID
JOIN ref.Entity e           ON e.EntityID     = h.EntityID
GROUP BY e.EntityCode;
