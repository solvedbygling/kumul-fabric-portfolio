CREATE   PROCEDURE etl.usp_Load_Dimensions
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

GO