module Vehicle.Backend.Marabou.Compile
  ( compile
  ) where

import Control.Monad.Except (MonadError(..))
import Control.Monad (forM)
import Data.Maybe (catMaybes)
import Data.Map qualified as Map (lookup)
import Data.Vector.Unboxed qualified as Vector

import Vehicle.Compile.Prelude
import Vehicle.Compile.Error
import Vehicle.Compile.Normalise.UserVariables
import Vehicle.Compile.Normalise.IfElimination (eliminateIfs)
import Vehicle.Compile.Normalise.DNF (convertToDNF, splitDisjunctions)
import Vehicle.Compile.QuantifierAnalysis (checkQuantifiersAndNegateIfNecessary)
import Vehicle.Backend.Prelude
import Vehicle.Backend.Marabou.Core
import Vehicle.Compile.Resource
import Vehicle.Compile.Linearity
import Vehicle.Compile.Normalise
import Control.Monad.Reader (MonadReader, asks, ReaderT (..))

--------------------------------------------------------------------------------
-- Compatibility

checkCompatibility :: DeclProvenance -> PropertyInfo -> Maybe CompileError
checkCompatibility decl (PropertyInfo linearity polarity) =
  case (linearity, polarity) of
    (NonLinear p pp1 pp2, _)       ->
      Just $ UnsupportedNonLinearConstraint MarabouBackend decl p pp1 pp2
    (_, MixedSequential q p pp2) ->
      Just $ UnsupportedAlternatingQuantifiers MarabouBackend decl q p pp2
    _ -> Nothing

--------------------------------------------------------------------------------
-- Compilation to Marabou

-- | Compiles the provided program to Marabou queries.
compile :: MonadCompile m
        => CheckedProg
        -> PropertyContext
        -> NetworkContext
        -> m [(Symbol, MarabouProperty)]
compile prog propertyCtx networkCtx = logCompilerPass MinDetail "compilation to Marabou" $ do
  normProg <- normalise prog fullNormalisationOptions
  results <- runReaderT (compileProg networkCtx normProg) propertyCtx
  if null results then
    throwError NoPropertiesFound
  else
    return results

--------------------------------------------------------------------------------
-- Monad

type MonadCompileMarabou m =
  ( MonadCompile m
  , MonadReader PropertyContext m
  )

--------------------------------------------------------------------------------
-- Algorithm


compileProg :: MonadCompileMarabou m => NetworkContext -> CheckedProg -> m [(Symbol, MarabouProperty)]
compileProg networkCtx (Main ds) = catMaybes <$> traverse (compileDecl networkCtx) ds

compileDecl :: MonadCompileMarabou m => NetworkContext -> CheckedDecl -> m (Maybe (Symbol, MarabouProperty))
compileDecl networkCtx d = case d of
  DefResource _ r _ _ ->
    normalisationError currentPass (pretty r <+> "declarations")

  DefPostulate{} ->
    normalisationError currentPass "postulates"

  DefFunction p ident _ expr -> do
    maybePropertyInfo <- asks (Map.lookup ident)
    case maybePropertyInfo of
      -- If it's not a property then we can discard it as all applications
      -- of it should have been normalised out by now.
      Nothing -> return Nothing
      -- Otherwise check the property information.
      Just propertyInfo -> case checkCompatibility (ident, p) propertyInfo of
        Just err -> throwError err
        Nothing -> do
          property <- compileProperty ident networkCtx expr
          return (Just (nameOf ident, property))

compileProperty :: MonadCompile m
                => Identifier
                -> NetworkContext
                -> CheckedExpr
                -> m MarabouProperty
