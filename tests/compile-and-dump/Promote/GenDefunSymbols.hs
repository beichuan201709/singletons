module Promote.GenDefunSymbols where

import Data.Singletons (Apply, TyFun)
import Data.Singletons.SuppressUnusedWarnings
import Data.Singletons.TH (genDefunSymbols)
import GHC.TypeLits hiding (type (*))
import Data.Kind (Type)

type family LiftMaybe (f :: TyFun a b -> Type) (x :: Maybe a) :: Maybe b where
    LiftMaybe f Nothing = Nothing
    LiftMaybe f (Just a) = Just (Apply f a)

data NatT = Zero | Succ NatT

type a :+ b = a + b

$(genDefunSymbols [ ''LiftMaybe, ''NatT, ''(:+) ])
