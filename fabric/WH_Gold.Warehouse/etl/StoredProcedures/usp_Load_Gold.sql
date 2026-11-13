CREATE   PROCEDURE etl.usp_Load_Gold
AS
BEGIN
    EXEC etl.usp_Load_Dimensions;
    EXEC etl.usp_Load_FactSales;

    INSERT INTO etl.LoadLog (LoadStep, RowsInTable, LoadedAt)
    SELECT 'dim.Customer', COUNT(*), SYSUTCDATETIME() FROM dim.Customer
    UNION ALL
    SELECT 'fact.Sales',   COUNT(*), SYSUTCDATETIME() FROM fact.Sales;
END;

GO