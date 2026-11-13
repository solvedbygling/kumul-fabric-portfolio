CREATE TABLE [etl].[LoadLog] (
    [LoadStep]    VARCHAR (50)  NOT NULL,
    [RowsInTable] INT           NULL,
    [LoadedAt]    DATETIME2 (6) NOT NULL
);


GO