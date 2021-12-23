-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Vehicle.Data.Tensor
open import Data.Product
open import Data.Integer as ℤ using (ℤ)
open import Data.Rational as ℚ using (ℚ)
open import Data.Fin as Fin using (#_)
open import Data.List
open import Relation.Binary.PropositionalEquality

module reachability-output where

private
  VEHICLE_PROJECT_FILE = "TODO_projectFile"

f : Tensor ℚ (2 ∷ []) → Tensor ℚ (1 ∷ [])
f = evaluate record
  { projectFile = VEHICLE_PROJECT_FILE
  ; networkUUID = "TODO_networkUUID"
  }

abstract
  reachable : ∃ λ (x : Tensor ℚ (2 ∷ [])) → f x (# 0) ≡ ℤ.+ 0 ℚ./ 1
  reachable = checkProperty record
    { projectFile  = VEHICLE_PROJECT_FILE
    ; propertyUUID = "TODO_propertyUUID"
    }