{-# OPTIONS -fglasgow-exts #-} 
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-- This module defines transformations. Given a term, a transformation returns a list of 
-- results (often a singleton list or the empty list). A transformation can be parameterized
-- with one or more arguments. A rule is in essence just a transformation with a name (which 
-- should be unique). Both transformations and rules can be lifted to work on more complex domains. 
--
-----------------------------------------------------------------------------
module Common.Transformation 
   ( -- * Transformations
     Transformation, makeTrans, makeTransList, (|-), inverseTrans
     -- * Arguments
   , ArgDescr(..), defaultArgDescr, Argument(..)
   , supply1, supply2, supply3, supplyLabeled1, supplyLabeled2, supplyLabeled3
   , hasArguments, expectedArguments, getDescriptors, useArguments
     -- * Rules
   , Rule, name, isMinorRule, isBuggyRule
   , makeRule, makeRuleList, makeSimpleRule, makeSimpleRuleList
   , idRule, emptyRule, minorRule, buggyRule, inverseRule
     -- * Lifting
   , LiftPair, liftPairGet, liftPairSet, liftPairChange, makeLiftPair, Lift(..)
     -- * QuickCheck
   , checkRule, checkRuleSmart
   ) where

import qualified Data.Set as S
import Data.Char
import Data.Ratio
import Test.QuickCheck hiding (arguments)
import Common.Apply
import Common.Utils
import Control.Monad
import Common.Unification

-----------------------------------------------------------
--- Transformations

infix  6 |- 

-- | Abstract data type for representing transformations
data Transformation a
   = Function (a -> [a])
   | Unifiable a => Pattern (ForAll (a, a))
   | forall b . Fun (ArgumentList b) (a -> Maybe b) (b -> Transformation a)
   | forall b . Lift (LiftPair b a) (Transformation b)
   
instance Apply Transformation where
   applyAll (Function f) = f
   applyAll (Pattern  p) = maybe [] return . applyPattern p
   applyAll (Fun _ f g)  = \a -> maybe [] (\b -> applyAll (g b) a) (f a)
   applyAll (Lift lp t ) = \b -> maybe [] (map (\new -> liftPairSet lp new b) . applyAll t) (liftPairGet lp b)
   
-- | Turn a function (which returns its result in the Maybe monad) into a transformation 
makeTrans :: (a -> Maybe a) -> Transformation a
makeTrans f = makeTransList (maybe [] return . f)

-- | Turn a function (which returns a list of results) into a transformation 
makeTransList :: (a -> [a]) -> Transformation a
makeTransList = Function

-- | Constructs a transformation based on two terms (a left-hand side and a
-- right-hand side). The terms must be unifiable. It is checked that no
-- free variables appear in the right-hand side term.
(|-) :: Unifiable a => a -> a -> Transformation a
p |- q | S.null frees = Pattern $ generalizeAll (p, q)
       | otherwise    = error $ "Transformation: free variables in transformation"
 where
   frees = getVars q S.\\ getVars p

applyPattern :: Unifiable a => ForAll (a, a) -> a -> Maybe a
applyPattern pair a = do
   (lhs, rhs) <- return $ unsafeInstantiateWith substitutePair pair
   sub <-  match lhs a
   return (sub |-> rhs)

-- | Return the inverse of a transformation. Only transformation that are constructed with (|-) 
-- can be inversed
inverseTrans :: Transformation a -> Maybe (Transformation a)
inverseTrans trans = 
   case trans of
      Pattern pair -> return $ Pattern $ fmap (\(lhs, rhs) -> (rhs, lhs)) pair
      Lift lp t    -> fmap (Lift lp) (inverseTrans t)
      _ -> Nothing

-----------------------------------------------------------
--- Arguments

-- | A data type for describing an argument of a parameterized transformation
data ArgDescr a = ArgDescr
   { labelArgument   :: String               -- ^ Label that is shown to the user when asked to supply the argument
   , defaultArgument :: Maybe a              -- ^ Default value that can be used
   , parseArgument   :: String -> Maybe a    -- ^ A parser 
   , showArgument    :: a -> String          -- ^ A pretty-printer
   }

-- | Constructor function for an argument descriptor that uses the Show and Read type classes
defaultArgDescr :: (Show a, Read a) => String -> ArgDescr a
defaultArgDescr descr = ArgDescr descr Nothing parse show
 where 
   parse s = case reads s of
                [(a, xs)] | all isSpace xs -> return a
                _ -> Nothing

-- | A type class for types which have an argument descriptor
class Argument a where
   makeArgDescr :: String -> ArgDescr a   -- ^ The first argument is the label of the argument descriptor

instance Argument Int where
   makeArgDescr = defaultArgDescr

instance Argument Integer where
   makeArgDescr = defaultArgDescr

instance Integral a => Argument (Ratio a) where
   makeArgDescr = ratioArgDescr

-- | Parameterization with one argument using a default label
supply1 :: Argument x => 
             (a -> Maybe x) -> (x -> Transformation a) -> Transformation a
supply1 = supplyLabeled1 "argument 1"

-- | Parameterization with two arguments using default labels
supply2 :: (Argument x, Argument y) => 
             (a -> Maybe (x, y)) -> (x -> y -> Transformation a) -> Transformation a
supply2 = supplyLabeled2 ("argument 1", "argument 2")

-- | Parameterization with three arguments using default labels
supply3 :: (Argument x, Argument y, Argument z) => 
             (a -> Maybe (x, y, z)) -> (x -> y -> z -> Transformation a) -> Transformation a
supply3 = supplyLabeled3 ("argument 1", "argument 2", "argument 3")

-- | Parameterization with one argument using the provided label
supplyLabeled1 :: Argument x 
                  => String -> (a -> Maybe x)
                  -> (x -> Transformation a) -> Transformation a
supplyLabeled1 s f t = 
   let args = cons (makeArgDescr s) nil
       nest a = (a, ())
   in Fun args (fmap nest . f) (\(a, ()) -> t a)

-- | Parameterization with two arguments using the provided labels
supplyLabeled2 :: (Argument x, Argument y) 
                   => (String, String) -> (a -> Maybe (x, y)) 
                   -> (x -> y -> Transformation a) -> Transformation a
supplyLabeled2 (s1, s2) f t = 
   let args = cons (makeArgDescr s1) (cons (makeArgDescr s2) nil)
       nest (a, b) = (a, (b, ()))
   in Fun args (fmap nest . f) (\(a, (b, ())) -> t a b)

-- | Parameterization with three arguments using the provided labels
supplyLabeled3 :: (Argument x, Argument y, Argument z) 
                  => (String, String, String) -> (a -> Maybe (x, y, z)) 
                  -> (x -> y -> z -> Transformation a) -> Transformation a
supplyLabeled3 (s1, s2, s3) f t =
   let args = cons (makeArgDescr s1) (cons (makeArgDescr s2) (cons (makeArgDescr s3) nil))
       nest (a, b, c) = (a, (b, (c, ())))
   in Fun args (fmap nest . f) (\(a, (b, (c, ()))) -> t a b c)

-- | Checks whether a rule is parameterized
hasArguments :: Rule a -> Bool
hasArguments = not . null . getDescriptors

-- | Returns a list of argument descriptors
getDescriptors :: Rule a -> [Some ArgDescr]
getDescriptors rule =
   case transformations rule of
      [Fun args f g] -> someArguments args
      [Lift lp t]    -> getDescriptors (rule {transformations = [t]})
      _              -> []

-- | Returns a list of pretty-printed expected arguments. Nothing indicates that there are no such arguments
expectedArguments :: Rule a -> a -> Maybe [String]
expectedArguments rule a =
   case transformations rule of
      [Fun args f g] -> fmap (showArguments args) (f a)
      [Lift lp t]    -> do b <- liftPairGet lp a
                           expectedArguments (rule {transformations = [t]}) b
      _              -> Nothing

-- | Transform a rule and use a list of pretty-printed arguments. Nothing indicates that the arguments are 
-- invalid (not parsable), or that the wrong number of arguments was supplied
useArguments :: [String] -> Rule a -> Maybe (Rule a)
useArguments list rule =
   case transformations rule of
      [t] -> do new <- make t
                return rule {transformations = [new]}
      _   -> Nothing
 where   
   make :: Transformation a -> Maybe (Transformation a)
   make trans = 
      case trans of
         Fun args f g -> fmap g (parseArguments args list)
         Lift lp t    -> fmap (Lift lp) (make t)     
         _            -> Nothing
   
-----------------------------------------------------------
--- Internal machinery for arguments
               
data ArgumentList a
   = Nil a
   | forall b c . Cons ((b, c) -> a, a -> (b, c)) (ArgDescr b) (ArgumentList c)

-- smart constructor
nil :: ArgumentList ()
nil = Nil ()

-- smart constructor (provides the isomorphism proofs)
cons :: ArgDescr a -> ArgumentList b -> ArgumentList (a, b)
cons arg list = Cons (id, id) arg list

showArguments :: ArgumentList a -> a -> [String]
showArguments (Nil _) _ = []
showArguments (Cons (_, f) arg list) a =
   let (b, c) = f a
   in showArgument arg b : showArguments list c
   
parseArguments :: ArgumentList a -> [String] -> Maybe a
parseArguments (Nil a) [] = Just a 
parseArguments (Cons (f, _) arg list) (x:xs) = do
   b <- parseArgument  arg  x
   c <- parseArguments list xs
   return $ f (b, c)
parseArguments _ _ = Nothing
   
someArguments :: ArgumentList a -> [Some ArgDescr]
someArguments (Nil _) = []
someArguments (Cons _ arg list) = Some arg : someArguments list

ratioArgDescr :: Integral a => String -> ArgDescr (Ratio a)
ratioArgDescr descr = ArgDescr descr Nothing parseRatio showRatio
 where
   showRatio  r = show (numerator r) ++ if denominator r == 1 then "" else "/" ++ show (denominator r)
   parseRatio s = 
      let readDivOp s = 
             case dropWhile isSpace s of
                ('/':rest) -> return rest
                [] -> return "1"
                _  -> fail "no (/) operator" 
      in safeHead [ fromInteger x / fromInteger y 
                  | (x, s1) <- reads s
                  , s2 <- readDivOp s1
                  , (y, s3) <- reads s2
                  , y /= 0
                  , all isSpace s3 
                  ]
      
-----------------------------------------------------------
--- Rules

-- | Abstract data type for representing rules
data Rule a = Rule 
   { name            :: String -- ^ Returns the name of the rule (should be unique)
   , transformations :: [Transformation a]
   , isBuggyRule     :: Bool -- ^ Inspect whether or not the rule is buggy (unsound)
   , isMinorRule     :: Bool -- ^ Returns whether or not the rule is minor (i.e., an administrative step that is automatically performed by the system)
   }

instance Show (Rule a) where
   show = name

instance Apply Rule where
   applyAll r a = concatMap (`applyAll` a) (transformations r)

-- | Turn a transformation into a rule: the first argument is the rule's name
makeRule :: String -> Transformation a -> Rule a
makeRule n = makeRuleList n . return

-- | Turn a list of transformations into a single rule: the first argument is the rule's name
makeRuleList :: String -> [Transformation a] -> Rule a
makeRuleList n ts = Rule n ts False False

-- | Turn a function (which returns its result in the Maybe monad) into a rule: the first argument is the rule's name
makeSimpleRule :: String -> (a -> Maybe a) -> Rule a
makeSimpleRule n = makeRule n . makeTrans

-- | Turn a function (which returns a list of results) into a rule: the first argument is the rule's name
makeSimpleRuleList :: String -> (a -> [a]) -> Rule a
makeSimpleRuleList n = makeRule n . makeTransList

-- | A special (minor) rule that always returns the identity
idRule :: Rule a
idRule = minorRule $ makeSimpleRule "Identity" return

-- | A special (minor) rule that is never applicable (i.e., this rule always fails)
emptyRule :: Rule a
emptyRule = minorRule $ makeSimpleRule "Empty" (const Nothing)

-- | Mark the rule as minor (by default, rules are not minor)
minorRule :: Rule a -> Rule a 
minorRule r = r {isMinorRule = True}

-- | Mark the rule as buggy (by default, rules are supposed to be sound)
buggyRule :: Rule a -> Rule a 
buggyRule r = r {isBuggyRule = True}

-- | Return the inverse of a transformation. Only transformation that are constructed with (|-) 
-- can be inversed
inverseRule :: Rule a -> Maybe (Rule a)
inverseRule r = do
   ts <- mapM inverseTrans (transformations r)
   return r
      { name = name r ++ " [inverse]"
      , transformations = ts
      }

-----------------------------------------------------------
--- Lifting

-- | A lift pair consists of two functions: the first to access a value in a context (this can fail,
-- hence the Maybe), the second to update the value in its context
data LiftPair a b = LiftPair 
   { liftPairGet :: b -> Maybe a -- ^ Returns the accessor function of a lift pair
   , liftPairSet :: a -> b -> b  -- ^ Returns the update function of a lift pair
   }
-- | Update a value in a context
liftPairChange :: LiftPair a b -> (a -> Maybe a) -> b -> Maybe b
liftPairChange lp f b = do 
   a   <- liftPairGet lp b
   new <- f a
   return (liftPairSet lp new b)

-- | Constructor for a lift pair
makeLiftPair :: (b -> Maybe a) -> (a -> b -> b) -> LiftPair a b
makeLiftPair = LiftPair

-- | A type class for functors that can be lifted with a lift pair
class Lift f where
   lift :: LiftPair a b -> f a -> f b

instance Lift Transformation where
   lift = Lift
   
instance Lift Rule where
   lift lp r = r {transformations = map (lift lp) (transformations r)}

-----------------------------------------------------------
--- QuickCheck

-- | Check the soundness of a rule: the equality function is passed explicitly
checkRule :: (Arbitrary a, Show a) => (a -> a -> Bool) -> Rule a -> IO ()
checkRule eq rule = do
   putStr $ "[" ++ name rule ++ "] "
   quickCheck (propRule arbitrary eq rule)

-- | Check the soundness of a rule and use a "smart generator" for this. The smart generator 
-- behaves differently on transformations constructed with a (|-), and for these transformations,
-- the left-hand side patterns are used (meta variables are instantiated with random terms)
checkRuleSmart :: (Arbitrary a, Substitutable a, Show a) => (a -> a -> Bool) -> Rule a -> IO ()
checkRuleSmart eq rule = do
   putStr $ "[" ++ name rule ++ "] "
   quickCheck (propRule (smartGen rule) eq rule)
   
propRule :: (Arbitrary a, Show a) => Gen a -> (a -> a -> Bool) -> Rule a -> (a -> Bool) -> Property
propRule gen eq rule condition = 
   forAll gen $ \a ->
      applicable rule a ==> (a `eq` applyD rule a)

smartGen :: (Arbitrary a, Substitutable a) => Rule a -> Gen a
smartGen = oneof . map smartGenTrans . transformations
   
smartGenTrans :: Arbitrary a => Transformation a -> Gen a
smartGenTrans (Pattern p) = smartGenTerm (fmap fst p)
smartGenTrans _           = arbitrary

smartGenTerm :: (Arbitrary a, Substitutable a) => ForAll a -> Gen a
smartGenTerm p = do 
   let (lhs, unique) = instantiate 1000 p
   list <- vector (unique - 1000) 
   let sub = listToSubst $ zip (map (('_':) . show) [1000 :: Int ..]) list
   return (sub |-> lhs)
     
instance Arbitrary a => Arbitrary (Rule a) where
   arbitrary     = liftM4 Rule arbName arbitrary arbitrary arbitrary
   coarbitrary r = coarbitrary (map ord $ name r) . coarbitrary (transformations r)

instance Arbitrary a => Arbitrary (Transformation a) where
   arbitrary = oneof [liftM Function arbitrary]
   coarbitrary (Function f) = variant 0 . coarbitrary f
   coarbitrary (Pattern _)  = variant 1
   coarbitrary (Fun _ _ _)  = variant 2
   coarbitrary (Lift _ _)   = variant 3

-- generates sufficiently long names
arbName :: Gen String
arbName = oneof $ map (return . ('r':) . show) [1 .. 10000 :: Int]