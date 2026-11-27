-- SQL lexer stress: dollar quoting, quoted identifiers, mixed-case keywords
-- PostgreSQL flavored, with some T-SQL and MySQL identifiers mixed in.

/* Block comment with 'strings' and "identifiers" and -- dashes */
/* Postgres block comments nest: /* inner */ still outer */

SET search_path TO public, "Extra Schema";
SET client_encoding = 'UTF8';

CREATE SCHEMA IF NOT EXISTS "Analytics";

CREATE TABLE IF NOT EXISTS "Analytics"."User Accounts" (
    id            BIGSERIAL PRIMARY KEY,
    "Name"        VARCHAR(255) NOT NULL,
    email         TEXT UNIQUE CHECK (email ~* '^[^@]+@[^@]+\.[a-z]+$'),
    "select"      INTEGER DEFAULT 0,          -- keyword as quoted identifier
    balance       NUMERIC(12, 2) DEFAULT 0.00,
    ratio         DOUBLE PRECISION DEFAULT 1.5e-3,
    flags         BIT VARYING(8) DEFAULT B'1010',
    hex_flags     BIT(8) DEFAULT X'FF',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata      JSONB DEFAULT '{"key": "value", "nested": {"a": [1, 2]}}'::jsonb,
    tags          TEXT[] DEFAULT ARRAY['a', 'b']::TEXT[],
    CONSTRAINT positive_balance CHECK (balance >= 0)
);

COMMENT ON TABLE "Analytics"."User Accounts" IS 'It''s a table with ''escaped'' quotes';

-- String literal forms
SELECT 'simple string',
       'it''s doubled',
       E'escape string with \n newline and \t tab and \\ backslash and \' quote',
       e'lowercase escape prefix \x41 \101 A',
       U&'unicode \0041 \+01F600' UESCAPE '\',
       N'national character string',
       B'101010',
       X'DEADBEEF',
       $$dollar-quoted with 'single' and "double" quotes$$,
       $tag$tagged dollar quote with $$ inside$tag$,
       $a$ nested $b$ inner $b$ still outer $a$,
       'multi-line
string literal',
       '' AS empty_string,
       'trailing backslash \' AS not_escaped_in_standard_strings;

-- Function with dollar-quoted body spanning many lines
CREATE OR REPLACE FUNCTION "Analytics".update_balance(
    p_user_id BIGINT,
    p_delta   NUMERIC DEFAULT 0
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_balance NUMERIC;
    v_msg     TEXT := 'updating user ' || p_user_id;  -- comment inside body
BEGIN
    /* block comment inside dollar body */
    RAISE NOTICE 'msg: %, delta: %', v_msg, p_delta;
    UPDATE "Analytics"."User Accounts"
       SET balance = balance + p_delta
     WHERE id = p_user_id
    RETURNING balance INTO v_balance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % not found', p_user_id
            USING ERRCODE = 'P0002', HINT = $$Check the "id" value$$;
    END IF;

    EXECUTE format($q$SELECT %I FROM %I.%I WHERE id = %L$q$,
                   'Name', 'Analytics', 'User Accounts', p_user_id);
    RETURN v_balance;
END;
$function$;

CREATE FUNCTION add(a integer, b integer) RETURNS integer
    AS 'select $1 + $2;'
    LANGUAGE SQL IMMUTABLE STRICT;

CREATE FUNCTION js_like() RETURNS text AS $$
    SELECT 'a $ sign alone and $1 placeholder inside dollar quotes'
$$ LANGUAGE sql;

-- Mixed case keywords
select Id, "Name", COUNT(*) as Total
FROM "Analytics"."User Accounts" ua
Left Outer Join orders o ON o.user_id = ua.id
wHeRe ua.balance > 100.50
  AnD ua.created_at BETWEEN '2024-01-01'::date AND CURRENT_DATE - INTERVAL '1 day'
  oR ua.email ILIKE '%@example.com'
  AND ua."select" IN (1, 2, 3)
  AND ua.tags @> ARRAY['vip']
  AND ua.metadata->>'key' = 'value'
  AND ua.metadata #>> '{nested,a,0}' IS NOT NULL
GROUP BY Id, "Name"
HAVING count(*) >= 2
ORDER BY Total DESC NULLS LAST, 2 ASC
LIMIT 10 OFFSET 0;

-- CTEs and window functions
WITH RECURSIVE tree(id, parent_id, depth, path) AS (
    SELECT id, parent_id, 0, ARRAY[id]
    FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, t.depth + 1, t.path || c.id
    FROM categories c JOIN tree t ON c.parent_id = t.id
    WHERE NOT c.id = ANY(t.path)
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY depth ORDER BY id) AS rn,
           SUM(depth) OVER w AS running,
           LAG(id, 1, -1) OVER w AS prev_id
    FROM tree
    WINDOW w AS (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT * FROM ranked WHERE rn <= 3;

-- Numbers
SELECT 42, -42, 3.14, .5, 5., 1e10, 1.5E-3, 0x1F, 0o17, 0b1010, 1_000_000, 42::bigint, '42'::int;

-- Operators
SELECT 1 + 2 - 3 * 4 / 5 % 6 ^ 2, 'a' || 'b', 5 & 3, 5 | 3, 5 # 3, ~5, 1 << 2, 8 >> 1,
       1 <> 2, 1 != 2, 1 <= 2, 1 >= 2, 'abc' ~ 'b', 'abc' !~ 'z', |/ 25.0, ||/ 27.0, @ -5;

-- T-SQL and MySQL quoted identifiers
SELECT [Order Details].[Unit Price], [dbo].[Customers].[Company Name]
FROM [dbo].[Order Details];
SELECT `backtick identifier`, `table`.`column with spaces` FROM `my db`.`my table`;

-- Upsert and JSON
INSERT INTO "Analytics"."User Accounts" ("Name", email, metadata)
VALUES ('O''Brien', 'ob@example.com', '{"quote": "it''s \"json\""}'),
       (E'Tab\tName', NULL, jsonb_build_object('k', 'v'))
ON CONFLICT (email) DO UPDATE
   SET "Name" = EXCLUDED."Name",
       metadata = "User Accounts".metadata || EXCLUDED.metadata
RETURNING *;

DO $do$
BEGIN
    PERFORM pg_sleep(0.1);
END
$do$;

-- Dollar quotes at line boundaries and lookalikes
SELECT $$
first line
$not_a_tag$ inside plain dollar quotes
last line$$ AS body,
       $1 AS positional_param,
       $_$underscore tag$_$ AS underscore_tag,
       $Tag1$mixed case tag$Tag1$ AS mixed_tag,
       '$$ inside a regular string' AS not_dollar,
       "col$with$dollars" AS quoted_ident_with_dollars;

PREPARE stmt(int, text) AS
    SELECT * FROM "Analytics"."User Accounts" WHERE id = $1 AND "Name" = $2;
EXECUTE stmt(1, 'O''Brien');

/* final nested /* comment */ closed */ SELECT 'done';
