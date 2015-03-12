{-# LANGUAGE DeriveFunctor #-}
module Optimize.ControlFlow where

import           AST.Annotation             (Annotated (..))
import qualified AST.Expression.Canonical   as Canon
import           AST.Expression.General
import qualified AST.Module                 as Module
import qualified AST.Pattern                as Pattern
import           Control.Monad
import qualified Data.List                  as List
import qualified Data.Map as Map hiding ((!)) 
import qualified Data.Set                   as Set
import           Elm.Compiler.Module
import           Optimize.Traversals
import AST.Variable (home, Home(..))
import qualified AST.Variable as Var

import qualified AST.Variable as Variable

import           Optimize.Environment
import           Optimize.MonotoneFramework
import           Optimize.Types

import Debug.Trace (trace)

import qualified AST.Type as Type

--Type for variables or some "special cases"
data VarPlus =
  NormalVar Var Label
  | IntermedExpr Label
  | FormalReturn Var
  | ActualParam Label
  | FormalParam Pattern Label
    deriving (Eq, Ord, Show)
--TODO how to make sure all our IntermedExprs are there?

--Our different types of control nodes
data ControlNode' expr =
  Branch (expr)
  | Assign VarPlus (expr)
  | AssignParam VarPlus VarPlus (expr)
  | Call (expr) 
  | Return Var (expr) --TODO assign to what?
  | ProcEntry (expr)
  | ProcExit (expr)
  | ExprEval (expr)
  | GlobalEntry --Always the first node
  | GlobalExit --Always the last node
    deriving (Functor, Eq, Ord, Show)


getNodeLabel :: (LabelNode) -> Label
getNodeLabel (Branch n) = n
getNodeLabel (Assign _ n2) = n2
getNodeLabel (Call n) = n
getNodeLabel (Return _ n2) = n2
getNodeLabel (ProcEntry n) = n
getNodeLabel (ProcExit n) = n
getNodeLabel _ = Label 0


mapGet :: (Ord k, Show k, Show a) => Map.Map k a -> k -> a
mapGet m k = case Map.lookup k m of
  Nothing -> error $ "Couldn't find key " ++ (show k) ++ " in map " ++ (show $ Map.toList m )
  Just e -> e

data FunctionInfo =
  FunctionInfo
  {
    arity :: Int,
    formalParams :: [VarPlus],
    entryNode :: ControlNode,
    exitNode :: ControlNode,
    topFnLabel :: Maybe Label
  } -- deriving (Eq, Ord, Show)


type ControlNode = ControlNode' LabeledExpr
type LabelNode = ControlNode' Label

type ControlEdge = (ControlNode, ControlNode)



--getLabel :: LabeledExpr -> Label
--getLabel (A (_,l,_) _) = l


--For a fuction parameter, we treat each tail-position expression in the parameter
--As an assignment to the actual value of that parameter
paramNodes :: [LabeledExpr] -> [[ControlNode]]
paramNodes = map (\ arg ->
                         map (\tailExpr ->
                           Assign (ActualParam $ getLabel arg) tailExpr ) $ tailExprs arg)


tailExprs :: LabeledExpr -> [LabeledExpr]
tailExprs wholeExp@(A _ e) = tailExprs' e
  where
    tailExprs' (MultiIf guardBodies) = concatMap tailExprs $ map snd guardBodies
    tailExprs' (Case e cases) = concatMap tailExprs $ map snd cases
    tailExprs' (Let defs body) = tailExprs body
    tailExprs' e = [wholeExp] --All other cases, the expression itself is the returned value, no control flow

tailAssign :: Label ->  LabeledExpr -> ControlNode
tailAssign label tailExpr = Assign (IntermedExpr label) tailExpr

binOpToFn :: LabeledExpr -> LabeledExpr
binOpToFn (A ann (Binop op _ _)) = A ann $ Var op

connectLists :: ([ControlNode], [ControlNode]) -> [ControlEdge]
connectLists (l1, l2) = [(n1, n2) | n1 <- l1, n2 <- l2]



--Used in a foldE to generate statements/control nodes for expressions that need one
--Later we'll go in and add control edges
oneLevelEdges
  :: Map.Map Var FunctionInfo
  -> LabeledExpr
  -> [Maybe (
     Map.Map Label [ControlNode]
    ,Map.Map Label [ControlNode]--Entry and exit node for sub exps
    --,[ControlNode]
    ,[ControlEdge]) ]
  -> Maybe (
     Map.Map Label [ControlNode]
    ,Map.Map Label [ControlNode]--Entry and exit node for sub exps
    --,[ControlNode]
    ,[ControlEdge])
oneLevelEdges fnInfo e@(A (_, label, env) expr) maybeSubInfo = do
  (headMaps, tailMaps, {-subNodesL,-} subEdgesL) <- List.unzip3 `fmap` mapM id maybeSubInfo --Edges and nodes from our sub-expressions
  --let subNodes = concat subNodesL
  let headMap = Map.unions headMaps
  let tailMap = Map.unions tailMaps
  let subEdges = concat subEdgesL
  case expr of
    --Function: we have call and return for the call, and evaluating each arg is a mock assignment
    App e1 _ -> do
      fnName <- functionName e1
      argList <- argsGiven e
      let numArgs = length argList
      thisFunInfo <- Map.lookup fnName fnInfo 
      let fnArity = arity thisFunInfo
      let inLocalScope = trace "Env look 1" $ case (Map.lookup fnName env) of
            Nothing -> False
            Just fnLab -> (Just fnLab) == (topFnLabel thisFunInfo)
      let argNodes = paramNodes argList
      let callNode = Call e
      let retNode = Return fnName e
      --Generate assignment nodes for the actual parameters to the formals
      let assignFormalNodes =
            map (\(formal, arg) -> Assign formal arg) $ zip (formalParams thisFunInfo) argList
      --Control edges to generate
      let firstHead = (headMap `mapGet` (getLabel $ head argList))
      let otherHeads = map (\arg -> headMap `mapGet` (getLabel $ arg) ) $ tail argList
      let tailLists = map (\arg -> tailMap `mapGet` (getLabel $ arg) )  argList
      --let (otherTails, lastTail) = (init tailLists, last tailLists)
      let assignParamEdges = concatMap connectLists $ zip tailLists argNodes
      let calcNextParamEdges = concatMap connectLists $ zip (init argNodes) otherHeads
      let gotoFormalEdges = connectLists ((last argNodes), [head assignFormalNodes])

      let assignFormalEdges = zip (init assignFormalNodes) (tail assignFormalNodes)
      let callEdges = [(last assignFormalNodes, callNode ),
                      (callNode, entryNode thisFunInfo)]

      --TODO separate labels for call and return?
      let ourTail = AssignParam (IntermedExpr label) (FormalReturn fnName)  e
      let returnEdges =
            [ (exitNode thisFunInfo, retNode)
              ,(retNode, ourTail)
            ]
            --TODO add edges to function entry, assigning formals
      --TODO check for shadowing?
      case (fnArity == numArgs, inLocalScope) of
        (True, False) -> return $
                        (Map.insert (getLabel e) firstHead headMap,
                         Map.insert (getLabel e) [ourTail] tailMap,
                          --[callNode, retNode] ++ (concat argNodes),
                         assignParamEdges ++ calcNextParamEdges ++ assignFormalEdges ++
                           gotoFormalEdges ++ callEdges ++
                           callEdges ++ returnEdges ++ subEdges  ) --TODO app edges
          
        _ -> trace ("@@@@@@@@@@ HOF or partial app" ++ (show fnArity) ++ " " ++ (show numArgs) ++ " " ++ show inLocalScope ) $
          Nothing --If function is locally defined, or not fully instantiated, we fail
    Lambda _ _ -> trace "@@@@@@@@@@ Tried to create lambda" $ Nothing
    Binop op e1 e2 -> case (isArith op) of
      True -> return (Map.insert (getLabel e) (headMap `mapGet` (getLabel e1)) headMap  
                        , Map.insert (getLabel e) (tailMap `mapGet` (getLabel e2)) headMap
                          ,subEdges ) --Arithmetic doesn't need its own statements, since we can do inline
      False -> oneLevelEdges fnInfo (binOpToFn e) maybeSubInfo
    --Data _ args -> paramNodes args --Ctor is a constant, so just evaluate the arguments
    MultiIf condCasePairs -> do
      --We treat each case of the if expression as an assignment to the final value
      --of the if expression
      let guards = (map fst condCasePairs) 
      let bodies = map snd condCasePairs
      let bodyTails = concatMap tailExprs bodies
      --let guardNodes = map Branch guards
      let bodyNodes = map (tailAssign $ getLabel e) bodyTails
      --Each guard is connected to the next guard, and the "head" control node of its body
      let ourHead = headMap `mapGet` (getLabel $ head guards)
      let otherHeads = map (\arg -> headMap `mapGet` (getLabel $ arg) ) (tail guards)
      let guardEnds = map (\arg -> tailMap `mapGet` (getLabel $ arg) ) guards
      let notLastGuardEnds = init guardEnds
      let bodyHeads = map (\arg -> headMap `mapGet` (getLabel $ arg) ) bodies

      let guardFallthroughEdges = concatMap connectLists $ zip notLastGuardEnds otherHeads
      let guardBodyEdges = concatMap connectLists $ zip guardEnds bodyHeads

      let ourTail = [(Assign (IntermedExpr (getLabel e)) body) | body <- bodies]
      let endEdges = connectLists (bodyNodes, ourTail)
      
      return (
        Map.insert (getLabel e) ourHead headMap --First statement is eval first guard
         ,Map.insert (getLabel e) ourTail tailMap --Last statements are any tail exps of bodies
        --,guardNodes ++ bodyNodes ++ subNodes
         ,subEdges ++ guardBodyEdges ++ guardFallthroughEdges  ++ endEdges)
    Case caseExpr patCasePairs -> do
      --We treat each case of the case expression as an assignment to the final value
      --of the case expression
      --Those assignments correspond to the expressions in tail-position of the case
      let cases = map snd patCasePairs
      let caseTailExprs = concatMap tailExprs cases 
      let caseTails =  map (\tailExpr -> Assign (IntermedExpr $ getLabel e) tailExpr ) caseTailExprs
            
      let branchNode = Branch e
      --let ourHead = case (headMap `mapGet` (getLabel caseExpr)) of
      --      [] -> [Assign (IntermedExpr $ getLabel caseExpr) caseExpr]
      --      headList -> headList
      let ourHead = headMap `mapGet` (getLabel caseExpr)
      let ourTail = [Assign (IntermedExpr (getLabel e)) theCase | theCase <- caseTailExprs]
            
      let caseHeads = trace ("####### Got Case Tails " ++ show caseTails ) $concatMap (\cs -> headMap `mapGet` (getLabel cs) ) cases
      let branchEdges = trace ("####### Got Case heads " ++ show caseHeads ) $ connectLists (ourHead, [branchNode])
      let caseEdges =  connectLists ([branchNode], caseHeads)

      let endEdges = connectLists (caseTails, ourTail)
      
      return $ (Map.insert (getLabel e) ourHead headMap
        ,Map.insert (getLabel e) ourTail tailMap --Last thing is tail statement of whichever case we take
        --,[Assign (IntermedExpr $ getLabel caseExpr) caseExpr] ++ caseNodes ++ subNodes
         ,subEdges ++ caseEdges ++ endEdges ++ branchEdges)
    Let defs body -> do
      --We treat the body of a let statement as an assignment to the final value of
      --the let statement
      --Those assignments correspond to the expressions in tail-position of the body
      let orderedDefs = defs --TODO sort these
      let getDefAssigns (GenericDef pat b _) = trace "DefAssigns" $ concatMap (varAssign label pat) $ tailExprs b
      let defAssigns = map getDefAssigns orderedDefs
      --let bodyAssigns = map (tailAssign $ getLabel e) $ tailExprs body

      let (ourHead:otherHeads) = map (\(GenericDef _ b _) -> headMap `mapGet` (getLabel b)) orderedDefs

      let lastDefs = map  (\defList->[last defList] ) defAssigns
      let firstDefs = map (\defList->[head defList] ) defAssigns
            
      --let ourHead = case (head allHeads) of
      --      [] -> head defAssigns
      --      headList -> headList
      --let otherHeads = tail allHeads
      --TODO separate variables?

      let bodyHead = headMap `mapGet` (getLabel body)
      let tailLists = map (tailMap `mapGet`) $ map (\(GenericDef _ rhs _) -> getLabel rhs) orderedDefs

      let bodyTail = tailMap `mapGet` (getLabel body)
      let ourTail = [Assign (IntermedExpr (getLabel e)) body]
      
      let betweenDefEdges =
            concatMap connectLists $ zip lastDefs (otherHeads ++ [bodyHead])
      let tailToDefEdges = concatMap connectLists $ zip tailLists firstDefs
      let interDefEdges =
            [(d1, d2) | defList <- defAssigns, d1 <- (init defList), d2 <- (tail defList)]
      let assignExprEdges = connectLists (bodyTail, ourTail)
          
      --TODO need intermediate?
      
      return $ (Map.insert (getLabel e) ourHead headMap
                ,Map.insert (getLabel e) ourTail tailMap
                --,defAssigns ++ bodyAssigns ++ subNodes
                ,subEdges ++ betweenDefEdges 
                 ++ tailToDefEdges ++ interDefEdges ++ assignExprEdges)
        
    _ -> (trace "Fallthrough" ) $ case (headMaps) of
      [] -> (trace "Leaf case" ) $ do
        let ourHead = [ExprEval e]
        let ourTail = ourHead
        return (Map.insert (getLabel e) ourHead headMap,
                Map.insert (getLabel e) ourTail tailMap,
                subEdges) --Means we are a leaf node, no sub-expressions
      _ -> (trace "In fallthrough version of getEdges" ) $ do
        let headLists = Map.elems headMap
        let tailLists = Map.elems tailMap
        let (ourHead:otherHeads) = headLists
        let otherTails = init tailLists
        let ourTail = last tailLists
        let subExpEdges = concatMap connectLists $ zip otherTails otherHeads
        return (Map.insert (getLabel e) ourHead headMap
              , Map.insert (getLabel e) ourTail tailMap
               --, subNodes
               , subEdges ++ subExpEdges)
        --Other cases don't generate control nodes for one-level analysis
        --For control flow, we just calculate each sub-expression in sequence
        --We connect the end nodes of each sub-expression to the first of the next


allExprEdges
  :: Map.Map Var FunctionInfo
  -> (LabeledExpr, Type.CanonicalType)
  -> Maybe (
    Map.Map Label [ControlNode],
    Map.Map Label [ControlNode],
    [(ControlNode, ControlNode)] )
allExprEdges fnInfo (body, ty) =
  if (isStateMonadFn ty)
  then monadicDefEdges fnInfo body
  else allExprEdgesNonMonadic fnInfo body

allExprEdgesNonMonadic
  :: Map.Map Var FunctionInfo
  -> LabeledExpr
  -> Maybe (
    Map.Map Label [ControlNode],
    Map.Map Label [ControlNode],
    [(ControlNode, ControlNode)] )
allExprEdgesNonMonadic fnInfo e = foldE
           (\ _ () -> repeat ())
           ()
           (\(GenericDef _ e v) -> [e])
           (\ _ e subs-> oneLevelEdges fnInfo e subs)
           e

nameToCanonVar :: String -> Var
nameToCanonVar name = Variable.Canonical  Variable.Local name

functionDefEdges
  :: (Map.Map Label [ControlNode]
    ,Map.Map Label [ControlNode])
  -> LabelDef
  -> Maybe [ControlEdge]
functionDefEdges (headMap, tailMap) (GenericDef (Pattern.Var name) e@(A (_,label,_) _) _ty ) = trace "Getting Function Edges " $ do
  let body = functionBody e
  let argPats = (functionArgPats e)
  let argLabels = (functionArgLabels e)
  let argPatLabels = zip argPats argLabels
  let argVars = concatMap getPatternVars argPats 
  let ourHead = ProcEntry e
  let ourTail = [ProcExit e]
  let bodyTails = tailExprs body
  let tailNodes = concatMap (\e -> tailMap `mapGet` (getLabel e) ) bodyTails 
  let assignReturns = [Assign (FormalReturn (nameToCanonVar name) ) body]
  let assignParams =
        [(AssignParam (FormalParam pat label) (NormalVar v argLab) body) |
           (pat,argLab) <- argPatLabels, v <- argVars]
  let startEdges = [(ourHead, head assignParams )]
  let assignFormalEdges = zip (init assignParams) (tail assignParams)
  let assignReturnEdges = connectLists (tailNodes, assignReturns)
  let fnExitEdges = connectLists (assignReturns, ourTail)
  let gotoBodyEdges = connectLists ([last assignParams], headMap `mapGet` (getLabel body))
  
  return $ startEdges ++ assignFormalEdges ++ assignReturnEdges ++ fnExitEdges ++ gotoBodyEdges

--Given a monadic expression, break it up into statements
--And calculate the edges between those statements in our CFG
--TODO self recursion
--TODO nested state monads?
monadicDefEdges
  :: Map.Map Var FunctionInfo
  -> LabeledExpr
  -> Maybe (
    Map.Map Label [ControlNode],
    Map.Map Label [ControlNode],
    [(ControlNode, ControlNode)] )
monadicDefEdges fnInfo e@(A _ expr) = do
  let (firstStmt, patternStmts) = sequenceMonadic e
  let otherStmts = (map snd patternStmts) :: [LabeledExpr]
  statementInfoTail <- forM otherStmts (allExprEdgesNonMonadic fnInfo)
  statementInfoHead <- allExprEdgesNonMonadic fnInfo firstStmt
  let patLabels = (map fst patternStmts)
  let statementInfo = (statementInfoHead:statementInfoTail)
  let zippedInfo = zip (firstStmt:(map snd patternStmts)) statementInfo
  let linkStatementEdges ((pat,andThenExpr), info1, info2) = do
        let (s1, (headMap1, tailMap1, _)) = info1
        let (s2, (headMap2, tailMap2, _)) = info2
        let s1Tail = tailMap1 `mapGet` (getLabel s1)
        let s2Head = headMap2 `mapGet` (getLabel s2)
        let assignParamNode = AssignParam (FormalParam pat (getLabel s2)) (IntermedExpr (getLabel s1)) andThenExpr
        return $  (connectLists (s1Tail, [assignParamNode] )) ++ (connectLists ([assignParamNode], s2Head))
  let edgeTriples =  (zip3 patLabels (tail zippedInfo) (init zippedInfo))
  let betweenStatementEdges = concatMap linkStatementEdges edgeTriples
  let combinedHeads = Map.unions $ map (\(hmap,_,_) -> hmap) statementInfo
  let combinedTails = Map.unions $ map (\(_, tmap, _) -> tmap) statementInfo
  let newHeads =
        Map.insert (getLabel e) (combinedHeads `mapGet` (getLabel firstStmt)) combinedHeads
  let newTails =
        Map.insert (getLabel e) (combinedTails `mapGet` (getLabel $ last otherStmts ) ) combinedTails
  return $ (newHeads,
           newTails,
           concat betweenStatementEdges
             ++ concatMap (\(_,_,edges) -> edges) statementInfo)
  
    
varAssign :: Label -> Pattern -> LabeledExpr -> [ControlNode]
varAssign defLabel pat e = [Assign (NormalVar pvar defLabel  ) e |
                   pvar <- getPatternVars pat]


functionName :: LabeledExpr -> Maybe Var
functionName (A _ e) = case e of
  Var v -> Just v
  (App f _ ) -> functionName f
  _ -> Nothing

functionBody :: LabeledExpr -> LabeledExpr
functionBody (A _ (Lambda _ e)) = functionBody e
functionBody e = e

functionLabel (GenericDef _ body _) = case functionBody body of
  (A (_, label, _) _) -> label

functionArgPats :: LabeledExpr -> [Pattern]
functionArgPats (A _ (Lambda pat e)) = [pat] ++ (functionArgPats e)
functionArgPats _ = []

functionArgLabels :: LabeledExpr -> [Label]
functionArgLabels (A (_,l,_) (Lambda pat e)) = [l] ++ (functionArgLabels e)
functionArgLabels _ = []

--Get the "final" return type of a function type
--i.e. what's returned if it is fully applied
functionFinalReturnType :: Type.CanonicalType -> Type.CanonicalType
functionFinalReturnType (Type.Lambda _ ret) = functionFinalReturnType ret
functionFinalReturnType t = t

--Our special State monad for imperative code                           
stateMonadTycon = Type.Var ("EState")

--Check if a function is "monadic" for our state monad
isStateMonadFn :: Type.CanonicalType -> Bool
isStateMonadFn ty =  case (functionFinalReturnType ty) of
  (Type.App tyCon _) -> tyCon == stateMonadTycon
  _ -> False

--Given a monadic function, sequence it into a series of "statements"
--Based on the `andThen` bind operator, used in infix position
sequenceMonadic :: LabeledExpr -> (LabeledExpr, [( (Pattern, LabeledExpr), LabeledExpr)])
sequenceMonadic e@(A _ (Binop op e1 (A _ (Lambda pat body)) )) = case (Var.name op) of
  "andThen" -> let
      (bodyHead,bodySeq) = sequenceMonadic body
    in (e1, ( (pat, e ), bodyHead):bodySeq)
  _ -> (e,[])
sequenceMonadic e = (e,[])

--TODO make TailRecursive

getArity :: LabeledExpr -> Int
getArity (A _ (Lambda _ e)) = 1 + (getArity e)
getArity e = 0

argsGiven :: LabeledExpr -> Maybe [LabeledExpr]
argsGiven (A _ e) = case e of
  Var v -> Just []
  (App f e ) -> ([e]++) `fmap` argsGiven f
  _ -> Nothing





isArith :: Var -> Bool
isArith = (`elem` arithVars )

arithVars = [
  Variable.Canonical (Variable.Module ["Basics"]) "+"
  ,Variable.Canonical (Variable.Module ["Basics"]) "-"
  ,Variable.Canonical (Variable.Module ["Basics"]) "*"
  ,Variable.Canonical (Variable.Module ["Basics"]) "/"
  ,Variable.Canonical (Variable.Module ["Basics"]) "&&"
  ,Variable.Canonical (Variable.Module ["Basics"]) "||"
  ,Variable.Canonical (Variable.Module ["Basics"]) "^"
  ,Variable.Canonical (Variable.Module ["Basics"]) "//"
  ,Variable.Canonical (Variable.Module ["Basics"]) "rem"
  ,Variable.Canonical (Variable.Module ["Basics"]) "%"
  ,Variable.Canonical (Variable.Module ["Basics"]) "<"
  ,Variable.Canonical (Variable.Module ["Basics"]) ">"
  ,Variable.Canonical (Variable.Module ["Basics"]) "<="
  ,Variable.Canonical (Variable.Module ["Basics"]) ">="
  ,Variable.Canonical (Variable.Module ["Basics"]) "=="
  ,Variable.Canonical (Variable.Module ["Basics"]) "/="
            ]