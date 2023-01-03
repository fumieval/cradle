{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Cradle
  ( CradleConfig(..)
  , cradleConfig
  , Cradle
  , withCradle
  , takeCradle
  -- * Common interface
  , Reacquire(..)
  , reacquire
  -- * Logging
  , CradleEvent(..)
  , showCradleEvent
  , logCradleEvent
  -- * Internal
  , newEmptyCradle
  , acquireCradle
  , releaseCradle
  ) where

import Control.Concurrent
import Control.Monad
import Control.Monad.Catch
import Control.Retry
import Control.Monad.IO.Unlift
import Data.Typeable

data CradleConfig a = CradleConfig
  { acquire :: Int -> RetryStatus -> IO a
  , release :: Int -> a -> IO ()
  , policy :: RetryPolicyM IO
  , shouldReacquire :: SomeException -> IO Bool
  }

data CradleEvent a
  = Acquiring Int RetryStatus
  | Acquired Int
  | Released Int
  deriving Show

showCradleEvent :: Typeable a => CradleEvent a -> String
showCradleEvent e = unwords $ case e of
  Acquiring i status
    | rsIterNumber status == 0 -> line i "Acquiring"
    | otherwise -> line i "Acquiring" <> ["attempts:", show $ rsIterNumber status]
  Acquired i -> line i "Acquired"
  Released i -> line i "Released"
  where
    line i str = [str, show $ typeOf e, "#" <> show i]

logCradleEvent
  :: (CradleEvent a -> IO ())
  -> CradleConfig a
  -> CradleConfig a
logCradleEvent logger config = CradleConfig
  { acquire = \num status -> do
    logger $ Acquiring num status
    a <- acquire config num status
    logger $ Acquired num
    pure a
  , release = \i a -> do
    release config i a
    logger $ Released i
  , policy = policy config
  , shouldReacquire = shouldReacquire config
  }

-- | Smart constructor for 'CradleConfig'
cradleConfig :: IO a -- ^ acquire a resource
  -> (a -> IO ()) -- ^ drop a resource
  -> CradleConfig a
cradleConfig create release = CradleConfig
  { acquire = \_ _ -> create
  , release = const release
  , policy = retryPolicyDefault
  , shouldReacquire = const $ pure False
  }

data Cradle a = Cradle
  { config :: CradleConfig a
  , reference :: MVar (Int, Maybe a)
  }

withCradle
  :: CradleConfig a
  -> (Cradle a -> IO r)
  -> IO r
withCradle config = bracket (acquireCradle config) releaseCradle

-- | Defers acquisition until the first call to 'takeCradle'
newEmptyCradle :: CradleConfig a -> IO (Cradle a)
newEmptyCradle config = do
  reference <- newMVar (0, Nothing)
  pure Cradle{..}

acquireCradle :: CradleConfig a -> IO (Cradle a)
acquireCradle config@CradleConfig{..} = do
  resource <- acquire 0 defaultRetryStatus
  reference <- newMVar (0, Just resource)
  pure Cradle{..}

releaseCradle :: Cradle a -> IO ()
releaseCradle Cradle{ config = CradleConfig{..}, ..} = do
  (i, a) <- takeMVar reference
  mapM_ (release i) a

-- | Run an action using the content of the 'Cradle'.
takeCradle :: MonadUnliftIO m => Cradle a -> (a -> m r) -> m r
takeCradle Cradle{ config = CradleConfig{..}, .. } cont = withRunInIO $ \runInIO -> recovering
  policy
  [ const $ Handler shouldReacquire,
    const $ Handler $ \Reacquire -> pure True
  ]
  $ \status -> do
    (i, resource) <- modifyMVar reference $ \case
      (i, Nothing) -> do
        resource <- acquire i status
        pure ((i, Just resource), (i, resource))
      v@(i, Just c) -> pure (v, (i, c))

    try (runInIO $ cont resource) >>= \case
      Right a -> pure a
      Left e -> do
        b <- case fromException e of
          Just Reacquire -> pure True
          _ -> shouldReacquire e
        when b $ do
          modifyMVar_ reference $ \case
            -- Drop the existing resource when reacquisition is requested,
            -- unless the current sequential number is different
            -- i.e. another thread already acquired a new resource
            (j, Just _) | i == j -> (i + 1, Nothing) <$ release i resource
            x -> pure x
        throwM e

data Reacquire = Reacquire deriving (Show, Eq)
instance Exception Reacquire

-- | When this is thrown inside `takeCradle`, it attempts to recreate a resource.
reacquire :: MonadThrow m => m r
reacquire = throwM Reacquire