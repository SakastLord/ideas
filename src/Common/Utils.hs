{-# OPTIONS -fglasgow-exts #-}
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-- A collection of general utility functions
--
-----------------------------------------------------------------------------
module Common.Utils where

import Data.Char
import Data.List
import Test.QuickCheck
import Control.Monad
import System.Random
import qualified Data.Map as M

data Some f = forall a . Some (f a)

thoroughCheck :: Testable a => a -> IO ()
thoroughCheck = check $ defaultConfig {configMaxTest = 1000, configMaxFail = 5000}

generateStd :: Gen a -> IO a
generateStd gen = do 
   stdgen <- newStdGen
   return (generate 100 stdgen gen)

subsets :: [a] -> [[a]]
subsets = foldr op [[]]
 where op a list = list ++ map (a:) list
 
isSubsetOf :: Eq a => [a] -> [a] -> Bool
isSubsetOf xs ys = all (`elem` ys) xs

distinct :: Eq a => [a] -> Bool
distinct []     = True
distinct (x:xs) = all (/=x) xs && distinct xs 

safeHead :: [a] -> Maybe a
safeHead (x:_) = return x
safeHead _     = Nothing

splitAtElem :: Eq a => a -> [a] -> Maybe ([a], [a])
splitAtElem c s =
   case break (==c) s of
      (xs, _:ys) -> Just (xs, ys) 
      _          -> Nothing

splitsWithElem :: Eq a => a -> [a] -> [[a]]
splitsWithElem c s = 
   case splitAtElem c s of
      Just (xs, ys) -> xs : splitsWithElem c ys
      Nothing       -> [s]
      
{- safeIndex :: Int -> [a] -> Maybe a
safeIndex 0 (x:_)  = return x
safeIndex n (_:xs) = safeIndex (n-1) xs
safeIndex _ _      = Nothing -}

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

isNatural :: String -> Bool
isNatural x = all isDigit x && not (null x)

fst3 (x, _, _) = x
snd3 (_, x, _) = x
thd3 (_, _, x) = x

uncurry3 :: (a -> b -> c -> d) -> (a, b, c) -> d
uncurry3 f (a, b, c) = f a b c

commaList :: [String] -> String
commaList = concat . intersperse ", "

indent :: Int -> String -> String
indent n = unlines . map (\s -> replicate n ' ' ++ s) . lines

primes :: [Int]
primes = rec [2..]
 where
   rec (x:xs) = x : rec (filter (\y -> y `mod` x /= 0) xs)

instance Show (a -> b) where
   show _ = "<function>"
   
instance Arbitrary Char where
   arbitrary = let chars = ['a' .. 'z'] ++ ['A' .. 'Z']
               in oneof (map return chars)
   coarbitrary = coarbitrary . ord
   
instance (Ord k, Arbitrary k, Arbitrary a) => Arbitrary (M.Map k a) where
   arbitrary   = liftM M.fromList arbitrary
   coarbitrary = coarbitrary . M.toList