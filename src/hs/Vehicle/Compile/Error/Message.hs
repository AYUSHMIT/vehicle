module Vehicle.Compile.Error.Message
  ( UserError(..)
  , VehicleError(..)
  , MeaningfulError(..)
  , fromLoggedEitherIO
  , logCompileError
  ) where

import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Except (ExceptT, runExceptT)
import Data.Void ( Void )
import Data.Text ( Text, pack )
import Data.List.NonEmpty qualified as NonEmpty
import Data.Foldable (fold)

import Vehicle.Prelude
import Vehicle.Compile.Error
import Vehicle.Compile.Prelude
import Vehicle.Language.Print
import Vehicle.Compile.Type.Constraint

--------------------------------------------------------------------------------
-- User errors

-- |Errors that are the user's responsibility to fix.
data UserError = UserError
  { provenance :: Provenance
  , problem    :: Doc Void
  , fix        :: Maybe (Doc Void)
  }

-- |Errors from external code that we have no control over.
-- These may be either user or developer errors but in general we
-- can't distinguish between the two.
newtype ExternalError = ExternalError Text

data VehicleError
  = UError UserError
  | EError ExternalError
  | DError (Doc ())

instance Pretty VehicleError where
  pretty (UError (UserError p prob probFix)) =
    unAnnotate $ "Error at" <+> pretty p <> ":" <+> prob <>
      maybe "" (\fix -> line <> fixText fix) probFix

  pretty (EError (ExternalError text)) = pretty text

  pretty (DError text) = unAnnotate text

fixText :: Doc ann -> Doc ann
fixText t = "Fix:" <+> t

--------------------------------------------------------------------------------
-- IO

fromEitherIO :: MonadIO m => LoggingOptions -> Either CompileError a -> m a
fromEitherIO _              (Right x)  = return x
fromEitherIO loggingOptions (Left err) =
  fatalError loggingOptions $ pretty $ details err

fromLoggedEitherIO :: MonadIO m
                   => LoggingOptions
                   -> ExceptT CompileError (LoggerT m) a
                   -> m a
fromLoggedEitherIO loggingOptions x = do
  fromEitherIO loggingOptions =<< fromLoggedIO loggingOptions (logCompileError x)

logCompileError :: Monad m
                => ExceptT CompileError (LoggerT m) a
                -> LoggerT m (Either CompileError a)
logCompileError x = do
  e' <- runExceptT x
  case e' of
    Left err -> logDebug MinDetail (pretty (details err))
    Right _  -> return ()
  return e'

--------------------------------------------------------------------------------
-- Meaningful error classes

class MeaningfulError e where
  details :: e -> VehicleError

