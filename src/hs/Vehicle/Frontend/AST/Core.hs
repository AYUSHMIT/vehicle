{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}

module Vehicle.Frontend.AST.Core
  ( Arg(..)
  , LetDecl(..)
  , Expr(..)
  , ExprF(..)
  , Ident(..)
  , Decl(..)
  , Prog(..)
  ) where

import Data.Functor.Foldable.TH (makeBaseFunctor)
import Data.List.NonEmpty (NonEmpty)
import Data.Sequence (Seq)

import Vehicle.Prelude

-- | Type of Vehicle Frontend type-level name-binding sites.
data Arg ann
  = Arg ann Visibility Symbol
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

data Ident ann
  = Ident ann Symbol
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

data LetDecl ann
  = LetDecl
    ann
    (Ident ann) -- Variable name
    (Expr  ann) -- Expression
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | The core Tree structure, parameterised by an annotation type so different
-- types of data can be associated with it's parts.
data Expr ann
  -- Kinds
  = Kind
  | Type     ann
  -- Types
  | Forall   ann (NonEmpty (Expr ann)) (Expr ann)
  | Fun      ann (Expr ann) (Expr ann)
  | Bool     ann
  | Prop     ann
  | Real     ann
  | Int      ann
  | List     ann (Expr ann)
  | Tensor   ann (Expr ann) (Expr ann)
  -- Terms
  | Ann      ann (Expr ann) (Expr ann)
  | App      ann (Expr ann) (Arg ann)
  | Lam      ann (NonEmpty (Arg ann)) (Expr ann)
  | Let      ann (NonEmpty (LetDecl ann)) (Expr ann)
  | Var      ann Symbol
  | Literal  ann Literal
  | If       ann (Expr ann) (Expr ann) (Expr ann)
  | Impl     ann (Expr ann) (Expr ann)
  | And      ann (Expr ann) (Expr ann)
  | Or       ann (Expr ann) (Expr ann)
  | Not      ann (Expr ann)
  | Eq       ann (Expr ann) (Expr ann)
  | Neq      ann (Expr ann) (Expr ann)
  | Le       ann (Expr ann) (Expr ann)
  | Lt       ann (Expr ann) (Expr ann)
  | Ge       ann (Expr ann) (Expr ann)
  | Gt       ann (Expr ann) (Expr ann)
  | Mul      ann (Expr ann) (Expr ann)
  | Div      ann (Expr ann) (Expr ann)
  | Add      ann (Expr ann) (Expr ann)
  | Sub      ann (Expr ann) (Expr ann)
  | Neg      ann (Expr ann)
  | Cons     ann (Expr ann) (Expr ann)
  | At       ann (Expr ann) (Expr ann)
  | All      ann
  | Any      ann
  | Seq      ann [Expr ann]

  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | Type of Vehicle Frontend declaration.
data Decl ann
  = DeclNetw
    ann
    (Ident ann) -- Name of the declared network.
    (Expr  ann) -- Type of the declared network.

  | DeclData
    ann
    (Ident ann) -- Name of the declared dataset.
    (Expr  ann) -- Type of the declared dataset.

  | DefType
    ann
    (Ident ann) -- Name of the type declaration.
    [Arg   ann] -- Args of the type declaration.
    (Expr  ann) -- Body of the type declaration.

  | DefFun
    ann
    (Ident ann) -- Name of the function declaration.
    (Expr  ann) -- Type of the function declaration.
    [Arg   ann] -- Args of the function declaration.
    (Expr  ann) -- Body of the function declaration.

  deriving (Eq, Ord, Show)

-- | Type of Vehicle programs
newtype Prog ann
  = Main [Decl ann] -- Sequence of declarations

  deriving (Eq, Ord, Show)

makeBaseFunctor ''Expr