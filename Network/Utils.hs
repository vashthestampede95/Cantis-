module Cantis.Network.Utils
(
    lazyToStrict
    , strictToLazy
    , getIPAddress
    , getPortNumber
)where 
import           Data.ByteString      (ByteString)
import qualified Data.ByteString.Lazy as Lazy (ByteString, fromStrict, toStrict)
import           Network.Socket       (HostName, PortNumber, SockAddr (..),
                                       inet_ntoa)
lazytoStrict::Lazy.ByteString->ByteString
lazytoStrict=Lazy.toStrict

stricttolazy::ByteString->Lazy.ByteString
stricttolazy=Lazy.fromStrict

getIPAddress::SockAddr->IO Hostname
getIPAddress (SockAddrInet _ hostAddress) = inet_ntoa hostAddress
getIPAddress (SockAddrInet6 _ _ (_, _, _, hA6) _) = inet_ntoa hA6
getIPAddress _ =
    error "getIPAddress: SockAddr is not of constructor SockAddrInet "

-- | Given `SockAddr` retrieves `PortNumber`
getPortNumber :: SockAddr -> PortNumber
getPortNumber (SockAddrInet portNumber _) = portNumber
getPortNumber (SockAddrInet6 portNumber _ _ _) = portNumber
getPortNumber _ =
    error "getPortNumber: SockAddr is not of constructor SockAddrInet "

