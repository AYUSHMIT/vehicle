-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Vehicle.Data.Tensor
open import Data.Nat as ℕ using (ℕ)
open import Data.List

module simple-vectorType-temp-output where

Vector : Set → (ℕ → Set)
Vector A n = Tensor A (n ∷ [])

vec : Vector ℕ 2
vec = 0 ∷ (1 ∷ [])