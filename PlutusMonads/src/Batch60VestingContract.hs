{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}   
{-# LANGUAGE DeriveGeneric         #-}  
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module Batch60VestingContract where

import           Control.Monad        hiding (fmap)
import           Data.Aeson           (ToJSON, FromJSON)       
import           Data.Map             as Map                  
import           Data.Text            (Text)
import           Data.Void            (Void)
import           GHC.Generics         (Generic)

import           Plutus.Contract

import           Plutus.Trace.Emulator as Emulator
import           Wallet.Emulator.Wallet

import           PlutusTx            (Data (..))
import qualified PlutusTx
import           PlutusTx.Prelude     hiding (Semigroup(..), unless)
import           Ledger               hiding (singleton)
import           Ledger.Address
import           Ledger.Constraints   (TxConstraints)
import qualified Ledger.Constraints   as Constraints
import qualified Ledger.Typed.Scripts as Scripts
import           Ledger.Ada           as Ada

import           Playground.Contract  (printJson, printSchemas, ensureKnownCurrencies, stage, ToSchema)
import           Playground.TH        (mkKnownCurrencies, mkSchemaDefinitions)
import           Playground.Types     (KnownCurrency (..))

import           Prelude              (IO, Semigroup (..), Show (..), String)
import           Text.Printf          (printf)

--ON-CHAIN
data VestingParams = VestingParams
                    { beneficiary :: PaymentPubKeyHash
                    , executionTime :: POSIXTime
                    } deriving Show

PlutusTx.makeLift ''VestingParams

{-# INLINABLE paramsValidator #-}
paramsValidator :: VestingParams -> () -> () -> ScriptContext -> Bool
paramsValidator params _ _ sContext = traceIfFalse "Beneficiary's signature missing" signedByBeneficiary &&
                                      traceIfFalse "Deadline not reached" executionTimeReached
   where
    info :: TxInfo
    info = scriptContextTxInfo sContext

    signedByBeneficiary :: Bool
    signedByBeneficiary = txSignedBy info $ unPaymentPubKeyHash $ beneficiary params

    executionTimeReached :: Bool
    executionTimeReached = contains (from $ executionTime params) $ txInfoValidRange info

data Vesting                                                          -- Enconding the type of the datum and the redeemer 
instance Scripts.ValidatorTypes Vesting where
    type instance DatumType Vesting = ()                    -- Instance for the Datum
    type instance RedeemerType Vesting = ()                           -- Instance for the Reederm, unit since its not been used

typedValidator :: VestingParams -> Scripts.TypedValidator Vesting
typedValidator params = Scripts.mkTypedValidator @Vesting
    ($$(PlutusTx.compile [|| paramsValidator ||]) `PlutusTx.applyCode` PlutusTx.liftCode params)
    $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @() @()

validator :: VestingParams -> Validator
validator = Scripts.validatorScript . typedValidator

scrAddress ::VestingParams -> Ledger.Address
scrAddress = scriptAddress . validator

-- OFF-CHAIN 

data GiveParams = GiveParams
     { gpBeneficiary :: !PaymentPubKeyHash
     , gpExecutionTime    :: !POSIXTime 
     , gpAmount       :: !Integer
     } deriving (Generic, ToJSON, FromJSON, ToSchema)


type VestingSchema =
        Endpoint "give" GiveParams
    .\/ Endpoint "grab" POSIXTime

give :: AsContractError e => GiveParams -> Contract w s e ()
give gp = do
          let params = VestingParams
                    { beneficiary = gpBeneficiary gp
                    , executionTime    = gpExecutionTime gp
                    }
              tx = Constraints.mustPayToTheScript () $ Ada.lovelaceValueOf $ gpAmount gp 
          ledgerTx <- submitTxConstraints (typedValidator params) tx
          void $ awaitTxConfirmed $ getCardanoTxId ledgerTx
          logInfo @String $ printf "Made a gift of %d lovelace to %s with release time = %s"
           (gpAmount gp)
           (show $ gpBeneficiary gp)
           (show $ gpExecutionTime gp)

grab :: forall w s e. AsContractError e => POSIXTime -> Contract w s e ()
grab dln = do
    now   <- currentTime
    pkh   <- ownPaymentPubKeyHash
    if now < dln
        then logInfo @String $ "too early!"
        else do
            let params = VestingParams
                         { beneficiary = pkh
                         , executionTime    = dln
                         }
            utxos <- utxosAt $ scrAddress params
            if Map.null utxos
                then logInfo @String $ "no gifts available"
                else do
                    let orefs   = fst <$> Map.toList utxos
                        lookups = Constraints.unspentOutputs utxos  <>
                          Constraints.otherScript (validator params)
                        tx :: TxConstraints Void Void
                        tx = mconcat [Constraints.mustSpendScriptOutput oref unitRedeemer | oref <- orefs] <>
                                      Constraints.mustValidateIn (from now)
                    ledgerTx <- submitTxConstraintsWith @Void lookups tx
                    void $ awaitTxConfirmed $ getCardanoTxId ledgerTx
                    logInfo @String $ "collected gifts"
  
endpoints :: Contract () VestingSchema Text ()
endpoints = awaitPromise (give' `select` grab') >> endpoints
  where
    give' = endpoint @"give" give
    grab' = endpoint @"grab" grab

mkSchemaDefinitions ''VestingSchema
mkKnownCurrencies []

-- SIMULATION

test :: IO ()
test = runEmulatorTraceIO $ do
       h1 <- activateContractWallet (knownWallet 1) endpoints
       h2 <- activateContractWallet (knownWallet 2) endpoints
       h3 <- activateContractWallet (knownWallet 3) endpoints
       callEndpoint @"give" h1 $ GiveParams
                               { gpBeneficiary = PaymentPubKeyHash "80a4f45b56b88d1139da23bc4c3c75ec6d32943c087f250b86193ca7"
                               , gpExecutionTime = 1596059111000 
                               , gpAmount      = 33000000
                               }
       void $ Emulator.waitNSlots 5
       callEndpoint @"grab" h3 1596059111000                        
       void $ Emulator.waitNSlots 10
       callEndpoint @"grab" h2 1596059111000
       void $ Emulator.waitNSlots 10
       void $ Emulator.waitNSlots 5
       callEndpoint @"grab" h3 1596059111000est :: IO ()
test 
       callEndpoint @"grab" h2 1596059111000
       void $ Emulator.waitNSlots 10