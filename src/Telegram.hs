-- |
-- Module      : Telegram
-- Description : Telegram bot integration
--
-- This module re-exports all Telegram bot components, providing a single
-- import point for bot functionality.
--
-- Available Modules:
--   - Types: Bot state, conversation state, callback data
--   - Bot: Initialization and main loop
--   - Commands: Command handlers
--   - Keyboards: Inline keyboard builders
--
-- Usage:
-- >>> import Telegram
module Telegram
  ( -- * Bot Types
    module Telegram.Types,

    -- * Bot Core
    module Telegram.Bot,

    -- * Commands
    module Telegram.Commands,

    -- * Keyboards
    module Telegram.Keyboards,
  )
where

import Telegram.Bot
import Telegram.Commands
import Telegram.Keyboards
import Telegram.Types
