/*
 * Copyright 2020 ConsenSys Software Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may 
 * not use this file except in compliance with the License. You may obtain 
 * a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software dis-
 * tributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
 * License for the specific language governing permissions and limitations 
 * under the License.
 */

include "../utils/NativeTypes.dfy"
include "../utils/Eth2Types.dfy"
include "ForkChoiceTypes.dfy"
include "../utils/Helpers.dfy"
include "../ssz/Constants.dfy"
include "BeaconChainTypes.dfy"
include "Validators.dfy"
include "Helpers.dfy"
include "StateTransition.s.dfy"

/**
 * State transition function for the Beacon Chain.
 */
module StateTransition {
    
    //  Import some constants, types and beacon chain helpers.
    import opened NativeTypes
    import opened Eth2Types
    import opened ForkChoiceTypes
    import opened Constants
    import opened BeaconChainTypes
    import opened Validators
    import opened Helpers
    import opened BeaconHelpers
    import opened StateTransitionSpec

// # Attestations
//     previous_epoch_attestations: List[PendingAttestation, MAX_ATTESTATIONS * SLOTS_PER_EPOCH]
//     current_epoch_attestations: List[PendingAttestation, MAX_ATTESTATIONS * SLOTS_PER_EPOCH]
//     # Finality
//     justification_bits: Bitvector[JUSTIFICATION_BITS_LENGTH]  # Bit set for every recent justified epoch
//     previous_justified_checkpoint: Checkpoint  # Previous epoch snapshot
//     current_justified_checkpoint: Checkpoint
//     finalized_checkpoint: Checkpoint

    /**
     *  Whether a block is valid in a given state.
     *
     *  @param  s   A beacon state.
     *  @param  b   A block.
     *
     *  @returns    true iff `b` can be successfully added to the state `s`.
     */
    predicate isValid(s : BeaconState, b : BeaconBlock) 
    {
        //  block slot should be in the future.
        s.slot < b.slot 
        //  Fast forward s to b.slot and check `b` can be attached to the
        //  resulting state's latest_block_header.
        && b.parent_root == 
            hash_tree_root(
                forwardStateToSlot(resolveStateRoot(s), 
                b.slot
            ).latest_block_header) 
        //  Check that number of deposits in b.body can be processed
        && s.eth1_deposit_index as int + |b.body.deposits| < 0x10000000000000000  
        //  Check that the block provides the correct hash for the state.
        &&  b.state_root == hash_tree_root(
                updateDeposits(
                    addBlockToState(
                        forwardStateToSlot(resolveStateRoot(s), b.slot), 
                        b
                    ),
                    b
                )
            )
    }

