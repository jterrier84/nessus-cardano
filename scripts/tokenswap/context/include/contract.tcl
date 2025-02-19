
proc scriptMintTokens {fromInfo mintAmount tokenName} {
  global POLICY_ID
  global SCRIPTS_DIR
  global MIN_TOKEN_LOVELACE
  set assetClass "$POLICY_ID.$tokenName"
  set fromName [dict get $fromInfo name]
  set fromAddr [dict get $fromInfo addr]

  logInfo "Mint $mintAmount $tokenName tokens for $fromName"

  set fromUtxos [queryUtxos $fromInfo]

  # Find fees and collateral
  set txidFees [findFeesId $fromUtxos [toLovelace 4]]
  set txidCollateral [findCollateralId $fromUtxos $txidFees]
  logInfo "Fees: $txidFees [dict get $fromUtxos $txidFees value]"
  logInfo "Collateral: $txidCollateral [dict get $fromUtxos $txidCollateral value]"

  # Build the Tx
  logInfo "Build token mint transaction"
  set args [networkAwareCmd [list "transaction" "build"]]
  lappend args "--alonzo-era"
  lappend args "--tx-in" $txidFees
  lappend args "--tx-in-collateral" $txidCollateral
  lappend args "--mint" "$mintAmount $assetClass"
  lappend args "--mint-script-file" "/var/cardano/local/$SCRIPTS_DIR/minttokens.plutus"
  lappend args "--mint-redeemer-value" $mintAmount
  lappend args "--tx-out" "$fromAddr+$MIN_TOKEN_LOVELACE+$mintAmount $assetClass"
  lappend args "--change-address" $fromAddr
  lappend args "--protocol-params-file" [getProtocolConfig]
  lappend args "--out-file" "/var/cardano/local/scratch/tx.raw"
  cardano-cli $args

  # Sign the Tx
  cliTxSign $fromInfo

  # Submit the Tx
  cliTxSubmit $fromInfo $txidFees
}

proc scriptBurnTokens {fromInfo burnAmount tokenName} {
  global POLICY_ID
  global SCRIPTS_DIR
  global MIN_COLLATERAL
  global MIN_TOKEN_LOVELACE
  set assetClass "$POLICY_ID.$tokenName"
  set fromName [dict get $fromInfo name]
  set fromAddr [dict get $fromInfo addr]

  logInfo "Burn $burnAmount $tokenName tokens for $fromName"

  set fromUtxos [queryUtxos $fromInfo]

  # Select utxos
  set tkinAmount 0
  set selectedIds [list]
  foreach txid [dict keys $fromUtxos] {
    set subdct [dict get $fromUtxos $txid value]
    set symbols [dict keys $subdct]
    if {$tkinAmount < $burnAmount && [lsearch $symbols $assetClass] > 0} {
      set amount [dict get $subdct $assetClass]
      lappend selectedIds $txid
      incr tkinAmount $amount
    }
  }

  if { $tkinAmount <= 0 } {
    logWarn "Cannot find tokens to burn"
    return false
  }

  # Find fees and collateral
  set firstTxid [lindex $selectedIds 0]
  set txidCollateral [findCollateralId $fromUtxos]
  logInfo "Collateral: $txidCollateral [dict get $fromUtxos $txidCollateral value]"

  # Build the Tx
  logInfo "Build token burn transaction"
  set args [networkAwareCmd [list "transaction" "build"]]
  lappend args "--alonzo-era"
  foreach txid $selectedIds {
    lappend args "--tx-in" $txid
  }
  if {$burnAmount < $tkinAmount} {
    set tkrefund [expr {$tkinAmount - $burnAmount}]
    lappend args "--tx-out" "$fromAddr+$MIN_TOKEN_LOVELACE+$tkrefund $assetClass"
  }
  lappend args "--tx-in-collateral" $txidCollateral
  lappend args "--mint" "-$burnAmount $assetClass"
  lappend args "--mint-script-file" "/var/cardano/local/$SCRIPTS_DIR/minttokens.plutus"
  lappend args "--mint-redeemer-value" "-$burnAmount"
  lappend args "--change-address" $fromAddr
  lappend args "--protocol-params-file" [getProtocolConfig]
  lappend args "--out-file" "/var/cardano/local/scratch/tx.raw"
  cardano-cli $args

  # Sign the Tx
  cliTxSign $fromInfo

  # Submit the Tx
  set firstTxid [lindex $selectedIds 0]
  cliTxSubmit $fromInfo $firstTxid
}

