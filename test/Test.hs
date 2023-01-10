{-# LANGUAGE CPP, OverloadedStrings, RecordWildCards, LambdaCase #-}
module Main (main) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
import Data.Monoid (mappend)
#endif
import qualified Control.Concurrent.Async as Async
import Control.Exception (try)
import Control.Concurrent
import Control.Monad
import Control.Monad.Trans
import qualified Data.List as L
import Data.Time
import Data.Time.Clock.POSIX
import qualified Test.Framework as Test (Test, defaultMain)
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import qualified Test.HUnit as HUnit
import qualified Data.ByteString as BS

import Database.Redis
import PubSubTest

------------------------------------------------------------------------------
-- Main and helpers
--
main :: IO ()
main = do
    singleNodeConn <- connect defaultConnectInfo
    let singleNodeTests = tests singleNodeConn
    clusterConn <- connectCluster $ defaultConnectInfo { connectPort = PortNumber 30001 }
    let clusterTestCases = clusterTests clusterConn
    Test.defaultMain $ clusterTestCases ++ singleNodeTests


data TestType = Cluster | SingleNode

instance Show TestType where
    show Cluster = "Cluster"
    show SingleNode = "SingleNode"

type Test = TestType -> Connection -> Test.Test


resetDb :: Connection -> IO ()
resetDb conn = do
    resps <- runRedis conn $ sendToAllMasterNodes ["FLUSHDB"]
    let combined = sequence resps
    case combined of
        Left reply -> HUnit.assertFailure $ "Redis error when flushing: " ++ show reply
        Right replies -> if  all (\r -> r == Ok) replies
                         then return ()
                         else HUnit.assertFailure "Redis error when flushing, non OK reply received"

testCase :: String -> Redis () -> Test
testCase name r testType conn = Test.testCase nameWithTestType $
    withTimeLimit 0.5 $ resetDb conn >> runRedis conn r
  where
    nameWithTestType = show testType ++ ": " ++ name
    withTimeLimit limit act = do
        start <- getCurrentTime
        _ <- act
        deltaT <-fmap (`diffUTCTime` start) getCurrentTime
        when (deltaT > limit) $
            putStrLn $ name ++ ": " ++ show deltaT

(>>=?) :: (Eq a, Show a) => Redis (Either Reply a) -> a -> Redis ()
redis >>=? expected = do
    a <- redis
    liftIO $ case a of
        Left reply   -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right actual -> expected HUnit.@=? actual

assert :: Bool -> Redis ()
assert = liftIO . HUnit.assert

------------------------------------------------------------------------------
-- Tests
--
tests :: Connection -> [Test.Test]
tests conn = map (\t -> t SingleNode conn) $ concat
    [ testsMisc, testsKeys, testsStrings, [testHashes], testsLists, testsSets, [testHyperLogLog]
    , testsZSets, [testPubSub], [testTransaction], [testScripting]
    , testsConnection, testsServer, [testScans], [testZrangelex]
    , [testXAddRead, testXReadGroup, testXRange, testXpending, testXClaim, testXInfo, testXDel, testXTrim]
    , (map (\f -> (\_ c -> f c)) testPubSubThreaded)
      -- should always be run last as connection gets closed after it
    , [testQuit]
    ]

clusterTests :: Connection -> [Test.Test]
clusterTests conn = map (\t -> t Cluster conn)
    [ testPipelining , testConstantSpacePipelining, testForceErrorReply
    , testEvalReplies ]

------------------------------------------------------------------------------
-- Miscellaneous
--
testsMisc :: [Test]
testsMisc =
    [ testConstantSpacePipelining, testForceErrorReply, testPipelining
    , testEvalReplies
    ]

testConstantSpacePipelining :: Test
testConstantSpacePipelining = testCase "constant-space pipelining" $ do
    -- This testcase should not exceed the maximum heap size, as set in
    -- the run-test.sh script.
    replicateM_ 100000 (set "key" "val")
    -- If the program didn't crash, pipelining takes constant memory.
    assert True

testForceErrorReply :: Test
testForceErrorReply = testCase "force error reply" $ do
    set "key" "value" >>= \case
      Left _ -> error "impossible"
      _ -> return ()
    -- key is not a hash -> wrong kind of value
    reply <- hkeys "key"
    assert $ case reply of
        Left (Error _) -> True
        _              -> False

testPipelining :: Test
testPipelining = testCase "pipelining" $ do
    let n = 200
    tPipe <- deltaT $ do
        oks <- replicateM n (set "pipelinekey" "pipelineval")
        assert $ oks == replicate n (Right Ok)

    tNoPipe <- deltaT $ replicateM_ n ((set "pipelinekey" "pipelineval") >>=? Ok)
    -- pipelining should at least be twice as fast.
    liftIO $ putStrLn $ "tPipe: " ++ show tPipe
    liftIO $ putStrLn $ "tNoPipe: " ++ show tNoPipe
    assert $ tNoPipe / tPipe > 2
  where
    deltaT redis = do
        start <- liftIO $ getCurrentTime
        _ <- redis
        liftIO $ fmap (`diffUTCTime` start) getCurrentTime

testEvalReplies :: Test
testEvalReplies testType conn = testCase "eval unused replies" go testType conn
  where
    go = do
      _ <- liftIO $ runRedis conn $ set "key" "value"
      result <- liftIO $ do
         threadDelay $ 10 ^ (5 :: Int)
         mvar <- newEmptyMVar
         _ <- asyncGet mvar >>= Async.wait
         takeMVar mvar
      pure result >>=? Just "value"
    asyncGet :: MVar (Either Reply (Maybe BS.ByteString)) -> IO (Async.Async ())
    asyncGet mvar = Async.async $ do
        result <- runRedis conn $ get "key"
        _ <- putMVar mvar result
        return ()

------------------------------------------------------------------------------
-- Keys
--
testsKeys :: [Test]
testsKeys = [ testKeys, testExpireAt, testSort, testGetType, testObject ]

testKeys :: Test
testKeys = testCase "keys" $ do
    set "key" "value"     >>=? Ok
    get "key"             >>=? Just "value"
    exists "key"          >>=? True
    keys "*"              >>=? ["key"]
    randomkey             >>=? Just "key"
    move "key" 13         >>=? True
    select 13             >>=? Ok
    expire "key" 1        >>=? True
    pexpire "key" 1000    >>=? True
    ttl "key" >>= \case
      Left _ -> error "error"
      Right t -> do
        assert $ t `elem` [0..1]
        pttl "key" >>= \case
          Left _ -> error "error"
          Right pt -> do
            assert $ pt `elem` [990..1000]
            persist "key"         >>=? True
            dump "key" >>= \case
              Left _ -> error "impossible"
              Right s -> do
                restore "key'" 0 s    >>=? Ok
                rename "key" "key'"   >>=? Ok
                renamenx "key'" "key" >>=? True
                del ["key"]           >>=? 1
                select 0              >>=? Ok

testExpireAt :: Test
testExpireAt = testCase "expireat" $ do
    set "key" "value"             >>=? Ok
    t <- ceiling . utcTimeToPOSIXSeconds <$> liftIO getCurrentTime
    let expiry = t+1
    expireat "key" expiry         >>=? True
    pexpireat "key" (expiry*1000) >>=? True

testSort :: Test
testSort = testCase "sort" $ do
    lpush "ids"     ["1","2","3"]                >>=? 3
    sort "ids" defaultSortOpts                   >>=? ["1","2","3"]
    sortStore "ids" "anotherKey" defaultSortOpts >>=? 3
    mset
         [("weight_1","1")
         ,("weight_2","2")
         ,("weight_3","3")
         ,("object_1","foo")
         ,("object_2","bar")
         ,("object_3","baz")
         ] >>= \case
      Left _ -> error "error"
      _ -> return ()
    let opts = defaultSortOpts { sortOrder = Desc, sortAlpha = True
                               , sortLimit = (1,2)
                               , sortBy    = Just "weight_*"
                               , sortGet   = ["#", "object_*"] }
    sort "ids" opts >>=? ["2", "bar", "1", "foo"]


testGetType :: Test
testGetType = testCase "getType" $ do
    getType "key"     >>=? None
    forM_ ts $ \(setKey, typ) -> do
        setKey
        getType "key" >>=? typ
        del ["key"]   >>=? 1
  where
    ts = [ (set "key" "value"                         >>=? Ok,   String)
         , (hset "key" "field" "value"                >>=? True, Hash)
         , (lpush "key" ["value"]                     >>=? 1,    List)
         , (sadd "key" ["member"]                     >>=? 1,    Set)
         , (zadd "key" [(42,"member"),(12.3,"value")] >>=? 2,    ZSet)
         ]

testObject :: Test
testObject = testCase "object" $ do
    set "key" "value"    >>=? Ok
    objectRefcount "key" >>=? 1
    objectEncoding "key" >>= \case
      Left _ -> error "error"
      _ -> return ()
    objectIdletime "key" >>=? 0

------------------------------------------------------------------------------
-- Strings
--
testsStrings :: [Test]
testsStrings = [testStrings, testBitops]

testStrings :: Test
testStrings = testCase "strings" $ do
    setnx "key" "value"               >>=? True
    getset "key" "hello"              >>=? Just "value"
    append "key" "world"              >>=? 10
    strlen "key"                      >>=? 10
    setrange "key" 0 "hello"          >>=? 10
    getrange "key" 0 4                >>=? "hello"
    mset [("k1","v1"), ("k2","v2")]   >>=? Ok
    msetnx [("k1","v1"), ("k2","v2")] >>=? False
    mget ["key"]                      >>=? [Just "helloworld"]
    setex "key" 1 "42"                >>=? Ok
    psetex "key" 1000 "42"            >>=? Ok
    decr "key"                        >>=? 41
    decrby "key" 1                    >>=? 40
    incr "key"                        >>=? 41
    incrby "key" 1                    >>=? 42
    incrbyfloat "key" 1               >>=? 43
    del ["key"]                       >>=? 1
    setbit "key" 42 "1"               >>=? 0
    getbit "key" 42                   >>=? 1
    bitcount "key"                    >>=? 1
    bitcountRange "key" 0 (-1)        >>=? 1

testBitops :: Test
testBitops = testCase "bitops" $ do
    set "k1" "a"               >>=? Ok
    set "k2" "b"               >>=? Ok
    bitopAnd "k3" ["k1", "k2"] >>=? 1
    bitopOr "k3" ["k1", "k2"]  >>=? 1
    bitopXor "k3" ["k1", "k2"] >>=? 1
    bitopNot "k3" "k1"         >>=? 1

------------------------------------------------------------------------------
-- Hashes
--
testHashes :: Test
testHashes = testCase "hashes" $ do
    hset "key" "field" "value"   >>=? True
    hsetnx "key" "field" "value" >>=? False
    hexists "key" "field"        >>=? True
    hlen "key"                   >>=? 1
    hget "key" "field"           >>=? Just "value"
    hmget "key" ["field", "-"]   >>=? [Just "value", Nothing]
    hgetall "key"                >>=? [("field","value")]
    hkeys "key"                  >>=? ["field"]
    hvals "key"                  >>=? ["value"]
    hdel "key" ["field"]         >>=? 1
    hmset "key" [("field","40")] >>=? Ok
    hincrby "key" "field" 2      >>=? 42
    hincrbyfloat "key" "field" 2 >>=? 44

------------------------------------------------------------------------------
-- Lists
--
testsLists :: [Test]
testsLists =
    [testLists, testBpop]

testLists :: Test
testLists = testCase "lists" $ do
    lpushx "notAKey" "-"          >>=? 0
    rpushx "notAKey" "-"          >>=? 0
    lpush "key" ["value"]         >>=? 1
    lpop "key"                    >>=? Just "value"
    rpush "key" ["value"]         >>=? 1
    rpop "key"                    >>=? Just "value"
    rpush "key" ["v2"]            >>=? 1
    linsertBefore "key" "v2" "v1" >>=? 2
    linsertAfter "key" "v2" "v3"  >>=? 3
    lindex "key" 0                >>=? Just "v1"
    lrange "key" 0 (-1)           >>=? ["v1", "v2", "v3"]
    lset "key" 1 "v2"             >>=? Ok
    lrem "key" 0 "v2"             >>=? 1
    llen "key"                    >>=? 2
    ltrim "key" 0 1               >>=? Ok

testBpop :: Test
testBpop = testCase "blocking push/pop" $ do
    lpush "key" ["v3","v2","v1"] >>=? 3
    blpop ["key"] 1              >>=? Just ("key","v1")
    brpop ["key"] 1              >>=? Just ("key","v3")
    rpush "k1" ["v1","v2"]       >>=? 2
    brpoplpush "k1" "k2" 1       >>=? Just "v2"
    rpoplpush "k1" "k2"          >>=? Just "v1"

------------------------------------------------------------------------------
-- Sets
--
testsSets :: [Test]
testsSets = [testSets, testSetAlgebra]

testSets :: Test
testSets = testCase "sets" $ do
    sadd "set" ["member"]       >>=? 1
    sismember "set" "member"    >>=? True
    scard "set"                 >>=? 1
    smembers "set"              >>=? ["member"]
    srandmember "set"           >>=? Just "member"
    spop "set"                  >>=? Just "member"
    srem "set" ["member"]       >>=? 0
    smove "set" "set'" "member" >>=? False
    _ <- sadd "set" ["member1", "member2"]
    (fmap L.sort <$> spopN "set" 2) >>=? ["member1", "member2"]
    _ <- sadd "set" ["member1", "member2"]
    (fmap L.sort <$> srandmemberN "set" 2) >>=? ["member1", "member2"]

testSetAlgebra :: Test
testSetAlgebra = testCase "set algebra" $ do
    sadd "s1" ["member"]          >>=? 1
    sdiff ["s1", "s2"]            >>=? ["member"]
    sunion ["s1", "s2"]           >>=? ["member"]
    sinter ["s1", "s2"]           >>=? []
    sdiffstore "s3" ["s1", "s2"]  >>=? 1
    sunionstore "s3" ["s1", "s2"] >>=? 1
    sinterstore "s3" ["s1", "s2"] >>=? 0

------------------------------------------------------------------------------
-- Sorted Sets
--
testsZSets :: [Test]
testsZSets = [testZSets, testZStore]

testZSets :: Test
testZSets = testCase "sorted sets" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")]          >>=? 3
    zcard "key"                                       >>=? 3
    zscore "key" "v3"                                 >>=? Just 40
    zincrby "key" 2 "v3"                              >>=? 42

    zrank "key" "v1"                                  >>=? Just 0
    zrevrank "key" "v1"                               >>=? Just 2
    zcount "key" 10 100                               >>=? 1

    zrange "key" 0 1                                  >>=? ["v1","v2"]
    zrevrange "key" 0 1                               >>=? ["v3","v2"]
    zrangeWithscores "key" 0 1                        >>=? [("v1",1),("v2",2)]
    zrevrangeWithscores "key" 0 1                     >>=? [("v3",42),("v2",2)]
    zrangebyscore "key" 0.5 1.5                       >>=? ["v1"]
    zrangebyscoreWithscores "key" 0.5 1.5             >>=? [("v1",1)]
    zrangebyscoreWithscores "key" (-inf) inf          >>=? [("v1",1.0),("v2",2.0),("v3",42.0)]
    zrangebyscoreLimit "key" 0.5 2.5 0 1              >>=? ["v1"]
    zrangebyscoreWithscoresLimit "key" 0.5 2.5 0 1    >>=? [("v1",1)]
    zrevrangebyscore "key" 1.5 0.5                    >>=? ["v1"]
    zrevrangebyscoreWithscores "key" 1.5 0.5          >>=? [("v1",1)]
    zrevrangebyscoreLimit "key" 2.5 0.5 0 1           >>=? ["v2"]
    zrevrangebyscoreWithscoresLimit "key" 2.5 0.5 0 1 >>=? [("v2",2)]

    zrem "key" ["v2"]                                 >>=? 1
    zremrangebyscore "key" 10 100                     >>=? 1
    zremrangebyrank "key" 0 0                         >>=? 1

testZStore :: Test
testZStore = testCase "zunionstore/zinterstore" $ do
    zadd "k1" [(1, "v1"), (2, "v2")] >>= \case
      Left _ -> error "error"
      _ -> return ()
    zadd "k2" [(2, "v2"), (3, "v3")] >>= \case
      Left _ -> error "error"
      _ -> return ()
    zinterstore "newkey" ["k1","k2"] Sum                >>=? 1
    zinterstoreWeights "newkey" [("k1",1),("k2",2)] Max >>=? 1
    zunionstore "newkey" ["k1","k2"] Sum                >>=? 3
    zunionstoreWeights "newkey" [("k1",1),("k2",2)] Min >>=? 3

------------------------------------------------------------------------------
-- HyperLogLog
--

testHyperLogLog :: Test
testHyperLogLog = testCase "hyperloglog" $ do
  -- test creation
  pfadd "hll1" ["a"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["hll1"] >>=? 1
  -- test cardinality
  pfadd "hll1" ["a"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["hll1"] >>=? 1
  pfadd "hll1" ["b", "c", "foo", "bar"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["hll1"] >>=? 5
  -- test merge
  pfadd "hll2" ["1", "2", "3"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfadd "hll3" ["4", "5", "6"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfmerge "hll4" ["hll2", "hll3"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["hll4"] >>=? 6
  -- test union cardinality
  pfcount ["hll2", "hll3"] >>=? 6

------------------------------------------------------------------------------
-- Pub/Sub
--
testPubSub :: Test
testPubSub testType conn = testCase "pubSub" go testType conn
  where
    go = do
        -- producer
        asyncProducer <- liftIO $ Async.async $ do
            runRedis conn $ do
                let t = 10^(5 :: Int)
                liftIO $ threadDelay t
                publish "chan1" "hello" >>=? 1
                liftIO $ threadDelay t
                publish "chan2" "world" >>=? 1
            return ()

        -- consumer
        pubSub (subscribe ["chan1"]) $ \msg -> do
            -- ready for a message
            case msg of
                Message{..} -> return
                    (unsubscribe [msgChannel] `mappend` psubscribe ["chan*"])
                PMessage{..} -> return (punsubscribe [msgPattern])

        pubSub (subscribe [] `mappend` psubscribe []) $ \_ -> do
            liftIO $ HUnit.assertFailure "no subs: should return immediately"
            undefined
        liftIO $ Async.wait asyncProducer


------------------------------------------------------------------------------
-- Transaction
--
testTransaction :: Test
testTransaction = testCase "transaction" $ do
    watch ["k1", "k2"] >>=? Ok
    unwatch            >>=? Ok
    set "foo" "foo" >>= \case
      Left _ -> error "error"
      _ -> return ()
    set "bar" "bar" >>= \case
      Left _ -> error "error"
      _ -> return ()
    foobar <- multiExec $ do
        foo <- get "foo"
        bar <- get "bar"
        return $ (,) <$> foo <*> bar
    assert $ foobar == TxSuccess (Just "foo", Just "bar")


------------------------------------------------------------------------------
-- Scripting
--
testScripting :: Test
testScripting testType conn = testCase "scripting" go testType conn
  where
    go = do
        let script    = "return {false, 42}"
            scriptRes = (False, 42 :: Integer)
        scriptLoad script >>= \case
          Left _ -> error "error"
          Right scriptHash -> do
            eval script [] []                       >>=? scriptRes
            evalsha scriptHash [] []                >>=? scriptRes
            scriptExists [scriptHash, "notAScript"] >>=? [True, False]
            scriptFlush                             >>=? Ok
            -- start long running script from another client
            configSet "lua-time-limit" "100"        >>=? Ok
            evalFinished <- liftIO newEmptyMVar
            asyncScripting <- liftIO $ Async.async $ runRedis conn $ do
                -- we must pattern match to block the thread
                (eval "while true do end" [] []
                    :: Redis (Either Reply Integer)) >>= \case
                    Left _ -> return ()
                    _ -> error "impossible"
                liftIO (putMVar evalFinished ())
                return ()
            liftIO (threadDelay 500000) -- 0.5s
            scriptKill                              >>=? Ok
            () <- liftIO (takeMVar evalFinished)
            liftIO $ Async.wait asyncScripting
            return ()

------------------------------------------------------------------------------
-- Connection
--
testsConnection :: [Test]
testsConnection = [ testConnectAuth, testConnectAuthUnexpected, testConnectDb
                  , testConnectDbUnexisting, testEcho, testPing, testSelect ]

testConnectAuth :: Test
testConnectAuth = testCase "connect/auth" $ do
    configSet "requirepass" "pass" >>=? Ok
    liftIO $ do
        c <- checkedConnect defaultConnectInfo { connectAuth = Just "pass" }
        runRedis c (ping >>=? Pong)
    auth "pass"                    >>=? Ok
    configSet "requirepass" ""     >>=? Ok

testConnectAuthUnexpected :: Test
testConnectAuthUnexpected = testCase "connect/auth/unexpected" $ do
    liftIO $ do
        res <- try $ void $ checkedConnect connInfo
        HUnit.assertEqual "" err res

    where connInfo = defaultConnectInfo { connectAuth = Just "pass" }
          err = Left $ ConnectAuthError $
                  Error "ERR Client sent AUTH, but no password is set"

testConnectDb :: Test
testConnectDb = testCase "connect/db" $ do
    set "connect" "value" >>=? Ok
    liftIO $ void $ do
        c <- checkedConnect defaultConnectInfo { connectDatabase = 1 }
        runRedis c (get "connect" >>=? Nothing)

testConnectDbUnexisting :: Test
testConnectDbUnexisting = testCase "connect/db/unexisting" $ do
    liftIO $ do
        res <- try $ void $ checkedConnect connInfo
        case res of
          Left (ConnectSelectError _) -> return ()
          _ -> HUnit.assertFailure $
                  "Expected ConnectSelectError, got " ++ show res

    where connInfo = defaultConnectInfo { connectDatabase = 100 }

testEcho :: Test
testEcho = testCase "echo" $
    echo ("value" ) >>=? "value"

testPing :: Test
testPing = testCase "ping" $ ping >>=? Pong

testQuit :: Test
testQuit = testCase "quit" $ quit >>=? Ok

testSelect :: Test
testSelect = testCase "select" $ do
    select 13 >>=? Ok
    select 0 >>=? Ok


------------------------------------------------------------------------------
-- Server
--
testsServer :: [Test]
testsServer =
    [testServer, testBgrewriteaof, testFlushall, testInfo, testConfig
    ,testSlowlog, testDebugObject]

testServer :: Test
testServer = testCase "server" $ do
    time >>= \case
      Right (_,_) -> return ()
      Left _ -> error "error"
    slaveof "no" "one" >>=? Ok
    return ()

testBgrewriteaof :: Test
testBgrewriteaof = testCase "bgrewriteaof/bgsave/save" $ do
    save >>=? Ok
    bgsave >>= \case
      Right (Status _) -> return ()
      _ -> error "error"
    -- Redis needs time to finish the bgsave
    liftIO $ threadDelay (10^(5 :: Int))
    bgrewriteaof >>= \case
      Right (Status _) -> return ()
      _ -> error "error"
    return ()

testConfig :: Test
testConfig = testCase "config/auth" $ do
    configGet "requirepass"        >>=? [("requirepass", "")]
    configSet "requirepass" "pass" >>=? Ok
    auth "pass"                    >>=? Ok
    configSet "requirepass" ""     >>=? Ok

testFlushall :: Test
testFlushall = testCase "flushall/flushdb" $ do
    flushall >>=? Ok
    flushdb  >>=? Ok

testInfo :: Test
testInfo = testCase "info/lastsave/dbsize" $ do
    info >>= \case
      Left _ -> error "error"
      _ -> return ()
    lastsave >>= \case
      Left _ -> error "error"
      _ -> return ()
    dbsize          >>=? 0
    configResetstat >>=? Ok

testSlowlog :: Test
testSlowlog = testCase "slowlog" $ do
    slowlogReset >>=? Ok
    slowlogGet 5 >>=? []
    slowlogLen   >>=? 0

testDebugObject :: Test
testDebugObject = testCase "debugObject/debugSegfault" $ do
    set "key" "value" >>=? Ok
    debugObject "key" >>= \case
      Left _ -> error "error"
      _ -> return ()
    return ()

testScans :: Test
testScans = testCase "scans" $ do
    set "key" "value"       >>=? Ok
    scan cursor0            >>=? (cursor0, ["key"])
    scanOpts cursor0 sOpts1 >>=? (cursor0, ["key"])
    scanOpts cursor0 sOpts2 >>=? (cursor0, [])
    sadd "set" ["1"]        >>=? 1
    sscan "set" cursor0     >>=? (cursor0, ["1"])
    hset "hash" "k" "v"     >>=? True
    hscan "hash" cursor0    >>=? (cursor0, [("k", "v")])
    zadd "zset" [(42, "2")] >>=? 1
    zscan "zset" cursor0    >>=? (cursor0, [("2", 42)])
    where sOpts1 = defaultScanOpts { scanMatch = Just "k*" }
          sOpts2 = defaultScanOpts { scanMatch = Just "not*"}

testZrangelex ::Test
testZrangelex = testCase "zrangebylex" $ do
    let testSet = [(10, "aaa"), (10, "abb"), (10, "ccc"), (10, "ddd")]
    zadd "zrangebylex" testSet                          >>=? 4
    zrangebylex "zrangebylex" (Incl "aaa") (Incl "bbb") >>=? ["aaa","abb"]
    zrangebylex "zrangebylex" (Excl "aaa") (Excl "ddd") >>=? ["abb","ccc"]
    zrangebylex "zrangebylex" Minr Maxr                 >>=? ["aaa","abb","ccc","ddd"]
    zrangebylexLimit "zrangebylex" Minr Maxr 2 1        >>=? ["ccc"]

testXAddRead ::Test
testXAddRead = testCase "xadd/xread" $ do
    xadd "somestream" "123" [("key", "value"), ("key2", "value2")]
    xadd "otherstream" "456" [("key1", "value1")]
    xaddOpts "thirdstream" "*" [("k", "v")] (Maxlen 1)
    xaddOpts "thirdstream" "*" [("k", "v")] (ApproxMaxlen 1)
    xread [("somestream", "0"), ("otherstream", "0")] >>=? Just [
        XReadResponse {
            stream = "somestream",
            records = [StreamsRecord{recordId = "123-0", keyValues = [("key", "value"), ("key2", "value2")]}]
        },
        XReadResponse {
            stream = "otherstream",
            records = [StreamsRecord{recordId = "456-0", keyValues = [("key1", "value1")]}]
        }]
    xlen "somestream" >>=? 1

testXReadGroup ::Test
testXReadGroup = testCase "XGROUP */xreadgroup/xack" $ do
    xadd "somestream" "123" [("key", "value")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroup "somegroup" "consumer1" [("somestream", ">")] >>=? Just [
        XReadResponse {
            stream = "somestream",
            records = [StreamsRecord{recordId = "123-0", keyValues = [("key", "value")]}]
        }]
    xack "somestream" "somegroup" ["123-0"] >>=? 1
    xreadGroup "somegroup" "consumer1" [("somestream", ">")] >>=? Nothing
    xgroupSetId "somestream" "somegroup" "0" >>=? Ok
    xgroupDelConsumer "somestream" "somegroup" "consumer1" >>=? 0
    xgroupDestroy "somestream" "somegroup" >>=? True

testXRange ::Test
testXRange = testCase "xrange/xrevrange" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xrange "somestream" "122" "123" Nothing >>=? [
        StreamsRecord{recordId = "122-0", keyValues = [("key2", "value2")]},
        StreamsRecord{recordId = "123-0", keyValues = [("key3", "value3")]}
        ]
    xrevRange "somestream" "123" "122" Nothing >>=? [
        StreamsRecord{recordId = "123-0", keyValues = [("key3", "value3")]},
        StreamsRecord{recordId = "122-0", keyValues = [("key2", "value2")]}
        ]

testXpending ::Test
testXpending = testCase "xpending" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroup "somegroup" "consumer1" [("somestream", ">")]
    xpendingSummary "somestream" "somegroup" Nothing >>=? XPendingSummaryResponse {
        numPendingMessages = 4,
        smallestPendingMessageId = "121-0",
        largestPendingMessageId = "124-0",
        numPendingMessagesByconsumer = [("consumer1", 4)]
    }
    detail <- xpendingDetail "somestream" "somegroup" "121" "121" 10 Nothing
    liftIO $ case detail of
        Left reply   -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right [XPendingDetailRecord{..}] -> do
            messageId HUnit.@=? "121-0"
        Right bad -> HUnit.assertFailure $ "Unexpectedly got " ++ show bad

testXClaim ::Test
testXClaim =
  testCase "xclaim" $ do
    xadd "somestream" "121" [("key1", "value1")] >>=? "121-0"
    xadd "somestream" "122" [("key2", "value2")] >>=? "122-0"
    xgroupCreate "somestream" "somegroup" "0" >>=? Ok
    xreadGroupOpts
      "somegroup"
      "consumer1"
      [("somestream", ">")]
      (defaultXreadOpts {recordCount = Just 2}) >>=?
      Just
        [ XReadResponse
            { stream = "somestream"
            , records =
                [ StreamsRecord
                    {recordId = "121-0", keyValues = [("key1", "value1")]}
                , StreamsRecord
                    {recordId = "122-0", keyValues = [("key2", "value2")]}
                ]
            }
        ]
    xclaim "somestream" "somegroup" "consumer2" 0 defaultXClaimOpts ["121-0"] >>=?
      [StreamsRecord {recordId = "121-0", keyValues = [("key1", "value1")]}]
    xclaimJustIds
      "somestream"
      "somegroup"
      "consumer2"
      0
      defaultXClaimOpts
      ["122-0"] >>=?
      ["122-0"]

testXInfo ::Test
testXInfo = testCase "xinfo" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroupOpts "somegroup" "consumer1" [("somestream", ">")] (defaultXreadOpts { recordCount = Just 2})
    consumerInfos <- xinfoConsumers "somestream" "somegroup"
    liftIO $ case consumerInfos of
        Left reply -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right [XInfoConsumersResponse{..}] -> do
            xinfoConsumerName HUnit.@=? "consumer1"
            xinfoConsumerNumPendingMessages HUnit.@=? 2
        Right bad -> HUnit.assertFailure $ "Unexpectedly got " ++ show bad
    xinfoGroups "somestream" >>=? [
        XInfoGroupsResponse{
            xinfoGroupsGroupName = "somegroup",
            xinfoGroupsNumConsumers = 1,
            xinfoGroupsNumPendingMessages = 2,
            xinfoGroupsLastDeliveredMessageId = "122-0"
        }]
    xinfoStream "somestream" >>=? XInfoStreamResponse
        { xinfoStreamLength = 2
        , xinfoStreamRadixTreeKeys = 1
        , xinfoStreamRadixTreeNodes = 2
        , xinfoStreamNumGroups = 1
        , xinfoStreamLastEntryId = "122-0"
        , xinfoStreamFirstEntry = StreamsRecord
            { recordId = "121-0"
            , keyValues = [("key1", "value1")]
            }
        , xinfoStreamLastEntry = StreamsRecord
            { recordId = "122-0"
            , keyValues = [("key2", "value2")]
            }
        }

testXDel ::Test
testXDel = testCase "xdel" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xdel "somestream" ["122"] >>=? 1
    xlen "somestream" >>=? 1

testXTrim ::Test
testXTrim = testCase "xtrim" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xadd "somestream" "125" [("key5", "value5")]
    xtrim "somestream" (Maxlen 2) >>=? 3
