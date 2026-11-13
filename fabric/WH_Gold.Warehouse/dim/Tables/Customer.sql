CREATE TABLE [dim].[Customer] (
    [CustomerKey]   BIGINT          NOT NULL,
    [CustomerID]    INT             NOT NULL,
    [CustomerCode]  VARCHAR (12)    NOT NULL,
    [EntityKey]     INT             NOT NULL,
    [CustomerName]  VARCHAR (150)   NOT NULL,
    [CustomerType]  VARCHAR (30)    NOT NULL,
    [City]          VARCHAR (50)    NULL,
    [StateProvince] VARCHAR (50)    NULL,
    [CreditLimit]   DECIMAL (12, 2) NULL,
    [IsActive]      BIT             NOT NULL,
    [ValidFrom]     DATETIME2 (6)   NOT NULL,
    [ValidTo]       DATETIME2 (6)   NOT NULL,
    [IsCurrent]     BIT             NOT NULL
);


GO