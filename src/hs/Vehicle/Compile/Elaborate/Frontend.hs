{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Compile.Elaborate.Frontend
  ( runElab
  , runElabExpr
  ) where

import Control.Monad.Except (MonadError, throwError)
import Data.Bitraversable (bitraverse)
import Data.List.NonEmpty (NonEmpty(..))
import Data.List.NonEmpty qualified as NonEmpty (groupBy1, head, toList)

import Vehicle.Frontend.Abs qualified as B

import Vehicle.Prelude
import Vehicle.Compile.Error
import Vehicle.Language.AST qualified as V
import Vehicle.Language.Sugar

runElab :: MonadElab e m => B.Prog -> m V.InputProg
runElab = elab

runElabExpr :: MonadElab e m => B.Expr -> m V.InputExpr
runElabExpr = elab

--------------------------------------------------------------------------------
-- Conversion from BNFC AST
--
-- We elabert from the simple AST generated automatically by BNFC to our
-- more complicated internal version of the AST which allows us to annotate
-- terms with sort-dependent types.
--
-- While doing this we:
--  1. extract the positions from the tokens generated by BNFC and elaborate
--     them into `Provenance` annotations.
--  2. combine function types and expressions into a single AST node

-- | Constraint for the monad stack used by the elaborator.
type MonadElab e m =
  ( AsFrontendElabError e
  , MonadError e m
  , MonadLogger m
  )

-- * Provenance

mkAnn :: IsToken a => a -> V.InputAnn
mkAnn t = (tkProvenance t, V.TheUser)

-- * Elaboration

class Elab vf vc where
  elab :: MonadElab e m => vf -> m vc

instance Elab B.Prog V.InputProg where
  elab (B.Main decls) = V.Main <$> groupDecls decls

-- |Elaborate declarations.
instance Elab (NonEmpty B.Decl) V.InputDecl where
  elab = \case
    -- Elaborate a network declaration.
    (B.DeclNetw n _tk t :| []) -> V.DeclNetw (tkProvenance n) <$> elab n <*> elab t

    -- Elaborate a dataset declaration.
    (B.DeclData n _tk t :| []) -> V.DeclData (tkProvenance n) <$> elab n <*> elab t

    -- Elaborate a type definition.
    (B.DefType n bs e :| []) -> do
      unfoldDefType (mkAnn n) <$> elab n <*> traverse elab bs <*> elab e

    -- Elaborate a function definition.
    (B.DefFunType n1 _tk t  :| [B.DefFunExpr _n2 bs e]) ->
      unfoldDefFun (mkAnn n1) <$> elab n1 <*> elab t <*> traverse elab bs <*> elab e

    -- Why did you write the signature AFTER the function?
    (e1@B.DefFunExpr {} :| [e2@B.DefFunType {}]) ->
      elab (e2 :| [e1])

    -- Missing type or expression declaration.
    (B.DefFunType n _tk _t :| []) ->
      throwError $ mkMissingDefFunExpr (tkProvenance n) (tkSymbol n)

    (B.DefFunExpr n _ns _e :| []) ->
      throwError $ mkMissingDefFunType (tkProvenance n) (tkSymbol n)

    -- Multiple type of expression declarations with the same n.
    ds ->
      throwError $ mkDuplicateName provs symbol
        where
          symbol = tkSymbol $ declName $ NonEmpty.head ds
          provs  = fmap (tkProvenance . declName) ds

instance Elab B.Expr V.InputExpr where
  elab = \case
    B.Type l                  -> return $ V.Type (fromIntegral l)
    B.Var  n                  -> return $ V.Var  (mkAnn n) (tkSymbol n)
    B.Hole n                  -> return $ V.Hole (tkProvenance n, V.TheUser) (tkSymbol n)
    B.Literal l               -> elab l
    B.TypeC   tc              -> elab tc

    B.Ann e tk t              -> op2 V.Ann tk  (elab e) (elab t)
    B.Fun t1 tk t2            -> op2 V.Pi  tk  (elabFunInputType t1) (elab t2)
    B.Seq tk1 es _tk2         -> op1 V.Seq tk1 (traverse elab es)

    B.App e1 e2               -> elabApp e1 e2
    -- It is really bad not to have provenance for let tokens here, see issue #6
    B.Let ds e                -> unfoldLet V.emptyUserAnn <$> bitraverse (traverse elab) elab (ds, e)
    B.Forall tk1 ns _tk2 t    -> do checkNonEmpty tk1 ns; unfoldForall (mkAnn tk1) <$> elabBindersAndBody ns t
    B.Lam tk1 ns _tk2 e       -> do checkNonEmpty tk1 ns; unfoldLam    (mkAnn tk1) <$> elabBindersAndBody ns e

    B.Every   tk1 ns    _tk2 e  -> elabQuantifier   tk1 V.All ns e
    B.Some    tk1 ns    _tk2 e  -> elabQuantifier   tk1 V.Any ns e
    B.EveryIn tk1 ns e1 _tk2 e2 -> elabQuantifierIn tk1 V.All ns e1 e2
    B.SomeIn  tk1 ns e1 _tk2 e2 -> elabQuantifierIn tk1 V.Any ns e1 e2

    B.Bool tk                 -> builtin (V.BooleanType   V.Bool)   tk []
    B.Prop tk                 -> builtin (V.BooleanType   V.Prop)   tk []
    B.Real tk                 -> builtin (V.NumericType   V.Real)   tk []
    B.Rat  tk                 -> builtin (V.NumericType   V.Rat)    tk []
    B.Int tk                  -> builtin (V.NumericType   V.Int)    tk []
    B.Nat tk                  -> builtin (V.NumericType   V.Nat)    tk []
    B.List tk t               -> builtin (V.ContainerType V.List)   tk [t]
    B.Tensor tk t1 t2         -> builtin (V.ContainerType V.Tensor) tk [t1, t2]

    B.If tk1 e1 _ e2 _ e3     -> builtin V.If                  tk1 [e1, e2, e3]
    B.Not tk e                -> builtin V.Not                 tk  [e]
    B.Impl e1 tk e2           -> builtin (V.BooleanOp2 V.Impl) tk  [e1, e2]
    B.And e1 tk e2            -> builtin (V.BooleanOp2 V.And)  tk  [e1, e2]
    B.Or e1 tk e2             -> builtin (V.BooleanOp2 V.Or)   tk  [e1, e2]

    B.Eq e1 tk e2             -> builtin (V.Equality V.Eq)  tk [e1, e2]
    B.Neq e1 tk e2            -> builtin (V.Equality V.Neq) tk [e1, e2]
    B.Le e1 tk e2             -> builtin (V.Order    V.Le)  tk [e1, e2]
    B.Lt e1 tk e2             -> builtin (V.Order    V.Lt)  tk [e1, e2]
    B.Ge e1 tk e2             -> builtin (V.Order    V.Ge)  tk [e1, e2]
    B.Gt e1 tk e2             -> builtin (V.Order    V.Gt)  tk [e1, e2]

    B.Mul e1 tk e2            -> builtin (V.NumericOp2 V.Mul) tk [e1, e2]
    B.Div e1 tk e2            -> builtin (V.NumericOp2 V.Div) tk [e1, e2]
    B.Add e1 tk e2            -> builtin (V.NumericOp2 V.Add) tk [e1, e2]
    B.Sub e1 tk e2            -> builtin (V.NumericOp2 V.Sub) tk [e1, e2]
    B.Neg tk e                -> builtin V.Neg tk [e]

    B.Cons e1 tk e2           -> builtin V.Cons tk [e1, e2]
    B.At e1 tk e2             -> builtin V.At   tk [e1, e2]
    B.Map tk e1 e2            -> builtin V.Map  tk [e1, e2]
    B.Fold tk e1 e2 e3        -> builtin V.Fold tk [e1, e2, e3]

instance Elab B.Arg V.InputArg where
  elab (B.ExplicitArg e) = mkArg V.Explicit <$> elab e
  elab (B.ImplicitArg e) = mkArg V.Implicit <$> elab e
  elab (B.InstanceArg e) = mkArg V.Instance <$> elab e

mkArg :: V.Visibility -> V.InputExpr -> V.InputArg
mkArg v e = V.Arg (V.visProv v (provenanceOf e), V.TheUser) v e

instance Elab B.Name V.Identifier where
  elab n = return $ V.Identifier $ tkSymbol n

instance Elab B.Binder V.InputBinder where
  elab (B.ExplicitBinder    n)         = return $ mkBinder n V.Explicit Nothing
  elab (B.ImplicitBinder    n)         = return $ mkBinder n V.Implicit Nothing
  elab (B.ExplicitBinderAnn n _tk typ) = mkBinder n V.Explicit . Just <$> elab typ
  elab (B.ImplicitBinderAnn n _tk typ) = mkBinder n V.Implicit . Just <$> elab typ

mkBinder :: B.Name -> V.Visibility -> Maybe V.InputExpr -> V.InputBinder
mkBinder n v e = V.Binder (V.visProv v p, V.TheUser) v (Just (tkSymbol n)) t
  where
    (p, t) = case e of
      Nothing -> (tkProvenance n, V.Hole (tkProvenance n, V.TheUser) "_")
      Just t1  -> (fillInProvenance [tkProvenance n, provenanceOf t1], t1)

instance Elab B.LetDecl (V.InputBinder, V.InputExpr) where
  elab (B.LDecl b e) = bitraverse elab elab (b,e)

instance Elab B.Lit V.InputExpr where
  elab = \case
    B.LitTrue  t -> return $ V.LitBool (mkAnn t) True
    B.LitFalse t -> return $ V.LitBool (mkAnn t) False
    B.LitRat   t -> return $ V.LitRat  (mkAnn t) (readRat (tkSymbol t))
    B.LitInt   n -> return $ if n >= 0
      then V.LitNat V.emptyUserAnn (fromIntegral n)
      else V.LitInt V.emptyUserAnn (fromIntegral n)

instance Elab B.TypeClass V.InputExpr where
  elab = \case
    B.TCEq    tk e1 e2 -> builtin (V.TypeClass V.HasEq)          tk [e1, e2]
    B.TCOrd   tk e1 e2 -> builtin (V.TypeClass V.HasOrd)         tk [e1, e2]
    B.TCCont  tk e1 e2 -> builtin (V.TypeClass V.IsContainer)    tk [e1, e2]
    B.TCTruth tk e     -> builtin (V.TypeClass V.IsTruth)        tk [e]
    B.TCQuant tk e     -> builtin (V.TypeClass V.IsQuantifiable) tk [e]
    B.TCNat   tk e     -> builtin (V.TypeClass V.IsNatural)      tk [e]
    B.TCInt   tk e     -> builtin (V.TypeClass V.IsIntegral)     tk [e]
    B.TCRat   tk e     -> builtin (V.TypeClass V.IsRational)     tk [e]
    B.TCReal  tk e     -> builtin (V.TypeClass V.IsReal)         tk [e]

op1 :: (MonadElab e m, HasProvenance a, IsToken token)
    => (V.InputAnn -> a -> b)
    -> token -> m a -> m b
op1 mk t e = do
  ce <- e
  let p = fillInProvenance [tkProvenance t, provenanceOf ce]
  return $ mk (p, V.TheUser) ce

op2 :: (MonadElab e m, HasProvenance a, HasProvenance b, IsToken token)
    => (V.InputAnn -> a -> b -> c)
    -> token -> m a -> m b -> m c
op2 mk t e1 e2 = do
  ce1 <- e1
  ce2 <- e2
  let p = fillInProvenance [tkProvenance t, provenanceOf ce1, provenanceOf ce2]
  return $ mk (p, V.TheUser) ce1 ce2

builtin :: (MonadElab e m, IsToken token) => V.Builtin -> token -> [B.Expr] -> m V.InputExpr
builtin b t args = builtin' b t <$> traverse elab args

builtin' :: IsToken token => V.Builtin -> token -> [V.InputExpr] -> V.InputExpr
builtin' b t argExprs = V.normAppList (p', V.TheUser) (V.Builtin (p, V.TheUser) b) args
  where
    p    = tkProvenance t
    p'   = fillInProvenance (p : map provenanceOf args)
    args = fmap (mkArg V.Explicit) argExprs

