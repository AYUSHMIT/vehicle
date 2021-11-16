{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Language.Elaborate.Core
  ( runElab
  ) where

import Control.Monad.Except (MonadError(..))
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (unpack)

import Vehicle.Core.Abs as B

import Vehicle.Prelude
import Vehicle.Language.AST as V
import Vehicle.Language.Print (prettyVerbose)

runElab :: (MonadLogger m, MonadError ElabError m) => B.Prog -> m V.InputProg
runElab = elab

--------------------------------------------------------------------------------
-- Errors

-- |Type of errors thrown when parsing.
data ElabError
  = UnknownBuiltin Token
  | MalformedPiBinder Token
  | MalformedLamBinder V.InputExpr

instance MeaningfulError ElabError where
  details (UnknownBuiltin tk) = UError $ UserError
    { problem    = "Unknown symbol" <+> pretty (tkSymbol tk)
    , provenance = tkProvenance tk
    , fix        = "Please consult the documentation for a description of Vehicle syntax"
    }

  details (MalformedPiBinder tk) = UError $ UserError
    { problem    = "Malformed binder for Pi, expected a type but only found name" <+> pretty (tkSymbol tk)
    , provenance = tkProvenance tk
    , fix        = "Unknown"
    }

  details (MalformedLamBinder expr) = UError $ UserError
    { problem    = "Malformed binder for Lambda, expected a name but only found an expression" <+> prettyVerbose expr
    , provenance = provenanceOf expr
    , fix        = "Unknown"
    }


--------------------------------------------------------------------------------
-- Conversion from BNFC AST
--
-- We convert from the simple AST generated automatically by BNFC to our
-- more complicated internal version of the AST which allows us to annotate
-- terms with sort-dependent types.
--
-- While doing this, we
--
--   1) extract the positions from the tokens generated by BNFC and convert them
--   into `Provenance` annotations.
--
--   2) convert the builtin strings into `Builtin`s

-- * Conversion

class Elab vf vc where
  elab :: MonadElab m => vf -> m vc

type MonadElab m = MonadError ElabError m

--------------------------------------------------------------------------------
-- AST conversion

lookupBuiltin :: MonadElab m => B.BuiltinToken -> m V.Builtin
lookupBuiltin (BuiltinToken tk) = case builtinFromSymbol (tkSymbol tk) of
    Nothing -> throwError $ UnknownBuiltin $ toToken tk
    Just v  -> return v

instance Elab B.Binder V.InputBinder where
  elab = \case
    B.ExplicitBinder n e -> mkBinder n Explicit e
    B.ImplicitBinder n e -> mkBinder n Implicit e
    B.InstanceBinder n e -> mkBinder n Instance e
    where
      mkBinder :: MonadElab m => B.NameToken -> Visibility -> B.Expr -> m V.InputBinder
      mkBinder n v e = V.Binder (mkAnn n) v (Just (tkSymbol n)) <$> elab e

instance Elab B.Arg V.InputArg where
  elab = \case
    B.ExplicitArg e -> mkArg Explicit <$> elab e
    B.ImplicitArg e -> mkArg Implicit <$> elab e
    B.InstanceArg e -> mkArg Instance <$> elab e
    where
      mkArg :: Visibility -> V.InputExpr -> V.InputArg
      mkArg v e = V.Arg (visProv v (provenanceOf e), TheUser) v e

instance Elab B.Lit Literal where
  elab = \case
    B.LitBool b -> return $ LBool (read (unpack $ tkSymbol b))
    B.LitRat  r -> return $ LRat  (readRat (tkSymbol r))
    B.LitInt  n -> return $ if n >= 0
      then LNat (fromIntegral n)
      else LInt (fromIntegral n)

instance Elab B.Expr V.InputExpr where
  elab = \case
    B.Type l           -> return $ convType l
    B.Hole name        -> return $ V.Hole (tkProvenance name) (tkSymbol name)
    B.Ann term typ     -> op2 V.Ann <$> elab term <*> elab typ
    B.Pi  binder expr  -> op2 V.Pi  <$> elab binder <*> elab expr;
    B.Lam binder e     -> op2 V.Lam <$> elab binder <*> elab e
    B.Let binder e1 e2 -> op3 V.Let <$> elab e1 <*> elab binder <*>  elab e2
    B.Seq es           -> op1 V.Seq <$> traverse elab es
    B.Builtin c        -> V.Builtin (mkAnn c) <$> lookupBuiltin c
    B.Literal v        -> V.Literal V.emptyUserAnn <$> elab v
    B.Var n            -> return $ V.Var (mkAnn n) (tkSymbol n)

    B.App fun arg -> do
      fun' <- elab fun
      arg' <- elab arg
      let p = fillInProvenance [provenanceOf fun', provenanceOf arg']
      return $ normApp (p, TheUser) fun' (arg' :| [])

instance Elab B.NameToken Identifier where
  elab n = return $ Identifier $ tkSymbol n

instance Elab B.Decl V.InputDecl where
  elab = \case
    B.DeclNetw n t   -> V.DeclNetw (tkProvenance n) <$> elab n <*> elab t
    B.DeclData n t   -> V.DeclData (tkProvenance n) <$> elab n <*> elab t
    B.DefFun   n t e -> V.DefFun   (tkProvenance n) <$> elab n <*> elab t <*> elab e

instance Elab B.Prog V.InputProg where
  elab (B.Main ds) = V.Main <$> traverse elab ds

mkAnn :: IsToken a => a -> InputAnn
mkAnn x = (tkProvenance x, TheUser)

op1 :: (HasProvenance a)
    => (InputAnn -> a -> b)
    -> a -> b
op1 mk t = mk (provenanceOf t, TheUser) t

op2 :: (HasProvenance a, HasProvenance b)
    => (InputAnn -> a -> b -> c)
    -> a -> b -> c
op2 mk t1 t2 = mk (provenanceOf t1 <> provenanceOf t2, TheUser) t1 t2

op3 :: (HasProvenance a, HasProvenance b, HasProvenance c)
    => (InputAnn -> a -> b -> c -> d)
    -> a -> b -> c -> d
op3 mk t1 t2 t3 = mk (provenanceOf t1 <> provenanceOf t2 <> provenanceOf t3, TheUser) t1 t2 t3

-- | Elabs the type token into a Type expression.
-- Doesn't run in the monad as if something goes wrong with this, we've got
-- the grammar wrong.
convType :: TypeToken -> V.InputExpr
convType tk = case unpack (tkSymbol tk) of
  ('T':'y':'p':'e':l) -> V.Type (read l)
  t                   -> developerError $ "Malformed type token" <+> pretty t