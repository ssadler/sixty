module Presyntax where

import Protolude

type Var = Text

data Term
  = Var !Var
  | Let !Var !Term !Term
  | Pi !Var !Term !Term
  | Fun !Term !Term
  | Lam !Var !Term
  | App !Term !Term
  deriving Show

apps :: Foldable f => Term -> f Term -> Term
apps = foldl App