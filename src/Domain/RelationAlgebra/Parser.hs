-----------------------------------------------------------------------------
-- Copyright 2008, Open Universiteit Nederland. This file is distributed 
-- under the terms of the GNU General Public License. For more information, 
-- see the file "LICENSE.txt", which is included in the distribution.
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-- (todo)
--
-----------------------------------------------------------------------------
module Domain.RelationAlgebra.Parser (parseRelAlg, ppRelAlg) where

import Domain.RelationAlgebra.Formula
import UU.Parsing
import UU.Parsing.CharParser
import UU.Scanner
import Data.Char

parseRelAlg  :: String -> (RelAlg, [Message Char Pos])
parseRelAlg = runParser disjunction
 where
   disjunction = pChainr ((:||:) <$ orSym )  conjunction 
   conjunction = pChainr ((:&&:) <$ andSym)  addition
   addition    = pChainr ((:+:)  <$ addSym)  composition
   composition = pChainr ((:.:)  <$ compSym) basic
   basic       = basicWith disjunction
   
basicWith :: CharParser RelAlg -> CharParser RelAlg
basicWith p = foldl (flip ($)) <$> atom <*> pList post
 where
   post =  Not <$ notSym <|> Inv <$ invSym
   atom =  Var <$> pvarid
       <|> pparens p
       <|> V     <$ pSym 'V'
       <|> empty <$ pSym 'E' -- The empty relation is no longer present in the data-type, but E remains an abbreviation (for now)
       <|> I     <$ pSym 'I'
                
andSym  = pToks "/\\"
orSym   = pToks "\\/" 
addSym  = pToks "!"
compSym = pToks ";"
notSym = pToks "-"
invSym = pToks "~"

fstPair :: Pair a b -> a
fstPair (Pair a _)  =  a

runParser  :: CharParser a -> String -> (a, [Message Char Pos])
runParser pLogic input = (result, messages)
 where
   steps    = parseString pLogic (filter (not . isSpace) input)
   result   = fstPair (evalSteps steps)
   messages = getMsgs steps
   
pparens :: CharParser a -> CharParser a
pparens = pPacked (pSymLow '(') (pSymLow ')')  

pvarid  :: CharParser String
pvarid = pList1 (pAnySymInf ['a'..'z'])    

pAnySymInf xs = foldr1 (<|>) (map pSymInf xs)

pSymInf a       =  pCostSym   1000 a a
pSymLow a       =  pCostSym      1 a a

-----------------------------------------------------------
--- Helper-function for parentheses analyses
{-
analyseAndParse :: Parser Token a -> [Token] -> Either SyntaxError a
analyseAndParse p ts =
   case checkParentheses ts of
      Just err -> Left err
      Nothing  -> case parse p ts of
                     (_, m:_) -> Left (fromMessage m)
                     (a, _)   -> Right a -}
                                        
-----------------------------------------------------------
--- Pretty-Printer

ppRelAlg :: RelAlg -> String
ppRelAlg = ppRelAlgPrio 0

ppRelAlgPrio :: Int -> RelAlg -> String 
ppRelAlgPrio n p = foldRelAlg (var, binop 5 ";", binop 4 "!", binop 3 "/\\", binop 2 "\\/", nott, inv, var "V", var "I") p n ""
 where
   binop prio op p q n = parIf (n > prio) (p (prio+1) . ((" "++op++" ")++) . q prio)
   var       = const . (++)
   nott p _  = p 6 . ("-"++) 
   inv  p _  = p 6 . ("~"++)
   parIf b f = if b then ("("++) . f . (")"++) else f