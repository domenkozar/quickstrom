{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

module WTP.Formula.Minimal where

import Algebra.Lattice
import Control.Monad.Freer
import WTP.Assertion
import WTP.Query
import WTP.Result
import Prelude hiding (False, True)
import Algebra.Heyting (Heyting(neg))

type IsQuery eff = Members '[Query] eff

data FormulaWith assertion
  = True
  | Not (FormulaWith assertion)
  | Or (FormulaWith assertion) (FormulaWith assertion)
  | Until (FormulaWith assertion) (FormulaWith assertion)
  | Next (FormulaWith assertion)
  | Assert assertion
  deriving (Show)

type Formula = FormulaWith QueryAssertion

withQueries :: Monad m => (forall a. Eff '[Query] a -> m b) -> Formula -> m [b]
withQueries f = \case
  True -> pure []
  Not p -> withQueries f p
  Next p -> withQueries f p
  Or p q -> (<>) <$> withQueries f p <*> withQueries f q
  Until p q -> (<>) <$> withQueries f p <*> withQueries f q
  Assert (QueryAssertion q _) -> (: []) <$> f q

verifyWith :: (a -> step -> Result) -> FormulaWith a -> [step] -> Result
verifyWith assert = go
  where
    go _ [] = Rejected
    go True _ = Accepted
    go (Not p) trace = neg (go p trace)
    -- go (Next _) [_] = Rejected
    go (Next p) trace = go p (tail trace)
    go (p `Or` q) trace = go p trace \/ go q trace
    go (p `Until` q) trace = go q trace \/ (go p trace /\ go (p `Until` q) (tail trace))
    go (Assert a) (current : _) = assert a current

verify :: Eq a => FormulaWith a -> [a] -> Result
verify = verifyWith $ \a b -> fromBool (a == b)
