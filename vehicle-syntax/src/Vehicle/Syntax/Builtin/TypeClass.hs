module Vehicle.Syntax.Builtin.TypeClass where

import Control.DeepSeq (NFData (..))
import Data.Hashable (Hashable (..))
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Prettyprinter (Pretty (..), (<+>))
import Vehicle.Syntax.Builtin.BasicOperations

--------------------------------------------------------------------------------
-- Type classes

data TypeClass
  = -- Operation type-classes
    HasEq EqualityOp
  | HasOrd OrderOp
  | HasQuantifier Quantifier
  | HasAdd
  | HasSub
  | HasMul
  | HasDiv
  | HasNeg
  | HasFold
  | HasMap
  | HasQuantifierIn Quantifier
  | -- Literal type-classes
    HasNatLits
  | HasRatLits
  | HasVecLits
  deriving (Eq, Ord, Generic, Show)

instance NFData TypeClass

instance Hashable TypeClass

instance Serialize TypeClass

instance Pretty TypeClass where
  pretty = \case
    HasEq {} -> "HasEq"
    HasOrd {} -> "HasOrd"
    HasQuantifier q -> "HasQuantifier" <+> pretty q
    HasQuantifierIn q -> "HasQuantifierIn" <+> pretty q
    HasAdd -> "HasAdd"
    HasSub -> "HasSub"
    HasMul -> "HasMul"
    HasDiv -> "HasDiv"
    HasNeg -> "HasNeg"
    HasMap -> "HasMap"
    HasFold -> "HasFold"
    HasNatLits -> "HasNatLiterals"
    HasRatLits -> "HasRatLiterals"
    HasVecLits -> "HasVecLiterals"

-- Builtin operations for type-classes
data TypeClassOp
  = FromNatTC
  | FromRatTC
  | FromVecTC
  | NegTC
  | AddTC
  | SubTC
  | MulTC
  | DivTC
  | EqualsTC EqualityOp
  | OrderTC OrderOp
  | MapTC
  | FoldTC
  | QuantifierTC Quantifier
  deriving (Eq, Ord, Generic, Show)

instance NFData TypeClassOp

instance Hashable TypeClassOp

instance Serialize TypeClassOp

instance Pretty TypeClassOp where
  pretty = \case
    NegTC -> "-"
    AddTC -> "+"
    SubTC -> "-"
    MulTC -> "*"
    DivTC -> "/"
    FromNatTC -> "fromNat"
    FromRatTC -> "fromRat"
    FromVecTC -> "fromVec"
    EqualsTC op -> pretty op
    OrderTC op -> pretty op
    MapTC -> "map"
    FoldTC -> "fold"
    QuantifierTC q -> pretty q
