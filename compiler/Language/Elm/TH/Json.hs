-----------------------------------------------------------------------------
--
-- Module      :  Language.Elm.TH.Json
-- Copyright   :  Copyright: (c) 2011-2013 Joey Eremondi
-- License     :  BSD3
--
-- Maintainer  :  joey.eremondi@usask.ca
-- Stability   :  experimental
-- Portability :  portable
--
-- |
--
-----------------------------------------------------------------------------
module Language.Elm.TH.Json where

{-# LANGUAGE TemplateHaskell, QuasiQuotes, MultiWayIf #-}

import Language.Haskell.TH.Syntax

import Data.Aeson.TH


import qualified SourceSyntax.Module as M
import qualified SourceSyntax.Declaration as D
import qualified SourceSyntax.Expression as E
import qualified SourceSyntax.Literal as L
import qualified SourceSyntax.Location as Lo
import qualified SourceSyntax.Pattern as P
import qualified SourceSyntax.Type as T

import Data.List (isPrefixOf)

import Language.Haskell.TH.Desugar.Sweeten
import Language.Haskell.TH.Desugar

import Language.Elm.TH.Util


--import Parse.Expression (makeFunction)

import Control.Applicative


------------------------------------------------------------------------------------
--Helpers to make to and fromJson functions

-- | Build the AST for the base-cases, translating primitive types, lists, tuples, etc.
makeJsonCase0 (jCtor, ctorName) = Match (ConP (mkName jCtor) [] ) (NormalB $ ConE (mkName ctorName) ) [] 
makeJsonCase1 (jCtor, varName, ctorName) = Match (ConP (mkName jCtor) [VarP (mkName varName)]) (NormalB $ AppE (ConE (mkName ctorName)) (VarE (mkName varName))) [] 

-- | A list of Match values representing the "base cases" for toJson
-- | These are checked before ADT conversion is performed
unJsonCase :: [Match]
unJsonCase = map makeJsonCase1 list1 ++ map makeJsonCase0 list0 ++ [intCase]
  where
    list1 = [--("Array", "lst", "FromJSON_List"), --TODO can do types?
             ( sumTypePrefix ++"_Float", "n",  "Json.Number"),
             (sumTypePrefix ++"_String", "s", "Json.String"),
             (sumTypePrefix ++"_Bool", "b", "Json.Boolean")]
    list0 = [(sumTypePrefix ++ "_Null", "Json.Null")]
    intCase = Match (ConP (mkName $ sumTypePrefix ++"_Int") [VarP (mkName "i")]) (NormalB $ AppE (ConE (mkName "Json.Number")) (AppE (VarE $ mkName "toFloat")(VarE (mkName "i")) ) ) []
    --Can't encode lists directly
    --listCase = Match (ConP (mkName "Json.Array") [VarP (mkName "l")]) (NormalB $ AppE (ConE (mkName "FromJSON_List")) (AppE (AppE (VarE (mkName "map")) (VarE (mkName "fromJson"))) (VarE (mkName "l")) )) [] 

-- | A list of Match values representing the "base cases" for fromJson
-- | These are checked before ADT conversion is attempted    
jsonCase :: [Match]
jsonCase = map makeJsonCase1 list1 ++ map makeJsonCase0 list0 ++ [listCase]
  where
    list1 = [--("Array", "lst", "FromJSON_List"), --TODO can do types?
             ("Json.Number", "n", sumTypePrefix ++"_Float"),
             ("Json.String", "s", sumTypePrefix ++"_String"),
             ("Json.Boolean", "b", sumTypePrefix ++"_Bool")]
    list0 = [("Json.Null", sumTypePrefix ++"_Null")]
    listCase = Match (ConP (mkName "Json.Array") [VarP (mkName "l")]) (NormalB $ AppE (ConE (mkName $ sumTypePrefix ++"_List")) (AppE (AppE (VarE (mkName "map")) (VarE (mkName "fromJson"))) (VarE (mkName "l")) )) []     
    

-- | Filter function to test if a dec is a data
isData :: Dec -> Bool
isData DataD{} = True
isData NewtypeD{} = True
isData _ = False

-- | Expression for the fromJson function
fromJson :: Exp
fromJson = VarE (mkName "fromJson")

-- | Expression for the toJson function
toJson :: Exp
toJson = VarE (mkName "toJson")

-- | The variable representing the current Json argument
json :: Exp
json = VarE (mkName "json")

-- | Pattern for an argument named 'json'
jsonPat :: Pat
jsonPat = VarP (mkName "json") 

-- | Variable for the getter function getting the nth variable from a Json
nthVar :: Exp
nthVar = VarE (mkName "nthVar")

-- | Variable for the getter function getting the nth variable from a Json
jsonType :: Exp
jsonType = VarE (mkName "getType")

-- | Variable for the getter function getting the nth variable from a Json
jsonCtor :: Exp
jsonCtor = VarE (mkName "getCtor")

-- | Expression getting the nth subvariable from a JSON object
getNthVar :: String -> Exp
getNthVar nstr = AppE (AppE nthVar json ) (LitE $ StringL nstr)

-- | Expression to access the "type" field of a JSON object
getType :: Exp
getType = AppE jsonType json  

-- | Expression to access the constructor field of a JSON object
getCtor :: Exp
getCtor = AppE jsonCtor json 

-- | Expression representing function composition
fnComp :: Exp
fnComp = VarE $ mkName "."

-- | The string prefix for the massive JSON sum type
sumTypePrefix :: String
sumTypePrefix = "BoxedJson"

-- |The String argument of the massive JSON sum type property denoting a given ADT
typeString :: Name -> Q String
typeString name = return $ sumTypePrefix ++ "_" ++  nameToString name


-- |The Pattern to unbox a value into its type from the massive sum type
-- | the second argument is the name to bind the value to
unJsonPat :: Name -> Name -> Q Pat
unJsonPat typeName nameToBind = do
  typeCtor <- mkName <$> typeString typeName
  return $ ConP typeCtor [VarP nameToBind]

-- | The name of the constructor which wraps
-- the type with the given name into the giant sum type
sumTypeCtor :: Name -> Q Name
sumTypeCtor name = mkName <$> typeString name

-- | Recursively generates an expression for the function which takes an argument of type BoxedJson
-- and converts it, while also extracting it from the BoxedJson type
unJsonType :: Type -> Q Exp
unJsonType (ConT name) = do
  argName <- newName "x"
  lambdaPat <- unJsonPat name argName
  let unCtor = LamE [lambdaPat] (VarE argName)
  return $ InfixE (Just unCtor) fnComp (Just fromJson)
  where
    fnComp = VarE $ mkName "."

unJsonType (AppT ListT t) = do
  subFun <- unJsonType t
  let mapVar = VarE $ mkName "mapJson"
  return $ AppE mapVar subFun

  
--Unpack JSON into a tuple type
--We convert the JSON to a list
--We make a lambda expression which applies the UnFromJSON function to each element of the tuple
unJsonType t
  | isTupleType t = do
      
