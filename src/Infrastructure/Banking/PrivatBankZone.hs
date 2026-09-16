{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.PrivatBankZone
-- Description : The time zone PrivatBank statement clocks are written in
--
-- A downloaded statement stamps a wall clock with no offset and no zone marker,
-- so the zone is a property of the provider's format and its parser must apply
-- it (ADR 005). PrivatBank writes Kyiv local time in both the retail (Privat24
-- @Історія операцій@) and business (Автоклієнт) exports, which are parsed by two
-- separate modules — so the zone lives here, named once, rather than as a
-- literal copied into each of them where the two could silently disagree.
--
-- It is flag-free (like 'Infrastructure.Banking.ExternalId') because the two
-- parsers sit behind /different/ Cabal flags — @flag(privatbank)@ and
-- @flag(privatbank-business)@ — so neither can own a constant the other needs.
module Infrastructure.Banking.PrivatBankZone
  ( privatBankZone,
  )
where

import Data.Time.Zones.All (TZLabel (..))

-- | The IANA zone of a PrivatBank statement's wall clock.
--
-- Note the label spelling: @tz@ (0.1.3.6) predates the @Europe/Kyiv@ rename, so
-- the constructor is still @Europe__Kiev@. Bumping @tz@/@tzdata@ past the rename
-- is the one place that has to change.
privatBankZone :: TZLabel
privatBankZone = Europe__Kiev
