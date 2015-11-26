{-# LANGUAGE RecordWildCards #-}
module Network.SSH.State where


import Network.SSH.Ciphers
import Network.SSH.Messages
import Network.SSH.Packet
import Network.SSH.TerminalModes
import Network.SSH.Mac

import Data.IORef
import Data.Word
import Data.Serialize.Get
import Control.Concurrent
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L


-- Server Internals ------------------------------------------------------------

data AuthResult = AuthFailed [S.ByteString]
                | AuthAccepted
                | AuthPkOk S.ByteString SshPubCert


data SessionEvent
  = SessionData S.ByteString
  | SessionClose
  | SessionWinsize SshWindowSize

data Client = Client
  { cGet         :: Int -> IO S.ByteString
  , cPut         :: L.ByteString -> IO ()
  , cClose       :: IO ()

  , cOpenShell   :: S.ByteString -> SshWindowSize -> [(TerminalFlag, Word32)] ->
                    Chan SessionEvent ->
                    (Maybe S.ByteString -> IO ()) ->
                    IO ()
  , cAuthHandler :: SshSessionId  ->
                    S.ByteString  ->
                    SshService    ->
                    SshAuthMethod ->
                    IO AuthResult
  }


data SshState = SshState
  { sshRecvState :: !(IORef (Word32, Cipher,Mac)) -- ^ Client context
  , sshBuf       :: !(IORef S.ByteString)
  , sshSendState :: !(MVar (Word32, Cipher, Mac)) -- ^ Server encryption context
  }

initialState :: IO SshState
initialState  =
  do sshRecvState <- newIORef (0,cipher_none,mac_none)
     sshSendState <- newMVar (0,cipher_none, mac_none)
     sshBuf       <- newIORef S.empty
     return SshState { .. }

send :: Client -> SshState -> SshMsg -> IO ()
send client SshState { .. } msg =
  modifyMVar_ sshSendState $ \(seqNum, cipher, mac) ->
    do let (pkt,cipher') = putSshPacket seqNum cipher mac (putSshMsg msg)
       cPut client pkt
       return (seqNum+1, cipher',mac)


receive :: Client -> SshState -> IO SshMsg
receive client SshState { .. } = loop
  where
  loop =
    do (seqNum, cipher, mac) <- readIORef sshRecvState
       res <- parseFrom client sshBuf (getSshPacket seqNum cipher mac getSshMsg)
       case res of

         Right (msg, cipher') ->
           do writeIORef sshRecvState (seqNum+1, cipher', mac)
              case msg of
                SshMsgIgnore _                      -> loop
                SshMsgDebug display m _ | display   -> S8.putStrLn m >> loop
                                        | otherwise -> loop
                _                                   -> return msg

         Left err ->
           do putStrLn err
              fail "Failed when reading from client"

parseFrom :: Client -> IORef S.ByteString -> Get a -> IO (Either String a)
parseFrom handle buffer body =
  do bytes <- readIORef buffer

     if S.null bytes
        then go True (Partial (runGetPartial body))
        else go True (runGetPartial body bytes)

  where

  go True  (Partial k) = do bytes <- cGet handle 1024
                            if S.null bytes
                               then fail "Client closed connection"
                               else go (S.length bytes == 1024) (k bytes)

  go False (Partial k) = go False (k S.empty)
  go _     (Done a bs) = do writeIORef buffer bs
                            return (Right a)
  go _     (Fail s _)  = return (Left s)


