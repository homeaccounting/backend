{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.LabelsDictionarySpec
-- Description : Relaxed CannotRemoveLastEntry rule for the `labels` dictionary.
module Domain.Configuration.LabelsDictionarySpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Configuration.CommandHandler
  ( ConfigurationCommand (..),
    ConfigurationError (..),
    handleConfigurationCommand,
  )
import Domain.Configuration.Commands (RemoveDictionaryEntry (..))
import Domain.Configuration.Projection (Configuration (..))
import Domain.Core.Types
  ( CreatedBy (System),
    Currency (USD),
    Dictionary (..),
    DictionaryEntry (..),
    DictionaryId (..),
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import RIO
import Test.Hspec

seedConfig :: DictionaryId -> Configuration
seedConfig dictId =
  Configuration
    { baseCurrency = USD,
      defaultCurrency = USD,
      dictionaries =
        Map.singleton
          dictId
          Dictionary
            { entries =
                [ DictionaryEntry
                    { entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0),
                      name = unsafeEntryName "only"
                    }
                ]
            },
      createdBy = System,
      isCreated = True
    }

spec :: Spec
spec = describe "CannotRemoveLastEntry predicate" $ do
  it "still refuses for income-category when it would become empty"
    $ let config = seedConfig (DictionaryId "income-category")
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryId = DictionaryId "income-category",
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "still refuses for expense-category when it would become empty"
    $ let config = seedConfig (DictionaryId "expense-category")
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryId = DictionaryId "expense-category",
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "allows removing the last labels entry"
    $ let config = seedConfig (DictionaryId "labels")
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryId = DictionaryId "labels",
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldSatisfy` isRight