# Invoke the swap method on the smart contract
#
# astor --script swap --from Shelley --value '10 Astor164'
proc scriptSwapTokens {fromInfo amount tokenName {targetAddr ""}} {
  global POLICY_ID
  global SCRIPTS_DIR
  global MIN_TOKEN_LOVELACE
  global MIN_PLUTUS_FEES
  global DOCKER_RUNTIME
  global scriptInfo
  set epoch [getEpochFromTokenName $tokenName]
  set assetClass "$POLICY_ID.$tokenName"
  set fromName [dict get $fromInfo name]
  set fromAddr [dict get $fromInfo addr]
  set scriptAddr [dict get $scriptInfo addr]

  if {$targetAddr == ""} { set targetAddr $fromAddr }
  logInfo "Swap $amount $tokenName from $fromName to $targetAddr"

  # Filter caller utxos by asset class
  set fromUtxos [queryUtxos $fromInfo]
  set tokenUtxos [filterUtxosBySymbol $fromUtxos $assetClass]
  set txidFees [findFeesId $fromUtxos]
  set txidCollateral [findCollateralId $fromUtxos $txidFees]
  logInfo "Fees: $txidFees [dict get $fromUtxos $txidFees value]"
  logInfo "Collateral: $txidCollateral [dict get $fromUtxos $txidCollateral value]"

  # Select the caller's token UTxO
  set lvtokens 0
  set tokenTxinId ""
  foreach txid [dict keys $tokenUtxos] {
    set value [dict get $tokenUtxos $txid value]
    if {$amount == [dict get $value $assetClass]} {
      set lvtokens [dict get $value "lovelace"]
      set tokenTxinId $txid
      break
    }
  }
  if {$tokenTxinId == ""} {
    error "Cannot find caller UTxO"
  }

  # Filter script utxos by datum
  set datumHash [getDatumHash $tokenName]
  set scriptUtxos [queryUtxos $scriptInfo]
  set scriptUtxos [filterUtxosByDatum $scriptUtxos $datumHash]

  # Select the script UTxO
  set scriptTxinId ""
  set lvamount [toLovelace $amount]
  foreach txid [dict keys $scriptUtxos] {
    set value [dict get $scriptUtxos $txid value]
    if {$lvamount <= [dict get $value "lovelace"]} {
      set scriptTxinId $txid
      break
    }
  }
  if {$scriptTxinId == ""} {
    error "Cannot find script UTxO"
  }

  # Calculate the script refund
  set scriptValue [dict get $scriptUtxos $scriptTxinId value]
  set scriptInputLovelace [dict get $scriptValue "lovelace"]
  if {[dict exists $scriptValue $assetClass]} {
    set scriptInputTokens [dict get $scriptValue $assetClass]
  } else {
    set scriptInputTokens 0
  }
  set scriptRefundTokens [expr {$scriptInputTokens + $amount}]
  set scriptRefundLovelace [expr {$scriptInputLovelace - $lvamount}]
  set scriptRefundLovelace [expr max($scriptRefundLovelace, $MIN_TOKEN_LOVELACE)]
  set scriptRefundSpec "$scriptAddr+$scriptRefundLovelace+$scriptRefundTokens $assetClass"

  # Calculate the invalid after slot
  set slotDelta 300
  set bounds [getEpochBoundaries]
  set currentSlot [dict get $bounds currentSlot]
  set currentTime [dict get $bounds currentTime]
  set targetSlot [expr {$currentSlot + $slotDelta}]
  set targetTime [expr {$currentTime + $slotDelta}]

  set timestr [clock format $targetTime -format {%d-%m-%Y %H:%M:%S %Z}]
  logInfo "InvalidAfter: $targetSlot => $timestr"

  # Sanity check external files that must be available
  set scriptFile "/var/cardano/local/$SCRIPTS_DIR/swaptokens.plutus"
  set datumFile "/var/cardano/local/scratch/script-datum$epoch.json"
  set protocolFile "/var/cardano/local/scratch/protocol.json"

  if {$DOCKER_RUNTIME} {
    if {![file exists $protocolFile]} { error "Protocol params file does not exist: $protocolFile"}
    if {![file exists $scriptFile]} { error "Script file does not exist: $scriptFile"}
    if {![file exists $datumFile]} { error "Datum file does not exist: $datumFile"}
  }

  # Build the transaction
  logInfo "Build token swap transaction"
  set args [networkAwareCmd [list "transaction" "build"]]
  lappend args "--alonzo-era"
  lappend args "--tx-in" $txidFees
  lappend args "--tx-in" $tokenTxinId
  lappend args "--tx-in" $scriptTxinId
  lappend args "--tx-in-script-file" "/var/cardano/local/$SCRIPTS_DIR/swaptokens.plutus"
  lappend args "--tx-in-datum-file" "/var/cardano/local/scratch/script-datum$epoch.json"
  lappend args "--tx-in-redeemer-value" 0
  lappend args "--tx-in-collateral" $txidCollateral
  lappend args "--tx-out" $scriptRefundSpec
  lappend args "--tx-out-datum-hash" $datumHash
  lappend args "--tx-out" "$targetAddr+[expr {$lvamount + $lvtokens - $MIN_PLUTUS_FEES}]"
  lappend args "--change-address" $fromAddr
  lappend args "--invalid-hereafter" $targetSlot
  lappend args "--protocol-params-file" [getProtocolConfig]
  lappend args "--out-file" "/var/cardano/local/scratch/tx.raw"
  cardano-cli $args

  # Sign the Tx
  cliTxSign $fromInfo

  # Submit the Tx
  cliTxSubmit $fromInfo $txidFees
}

