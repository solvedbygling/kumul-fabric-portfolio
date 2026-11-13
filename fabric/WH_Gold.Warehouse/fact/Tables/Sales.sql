CREATE TABLE [fact].[Sales] (
    [SalesOrderLineID]     INT             NOT NULL,
    [SalesOrderID]         INT             NOT NULL,
    [OrderNumber]          VARCHAR (20)    NOT NULL,
    [LineNumber]           SMALLINT        NOT NULL,
    [OrderDateKey]         INT             NOT NULL,
    [RequiredDateKey]      INT             NULL,
    [ShippedDateKey]       INT             NULL,
    [CustomerKey]          BIGINT          NOT NULL,
    [ProductKey]           INT             NOT NULL,
    [WarehouseKey]         INT             NOT NULL,
    [EntityKey]            INT             NOT NULL,
    [OrderStatus]          VARCHAR (15)    NOT NULL,
    [CurrencyCode]         VARCHAR (3)     NOT NULL,
    [Quantity]             INT             NOT NULL,
    [UnitPriceLocal]       DECIMAL (12, 2) NOT NULL,
    [DiscountPct]          DECIMAL (5, 2)  NOT NULL,
    [SalesAmountLocal]     DECIMAL (18, 2) NOT NULL,
    [FxRateToAUD]          DECIMAL (12, 6) NULL,
    [SalesAmountAUD]       DECIMAL (18, 2) NULL,
    [CostAmountAUD]        DECIMAL (18, 2) NOT NULL,
    [GrossMarginAUD]       DECIMAL (18, 2) NULL,
    [DaysToShip]           INT             NULL,
    [IsShippedLate]        BIT             NULL,
    [IsReturn]             BIT             NOT NULL,
    [IsOrderDateCorrected] BIT             NOT NULL,
    [IsShipDateImputed]    BIT             NOT NULL
);


GO