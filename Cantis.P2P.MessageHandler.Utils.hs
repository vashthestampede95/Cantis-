{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Cantis.P2P.MessageHandler.Utils
    ( module Arivi.P2P.MessageHandler.Utils
    ) where

import           Cantis.Network                         (AriviNetworkException (..), ConnectionHandle (..), TransportType (..), openConnection)
import           Cantis.P2P.MessageHandler.HandlerTypes hiding (uuid)
import           Cantis.P2P.P2PEnv
import           Cantis.P2P.Types
import           Cantis.P2P.Exception
import           Cantis.Utils.Logging

import           Control.Concurrent.MVar
import           Control.Concurrent.STM
import           Codec.Serialise                       (DeserialiseFailure)
import           Control.Monad.Logger
import           Data.HashMap.Strict                   as HM
import           Data.String.Conv
import qualified Data.UUID                             as UUID (toString)
import           Data.UUID.V4                          (nextRandom)
import           Control.Lens

logWithNodeID :: (HasLogging m) => NodeId -> String -> m ()
logWithNodeID peerNodeID logLine = $ (logDebug) $ toS $ logline ++ show peerNodeID

getNodeID :: TVar PeerDetails ->  IO NodeID
getNodeID peerdetailsTvar = (^.networkconfig.nodeID) <$> readTVarIO peerdetailsTvar
 
--wraps the payload with message type { Kademlia | Rpc | PubSub} and UUID
generateP2PMessage :: Maybe P2PUUID -> MessageType -> P2PPayload -> P2PMessage
generateP2PMessage = P2PMessage 

inserttoUUIDMap :: P2PUUID -> MVar P2PMessage -> PeerDetails -> PeerDetails
inserttoUUIDMap uuid mvar peerDetails= peerDetails & uuidMap.at uuid ?~ mvar

deletefromUUIDMap:: P2PUUID -> PeerDetails ->PeerDetails
deletefromUUIDMap uuid peerdetails=peerdetails & uuidMap %~ HM.delete uuid

getHandlerByMessageType :: P2PUUID -> TransportType -> Handle
getHandlerByMessageType peerdetails TCP= peerdetails ^.streamHandle
getHandlerByMessageType peerdetails UDP= peerdetails ^.datagramHandle

getTransportType :: MessageType -> TransportType
getTransportType  Rpc =TCP
getTransportTypr   _  =UDP

networkToP2PException :: Either CantisNetworkException a -> Either CantisP2PException 
networkToP2PException (Left a)=Left (NetworkException e)
networkToP2PException (Right a)=Right a

--Wrapper Around Open Connection 
openconnectiontoPeer :: (HasNodeEndpoint m,HasLogging m) => NetworkConfig ->TransportType -> m (Either CantisNetworkException ConnectionHandle )
openconnectiontoPeer = openConnection 

safeDeserialise :: Either DeserialiseFailure a -> Either CantisNetworkException a
safeDeserialise (Left _)= Left DeserialiseFailureP2P
safeDeserialise (Right a)= Right a

checkConnection :: PeerDetails -> TransportType -> Handle
checkConnection peerDetails TCP =peerdetails^.streamHandle
checkConnection peerDetails UDP =peerdetails^.datagramHandle

--Get a random Unique ID 
getUUId :: IO P2PUUID
getUUId =UUID.toString<$>nextRandom

doesPeerExist :: TVar NodeIdPeerMap -> Node -> IO Bool
doesPeerExist nodeIdPeerTVar peerNodeId =
    HM.member peerNodeId <$> readTVarIO nodeIdPeerTVar

mkPeer :: NetworkConfig -> TransportType -> Handle -> STM (TVar PeerDetails) 
mkPeer nc transporttype connhandle = do 
    lock <- newTMVar True
    let peerDetails=
        PeerDetails 
        { _networkConfig = nc 
         ,_rep= 0.0
         ,_streamHandle = 
            case transporttype of 
                TCP -> connHandle
                UDP -> NotConnected
         ,_datagramHandle=
            case transporttype of 
                TCP <- NotConnected 
                UDO <- connHandle
         ,_uuidMap= HM.empty 
         ,_connectionLock = lock        
        }  
    newTvar peerDetails
 
-- | Adds new peer passed details
-- | Assume we get IP and portNumber as well.
-- | Need to discuss if its really needed to store IP and port in case that the node is the recipient of the handshake

addnewPeer :: NodeId -> TVar PeerDetails -> TVar PeerDetails -> STM ()
addnewPeer  peernodeId  peerDetailsTVar nodeIdMapTVar = modifyTVar ' nodeIdMapTVar (HM.insert peerNodeId peerDetailsTVar)

-- | Updates the NodeIdPeerMap with the passed details
-- | Need to discuss if its really needed to store IP and port in case that the node is the recipient of the handshake
    updatePeer ::
    TransportType
 -> Handle
 -> TVar PeerDetails
 -> STM ()
updatePeer transportType connHandle peerDetailsTVar =
 modifyTVar' peerDetailsTVar updateConnHandle
 where
     updateConnHandle peerDetails =
         if transportType == TCP then
             peerDetails & streamHandle .~ connHandle
         else peerDetails & datagramHandle .~ connHandle


-- | Create an entry in the nodeIdPeerDetails map with the given NetworkConfig and transportType 
addPeerToMap :: 
    NetworkConfig
 -> TransportType
 -> TVar NodeIdPeerMap
 -> STM ()
addPeerToMap nc transportType nodeIdMapTVar = do 
 peerDetailsTVar <- mkPeer nc transportType NotConnected
 addNewPeer (nc ^. nodeId) peerDetailsTVar nodeIdMapTVar




