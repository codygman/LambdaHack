-- | Personal game configuration file type definitions.
module Game.LambdaHack.Client.Config
  ( ConfigUI(..)
  ) where

import Control.DeepSeq

import Game.LambdaHack.Common.HumanCmd
import qualified Game.LambdaHack.Common.Key as K

-- | Fully typed contents of the UI config file. This config
-- is a part of a game client.
data ConfigUI = ConfigUI
  { -- commands
    configCommands    :: ![(K.KM, (CmdCategory, HumanCmd))]
    -- files
  , configAppDataDir  :: !FilePath
  , configUICfgFile   :: !FilePath
  , configSavePrefix  :: !String
    -- ui
  , configFont        :: !String
  , configHistoryMax  :: !Int
  , configMaxFps      :: !Int
  , configNoAnim      :: !Bool
  , configRunStopMsgs :: !Bool
  }
  deriving Show

instance NFData ConfigUI
