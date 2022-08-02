module Test where

import Test.Tasty
import Control.Monad.Reader (runReader)
import GHC.IO.Encoding
import System.Environment

import Test.Compile.Golden as Compile (goldenTests)
import Test.Compile.Unit as Compile (unitTests)
import Test.Compile.Error as Compile (errorTests)
import Test.Check.Golden as Check (goldenTests)
import Test.Verify.Golden as Verify (goldenTests)
import Test.FilePathUtils (filepathTests)
import Test.Compile.Utils (MonadTest)

-- Can't figure out how to get this passed in via the command-line *sadness*
testLogLevel :: Int
testLogLevel = 0

main :: IO ()
main = do
  setLocaleEncoding utf8
  defaultMain (runReader tests testLogLevel)

tests :: MonadTest m => m TestTree
tests = do
  compTests <- compileTests
  return $ localOption (mkTimeout 100000000) $ testGroup "Tests"
    [ compTests
    , checkTests
    -- , verifyTests
    , miscTests
    ]

compileTests :: MonadTest m => m TestTree
compileTests = testGroup "Compile" <$> sequence
  [ Compile.goldenTests
  , Compile.unitTests
  , Compile.errorTests
  ]

verifyTests :: TestTree
verifyTests = testGroup "Verify"
  [ Verify.goldenTests
  ]

checkTests :: TestTree
checkTests = testGroup "Check"
  [ Check.goldenTests
  ]

miscTests :: TestTree
miscTests = testGroup "Misc"
  [ filepathTests
  ]