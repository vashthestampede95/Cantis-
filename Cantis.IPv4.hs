{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DuplicateRecordFields#-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNtypes #-}
{-# LANGUAGE NameFieldPuns #-}

module Socket.IPv4.Stream
(
 Listener
 ,Connection
 ,Endpoint(..)
 ,withListener
 ,withAccepted
 ,forkAccepted
 ,forkAcceptedUnmasked
 ,sendbyteArray
 
 , sendByteArraySlice
 , sendMutableByteArray
 , sendMutableByteArraySlice
 , receiveByteArray
 , receiveBoundedByteArray
 , receiveMutableByteArraySlice
 , receiveMutableByteArray
    -- * Exceptions
 , SocketException(..)

)
where 
import           Control.Concurrent      (ThreadId, threadWaitRead,
                                          threadWaitWrite)
import           Control.Concurrent      (forkIO, forkIOWithUnmask)
import           Control.Exception       (mask, onException)
import           Data.Bifunctor          (bimap)
import           Data.Primitive          (ByteArray, MutableByteArray (..))
import           Data.Word               (Word16)
import           Foreign.C.Error         (Errno (..), eAGAIN, eINPROGRESS,
                                          eWOULDBLOCK)
import           Foreign.C.Types         (CInt, CSize)
import           GHC.Exts                (Int (I#), RealWorld,
                                          shrinkMutableByteArray#)
import           Net.Types               (IPv4 (..))
import           Socket                  (SocketException (..))
import           Socket.Debug            (debug)
import           Socket.IPv4             (Endpoint (..))
import           System.Posix.Types      (Fd)

import qualified Control.Monad.Primitive as PM
import qualified Data.Primitive          as PM
import qualified Linux.Socket            as L
import qualified Posix.Socket            as S

-- Socket upons which the incoming connections listen 
newtype Listener=Listener fd

-- A connection oriented stream socket 
newtype Connection=Connection fd

withListener::Endpoint->(listener->Word16->IO a)->IO (Either SocketException a)
withListener endpoint@Endpoint{port=specifiedPort}f=mask $\restore ->do
    debug ("withSocket:opened Listener"++show endpoint)
    e1<-S.uninteruptableSocket S.internet
    (L.applySocketFlags(L.closeOnExec<>L.nonBlocking)S.stream)
    S.defaultProtocol
    debug("withSocket:opened Listener"++show endpoint)
    case e1 of
        Left err->pure (Left(errorCode err))
        Right fd->do
            e2->S.uninteruptibleBind fd
            (S.encodeSocketAddressInternet(endpointtoSocketAddressInternet endpoint))
            debug("withSocket:requested binding for listener"++show endpoint)
             case e2 of 
                Left err->do
                    _<-S.uninteruptableClose fd
                    pure (Left(errorCode err))
                Right _->S.interuptibleListen fd 16 >>=\case 
                --We hardcode the listen backlog to 16.the author is unfamiliiar with use cases 
                -- where gains are realized from tuning this parameter 
                Left err->do
                    _<-S.uninteruptibleClose fd
                    debug"withSocket:Listen failed with error code"
                    pure (Left(errorCode err))
                Right _->do
                    --get Socket name is copied from in socket.datagram.IPv4.Undestined 
                    eactualPort<-if specifiedPort== 0
                        then  S.uninteruptibleGetSocketName fd S.sizeofSocketAddressInternet >>=\case 
                        Left err->do
                            _<-S.uninteruptibleClose fd 
                            pure(Left(errorCode err))
                        Right (sockAddrRequiredSz,sockAddr) -> if sockAddrRequiredSz == S.sizeofSocketAddressInternet
                            then case S.decodeSocketAddressInternet sockAddr of
                              Just S.SocketAddressInternet{port = actualPort} -> do
                                let cleanActualPort = S.networkToHostShort actualPort
                                debug ("withSocket: successfully bound listener " ++ show endpoint ++ " and got port " ++ show cleanActualPort)
                                pure (Right cleanActualPort)
                              Nothing -> do
                                _ <- S.uninterruptibleClose fd
                                pure (Left (SocketAddressFamily (-1)))
                            else do
                              _ <- S.uninterruptibleClose fd
                              pure (Left SocketAddressSize)
                        else pure (Right specifiedPort)
                      case eactualPort of
                        Left err -> pure (Left err)
                        Right actualPort -> do
                          a <- onException (restore (f (Listener fd) actualPort)) (S.uninterruptibleClose fd)
                          S.uninterruptibleClose fd >>= \case
                            Left err -> pure (Left (errorCode err))
                            Right _ -> pure (Right a)
-- | Accept a connection on the listener and run the supplied callback
-- on it. This closes the connection when the callback finishes or if
-- an exception is thrown. Since this function blocks the thread until
-- the callback finishes, it is only suitable for stream socket clients
-- that handle one connection at a time. The variant 'forkAcceptedUnmasked'
-- is preferrable for servers that need to handle connections concurrently
-- (most use cases).
withAccepted::Listener->(Connection->Endpoint->IO a)->IO (Either SocketException a)
withAccepted lst cb=internalAccepted 
( \restore action->do
    action restore 
)lst cb 
internalAccepted::((forall x.IO x-> IO x)->(IO a -> IO b) -> IO (Either SocketException b)) -> IO (Either SocketException c))->Listener->(Connection->Endpoint->IO a)->IO (Either SocketException a)
internalAccepted wrap (Listener !lst)f=do
    threadWaitRead lst 
    mask $ \restore->do
        S.uninterruptibleAccept lst S.sizeofSocketAddressInternet >>= \case
        Left err -> pure (Left (errorCode err))
        Right (sockAddrRequiredSz,sockAddr,acpt) -> if sockAddrRequiredSz == S.sizeofSocketAddressInternet
          then case S.decodeSocketAddressInternet sockAddr of
            Just sockAddrInet -> do
              let acceptedEndpoint = socketAddressInternetToEndpoint sockAddrInet
              debug ("withAccepted: successfully accepted connection from " ++ show acceptedEndpoint)
              wrap restore $ \restore' -> do
                a <- onException (restore' (f (Connection acpt) acceptedEndpoint)) (S.uninterruptibleClose acpt)
                gracefulClose acpt a
            Nothing -> do
              _ <- S.uninterruptibleClose acpt
              pure (Left (SocketAddressFamily (-1)))
          else do
            _ <- S.uninterruptibleClose acpt
            pure (Left SocketAddressSize)
            gracefulClose :: Fd -> a -> IO (Either SocketException a)
            gracefulClose fd a = S.uninterruptibleShutdown fd S.write >>= \case
              Left err -> do
                _ <- S.uninterruptibleClose fd
                pure (Left (errorCode err))
              Right _ -> do
                buf <- PM.newByteArray 1
                S.uninterruptibleReceiveMutableByteArray fd buf 0 1 mempty >>= \case
                  Left err1 -> if err1 == eWOULDBLOCK || err1 == eAGAIN
                    then do
                      threadWaitRead fd
                      S.uninterruptibleReceiveMutableByteArray fd buf 0 1 mempty >>= \case
                        Left err -> do
                          _ <- S.uninterruptibleClose fd
                          pure (Left (errorCode err))
                        Right sz -> if sz == 0
                          then fmap (bimap errorCode (const a)) (S.uninterruptibleClose fd)
                          else do
                            debug ("Socket.Stream.IPv4.gracefulClose: remote not shutdown A")
                            _ <- S.uninterruptibleClose fd
                            pure (Left RemoteNotShutdown)
                    else do
                      _ <- S.uninterruptibleClose fd
                      -- Is this the right error context? It's a call
                      -- to recv, but it happens while shutting down
                      -- the socket.
                      pure (Left (errorCode err1))
                  Right sz -> if sz == 0
                    then fmap (bimap errorCode (const a)) (S.uninterruptibleClose fd)
                    else do
                      debug ("Socket.Stream.IPv4.gracefulClose: remote not shutdown B")
                      _ <- S.uninterruptibleClose fd
                      pure (Left RemoteNotShutdown)
-- | Accept a connection on the listener and run the supplied callback in
-- a new thread. Prefer 'forkAcceptedUnmasked' unless the masking state
-- needs to be preserved for the callback. Such a situation seems unlikely
-- to the author. 
forkAccepted::Listener->(Either SocketException a->IO ())->(Connection->Endpoint->IO a)->IO(Either SocketException ThreadId)
forkAccepted lst consumeException cb = internalAccepted
  ( \restore action -> do
    tid <- forkIO $ do
      x <- action restore
      restore (consumeException x)
    pure (Right tid)
  ) lst cb
-- | Accept a connection on the listener and run the supplied callback in
-- a new thread. The masking state is set to @Unmasked@ when running the
-- callback.
forkAcceptedUnmasked::Listener->(Either SocketException ->IO())->(Connection->Endpoint->IO a)->IO(Either SocketException IO a)
forkAcceptedUnmasked lst consumeException cb = internalAccepted
  ( \_ action -> do
    tid <- forkIOWithUnmask $ \unmask -> do
      x <- action unmask
      unmask (consumeException x)
    pure (Right tid)
  ) lst cb
  --Establish A connection to the server 
  withConnection::Endpoint->(Connection->IO a)->IO(Either SocketException IO a)
  withConnection !remote f= mask $ \restore -> do
    debug ("withSocket: opening connection " ++ show remote)
    e1 <- S.uninterruptibleSocket S.internet
      (L.applySocketFlags (L.closeOnExec <> L.nonblocking) S.stream)
      S.defaultProtocol
    debug ("withSocket: opened connection " ++ show remote)
    case e1 of
      Left err1 -> pure (Left (errorCode err1))
      Right fd -> do
        let sockAddr = id
              $ S.encodeSocketAddressInternet
              $ endpointToSocketAddressInternet
              $ remote
        merr <- S.uninterruptibleConnect fd sockAddr >>= \case
          Left err2 -> if err2 == eINPROGRESS
            then do
              threadWaitWrite fd
              pure Nothing
            else pure (Just (errorCode err2))
          Right _ -> pure Nothing
        case merr of
          Just err -> do
            _ <- S.uninterruptibleClose fd
            pure (Left err)
          Nothing -> do
            e <- S.uninterruptibleGetSocketOption fd
              S.levelSocket S.optionError (intToCInt (PM.sizeOf (undefined :: CInt)))
            case e of
              Left err -> do
                _ <- S.uninterruptibleClose fd
                pure (Left (errorCode err))
              Right (sz,S.OptionValue val) -> if sz == intToCInt (PM.sizeOf (undefined :: CInt))
                then
                  let err = PM.indexByteArray val 0 :: CInt in
                  if err == 0
                    then do
                      a <- onException (restore (f (Connection fd))) (S.uninterruptibleClose fd)
                      gracefulClose fd a
                    else do
                      _ <- S.uninterruptibleClose fd
                      pure (Left (errorCode (Errno err)))
                else do
                  _ <- S.uninterruptibleClose fd
                  pure (Left OptionValueSize)
sendByteArray ::Connection -> ByteArray -> IO (Either SocketException ())
sendByteArray conn arr = sendByteArraySlice conn arr 0 (PM.sizeofByteArray arr)
sendByteArraySlice ::Connection -> ByteArray -> Int  -> Int-> IO (Either SocketException ())
sendByteArraySlice !conn !payload !off0 !len0 = go off0 len0
  where
  go !off !len = if len > 0
    then internalSend conn payload off len >>= \case
      Left e -> pure (Left e)
      Right sz' -> do
        let sz = csizeToInt sz'
        go (off + sz) (len - sz)
    else pure (Right ())

sendMutableByteArray ::
     Connection -> MutableByteArray RealWorld -> IO (Either SocketException ())
sendMutableByteArray conn arr =
  sendMutableByteArraySlice conn arr 0 =<< PM.getSizeofMutableByteArray arr

sendMutableByteArraySlice ::
     Connection -> MutableByteArray RealWorld -> Int -> Int -> IO (Either SocketException ())
sendMutableByteArraySlice !conn !payload !off0 !len0 = go off0 len0
  where
  go !off !len = if len > 0
    then internalSendMutable conn payload off len >>= \case
      Left e -> pure (Left e)
      Right sz' -> do
        let sz = csizeToInt sz'
        go (off + sz) (len - sz)
    else pure (Right ())

-- The length must be greater than zero.
internalSendMutable ::
     Connection -> MutableByteArray RealWorld-> Int -> Int -> IO (Either SocketException CSize)
internalSendMutable (Connection !s) !payload !off !len = do
  e1 <- S.uninterruptibleSendMutableByteArray s payload
    (intToCInt off)
    (intToCSize len)
    mempty
  case e1 of
    Left err1 -> if err1 == eWOULDBLOCK || err1 == eAGAIN
      then do
        threadWaitWrite s
        e2 <- S.uninterruptibleSendMutableByteArray s payload
          (intToCInt off)
          (intToCSize len)
          mempty
        case e2 of
          Left err2 -> pure (Left (errorCode err2))
          Right sz  -> pure (Right sz)
      else pure (Left (errorCode err1))
    Right sz -> pure (Right sz)

-- The length must be greater than zero.
internalSend ::
     Connection -> ByteArray -> Int -> Int -> IO (Either SocketException CSize)
internalSend (Connection !s) !payload !off !len = do
  debug ("send: about to send chunk on stream socket, offset " ++ show off ++ " and length " ++ show len)
  e1 <- S.uninterruptibleSendByteArray s payload
    (intToCInt off)
    (intToCSize len)
    mempty
  debug "send: just sent chunk on stream socket"
  case e1 of
    Left err1 -> if err1 == eWOULDBLOCK || err1 == eAGAIN
      then do
        debug "send: waiting to for write ready on stream socket"
        threadWaitWrite s
        e2 <- S.uninterruptibleSendByteArray s payload
          (intToCInt off)
          (intToCSize len)
          mempty
        case e2 of
          Left err2 -> do
            debug "send: encountered error after sending chunk on stream socket"
            pure (Left (errorCode err2))
          Right sz -> pure (Right sz)
      else pure (Left (errorCode err1))
    Right sz -> pure (Right sz)

-- The maximum number of bytes to receive must be greater than zero.
-- The operating system guarantees us that the returned actual number
-- of bytes is less than or equal to the requested number of bytes.
-- This function does not validate that the result size is greater
-- than zero. Functions calling this must perform that check. This
-- also does not trim the buffer. The caller must do that if it is
-- necessary.
internalReceiveMaximally ::Connection -> Int-> MutableByteArray RealWorld -> Int -> IO (Either SocketException Int)
internalReceiveMaximally (Connection !fd) !maxSz !buf !off = do
  debug "receive: stream socket about to wait"
  threadWaitRead fd
  debug ("receive: stream socket is now readable, receiving up to " ++ show maxSz ++ " bytes at offset " ++ show off)
  e <- S.uninterruptibleReceiveMutableByteArray fd buf (intToCInt off) (intToCSize maxSz) mempty
  debug "receive: finished reading from stream socket"
  case e of
    Left err     -> pure (Left (errorCode err))
    Right recvSz -> pure (Right (csizeToInt recvSz))

-- | Receive exactly the given number of bytes. If the remote application
--   shuts down its end of the connection before sending the required
--   number of bytes, this returns
--   @'Left' ('SocketException' 'Receive' 'RemoteShutdown')@.
receiveByteArray ::
     Connection -> Int -> IO (Either SocketException ByteArray)
receiveByteArray !conn0 !total = do
  marr <- PM.newByteArray total
  go conn0 marr 0 total
  where
  go !conn !marr !off !remaining = case compare remaining 0 of
    GT -> internalReceiveMaximally conn remaining marr off >>= \case
      Left err -> pure (Left err)
      Right sz -> if sz /= 0
        then go conn marr (off + sz) (remaining - sz)
        else pure (Left RemoteShutdown)
    EQ -> do
      arr <- PM.unsafeFreezeByteArray marr
      pure (Right arr)
    LT -> pure (Left NegativeBytesRequested)

-- | Receive a number of bytes exactly equal to the size of the mutable
--   byte array. If the remote application shuts down its end of the
--   connection before sending the required number of bytes, this returns
--   @'Left' ('SocketException' 'Receive' 'RemoteShutdown')@.
receiveMutableByteArray ::Connection-> MutableByteArray RealWorld-> IO (Either SocketException ())
receiveMutableByteArray !conn0 !marr0 = do
  total <- PM.getSizeofMutableByteArray marr0
  go conn0 marr0 0 total
  where
  go !conn !marr !off !remaining = if remaining > 0
    then internalReceiveMaximally conn remaining marr off >>= \case
      Left err -> pure (Left err)
      Right sz -> if sz /= 0
        then go conn marr (off + sz) (remaining - sz)
        else pure (Left RemoteShutdown)
    else pure (Right ())

-- | Receive up to the given number of bytes, using the given array and
--   starting at the given offset.
--   If the remote application shuts down its end of the connection instead of
--   sending any bytes, this returns
--   @'Left' ('SocketException' 'Receive' 'RemoteShutdown')@.
receiveMutableByteArraySlice ::
     Connection -> Int-> MutableByteArray RealWorld -> Int-> IO (Either SocketException Int) 
receiveMutableByteArraySlice !conn !total !marr !off
  | total > 0 =
      internalReceiveMaximally conn total marr off >>= \case
        Left err -> pure (Left err)
        Right sz -> if sz /= 0
          then pure (Right sz)
          else pure (Left RemoteShutdown)
  | total == 0 = pure (Right 0)
  | otherwise = pure (Left NegativeBytesRequested)

-- | Receive up to the given number of bytes. If the remote application
--   shuts down its end of the connection instead of sending any bytes,
--   this returns
--   @'Left' ('SocketException' 'Receive' 'RemoteShutdown')@.
receiveBoundedByteArray ::Connection -> Int -> IO (Either SocketException ByteArray)
receiveBoundedByteArray !conn !total
  | total > 0 = do
      m <- PM.newByteArray total
      receiveMutableByteArraySlice conn total m 0 >>= \case
        Left err -> pure (Left err)
        Right sz -> do
          shrinkMutableByteArray m sz
          Right <$> PM.unsafeFreezeByteArray m
  | total == 0 = pure (Right mempty)
  | otherwise = pure (Left NegativeBytesRequested)

endpointToSocketAddressInternet :: Endpoint -> S.SocketAddressInternet
endpointToSocketAddressInternet (Endpoint {address, port}) = S.SocketAddressInternet
  { port = S.hostToNetworkShort port
  , address = S.hostToNetworkLong (getIPv4 address)
  }

socketAddressInternetToEndpoint :: S.SocketAddressInternet -> Endpoint
socketAddressInternetToEndpoint (S.SocketAddressInternet {address,port}) = Endpoint
  { address = IPv4 (S.networkToHostLong address)
  , port = S.networkToHostShort port
  }

intToCInt :: Int -> CInt
intToCInt = fromIntegral

intToCSize :: Int -> CSize
intToCSize = fromIntegral

csizeToInt :: CSize -> Int
csizeToInt = fromIntegral

shrinkMutableByteArray :: MutableByteArray RealWorld -> Int -> IO ()
shrinkMutableByteArray (MutableByteArray arr) (I# sz) =
  PM.primitive_ (shrinkMutableByteArray# arr sz)

errorCode :: Errno -> SocketException
errorCode (Errno x) = ErrorCode x

  




            
        
