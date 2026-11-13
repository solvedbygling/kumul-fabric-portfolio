CREATE TABLE [dim].[Product] (
    [ProductKey]     INT             NOT NULL,
    [SKU]            VARCHAR (20)    NOT NULL,
    [ProductName]    VARCHAR (150)   NOT NULL,
    [Category]       VARCHAR (50)    NOT NULL,
    [PackSize]       VARCHAR (30)    NOT NULL,
    [UnitCostAUD]    DECIMAL (10, 2) NOT NULL,
    [ListPriceAUD]   DECIMAL (10, 2) NOT NULL,
    [IsActive]       BIT             NOT NULL,
    [IsPriceMissing] BIT             NOT NULL
);


GO