{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- This module provides the p2p instance by sending FIND_NODE request 
-- to the default nodes which are read from a config file and are called bootstrap nodes in response 
-- it recieves a list of peer close to it  where closeness is defined by the XOR metric and agian issues 
-- to the peers recieved 

module Cantis.P2P.Kademlia.LoadDefaultPeers 
(
    loadDefaultPeers
    ,deleteIfPeerExists
    ,ifPeerExists
    ,getPeerListFromPayload

)where 
     
import             Cantis.P2P.Exception 
import             Cantis.P2P.Kademlia.Kbucket
import             Cantis.P2P.Kademlia.RunConcurrently  
import             Cantis.P2P.Kademlia.Types 
import             Cantis.P2P.MessageHandler.HandlerTypes
import             Cantis.P2P.MessageHandler.NodeEndpoint (issueKademliaRequest)
import             Cantis.P2P.P2PEnv 
import             Cantis.P2P.Types
import             Control.Exception                       (displayException)
import             Control.Lens 
import             Control.Monad.Except
import             Control.Monad.Logger 
import             Control.Monad.Reader 
import  qualified  Data.Text                 as       T

-- |  Sends FIND_NODE to bootstrap nodes and requires a P2P instance to get
--   local node information which are passed to P2P environment during
--   P2P instance initialization.
--   to Bootstrap 

loadDefaultPeers :: (HasP2PEnv env m r t rmsg pmsg) => [Peer] -> m()
loadDefaultPeers = runKademliaActionConcurrently_ issueFindNode 

-- | Helper Function to retrive Peer List from PayLoad 
getPeerListFromPayload :: Payload -> Either CantisP2PException [Peer]
getPeerLsitFromPayload payload =
    let msg = message payload 
        msgb= messageBody msg 
     in case msgb of 
        FN_RESP _pl_ -> Right pl
        _             -> Left KademliaInvalidResponse 

ifPeerExist :: (HasKbucket m,MonadIO m) => Cantis.P2P.Kademlia.Types.NodeId -> m Bool
ifPeerExist' nid = do 
    m <- runExcepT $ ifPeerExist nid 
    case m of
        Right x -> return x 
        Left x -> return False 
        
deleteIfPeerExists :: (HasKbucket m,MOnadIO m) => [Peer] -> m [Peer]
deleteIfPeerExists [] = return [] 
deleteIfPeerExists (x:xs) = do
    fe <- ifPeerExist' (fst $ getPeer x)
    t <- deleteIfPeerExist xs
    if not ife
        then return (x : t)
        else return []

-- | Issues a FIND_NODE request by calling the network apis from P2P Layer
--  TODO : See if need to be converted to ExceptT

  issueFindNode :: (HasP2PEnv env m r t rmsg pmsg ) => Peer -> m ()
  issueFindNode rpeer = do 
    nc@NetworkConfig {..} <- asks (^.networkConfig)
    let rnid = fst $ getPeer rpeer 
        rnep = snd $ getPeer rpeer
        ruport =Cantis.P2P.Kademlia.Types.udpPort rnep 
        rip =nodeIp rnep 
        rnc = NetworkConfig rnid rip ruport ruport 
        fn_msg = packFindMsg nc _nodeId
    $(logDebug) $
        T.pack ("Issuing Find_Node to : " ++ show rip ++ ":" ++ show ruport)
    resp <- runExceptT $ issueKademliaRequest rnc (KademliaRequest fn_msg)
    case resp of
        Left e -> $(logDebug) $ T.pack (displayException e)
        Right (KademliaResponse payload) -> do
            _ <- runExceptT $ addToKBucket rpeer
            case getPeerListFromPayload payload of
                Left e ->
                    $(logDebug) $
                    T.append
                        (T.pack
                             ("Couldn't deserialise message while recieving fn_resp from : " ++
                              show rip ++ ":" ++ show ruport))
                        (T.pack (displayException e))
                Right peerl -> do
                    $(logDebug) $
                        T.pack
                            ("Received PeerList from " ++
                             show rip ++
                             ":" ++ show ruport ++ ": " ++ show peerl)
                    -- Verification
                    -- TODO Rethink about handling exceptions
                    peerl2 <- deleteIfPeerExist peerl
                    $(logDebug) $
                        T.pack
                            ("Received PeerList after removing exisiting peers : " ++
                             show peerl2)
                    -- Initiates the verification process
                    --   Deletes nodes from peer list which already exists in
                    --   k-bucket this is important otherwise it will be stuck
                    --   in a loop where the function constantly issue
                    --   FIND_NODE request forever.
                    runKademliaActionConcurrently_ issueFindNode peerl2

