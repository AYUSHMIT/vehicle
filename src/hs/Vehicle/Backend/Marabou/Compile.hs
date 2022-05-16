module Vehicle.Backend.Marabou.Compile
  ( compile
  ) where

import Control.Monad.Except (MonadError(..))
import Control.Monad (forM)
import Data.Maybe (catMaybes)
import Data.Vector.Unboxed qualified as Vector

import Vehicle.Compile.Prelude
import Vehicle.Compile.Error
import Vehicle.Compile.Normalise (normalise, NormalisationOptions(..), defaultNormalisationOptions)
import Vehicle.Compile.Normalise.UserVariables
import Vehicle.Compile.Normalise.IfElimination (eliminateIfs)
import Vehicle.Compile.Normalise.DNF (convertToDNF, splitDisjunctions)
import Vehicle.Compile.QuantifierAnalysis (checkQuantifiersAndNegateIfNecessary)
import Vehicle.Backend.Prelude
import Vehicle.Backend.Marabou.Core
import Vehicle.Resource.NeuralNetwork
import Vehicle.Compile.Linearity

--------------------------------------------------------------------------------
-- Compilation to Marabou

-- | Compiles the provided program to Marabou queries.
compile :: MonadCompile m => NetworkCtx -> CheckedProg -> m [MarabouProperty]
compile networkCtx prog = logCompilerPass "compilation to Marabou" $
  compileProg networkCtx prog

--------------------------------------------------------------------------------
-- Algorithm

compileProg :: MonadCompile m => NetworkCtx -> CheckedProg -> m [MarabouProperty]
compileProg networkCtx (Main ds) = do
  results <- catMaybes <$> traverse (compileDecl networkCtx) ds
  if null results then
    throwError NoPropertiesFound
  else
    return results

compileDecl :: MonadCompile m => NetworkCtx -> CheckedDecl -> m (Maybe MarabouProperty)
compileDecl networkCtx d = case d of
  DefResource _ r _ _ -> normalisationError currentPass (pretty r <+> "declarations")

  DefFunction _p _ ident t expr ->
    if not $ isProperty t
      -- If it's not a property then we can discard it as all applications
      -- of it should have been normalised out by now.
      then return Nothing
      else Just <$> compileProperty ident networkCtx expr

compileProperty :: MonadCompile m
                => Identifier
                -> NetworkCtx
                -> CheckedExpr
                -> m MarabouProperty
compileProperty ident networkCtx expr =
  logCompilerPass ("property" <+> squotes (pretty ident)) $ do

    -- Check that we only have one type of quantifier in the property
    -- and if it is universal then negate the property
    (isPropertyNegated, possiblyNegatedExpr) <-
      checkQuantifiersAndNegateIfNecessary MarabouBackend ident expr

    -- Normalise the expression to push through the negation.
    normExpr <- normalise (defaultNormalisationOptions
      { implicationsToDisjunctions = True
      , subtractionToAddition      = True
      , expandOutPolynomials       = True
      }) possiblyNegatedExpr

    -- Eliminate any if-expressions
    ifFreeExpr <- eliminateIfs normExpr

    -- Normalise again to push through the introduced nots. Can definitely be
    -- more efficient here and just push in the not, when we introduce
    -- it during if elimination.
    normExpr2 <- normalise (defaultNormalisationOptions
      { implicationsToDisjunctions = True
      , subtractionToAddition      = True
      , expandOutPolynomials       = True
      }) ifFreeExpr

    -- Convert to disjunctive normal form
    dnfExpr <- convertToDNF normExpr2

    -- Split up into the individual queries needed for Marabou.
    let queryExprs = splitDisjunctions dnfExpr
    let numberOfQueries = length queryExprs
    logDebug MinDetail $ "Found" <+> pretty numberOfQueries <+> "queries" <> line

    -- Compile the individual queries
    let compileQ = compileQuery ident networkCtx
    queries <- traverse compileQ (zip [1..] queryExprs)

    return $ MarabouProperty (nameOf ident) isPropertyNegated queries

compileQuery :: MonadCompile m
             => Identifier
             -> NetworkCtx
             -> (Int, CheckedExpr)
             -> m MarabouQuery
compileQuery ident networkCtx (queryId, expr) =
  logCompilerPass ("query" <+> pretty queryId) $ do

    -- Convert all user varaibles and applications of networks into magic I/O variables
    (CLSTProblem varNames assertions, metaNetwork) <-
      normUserVariables ident Marabou networkCtx expr

    (vars, doc) <- logCompilerPass "compiling assertions" $ do
      let vars = fmap (`MarabouVar` MReal) varNames
      assertionDocs <- forM assertions (compileAssertion varNames)
      let assertionsDoc = vsep assertionDocs
      logCompilerPassOutput assertionsDoc
      return (vars, assertionsDoc)

    return $ MarabouQuery doc vars metaNetwork


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
    compileRel _     Equals            = "="
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