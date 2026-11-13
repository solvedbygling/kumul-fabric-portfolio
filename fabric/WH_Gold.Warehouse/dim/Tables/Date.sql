CREATE TABLE [dim].[Date] (
    [DateKey]         INT          NOT NULL,
    [Date]            DATE         NOT NULL,
    [Year]            SMALLINT     NOT NULL,
    [Quarter]         VARCHAR (2)  NOT NULL,
    [MonthNumber]     SMALLINT     NOT NULL,
    [MonthName]       VARCHAR (10) NOT NULL,
    [MonthStart]      DATE         NOT NULL,
    [YearMonth]       VARCHAR (8)  NOT NULL,
    [DayOfWeekNumber] SMALLINT     NOT NULL,
    [DayName]         VARCHAR (10) NOT NULL,
    [IsWeekend]       BIT          NOT NULL,
    [AUFinancialYear] VARCHAR (9)  NOT NULL
);


GO