      let tList = tupleTypeToList t
      let n = length tList
      --Generate the lambda to convert the list into a tuple
      subFunList <- mapM unJsonType tList
      argNames <- mapM (newName . ("x" ++) . show) [1 .. n]
      let argValues = map VarE argNames
      let argPat = ListP $ map VarP argNames
      let lambdaBody = TupE $ zipWith AppE subFunList argValues
      let lambda = LamE [argPat] lambdaBody
      let makeList = VarE $ mkName "makeList"
      
      return $ InfixE (Just lambda) fnComp (Just makeList)
  | otherwise = do
      test <- isIntType t
      case test of
        True -> do
          argName <- newName "x"
          lambdaPat <- unJsonPat (mkName "Int") argName
          let unCtor = LamE [lambdaPat] (AppE (VarE (mkName "round")) (VarE argName) )
          return $ InfixE (Just unCtor) fnComp (Just fromJson)
        _ -> unImplemented $ "Can't un-json type " ++ show t
        
-- | Generate a declaration, and a name bound in that declaration,
-- Which unpacks a value of the given type from the nth field of a JSON object
getSubJson :: (Type, Int) -> Q (Name, Dec)
-- We need special cases for lists and tuples, to unpack them
--TODO recursive case
getSubJson (t, n) = do
  funToApply <- unJsonType t
  subName <- newName "subVar"
  let subLeftHand = VarP subName
  let subRightHand = NormalB $ AppE funToApply (getNthVar $ show n)
  return (subName, ValD subLeftHand subRightHand [])
  

-- | Given a type constructor, generate the match which matches the "ctor" field of a JSON object
-- | to apply the corresponding constructor to the proper arguments, recursively extracted from the JSON
fromMatchForCtor :: Con -> Q Match        
fromMatchForCtor (NormalC name types) = do
  let matchPat = LitP $ StringL $ nameToString name
  (subNames, subDecs) <- unzip <$> mapM getSubJson (zip (map snd types) [1,2..])
  let body = NormalB $ if null subNames
              then applyArgs subNames ctorExp
              else LetE subDecs (applyArgs subNames ctorExp)
  return $ Match matchPat body []
  where
    ctorExp = ConE name
    applyArgs t accum = foldl (\ accum h -> AppE accum (VarE h)) accum t 

fromMatchForCtor (RecC name vstList) = do
  let nameTypes = map (\(a,_,b)->(a,b)) vstList
  return $ unImplemented "Records for JSON"
    
-- | Given a type delcaration, generate the match which matches the "type" field of a JSON object
-- and then defers to a case statement on constructors for that type
fromMatchForType :: Dec -> Q Match
fromMatchForType dec@(DataD _ name _ ctors []) = do
  let matchPat = LitP $ StringL $ nameToString name
  ctorMatches <- mapM fromMatchForCtor ctors
  let typeBody = NormalB $ CaseE getCtor ctorMatches
  jsonName <- newName "typedJson"
  typeCtor <- sumTypeCtor name
  let typeBodyDec = ValD (VarP jsonName) typeBody []
  let ret = AppE (ConE typeCtor) (VarE jsonName)
  let body = NormalB $ LetE [typeBodyDec] ret
  return $ Match matchPat body []

fromMatchForType (NewtypeD cxt name tyBindings  ctor nameList) = 
  fromMatchForType $ DataD cxt name tyBindings [ctor] nameList  
  
-- |Given a list of declarations, generate the fromJSON function for all
-- types defined in the declaration list
makeFromJson :: [Dec] -> Q [Dec]
makeFromJson allDecs = do
  let decs = filter isData allDecs
  typeMatches <- mapM fromMatchForType decs
  let objectBody = NormalB $ CaseE getType typeMatches
  let objectMatch = Match WildP objectBody []
  let body = NormalB $ CaseE json (jsonCase ++ [objectMatch])
  return [ FunD (mkName "fromJson") [Clause [jsonPat] body []] ]

  
-----------------------------------------------------------------------
-- |Given a list of declarations, generate the toJSON function for all
-- types defined in the declaration list
makeToJson :: [Dec] -> Q [Dec]
makeToJson allDecs = do
  let decs = filter isData allDecs
  typeMatches <- mapM toMatchForType decs
  --TODO remove jsonCase, put in equivalent
  let body = NormalB $ CaseE json (unJsonCase ++ typeMatches)
  return [ FunD (mkName "toJson") [Clause [jsonPat] body []] ]

-- | Helper function to generate a the names X1 .. Xn with some prefix X  
nNames :: Int -> String -> Q [Name]
nNames n base = do
  let varStrings = map (\n -> base ++ show n) [1..n]
  mapM newName varStrings

--Generate the Match which matches against the given constructor
--then packs its argument into a JSON with the proper type, ctor and argument data
toMatchForCtor :: Name -> Con -> Q Match        
toMatchForCtor typeName (NormalC name types) = do
  let n = length types
  adtNames <- nNames n "adtVar"
  jsonNames <- nNames n "jsonVar"
  let adtPats = map VarP adtNames
  let matchPat = ConP name adtPats
  jsonDecs <- mapM makeSubJson (zip3 (map snd types) adtNames jsonNames)
  dictName <- newName "objectDict"
  dictDec <-  makeDict typeName name dictName jsonNames
  let ret = AppE (VarE $ mkName "Json.Object") (VarE dictName)
  let body = NormalB $ LetE (jsonDecs ++ [dictDec]) ret
  return $ Match matchPat body []

-- | Generate the declaration of a dictionary mapping field names to values
-- to be used with the JSON Object constructor
makeDict :: Name -> Name -> Name -> [Name] -> Q Dec    
makeDict typeName ctorName dictName jsonNames = do
  let leftSide = VarP dictName
  let jsonExps = map VarE jsonNames
  let fieldNames = map (LitE . StringL . show) [1 .. (length jsonNames)]
  let tuples = map (\(field, json) -> TupE [field, json]) (zip fieldNames jsonExps)
  let typeExp = LitE $ StringL $ nameToString typeName
  let ctorExp = LitE $ StringL $ nameToString ctorName
  let typeTuple = TupE [LitE $ StringL "type", AppE (VarE (mkName "Json.String")) typeExp ]
  let ctorTuple = TupE [LitE $ StringL "ctor", AppE (VarE (mkName "Json.String")) ctorExp ]
  let tupleList = ListE $ [typeTuple, ctorTuple] ++ tuples
  let rightSide = NormalB $ AppE (VarE $ mkName "Dict.fromList") tupleList
  return $ ValD leftSide rightSide []
  
