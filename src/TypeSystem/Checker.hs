{-|
Module: TypeSystem.Checker
Description: A type checker for SPL
Copyright: (c) Thomas Churchman, 2017
License: MIT
Maintainer: thomas@kepow.org
Stability: experimental

A type checker based on Algorithm W.

See more here: http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.65.7733&rep=rep1&type=pdf (last retrieved
10 April 2017).
https://github.com/mgrabmueller/AlgorithmW

-}

module TypeSystem.Checker where

import qualified Data.Map as Map
import qualified Data.Set as Set

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State

import qualified Data.Pos as Pos
import qualified Data.AST as AST

------------------------------------------------------------------------------------------------------------------------

-- |Todo: implement main SPL checker
check :: AST.SPL -> Either Int Int
check spl = undefined

typeInferenceExpr :: Map.Map String Scheme -> AST.Expression -> TInf Type
typeInferenceExpr ctx e = do
    (s, t) <- tInfExpr (TypeCtx ctx) e
    return (apply s t)

------------------------------------------------------------------------------------------------------------------------

data Type = TVar String
          | TBool
          | TInt
          | TChar
          | TList Type
          | TTuple Type Type
          | TFunction Type Type
            deriving (Show, Eq, Ord)
data Scheme = Scheme [String] Type

------------------------------------------------------------------------------------------------------------------------

-- |Class to perform type inference and the like
class Types a where
    freeTypeVars :: a -> Set.Set String
    apply :: Substitution -> a -> a

instance Types Type where
    freeTypeVars (TVar v) = Set.singleton v
    freeTypeVars TBool = Set.empty
    freeTypeVars TInt = Set.empty
    freeTypeVars TChar = Set.empty
    freeTypeVars (TList l) = freeTypeVars l
    freeTypeVars (TTuple t1 t2) = Set.union (freeTypeVars t1) (freeTypeVars t2)
    freeTypeVars (TFunction arg body) = Set.union (freeTypeVars arg) (freeTypeVars body)

    apply s (TList l) = TList $ apply s l
    apply s (TTuple t1 t2) = TTuple (apply s t1) (apply s t2)
    apply s (TFunction arg body) = TFunction (apply s arg) (apply s body)
    apply s t = t

instance Types Scheme where
    freeTypeVars (Scheme vars t) = (freeTypeVars t) `Set.difference` (Set.fromList vars)
    apply s (Scheme vars t) = Scheme vars (apply (foldr Map.delete s vars) t)

instance Types a => Types [a] where
    freeTypeVars l = foldr Set.union Set.empty (map freeTypeVars l)
    apply s = map (apply s)

------------------------------------------------------------------------------------------------------------------------

-- |A substitution is a (finite) mapping from type variables to types
type Substitution = Map.Map String Type

nullSubstitution :: Substitution
nullSubstitution = Map.empty

composeSubstitution :: Substitution -> Substitution -> Substitution
composeSubstitution s1 s2 = (Map.map (apply s1) s2) `Map.union` s1

------------------------------------------------------------------------------------------------------------------------

-- |A type context (or environment) is a mapping from term variables to type schemes
newtype TypeCtx = TypeCtx (Map.Map String Scheme)

emptyCtx :: TypeCtx
emptyCtx = TypeCtx (Map.empty)

remove :: TypeCtx -> String -> TypeCtx
remove (TypeCtx ctx) var = TypeCtx (Map.delete var ctx)

instance Types TypeCtx where
    freeTypeVars (TypeCtx ctx) = freeTypeVars (Map.elems ctx)
    apply s (TypeCtx ctx) = TypeCtx (Map.map (apply s) ctx)

------------------------------------------------------------------------------------------------------------------------

-- |Abstract a type over all type variables free in the type but not free in the context
generalize :: TypeCtx -> Type -> Scheme
generalize ctx t =
    let vars = Set.toList ((freeTypeVars t) `Set.difference` (freeTypeVars ctx)) in
        Scheme vars t

------------------------------------------------------------------------------------------------------------------------

-- |Handle type initialization (such as generating fresh variable names for new type variables)
data TInfCtx = TInfCtx {}
data TInfState = TInfState { tInfSupply :: Int,
                             tInfSubst :: Substitution}

-- type TInf a = ExceptT String (ReaderT TInfCtx (StateT TInfState IO)) a
type TInf a = ExceptT String (ReaderT TInfCtx (State TInfState)) a

runTInf :: TInf a -> (Either String a, TInfState)
runTInf t = runState (runReaderT (runExceptT t) initTInfCtx) initTInfState
    where
        initTInfCtx = TInfCtx{}
        initTInfState = TInfState { tInfSupply = 0,
                                    tInfSubst = Map.empty}

------------------------------------------------------------------------------------------------------------------------

-- |Generate a new type var using the type name supplier
newTypeVar :: String -> TInf Type
newTypeVar prefix = do
    s <- get
    put s {tInfSupply = tInfSupply s + 1}
    return (TVar (prefix ++ show (tInfSupply s)))

-- |Replace bound type variables in a scheme with fresh type variables
instantiate :: Scheme -> TInf Type
instantiate (Scheme vars t) = do
    newVars <- mapM (\_ -> newTypeVar "a") vars
    let s = Map.fromList (zip vars newVars)
    return $ apply s t

------------------------------------------------------------------------------------------------------------------------

-- |Bind a type variable to a type, but don't bind to itself, and make sure the free type variable occurs
varBind :: String -> Type -> TInf Substitution
varBind u t
    | t == TVar u                   = return nullSubstitution
    | u `Set.member` freeTypeVars t = throwError $ "occurs check fails: " ++ u ++ " vs. " ++ show t
    | otherwise                     = return (Map.singleton u t)

-- |Unify two types (using the most general unifier)
mgu :: Type -> Type -> TInf Substitution
mgu (TFunction arg body) (TFunction arg' body') = do
    s1 <- mgu arg arg'
    s2 <- mgu (apply s1 body) (apply s1 body')
    return $ composeSubstitution s1 s2
mgu (TVar u) t  = varBind u t
mgu t (TVar u)  = varBind u t
mgu TInt TInt   = return nullSubstitution
mgu TBool TBool = return nullSubstitution
mgu t1 t2       = throwError $ "types do not unify: " ++ show t1 ++ " and " ++ show t2

------------------------------------------------------------------------------------------------------------------------

idName :: AST.Identifier -> String
idName (AST.Identifier i, _) = i

tInfConst :: TypeCtx -> AST.Constant -> TInf (Substitution, Type)
tInfConst _ (AST.ConstBool _, _) = return (nullSubstitution, TBool)
tInfConst _ (AST.ConstInt _, _) = return (nullSubstitution, TInt)
tInfConst _ (AST.ConstChar _, _) = return (nullSubstitution, TChar)
-- tInfCosnt _ (AST.ConstEmptyList, _) = return (nullSubstitution, TChar)

tInfExpr :: TypeCtx -> AST.Expression -> TInf (Substitution, Type)
tInfExpr (TypeCtx ctx) (AST.ExprIdentifier id, _) =
    let i = idName id in
        case Map.lookup i ctx of
            Nothing -> throwError $ "unbound variable: " ++ i
            Just s -> do
                t <- instantiate s
                return (nullSubstitution, t)
tInfExpr ctx (AST.ExprConstant const, _) = tInfConst ctx const

