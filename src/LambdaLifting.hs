{-# language OverloadedStrings #-}

module LambdaLifting where

import Protolude hiding (Type, IntSet, evaluate)

import Data.Graph (SCC(AcyclicSCC))
import Data.HashMap.Lazy (HashMap)

import Binding (Binding)
import qualified Binding
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Environment as Environment
import Extra (topoSortWith)
import qualified Index
import Monad
import qualified Name
import Plicity
import qualified Scope
import qualified Syntax
import qualified Syntax.LambdaLifted as LambdaLifted
import Syntax.Telescope (Telescope)
import qualified Syntax.Telescope as Telescope
import Var (Var)
import qualified Var

data Value = Value !InnerValue Occurrences
  deriving Show

data InnerValue
  = Var !Var
  | Global !Name.Lifted
  | Con !Name.QualifiedConstructor
  | Let !Binding !Var !Value !Type !Value
  | Pi !Binding !Var !Type !Plicity !Type
  | Fun !Type !Plicity !Type
  | App !Value !Plicity !Value
  | Case !Value !Branches !(Maybe Value)
  deriving Show

type Type = Value

type Branches = HashMap Name.QualifiedConstructor ([(Binding, Var, Type, Plicity)], Value)

type Occurrences = IntSet Var

occurrences :: Value -> Occurrences
occurrences (Value _ occs) =
  occs

makeVar :: Environment v -> Var -> Value
makeVar env var =
  Value (Var var) $
    IntSet.singleton var <>
    foldMap occurrences (Environment.lookupVarValue var env)

makeGlobal :: Name.Lifted -> Value
makeGlobal global =
  Value (Global global) mempty

makeCon :: Name.QualifiedConstructor -> Value
makeCon con =
  Value (Con con) mempty

makeLet :: Binding -> Var -> Value -> Type -> Value -> Value
makeLet binding var value type_ body =
  Value (Let binding var value type_ body) $
    occurrences value <>
    occurrences type_ <>
    IntSet.delete var (occurrences body)

makePi :: Binding -> Var -> Type -> Plicity -> Value -> Value
makePi name var domain plicity target =
  Value (Pi name var domain plicity target) $
    occurrences domain <>
    IntSet.delete var (occurrences target)

makeFun :: Value -> Plicity -> Value -> Value
makeFun domain plicity target =
  Value (Fun domain plicity target) $
    occurrences domain <>
    occurrences target

makeApp :: Value -> Plicity -> Value -> Value
makeApp fun plicity arg =
  Value (App fun plicity arg) $
    occurrences fun <>
    occurrences arg

makeApps :: Foldable f => Value -> f (Plicity, Value) -> Value
makeApps =
  foldl (\fun (plicity, arg) -> makeApp fun plicity arg)

makeCase :: Value -> Branches -> Maybe Value -> Value
makeCase scrutinee branches defaultBranch =
  Value (Case scrutinee branches defaultBranch) $
    occurrences scrutinee <>
    foldMap (uncurry telescopeOccurrences) branches <>
    foldMap occurrences defaultBranch

telescopeOccurrences :: [(Binding, Var, Type, Plicity)] -> Value -> Occurrences
telescopeOccurrences tele body =
  case tele of
    [] ->
      occurrences body

    (_, var, type_, _):tele' ->
      occurrences type_ <>
      IntSet.delete var (telescopeOccurrences tele' body)

-------------------------------------------------------------------------------

data LiftState = LiftState
  { _nextIndex :: !Int
  , _liftedDefinitions :: [(Name.Lifted, Telescope LambdaLifted.Type LambdaLifted.Term Void)]
  } deriving Show

emptyState :: LiftState
emptyState =
  LiftState
    { _nextIndex = 1
    , _liftedDefinitions = mempty
    }

type Lift = StateT LiftState M

type Environment = Environment.Environment Value

extend :: Environment v -> Type -> Lift (Environment (Index.Succ v), Var)
extend env type_ =
  lift $ Environment.extendValue env type_

-------------------------------------------------------------------------------

evaluate :: Environment v -> Syntax.Term v -> Lift Value
evaluate env term =
  case term of
    Syntax.Var index ->
      pure $ makeVar env $ Environment.lookupIndexVar index env

    Syntax.Global global ->
      pure $ makeGlobal $ Name.Lifted global 0

    Syntax.Con con ->
      pure $ makeCon con

    Syntax.Meta _ ->
      panic "LambdaLifting.evaluate meta"

    Syntax.Let name value type_ body -> do
      type' <- evaluate env type_
      (env', var) <- extend env type'
      makeLet name var <$>
        evaluate env value <*>
        pure type' <*>
        evaluate env' body

    Syntax.Pi name domain plicity target -> do
      domain' <- evaluate env domain
      (env', var) <- extend env domain'
      makePi name var domain' <$>
        pure plicity <*>
        evaluate env' target

    Syntax.Fun domain plicity target ->
      makeFun <$>
        evaluate env domain <*>
        pure plicity <*>
        evaluate env target

    Syntax.Lam {} -> do
      (argVars, def) <- liftLambda env term
      i <- gets _nextIndex

      let
        Scope.KeyedName _ name =
          Environment.scopeKey env

        liftedName =
          Name.Lifted name i

      modify $ \s -> s
        { _nextIndex = i + 1
        , _liftedDefinitions = (liftedName, def) : _liftedDefinitions s
        }
      pure $ makeApps (makeGlobal $ Name.Lifted name i) $ (,) Explicit . makeVar env <$> argVars

    Syntax.App function plicity argument ->
      makeApp <$>
        evaluate env function <*>
        pure plicity <*>
        evaluate env argument

    Syntax.Case scrutinee branches defaultBranch ->
      makeCase <$>
        evaluate env scrutinee <*>
        mapM (evaluateBranch env . snd) branches <*>
        mapM (evaluate env) defaultBranch

    Syntax.Spanned _ term' ->
      evaluate env term'

evaluateBranch
  :: Environment v
  -> Telescope Syntax.Type Syntax.Term v
  -> Lift ([(Binding, Var, Type, Plicity)], Value)
evaluateBranch env tele =
  case tele of
    Telescope.Empty body -> do
      body' <- evaluate env body
      pure ([], body')

    Telescope.Extend name type_ plicity tele' -> do
      type' <- evaluate env type_
      (env', var) <- extend env type'
      (bindings, body) <- evaluateBranch env' tele'
      pure ((name, var, type', plicity):bindings, body)

liftLambda
  :: Environment v
  -> Syntax.Term v
  -> Lift ([Var], Telescope LambdaLifted.Type LambdaLifted.Term Void)
liftLambda env term = do
  (tele, body) <- evaluateLambdaTelescope env term

  let
    occs =
      telescopeOccurrences tele body

    sortedOccs =
      fmap acyclic $
        topoSortWith
          identity
          (\var -> IntSet.toList $ foldMap occurrences $ Environment.lookupVarValue var env)
          (IntSet.toList occs)

    occurrenceTele =
      [ (Binding.Unspanned "x", var, type_, Explicit)
      | var <- sortedOccs
      , let
          type_ =
            fromMaybe (panic "liftLambda no type") $ Environment.lookupVarValue var env
      ]

    emptyEnv =
      Environment.empty $ Environment.scopeKey env

  pure (sortedOccs, readbackTelescope emptyEnv (occurrenceTele <> tele) body)
  where
    acyclic :: SCC a -> a
    acyclic (AcyclicSCC a) = a
    acyclic _ = panic "liftLambda cyclic"

evaluateLambdaTelescope :: Environment v -> Syntax.Term v -> Lift ([(Binding, Var, Type, Plicity)], Value)
evaluateLambdaTelescope env term =
  case term of
    Syntax.Lam name type_ plicity body -> do
      type' <- evaluate env type_
      (env', var) <- extend env type'
      (tele, body') <- evaluateLambdaTelescope env' body
      pure ((name, var, type', plicity):tele, body')

    _ -> do
      term' <- evaluate env term
      pure ([], term')

-------------------------------------------------------------------------------

readback :: Environment v -> Value -> LambdaLifted.Term v
readback env (Value value _) =
  case value of
    Var var ->
      LambdaLifted.Var $
        fromMaybe (panic "LambdaLifting.readback Var") $
          Environment.lookupVarIndex var env

    Global global ->
      LambdaLifted.Global global

    Con global ->
      LambdaLifted.Con global

    Let name var value' type_ body ->
      LambdaLifted.Let
        name
        (readback env value')
        (readback env type_)
        (readback (Environment.extendVar env var) body)

    Pi name var domain plicity target ->
      LambdaLifted.Pi
        name
        (readback env domain)
        plicity
        (readback (Environment.extendVar env var) target)

    Fun domain plicity target ->
      LambdaLifted.Fun (readback env domain) plicity (readback env target)

    App function plicity argument ->
      LambdaLifted.App (readback env function) plicity (readback env argument)

    Case scrutinee branches defaultBranch ->
      LambdaLifted.Case
        (readback env scrutinee)
        (map (uncurry (readbackTelescope env)) branches)
        (readback env <$> defaultBranch)

readbackTelescope
  :: Environment v
  -> [(Binding, Var, Type, Plicity)]
  -> Value
  -> Telescope LambdaLifted.Type LambdaLifted.Term v
readbackTelescope env bindings body =
  case bindings of
    [] ->
      Telescope.Empty $ readback env body

    (name, var, type_, plicity):bindings' -> do
      let
        env' =
          Environment.extendVar env var
      Telescope.Extend name (readback env type_) plicity (readbackTelescope env' bindings' body)