instance MeaningfulError CompileError where
  details = \case

    ----------------------
    -- Developer errors --
    ----------------------

    DevError text -> DError text

    -------------
    -- Parsing --
    -------------

    BNFCParseError text -> EError $ ExternalError
      -- TODO need to revamp this error, BNFC must provide some more
      -- information than a simple string surely?
      (pack text)

    --------------------------
    -- Elaboration internal --
    --------------------------

    UnknownBuiltin tk -> UError $ UserError
      { provenance = tkProvenance tk
      , problem    = "Unknown symbol" <+> pretty (tkSymbol tk)
      , fix        = Just $ "Please consult the documentation for a description" <+>
                            "of Vehicle syntax"
      }

    MalformedPiBinder tk -> UError $ UserError
      { provenance = tkProvenance tk
      , problem    = "Malformed binder for Pi, expected a type but only found" <+>
                     "name" <+> pretty (tkSymbol tk)
      , fix        = Nothing
      }

    MalformedLamBinder expr -> UError $ UserError
      { provenance = provenanceOf expr
      , problem    = "Malformed binder for Lambda, expected a name but only" <+>
                     "found an expression" <+> prettyVerbose expr
      , fix        = Nothing
      }

    --------------------------
    -- Elaboration external --
    --------------------------

    MissingDefFunExpr p name -> UError $ UserError
      { provenance = p
      , problem    = "missing definition for the declaration" <+> squotes (pretty name)
      , fix        = Just $ "add a definition for the declaration, e.g."
                    <> line <> line
                    <> "addOne :: Int -> Int" <> line
                    <> "addOne x = x + 1     <-----   declaration definition"
      }

    DuplicateName p name -> UError $ UserError
      { provenance = fold p
      , problem    = "multiple definitions found with the name" <+> squotes (pretty name)
      , fix        = Just "remove or rename the duplicate definitions"
      }

    MissingVariables p symbol -> UError $ UserError
      { provenance = p
      , problem    = "expected at least one variable name after" <+> squotes (pretty symbol)
      , fix        = Just $ "add one or more names after" <+> squotes (pretty symbol)
      }

    UnchainableOrders p prevOrder currentOrder -> UError $ UserError
      { provenance = p
      , problem    = "cannot chain" <+> squotes (pretty prevOrder) <+>
                     "and" <+> squotes (pretty currentOrder)
      , fix        = Just "split chained orders into a conjunction"
      }

    -------------
    -- Scoping --
    -------------

    UnboundName name p -> UError $ UserError
      { provenance = p
      -- TODO can use Levenschtein distance to search contexts/builtins
      , problem    = "The name" <+> squotes (pretty name) <+> "is not in scope"
      , fix        = Nothing
      }

    ------------
    -- Typing --
    ------------

    TypeMismatch p ctx candidate expected -> UError $ UserError
      { provenance = p
      , problem    = "expected something of type" <+> prettyExpr ctx expected <+>
                    "but inferred type" <+> prettyExpr ctx candidate
      , fix        = Nothing
      }

    UnresolvedHole p name -> UError $ UserError
      { provenance = p
      , problem    = "the type of" <+> squotes (pretty name) <+> "could not be resolved"
      , fix        = Nothing
      }

    FailedConstraints cs -> UError $ failedConstraintError nameCtx constraint
      where
        constraint = NonEmpty.head cs
        nameCtx = boundContextOf constraint

    UnsolvedConstraints cs -> UError $ UserError
      { provenance = provenanceOf constraint
      , problem    = unsolvedConstraintError constraint nameCtx
      , fix        = Just "try adding more type annotations"
      }
      where
        constraint = NonEmpty.head cs
        nameCtx    = boundContextOf constraint

    UnsolvedMetas ms -> UError $ UserError
      { provenance = p
      , problem    = "Unable to infer type of bound variable"
      , fix        = Just "add more type annotations"
      }
      where
        (_, p) = NonEmpty.head ms

    MissingExplicitArg ctx arg argType -> UError $ UserError
      { provenance = provenanceOf arg
      , problem    = "expected an" <+> pretty Explicit <+> "argument of type" <+>
                    argTypeDoc <+> "but instead found" <+>
                    pretty (visibilityOf arg) <+> "argument" <+> argExprDoc
      , fix        = Just $ "try inserting an argument of type" <+> argTypeDoc
      }
      where
        argExprDoc = prettyExpr ctx (argExpr arg)
        argTypeDoc = prettyExpr ctx argType

    FailedEqConstraint ctx t1 t2 eq -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot use" <+> squotes (pretty eq) <+> "to compare" <+>
                     "arguments" <+> "of type" <+> prettyExpr ctx t1 <+>
                     "and" <+> prettyExpr ctx t2 <> "."
      , fix        = Nothing
      }

    FailedOrdConstraint ctx t1 t2 ord -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot use" <+> squotes (pretty ord) <+> "to compare" <+>
                     "arguments" <+> "of type" <+> prettyExpr ctx t1 <+>
                     "and" <+> prettyExpr ctx t2 <> "."
      , fix        = Nothing
      }

    FailedNotConstraint ctx t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot apply" <+> squotes (pretty Not) <+> "to" <+>
                     "something of type" <+> prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    FailedBoolOp2Constraint ctx t1 t2 op -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot apply" <+> squotes (pretty op) <+> "to" <+>
                     "arguments of type" <+> prettyExpr ctx t1 <+>
                     "and" <+> prettyExpr ctx t2 <> "."
      , fix        = Nothing
      }

    FailedQuantifierConstraintDomain ctx typeOfDomain _q -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot quantify over arguments of type" <+>
                     prettyExpr ctx typeOfDomain <> "."
      , fix        = Nothing
      }

    FailedQuantifierConstraintBody ctx typeOfBody _q -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the body of the quantifier cannot be of type" <+>
                     prettyExpr ctx typeOfBody <> "."
      , fix        = Nothing
      }

    FailedBuiltinConstraintArgument ctx builtin t allowedTypes argNo argTotal ->
      UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "expecting" <+> prettyArgOrdinal argNo argTotal <+>
                     "of" <+> squotes (pretty builtin) <+> "to be" <+>
                     prettyAllowedTypes allowedTypes <+>
                     "but found something of type" <+> prettyExpr ctx t <> "."
      , fix        = Nothing
      } where

    FailedBuiltinConstraintResult ctx builtin actualType allowedTypes ->
      UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the return type of" <+> squotes (pretty builtin) <+>
                     "should be" <+> prettyAllowedTypes allowedTypes <+>
                     "but the program is expecting something of type" <+>
                     prettyExpr ctx actualType <> "."
      , fix        = Nothing
      } where

    FailedArithOp2Constraint ctx t1 t2 op2 -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "cannot apply" <+> squotes (pretty op2) <+> "to" <+>
                     "arguments of type" <+> prettyExpr ctx t1 <+>
                     "and" <+> prettyExpr ctx t2 <> "."
      , fix        = Nothing
      }

    FailedFoldConstraintContainer ctx tCont -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the second argument to" <+> squotes (pretty FoldTC) <+>
                     "must be a container type but found something of type" <+>
                     prettyExpr ctx tCont <> "."
      , fix        = Nothing
      }

    FailedQuantInConstraintContainer ctx tCont q -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the argument <c> in '" <> pretty q <> " <v> in <c> . ...`" <+>
                     "must be a container type but found something of type" <+>
                     prettyExpr ctx tCont <> "."
      , fix        = Nothing
      }

    FailedNatLitConstraint ctx v t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the value" <+> squotes (pretty v) <+> "is not a valid" <+>
                     "instance of type" <+> prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    FailedNatLitConstraintTooBig ctx v n -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "the value" <+> squotes (pretty v) <+> "is too big to" <+>
                     "be used as an index of size" <+> squotes (pretty n) <> "."
      , fix        = Nothing
      }

    FailedNatLitConstraintUnknown ctx v t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "unable to determine if" <+> squotes (pretty v) <+>
                     "is a valid index of size" <+> prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    FailedIntLitConstraint ctx t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "an integer literal is not a valid element of the type" <+>
                     prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    FailedRatLitConstraint ctx t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "a rational literal is not a valid element of the type" <+>
                     prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    FailedConLitConstraint ctx t -> UError $ UserError
      { provenance = provenanceOf ctx
      , problem    = "a vector literal is not a valid element of the type" <+>
                     prettyExpr ctx t <> "."
      , fix        = Nothing
      }

    ---------------
    -- Resources --
    ---------------

    ResourceNotProvided (ident, p) resourceType -> UError $ UserError
      { provenance = p
      , problem    = "No" <+> entity <+> "was provided for the" <+>
                     prettyResource resourceType ident <> "."
      , fix        = Just $ "provide it via the command line using" <+>
                     squotes ("--" <> pretty resourceType <+> pretty ident <>
                     ":" <> var)
      }
      where
      (entity, var) = case resourceType of
        Parameter -> ("value", "VALUE")
        _         -> ("file", "FILEPATH")

    UnsupportedResourceFormat (ident, p) resourceType fileExtension -> UError $ UserError
      { provenance = p
      , problem    = "The file provided for the" <+> prettyResource resourceType ident <+>
                     "is in a format (" <> pretty fileExtension <> ") not currently" <+>
                     "supported by Vehicle."
      , fix        = Just $ "use one of the supported formats" <+>
                     pretty (supportedFileFormats resourceType) <+>
                     ", or open an issue on Github to discuss adding support."
      }

    ResourceIOError (ident, p) resourceType ioException -> UError $ UserError
      { provenance = p
      , problem    = "The following exception occured when trying to read the file" <+>
                     "provided for" <+> prettyResource resourceType ident <> ":" <>
                     line <> indent 2 (pretty (show ioException))
      , fix        = Nothing
      }

    UnableToParseResource (ident, p) resourceType value -> UError $ UserError
      { provenance = p
      , problem    = "Unable to parse the" <+> entity <+> squotes (pretty value) <+>
                     "provided for the" <+> prettyResource resourceType ident
      , fix        = Nothing
      } where entity = if resourceType == Parameter then "value" else "file"

    -- Network errors

    NetworkTypeIsNotAFunction (ident, _p) networkType -> UError $ UserError
      { provenance = provenanceOf networkType
      , problem    = unsupportedResourceTypeDescription Network ident networkType <+> "as" <+>
                     squotes (prettyFriendly networkType) <+> "is not a function."
      , fix        = Just $ supportedNetworkTypeDescription <+>
                     "Provide both an input type and output type for your network."
      }

    NetworkTypeIsNotOverTensors (ident, _p) fullType nonTensorType io -> UError $ UserError
      { provenance = provenanceOf nonTensorType
      , problem    = unsupportedResourceTypeDescription Network ident fullType <+>
                    "as the" <+> pretty io <+> squotes (prettyFriendly nonTensorType) <+>
                    "is not one of" <+> pretty @[Builtin] [Vector, Tensor] <> "."
      , fix        = Just $ supportedNetworkTypeDescription <+>
                     "Ensure the" <+> pretty io <+> "of the network is a Tensor"
      }

    NetworkTypeHasNonExplicitArguments (ident, _p) networkType binder -> UError $ UserError
      { provenance = provenanceOf binder
      , problem    = unsupportedResourceTypeDescription Network ident networkType <+> "as" <+>
                     squotes (prettyFriendly networkType) <+>
                     "contains a non-explicit argument" <+>
                     squotes (prettyFriendly binder) <> "."
      , fix        = Just $ supportedNetworkTypeDescription <+>
                     "Remove the non-explicit argument."
      }

    NetworkTypeHasUnsupportedElementType (ident, _p) fullType elementType io -> UError $ UserError
      { provenance = provenanceOf elementType
      , problem    = unsupportedResourceTypeDescription Network ident fullType <+> "as" <+>
                     pretty io <> "s of type" <+>
                     squotes (prettyFriendlyDBClosed elementType) <+>
                     "are not currently supported."
      , fix        = Just $ supportedNetworkTypeDescription <+>
                     "Ensure that the network" <+> pretty io <+> "uses" <+>
                     "supported types."
      }

    NetworkTypeHasVariableSizeTensor (ident, _p) fullType tDim io -> UError $ UserError
      { provenance = provenanceOf tDim
      , problem    = unsupportedResourceTypeDescription Network ident fullType <+> "as" <+>
                     "the size of the" <+> pretty io <+> "tensor" <+>
                     squotes (prettyFriendlyDBClosed tDim) <+> "is not a constant."
      , fix        = Just $ supportedNetworkTypeDescription <+>
                     "ensure that the size of the" <+> pretty io <+>
                     "tensor is constant."
      }

    NetworkTypeHasImplicitSizeTensor (_, p) implIdent _io -> UError $ UserError
      { provenance = p
      , problem    = "The use of implicit parameters in the type of network declarations" <+>
                     "is not supported."
      , fix        = Just $ "instanstiate the" <+>
                      prettyResource ImplicitParameter implIdent <+>
                      "to an explicit value"
      }

    -- Dataset errors

    DatasetTypeUnsupportedContainer (ident, p) tCont -> UError $ UserError
      { provenance = p
      , problem    = squotes (prettyFriendly tCont) <+> "is not a valid type" <+>
                     "for the" <+> prettyResource Dataset ident <> "."
      , fix        = Just $ "change the type of" <+> squotes (pretty ident) <+>
                     "to one of" <+> elementTypes <> "."
      } where elementTypes = pretty @[Builtin] [List, Vector, Tensor]

    DatasetTypeUnsupportedElement (ident, p) tCont -> UError $ UserError
      { provenance = p
      , problem    = squotes (prettyFriendly tCont) <+> "is not a valid type" <+>
                     "for the elements of the" <+> prettyResource Dataset ident <> "."
      , fix        = Just $ "change the type to one of" <+> elementTypes <> "."
      } where elementTypes = pretty @[Builtin] [Index, Nat, Int, Rat]

    DatasetVariableSizeTensor (ident, p) tCont -> UError $ UserError
      { provenance = p
      , problem    = "A tensor with variable dimension" <+>
                     squotes (prettyFriendlyDBClosed tCont) <+>
                     "is not a supported type for the" <+>
                     prettyResource Dataset ident <> "."
      , fix        = Just "make sure the dimensions of the dataset are all constants."
      }

    DatasetInvalidNat (ident, p) v -> UError $ UserError
      { provenance = p
      , problem    = "Found value" <+> squotes (pretty v) <+>
                     "while reading" <+> prettyResource Dataset ident <+>
                     "but expected elements of type" <+> squotes (prettyFriendlyDBClosed nat)
      , fix        = Just $ "either remove the offending entries in the dataset or" <+>
                     "update the type of the dataset in the specification."
      } where (nat :: CheckedExpr) = NatType mempty

    DatasetInvalidIndex (ident, p) v n -> UError $ UserError
      { provenance = p
      , problem    = "Found value" <+> squotes (pretty v) <+>
                     "while reading" <+> prettyResource Dataset ident <+>
                     "but expected elements of type" <+> squotes (prettyFriendly (ConcreteIndexType mempty n :: InputExpr))
      , fix        = Just $ "either remove the offending entries in the dataset or" <+>
                     "update the type of the dataset in the specification."
      }

    DatasetDimensionMismatch (ident, p) expectedType actualDims -> UError $ UserError
      { provenance = p
      , problem    = "Found dimensions" <+> pretty actualDims <+>
                     "while reading" <+> prettyResource Dataset ident <+>
                     "but expected type to be" <+> prettyFriendlyDBClosed expectedType
      , fix        = Just $ "correct the dataset dimensions in the specification" <+>
                      "or check that the dataset is in the format you were expecting."
      }

    DatasetTypeMismatch (ident, p) expectedType actualType -> UError $ UserError
      { provenance = p
      , problem    = "Found elements of type" <+> prettyFriendlyDBClosed actualType <+>
                     "while reading" <+> prettyResource Dataset ident <+>
                     "but expected elements of type" <+> prettyFriendlyDBClosed expectedType
      , fix        = Just $ "correct the dataset type in the specification or check that" <+>
                      "the dataset is in the format you were expecting."
      }

    -- Parameter errors

    ParameterTypeUnsupported (ident, p) expectedType -> UError $ UserError
      { provenance = p
      , problem    = unsupportedResourceTypeDescription Parameter ident expectedType <>
                    "." <+> supportedParameterTypeDescription
      , fix        = Just "change the parameter type in the specification."
      }

    ParameterValueUnparsable (ident, p) value expectedType -> UError $ UserError
      { provenance = p
      , problem    = "The value" <+> squotes (pretty value) <+>
                     "provided for" <+> prettyResource Parameter ident <+>
                     "could not be parsed as" <+> prettyBuiltinType expectedType <> "."
      , fix        = Just $ "either change the type of the parameter in the" <+>
                     "specification or change the value provided."
      }

    ParameterTypeVariableSizeIndex (ident, p) fullType -> UError $ UserError
      { provenance = p
      , problem    = "An" <+> pretty Index <+> "with variable dimensions" <+>
                     squotes (prettyFriendly fullType) <+>
                     "is not a supported type for the" <+> prettyResource Parameter ident <> "."
      , fix        = Just "make sure the dimensions of the indices are all constants."
      }

    ParameterValueTooLargeForIndex (ident, p) value indexSize -> UError $ UserError
      { provenance = p
      , problem    = "The value" <+> squotes (pretty value) <+>
                     "provided for" <+> prettyResource Parameter ident <+> "is not" <+>
                     "a valid member of the type" <+>
                     squotes (pretty Index <+> pretty indexSize) <> "."
      , fix        = Just $ "either change the size of the index or ensure the value" <+>
                      "provided is in the range" <+> squotes ("0..." <> pretty (indexSize -1)) <+>
                      "(inclusive)."
      }

    ParameterTypeImplicitParamIndex (ident, p) _varIndent -> UError $ UserError
      { provenance = p
      , problem    = "The use of an" <+> pretty ImplicitParameter <+> "for the size of" <+>
                     "an" <+> pretty Index <+> "in the type of" <+>
                     prettyResource Parameter ident <+>  "is not currently supported."
      , fix        = Just $ "replace the 'implicit parameter' with a concrete value or" <+>
                     "open an issue on the Github tracker to request support."
      }

    -- Implicit parameter errors

    ImplicitParameterTypeUnsupported (ident, p) expectedType -> UError $ UserError
      { provenance = p
      , problem    = unsupportedResourceTypeDescription ImplicitParameter ident expectedType <>
                     "." <+> supportedImplicitParameterTypeDescription
      , fix        = Just "change the implicit parameter type in the specification."
      }

    ImplicitParameterContradictory ident ((ident1, _p1), r1, v1) ((ident2, p2), r2, v2) ->
      UError $ UserError
      { provenance = p2
      , problem    = "Found contradictory for values for" <+>
                     prettyResource ImplicitParameter ident <> "." <>
                     "Inferred the value" <+> squotes (pretty v1) <+> "from" <+>
                     prettyResource r1 ident1 <>
                     "but inferred the value" <+> squotes (pretty v2) <+> "from" <+>
                     prettyResource r2 ident2 <> "."
      , fix        = Just "make sure the provided resources are consistent with each other."
      }

    ImplicitParameterUninferrable (ident, p) ->
      UError $ UserError
      { provenance = p
      , problem    = "Unable to infer the value of" <+>
                     prettyResource ImplicitParameter ident <> "."
      , fix        = Just $ "For an implicit parameter to be inferable, it must" <>
                      "be used as the dimension of a dataset" <>
                      "(networks will be supported later)."
      }

    --------------------
    -- Backend errors --
    --------------------

    UnsupportedResource target ident p resource ->
      let dType = squotes (pretty resource) in UError $ UserError
      { provenance = p
      , problem    = "While compiling property" <+> squotes (pretty ident) <+> "to" <+>
                     pretty target <+> "found a" <+> dType <+> "declaration which" <+>
                     "cannot be compiled."
      , fix        = Just $ "remove all" <+> dType <+> "declarations or switch to a" <+>
                     "different compilation target."
      }

    UnsupportedSequentialQuantifiers target (ident, p) q pq pp -> UError $ UserError
      { provenance = p
      , problem    = "The property" <+> squotes (pretty ident) <+> "contains" <+>
                     "a sequence of quantifiers unsupported by" <+> pretty target <>
                     "." <> line <>
                     pretty target <+> "cannot verify properties that mix both" <+>
                     squotes (pretty Forall) <+> "and" <+> squotes (pretty Exists) <+>
                     "quantifiers." <>
                     line <>
                     "In particular the" <+> squotes (pretty q) <+> "at" <+>
                     pretty pq <+> "clashes with" <+>
                     prettyPolarityProvenance (neg q) pp
      , fix        = Just $ "if possible try reformulating" <+> squotes (pretty ident) <+>
                    "in terms of a single type of quantifier."
      }

    UnsupportedNonLinearConstraint target (ident, p) v1 v2 -> UError $ UserError
      { provenance = p
      , problem    = "The property" <+> squotes (pretty ident) <+> "contains" <+>
                     "a non-linear constraint which is not supported by" <+>
                     pretty target <> "." <> line <>
                     "In particular the multiplication at" <+> pretty p <+>
                     "involves" <>
                     prettyLinearityProvenance v1 <>
                     "and" <>
                     prettyLinearityProvenance v2
      , fix        = Just $ "try avoiding it, otherwise please open an issue on the" <+>
                     "Vehicle issue tracker."
      }

    UnsupportedVariableType target ident p name t supportedTypes -> UError $ UserError
      { provenance = p
      , problem    = "When compiling property" <+> squotes (pretty ident) <+> "to" <+>
                     pretty target <+> "found a quantified variable" <+> squotes (pretty name) <+> "of type" <+>
                     squotes (prettyFriendlyDBClosed t) <+> "which is not currently supported" <+>
                     "when compiling to" <+> pretty target <> "."
      , fix        = Just $ "try switching the variable to one of the following supported types:" <+>
                     pretty supportedTypes
      }

    UnsupportedBuiltin target p builtin -> UError $ UserError
      { provenance = p
      , problem    = "Compilation of" <+> squotes (pretty builtin) <+> "to" <+>
                     pretty target <+> "is not currently supported."
      , fix        = Just $ "Try avoiding it, otherwise please open an issue on the" <+>
                     "Vehicle issue tracker."
      }

    UnsupportedInequality target identifier p -> UError $ UserError
      { provenance = p
      , problem    = "After compilation, property" <+> squotes (pretty identifier) <+>
                     "contains a `!=` which is not current supported by" <+>
                     pretty target <> ". See https://github.com/vehicle-lang/vehicle/issues/74" <+>
                     "for details."
      , fix        = Just "not easy, needs fixing upstream in Marabou."
      }

    UnsupportedPolymorphicEquality target p typeName -> UError $ UserError
      { provenance = p
      , problem    = "The use of equality over the unknown type" <+>
                     squotes (pretty typeName) <+> "is not currently supported" <+>
                     "when compiling to" <+> pretty target
      , fix        = Just $ "try avoiding it, otherwise open an issue on the" <+>
                     "Vehicle issue tracker describing the use case."
      }

    UnsupportedNonMagicVariable target p name -> UError $ UserError
      { provenance = p
      , problem    = "The variable" <+> squotes (pretty name) <+> "is not used as" <+>
                     "an input to a network, which is not currently supported" <+>
                     "by" <+> pretty target
      , fix        = Just $ "try reformulating the property, or else open an issue on the" <+>
                     "Vehicle issue tracker describing the use-case."
      }

    NoPropertiesFound -> UError $ UserError
      { provenance = mempty
      , problem    = "No properties found in file."
      , fix        = Just $ "an expression is labelled as a property by giving it type" <+> squotes (pretty Bool) <+> "."
      }

    NoNetworkUsedInProperty target ann ident -> UError $ UserError
      { provenance = provenanceOf ann
      , problem    = "After normalisation, the property" <+>
                     squotes (pretty ident) <+>
                     "does not contain any neural networks and" <+>
                     "therefore" <+> pretty target <+> "is the wrong compilation target"
      , fix        = Just "choose a different compilation target than VNNLib"
      }

