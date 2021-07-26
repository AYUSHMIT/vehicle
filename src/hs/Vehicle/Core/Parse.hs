{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Core.Parse
  ( parseText
  , parseFile
  , ParseError(..)
  ) where

import Control.Monad.Except (MonadError(..))
import Data.Text (Text, pack, unpack)
import Data.Text.IO qualified as T
import Prettyprinter ( (<+>), pretty )
import System.Exit (exitFailure)

import Vehicle.Core.Abs as B
import Vehicle.Core.Par (pProg, myLexer)
import Vehicle.Core.AST as V hiding (Name)
import Vehicle.Prelude

--------------------------------------------------------------------------------
-- Parsing

parseText :: Text -> Either ParseError V.InputProg
parseText txt = case pProg (myLexer txt) of
  Left err1      -> Left $ BNFCParseError err1
  Right bnfcProg -> case conv bnfcProg of
    Left  err2 -> Left  err2
    Right prog -> Right prog

-- Used in both application and testing which is why it lives here.
parseFile :: FilePath -> IO V.InputProg
parseFile file = do
  contents <- T.readFile file
  case parseText contents of
    Left err -> do print (details err); exitFailure
    Right ast -> return ast

--------------------------------------------------------------------------------
-- Errors

-- |Type of errors thrown when parsing.
data ParseError
  = UnknownBuiltin Token
  | MalformedPiBinder Token
  | MalformedLamBinder V.InputExpr
  | BNFCParseError String

instance MeaningfulError ParseError where
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
    { problem    = "Malformed binder for Lambda, expected a name but only found an expression" <+> pretty expr
    , provenance = annotation expr
    , fix        = "Unknown"
    }


  -- TODO need to revamp this error, BNFC must provide some more
  -- information than a simple string surely?
  details (BNFCParseError text) = EError $ ExternalError (pack text)

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

class Convert vf vc where
  conv :: MonadParse m => vf -> m vc

type MonadParse m = MonadError ParseError m

--------------------------------------------------------------------------------
-- AST conversion

lookupBuiltin :: MonadParse m => B.BuiltinToken -> m V.Builtin
lookupBuiltin (BuiltinToken tk) = case builtinFromSymbol (tkSymbol tk) of
    Nothing -> throwError $ UnknownBuiltin $ toToken tk
    Just v  -> return v

instance Convert B.Binder V.InputBinder where
  conv = \case
    B.ExplicitNameAndType n e -> V.Binder (tkProvenance n) Explicit (tkSymbol n) <$> conv e
    B.ImplicitNameAndType n e -> V.Binder (tkProvenance n) Implicit (tkSymbol n) <$> conv e
    B.ExplicitName n          -> return $ V.Binder (tkProvenance n) Explicit (tkSymbol n) (V.Meta _)
    B.ImplicitName n          -> return $ V.Binder (tkProvenance n) Implicit (tkSymbol n) (V.Meta _)

instance Convert B.Arg V.InputArg where
  conv = \case
    B.ImplicitArg e -> V.Arg _ Implicit <$> conv e
    B.ExplicitArg e -> V.Arg _ Explicit <$> conv e

instance Convert B.Lit Literal where
  conv = \case
    B.LitNat  n -> return $ LInt  n
    B.LitReal r -> return $ LReal r
    B.LitBool b -> return $ LBool (read (unpack $ tkSymbol b))

instance Convert B.Expr V.InputExpr where
  conv = \case
    B.Type l           -> return $ V.Type l
    B.Hole name        -> return $ V.Hole (tkProvenance name) (tkSymbol name)
    B.Ann term typ     -> op2 V.Ann <$> conv term <*> conv typ
    B.App fun arg      -> op2 V.App <$> conv fun <*> conv arg
    B.Pi  binder expr  -> op2 V.Pi  <$> conv binder <*> conv expr;
    B.Lam binder e     -> op2 V.Lam <$> conv binder <*> conv e
    B.Let binder e1 e2 -> op3 V.Let <$> conv binder <*> conv e1 <*> conv e2
    B.Seq es           -> op1 V.Seq <$> traverse conv es
    B.Builtin c        -> V.Builtin (tkProvenance c) <$> lookupBuiltin c
    B.Literal v        -> V.Literal mempty <$> conv v
    B.Var n            -> return $ V.Bound (tkProvenance n) (tkSymbol n)

instance Convert B.NameToken DeclIdentifier where
  conv n = return $ DeclIdentifier (tkProvenance n) (tkSymbol n)

instance Convert B.Decl V.InputDecl where
  conv = \case
    B.DeclNetw n t   -> op2 V.DeclNetw <$> conv n <*> conv t
    B.DeclData n t   -> op2 V.DeclData <$> conv n <*> conv t
    B.DefFun   n t e -> op3 V.DefFun   <$> conv n <*> conv t <*> conv e

instance Convert B.Prog V.InputProg where
  conv (B.Main ds) = V.Main <$> traverse conv ds

op1 :: (HasProvenance a)
    => (Provenance -> a -> b)
    -> a -> b
op1 mk t = mk (prov t) t

op2 :: (HasProvenance a, HasProvenance b)
    => (Provenance -> a -> b -> c)
    -> a -> b -> c
op2 mk t1 t2 = mk (prov t1 <> prov t2) t1 t2

op3 :: (HasProvenance a, HasProvenance b, HasProvenance c)
    => (Provenance -> a -> b -> c -> d)
    -> a -> b -> c -> d
op3 mk t1 t2 t3 = mk (prov t1 <> prov t2 <> prov t3) t1 t2 t3