compileProperty ident networkCtx = \case
  VecLiteral _ _ es ->
    MultiProperty <$> traverse (compileProperty ident networkCtx) es

  expr -> logCompilerPass MinDetail ("property" <+> squotes (pretty ident)) $ do

    -- Check that we only have one type of quantifier in the property
    -- and if it is universal then negate the property
    (isPropertyNegated, possiblyNegatedExpr) <-
      checkQuantifiersAndNegateIfNecessary MarabouBackend ident expr

    -- Eliminate any if-expressions
    ifFreeExpr <- eliminateIfs possiblyNegatedExpr

    -- Convert to disjunctive normal form
    dnfExpr <- convertToDNF ifFreeExpr

    -- Split up into the individual queries needed for Marabou.
    let queryExprs = splitDisjunctions dnfExpr
    let numberOfQueries = length queryExprs
    logDebug MinDetail $ "Found" <+> pretty numberOfQueries <+> "queries" <> line

    -- Compile the individual queries
    let compileQ = compileQuery ident networkCtx
    queries <- traverse compileQ (zip [1..] queryExprs)

    let result = disjunctPropertyStates queries
    return $ SingleProperty isPropertyNegated result

-- Returns `Nothing` for trivially false, `Just Nothing` for trivially true and `Just Just` otherwise.
compileQuery :: MonadCompile m
             => Identifier
             -> NetworkContext
             -> (Int, CheckedExpr)
             -> m (PropertyState MarabouQuery)
compileQuery ident networkCtx (queryId, expr) =
  logCompilerPass MinDetail ("query" <+> pretty queryId) $ do

    -- Convert all user variables and applications of networks into magic I/O variables
    result <- normUserVariables ident Marabou networkCtx expr

    traversePropertyState result $
      \(CLSTProblem varNames assertions, metaNetwork, userVarReconstruction) -> do
        (vars, doc) <- logCompilerPass MinDetail "compiling assertions" $ do
          assertionDocs <- forM assertions (compileAssertion varNames)
          let assertionsDoc = vsep assertionDocs
          logCompilerPassOutput assertionsDoc
          return (varNames, assertionsDoc)

        return $ MarabouQuery doc vars metaNetwork userVarReconstruction


compileAssertion :: MonadCompile m
                 => VariableNames
                 -> Assertion
                 -> m (Doc a)
compileAssertion varNames (Assertion rel linearExpr) = do
  let (coefficientsVec, constant) = splitOutConstant linearExpr
  let coefficients = Vector.toList coefficientsVec
  let allCoeffVars = zip coefficients varNames
  let coeffVars = filter (\(c,_) -> c /= 0) allCoeffVars

  -- Make the properties a tiny bit nicer by checking if all the vars are
  -- negative and if so negating everything.
  let allCoefficientsNegative = all (\(c,_) -> c < 0) coeffVars
  let (finalCoefVars, constant', flipRel) = if allCoefficientsNegative
        then (fmap (\(c,n) -> (-c,n)) coeffVars, -constant, True)
        else (coeffVars, constant, False)

  -- Marabou always has the constants on the RHS so we need to negate the constant.
  let negatedConstant = -constant'
  -- Also check for and remove `-0.0`s for cleanliness.
  let finalConstant = if isNegativeZero negatedConstant then 0.0 else negatedConstant

  let compiledRel = compileRel flipRel rel
  let compiledLHS = hsep (fmap (compileVar (length finalCoefVars > 1)) finalCoefVars)
  let compiledRHS = pretty finalConstant
  return $ compiledLHS <+> compiledRel <+> compiledRHS
  where
    compileRel :: Bool -> Relation -> Doc a
    compileRel _     Equal             = "="
    compileRel False LessThanOrEqualTo = "<="
    compileRel True  LessThanOrEqualTo = ">="
    -- Suboptimal. Marabou doesn't currently support strict inequalities.
    -- See https://github.com/vehicle-lang/vehicle/issues/74 for details.
    compileRel False LessThan          = "<="
    compileRel True  LessThan          = ">="

    compileVar :: Bool -> (Double, Symbol) -> Doc a
    compileVar False (1,           var) = pretty var
    compileVar True  (1,           var) = "+" <> pretty var
    compileVar _     (-1,          var) = "-" <> pretty var
    compileVar _     (coefficient, var) = pretty coefficient <> pretty var

currentPass :: Doc a
currentPass = "compilation to Marabou"