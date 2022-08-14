{-# LANGUAGE TemplateHaskell #-}
module Main where

import Prelude (IO, print)
import FFI (hexchar2int)
import Language.Haskell.TH.Syntax (lift)

main :: IO ()
main = print $(lift (hexchar2int 'a'))
