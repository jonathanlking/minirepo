{-# LANGUAGE ForeignFunctionInterface #-}

module FFI where

foreign import ccall safe "OPENSSL_strlcpy"
  f :: ()
