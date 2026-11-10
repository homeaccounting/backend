-- |
-- Module      : Domain.Transaction.TransferFeesPropertySpec
-- Description : Property tests for transfer fee allocations (mkTransfer et al.)
module Domain.Transaction.TransferFeesPropertySpec (spec) where

import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
import Domain.Transaction.Types
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators

feeOf :: Currency -> Rational -> Gen Allocations
feeOf cur amt = do
  cid <- genDictionaryEntryId
  pure (mkExpenseAllocations (Allocation cid (unsafeMoney cur amt) Nothing NE.:| []))

validationField :: Either DomainError a -> Maybe Text
validationField (Left (ValidationErr e)) = Just e.validationField
validationField _ = Nothing

spec :: Spec
spec = describe "TransferFees" $ do
  prop "mkTransfer accepts generated valid fees" $
    forAll genPositiveMoney $ \src ->
      forAll (genTransferFees src) $ \f ->
        isRight (mkTransfer src f)

  prop "transferFeeTotal is below the source amount for accepted transfers" $
    forAll genPositiveMoney $ \src ->
      forAll (genTransferFees src) $ \f ->
        case mkTransfer src f of
          Right tt -> transferFeeTotal tt < unMoney src
          Left _ -> False

  prop "transferGrossAmount inverts transferNetAmount for accepted transfers" $
    forAll genPositiveMoney $ \src ->
      forAll (genTransferFees src) $ \f ->
        case mkTransfer src f of
          Right tt -> fmap (`transferGrossAmount` tt) (transferNetAmount src tt) === Right src
          Left _ -> property False

  prop "transferFeeTotal is zero without fees" $
    transferFeeTotal (Transfer Nothing) === 0

  prop "rejects an income-bucket fee" $
    forAll genPositiveMoney $ \src ->
      forAll genDictionaryEntryId $ \cid ->
        let a = mkIncomeAllocations (Allocation cid (unsafeMoney (moneyCurrency src) (unMoney src / 2)) Nothing NE.:| [])
         in mkTransfer src (Just a) === Left TransferFeeIncomeNotSupported

  prop "rejects fees equal to or above the source amount" $
    forAll genPositiveMoney $ \src ->
      forAll (elements [1, 2]) $ \k ->
        forAll (feeOf (moneyCurrency src) (unMoney src * k)) $ \a ->
          mkTransfer src (Just a) === Left TransferFeesNotBelowSource

  prop "rejects a fee in another currency" $
    forAll genPositiveMoney $ \src ->
      forAll (feeOf (if moneyCurrency src == USD then UAH else USD) (unMoney src / 2)) $ \a ->
        validationField (mkTransfer src (Just a)) === Just (T.pack "currency")

  prop "rejects a non-positive fee" $
    forAll genPositiveMoney $ \src ->
      forAll (elements [0, -1]) $ \k ->
        forAll (feeOf (moneyCurrency src) k) $ \a ->
          validationField (mkTransfer src (Just a)) === Just (T.pack "amount")

  prop "allocationsOf (Transfer f) == f" $
    forAll genFees $
      \f -> allocationsOf (Transfer f) === f

  prop "replaceAllocations replaces fees on a fee transfer" $
    forAll genAllocs $ \a -> forAll genAllocs $ \b ->
      replaceAllocations b (Transfer (Just a)) === Transfer (Just b)

  prop "replaceAllocations is a no-op on a plain transfer" $
    forAll genAllocs $
      \b -> replaceAllocations b (Transfer Nothing) === Transfer Nothing
  where
    genAllocs = genPositiveMoney >>= \m -> feeOf (moneyCurrency m) (unMoney m)
    genFees = genPositiveMoney >>= genTransferFees
