{-# LANGUAGE ForeignFunctionInterface #-}

module FFI where

import Prelude (Integer, Char, toInteger, fromIntegral, (.))
import Data.Char (ord)
import Foreign.C.Types (CChar(..), CInt(..))

-- int OPENSSL_hexchar2int(unsigned char c);
foreign import ccall safe "OPENSSL_hexchar2int"
  c_hexchar2int :: CChar -> CInt

hexchar2int :: Char -> Integer
hexchar2int = toInteger . c_hexchar2int . fromIntegral . ord
