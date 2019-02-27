{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}

module Cantis.P2P.PubSub.Class
    ( module Cantis.P2P.PubSub.Class
    ) where

import Cantis.P2P.PubSub.Types

import Control.Concurrent.STM.TVar (TVar)
import Data.Set (Set)

class HasTopics env t | env -> t where
    topics :: env -> Set t

class HasSubscribers env t  | env -> t where
    subscribers :: env ->  Subscribers t

class HasNotifiers env t | env -> t where
    notifiers :: env -> Notifiers t

class HasTopicHandlers env t msg | env -> t msg where
    topicHandlers :: env -> TopicHandlers t msg

class HasInbox env msg | env -> msg where
    inbox :: env -> TVar (Inbox msg)

class HasCache env msg | env -> msg where
    cache :: env -> TVar (Cache msg)

