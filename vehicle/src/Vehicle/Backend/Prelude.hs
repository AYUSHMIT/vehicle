module Vehicle.Backend.Prelude where

import Control.Monad.IO.Class
import Data.Maybe (catMaybes)
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Vehicle.Prelude
import Vehicle.Verify.Core

--------------------------------------------------------------------------------
-- Differentiable logics

-- | Different ways of translating from the logical constraints to loss functions.
data DifferentiableLogicID
  = VehicleLoss
  | DL2Loss
  | GodelLoss
  | LukasiewiczLoss
  | ProductLoss
  | YagerLoss
  | STLLoss
  deriving (Eq, Show, Read, Bounded, Enum)

instance Pretty DifferentiableLogicID where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Interactive theorem provers

data ITP
  = Agda
  deriving (Eq, Show, Read, Bounded, Enum)

instance Pretty ITP where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Different type-checking modes

data TypingSystem
  = Standard
  | Polarity
  | Linearity
  deriving (Eq, Show, Bounded, Enum)

instance Read TypingSystem where
  readsPrec _d x = case x of
    "Standard" -> [(Standard, [])]
    "Linearity" -> [(Linearity, [])]
    "Polarity" -> [(Polarity, [])]
    _ -> []

--------------------------------------------------------------------------------
-- Action

data Target
  = ITP ITP
  | VerifierQueries QueryFormatID
  | LossFunction DifferentiableLogicID
  | ExplicitVehicle
  deriving (Eq)

findTarget :: String -> Maybe Target
findTarget s = do
  let itp = lookup s (fmap (\t -> (show t, ITP t)) (enumerate @ITP))
  let queries = lookup s (fmap (\t -> (show t, VerifierQueries t)) (enumerate @QueryFormatID))
  let dl = lookup s (fmap (\t -> (show t, LossFunction t)) (enumerate @DifferentiableLogicID))
  let json = if s == show ExplicitVehicle then Just ExplicitVehicle else Nothing
  catMaybes [itp, queries, dl, json] !!? 0

instance Show Target where
  show = \case
    ITP x -> show x
    VerifierQueries x -> show x
    LossFunction x -> show x
    ExplicitVehicle -> "Explicit"

instance Pretty Target where
  pretty = \case
    ITP x -> pretty x
    VerifierQueries x -> pretty x
    LossFunction x -> pretty x
    ExplicitVehicle -> pretty $ show ExplicitVehicle

-- | Generate the file header given the token used to start comments in the
--  target language
prependfileHeader :: Doc a -> Maybe ExternalOutputFormat -> Doc a
prependfileHeader doc format = case format of
  Nothing -> doc
  Just ExternalOutputFormat {..} ->
    vsep
      ( map
          (commentToken <+>)
          [ "WARNING: This file was generated automatically by Vehicle",
            "and should not be modified manually!",
            "Metadata:",
            " -" <+> formatName <> " version:" <+> targetVersion,
            " - Vehicle version:" <+> pretty impreciseVehicleVersion
          ]
      )
      <> line
      -- Marabou query format doesn't current support empty lines.
      -- See https://github.com/NeuralNetworkVerification/Marabou/issues/625
      <> (if emptyLines then line else "")
      <> doc
    where
      targetVersion = maybe "unknown" pretty formatVersion

writeResultToFile ::
  (MonadIO m, MonadLogger m) =>
  Maybe ExternalOutputFormat ->
  Maybe FilePath ->
  Doc a ->
  m ()
writeResultToFile target filepath doc = do
  logDebug MaxDetail $ "Creating file:" <+> pretty filepath
  let text = layoutAsText $ prependfileHeader doc target
  liftIO $ case filepath of
    Nothing -> TIO.putStrLn text
    Just outputFilePath -> do
      createDirectoryIfMissing True (takeDirectory outputFilePath)
      TIO.writeFile outputFilePath text
