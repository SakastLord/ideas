{-# LANGUAGE GADTs #-}
-----------------------------------------------------------------------------
-- Copyright 2011, Open Universiteit Nederland. This file is distributed
-- under the terms of the GNU General Public License. For more information,
-- see the file "LICENSE.txt", which is included in the distribution.
-----------------------------------------------------------------------------
-- |
-- Maintainer  :  bastiaan.heeren@ou.nl
-- Stability   :  provisional
-- Portability :  portable (depends on ghc)
--
-- Services using XML notation
--
-----------------------------------------------------------------------------
module Service.ModeXML
   ( processXML, xmlRequest, openMathConverterTp, stringFormatConverterTp
   , resultOk, resultError, addVersion
   ) where

import Common.Library hiding (exerciseId, (:=))
import Common.Utils (Some(..), readM)
import Control.Monad
import Data.Char
import Data.List
import Data.Maybe
import Service.DomainReasoner
import Service.Evaluator
import Service.FeedbackScript.Syntax
import Service.OpenMathSupport
import Service.Request
import Service.RulesInfo (rulesInfoXML)
import Service.State
import Service.StrategyInfo
import Service.Types
import Text.OpenMath.Object
import Text.XML
import qualified Service.Types as Tp

processXML :: String -> DomainReasoner (Request, String, String)
processXML input = do
   xml  <- liftEither (parseXML input)
   req  <- liftEither (xmlRequest xml)
   resp <- xmlReply req xml
              `catchError` (return . resultError)
   vers <- getVersion
   let out = showXML (if null vers then resp else addVersion vers resp)
   return (req, out, "application/xml")

addVersion :: String -> XML -> XML
addVersion s xml =
   let info = [ "version" := s ]
   in xml { attributes = attributes xml ++ info }

xmlRequest :: XML -> Either String Request
xmlRequest xml = do
   unless (name xml == "request") $
      fail "expected xml tag request"
   srv  <- findAttribute "service" xml
   let a = extractExerciseId xml
   enc  <- case findAttribute "encoding" xml of
              Just s  -> liftM Just (readEncoding s)
              Nothing -> return Nothing
   return Request
      { service    = srv
      , exerciseId = a
      , source     = findAttribute "source" xml
      , dataformat = XML
      , encoding   = enc
      }

xmlReply :: Request -> XML -> DomainReasoner XML
xmlReply request xml = do
   srv <- findService (service request)
   ex  <-
      case exerciseId request of
         Just code -> findExercise code
         Nothing
            | service request == "exerciselist" ->
                 return (Some emptyExercise)
            | otherwise ->
                 fail "unknown exercise code"
   Some conv <-
      case encoding request of
         Just StringEncoding -> return (stringFormatConverter ex)
         -- always use special mixed fraction symbol
         _ -> return (openMathConverter ex)
         -- _ | fromDWO request -> return (dwoConverter ex)
         --   | otherwise       -> return (openMathConverter ex)
   res <- evalService conv srv xml
   return (resultOk res)

--fromDWO :: Request -> Bool
--fromDWO = (== Just "dwo") . fmap (map toLower) . source

extractExerciseId :: Monad m => XML -> m Id
extractExerciseId = liftM newId . findAttribute "exerciseid"

resultOk :: XMLBuilder -> XML
resultOk body = makeXML "reply" $ do
   "result" .=. "ok"
   body

resultError :: String -> XML
resultError txt = makeXML "reply" $ do
   "result" .=. "error"
   element "message" (text txt)

------------------------------------------------------------
-- Mixing abstract syntax (OpenMath format) and concrete syntax (string)

stringFormatConverter :: Some Exercise -> Some (Evaluator XML XMLBuilder)
stringFormatConverter (Some ex) = Some (stringFormatConverterTp ex)

stringFormatConverterTp :: Exercise a -> Evaluator XML XMLBuilder a
stringFormatConverterTp ex =
   Evaluator (xmlEncoder False f ex) (xmlDecoder False g ex)
 where
   f  = return . element "expr" . text . prettyPrinter ex
   g xml0 = do
      xml <- findChild "expr" xml0 -- quick fix
      -- guard (name xml == "expr")
      let input = getData xml
      either (fail . show) return (parser ex input)

openMathConverter :: Some Exercise -> Some (Evaluator XML XMLBuilder)
openMathConverter (Some ex) = Some (openMathConverterTp True ex)

--dwoConverter :: Some Exercise -> Some (Evaluator XML XMLBuilder)
--dwoConverter (Some ex) = Some (openMathConverterTp True ex)

openMathConverterTp :: Bool -> Exercise a -> Evaluator XML XMLBuilder a
openMathConverterTp withMF ex =
   Evaluator (xmlEncoder True f ex) (xmlDecoder True g ex)
 where
   f a = liftM (builder . toXML) $ handleMixedFractions $ toOpenMath ex a
   g xml = do
      xob   <- findChild "OMOBJ" xml
      omobj <- liftEither (xml2omobj xob)
      case fromOpenMath ex omobj of
         Just a  -> return a
         Nothing -> fail "Invalid OpenMath object for this exercise"
   
   -- Remove special mixed-fraction symbol (depending on boolean argument)
   handleMixedFractions = if withMF then id else liftM noMixedFractions


xmlEncoder :: Bool -> (a -> DomainReasoner XMLBuilder) -> Exercise a -> Encoder XMLBuilder a
xmlEncoder isOM enc ex tp a =
   case tp of
      Iso p t    -> xmlEncoder isOM enc ex t (to p a)
      Pair t1 t2 -> do
         sx <- xmlEncoder isOM enc ex t1 (fst a)
         sy <- xmlEncoder isOM enc ex t2 (snd a)
         return (sx >> sy)
      t1 :|: t2 -> case a of
                      Left  x -> xmlEncoder isOM enc ex t1 x
                      Right y -> xmlEncoder isOM enc ex t2 y
       
      List t -> liftM sequence_ (mapM (xmlEncoder isOM enc ex t) a)
      Exercise      -> return (return ())
      Exception     -> fail a
      Unit          -> return (return ())
      Id            -> return (text (show a))
      IO t          -> do x <- liftIO (runIO a)
                          xmlEncoder isOM enc ex (Exception :|: t) x
      Tp.Tag s t1
         | s == "RulesInfo" -> 
              rulesInfoXML ex enc
         | otherwise ->
              case useAttribute t1 of
                 Just f | s /= "message" -> return (s .=. f a)
                 _  -> liftM (element s) (xmlEncoder isOM enc ex t1 a)
      Tp.Strategy   -> return (builder (strategyToXML a))
      Tp.Rule       -> return ("ruleid" .=. showId a)
      Tp.Term       -> enc a
      Tp.Context    -> encodeContext isOM enc a
      Tp.Location   -> return ("location" .=. show a)
      Tp.BindingTp  -> return (encodeTypedBinding isOM a)
      Tp.Text       -> encodeText enc ex a
      Tp.Bool       -> return (text (map toLower (show a)))
      Tp.Int        -> return (text (show a))
      Tp.String     -> return (text a)
      _             -> fail $ "Type " ++ show tp ++ " not supported in XML"

xmlDecoder :: Bool -> (XML -> DomainReasoner a) -> Exercise a -> Decoder XML a
xmlDecoder b f ex = Decoder
   { decodeType      = xmlDecodeType b (xmlDecoder b f ex)
   , decodeTerm      = f
   , decoderExercise = ex
   }

xmlDecodeType :: Bool -> Decoder XML a -> Type a t -> XML -> DomainReasoner (t, XML)
xmlDecodeType b dec serviceType =
   case serviceType of
      Tp.Context     -> keep $ decodeContext b (decoderExercise dec) (decodeTerm dec)
      Tp.Location    -> keep $ liftM (read . getData) . findChild "location"
      Tp.Id          -> keep $ \xml -> do
                           a <- findChild "location" xml
                           return (newId (getData a))
      Tp.Rule        -> keep $ fromMaybe (fail "unknown rule") . liftM (getRule (decoderExercise dec) . newId . getData) . findChild "ruleid"
      Tp.Term        -> keep $ decodeTerm dec
      Tp.StrategyCfg -> keep decodeConfiguration
      Tp.Script      -> keep $ \xml ->
                           case findAttribute "script" xml of
                              Just s  -> readScript s
                              Nothing ->
                                 defaultScript (getId (decoderExercise dec))
      Tp.Tag s t
         | s == "state" -> keep $ \xml -> do
              g  <- equalM stateType serviceType
              st <- decodeState b (decoderExercise dec) (decodeTerm dec) xml
              return (g st)
         | s == "answer" -> keep $ \xml -> do
              c <- findChild "answer" xml
              (a, _) <- xmlDecodeType b dec t c
              return a
         | s == "difficulty" -> keep $ \xml -> do
              g <- equalM difficultyType serviceType
              a <- findAttribute "difficulty" xml
              maybe (fail "unknown difficulty level") (return . g) (readDifficulty a)
         {- s == "prefix" -> \xml -> do
              f  <- equalM String t
              mp <- decodePrefix (decoderExercise dec) xml
              s  <- maybe (fail "no prefix") (return . show) mp
              return (f s, xml) -}
         | s == "args" -> keep $ \xml -> do
              g   <- equalM envType t
              env <- decodeArgEnvironment b xml
              return (g env)
         | otherwise -> keep $ \xml ->
              findChild s xml >>= liftM fst . xmlDecodeType b dec t

      _ -> decodeDefault dec serviceType
 where
   keep :: Monad m => (XML -> m a) -> XML -> m (a, XML)
   keep f xml = liftM (\a -> (a, xml)) (f xml)

useAttribute :: Type a t -> Maybe (t -> String)
useAttribute String = Just id
useAttribute Bool   = Just (map toLower . show)
useAttribute Int    = Just show
useAttribute _      = Nothing

decodeState :: Monad m => Bool -> Exercise a -> (XML -> m a) -> XML -> m (State a)
decodeState b ex f xmlTop = do
   xml  <- findChild "state" xmlTop
   mpr  <- decodePrefix ex xml
   term <- decodeContext b ex f xml
   return (makeState ex mpr term)

decodePrefix :: Monad m => Exercise a -> XML -> m [Prefix (Context a)]
decodePrefix ex xml
   | all isSpace prefixText =
        return [emptyPrefix str]
   | prefixText ~= "no prefix" =
        return []
   | otherwise = do
        a  <- readM prefixText
        pr <- makePrefix a str
        return [pr]
 where
   prefixText = maybe "" getData (findChild "prefix" xml)
   str = strategy ex
   a ~= b = g a == g b
   g = map toLower . filter (not . isSpace)

decodeContext :: Monad m => Bool -> Exercise a -> (XML -> m a) -> XML -> m (Context a)
decodeContext b ex f xml = do
   expr <- f xml
   env  <- decodeEnvironment b xml
   return (makeContext ex env expr)

decodeEnvironment :: Monad m => Bool -> XML -> m Environment
decodeEnvironment b xml =
   case findChild "context" xml of
      Just this -> foldM add mempty (children this)
      Nothing   -> return mempty
 where
   add env item = do
      unless (name item == "item") $
         fail $ "expecting item tag, found " ++ name item
      n  <- findAttribute "name"  item
      case findChild "OMOBJ" item of
         -- OpenMath object found inside item tag
         Just this | b ->
            case xml2omobj this >>= fromOMOBJ of
               Left err -> fail err
               Right term ->
                  return $ insertRef (makeRef n) (term :: Term) env
         -- Simple value in attribute
         _ -> do
            value <- findAttribute "value" item
            return $ insertRef (makeRef n) value env

decodeConfiguration :: MonadPlus m => XML -> m StrategyConfiguration
decodeConfiguration xml =
   case findChild "configuration" xml of
      Just this -> mapM decodeAction (children this)
      Nothing   -> fail "no strategy configuration"
 where
   decodeAction item = do
      guard (null (children item))
      action <-
         case find (\a -> map toLower (show a) == name item) configActions of
            Just a  -> return a
            Nothing -> fail $ "unknown action " ++ show (name item)
      cfgloc <- findAttribute "name" item
      return (byName (newId cfgloc), action)

encodeEnvironment :: Bool -> Context a -> XMLBuilder
encodeEnvironment b ctx
   | null values = return ()
   | otherwise = element "context" $
        forM_ values $ \tb ->
           element "item" $ do
              "name"  .=. showId tb
              case getTermValue tb of
                 term | b -> 
                    builder (omobj2xml (toOMOBJ term))
                 _ -> "value" .=. showValue tb
 where
   loc    = location ctx
   values = bindings (withLoc ctx)
   withLoc
      | null loc  = id
      | otherwise = insertRef (makeRef "location") loc 

encodeContext :: Monad m => Bool -> (a -> m XMLBuilder) -> Context a -> m XMLBuilder
encodeContext b f ctx = do
   a   <- fromContext ctx
   xml <- f a
   return (xml >> encodeEnvironment b ctx)

encodeTypedBinding :: Bool -> Binding -> XMLBuilder
encodeTypedBinding b tb = element "argument" $ do
   "description" .=. showId tb
   case getTermValue tb of
      term | b -> builder $ 
         omobj2xml $ toOMOBJ term
      _ -> text (showValue tb)

decodeArgEnvironment :: MonadPlus m => Bool -> XML -> m Environment
decodeArgEnvironment b = 
   liftM makeEnvironment . mapM make . filter isArg . children
 where
   isArg = (== "argument") . name
 
   make :: MonadPlus m => XML -> m Binding
   make xml = do
      a <- findAttribute "description" xml
      case findChild "OMOBJ" xml of
         -- OpenMath object found inside tag
         Just this | b -> 
            case xml2omobj this >>= fromOMOBJ of
               Left err   -> fail err
               Right term -> return (termBinding a term)
         -- Simple value
         _ -> return (makeBinding (makeRef a) (getData xml))
         
   termBinding :: String -> Term -> Binding
   termBinding = makeBinding . makeRef
   
encodeText :: (a -> DomainReasoner XMLBuilder) -> Exercise a -> Text -> DomainReasoner XMLBuilder
encodeText f ex = liftM sequence_ . mapM make . textItems
 where
   make t@(TextTerm a) = fromMaybe (returnText t) $ do
      v <- hasTermView ex
      b <- match v a
      return (f b)
   make a = returnText a
   
   returnText = return . text . show