unsupportedResourceTypeDescription :: ResourceType -> Identifier -> CheckedExpr -> Doc a
unsupportedResourceTypeDescription resource ident actualType =
  "The type" <+> squotes (prettyFriendlyDBClosed actualType) <+> "of" <+> pretty resource <+>
  squotes (pretty ident) <+> "is not currently supported"

supportedNetworkTypeDescription :: Doc a
supportedNetworkTypeDescription =
  "Only networks of the following types are allowed:" <> line <>
  indent 2 "Tensor Rat [a_1, ..., a_n] -> Tensor Rat [b_1, ..., b_n]" <> line <>
  "where 'a_i' and 'b_i' are all constants."

supportedParameterTypeDescription :: Doc a
supportedParameterTypeDescription =
  "Only parameters of the following types are allowed:" <> line <>
  indent 2 (
    "1." <+> "Bool"    <> line <>
    "2." <+> "Index n" <> line <>
    "3." <+> "Nat"     <> line <>
    "4." <+> "Int"     <> line <>
    "5." <+> "Rat" )

supportedImplicitParameterTypeDescription :: Doc a
supportedImplicitParameterTypeDescription =
  "Only implicit parameters of type 'Nat' are allowed."

unsolvedConstraintError :: Constraint -> [DBBinding] -> Doc a
unsolvedConstraintError constraint ctx ="Typing error: not enough information to solve constraint" <+>
  case constraint of
    UC _ (Unify _)       ->  prettyFriendlyDB ctx constraint
    TC _ (Has _ tc args) ->  prettyFriendlyDB ctx (BuiltinTypeClass mempty tc args)

