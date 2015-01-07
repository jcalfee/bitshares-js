{Transaction} = require '../blockchain/transaction'
{RegisterAccount} = require '../blockchain/register_account'
{BlockchainAPI} = require '../blockchain/blockchain_api'
{Withdraw} = require '../blockchain/withdraw'
{Deposit} = require '../blockchain/deposit'
{WithdrawCondition} = require '../blockchain/withdraw_condition'
{WithdrawSignatureType} = require '../blockchain/withdraw_signature_type'
{SignedTransaction} = require '../blockchain/signed_transaction'
{Operation} = require '../blockchain/operation'

{Address} = require '../ecc/address'
{PublicKey} = require '../ecc/key_public'
{Signature} = require '../ecc/signature'
{ExtendedAddress} = require '../ecc/extended_address'

LE = require('../common/exceptions').LocalizedException
config = require '../config'
hash = require '../ecc/hash'
q = require 'q'
types = require '../blockchain/types'
type_id = types.type_id

BTS_BLOCKCHAIN_MAX_MEMO_SIZE = 19

class TransactionBuilder
    
    constructor:(@wallet, @rpc, @transaction_ledger, @aes_root)->
        @blockchain_api = new BlockchainAPI @rpc
        @mail_trx_notices = []
        now = new Date().toISOString().split('.')[0]
        @transaction_record =
            trx: {}
            ledger_entries: []
            created_time: now
            received_time: now
        @signatures = []
        @required_signatures = []
        @outstanding_balances = {}
        @account_balance_records = {}
        @operations = []
        @order_keys = {}
        @slate_id = 0
    
    ### @return record with private journal entries ###
    get_transaction_record:()->
        record = @transaction_record
        record.trx.expiration = @expiration.toISOString().split('.')[0]
        record.trx.slate_id = @slate_id
        record.trx.operations = ops = []
        for op in @operations
            op.toJson(o = {})
            ops.push o
        
        record.trx.signatures = sigs = []
        sigs.push sig.toHex() for sig in @signatures
        
        record
    
    get_binary_transaction:()->
        trx = @transaction_record.trx
        new Transaction(
            expiration = @expiration
            @slate_id
            @operations
        )
    
    ### @return public transaction for broadcast ###
    get_signed_trx:()->
        sigs = @signatures
        if sigs.length is 0
            throw new Error 'call sign_transaction first'
            
        transaction = @get_binary_transaction()
        new SignedTransaction transaction, sigs
    
    deposit_asset:(
        payer, recipient, amount
        memo_message, vote_method
        memo_sender_public #BTS Public Key String
    )->
        throw new Error 'missing payer' unless payer?.name
        throw new Error 'missing recipient' unless recipient?.name
        throw new Error 'missing amount' unless amount?.amount
        
        if recipient.is_retracted #active_key() == public_key_type()
            LE.throw 'blockchain.account_retracted',[recipient.name]
        
        unless amount and amount.amount > 0
            LE.throw 'Invalid amount', [amount]
        
        if memo_message?.length > BTS_BLOCKCHAIN_MAX_MEMO_SIZE
            LE.throw 'chain.memo_too_long'
        
        recipientActivePublic = @wallet.getActiveKey recipient.name
        payerActivePublic = @wallet.getActiveKey payer.name
        
        unless memo_sender_public
            memo_sender_public = @wallet.lookup_active_key payer.name
        memoSenderPrivate = @wallet.getPrivateKey memo_sender_public
        
        oneTimePublic = null
        if recipient.meta_data?.type? is "public_account"
            @deposit(
                recipientActivePublic, amount, 
                0 #@wallet.select_slate trx, amount.asset_id, vote_method
            )
        else
            oneTimePrivate = @wallet.getNewPrivateKey payer.name
            oneTimePublic = oneTimePrivate.toPublicKey()
            @deposit_to_account( # trx
                recipientActivePublic, amount
                memoSenderPrivate, memo_message
                @slate_id # @wallet.select_slate_id trx, amount.asset_id, vote_method
                oneTimePrivate, 'from_memo'
            )
        
        fee = @wallet.get_transaction_fee()
        @transaction_record.fee = fee
        @_deduct_balance payer.owner_key, fee, payer
        @_deduct_balance payer.owner_key, amount, payer
        
        @transaction_record.ledger_entries.push ledger_entry =
            from_account: payer.owner_key
            to_account: recipient.owner_key
            amount: amount
            memo: memo_message
        if memo_sender_public isnt payerActivePublic
            ledger_entry.memo_from_account = memo_sender_public
        
        @mail_trx_notices.push (=>
            sig = Signature.sign memo_message, memoSenderPrivate
            [
                extended_memo: memo_message
                one_time_private: oneTimePrivate
                memo_signature: sig
            ,
                recipientActivePublic
            ]
        )()
    
    order_key_for_account:(account_address, account_name)->
        order_key = @order_keys[account_address]
        unless order_key
            order_key = @wallet.getNewPublicKey account_name
            order_keys[account_address] = order_key
        order_key
    
    deposit:(recipientPublic, amount, slate_id)->
        deposit = new Deposit amount.amount, new WithdrawCondition(
            amount.asset_id, slate_id
            type_id(types.withdraw, "withdraw_signature_type"), 
            new WithdrawSignatureType new Buffer recipientPublic.toBtsAddy()
        )
        @operations.push new Operation deposit.type_id, deposit
    
    deposit_to_account:(
        recipientPublic, amount
        memoSenderPrivate, memo_message, slate_id
        oneTimePrivate, memo_type
    )->
        throw new Error 'not implemented' if memo_message
        
        memoSenderPublic = memoSenderPrivate.toPublicKey()
        ###
        receiver_address = WithdrawTypes.encrypt_memo_data(
            oneTimePrivate, recipientPublic, memoSenderPrivate,
            memo_message, memoSenderPublic, memo_type
        )###
        encrypted_memo_data = null
        oneTimePublic = oneTimePrivate.toPublicKey()
        wws = new WithdrawSignatureType(
            recipientPublic.toBlockchainAddress()
            oneTimePublic, encrypted_memo_data
        )
        wc = new WithdrawCondition(
            amount.asset_id, slate_id
            type_id(types.withdraw, "withdraw_signature_type"), 
            wws
        )
        deposit = new Deposit amount.amount, wc
        @operations.push new Operation deposit.type_id, deposit
    
    ###
    wallet_transfer:(
        amount, asset
        from_name, to_public
        memo_message, vote_method
    )->
        defer = q.defer()
        if memo_message?.length > BTS_BLOCKCHAIN_MAX_MEMO_SIZE
            LE.throw 'chain.memo_too_long' 
        
        otk_private = @wallet.generate_new_account_child_key(
            @aes_root
            from_name
        )
        owner = ExtendedAddress.derivePublic_outbound otk_private, to_public
        one_time_public = otk_private.toPublicKey()
        sender_private = @wallet.getActivePrivate @aes_root, from_name
        aes = sender_private.sharedAes one_time_public
        encrypted_memo = if memo_message then aes.encrypt memo_message else ""
        @_transfer(
            amount
            asset
            from_name
            owner.toBtsAddy()
            memo_message
            encrypted_memo
            vote_method
            one_time_public
            to_public
        ).then(
            (result)->defer.resolve result
            (error)->defer.reject error
        ).done()
        defer.promise
    ###
    account_register:(
        account_name
        pay_from_account
        public_data=null
        delegate_pay_rate = -1
        account_type = "titan_account"
    )->
        defer = q.defer()
        LE.throw "wallet.must_be_opened" unless @wallet
        if delegate_pay_rate isnt -1
            throw new Error 'Not implemented'
        
        owner_key = @wallet.getOwnerKey account_name
        unless owner_key
            throw new Error "Create account before registering"
        
        active_key = @wallet.getActiveKey account_name
        unless active_key
            throw new Error "Unknown pay_from account #{pay_from_account}"
        
        meta_data = null
        if account_type
            type_id = RegisterAccount.type[account_type]
            if type_id is undefined
                throw new Error "Unknown account type: #{account_type}"
            meta_data=
                type: type_id
                data: new Buffer("")
        if delegate_pay_rate > 100
            LE.throw 'wallet.delegate_pay_rate_invalid', [delegate_pay_rate]
        
        public_data = "" unless public_data
        register = new RegisterAccount(
            new Buffer account_name
            new Buffer public_data
            owner_key
            active_key
            delegate_pay_rate
            meta_data
        )
        @operations.push new Operation register.type_id, register
        
        account_segments = account_name.split '.'
        if account_segments.length > 1
            throw new Error 'untested'
            ###
            parents = account_segments.slice 1
            for parent in parents
                account = @wallet.lookup_account parent
                unless account
                    LE.throw 'wallet.need_parent_for_registration', [parent]
                
                #continue if account.is_retracted #active_key == public_key
                @wallet.has_private_key account
                @required_signatures.push @wallet.lookup_active_key parent
            ###
        
        #fees = @wallet.get_transaction_fee()
        
        #if delegate_pay_rate isnt -1
            #calc and add delegate fee
        @withdraw_to_transaction( fees, pay_from_account ).then ()->  
            defer.resolve()
            return
        .done()
        defer.promise
        
    withdraw_to_transaction:(
        amount_to_withdraw
        from_account_name
    )->
        defer = q.defer()
        amount_remaining = amount_to_withdraw.amount
        withdraw_asset_id = amount_to_withdraw.asset_id
        owner_private=(balance_record)=>
            id = balance_record[0]
            balance = balance_record[1]
            if balance.snapshot_info?.original_address
                activePrivate = @wallet.getActivePrivate from_account_name
                throw new Error "account '#{from_account_name}' is missing active private key" unless   activePrivate
                return activePrivate
            
            throw new Error "... correct one_time_public \t"+JSON.stringify balance_record
            #one_time_public = balance_record.memo.one_time_public
            #sender_private = @wallet.getActivePrivate @aes_root, from_account_name
            #ExtendedAddress.private_key_child sender_private, one_time_public
        
        @get_account_balance_records(from_account_name).then(
            (balance_records)=>
                #console.log balance_records,'b'
                withdraws = []
                
                #console.log 'balance records',JSON.stringify balance_records,null,4
                for record in balance_records
                    balance_amount = @get_spendable_balance(record[1])
                    continue unless balance_amount
                    balance_id = record[0]
                    balance_asset_id = record[1].condition.asset_id
                    balance_owner = record[1].condition.data.owner
                    
                    continue if balance_amount <= 0
                    continue if balance_asset_id isnt withdraw_asset_id
                    if amount_remaining > balance_amount
                        withdraws = new Withdraw(
                            Address.fromString(balance_id).toBuffer()
                            balance_amount
                        )
                        @operations.push new Operation withdraw.type_id, withdraw
                        @required_signatures.push owner_private record
                        amount_remaining -= balance_amount
                    else
                        withdraw = new Withdraw(
                            Address.fromString(balance_id).toBuffer()
                            amount_remaining
                        )
                        @operations.push new Operation withdraw.type_id, withdraw
                        amount_remaining = 0
                        @required_signatures.push owner_private record
                        break
                    
                if amount_remaining isnt 0
                    available = amount_to_withdraw.amount - amount_remaining
                    error = new LE 'wallet.insufficient_funds', amount_to_withdraw.amount, available
                    defer.reject error
                    return
                defer.resolve()
            (error)->
                defer.reject error
        ).done()
        defer.promise
        
    get_spendable_balance:(balance_record)->
        switch balance_record.condition.type
            when "withdraw_signature_type" or "withdraw_escrow_type" or "withdraw_multisig_type"
                return balance_record.balance
            when "withdraw_vesting_type"
                vc = balance_record.condition
                try
                    at_time = (new Date().getTime()) / 1000
                    vc_start = (new Date(vc.start_time).getTime()) / 1000
                    max_claimable = 0
                    if at_time >= vc_start + vc.duration
                        max_claimable = vc.original_balance
                    else
                        if at_time > vc_start
                            elapsed_sec = (at_time = vc_start)
                            if elapsed_sec <= 0 or elapsed_time >= vc.duration
                                throw new Error "elapsed '#{elapsed_sec}' is out of bounds"
                            max_claimable = (vc.original_balance * elapsed_sec) / vc.duration
                            if max_claimable < 0 or max_claimable >= vc.original_balance
                                throw new Error "max_claimable '#{max_claimable}; is out of bounds"
                    
                    claimed_so_far = vc.original_balance - balance_record.balance
                    if claimed_so_far < 0 or claimed_so_far > vc.original_balance
                        throw new Error "claimed_so_far '#{claimed_so_far}' is out of bounds"
                    
                    spendable_balance = max_claimable - claimed_so_far;
                    if spendable_balance < 0 or spendable_balance > vc.original_balance
                        throw new Error "spendable_balance '#{spendable_balance}' is out of bounds"
                    
                    return spendable_balance
                catch error
                    console.log "WARN: get_spendable_balance() bug in calcuating vesting balance",error,error.stack
            else
                console.log "WARN: get_spendable_balance() called on unsupported withdraw type: " + balance_record.condition.type
        return
    
    get_account_balance_records:(account_name)->
        defer = q.defer()
        if @account_balance_records[account_name]
            defer.resolve @account_balance_records[account_name]
            return defer.promise
            
        #throw new Error "Account not found #{account_name}"
        owner_pts = (=>
            # genesis credit
            owner_public = @wallet.getOwnerKey account_name
            owner_public.toPtsAddy()
        )()
        try
            @blockchain_api.list_address_balances(owner_pts).then(
                (result)=>
                    balance_records = []
                    balance_records.push balance for balance in result if result
                    wcs = @wallet.getWithdrawConditions account_name
                    balance_ids = []
                    #balance_ids.push wc.getBalanceId() for wc in wcs
                    if balance_ids.length is 0
                        defer.resolve balance_records
                        return
                    @blockchain_lookup_balances(balance_ids).then(
                        (result)->
                            balance_records.push balance for balance in result if result
                            @account_balance_records[account_name]=balance_records
                            defer.resolve balance_records
                    ).done()
            ).done()
        catch error
            defer.reject error
        defer.promise
    
    blockchain_lookup_balances:(balances)->
        defer = q.defer()
        batch_ids = []
        batch_ids.push [id, 1] for id in balances
        @rpc.request("batch", ["blockchain_list_balances", batch_ids]).then(
            (batch_balances)->
                ###
                blockchain_list_address_balances= = [[
                  "XTS4pca7BPiQqnQLXUZp8ojTxfXo2g4EzBLP"
                  {
                    condition:
                      asset_id: 0
                      slate_id: 0
                      type: "withdraw_signature_type"
                      data:
                        owner: "XTSD5rYtofD6D4UHJH6mo953P5wpBfMhdMEi"
                        memo: null
                
                    balance: 99009900990
                    restricted_owner: null
                    snapshot_info:
                      original_address: "Po3mqkgMzBL4F1VXJArwQxeWf3fWEpxUf3"
                      original_balance: 99009900990
                
                    deposit_date: "1970-01-01T00:00:00"
                    last_update: "2014-10-07T10:55:00"
                  }
                ]]
                ###
                # or [] (no genesis claim)
                balance_records = []
                for balances in batch_balances
                    for balance in balances
                        #console.log 'balance',balance
                        unless balance[1].condition.type is "withdraw_signature_type"
                            console.log "WARN: unsupported balance record #{balance[1].condition.type}"
                            continue
                        balance_records.push balance
                    defer.resolve balance_records
            (error)->
                defer.reject error
        ).done()
        ###
        @blockchain_api.request("get_pending_transactions").then(
            (result)->
                # TODO need example output to complete...
                console.log '... result',JSON.stringify result
                defer.resolve result
            (error)->
                defer.reject error
        ).done()
        ###
        defer.promise
        
    finalize:()->
        defer = q.defer()
        throw new Error 'empty transaction' if @operations.length is 0
        if (Object.keys @outstanding_balances).length is 0
            throw new Error 'nothing to finalize'
        
        #slate = @wallet.select_delegate_vote 'vote_recommended'
        #if slate.supported_delegates.length > 0 and not @blockchain.get_delegate_slate slate_id
        #    trx.define_delegate_slate(slate);
        #else
        #    slate_id = 0
        
        p = []
        for address in Object.keys @outstanding_balances
            #rec = asset_id: amount.asset_id, account: account, amount: amount
            rec = @outstanding_balances[address]
            continue if rec.amount is 0
            console.log '... rec.amount',JSON.stringify rec.amount
            balance = {amount:rec.amount, asset_id: rec.asset_id}
            account_name = rec.account.name
            #address->ownerkey lookup 
            
            if rec.amount > 0
                depositAddress = @order_key_for_account address, account_name
                @deposit depositAddress, balance
            else
                balance.amount = -rec.amount
                p.push @withdraw_to_transaction balance, account_name
        
        @outstanding_balances.length = 0
        @expiration = @wallet.get_trx_expiration()
        q.all p
    
    sign_transaction:() ->
        unless @transaction_record.trx
            throw new Error 'call finalize first'
        
        if @signatures.length isnt 0
            throw new Error 'already signed'
        
        chain_id_buffer = new Buffer config.chain_id, 'hex'
        trx_buffer = @get_binary_transaction().toBuffer()
        trx_sign = Buffer.concat([trx_buffer, chain_id_buffer])
        #console.log 'digest',hash.sha256(trx_sign).toString('hex')
        for private_key in @required_signatures
            #console.log 'sign by', private_key.toPublicKey().toBtsPublic()
            @signatures.push(
                Signature.signBuffer trx_sign, private_key
            )
    
    ###
    _pay_fee:->
        available_balances = @_all_negative_balances()
        required_fee = { amount:0, asset_id: -1 }
        # see if one asset can pay fee
        for asset_id in Object.keys available_balances
            amount = available_balances[asset_id]
            _required_fee = @wallet.get_transaction_fee(asset_id).then (amt)=>
                if @wallet.asset_can_pay_fee(asset_id) and amount >= _required_fee.amount
                    required_fee = _required_fee
                    @transaction_record.fee = required_fee
                    defer.resolve()
                    return
        
        if required_fee.asset_id isnt -1
            @transaction_record.fee = required_fee
            for address in @outstanding_balances
                #rec = asset_id: amount.asset_id, account: account, amount: amount
                rec = @outstanding_balances[address]
                continue if rec.asset_id isnt required_fee.asset_id
                if required_fee.amount > rec.amount
                    required_fee.amount -= rec.amount
                    delete @outstanding_balances[address]
                    # not enough, look for more
                    continue
                
                # fee is paied in full
                rec.amount -= required_fee.amount
                return
        else
            if @_withdraw_fee_other_asset()
                return
        
        LE.throw 'wallet.unable_to_pay_fee'
            
    _all_negative_balances:->
        balances = {}
        for address in Object.keys @outstanding_balances
            #rec = asset_id: amount.asset_id, account: account, amount: amount
            rec = @outstanding_balances[address]
            continue unless rec.amount < 0
            balance = balances[rec.asset_id]
            balances[rec.asset_id] = 0 unless balance
            balances[rec.asset_id] += -1 * rec.amount
        return balances
            
    
    _withdraw_fee_other_asset:->
        throw new Error 'not implemented'
        account_balances = @wallet.get_account_balances "", false
        for address in Object.keys @outstanding_balances
            #rec = asset_id: amount.asset_id, account: account, amount: amount
            rec = @outstanding_balances[address]
            balances = account_balances[key.account.name]
            continue unless balances
            for balance in balances
                fee = @wallet.get_transaction_fee balance.asset_id
                continue if fee.asset_id isnt balance.asset_id or fee.amount > balance.amount
                @_deduct_balance address, fee, key.account
                @transaction_record.fee = fee
                return true
        return false
    ###
    
    # manually tweak an account's balance in this transaction
    _deduct_balance:(address, amount, account)->
        unless amount.amount >= 0
            throw new Error "amount must be positive"
        record = @outstanding_balances[address]
        unless record
            @outstanding_balances[address] = record =
                address:address
                asset_id: amount.asset_id
                account: account
                amount: 0
        record.amount -= amount.amount
        
    # manually tweak an account's balance in this transaction
    _credit_balance:(address, amount, account)->
        unless amount.amount >= 0
            throw new Error "amount must be positive"
        record = @outstanding_balances[address]
        unless record
            @outstanding_balances[address] = record =
                address:address
                asset_id: amount.asset_id
                account: account
                amount: 0
        record.amount += amount.amount

exports.TransactionBuilder = TransactionBuilder