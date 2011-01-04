-----------------------------------------------------------------------------
-- Copyright 2010, Open Universiteit Nederland. This file is distributed 
-- under the terms of the GNU General Public License. For more information, 
-- see the file "LICENSE.txt", which is included in the distribution.
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-----------------------------------------------------------------------------
module Domain.Logic.Formula where

import Common.Id
import Common.Rewriting
import Common.Uniplate (Uniplate(..), universe)
import Common.Utils (ShowString, subsets)
import Common.View
import Control.Monad
import Data.Foldable (Foldable, foldMap, toList)
import Data.Traversable (Traversable, sequenceA)
import Control.Applicative
import Data.Monoid (mconcat)
import Data.List
import Data.Maybe
import Domain.Math.Expr.Symbols (openMathSymbol)
import qualified Text.OpenMath.Dictionary.Logic1 as OM

infixr 2 :<->:
infixr 3 :->: 
infixr 4 :||: 
infixr 5 :&&:

-- | The data type Logic is the abstract syntax for the domain
-- | of logic expressions.
data Logic a = Var a
             | Logic a :->:  Logic a            -- implication
             | Logic a :<->: Logic a            -- equivalence
             | Logic a :&&:  Logic a            -- and (conjunction)
             | Logic a :||:  Logic a            -- or (disjunction)
             | Not (Logic a)                    -- not
             | T                                -- true
             | F                                -- false
 deriving (Eq, Ord)

-- | For simple use, we assume the variables to be strings
type SLogic = Logic ShowString

instance Show a => Show (Logic a) where
   show = ppLogic

instance Functor Logic where
   fmap f = foldLogic (Var . f, (:->:), (:<->:), (:&&:), (:||:), Not, T, F)

instance Foldable Logic where
   foldMap f p = mconcat [ f x | Var x <- universe p ]

instance Traversable Logic where
   sequenceA = foldLogic 
      ( liftA Var, liftA2 (:->:), liftA2 (:<->:), liftA2 (:&&:)
      , liftA2 (:||:), liftA Not, pure T, pure F
      )

-- | The type LogicAlg is the algebra for the data type Logic
-- | Used in the fold for Logic.
type LogicAlg b a = (b -> a, a -> a -> a, a -> a -> a, a -> a -> a, a -> a -> a, a -> a, a, a)

-- | foldLogic is the standard fold for Logic.
foldLogic :: LogicAlg b a -> Logic b -> a
foldLogic (var, impl, equiv, conj, disj, neg, true, false) = rec
 where
   rec logic = 
      case logic of
         Var x     -> var x
         p :->: q  -> rec p `impl`  rec q
         p :<->: q -> rec p `equiv` rec q
         p :&&: q  -> rec p `conj`  rec q
         p :||: q  -> rec p `disj`  rec q
         Not p     -> neg (rec p)
         T         -> true 
         F         -> false

-- | Pretty-printer for propositions
ppLogic :: Show a => Logic a -> String
ppLogic = ppLogicPrio 0
        
ppLogicPrio :: Show a => Int -> Logic a -> String
ppLogicPrio = (\f s -> f s "") . flip (foldLogic alg)
 where
   alg = ( pp . show, binop 3 "->", binop 0 "<->", binop 2 "/\\"
         , binop 1 "||", nott, pp "T", pp "F")
   binop prio op p q n = parIf (n > prio) (p (prio+1) . ((" "++op++" ")++) . q prio)
   pp s      = const (s++)
   nott p _  = ("~"++) . p 4
   parIf b f = if b then ("("++) . f . (")"++) else f
   
-- | The monadic join for logic
catLogic :: Logic (Logic a) -> Logic a
catLogic = foldLogic (id, (:->:), (:<->:), (:&&:), (:||:), Not, T, F)
       
-- | evalLogic takes a function that gives a logic value to a variable,
-- | and a Logic expression, and evaluates the boolean expression.
evalLogic :: (a -> Bool) -> Logic a -> Bool
evalLogic env = foldLogic (env, impl, (==), (&&), (||), not, True, False)
 where
   impl p q = not p || q

-- | eqLogic determines whether or not two Logic expression are logically 
-- | equal, by evaluating the logic expressions on all valuations.
eqLogic :: Eq a => Logic a -> Logic a -> Bool
eqLogic p q = all (\f -> evalLogic f p == evalLogic f q) fs
 where 
   xs = varsLogic p `union` varsLogic q
   fs = map (flip elem) (subsets xs) 

-- | A Logic expression is atomic if it is a variable or a constant True or False.
isAtomic :: Logic a -> Bool
isAtomic logic = 
   case logic of
      Var _       -> True
      Not (Var _) -> True
      T           -> True
      F           -> True
      _           -> False