prettyResource :: ResourceType -> Identifier -> Doc a
prettyResource resourceType ident = pretty resourceType <+> squotes (pretty ident)

prettyBuiltinType :: Builtin -> Doc a
prettyBuiltinType t = article <+> squotes (pretty t)
  where
    article :: Doc a
    article = case t of
      Index -> "an"
      _     -> "a"

prettyExpr :: HasBoundCtx a => a -> CheckedExpr -> Doc b
prettyExpr ctx e = squotes $ prettyFriendlyDB (boundContextOf ctx) e

prettyQuantifierArticle :: Quantifier -> Doc a
prettyQuantifierArticle q =
  (if q == Forall then "a" else "an") <+> squotes (pretty q)

prettyPolarityProvenance :: Quantifier -> PolarityProvenance -> Doc a
prettyPolarityProvenance quantifier = \case
  QuantifierProvenance p ->
    "the" <+> squotes (pretty quantifier) <+> "at" <+> pretty p
  polProv ->
    prettyQuantifierArticle quantifier <+>
    "derived as follows:" <> line <>
    indent 2 (numberedList $ reverse (go quantifier polProv))
  where
    go :: Quantifier -> PolarityProvenance -> [Doc a]
    go q = \case
      QuantifierProvenance p ->
        ["the" <+> squotes (pretty q) <+> "is originally located at" <+> pretty p]
      NegateProvenance p pp ->
        surround p pp ("the" <+> squotes (pretty NotTC))
      LHSImpliesProvenance p pp ->
        surround p pp ("being on the LHS of the" <+> squotes (pretty ImpliesTC))
      EqProvenance eq p pp ->
        surround p pp ("being involved in the" <+> squotes (pretty (EqualsTC eq)))
      where surround p pp x =
              "which is turned into" <+> prettyQuantifierArticle q <+> "by" <+> x <+>
              "at" <+> pretty p : go (neg q) pp

