{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE GADTs        #-}
{-# LANGUAGE TypeFamilies #-}

module Cantis.P2P.PubSub.Subscribe
    ( subscribe
    ) where

import Cantis.P2P.MessageHandler.HandlerTypes
import Cantis.P2P.MessageHandler.NodeEndpoint
import Cantis.P2P.P2PEnv
import Cantis .P2P.PubSub.Class
import Cantis.P2P.PubSub.Types
import Cantis.P2P.Types

import Control.Monad.Except
import Control.Monad.Reader

subscribe ::
       (HasP2PEnv env m r t rmsg msg) => PubSubPayload t Timer -> NodeId -> m ()
subscribe req@(PubSubPayload (t,_)) nid = do
    resp <- runExceptT $ issueRequest nid (subscribeRequest req)
    notf <- asks notifiers
    case resp of
        Left _ -> return ()
        Right (PubSubResponse Ok) -> liftIO $ newNotifier nid notf t
        Right (PubSubResponse Error) -> return ()

subscribeRequest :: msg -> Request ('PubSub 'Subscribe) msg
subscribeRequest = PubSubRequest
