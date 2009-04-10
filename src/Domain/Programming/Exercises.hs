module Domain.Programming.Exercises where

import Domain.Programming.Expr
import Domain.Programming.Parser
import Domain.Programming.Strategies
import Common.Context
import Common.Strategy
import Common.Uniplate
import Common.Exercise
import Common.Transformation
import Common.Apply
import Common.Parsing (SyntaxError(..))
import Common.Rewriting
import Data.Maybe
import Data.Char
import Domain.Programming.Parser
import Domain.Programming.Helium
import qualified UHA_Pretty as PP (sem_Module) 

isortExercise :: Exercise Expr
isortExercise = Exercise   
   { identifier    = "isort"
   , domain        = "programming"
   , description   = "Insertion sort"
   , status        = Experimental
{-   , parser        = \s -> case reads s of  
                             [(a, rest)] | all isSpace rest -> Right a 
                             _ -> Left $ ErrorMessage "parse error" -}
   , parser        = parseExpr
   , subTerm       = \_ _ -> Nothing
   , prettyPrinter = \e -> ppExpr (e,0)
   , equivalence   = \_ _ -> True
   , equality      = (==)
   , finalProperty = const True
   , ruleset       = []
   , strategy      = label "isort"  isortAbstractStrategy
   , differences   = treeDiff
   , ordering      = compare
   , generator     = return undef
   , suitableTerm  = const True
   }

heliumExercise :: Exercise Module
heliumExercise = Exercise   
   { identifier    = "helium"
   , domain        = "programming"
   , description   = "Helium testing"
   , status        = Experimental
   , parser        = \s -> if s == "" then Right emptyProg else modParser s 
   , subTerm       = \_ _ -> Nothing
   , prettyPrinter = show . PP.sem_Module
   , equivalence   = \_ _ -> True
   , equality      = \_ _ -> False
   , finalProperty = const True
   , ruleset       = []
   , strategy      = label "helium" succeed
   , differences   = \_ _ -> [([], Different)]
   , ordering      = \_ _ -> LT
   , generator     = return emptyProg
   , suitableTerm  = const True
   }

modParser s = case compile s of
                Left e  -> Left $ ErrorMessage e
                Right m -> Right m

emptyProg =  Module_Module posUnknown
                           MaybeName_Nothing
                           MaybeExports_Nothing
                           (Body_Body posUnknown [] [])
  where 
    posUnknown = (Range_Range Position_Unknown Position_Unknown)

deriving instance Show Module
deriving instance Show Body
deriving instance Show MaybeName
deriving instance Show MaybeNames
deriving instance Show MaybeExports
deriving instance Show Declaration
deriving instance Show ImportDeclaration
deriving instance Show Export 
deriving instance Show Type
deriving instance Show RightHandSide
deriving instance Show Pattern
deriving instance Show Constructor
deriving instance Show FunctionBinding
deriving instance Show MaybeInt
deriving instance Show Fixity
deriving instance Show MaybeDeclarations
deriving instance Show SimpleType
deriving instance Show ContextItem
deriving instance Show MaybeImportSpecification
deriving instance Show Expression
deriving instance Show RecordPatternBinding
deriving instance Show Literal
deriving instance Show GuardedExpression
deriving instance Show FieldDeclaration
deriving instance Show AnnotatedType
deriving instance Show LeftHandSide
deriving instance Show ImportSpecification
deriving instance Show RecordExpressionBinding
deriving instance Show MaybeExpression
deriving instance Show Statement
deriving instance Show Qualifier
deriving instance Show Alternative
deriving instance Show Import