elabFunInputType :: MonadElab e m => B.Expr -> m V.InputBinder
elabFunInputType t = do
  t' <- elab t
  return $ V.ExplicitBinder (provenanceOf t', V.TheUser) Nothing t'

elabApp :: MonadElab e m => B.Expr -> B.Arg -> m V.InputExpr
elabApp fun arg = do
  fun' <- elab fun
  arg' <- elab arg
  let p = fillInProvenance [provenanceOf fun', provenanceOf arg']
  return $ V.normAppList (p, V.TheUser) fun' [arg']

elabBindersAndBody :: MonadElab e m => [B.Binder] -> B.Expr -> m ([V.InputBinder], V.InputExpr)
elabBindersAndBody bs body = bitraverse (traverse elab) elab (bs, body)

elabQuantifier :: (MonadElab e m, IsToken token) => token -> V.Quantifier -> [B.Binder] -> B.Expr -> m V.InputExpr
elabQuantifier t q bs body = do
  checkNonEmpty t bs
  unfoldQuantifier (mkAnn t) q <$> elabBindersAndBody bs body

elabQuantifierIn :: (MonadElab e m, IsToken token) => token -> V.Quantifier -> [B.Binder] -> B.Expr -> B.Expr -> m V.InputExpr
elabQuantifierIn t q bs container body = do
  checkNonEmpty t bs
  unfoldQuantifierIn (mkAnn t) q <$> elab container <*> elabBindersAndBody bs body

