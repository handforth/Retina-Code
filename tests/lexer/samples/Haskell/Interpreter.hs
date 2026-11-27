{-# LANGUAGE GADTs, KindSignatures, RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables, DerivingStrategies #-}
-- Second Haskell sample: a GADT interpreter, records, where-clauses,
-- and an unterminated nested block comment at EOF.

module Main (main) where

import Control.Monad.State
import Data.IORef (newIORef, readIORef, modifyIORef')
import qualified Data.Map as M
import Text.Printf (printf)

{-| Haddock block doc for the expression type.
    Contains @code@ and 'identifiers' and "strings". -}
data Expr :: * -> * where
  IntE  :: Int -> Expr Int
  BoolE :: Bool -> Expr Bool
  Add   :: Expr Int -> Expr Int -> Expr Int
  Mul   :: Expr Int -> Expr Int -> Expr Int
  If    :: Expr Bool -> Expr a -> Expr a -> Expr a
  Eq    :: Expr Int -> Expr Int -> Expr Bool
  Lt    :: Expr Int -> Expr Int -> Expr Bool
  Not   :: Expr Bool -> Expr Bool

eval :: Expr a -> a
eval (IntE n) = n
eval (BoolE b) = b
eval (Add a b) = eval a + eval b
eval (Mul a b) = eval a * eval b
eval (If c t e) = if eval c then eval t else eval e
eval (Eq a b) = eval a == eval b
eval (Lt a b) = eval a < eval b
eval (Not b) = not (eval b)

pretty :: Expr a -> String
pretty = go 0
  where
    go :: Int -> Expr b -> String
    go _ (IntE n) = show n
    go _ (BoolE b) = if b then "true" else "false"
    go p (Add a b) = paren (p > 6) $ go 6 a ++ " + " ++ go 7 b
    go p (Mul a b) = paren (p > 7) $ go 7 a ++ " * " ++ go 8 b
    go p (If c t e) = paren (p > 0) $ "if " ++ go 0 c ++ " then " ++ go 0 t ++ " else " ++ go 0 e
    go p (Eq a b) = paren (p > 4) $ go 5 a ++ " == " ++ go 5 b
    go p (Lt a b) = paren (p > 4) $ go 5 a ++ " < " ++ go 5 b
    go p (Not b) = paren (p > 9) $ "not " ++ go 10 b
    paren True s = "(" ++ s ++ ")"
    paren False s = s

-- A small stack machine
data Instr = Push !Int | IAdd | IMul | Dup | Swap | Jz Int | Jmp Int | Print
  deriving stock (Show, Eq)

data VM = VM
  { stack   :: [Int]
  , pc      :: !Int
  , output  :: [String]
  , counter :: Int
  } deriving Show

step :: [Instr] -> State VM Bool
step prog = do
  vm@VM{ pc = i, stack = st } <- get
  if i >= length prog
    then pure False
    else do
      case (prog !! i, st) of
        (Push n, _)       -> put vm { stack = n : st, pc = i + 1 }
        (IAdd, a:b:rest)  -> put vm { stack = (a + b) : rest, pc = i + 1 }
        (IMul, a:b:rest)  -> put vm { stack = (a * b) : rest, pc = i + 1 }
        (Dup, a:rest)     -> put vm { stack = a : a : rest, pc = i + 1 }
        (Swap, a:b:rest)  -> put vm { stack = b : a : rest, pc = i + 1 }
        (Jz t, 0:rest)    -> put vm { stack = rest, pc = t }
        (Jz _, _:rest)    -> put vm { stack = rest, pc = i + 1 }
        (Jmp t, _)        -> put vm { pc = t }
        (Print, a:_)      -> put vm { output = show a : output vm, pc = i + 1 }
        (ins, _)          -> error $ "bad state at " ++ show i ++ ": " ++ show ins
      modify' (\v -> v { counter = counter v + 1 })
      pure True

runVM :: [Instr] -> VM
runVM prog = execState loop (VM [] 0 [] 0)
  where
    loop = do
      continue <- step prog
      n <- gets counter
      when (continue && n < 10000) loop

-- Rank-N and typeclass defaults
applyAll :: (forall x. [x] -> [x]) -> ([Int], String) -> ([Int], String)
applyAll f (a, b) = (f a, f b)

class Describe a where
  describe :: a -> String
  describe _ = "<thing>"
  name' :: a -> String

instance Describe Instr where
  name' = show

instance Describe Bool where
  describe b = "bool: " ++ show b
  name' _ = "Bool"

-- Operator definitions with symbols that look like comments
(-->) :: Bool -> Bool -> Bool
a --> b = not a || b

(|--) :: Int -> Int -> Int
(|--) = (-)

(<--) :: Int -> Int -> Int
x <-- y = x - y

-- But two dashes followed by a space starts a comment: this is a comment
--- three dashes also start a comment
-- | Haddock "doc" comment
-- ^ Haddock post-comment

-- Strings and chars at line boundaries
multiGap :: String
multiGap = "string gap starts here \
           \and resumes here \
           \three lines"

primes :: [Int]
primes = sieve [2 ..] where sieve (p : xs) = p : sieve [x | x <- xs, x `mod` p /= 0]

charsWithPrimes :: (Char, Char, String)
charsWithPrimes = let c' = 'c'; c'' = '\'' in (c', c'', [c', c''])

{-# INLINE strictSum #-}
strictSum :: [Int] -> Int
strictSum = go 0 where
  go !acc [] = acc
  go !acc (y:ys) = go (acc + y) ys

main :: IO ()
main = do
  let e = If (Lt (IntE 2) (Add (IntE 1) (IntE 3))) (Mul (IntE 6) (IntE 7)) (IntE 0)
  putStrLn $ pretty e ++ " = " ++ show (eval e)
  let prog = [Push 5, Dup, Print, Push (-1), IAdd, Dup, Jz 8, Jmp 1, Push 0x2A, Print]
      vm = runVM prog
  mapM_ putStrLn (reverse (output vm))
  printf "steps: %d, final stack: %s\n" (counter vm) (show (stack vm))
  ref <- newIORef (0 :: Int)
  forM_ [1 .. 10] $ \i -> modifyIORef' ref (+ i)
  readIORef ref >>= print
  print $ applyAll reverse ([1, 2, 3], "abc")
  print (True --> False, 5 |-- 3, 5 <-- 3)
  let table = M.fromList [(k, v) | (k, v) <- zip "abc" [1 :: Int ..]]
  print $ M.lookup 'b' table
  putStrLn "string with {- comment opener inside -} and -- dashes"
  putStrLn ['\'', '"', '\\']

{- This comment is never closed.
   {- A nested level that is closed -}
   {- A nested level that is NOT closed
      main = putStrLn "not code"
   still nested
   -} back to the outer level
   data NotCode = NotCode
   end of file inside the outer comment