prettyLinearityProvenance :: LinearityProvenance -> Doc a
prettyLinearityProvenance lp =
  line <> indent 2 (numberedList $ reverse (go lp)) <> line
  where
  go :: LinearityProvenance -> [Doc a]
  go = \case
    QuantifiedVariableProvenance p ->
      ["the quantified variable at" <+> pretty p ]
    NetworkOutputProvenance p networkName ->
      ["the output of network" <+> squotes (pretty networkName) <+> "at" <+> pretty p]

prettyAllowedTypes :: [InputExpr] -> Doc b
prettyAllowedTypes allowedTypes = if length allowedTypes == 1
  then squotes (prettyFriendly (head allowedTypes))
  else "one of" <+> prettyFlatList (prettyFriendly <$> allowedTypes)

prettyArgOrdinal :: Int -> Int -> Doc b
prettyArgOrdinal argNo argTotal
  | argTotal == 1 = "the argument"
  | argNo > 9    = "argument" <+> pretty argNo
  | otherwise = "the" <+> (case argNo of
    1 -> "first"
    2 -> "second"
    3 -> "third"
    4 -> "fourth"
    5 -> "fifth"
    6 -> "sixth"
    7 -> "seventh"
    8 -> "eighth"
    9 -> "ninth"
    _ -> developerError "Cannot convert ordinal") <+> "argument"

--------------------------------------------------------------------------------
-- Constraint error messages

failedConstraintError :: [DBBinding]
                      -> Constraint
                      -> UserError
failedConstraintError ctx c@(UC _ (Unify (t1, t2))) = UserError
  { provenance = provenanceOf c
  , problem    = "Type error:" <+>
                    prettyFriendlyDB ctx t1 <+> "!=" <+> prettyFriendlyDB ctx t2
  , fix        = Just "check your types"
  }
failedConstraintError _ TC{} =
  developerError "Type-class constraints should not be thrown here"