-- |Takes a list of declarations, and groups type and expression
--  declarations by their name.
groupDecls :: MonadElab e m => [B.Decl] -> m [V.InputDecl]
groupDecls []       = return []
groupDecls (d : ds) = NonEmpty.toList <$> traverse elab (NonEmpty.groupBy1 cond (d :| ds))
  where
    cond :: B.Decl -> B.Decl -> Bool
    cond d1 d2 = isDefFun d1 && isDefFun d2 && tkSymbol (declName d1) == tkSymbol (declName d2)

    isDefFun :: B.Decl -> Bool
    isDefFun (B.DefFunType _name _args _exp) = True
    isDefFun (B.DefFunExpr _ann _name _typ)  = True
    isDefFun _                               = False

-- |Get the name for any declaration.
declName :: B.Decl -> B.Name
declName (B.DeclNetw   n _ _) = n
declName (B.DeclData   n _ _) = n
declName (B.DefType    n _ _) = n
declName (B.DefFunType n _ _) = n
declName (B.DefFunExpr n _ _) = n

checkNonEmpty :: (MonadElab e m, IsToken token) => token -> [a] -> m ()
checkNonEmpty tk = checkNonEmpty' (tkProvenance tk) (tkSymbol tk)

checkNonEmpty' :: (MonadElab e m) => Provenance -> Symbol -> [a] -> m ()
checkNonEmpty' p s []      = throwError $ mkMissingVariables p s
checkNonEmpty' _ _ (_ : _) = return ()