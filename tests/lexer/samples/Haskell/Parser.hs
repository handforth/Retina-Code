{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase, TupleSections #-}
{-# LANGUAGE QuasiQuotes, TemplateHaskell #-}
{-# OPTIONS_GHC -Wall -fno-warn-unused-imports #-}

{- Haskell block comments nest: {- inner {- deeper -} -} still outer
   and this line is still a comment -}

-- | Module header doc comment with 'quotes' and "strings"
module Parser
  ( Parser (..)
  , runParser
  , char
  , string
  , (<||>)
  ) where

import Control.Applicative (Alternative (..))
import Data.Char (isDigit, isSpace, isAlpha)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.List (foldl')

-- | A parser newtype.
-- >>> runParser (char 'a') "abc"
-- Just ('a',"bc")
newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }

instance Functor Parser where
  fmap f (Parser p) = Parser $ \s -> case p s of
    Nothing -> Nothing
    Just (a, rest) -> Just (f a, rest)

instance Applicative Parser where
  pure x = Parser $ \s -> Just (x, s)
  Parser pf <*> Parser pa = Parser $ \s -> do
    (f, r1) <- pf s
    (a, r2) <- pa r1
    pure (f a, r2)

instance Monad Parser where
  Parser p >>= f = Parser $ \s -> case p s of
    Nothing -> Nothing
    Just (a, rest) -> runParser (f a) rest

instance Alternative Parser where
  empty = Parser (const Nothing)
  Parser p <|> Parser q = Parser $ \s -> maybe (q s) Just (p s)

infixl 3 <||>
(<||>) :: Parser a -> Parser a -> Parser a
(<||>) = (<|>)

satisfy :: (Char -> Bool) -> Parser Char
satisfy pr = Parser $ \case
  (c:cs) | pr c -> Just (c, cs)
  _ -> Nothing

char :: Char -> Parser Char
char c = satisfy (== c)

string :: String -> Parser String
string = traverse char

spaces :: Parser ()
spaces = () <$ many (satisfy isSpace)

token :: Parser a -> Parser a
token p = p <* spaces

-- Character literals vs primes in identifiers
x' :: Int
x' = 1
x'' = x' + 1
f' a' = a' * 2
chars = ['a', '\'', '\\', '\n', '\t', '\x41', '\65', '\o101', '\SOH', '\DEL', '"', '\^A']
promoted = '[1, 2]       -- DataKinds promoted list
thName = 'map            -- TemplateHaskell name quote
thType = ''Maybe         -- TemplateHaskell type quote

-- Strings
s1 = "double \"quoted\" with \\ and \n and \t"
s2 = "numeric escapes \65\x41\o101 and \1234\&5 and \SOH\&H"
s3 = "string gap \
     \continues here"
s4 = "trailing backslash \\"
s5 = "comment markers -- and {- inside string -}"
s6 = "unterminated string on this line
s7 = "next"

-- Numbers
n1 = 42 :: Int
n2 = 0xFF :: Int
n3 = 0o17 :: Int
n4 = 0b1010 :: Int     -- BinaryLiterals
n5 = 1_000_000 :: Int  -- NumericUnderscores
n6 = 1.5e-3 :: Double
n7 = 6.022e23
n8 = 0x1.8p1           -- HexFloatLiterals
n9 = 1e10
n10 = -5

-- Operators and sections
ops = [(+ 1), (subtract 1), (* 2), (`div` 2), (2 ^), (<> "x")]
composed = map (show . (+1)) . filter even $ [1..10]
range1 = [1, 3 .. 99]
range2 = ['a' .. 'z']
listComp = [(x, y) | x <- [1..3], y <- "ab", odd x]
lambda = \x y -> x + y
backtick = 10 `mod` 3
arrows = (>>=) <$> pure 1 <*> pure (const Nothing)
custom = a |> b <| c >=> d <=< e
lens = view (field . _1) record & over _2 (+1)
dollarOp = print $ sum $ map (*2) [1..10]
typeApp = read @Int "42"

-- Data types and classes
data Shape
  = Circle { radius :: Double }
  | Rect { width, height :: Double }
  deriving (Show, Eq, Ord)

data Tree a = Leaf | Node (Tree a) a (Tree a)
  deriving stock (Show, Functor, Foldable)

class Container f where
  type Elem f
  empty' :: f
  insert :: Elem f -> f -> f

type family Fam a where
  Fam Int = Bool
  Fam a = a

area :: Shape -> Double
area (Circle r) = pi * r ^ (2 :: Int)
area Rect{width = w, height = h} = w * h

classify :: Int -> String
classify n
  | n < 0 = "negative"
  | n == 0 = "zero"
  | otherwise = let big = n > 100 in if big then "big" else "small"

expr :: Parser Int
expr = do
  t <- term
  rest t
  where
    rest acc = (do _ <- token (char '+'); t <- term; rest (acc + t)) <|> pure acc
    term = token (read <$> some (satisfy isDigit))

wordFreq :: T.Text -> Map.Map T.Text Int
wordFreq = foldl' (\m w -> Map.insertWith (+) w 1 m) Map.empty . T.words . T.toLower

-- Quasiquote and Template Haskell splice
query = [sql| SELECT * FROM users WHERE name = 'x' -- not a haskell comment |]
spliced = $(generateCode 'expr)
typed = $$(typedSplice)

main :: IO ()
main = do
  let input = "1 + 2 + 3"
  print (runParser expr input)
  mapM_ (putStrLn . classify) [-1, 0, 5, 500]
  case runParser (string "hello") "hello world" of
    Just (h, rest) -> putStrLn $ h ++ "|" ++ rest
    Nothing -> pure ()

--| Not a doc comment, an operator-ish line comment start
-->> also an operator, not a comment in real Haskell
{- nested {- comment -} closes properly -} finalValue = 'z'
