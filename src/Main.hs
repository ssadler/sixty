{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Protolude hiding (force)

import qualified Text.Parsix as Parsix

import qualified Context
import qualified Elaboration
import qualified Evaluation
import Index
import Monad
import qualified Parser

main :: IO ()
main = do
  [inputString] <- getArgs
  parseAndTypeCheck inputString

parseAndTypeCheck :: StringConv s Text => s -> IO ()
parseAndTypeCheck inputString =
  case Parser.parseText Parser.term (toS inputString) "<command-line>" of
    Parsix.Success preTerm -> do
      Elaboration.Inferred term typeValue <- Elaboration.infer Context.empty preTerm
      print term
      typeValue' <- force typeValue
      type_ <- Evaluation.readBack Zero typeValue'
      print type_
    Parsix.Failure err -> do
      putText "Parse error"
      print $ Parsix.prettyError err
