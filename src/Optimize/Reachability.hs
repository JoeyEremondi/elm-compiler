module Optimize.Reachability (removeUnreachable, removeUnreachableModule, reachabilityMap) where

import Optimize.MonotoneFramework

import Elm.Compiler.Module
import qualified AST.Module as Module
import qualified Data.Map as Map hiding ((!))
import AST.Expression.General
import qualified AST.Expression.Canonical as Canon
import AST.Annotation
import Optimize.Environment
import AST.Variable as Var
import Optimize.Traversals

import Optimize.Types

import Debug.Trace (trace)

newtype IsReachable = IsReachable {fromReachable :: Bool}
  deriving (Eq, Ord, Show)

mapGet m k = case (Map.lookup k m) of
  Just e -> e
  Nothing -> error $ "Couldn't find elem " ++ show k ++ " in map " ++ show m

reachingJoin :: IsReachable -> IsReachable -> IsReachable
reachingJoin a b = IsReachable (fromReachable a || fromReachable b )

{-|
A simple reachability test.
When we use this lattice, our worklist algorithm basically
becomes a depth-first search on a graph,
returning a boolean for each label for whether it is reachable
from our initial extremal values
|-}
isReachableLattice :: Lattice IsReachable
--instance Lattice IsReachable where
isReachableLattice = Lattice {
  latticeBottom = IsReachable False,
  latticeJoin = reachingJoin,
  iota = IsReachable True,
  lleq = \a b -> (reachingJoin a b) == b,
  flowDirection = ForwardAnalysis
  }

topLevelDefs :: Name -> Canon.Expr -> [(Var.Canonical,Canon.Expr)]
topLevelDefs name (A _ (Let defs _))=
  concatMap (\(Canon.Definition p body _) -> map (\v -> (addContext name v, body)) $ getPatternVars p ) defs
topLevelDefs _ _ = [] --TODO, causes problems?

defVars :: Canon.Def -> [Var.Canonical]
defVars (Canon.Definition p _ _) = getPatternVars p

oneLevelVars :: Env () -> Canon.Expr  -> [[Var.Canonical]] -> [Var.Canonical]
oneLevelVars env (A _ (Var v)) vars = [v] ++ (concat vars)
oneLevelVars _ _ vars = concat vars

referencedTopLevels :: (Env ()) -> Canon.Expr -> [Var.Canonical]
referencedTopLevels env exp = foldE
                              (extendEnv defVars (\_ -> ()))
                              env
                              (\(Canon.Definition _ exp _) -> [exp])
                              oneLevelVars
                              exp

--TODO forward or backward?
makeProgramInfo :: [Name] -> [(Name, Module)] -> ProgramInfo Var.Canonical
makeProgramInfo targets mods = ProgramInfo (eMap) allLabs labPairs isExtr
  where
    targetVars = map nameToVar targets
    eMap  = \var -> referencedTopLevels (Map.empty) (allLabelsMap `mapGet` var)
    allLabelBodies = concatMap (\(name, mod) -> topLevelDefs name $ Module.program $ Module.body mod) mods
    allLabelsMap = Map.fromList allLabelBodies
    allLabs = map fst allLabelBodies
    labPairs = [(l,l') | l <- allLabs, l' <- eMap l, l' `elem` allLabs] --Ignore external calls, if they're not defined, allows us to do single-module analysis
    --TODO bad design?
    isExtr var = var `elem` targetVars

transferFun :: Map.Map Var.Canonical IsReachable -> Var.Canonical -> IsReachable -> IsReachable
transferFun _ _ r = r

findReachable :: [Name] -> [(Name, Module)] -> Map.Map Var.Canonical IsReachable
findReachable targets mods = snd $ minFP isReachableLattice transferFun
                             $ makeProgramInfo targets mods

reachabilityMap :: [Name] -> [(Name, Module)] -> Map.Map Var.Canonical Bool
reachabilityMap names mods = Map.map (fromReachable) $ findReachable names mods

--A variable can stay if it's not a TLD, or if it is reachable
canStay :: Name -> Map.Map Var.Canonical IsReachable -> Canon.Def -> Bool
canStay name reachMap (Canon.Definition pat _ _) = trace "canStay " $
                          let
                            varCanStay var = case Map.lookup var reachMap of
                              Nothing -> True
                              Just (IsReachable False) -> False
                              Just (IsReachable True) -> True
                          in or $ map varCanStay (map (addContext name) $ getPatternVars pat)

--Remove unreachable definitions from our top-level expression
fixDef :: Map.Map Var.Canonical IsReachable -> Name -> Canon.Expr -> Canon.Expr
fixDef reachMap name (A a (Let defs body)) = trace " Fixing def" $
  A a $ Let (filter (canStay name reachMap) defs) body
fixDef _ _ exp = exp

--TODO avoid recomputing?
removeUnreachable :: [Name] -> Map.Map Name (Module, Interface) -> Map.Map Name (Module, Interface)
removeUnreachable targets mods = trace "Remove Unreachable " $
  let
    --dictPairs = Map.toList mods
    inPairs = Map.toList $ Map.map fst mods
    reachMap = findReachable targets inPairs
    outPairs = map (\(name, mod) -> (name, (tformModule (fixDef reachMap name))  mod)) inPairs
    --outDict = Map.fromList outPairs
    ifaceDict = Map.map snd mods
    outWithIface = map (\(name, mod) -> (name, (mod, ifaceDict `mapGet` name) )) outPairs
  in Map.fromList outWithIface


removeUnreachableModule :: Name -> (Module, Interface) -> (Module, Interface)
removeUnreachableModule name@(Name nlist) modul =
  let
    varToValList v = case v of
      Var.Value s -> [Name $ nlist ++ [s]]
      _ -> []
    targets = concatMap varToValList $ Module.exports $ fst modul
    inMap = Map.fromList [(name, modul)]

  in snd $ head $ Map.toList $ removeUnreachable targets inMap