-- | Functions isDNF, and isCNF determine whether or not a Logix expression
-- | is in disjunctive normal form, or conjunctive normal form, respectively. 
isDNF, isCNF :: Logic a -> Bool
isDNF = all isAtomic . concatMap conjunctions . disjunctions
isCNF = all isAtomic . concatMap disjunctions . conjunctions

-- | Function disjunctions returns all Logic expressions separated by an or
-- | operator at the top level.
disjunctions :: Logic a -> [Logic a]
disjunctions p = fromMaybe [p] $ match (magmaListView orMonoid) p

-- | Function conjunctions returns all Logic expressions separated by an and
-- | operator at the top level.
conjunctions :: Logic a -> [Logic a]
conjunctions p = fromMaybe [p] $ match (magmaListView andMonoid) p
 
-- | Count the number of equivalences
countEquivalences :: Logic a -> Int
countEquivalences p = length [ () | _ :<->: _ <- universe p ]

-- | Function varsLogic returns the variables that appear in a Logic expression.
varsLogic :: Eq a => Logic a -> [a]
varsLogic = nub . toList

instance Uniplate (Logic a) where
   uniplate this =
      case this of 
         p :->: q  -> ([p, q], \[a, b] -> a :->:  b)
         p :<->: q -> ([p, q], \[a, b] -> a :<->: b)
         p :&&: q  -> ([p, q], \[a, b] -> a :&&:  b)
         p :||: q  -> ([p, q], \[a, b] -> a :||:  b)
         Not p     -> ([p], \[a] -> Not a)
         _         -> ([], \[] -> this)

instance Different (Logic a) where
   different = (T, F)

instance IsTerm a => IsTerm (Logic a) where
   toTerm = foldLogic
      ( toTerm, binary impliesSymbol, binary equivalentSymbol
      , binary andSymbol, binary orSymbol, unary notSymbol
      , symbol trueSymbol, symbol falseSymbol
      )

   fromTerm a = 
      fromTermWith f a `mplus` liftM Var (fromTerm a)
    where
      f s [] 
         | s == trueSymbol       = return T
         | s == falseSymbol      = return F
      f s [x]
         | s == notSymbol        = return (Not x)
      f s [x, y]
         | s == impliesSymbol    = return (x :->: y)
         | s == equivalentSymbol = return (x :<->: y)
      f s xs@(_:_)
         | s == andSymbol        = return (foldr1 (:&&:) xs)
         | s == orSymbol         = return (foldr1 (:||:) xs)
      f _ _ = fail "fromTerm"

trueSymbol, falseSymbol, notSymbol, impliesSymbol, equivalentSymbol,
   andSymbol, orSymbol :: Symbol

trueSymbol       = openMathSymbol OM.trueSymbol
falseSymbol      = openMathSymbol OM.falseSymbol
notSymbol        = openMathSymbol OM.notSymbol
impliesSymbol    = openMathSymbol OM.impliesSymbol
equivalentSymbol = openMathSymbol OM.equivalentSymbol
andSymbol        = openMathSymbol OM.andSymbol
orSymbol         = openMathSymbol OM.orSymbol

logicOperators :: [Magma (Logic a)]
logicOperators = map toMagma [andMonoid, orMonoid]

andMonoid :: Monoid (Logic a)
andMonoid = monoid andOperator (makeConstant (getId trueSymbol) T isT)
 where
   isT T = True
   isT _ = False 
   
orMonoid :: Monoid (Logic a)
orMonoid = monoid orOperator (makeConstant (getId falseSymbol) F isF)
 where
   isF F = True
   isF _ = False

andOperator:: BinaryOp (Logic a)
andOperator = makeBinaryOp (getId andSymbol) (:&&:) isAnd
 where 
   isAnd (p :&&: q) = Just (p, q)
   isAnd _          = Nothing

orOperator :: BinaryOp (Logic a)
orOperator = makeBinaryOp (getId orSymbol) (:||:) isOr
 where
   isOr (p :||: q) = Just (p, q)
   isOr _          = Nothing

implOperator :: BinaryOp (Logic a)   
implOperator = makeBinaryOp (getId impliesSymbol) (:->:) isImpl
 where
   isImpl (p :->: q) = Just (p, q)
   isImpl _           = Nothing
   
equivOperator :: BinaryOp (Logic a)   
equivOperator = makeBinaryOp (getId equivalentSymbol) (:<->:) isEquiv
 where
   isEquiv (p :<->: q) = Just (p, q)
   isEquiv _           = Nothing