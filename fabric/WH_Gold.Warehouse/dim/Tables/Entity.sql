CREATE TABLE [dim].[Entity] (
    [EntityKey]    INT           NOT NULL,
    [EntityCode]   VARCHAR (3)   NOT NULL,
    [EntityName]   VARCHAR (100) NOT NULL,
    [CountryName]  VARCHAR (50)  NOT NULL,
    [BaseCurrency] VARCHAR (3)   NOT NULL
);


GO