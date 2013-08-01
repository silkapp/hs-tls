-- |
-- Module      : Network.TLS.Handshake.Process
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- process handshake message received
--
module Network.TLS.Handshake.Process
    ( processHandshake
    ) where

import Data.ByteString (ByteString)

import Control.Applicative
import Control.Monad.Error
import Control.Monad.State (gets)

import Network.TLS.Types (Role(..), invertRole)
import Network.TLS.Util
import Network.TLS.Packet
import Network.TLS.Struct
import Network.TLS.State
import Network.TLS.Context
import Network.TLS.Handshake.State
import Network.TLS.Handshake.Key
import Network.TLS.Extension
import Data.X509

processHandshake :: MonadIO m => Context -> Handshake -> m ()
processHandshake ctx hs = do
    role <- usingState_ ctx isClientContext
    case hs of
        ClientHello cver ran _ _ _ ex _ -> when (role == ServerRole) $ do
            mapM_ (usingState_ ctx . processClientExtension) ex
            usingState_ ctx $ startHandshakeClient cver ran
        Certificates certs            -> processCertificates role certs
        ClientKeyXchg content         -> when (role == ServerRole) $ do
            processClientKeyXchg ctx content
        HsNextProtocolNegotiation selected_protocol ->
            when (role == ServerRole) $ usingState_ ctx $ setNegotiatedProtocol selected_protocol
        Finished fdata                -> processClientFinished ctx fdata
        _                             -> return ()
    let encoded = encodeHandshake hs
    when (certVerifyHandshakeMaterial hs) $ usingHState ctx $ addHandshakeMessage encoded
    when (finishHandshakeTypeMaterial $ typeOfHandshake hs) $ usingHState ctx $ updateHandshakeDigest encoded
  where -- secure renegotiation
        processClientExtension (0xff01, content) = do
            v <- getVerifiedData ClientRole
            let bs = extensionEncode (SecureRenegotiation v Nothing)
            unless (bs `bytesEq` content) $ throwError $ Error_Protocol ("client verified data not matching: " ++ show v ++ ":" ++ show content, True, HandshakeFailure)

            setSecureRenegotiation True
        -- unknown extensions
        processClientExtension _ = return ()

        processCertificates :: MonadIO m => Role -> CertificateChain -> m ()
        processCertificates ServerRole (CertificateChain []) = return ()
        processCertificates ClientRole (CertificateChain []) =
            throwCore $ Error_Protocol ("server certificate missing", True, HandshakeFailure)
        processCertificates role (CertificateChain (c:_))
            | role == ClientRole = usingHState ctx $ setPublicKey pubkey
            | otherwise          = usingHState ctx $ setClientPublicKey pubkey
          where pubkey = certPubKey $ getCertificate c

-- process the client key exchange message. the protocol expects the initial
-- client version received in ClientHello, not the negotiated version.
-- in case the version mismatch, generate a random master secret
processClientKeyXchg :: MonadIO m => Context -> ByteString -> m ()
processClientKeyXchg ctx encryptedPremaster = do
    (rver, role, random, ePremaster) <- usingState_ ctx $ do
        (,,,) <$> getVersion <*> isClientContext <*> genRandom 48 <*> decryptRSA encryptedPremaster
    usingHState ctx $ do
        expectedVer <- gets hstClientVersion
        case ePremaster of
            Left _          -> setMasterSecretFromPre rver role random
            Right premaster -> case decodePreMasterSecret premaster of
                Left _                   -> setMasterSecretFromPre rver role random
                Right (ver, _)
                    | ver /= expectedVer -> setMasterSecretFromPre rver role random
                    | otherwise          -> setMasterSecretFromPre rver role premaster

processClientFinished :: MonadIO m => Context -> FinishedData -> m ()
processClientFinished ctx fdata = do
    (cc,ver) <- usingState_ ctx $ (,) <$> isClientContext <*> getVersion
    expected <- usingHState ctx $ getHandshakeDigest ver $ invertRole cc
    when (expected /= fdata) $ do
        throwCore $ Error_Protocol("bad record mac", True, BadRecordMac)
    usingState_ ctx $ updateVerifiedData ServerRole fdata
    return ()

