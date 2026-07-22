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
import Domain.Configuration.Dictionary (Dictionary (..), DictionaryEntry (..), DictionaryKind (..), EntryRole (ItemRole))
import Domain.Configuration.Projection (Configuration (..), emptyBankingConfiguration, emptyConfigurationDefaults)
import Domain.Core.Types
  ( CreatedBy (System),
    Currency (USD),
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import RIO
import Test.Hspec

seedConfig :: DictionaryKind -> Configuration
seedConfig dictKind =
  Configuration
    { baseCurrency = USD,
      defaultCurrency = USD,
      dictionaries =
        Map.singleton
          dictKind
          Dictionary
            { entries =
                [ DictionaryEntry
                    { entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0),
                      name = unsafeEntryName "only",
                      role = ItemRole,
                      parentId = Nothing
                    }
                ]
            },
      banking = emptyBankingConfiguration,
      createdBy = System,
      isCreated = True,
      booksClosedThrough = Nothing,
      defaults = emptyConfigurationDefaults
    }

spec :: Spec
spec = describe "CannotRemoveLastEntry predicate" $ do
  it "still refuses for income-category when it would become empty"
    $ let config = seedConfig IncomeKind
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryKind = IncomeKind,
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "still refuses for expense-category when it would become empty"
    $ let config = seedConfig ExpenseKind
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryKind = ExpenseKind,
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "allows removing the last labels entry"
    $ let config = seedConfig LabelKind
          cmd =
            RemoveDictionaryEntryConfigurationCommand
              RemoveDictionaryEntry
                { dictionaryKind = LabelKind,
                  entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
                }
       in handleConfigurationCommand config cmd `shouldSatisfy` isRight
