-- Simple test
module Fac where
import Prelude
import IO

fac :: Int -> Int  -- ignored
fac n =
  case n == 0 of
    False -> n * fac (n - 1)
    True  -> 1

nfib :: Int -> Int   -- ignored
nfib n =
  case n < 2 of
    False -> nfib (n - 1) + nfib (n - 2) + 1
    True  -> 1

res = (fac 10, nfib 30)

main = IO.do
  print $ fac 6
  print $ fst res + snd res
  print $ nfib 35