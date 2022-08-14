module Main where

import Prelude (IO, print)
import FFI (hexchar2int)

main :: IO ()
main = print (hexchar2int 'a')
