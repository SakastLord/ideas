{-# OPTIONS -fglasgow-exts #-} 
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-- (todo)
--
-----------------------------------------------------------------------------
module Common.Transformation 
   ( Apply(..), applyD, applicable, applyList, applyListAll, applyListD, applyListM, minorRule
   , Rule(..), makeRule, makeRuleList, makeSimpleRule, (|-), combineRules, Transformation, makeTrans
   , LiftPair(..), liftRule, idRule, emptyRule, app, app2, app3, appM, appM2, appM3
   , smartGen, checkRule, checkRuleSmart, propRule
   ) where

import qualified Data.Set as S
import Data.List
import Data.Char
import Data.Maybe
import Test.QuickCheck
import Common.Utils
import Control.Monad
import Common.Unification

class Apply t where
   apply    :: t a -> a -> Maybe a
   applyAll :: t a -> a -> [a] 
   -- default definitions
   apply    ta = safeHead . applyAll ta
   applyAll ta = maybe [] return . apply ta

applicable :: Apply t => t a -> a -> Bool
applicable ta = isJust . apply ta

applyD :: Apply t => t a -> a -> a
applyD ta a = fromMaybe a (apply ta a)

applyM :: (Apply t, Monad m) => t a -> a -> m a
applyM ta a = maybe (fail "applyM") return (apply ta a)
 
applyList :: Apply t => [t a] -> a -> Maybe a
applyList xs a = foldl (\ma t -> join $ fmap (apply t) ma) (Just a) xs

applyListAll :: Apply t => [t a] -> a -> [a]
applyListAll xs a = foldl (\ma t -> concatMap (applyAll t) ma) [a] xs

applyListD :: Apply t => [t a] -> a -> a
applyListD xs a = foldl (\a t -> applyD t a) a xs

applyListM :: (Apply t, Monad m) => [t a] -> a -> m a
applyListM xs a = foldl (\ma t -> ma >>= applyM t) (return a) xs

-----------------------------------------------------------
--- Transformations

infix  6 |- 

data Transformation a
   = Function (a -> Maybe a)
   | Unifiable a => Pattern (ForAll (a, a))
   | forall b . App (a -> Maybe b) (b -> Transformation a)
   
instance Apply Transformation where
   apply (Function f) = f
   apply (Pattern  p) = applyPattern p
   apply (App f g   ) = \a -> f a >>= \b -> apply (g b) a

-- | Constructs a transformation based on two terms (a left-hand side and a
-- | right-hand side). The terms must be unifiable. It is checked that no
-- | free variables appear in the right-hand side term.
(|-) :: Unifiable a => a -> a -> Transformation a
p |- q | S.null frees = Pattern $ generalizeAll (p, q)
       | otherwise    = error $ "Transformation: free variables in transformation"
 where
   frees = getVars q S.\\ getVars p

applyPattern :: Unifiable a => ForAll (a, a) -> a -> Maybe a
applyPattern pair a = do
   mkVar <- return (makeVarInt `asTypeOf` \_ -> a)
   (lhs, rhs) <- return $ unsafeInstantiateWith substitutePair pair
   sub <-  match lhs a
   return (sub |-> rhs)

makeTrans :: (a -> Maybe a) -> Transformation a
makeTrans = Function

-----------------------------------------------------------
--- Rules

data Rule a = Rule 
   { name            :: String
   , transformations :: [Transformation a]
   , isBuggyRule     :: Bool
   , isMinorRule     :: Bool
   }

-- | Smart constructor
makeRuleList :: String -> [Transformation a] -> Rule a
makeRuleList n ts = Rule n ts False False

-- | Smart constructor
makeRule :: String -> Transformation a -> Rule a
makeRule n ts = makeRuleList n [ts]

-- | Smart constructor
makeSimpleRule :: String -> (a -> Maybe a) -> Rule a
makeSimpleRule n f = makeRule n (Function f)

-- | Combine a list of rules. Select the first rule that is applicable (is such a rule exists)
combineRules :: [Rule a] -> Rule a
combineRules rs = Rule
   { name            = concat $ intersperse "/" $ map name rs
   , transformations = concatMap transformations rs
   , isBuggyRule     = any isBuggyRule rs
   , isMinorRule     = all isMinorRule rs
   }

minorRule :: Rule a -> Rule a 
minorRule r = r {isMinorRule = True}

app  :: (a -> x) ->                         (x ->           Transformation a) -> Transformation a
app2 :: (a -> x) -> (a -> y) ->             (x -> y ->      Transformation a) -> Transformation a
app3 :: (a -> x) -> (a -> y) -> (a -> z) -> (x -> y -> z -> Transformation a) -> Transformation a

app  a1       = appM  (Just . a1)
app2 a1 a2    = appM2 (Just . a1) (Just . a2)
app3 a1 a2 a3 = appM3 (Just . a1) (Just . a2) (Just . a3)
 
appM  :: (a -> Maybe x) ->                                     (x ->           Transformation a) -> Transformation a
appM2 :: (a -> Maybe x) -> (a -> Maybe y) ->                   (x -> y ->      Transformation a) -> Transformation a
appM3 :: (a -> Maybe x) -> (a -> Maybe y) -> (a -> Maybe z) -> (x -> y -> z -> Transformation a) -> Transformation a

appM  a1       f = App a1 $ \a -> f a
appM2 a1 a2    f = App a1 $ \a -> App a2 $ \b -> f a b
appM3 a1 a2 a3 f = App a1 $ \a -> App a2 $ \b -> App a3 $ \c -> f a b c
  
-- | Identity rule 
idRule :: Rule a
idRule = minorRule $ makeSimpleRule "Identity" return
   
emptyRule :: Rule a
emptyRule = minorRule $ makeSimpleRule "Empty" (const Nothing)
   
instance Show (Rule a) where
   show = name

instance Eq (Rule a) where
   r1 == r2 = name r1 == name r2

instance Ord (Rule a) where
   r1 `compare` r2 = name r1 `compare` name r2
     
instance Apply Rule where
   apply r a = msum . map (`apply` a) . transformations $ r

-----------------------------------------------------------
--- Lifting rules

data LiftPair a b = LiftPair { getter :: b -> Maybe a, setter :: a -> b -> b }

liftRule :: LiftPair a b -> Rule a -> Rule b
liftRule lp r = r {transformations = [Function f]}
 where
   f x = do
      this <- getter lp x
      new  <- apply r this
      return (setter lp new x)

-----------------------------------------------------------
--- QuickCheck generator

checkRule :: (Arbitrary a, Show a) => (a -> a -> Bool) -> Rule a -> IO ()
checkRule eq rule = do
   putStr $ "[" ++ name rule ++ "] "
   quickCheck (propRule arbitrary eq rule)

checkRuleSmart :: (Arbitrary a, Substitutable a, Show a) => (a -> a -> Bool) -> Rule a -> IO ()
checkRuleSmart eq rule = do
   putStr $ "[" ++ name rule ++ "] "
   quickCheck (propRule (smartGen rule) eq rule)
   
propRule :: (Arbitrary a, Show a) => Gen a -> (a -> a -> Bool) -> Rule a -> Property
propRule gen eq rule = 
   forAll gen $ \a ->
      applicable rule a ==> (a `eq` applyD rule a)

smartGen :: (Arbitrary a, Substitutable a) => Rule a -> Gen a
smartGen rule = 
   let normal = (2*total - length pairs, arbitrary)
       total = length (transformations rule)
       pairs = [ x | p@(Pattern x) <- transformations rule ]
       special p = let ((lhs, _), unique) = instantiateWith substitutePair 1000 p
                   in do list <- vector (unique - 1000) 
                         let sub = listToSubst $ zip (map (('_':) . show) [1000..]) list
                         return (sub |-> lhs)
   in frequency $ normal : zip (repeat 1) (map special pairs)
          
instance Arbitrary a => Arbitrary (Rule a) where
   arbitrary     = liftM4 Rule arbName arbitrary arbitrary arbitrary
   coarbitrary r = coarbitrary (map ord $ name r) . coarbitrary (transformations r)

instance Arbitrary a => Arbitrary (Transformation a) where
   arbitrary = oneof [liftM Function arbitrary]
   coarbitrary (Function f) = variant 0 . coarbitrary f
   coarbitrary (Pattern _)  = variant 1
   coarbitrary (App _ _)    = variant 2

-- generates sufficiently long names
arbName :: Gen String
arbName = oneof $ map (return . ('r':) . show) [1..10000]