proc scriptWithdraw {fromInfo epoch} {
  global SCRIPTS_DIR
  global MIN_TOKEN_LOVELACE
  global scriptInfo
  set tokenName "Astor$epoch"
  set fromName [dict get $fromInfo name]
  set fromAddr [dict get $fromInfo addr]

  logInfo "Withdraw epoch $epoch from Script to $fromName"

  # Filter script utxos by datum
  set datumHash [getDatumHash $tokenName]
  set scriptUtxos [queryUtxos $scriptInfo]
  set scriptUtxos [filterUtxosByDatum $scriptUtxos $datumHash]

  if { [dict size $scriptUtxos] < 1 } {
    logWarn "Nothing to withdraw"
    return false
  }

  # Find fees and collateral
  set fromUtxos [queryUtxos $fromInfo]
  set txidFees [findFeesId $fromUtxos]
  set txidCollateral [findCollateralId $fromUtxos $txidFees]
  logInfo "Fees: $txidFees [dict get $fromUtxos $txidFees value]"
  logInfo "Collateral: $txidCollateral [dict get $fromUtxos $txidCollateral value]"

  # Build the transaction
  logInfo "Build withdraw transaction"
  set args [networkAwareCmd [list "transaction" "build"]]
  lappend args "--alonzo-era"
  lappend args "--tx-in" $txidFees
  foreach txid [dict keys $scriptUtxos] {
    set value [dict get $scriptUtxos $txid value]
    set symbols [dict keys $value]
    set isAdaOnly [expr {[llength $symbols] == 1}]
    lappend args "--tx-in" $txid
    lappend args "--tx-in-script-file" "/var/cardano/local/$SCRIPTS_DIR/swaptokens.plutus"
    lappend args "--tx-in-datum-file" "/var/cardano/local/scratch/script-datum$epoch.json"
    lappend args "--tx-in-redeemer-value" 1
    if {$isAdaOnly} {
      set lvamount [dict get $value "lovelace"]
      lappend args "--tx-out" "$fromAddr+$lvamount"
    } else {
      set assetClass [lindex $symbols 1]
      set amount [dict get $value $assetClass]
      lappend args "--tx-out" "$fromAddr+$MIN_TOKEN_LOVELACE+$amount $assetClass"
    }
  }
  lappend args "--tx-in-collateral" $txidCollateral
  lappend args "--change-address" $fromAddr
  lappend args "--protocol-params-file" [getProtocolConfig]
  lappend args "--out-file" "/var/cardano/local/scratch/tx.raw"
  cardano-cli $args

  # Sign the Tx
  cliTxSign $fromInfo

  # Submit the Tx
  cliTxSubmit $fromInfo $txidFees
}
