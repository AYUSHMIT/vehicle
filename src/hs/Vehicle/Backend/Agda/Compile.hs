module Vehicle.Backend.Agda.Compile
  ( AgdaOptions(..)
  , compileProgToAgda
  ) where

import GHC.Real (numerator, denominator)
import Control.Monad.Except (MonadError(..))
import Control.Monad.Reader (MonadReader(..), runReaderT, asks)
import Data.List.NonEmpty qualified as NonEmpty (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Foldable (fold)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.List (sort)
import System.FilePath (takeBaseName)
import Prettyprinter hiding (hsep, vsep, hcat, vcat)

import Vehicle.Language.Print
import Vehicle.Language.Sugar
import Vehicle.Compile.Prelude hiding (CompileOptions(..))
import Vehicle.Compile.Error
import Vehicle.Compile.CapitaliseTypeNames (capitaliseTypeNames)
import Vehicle.Compile.SupplyNames (supplyDBNames)
import Vehicle.Compile.Descope (runDescopeProg)
import Vehicle.Backend.Prelude


--------------------------------------------------------------------------------
-- Agda-specific options

data AgdaOptions = AgdaOptions
  { proofCacheLocation  :: Maybe FilePath
  , outputFile          :: Maybe FilePath
  , modulePrefix        :: Maybe String
  }

compileProgToAgda :: MonadCompile m => AgdaOptions -> CheckedProg -> m (Doc a)
compileProgToAgda options prog1 = logCompilerPass currentPhase $
  flip runReaderT (options, BoolLevel) $ do
    let prog2 = capitaliseTypeNames prog1
    let prog3 = supplyDBNames prog2
    let prog4 = runDescopeProg prog3
    programDoc <- compileProg prog4
    let programStream = layoutPretty defaultLayoutOptions programDoc
    -- Collects dependencies by first discarding precedence info and then
    -- folding using Set Monoid
    let progamDependencies = fold (reAnnotateS fst programStream)

    let baseModule = maybe "Spec" takeBaseName (outputFile options)
    let moduleName = Text.pack $ maybe "" (<> ".") (modulePrefix options) <> baseModule
    return $ unAnnotate ((vsep2 :: [Code] -> Code)
      [ optionStatements ["allow-exec"]
      , importStatements progamDependencies
      , moduleHeader moduleName
      , programDoc
      ])

--------------------------------------------------------------------------------
-- Debug functions

logEntry :: MonadAgdaCompile m => OutputExpr -> m ()
logEntry e = do
  incrCallDepth
  logDebug MaxDetail $ "compile-entry" <+> prettyVerbose e

logExit :: MonadAgdaCompile m => Code -> m ()
logExit e = do
  logDebug MaxDetail $ "compile-exit " <+> e
  decrCallDepth

--------------------------------------------------------------------------------
-- Modules

-- |All possible Agda modules the program may depend on.
data Dependency
  -- Vehicle Agda library (hopefully will migrate these with time)
  = VehicleCore
  | VehicleUtils
  | DataTensor
  | DataTensorInstances
  | DataTensorAll
  | DataTensorAny
  -- Standard library
  | DataUnit
  | DataEmpty
  | DataProduct
  | DataSum
  | DataNat
  | DataNatInstances
  | DataNatDivMod
  | DataInteger
  | DataIntegerInstances
  | DataIntegerDivMod
  | DataRat
  | DataRatInstances
  | DataBool
  | DataBoolInstances
  | DataFin
  | DataList
  | DataListInstances
  | DataListAll
  | DataListAny
  | FunctionBase
  | PropEquality
  | RelNullary
  | RelNullaryDecidable
  deriving (Eq, Ord)

instance Pretty Dependency where
  pretty = \case
    VehicleCore          -> "Vehicle"
    VehicleUtils         -> "Vehicle.Utils"
    DataTensor           -> "Vehicle.Data.Tensor"
    DataTensorInstances  -> "Vehicle.Data.Tensor.Instances"
    DataTensorAll        -> "Vehicle.Data.Tensor.Relation.Unary.All as" <+> containerQualifier Tensor
    DataTensorAny        -> "Vehicle.Data.Tensor.Relation.Unary.Any as" <+> containerQualifier Tensor
    DataUnit             -> "Data.Unit"
    DataEmpty            -> "Data.Empty"
    DataProduct          -> "Data.Product"
    DataSum              -> "Data.Sum"
    DataNat              -> "Data.Nat as" <+> numericQualifier Nat <+> "using" <+> parens "ℕ"
    DataNatInstances     -> "Data.Nat.Instances"
    DataNatDivMod        -> "Data.Nat.DivMod as" <+> numericQualifier Nat
    DataInteger          -> "Data.Integer as" <+> numericQualifier Int <+> "using" <+> parens "ℤ"
    DataIntegerInstances -> "Data.Integer.Instances"
    DataIntegerDivMod    -> "Data.Int.DivMod as" <+> numericQualifier Int
    DataRat              -> "Data.Rational as" <+> numericQualifier Rat <+> "using" <+> parens "ℚ"
    DataRatInstances     -> "Data.Rational.Instances"
    DataBool             -> "Data.Bool as 𝔹" <+> "using" <+> parens "Bool; true; false; if_then_else_"
    DataBoolInstances    -> "Data.Bool.Instances"
    DataFin              -> "Data.Fin as Fin" <+> "using" <+> parens "Fin; #_"
    DataList             -> "Data.List"
    DataListInstances    -> "Data.List.Instances"
    DataListAll          -> "Data.List.Relation.Unary.All as" <+> containerQualifier List
    DataListAny          -> "Data.List.Relation.Unary.Any as" <+> containerQualifier List
    FunctionBase         -> "Function.Base"
    PropEquality         -> "Relation.Binary.PropositionalEquality"
    RelNullary           -> "Relation.Nullary"
    RelNullaryDecidable  -> "Relation.Nullary.Decidable"

optionStatement :: Text -> Doc a
optionStatement option = "{-# OPTIONS --" <> pretty option <+> "#-}"

optionStatements :: [Text] -> Doc a
optionStatements = vsep . map optionStatement

importStatement :: Dependency -> Doc a
importStatement dep = "open import" <+> pretty dep

importStatements :: Set Dependency -> Doc a
importStatements deps = vsep $ map importStatement dependencies
  where dependencies = sort (VehicleCore : Set.toList deps)

moduleHeader :: Text -> Doc a
moduleHeader moduleName = "module" <+> pretty moduleName <+> "where"

numericQualifier :: NumericType -> Doc a
numericQualifier = \case
  Nat   -> "ℕ"
  Int   -> "ℤ"
  Rat   -> "ℚ"

containerQualifier :: ContainerType -> Doc a
containerQualifier = pretty . show

numericDependencies :: NumericType -> [Dependency]
numericDependencies = \case
  Nat   -> [DataNat]
  Int   -> [DataInteger]
  Rat   -> [DataRat]

indentCode :: Code -> Code
indentCode = indent 2

scopeCode :: Code -> Code -> Code
scopeCode keyword code = keyword <> line <> indentCode code

--------------------------------------------------------------------------------
-- Intermediate results of compilation

-- | Marks if the current boolean expression is compiled to `Set` or `Bool`
data BoolLevel = TypeLevel | BoolLevel

type Precedence = Int

type Code = Doc (Set Dependency, Precedence)

minPrecedence :: Precedence
minPrecedence = -1000

maxPrecedence :: Precedence
maxPrecedence = 1000

getPrecedence :: Code -> Precedence
getPrecedence e = maybe maxPrecedence snd (docAnn e)

annotateConstant :: [Dependency] -> Code -> Code
annotateConstant dependencies = annotate (Set.fromList dependencies, maxPrecedence)

annotateApp :: [Dependency] -> Code -> [Code] -> Code
annotateApp dependencies fun args =
  let precedence = 20 in
  let bracketedArgs = map (bracketIfRequired precedence) args in
  annotate (Set.fromList dependencies, precedence) (hsep (fun : bracketedArgs))

annotateInfixOp1 :: [Dependency]
                 -> Precedence
                 -> Maybe Code
                 -> Code
                 -> [Code]
                 -> Code
annotateInfixOp1 dependencies precedence qualifier op args = result
  where
    bracketedArgs = map (bracketIfRequired precedence) args
    qualifierDoc  = maybe "" (<> ".") qualifier
    doc = case bracketedArgs of
      []       -> qualifierDoc <> op <> "_"
      [e1]     -> qualifierDoc <> op <+> e1
      _        -> developerError $ "was expecting no more than 1 argument for" <+> op <+>
                                   "but found the following arguments:" <+> list args
    result = annotate (Set.fromList dependencies, precedence) doc

annotateInfixOp2 :: [Dependency]
                 -> Precedence
                 -> (Code -> Code)
                 -> Maybe Code
                 -> Code
                 -> [Code]
                 -> Code
annotateInfixOp2 dependencies precedence opBraces qualifier op args = result
  where
    bracketedArgs = map (bracketIfRequired precedence) args
    qualifierDoc  = maybe "" (<> ".") qualifier
    doc = case bracketedArgs of
      []       -> qualifierDoc <> "_" <> op <> "_"
      [e1]     -> e1 <+> qualifierDoc <> op <> "_"
      [e1, e2] -> e1 <+> qualifierDoc <> op <+> e2
      _        -> developerError $ "was expecting no more than 2 arguments for" <+> op <+>
                                   "but found the following arguments:" <+> list args
    result = annotate (Set.fromList dependencies, precedence) (opBraces doc)


bracketIfRequired :: Precedence -> Code -> Code
bracketIfRequired parentPrecedence expr =
  if getPrecedence expr <= parentPrecedence
    then parens expr
    else expr

argBrackets :: Visibility -> Code -> Code
argBrackets Explicit = id
argBrackets Implicit = braces
argBrackets Instance = braces . braces

binderBrackets :: Visibility -> Code -> Code
binderBrackets Explicit = parens
binderBrackets Implicit = braces
binderBrackets Instance = braces . braces

boolBraces :: Code -> Code
boolBraces c = annotateConstant [RelNullaryDecidable] "⌊" <+> c <+> "⌋"

arrow :: Code
arrow = "→" -- <> softline'

--------------------------------------------------------------------------------
-- Monad stack

type MonadAgdaCompile m =
  ( MonadCompile m
  , MonadReader (AgdaOptions, BoolLevel) m
  )

getBoolLevel :: MonadAgdaCompile m => m BoolLevel
getBoolLevel = asks snd

setBoolLevel :: MonadAgdaCompile m => BoolLevel -> m a -> m a
setBoolLevel level = local (\(opts, _) -> (opts, level))

--------------------------------------------------------------------------------
-- Program Compilation

compileProg :: MonadAgdaCompile m => OutputProg -> m Code
compileProg (Main ds) = vsep2 <$> traverse compileDecl ds

compileDecl :: MonadAgdaCompile m => OutputDecl -> m Code
compileDecl = \case
  DefResource _ _ n t ->
    compileResource (compileIdentifier n) <$> compileExpr t

  DefFunction _ann _u n t e -> do
    let (binders, body) = foldLam e
    setBoolLevel TypeLevel $
      if isProperty t
        then compileProperty (compileIdentifier n) =<< compileExpr e
        else do
          let binders' = traverse (compileBinder True) binders
          compileFunDef (compileIdentifier n) <$> compileExpr t <*> binders' <*> compileExpr body

compileExpr :: MonadAgdaCompile m => OutputExpr -> m Code
compileExpr expr = do
  logEntry expr
  result <- case expr of
    Hole{}     -> resolutionError currentPhase "Hole"
    Meta{}     -> resolutionError currentPhase "Meta"
    PrimDict{} -> typeError currentPhase "PrimDict"

    Type _ l   -> return $ compileType l
    Var  _ n   -> return $ annotateConstant [] (pretty n)

    Pi ann binder result -> case foldPi ann binder result of
      Left (binders, body)  -> compileTypeLevelQuantifier Forall binders body
      Right (input, output) ->
        annotateInfixOp2 [] minPrecedence id Nothing arrow <$> traverse compileExpr [input, output]

    Ann _ann e t -> compileAnn <$> compileExpr e <*> compileExpr t

    Let _ann bound binding body -> do
      cBoundExpr <- compileLetBinder (binding, bound)
      cBody      <- compileExpr body
      return $ "let" <+> cBoundExpr <+> "in" <+> cBody
      {-
      -- TODO re-enable let folding - Agda separates by whitespace though so it's complicated.
      let (boundExprs, body) = foldLet expr
      cBoundExprs <- traverse compile boundExprs
      cBody       <- compile body
      return $ "let" <+> vsep (punctuate ";" cBoundExprs) <+> "in" <+> cBody
      -}

    Lam{} -> do
      let (binders, body) = foldLam expr
      cBinders <- traverse (compileBinder False) binders
      cBody    <- compileExpr body
      return $ annotate (mempty, minPrecedence) ("λ" <+> hsep cBinders <+> arrow <+> cBody)

    Builtin{} -> compileBuiltin expr
    Literal{} -> compileLiteral expr

    App _ fun args -> case fun of
      Builtin{}    -> compileBuiltin expr
      Literal{}    -> compileLiteral expr
      _            -> do
        cFun   <- compileExpr fun
        cArgs  <- traverse compileArg args
        return $ annotateApp [] cFun (NonEmpty.toList cArgs)

    LSeq ann dict xs -> compileSeq ann dict xs

  logExit result
  return result

compileLetBinder :: MonadAgdaCompile m
                 => LetBinder OutputBinding OutputVar OutputAnn
                 -> m Code
compileLetBinder (binder, expr) = do
  let binderName = pretty (nameOf binder :: OutputBinding)
  cExpr <- compileExpr expr
  return $ binderName <+> "=" <+> cExpr

compileArg :: MonadAgdaCompile m => OutputArg -> m Code
compileArg arg = argBrackets (visibilityOf arg) <$> compileExpr (argExpr arg)

compileBooleanType :: MonadAgdaCompile m => m Code
compileBooleanType = do
  boolLevel <- getBoolLevel
  return $ case boolLevel of
    TypeLevel -> compileType 0
    BoolLevel -> annotateConstant [DataBool] "Bool"

compileNumericType :: NumericType -> Code
compileNumericType t = annotateConstant (numericDependencies t) (numericQualifier t)

compileIdentifier :: Identifier -> Code
compileIdentifier ident = pretty (nameOf ident :: Symbol)

compileType :: UniverseLevel -> Code
compileType 0 = "Set"
compileType l = annotateConstant [] ("Set" <> pretty l)

compileBinder :: MonadAgdaCompile m => Bool -> OutputBinder -> m Code
compileBinder topLevel binder = do
  let binderName = pretty (nameOf binder :: OutputBinding)
  if topLevel
    then return binderName
    else do
      binderType <- compileExpr (typeOf binder)
      let annBinder = annotateInfixOp2 [] minPrecedence id Nothing ":" [binderName, binderType]
      return $ binderBrackets (visibilityOf binder) annBinder

compileBuiltin :: MonadAgdaCompile m => OutputExpr -> m Code
compileBuiltin e = case e of
  BoolType{}              -> compileBooleanType
  BuiltinNumericType _ t  -> return $ compileNumericType t

  ListType   _ tElem       -> annotateApp [DataList]   "List"   <$> traverse compileExpr [tElem]
  TensorType _ tElem tDims -> annotateApp [DataTensor] "Tensor" <$> traverse compileExpr [tElem, tDims]
  IndexType  _ size        -> annotateApp [DataFin]    "Fin"    <$> traverse compileExpr [size]

  IfExpr _ _ [e1, e2, e3] -> do
    ce1 <- setBoolLevel BoolLevel $ compileArg e1
    ce2 <- compileArg e2
    ce3 <- compileArg e3
    return $ annotate (Set.singleton DataBool, 0)
      ("if" <+> ce1 <+> "then" <+> ce2 <+> "else" <+> ce3)

  BooleanOp2Expr op2 _     args -> compileBoolOp2 op2   =<< traverse compileArg (NonEmpty.toList args)
  NotExpr            _     args -> compileNot           =<< traverse compileArg (NonEmpty.toList args)
  NumericOp2Expr op2 _ t _ args -> compileNumOp2  op2 t <$> traverse compileArg args
  NegExpr            _ t   args -> compileNeg         t <$> traverse compileArg args

  (ForallExpr  _  binder body) -> compileTypeLevelQuantifier Forall [binder] body
  (ExistsExpr  _  binder body) -> compileTypeLevelQuantifier Exists [binder] body
  (ForeachExpr ann _ _)        -> throwError $ UnsupportedBuiltin AgdaBackend ann Foreach

  (ForallInExpr  ann tCont binder body cont) -> compileQuantIn Forall tCont (Lam ann binder body) cont
  (ExistsInExpr  ann tCont binder body cont) -> compileQuantIn Exists tCont (Lam ann binder body) cont
  (ForeachInExpr ann _ _ _       _    _)     -> throwError $ UnsupportedBuiltin AgdaBackend ann ForeachIn

  (OrderExpr    ord _ t1 args) -> compileOrder ord  t1 =<< traverse compileArg args
  (EqualityExpr Eq  _ t1 args) -> compileEquality   t1 =<< traverse compileArg args
  (EqualityExpr Neq _ t1 args) -> compileInequality t1 =<< traverse compileArg args

  (ConsExpr _ tElem               args) -> compileCons tElem =<< traverse compileArg args
  (AtExpr ann _tElem _tDim _tDims args) -> compileAt ann (map argExpr args)

  MapExpr{}             -> throwError $ UnsupportedBuiltin AgdaBackend (provenanceOf e) Map
  FoldExpr{}            -> throwError $ UnsupportedBuiltin AgdaBackend (provenanceOf e) Fold
  BuiltinTypeClass _ tc -> throwError $ UnsupportedBuiltin AgdaBackend (provenanceOf e) (TypeClass tc)

  _ -> compilerDeveloperError $
    "unexpected application of builtin found during compilation to Agda:" <+>
    squotes (prettyVerbose e) <+> parens (pretty $ provenanceOf e)

compileAnn :: Code -> Code -> Code
compileAnn e t = annotateInfixOp2 [FunctionBase] 0 id Nothing "∋" [t,e]

compileTypeLevelQuantifier :: MonadAgdaCompile m
                           => Quantifier
                           -> [OutputBinder]
                           -> OutputExpr
                           -> m Code
compileTypeLevelQuantifier q binders body = do
  cBinders  <- traverse (compileBinder False) binders
  cBody     <- compileExpr body
  quant     <- case q of
    Forall  -> return "∀"
    Exists  -> return $ annotateConstant [DataProduct] "∃ λ"
  return $ quant <+> hsep cBinders <+> arrow <+> cBody

compileQuantIn :: MonadAgdaCompile m => Quantifier -> OutputExpr -> OutputExpr -> OutputExpr -> m Code
compileQuantIn q tCont fn cont = do
  boolLevel <- getBoolLevel
  contType <- containerType tCont
  let qualifier = containerQualifier contType
  case boolLevel of
    TypeLevel -> do
      let deps  = containerQuantifierDependencies q contType
      let quant = qualifier <> "." <> (if q == Forall then "All" else "Any")
      annotateApp deps quant <$> traverse compileExpr [fn, cont]
    BoolLevel -> do
      let deps  = containerDependencies contType
      let quant = qualifier <> "." <> (if q == Forall then "all" else "any")
      annotateApp deps quant <$> traverse compileExpr [fn, cont]

compileLiteral :: MonadAgdaCompile m => OutputExpr -> m Code
compileLiteral e = case e of
  NatLiteralExpr  _ann IndexType{} n -> return $ compileIndexLiteral (toInteger n)
  NatLiteralExpr  _ann NatType{}   n -> return $ compileNatLiteral   (toInteger n)
  NatLiteralExpr  _ann IntType{}   n -> return $ compileIntLiteral   (toInteger n)
  NatLiteralExpr  _ann RatType{}   n -> return $ compileRatLiteral   (toRational n)
  IntLiteralExpr  _ann Int         i -> return $ compileIntLiteral   (toInteger i)
  IntLiteralExpr  _ann Rat         i -> return $ compileRatLiteral   (toRational i)
  RatLiteralExpr  _ann Rat         p -> return $ compileRatLiteral   p
  BoolLiteralExpr _ann b             -> compileBoolOp0 b
  _                                  -> compilerDeveloperError $
    "unexpected literal" <+> squotes (prettyVerbose e) <+>
    "found during compilation to Agda"

compileIndexLiteral :: Integer -> Code
compileIndexLiteral i = annotateInfixOp1 [DataFin] 10 Nothing "#" [pretty i]

compileNatLiteral :: Integer -> Code
compileNatLiteral = pretty

compileIntLiteral :: Integer -> Code
compileIntLiteral i
  | i >= 0    = annotateInfixOp1 [DataInteger] 8 (Just (numericQualifier Int)) "+" [pretty i]
  | otherwise = annotateInfixOp1 [DataInteger] 6 (Just (numericQualifier Int)) "-" [compileIntLiteral (- i)]

compileRatLiteral :: Rational -> Code
compileRatLiteral r = annotateInfixOp2 [DataRat] 7 id
  (Just $ numericQualifier Rat) "/"
  [ compileIntLiteral (numerator r)
  , compileNatLiteral (denominator r)
  ]

-- |Compiling sequences. No sequences in Agda so have to go via cons.
compileSeq :: MonadAgdaCompile m => OutputAnn -> OutputExpr -> [OutputExpr] -> m Code
compileSeq _ (PrimDict _ (HasConLitsOfSizeExpr _ _ _ tCont)) elems = go elems
  where
    go :: MonadAgdaCompile m => [OutputExpr] -> m Code
    go []       = do
      contType <- containerType tCont
      return $ annotateConstant (containerDependencies contType) "[]"
    go (x : xs) = do
      cx  <- compileExpr x
      cxs <- go xs
      return $ annotateInfixOp2 [] 5 id Nothing "∷" [cx , cxs]
compileSeq ann dict elems = unexpectedArgsError (LSeq ann dict elems) elems ["tElem", "tCont", "tc"]


-- |Compiling cons operator
compileCons :: MonadCompile m => OutputExpr -> [Code] -> m Code
compileCons tCont args = do
  contType <- containerType tCont
  let qualifier = containerQualifier contType
  let deps      = containerDependencies contType
  return $ annotateInfixOp2 deps 5 id (Just qualifier) "∷" args

-- |Compiling boolean constants
compileBoolOp0 :: MonadAgdaCompile m => Bool -> m Code
compileBoolOp0 value = do
  boolLevel <- getBoolLevel
  let (deps, code) = case (value, boolLevel) of
        (True,  BoolLevel) -> ([DataBool],  "true")
        (True,  TypeLevel) -> ([DataUnit],  "⊤")
        (False, BoolLevel) -> ([DataBool],  "false")
        (False, TypeLevel) -> ([DataEmpty], "⊥")
  return $ annotateConstant deps code

-- |Compiling boolean negation
compileNot :: MonadAgdaCompile m => [Code] -> m Code
compileNot args = do
  boolLevel <- getBoolLevel
  return $ case boolLevel of
    BoolLevel -> annotateApp      [DataBool] "not" args
    TypeLevel -> annotateInfixOp1 [RelNullary] 3 Nothing "¬" args

-- |Compiling boolean binary operations
compileBoolOp2 :: MonadAgdaCompile m => BooleanOp2 -> [Code] -> m Code
compileBoolOp2 op2 args = do
  boolLevel <- getBoolLevel
  let (opDoc, precedence, dependencies) = case (op2, boolLevel) of
        (And , BoolLevel) -> ("∧", 6,  [DataBool])
        (Or  , BoolLevel) -> ("∨", 5,  [DataBool])
        (Impl, BoolLevel) -> ("⇒", 4,  [VehicleUtils])
        (And , TypeLevel) -> ("×", 2,  [DataProduct])
        (Or  , TypeLevel) -> ("⊎", 1,  [DataSum])
        (Impl, TypeLevel) -> (arrow, minPrecedence, [])
  return $ annotateInfixOp2 dependencies precedence id Nothing opDoc args

-- |Compiling numeric unary operations
compileNeg :: NumericType -> [Code] -> Code
compileNeg Nat = developerError "Negation is not supported for naturals"
compileNeg t   = annotateInfixOp1 (numericDependencies t) 8 (Just (numericQualifier t)) "-"

-- |Compiling numeric binary operations
compileNumOp2 :: NumericOp2 -> NumericType -> [Code] -> Code
compileNumOp2 op2 t = annotateInfixOp2 dependencies precedence id qualifier opDoc
  where
    precedence = if op2 == Mul || op2 == Div then 7 else 6
    qualifier  = Just (numericQualifier t)
    (opDoc, dependencies) = case (op2, t) of
      (Add, _)     -> ("+", numericDependencies t)
      (Mul, _)     -> ("*", numericDependencies t)
      (Sub, Nat)   -> ("∸", numericDependencies t)
      (Sub, _)     -> ("-", numericDependencies t)
      (Div, Nat)   -> ("/", [DataNatDivMod])
      (Div, Int)   -> ("/", [DataIntegerDivMod])
      (Div, Rat)   -> ("÷", [DataRat])

compileOrder :: MonadAgdaCompile m => Order -> OutputExpr -> [Code] -> m Code
compileOrder order elemType args = do
  boolLevel <- getBoolLevel

  (qualifier, elemDeps) <- case elemType of
        IndexType{}            -> return ("Fin", [DataFin])
        BuiltinNumericType _ t -> return (numericQualifier t, numericDependencies t)
        _                      ->
          unexpectedTypeError elemType ["Nat", "Int", "Rat", "Fin n"]

  let (boolDecDoc, boolDeps, opBraces) = case boolLevel of
        BoolLevel -> ("?", [RelNullary], boolBraces)
        TypeLevel -> ("" , [], id)

  let orderDoc = case order of
        Le -> "≤"
        Lt -> "<"
        Ge -> "≥"
        Gt -> ">"

  let dependencies = elemDeps <> boolDeps
  let opDoc        = orderDoc <> boolDecDoc
  return $ annotateInfixOp2 dependencies 4 opBraces (Just qualifier) opDoc args

compileAt :: MonadAgdaCompile m => CheckedAnn -> [OutputExpr] -> m Code
compileAt _ [tensorExpr, indexExpr] =
  annotateApp [] <$> compileExpr tensorExpr <*> traverse compileExpr [indexExpr]
compileAt ann args =
  unexpectedArgsError (Builtin ann At) args ["tensor", "index"]

compileEquality :: MonadAgdaCompile m => OutputExpr -> [Code] -> m Code
compileEquality tElem args = do
  boolLevel <- getBoolLevel
  case boolLevel of
    TypeLevel -> return $ annotateInfixOp2 [PropEquality] 4 id Nothing "≡" args
    BoolLevel -> do
      -- Boolean function equality is more complicated as we need an actual decision procedure.
      -- We handle this using instance arguments
      instanceArgDependencies <- equalityDependencies tElem
      return $ annotateInfixOp2 ([RelNullary] <> instanceArgDependencies) 4 boolBraces Nothing "≟" args

compileInequality :: MonadAgdaCompile m => OutputExpr -> [Code] -> m Code
compileInequality tElem args = do
  boolLevel <- getBoolLevel
  case boolLevel of
    TypeLevel -> return $ annotateInfixOp2 [PropEquality] 4 id Nothing "≢" args
    BoolLevel -> do
      eq <- compileEquality tElem args
      compileNot [eq]

compileFunDef :: Code -> Code -> [Code] -> Code -> Code
compileFunDef n t ns e =
  n <+> ":" <+> align t <> line <>
  n <+> (if null ns then mempty else hsep ns <> " ") <> "=" <+> e

-- |Compile a `network` declaration
compileResource :: Code -> Code -> Code
compileResource name t =
  "postulate" <+> name <+> ":" <+> align t

compileProperty :: MonadAgdaCompile m => Code -> Code -> m Code
compileProperty propertyName propertyBody = do
  proofCache <- asks (proofCacheLocation . fst)
  return $
    case proofCache of
      Nothing  ->
        "postulate" <+> propertyName <+> ":" <+> align propertyBody
      Just loc ->
        scopeCode "abstract" $
          propertyName <+> ":" <+> align propertyBody          <> line <>
          propertyName <+> "= checkSpecification record"       <> line <>
            indentCode (
            "{ proofCache   =" <+> dquotes (pretty loc) <> line <>
            "}")

containerDependencies :: ContainerType -> [Dependency]
containerDependencies = \case
  List   -> [DataList]
  Tensor -> [DataTensor]

containerQuantifierDependencies :: Quantifier -> ContainerType -> [Dependency]
containerQuantifierDependencies Forall  List   = [DataListAll]
containerQuantifierDependencies Exists  List   = [DataListAny]
containerQuantifierDependencies Forall  Tensor = [DataTensorAll]
containerQuantifierDependencies Exists  Tensor = [DataTensorAny]


-- Calculates the dependencies needed for equality over the provided type
equalityDependencies :: MonadAgdaCompile m => OutputExpr -> m [Dependency]
equalityDependencies = \case
  BuiltinNumericType _ Nat  -> return [DataNatInstances]
  BuiltinNumericType _ Int  -> return [DataIntegerInstances]
  BoolType _                -> return [DataBoolInstances]
  App _ (BuiltinContainerType _ List)   [tElem] -> do
    deps <- equalityDependencies (argExpr tElem)
    return $ [DataListInstances] <> deps
  App _ (BuiltinContainerType _ Tensor) [tElem, _tDims] -> do
    deps <- equalityDependencies (argExpr tElem)
    return $ [DataTensorInstances] <> deps
  Var ann n -> throwError $ UnsupportedPolymorphicEquality AgdaBackend (provenanceOf ann) n
  t         -> unexpectedTypeError t ["Tensor", "Int", "List"]

containerType :: MonadCompile m => OutputExpr -> m ContainerType
containerType (App _ (Builtin _ (ContainerType t)) _) = return t
containerType t = unexpectedTypeError t (map show [List, Tensor])

unexpectedTypeError :: MonadCompile m => OutputExpr -> [String] -> m a
unexpectedTypeError actualType expectedTypes = compilerDeveloperError $
  "Unexpected type found." <+>
  "Was expecting one of" <+> pretty expectedTypes <+>
  "but found" <+> prettyFriendly actualType <+>
  "at" <+> pretty (provenanceOf actualType) <> "."

unexpectedArgsError :: MonadCompile m => OutputExpr -> [OutputExpr] -> [String] -> m a
unexpectedArgsError fun actualArgs expectedArgs = compilerDeveloperError $
  "The function" <+> prettyFriendly fun <+> "was expected to have arguments" <+>
  "of the following form" <+> squotes (pretty expectedArgs) <+> "but found" <+>
  "the following" <+> squotes (prettyFriendly actualArgs) <+>
  "at" <+> pretty (provenanceOf fun) <> "."

currentPhase :: Doc ()
currentPhase = "compilation to Agda"
