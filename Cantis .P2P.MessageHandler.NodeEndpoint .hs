{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}

module Cantis.P2P.MessageHandler.NodeEndpoint (
    issueRequest
    ,issuesend
    ,issueKademiliaRequest
)where 

import           Cantis.Network                         (AriviNetworkException,ConnectionHandle (..),TransportType (..))
import           Cantis.P2P.Exception
import           Cantis.P2P.MessageHandler.HandlerTypes hiding (messageType, uuid, payload)
import           Cantis.P2P.MessageHandler.Utils
import           Cantis.P2P.P2PEnv
import           Cantis.P2P.Types
import           Cantis.Utils.Logging
import           Cantis.Network.Types                   hiding (NodeId)
import           Cantis.P2P.Connection

import           Codec.Serialise
import           Control.Concurrent                    (threadDelay)
import qualified Control.Concurrent.Async              as Async (race)
import           Control.Concurrent.MVar
import           Control.Concurrent.STM
import qualified Control.Exception.Lifted              as LE (try)
import           Control.Monad.IO.Class                (liftIO)
import           Control.Monad.Logger
import           Control.Lens
import           Data.Proxy
import           Control.Monad.Except

sendwithoutUUID :: (HasNodeEndpoint m,HasLogging m )=> NodeId -> MessageType ->Maybe P2PUUID -> Connection Handle -> P2PPayload -> m(Either CantisP2PException ())
sendwithoutUUID peerNodeID  messageType uuid connHandle payload = do
    let p2pMessage =generatep2pmessage uuid messagetype payload 
    res <- LE.try(send connHandle (serialise p2pMessage )) 
     case res of 
        Left (e::CantisNetworkException )-> do
            logWithNodeId peerNodeId "network end failed from sendwithoutUUID for"
            return (Left $NetworkException e)
            Right a ->return (Right a)

sendandreceive :: (HasNodeEndpoint m,HasLogging m) => TVar PeerDetails -> MessageType ->ConnectionHandle -> P2PPayload -> m(Either CantisP2PException P2PPayload )
sendandreceive peerDetailsTVar messageType connHandle msg = do 
    uuid <-liftIO getUUID 
    mvar <-liftIO newEmptyMVar
    liftIO $ atomically $ modifyTVar' peerDetailsTVar (inserttoUUID uuid mvar)
    let p2pMessage =generateP2PMessage (Just uuid ) messageType msg 
    res<-networkToP2PException <$> LE.try (send connHandle (serialise p2pMessage))
    case res of
        Left e -> do
            liftIO $ atomically $ modifyTVar' peerDetailsTVar (deletefromUUID uuid)
            return (Left e)
        Right e->do
            winner <-liftIO $ Async.race(threadDelay 300000)(takeMVar mvar :: IO P2PMessage )
            case winner of 
                Left _->$(logDebug )"response timed out ">> return (Left SendMessageTimeout)
                Right (P2PMessage _ _ payl)->return (Right payl)

-- | Send a message without waiting for any response or registering a uuid.
-- | Useful for pubsub notifies and publish. To be called by the rpc/pubsub and kademlia handlers on getting a new request
issueSend ::
       forall env m r topic rmsg pmsg t i.
       (HasP2PEnv env m r topic rmsg pmsg, Msg t, Serialise (Request t i))
    => NodeId
    -> Maybe P2PUUID
    -> Request t i
    -> ExceptT AriviP2PException m ()
issueSend peerNodeId uuid req = do
    nodeIdMapTVar <- lift getNodeIdPeerMapTVarP2PEnv
    connHandle <- ExceptT $ getConnectionHandle peerNodeId nodeIdMapTVar (getTransportType $ msgType (Proxy :: Proxy (Request t i)))
    ExceptT $ sendWithoutUUID peerNodeId (msgType (Proxy :: Proxy (Request t i))) uuid connHandle (serialise req)

-- | Sends a request and gets a response. Should be catching all the exceptions thrown and handle them correctly
issueRequest ::
       forall env m r topic rmsg pmsg i o t.
       ( HasP2PEnv env m r topic rmsg pmsg
       , Msg t
       , Serialise (Request t i)
       , Serialise (Response t o)
       )
    => NodeId
    -> Request t i
    -> ExceptT AriviP2PException m (Response t o)
issueRequest peerNodeId req = do
    nodeIdMapTVar <- lift getNodeIdPeerMapTVarP2PEnv
    nodeIdPeerMap <- liftIO $ readTVarIO nodeIdMapTVar
    connHandle <- ExceptT $ getConnectionHandle peerNodeId nodeIdMapTVar (getTransportType $ msgType (Proxy :: Proxy (Request t i)))
    peerDetailsTVar <- maybe (throwError PeerNotFound) return (nodeIdPeerMap ^.at peerNodeId)
    resp <- ExceptT $ sendAndReceive peerDetailsTVar (msgType (Proxy :: Proxy (Request t i))) connHandle (serialise req)
    ExceptT $ (return . safeDeserialise . deserialiseOrFail) resp

-- | Called by kademlia. Adds a default PeerDetails record into hashmap before calling generic issueRequest
issueKademliaRequest :: (HasP2PEnv env m r t rmsg pmsg, Serialise msg)
    => NetworkConfig
    -> Request 'Kademlia msg
    -> ExceptT AriviP2PException m (Response 'Kademlia msg)
issueKademliaRequest nc payload = do
    nodeIdMapTVar <- lift getNodeIdPeerMapTVarP2PEnv
    peerExists <- (lift . liftIO) $ doesPeerExist nodeIdMapTVar (nc ^. nodeId)
    if peerExists
        then issueRequest (nc ^. nodeId) payload
        else (do (lift . liftIO) $
                     atomically $ addPeerToMap nc UDP nodeIdMapTVar
                 issueRequest (nc ^. nodeId) payload)