    /**
     *  Compute the state obtained after adding a block.
     *  
     *  @param      s   A beacon state.
     *  @param      b   A block.
     *  @returns        The state obtained after adding `b` to the current state.
     *                  
     */
     method stateTransition(s: BeaconState, b: BeaconBlock) returns (s' : BeaconState)
        //  make sure the last state was one right after addition of new block
        requires isValid(s, b)

        requires s.eth1_deposit_index as int + |b.body.deposits| < 0x10000000000000000  

        /** The next state latest_block_header is same as b except for state_root that is 0. */
        // ensures s'.latest_block_header == BeaconBlockHeader(b.slot, b.parent_root, DEFAULT_BYTES32)
        /** s' slot is now adjusted to the slot of b. */
        // ensures s'.slot == b.slot
        /** s' parent_root is the hash of the state obtained by resolving/forwarding s to
            the slot of b.  */
        // ensures s'.latest_block_header.parent_root  == 
        //     hash_tree_root(
        //         forwardStateToSlot(resolveStateRoot(s), b.slot)
        //         .latest_block_header
        //     )
        // ensures s'.eth1_deposit_index as int == s.eth1_deposit_index as int + |b.body.deposits|
    {
        //  finalise slots before b.slot.
        var s1 := processSlots(s, b.slot);

        //  Process block and compute the new state.
        // s' := processBlock(s1, b);  

        // Verify state root (from eth2.0 specs)
        // A proof that this function is correct establishes that this assert statement 
        // is never violated (i.e. when isValid() is true.)
        // In the Eth2.0 specs this check is conditional and enabled by default.
        //  if validate_result:
        // assert (b.state_root == hash_tree_root(s'));
    }  

    /**
     *  Advance current state to a given slot.
     *
     *  This mainly consists in advancing the slot number to
     *  a target future `slot` number and updating/recording the history of intermediate
     *  states (and block headers). 
     *  Under normal circumstances, where a block is received at each slot,
     *  this involves only one iteration of the loop.
     *  Otherwise, the first iteration of the loop `finalises` the block header
     *  of the previous slot before recortding it, 
     *  and subsequent rounds advance the slot number and record the history of states
     *  and blocks for each slot.
     *
     *  @param  s       A state
     *  @param  slot    The slot to advance to. This is usually the slot of newly
     *                  proposed block.
     *  @returns        The state obtained after advancing the histories to slot.
     *      
     *  @note           The specs have the the first processSlot integrated in the while loop. 
     *                  However, because s.slot < slot, the while bdoy must be executed at least 
     *                  one time. To simplify the proof, we have taken this first iteration 
     *                  outside of the loop. It does not change the semantics but enables us to 
     *                  use the state obtained after the first iteration the loop and prove it 
     *                  is the same as resolveStateRoot(s).
     *
     */
    method processSlots(s: BeaconState, slot: Slot) returns (s' : BeaconState)
        requires s.slot < slot  //  update in 0.12.0 (was <= before)

        // ensures s' == forwardStateToSlot( resolveStateRoot(s), slot)
        ensures s' == forwardStateToSlot( nextSlot2(s), slot)
        // ensures s' == forwardStateToSlot(updateJustification(resolveStateRoot(s)), slot)
        // ensures equalExceptCheckpoints(s', forwardStateToSlot( resolveStateRoot(s), slot))
        // ensures s.latest_block_header.parent_root == s'.latest_block_header.parent_root  
        // ensures s'.eth1_deposit_index == s.eth1_deposit_index
        ensures s'.slot == slot
        //  Termination ranking function
        decreases slot - s.slot
    {
        //  Start from the current state and update it with processSlot.
        //  First iteration of the loop in process_slots (Eth2)
        s' := processSlot(s);
        // assert(s' == nextSlot(s));
        // assert(s'.(slot := s.slot + 1) == resolveStateRoot(s));  
        // var k := s';
        //  Joanne's fix: need this for the first processSlot too as it can be at the
        //  boundary of an epoch.
        //  Process epoch on the start slot of the next epoch
        // assert(s'.slot == s.slot);
        // assert(get_current_epoch(s) == get_current_epoch(s'));
        if (s'.slot + 1) % SLOTS_PER_EPOCH  == 0 {
            // var k1 := s';
            s' := process_epoch(s');
            // assert(s' == updateJustification(k1));
            // assert(s'.previous_justified_checkpoint == k1.current_justified_checkpoint);

            // assert(s'.(slot := s.slot + 1) == updateJustification(resolveStateRoot(s));
        } 
        else {
            // assert(s' == k);
            // assert(s'.(slot := s.slot + 1) == resolveStateRoot(s));  
        }
        /*
            s' == if (s'.slot + 1) % SLOTS_PER_EPOCH  == 0 then 
                process_epoch(processSlot(s))
            else 
                processSlot(s) == resolveStateRoot(s)

            // process_epoch() == updateJustification()
        */
        // assert(s'.slot + 1 == nextSlot2(s).slot);
        // assert(s'.latest_block_header == nextSlot2(s).latest_block_header);
        // assert(s'.block_roots == nextSlot2(s).block_roots);
        // assert(s'.state_roots == nextSlot2(s).state_roots);
        // assert(s'.genesis_time == nextSlot2(s).genesis_time);
        // assert(s'.current_justified_checkpoint == nextSlot2(s).current_justified_checkpoint);
        // assert(s'.previous_justified_checkpoint == nextSlot2(s).previous_justified_checkpoint);
        // assert(s'.(slot := s.slot + 1) == nextSlot(s));
        // assert(s'.(slot := s.slot + 1) == nextSlot(s));
        //  Check properties of fields of new state
        // assert(s' == nextSlot2(s));
        // assert(s'.(slot := s.slot + 1) == resolveStateRoot(s));  

        // assert(s' == updateJustification(resolveStateRoot(s)));  
        s':= s'.(slot := s'.slot + 1) ;
        // assert(s' == updateJustification(resolveStateRoot(s)));  
        assert(s' == nextSlot2(s));
        //  The following asserts are not needed for the proof but provided for readability. 
        // assert(equalExceptCheckpoints(s', resolveStateRoot(s)));
        // assert(s'.slot == resolveStateRoot(s).slot);  
        // assert(s'.slot == nextSlot(s).slot);  
        // assert(s' == resolveStateRoot(s));
        // assert(s' == updateJustification(resolveStateRoot(s)));
        // assert(s' == resolveStateRoot(updateJustification(s)));
        // assert(s' == forwardStateToSlot( resolveStateRoot(s), s'.slot));

        // assert(s'.genesis_time == resolveStateRoot(s).genesis_time);  
        // assert(s'.latest_block_header == resolveStateRoot(s).latest_block_header);  
        // assert(s'.latest_block_header == resolveStateRoot(s).latest_block_header);  
        // assert(s'.latest_block_header == resolveStateRoot(s).latest_block_header);  
        //  s'.block header state_root should now be resolved
        assert(s'.latest_block_header.state_root != DEFAULT_BYTES32);

        //  Now fast forward to slot
        //  Next iterations of process_slot (Eth2)
        while (s'.slot < slot)  
            invariant s'.slot <= slot
            invariant s'.latest_block_header.state_root != DEFAULT_BYTES32
            invariant s' == forwardStateToSlot( nextSlot2(s), s'.slot)

            // invariant s' == forwardStateToSlot(resolveStateRoot(s), s'.slot) // Inv1
            // invariant equalExceptCheckpoints(s', forwardStateToSlot(resolveStateRoot(s), s'.slot))
            invariant s'.eth1_deposit_index == s.eth1_deposit_index
            decreases slot - s'.slot 
        {
            // var k := s';
            s':= processSlot(s');
            //  Process epoch on the start slot of the next epoch
            if (s'.slot + 1) % SLOTS_PER_EPOCH  == 0 {
                s' := process_epoch(s');
            }
            
            //  s'.slot is now processed: history updated and block header resolved
            //  The state's slot is processed and we can advance to the next slot.
            s':= s'.(slot := s'.slot + 1) ;
            // assert(s' == nextSlot2(k));
        }
    }

    predicate equalExceptCheckpoints(s : BeaconState, s' : BeaconState) 
    {
        s.slot == s'.slot 
        && s.genesis_time == s'.genesis_time
        && s.latest_block_header == s'.latest_block_header
        && s.block_roots == s'.block_roots
        && s.state_roots == s'.state_roots
        && s.eth1_deposit_index == s'.eth1_deposit_index
        && s.validators == s'.validators
    }

    /** 
     *  Cache data for a slot.
     *
     *  This function also finalises the block header of the last block
     *  so that it records the hash of the state `s`. 
     *
     *  @param  s   A state.
     *  @returns    A new state where `s` has been added/cached to the history and
     *              the block header tracks the hash of the most recent received
     *              block.
     *
     *  @note       This function method could be a method (as per the Eth2 specs).
     *              However, this requires to expose the properties of the computation
     *              as methods are not inlined. 
     *  @note       Matches eth2.0 specs, need to uncomment update of state/block_roots.
     *
     *  @todo       Make this a method to have a def closer to Eth2 implementation.  
     */
    method processSlot(s: BeaconState) returns (s' : BeaconState)
        requires s.slot as nat + 1 < 0x10000000000000000 as nat

        ensures  s.latest_block_header.state_root == DEFAULT_BYTES32 ==>
            s' == resolveStateRoot(s).(slot := s.slot)
        ensures  s.latest_block_header.state_root != DEFAULT_BYTES32 ==>
            s' == advanceSlot(s).(slot := s.slot)
        ensures s.latest_block_header.parent_root == s'.latest_block_header.parent_root
        // ensures s'.eth1_deposit_index == s'.eth1_deposit_index
        // ensures s'.previous_justified_checkpoint == s.previous_justified_checkpoint
        // ensures s'.current_justified_checkpoint == s.current_justified_checkpoint
        // ensures s' == resolveStateRoot(s) || s' == advanceSlot(s)
    {
        s' := s;

        //  Cache state root. Record the hash of the previous state in the history.
        var previous_state_root := hash_tree_root(s); 

        s' := s'.(state_roots := s'.state_roots[(s'.slot % SLOTS_PER_HISTORICAL_ROOT) as int := previous_state_root]);

        //  Cache latest block header state root
        if (s'.latest_block_header.state_root == DEFAULT_BYTES32) {
            s' := s'.(latest_block_header := s'.latest_block_header.(state_root := previous_state_root));
        }

        //  Cache block root
        var previous_block_root := hash_tree_root(s'.latest_block_header);

        //  Compute the final value of the new state.
        s' := s'.(block_roots := s'.block_roots[(s.slot % SLOTS_PER_HISTORICAL_ROOT) as int := previous_block_root]);
    }

    /**
     *  Verify that a block is valid.
     *  
     *  @param      s   A beacon state.   
     *  @param      b   A block header.
     *  @returns        The state obtained after processing `b`.
     *
     *  @note   Matches eth2.0 specs, need to implement randao, eth1, operations. 
     */
     method processBlock(s: BeaconState, b: BeaconBlock) returns (s' : BeaconState) 
        requires b.slot == s.slot
        requires b.parent_root == hash_tree_root(s.latest_block_header)
        requires s.eth1_deposit_index as int + |b.body.deposits| < 0x10000000000000000  

        ensures s' == updateDeposits(addBlockToState(s, b), b)
    {
        //  Start by creating a block header from the ther actual block.
        s' := processBlockHeader(s, b); 
        
        //  process_randao(s, b.body)
        //  process_eth1_data(s, b.body)
        s' := process_operations(s', b.body);
    }

    /**
     *  Check whether a block is valid and prepare and initialise new state
     *  with a corresponding block header. 
     *
     *  @param  s   A beacon state.
     *  @param  b   A block.
     *  @returns    The state obtained processing the block.
     *
     *  @note   Matches eth2.0 specs except proposer slashing verification.
     */
    method processBlockHeader(s: BeaconState, b: BeaconBlock) returns (s' : BeaconState) 
        //  Verify that the slots match
        requires b.slot == s.slot  
        //  Verify that the parent matches
        requires b.parent_root == hash_tree_root(s.latest_block_header) 

        requires s.eth1_deposit_index as int + |b.body.deposits| < 0x10000000000000000 

        ensures s' == addBlockToState(s, b)
    {
        s':= s.(
            latest_block_header := BeaconBlockHeader(
                b.slot,
                b.parent_root,
                DEFAULT_BYTES32
            )
        );
    }
    
    /**
     *  At epoch boundaries, update justifications, rewards, penalities,
     *  resgistry, slashing, and final updates.
     *
     *  @param  s   A beacon state.
     *  @returns    
     *  @todo       To be specified and implemented. currently returns s.
     */
    method process_epoch(s: BeaconState) returns (s' : BeaconState) 
        //  Make sure s.slot does not overflow
        requires s.slot as nat + 1 < 0x10000000000000000 as nat
        //  And we should only execute this method when:
        requires (s.slot + 1) % SLOTS_PER_EPOCH == 0
        // requires s' == forwardStateToSlot(resolveStateRoot(s), s'.slot)

        // ensures s'.slot == s.slot 
        // ensures s'.latest_block_header == s.latest_block_header
        // ensures s'.block_roots == s.block_roots
        // ensures s'.state_roots == s.state_roots
        // ensures s'.validators == s.validators
        // ensures s' == forwardStateToSlot(s, s.slot)
        // ensures s' == updateJustification(s)
        // ensures equalExceptCheckpoints(s', s) 
        // ensures s.latest_block_header.parent_root == s'.latest_block_header.parent_root
        ensures s'== updateJustification(s)

        // ensures s' == s

    {
        s' := process_justification_and_finalization(s);
        // process_rewards_and_penalties(state)
        // process_registry_updates(state)
        // process_slashings(state)
        // process_final_updates(state) 
        // assume(s' == forwardStateToSlot(s, s.slot));
        // assume(s' == resolveStateRoot(s));
        return s';
    }

    /**
     *  Update justification and finalisation status.
     *
     *  @link{https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#justification-and-finalization}
     */
    method process_justification_and_finalization(s : BeaconState) returns (s' : BeaconState) 
        //  Make sure s.slot does not overflow
        requires s.slot as nat + 1 < 0x10000000000000000 as nat
        //  And we should only execute this method when:
        requires (s.slot + 1) % SLOTS_PER_EPOCH == 0
        // ensures s'.slot == s.slot 
        // ensures s'.latest_block_header == s.latest_block_header
        // ensures s'.slot == s.slot 
        // ensures s'.latest_block_header == s.latest_block_header
        // ensures s'.block_roots == s.block_roots
        // ensures s'.state_roots == s.state_roots
        // ensures s'.validators == s.validators
        // ensures s' == s
        //  FIXME: add functional spec of what justifications/finalisations are supposed
        //  to do
        // ensures equalExceptCheckpoints(s', s) 
        ensures s' == updateJustification(s)

    {
        //  epoch in state s is given by s.slot

        if get_current_epoch(s) <= GENESIS_EPOCH + 1 {
            //  Initial FFG checkpoint values have a `0x00` stub for `root`.
            //  Skip FFG updates in the first two epochs to avoid corner cases 
            //  that might result in modifying this stub.
            return s;   
        } else {
            //  Process jutstifications and finalisations
            var previous_epoch := get_previous_epoch(s);
            var current_epoch := get_current_epoch(s);
            // old_previous_justified_checkpoint = state.previous_justified_checkpoint
            // old_current_justified_checkpoint = state.current_justified_checkpoint
            s' := s.(previous_justified_checkpoint := s.current_justified_checkpoint);
            return s';
        }

   
    //  Process justifications
    // state.previous_justified_checkpoint = state.current_justified_checkpoint
    // state.justification_bits[1:] = state.justification_bits[:JUSTIFICATION_BITS_LENGTH - 1]
    // state.justification_bits[0] = 0b0
    // matching_target_attestations = get_matching_target_attestations(state, previous_epoch)  # Previous epoch
    // if get_attesting_balance(state, matching_target_attestations) * 3 >= get_total_active_balance(state) * 2:
    //     state.current_justified_checkpoint = Checkpoint(epoch=previous_epoch,
    //                                                     root=get_block_root(state, previous_epoch))
    //     state.justification_bits[1] = 0b1
    // matching_target_attestations = get_matching_target_attestations(state, current_epoch)  # Current epoch
    // if get_attesting_balance(state, matching_target_attestations) * 3 >= get_total_active_balance(state) * 2:
    //     state.current_justified_checkpoint = Checkpoint(epoch=current_epoch,
    //                                                     root=get_block_root(state, current_epoch))
    //     state.justification_bits[0] = 0b1

    //  Process finalizations
    // bits = state.justification_bits
    //  The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th as source
    // if all(bits[1:4]) and old_previous_justified_checkpoint.epoch + 3 == current_epoch:
    //     state.finalized_checkpoint = old_previous_justified_checkpoint
    //  The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as source
    // if all(bits[1:3]) and old_previous_justified_checkpoint.epoch + 2 == current_epoch:
    //     state.finalized_checkpoint = old_previous_justified_checkpoint
    //  The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as source
    // if all(bits[0:3]) and old_current_justified_checkpoint.epoch + 2 == current_epoch:
    //     state.finalized_checkpoint = old_current_justified_checkpoint
    //  The 1st/2nd most recent epochs are justified, the 1st using the 2nd as source
    // if all(bits[0:2]) and old_current_justified_checkpoint.epoch + 1 == current_epoch:
    //     state.finalized_checkpoint = old_current_justified_checkpoint


        return s;
    }

    /**
     *  Process the operations defined by a block body.
     *  
     *  @param  s   A state.
     *  @param  bb  A block body.
     *  @returns    The state obtained after applying the operations of `bb` to `s`.
     */
    method process_operations(s: BeaconState, bb: BeaconBlockBody)  returns (s' : BeaconState)  
        requires s.eth1_deposit_index as int + |bb.deposits| < 0x10000000000000000 
        ensures s' == s.(eth1_deposit_index := (s. eth1_deposit_index as int + |bb.deposits|) as uint64 )
    {
        //  process deposits in the beacon block body.
        s' := s;

        var i := 0; 
        while i < |bb.deposits| 
            decreases |bb.deposits| - i
            invariant s.eth1_deposit_index as int + i <  0x10000000000000000 
            invariant i <= |bb.deposits|
            invariant s' == s.(eth1_deposit_index := (s.eth1_deposit_index as int + i) as uint64) ;  
        {
            s':= process_deposit(s', bb.deposits[i]);
            i := i + 1;
        }
    }

    /**
     *  Process a deposit operation.
     *
     *  @param  s   A state.
     *  @param  d   A deposit.  
     *  @returns    The state obtained depositing of `d` to `s`.
     */
    method process_deposit(s: BeaconState, d : Deposit)  returns (s' : BeaconState)  
        requires s. eth1_deposit_index as int + 1 < 0x10000000000000000 
        ensures s' == s.(eth1_deposit_index := s. eth1_deposit_index + 1)
    {
        s' := s;
        //  Verify the Merkle branch
        // assert is_valid_merkle_branch(
        //     leaf=hash_tree_root(deposit.data),
        //     branch=deposit.proof,
        //     depth=DEPOSIT_CONTRACT_TREE_DEPTH + 1,  # Add 1 for the List length mix-in
        //     index=state.eth1_deposit_index,
        //     root=state.eth1_data.deposit_root,
        // );
        //  Deposits must be processed in order
        s' := s.(eth1_deposit_index := s. eth1_deposit_index + 1);

        // pubkey = deposit.data.pubkey
        // amount = deposit.data.amount
        // validator_pubkeys = [v.pubkey for v in state.validators]
        // if pubkey not in validator_pubkeys:
        //     # Verify the deposit signature (proof of possession) which is not checked by the deposit contract
        //     deposit_message = DepositMessage(
        //         pubkey=deposit.data.pubkey,
        //         withdrawal_credentials=deposit.data.withdrawal_credentials,
        //         amount=deposit.data.amount,
        //     )
        //     domain = compute_domain(DOMAIN_DEPOSIT)  # Fork-agnostic domain since deposits are valid across forks
        //     signing_root = compute_signing_root(deposit_message, domain)
        //     if not bls.Verify(pubkey, signing_root, deposit.data.signature):
        //         return

        //     # Add validator and balance entries
        //     state.validators.append(get_validator_from_deposit(state, deposit))
        //     state.balances.append(amount)
        // else:
        //     # Increase balance by deposit amount
        //     index = ValidatorIndex(validator_pubkeys.index(pubkey))
            // increase_balance(state, index, amount)

        //  Simplified version assuming the validator is already in state.validators (else section above)
        //  Increase balance by deposit amount
        // var index := ValidatorIndex(validator_pubkeys.index(pubkey))
        // increase_balance(state, index, amount);
        return s';
    }

}