CREATE   PROCEDURE etl.usp_Load_FactSales
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

GO