 -- |Generate the Match which matches against the BoxedJson constructor
 -- to properly encode a given type
toMatchForType :: Dec -> Q Match
toMatchForType dec@(DataD _ name _ ctors []) = do
  varName <- newName "adt"
  matchPat <- unJsonPat name varName
  ctorMatches <- mapM (toMatchForCtor name) ctors
  let body = NormalB $ CaseE (VarE varName) ctorMatches
  return $ Match matchPat body []  

toMatchForType (NewtypeD cxt name tyBindings  ctor nameList) = 
  toMatchForType $ DataD cxt name tyBindings [ctor] nameList
-- | Generate the declaration of a value converted to Json
-- given the name of an ADT value to convert
makeSubJson :: (Type, Name, Name) -> Q Dec
-- We need special cases for lists and tuples, to unpack them
--TODO recursive case
makeSubJson (t, adtName, jsonName) = do
  funToApply <- pureJsonType t
  let subLeftHand = VarP jsonName
  let subRightHand = NormalB $ AppE funToApply (VarE adtName)
  return $ ValD subLeftHand subRightHand []

-- | For a type, generate the expression for the function which takes a value of that type
--  and converts it to JSON
-- used to recursively convert the data of ADTs
pureJsonType :: Type -> Q Exp
--Base case: if an ADT, just call toJson with the appropriate constructor
pureJsonType (ConT name) = do
  argName <- newName "adt"
  typeCtor <- sumTypeCtor name
  lambdaPat <- unJsonPat name argName
  let addCtor = LamE [VarP argName] (AppE (ConE typeCtor) (VarE argName))
  return $ InfixE (Just toJson) fnComp (Just addCtor)
  where
    fnComp = VarE $ mkName "."

pureJsonType (AppT ListT t) = do
  subFun <- pureJsonType t
  let listCtor = VarE $ mkName "Json.Array"
  let mapVar = VarE $ mkName "map"
  return $ InfixE (Just listCtor ) fnComp (Just (AppE mapVar subFun))
  where
    fnComp = VarE $ mkName "."

--Unpack JSON into a tuple type
--We convert the JSON to a list
--We make a lambda expression which applies the UnFromJSON function to each element of the tuple
pureJsonType t
  | isTupleType t = do
      let tList = tupleTypeToList t
      let n = length tList
      --Generate the lambda to convert the list into a tuple
      subFunList <- mapM pureJsonType tList
      argNames <- mapM (newName . ("x" ++) . show) [1 .. n]
      let argValues = map VarE argNames
      let argPat = TupP $ map VarP argNames
      --Get each tuple element as Json, then wrap them in a Json Array
      let listExp = AppE (VarE $ mkName "Json.Array") (ListE $ zipWith AppE subFunList argValues)
      return $ LamE [argPat] listExp      
  --Don't need special int case, that happens when actually boxing the Json
-----------------------------------------------------------------------

-- | Generate a giant sum type representing all of the types within this module
-- this allows us to use toJson and fromJson without having typeClasses
giantSumType :: [Dec] -> Q [Dec]
giantSumType allDecs = do
  let decs = filter isData allDecs
  let typeNames = map getTypeName decs ++  map mkName ["Int", "Float", "Bool", "String"] --TODO lists?
  
  ctorStrings <- mapM typeString typeNames
  let ctorNames = zip typeNames (map mkName ctorStrings)
  let nullCtor = NormalC (mkName $ sumTypePrefix ++ "_Null") []
  let listCtor = NormalC (mkName $ sumTypePrefix ++  "_List") [(NotStrict, AppT ListT (ConT $ mkName sumTypePrefix)) ]
  let ctors = map (\ (typeName, ctorName) -> NormalC ctorName [(NotStrict, ConT typeName)] ) ctorNames
  return [ DataD [] (mkName sumTypePrefix) [] (ctors ++ [nullCtor, listCtor]) [] ]
    where 
      getTypeName :: Dec -> Name
      getTypeName (DataD _ name _ _ _ ) = name
      getTypeName (NewtypeD _ name _tyBindings  _ctor _nameList) = name