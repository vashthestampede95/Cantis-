{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}

module Cantis.Env
    ( module Arivi.Env
    ) where

import qualified Crypto.PubKey.Ed25519 as Ed25519

data CantisEnv = AriviEnv
    { cantisEnvCryptoEnv :: CryptoEnv
    , cantisEnvTcpPort   :: Int -- ^ TCP port for new connections
    , cantisEnvUdpPort   :: Int -- ^ UDP port for new connections
    }

data CryptoEnv = CryptoEnv
    { cryptoEnvSecretKey :: Ed25519.SecretKey
    }

class (Monad m) =>
      HasNetworkEnv m
    where
    getEnv :: m AriviEnv

class (HasNetworkEnv m) =>
      HasSecretKey m
    where
    getSecretKey :: m Ed25519.SecretKey
    getSecretKey = cryptoEnvSecretKey . ariviEnvCryptoEnv <$> getEnv

mkAriviEnv :: Int -> Int -> Ed25519.SecretKey -> AriviEnv
mkAriviEnv tcpPort udpPort sk =
    AriviEnv
        { ariviEnvCryptoEnv = CryptoEnv sk
        , ariviEnvTcpPort = tcpPort
        , ariviEnvUdpPort = udpPort
        }
-- makeLensesWith camelCaseFields ''CantisNetworkInstance
-- makeLensesWith camelCaseFields ''CantisEnv
-- makeLensesWith camelCaseFields ''CryptoEnv
-- instance Has CantisNetworkInstance CantisEnv where
--     get = networkInstance
-- instance Has SecretKey CantisEnv where
--     get = cryptoEnv . secretKey
-- instance Has Socket CantisEnv where
--    get = udpSocket
--
