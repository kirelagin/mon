{-# LANGUAGE RecordWildCards #-}

-- | Local and non-persistent monitoring server.
--   Listens for UDP statsd messages, parses and stores metrics/events
--   to ekg store whoose data is diplayed by ekg-wai http server

module Main
       ( main
       ) where

import Universum hiding (empty, intercalate)

import Data.Map (empty, insert, member, (!))
import Data.Text (intercalate)
import Network.Socket (AddrInfoFlag (AI_PASSIVE), Socket, SocketType (Datagram), addrAddress,
                       addrFamily, addrFlags, bind, close, defaultHints, defaultProtocol,
                       getAddrInfo, socket, withSocketsDo)
import Network.Socket.ByteString (recvFrom)
import Options.Applicative (Parser, argument, auto, execParser, helper, info, metavar, progDesc)
import System.Metrics (Store, createCounter, createDistribution, createGauge)
import System.Remote.Monitoring.Wai (forkServer, serverMetricStore)

import Mon.Network.Statsd (StatsdMessage (..))
import Mon.Network.Statsd.Parse (decodeStatsdMessage)
import Mon.Types (MetricType (..), Name, Tag)

import qualified System.Metrics.Counter as SMC
import qualified System.Metrics.Distribution as SMD
import qualified System.Metrics.Gauge as SMG

data Metric = CounterM !SMC.Counter
            | GaugeM !SMG.Gauge
            | DistributionM !SMD.Distribution

addValueToMetric :: Int -> Metric -> IO ()
addValueToMetric value (CounterM counter) =
    SMC.add counter $ fromIntegral value
addValueToMetric value (GaugeM gauge) =
    SMG.add gauge $ fromIntegral value
addValueToMetric value (DistributionM distriution) =
    SMD.add distriution $ fromIntegral value

type StoreMap = Map Name Metric

createMetric :: StatsdMessage -> Store -> IO Metric
createMetric StatsdMessage {..} store  = case smMetricType of
    Counter -> CounterM <$> createCounter taggedName store
    Gauge   -> GaugeM <$> createGauge taggedName store
    Timer   -> DistributionM <$> createDistribution taggedName store
  where
    taggedName = tagName smName smTags

tagName :: Name -> [Tag] -> Text
tagName name tags = name <> (intercalate ";" $ "" : fmap showTag tags)
  where
    showTag :: (Text, Text) -> Text
    showTag (tag, value) = tag <> if null value then "" else "=" <> value

addMeasurement :: StatsdMessage -> Store -> StoreMap -> IO StoreMap
addMeasurement statsdMessage@StatsdMessage {..} store storeMap = do
    newMetric <- if member taggedName storeMap
                    then return (storeMap ! taggedName)
                    else createMetric statsdMessage store
    addValueToMetric smValue newMetric
    return $ insert taggedName newMetric storeMap
  where
    taggedName = tagName smName smTags


mainArgsP :: Parser (Int, Int)
mainArgsP = (,)
        <$> argument auto (metavar "<statsd_listen_port>")
        <*> argument auto (metavar "<ekg_http_interface_port>")

-- | Specify statsd UDP listening port
--   and http wai server port
main :: IO ()
main = do
    (listenPort, waiPort)  <- execParser $  info (helper <*> mainArgsP) $
                                            progDesc "Local monitoring server"
    store <- serverMetricStore <$> forkServer "127.0.0.1" waiPort
    listen listenPort store

listen :: Int -> Store -> IO ()
listen port store = withSocketsDo $ do
    (serveraddr:_) <- getAddrInfo
                      (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
                      Nothing (Just $ show port)
    sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
    bind sock (addrAddress serveraddr)
    handler sock empty
    close sock
  where
    handler :: Socket -> StoreMap -> IO ()
    handler sock storeMap = do
        (msg,_) <- recvFrom sock 1024
        let statsdMessage = decodeStatsdMessage msg
        newStoreMap <- addMeasurement statsdMessage store storeMap
        print statsdMessage
        handler sock newStoreMap