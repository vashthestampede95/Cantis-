{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

module Cantis.P2P.PubSub.Notify 
(
    notify 
)where 
    import    Cantis.P2P.MessageHandler.NodeEndpoint 
    import    Cantis.P2P.P2PEnv 
    import    Cantis.P2P.PubSub.Class 
    import    Cantis.P2P.PubSub.Types 
    import    Cantis.P2P.Types
    import    Cantis.Utils.Set 

    import Control.Concurrrent.STM.TVar (readTVarIO)
    import Control.Monad.Except
    import Control.Monad.Reader 

    notify ::
    ( HasP2PEnv env m r t rmsg msg)
    => PubSubPayload t msg
    -> m ()
notify req@(PubSubPayload (t, msg)) = do
    subs <- asks subscribers
    inboxed <-  (liftIO . readTVarIO) =<< asks inbox
    peers <- liftIO $ notifiersForMessage inboxed subs msg t
    responses <-
        mapSetConcurrently
            (\node -> runExceptT $ issueRequest node (notifyRequest req))
            peers
    void $
        traverseSet
            (\case
                 Left _ -> return ()
                 Right (PubSubResponse Ok) -> return ()
                 Right (PubSubResponse Error) -> return ())
            responses

notifyRequest :: msg -> Request ('PubSub 'Notify) msg
notifyRequest = PubSubRequest
