-- Second SQL sample: T-SQL, MySQL, SQLite fragments; ends in an unterminated block comment.
-- Line comment with 'unbalanced quote
-- Line comment with "unbalanced identifier quote
#  MySQL hash comment line
-- MySQL requires a space after -- ; this next line is not a comment in MySQL: --notcomment

USE [Inventory];
GO

/* ======================================================
   T-SQL section
   ====================================================== */
IF OBJECT_ID(N'[dbo].[Products]', N'U') IS NOT NULL
    DROP TABLE [dbo].[Products];
GO

CREATE TABLE [dbo].[Products] (
    [ProductID]    INT IDENTITY(1, 1) NOT NULL PRIMARY KEY CLUSTERED,
    [Product Name] NVARCHAR(200) NOT NULL,
    [Price]        DECIMAL(10, 2) NOT NULL CONSTRAINT [DF_Price] DEFAULT (0.00),
    [Weird]]Name]  INT NULL,                      -- escaped bracket in identifier
    [Data]         VARBINARY(MAX) NULL DEFAULT 0xDEADBEEF,
    [Created]      DATETIME2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    [RowVer]       ROWVERSION
);
GO

DECLARE @name NVARCHAR(100) = N'Widget ''Deluxe''';
DECLARE @price MONEY = $19.99;
DECLARE @json NVARCHAR(MAX) = N'{"items": [{"id": 1, "label": "it''s"}]}';
DECLARE @@notReallyAllowed INT;

SET NOCOUNT ON;

BEGIN TRY
    BEGIN TRANSACTION;
    INSERT INTO [dbo].[Products] ([Product Name], [Price])
    OUTPUT INSERTED.[ProductID], INSERTED.[Product Name]
    VALUES (@name, @price), (N'Gadget', 5.5), (N'Thing "quoted"', 1E2);

    UPDATE p
       SET p.[Price] = p.[Price] * 1.1
      FROM [dbo].[Products] AS p WITH (NOLOCK)
     WHERE p.[Product Name] LIKE N'%[Ww]idget%' ESCAPE '\';

    MERGE INTO [dbo].[Products] AS tgt
    USING (SELECT * FROM OPENJSON(@json, '$.items') WITH (id INT '$.id', label NVARCHAR(50) '$.label')) AS src
       ON tgt.[ProductID] = src.id
    WHEN MATCHED THEN UPDATE SET tgt.[Product Name] = src.label
    WHEN NOT MATCHED BY TARGET THEN INSERT ([Product Name], [Price]) VALUES (src.label, 0)
    OUTPUT $action, inserted.*, deleted.*;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(N'Failed: %s', 16, 1, @msg) WITH NOWAIT;
    THROW 50001, 'Custom error with ''quotes''', 1;
END CATCH;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_GetProducts]
    @MinPrice DECIMAL(10, 2) = 0,
    @Search   NVARCHAR(100) = NULL
AS
BEGIN
    SELECT TOP (10) WITH TIES
           [ProductID],
           [Product Name] AS [Name],
           FORMAT([Price], 'C', 'en-US') AS [Formatted Price],
           IIF([Price] > 100, 'expensive', 'cheap') AS Category,
           CASE WHEN [Price] BETWEEN 0 AND 10 THEN 'low'
                WHEN [Price] < 100 THEN 'mid'
                ELSE 'high' END AS Tier
      FROM [dbo].[Products]
     WHERE [Price] >= @MinPrice
       AND (@Search IS NULL OR [Product Name] LIKE '%' + @Search + '%')
  ORDER BY [Price] DESC;
END;
GO

/* ======================================================
   MySQL section
   ====================================================== */
DELIMITER $$
CREATE PROCEDURE `inventory`.`restock`(IN p_id INT, IN qty INT)
BEGIN
    DECLARE v_now DATETIME DEFAULT NOW();
    UPDATE `products` SET `stock` = `stock` + qty, `updated` = v_now WHERE `id` = p_id;
    SELECT CONCAT('Restocked ', qty, ' of #', p_id, " at ", v_now) AS `message`;
    SELECT 'backslash escapes in MySQL: \n \t \\ \' \"' AS escapes;
    SELECT "double-quoted string in MySQL with \"escapes\"" AS dq;
END$$
DELIMITER ;

SELECT `weird``name`, b'1010', x'4142', 0x4142, 1.5e3, _utf8mb4'charset introducer', N'nchar'
  FROM `my db`.`my table`
 WHERE `id` <=> NULL
   AND `name` REGEXP '^[A-Z]'
   AND `flags` & 0x0F = 0x0F
 LIMIT 5, 10;

/*! MySQL-specific executable comment SET NAMES utf8mb4 */;
/*!50503 SET character_set_client = utf8mb4 */;

/* ======================================================
   SQLite section
   ====================================================== */
CREATE TABLE IF NOT EXISTS "notes" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    `body` TEXT NOT NULL DEFAULT '',
    [tags] TEXT,
    created INTEGER DEFAULT (strftime('%s', 'now'))
) STRICT;

CREATE TRIGGER IF NOT EXISTS notes_touch AFTER UPDATE ON notes
FOR EACH ROW BEGIN
    UPDATE notes SET created = strftime('%s', 'now') WHERE id = OLD.id;
END;

SELECT id, json_extract(body, '$.title') AS title, ?1, :named, @at, $dollar
  FROM notes
 WHERE body GLOB '*[0-9]*' AND tags MATCH 'sql*'
 ORDER BY created COLLATE NOCASE;

-- Edge cases at line boundaries
SELECT 'string that starts here
and ends here' AS multi,
       "identifier that
spans lines" AS weird,
       1 -- comment after code with 'quote
       + 2 AS sum_across_comment,
       3 /* inline */ * 4 AS product;

-- Oracle-style alternative quoting and other oddities
SELECT q'[It's a quoted string with [brackets]]' AS oracle_q,
       q'{braces}' AS q_braces,
       q'!bangs!' AS q_bangs,
       n'national' AS lower_n,
       'a' || chr(10) || 'b' AS concat_newline,
       1e3 AS sci, 1.e3 AS sci2, .1e-3 AS sci3, 0x1F AS hex_mysql
  FROM dual
 WHERE ROWNUM <= 10
   AND col = :bind_var
   AND other = &substitution;

-- PL/SQL block
BEGIN
  DBMS_OUTPUT.PUT_LINE('Hello from PL/SQL, it''s ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD'));
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
/

SELECT 'unterminated string runs on
FROM nowhere;
SELECT 'closes here' AS fixed;

/* This block comment never closes.
   SELECT * FROM "not_code";
   'strings' and "identifiers" and [brackets] and `backticks`
   $$ dollar quotes $$ and -- dashes
