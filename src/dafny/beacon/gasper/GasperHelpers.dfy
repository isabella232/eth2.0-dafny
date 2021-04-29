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

include "../../ssz/Constants.dfy"
include "../../utils/Eth2Types.dfy"
include "../attestations/AttestationsTypes.dfy"
include "../attestations/AttestationsHelpers.dfy"
include "../BeaconChainTypes.dfy"
include "../Helpers.dfy"
include "../forkchoice/ForkChoiceTypes.dfy"

/**
 *  Provide definitions of chain, well-formed store, EBB, justified.
 */
module GasperHelpers {
    
    import opened Constants
    import opened Eth2Types
    import opened BeaconChainTypes
    import opened BeaconHelpers
    import opened AttestationsTypes
    import opened AttestationsHelpers
    import opened ForkChoiceTypes
   
    /**
     *  Compute the first block root in chain with slot number less than or equal to an epoch.
     *  Also known as EBB in the Gasper paper.
     *
     *  @param  xb      A sequence of block roots which is a chain. First element
     *                  is the block with highest slot.
     *  @param  e       An epoch.
     *  @param  store   A store.
     *  @return         The index i of the first block root in xb (left to right) with 
     *                  slot number less than or equal to the epoch `e`. 
     *  @note           We don't need the assumption that the list of blocks in `xb`
     *                  are ordered by slot number.
     *  @note           LEBB(xb) is defined by computeEBBAtEpoch(xb, epoch(first(xb))).
     *  
     *  epoch   0            1            2            3            4            5  
     *          |............|............|............|............|............|....
     *  block   b5----------->b4---------->b3---->b2------>b1------->b0      
     *  slot    0             32           65      95      105       134
     *       
     *  For any sequence xb == [..,b5], EBB(xb, 0) == (b5, 0).
     *
     *  Example 1. xb == [b0, b1, b2, b3, b4, b5].
     *  if e >= 5, EBB(xb, e) == (b0, e). 
     *  If e == 4, EBB(xb, 4) == b1 (last block in epoch 4). 
     *  As epoch(b0) == 4, LEBB(xb) == EBB(xb, epoch(b0)) == b1.
     *
     *  Example 2. xb == [b4, b5].
     *  If e >= 2, EBB(xb,e) == (b4, e). If e == 1, EBB(xb, 1) == (b4,1).
     *  LEBB(xb) == (32, 1).
     *  
     *  Example 3. xb == [b2, b3, b4, b5].
     *  If e >= 3, EBB(xb, e) == (b2, 3). 
     *  If e == 2, EBB(xb, 2) == (b4, 2).
     *  If e == 1, EBB(xb, 1) == (b0, 1).
     *  LEBB(xb) == (b4, 2).
     */
    function computeEBBsForAllEpochs(xb: seq<Root>, e: Epoch, store: Store): seq<Root>

        requires |xb| >= 1
        /** A slot decreasing chain of roots. */
        requires isChain(xb, store)

        /** The result is in the range of xb. */
        ensures |computeEBBsForAllEpochs(xb, e, store)| == e as nat + 1

        /** All the block roots are in the store. */
        ensures forall b:: b in computeEBBsForAllEpochs(xb, e, store) ==> b in store.blocks.Keys

        /** EBB for epoch 0 is a block with slot == 0. */
        ensures store.blocks[computeEBBsForAllEpochs(xb, e, store)[e]].slot == 0  

        /** The slots of the EBB at epoch k is less or equal to k * SLOTS_PER_EPOCH. */
        ensures forall k:: 0 <= k <= e ==>
            //  EBBs are collected in reverse order, so EBB at epoch k has index e - k
            store.blocks[computeEBBsForAllEpochs(xb, e, store)[e - k]].slot as nat <= k as nat * SLOTS_PER_EPOCH as nat

        decreases xb, e
    {
        if store.blocks[xb[0]].slot as nat <= e as nat * SLOTS_PER_EPOCH as nat  then 
            //  first block is a good one. If e > 0 continue with e - 1, stop otherwise.
            assert(e == 0 ==> store.blocks[xb[0]].slot == 0);
            [xb[0]] + 
                (if e > 0 then computeEBBsForAllEpochs(xb, e - 1, store) else [])
        else 
            //  First block has too large a slot, search suffix of xb.
            //  Note that this implies that the slot > 0 and hence |xb| >= 2 
            assert(|xb| >= 2);
            computeEBBsForAllEpochs(xb[1..], e, store)
    }

    /**
     *  The EBB for epoch 0 is the last element of `xb`.
     *
     *  @param  xb      A sequence of block roots, the last one with slot == 0.
     *  @param  e       An epoch.
     *  @param  store   A store.
     */
    // lemma {:induction xb} ebbForEpochZeroIsLast(xb : seq<Root>, e :  Epoch, store: Store)
    //     requires |xb| >= 1
    //     /** A slot decreasing chain of roots. */
    //     requires isChain(xb, store)

    //     ensures computeEBBAtEpoch(xb, 0, store) == |xb| - 1
    // {   //  Thanks Dafny
    // }
   
    /**
     *  Compute all the EBBs in a chain of block roots.
     *
     *  @param  xb      A sequence of block roots, the last one has slot equal to 0.
     *  @param  e       An epoch.
     *  @param  store   A store.
     *  @returns        The sequence of e + 1 EBBs for each epoch 0 <= e' <= e.
     *                  Element at index 0 <= k < |computeAllEBBsIndices()| is 
     *                  EBB(xb, e - k).
     *
     *  epoch   0            1            2            3            4            5  ...
     *          |............|............|............|............|............|  ...
     *  block   b5----------->b4---------->b3---->b2------>b1------->b0      
     *  slot    0             32           65      95      105       134
     *       
     *  For any sequence xb == [..,b5], EBB(xb, 0) == (b5, 0).
     *
     *  Example 1. xb == [b0, b1, b2, b3, b4, b5].
     *  if e >= 5, EBB(xb, e) == (b0, e). 
     *  If e == 4, EBB(xb, 4) == b1 (last block in epoch 4). 
     *  As epoch(b0) == 4, LEBB(xb) == EBB(xb, epoch(b0)) == b1.
     *  computeAllEBBsIndices(xb, 6) = [b0, b0, b1, b2, b4, b5, b5]
     *
     */
    // function computeAllEBBsIndices(xb : seq<Root>, e :  Epoch, store: Store) : seq<nat>
    //     requires |xb| >= 1
    //     /** A slot decreasing chain of roots. */
    //     requires isChain(xb, store)

    //     /** Store is well-formed. */
    //     requires isClosedUnderParent(store)
    //     requires isSlotDecreasing(store)

    //     /** Each epoch has a block associated to. */
    //     ensures |computeAllEBBsIndices(xb, e, store)| == e as nat + 1
    //     /** The index for each epoch is in the range of xb. */
    //     ensures forall i :: 0 <= i < e as nat + 1 ==> computeAllEBBsIndices(xb, e, store)[i] < |xb|
    //     /** The sequence returned is in decreasing order slot-wise. */
    //     ensures forall i :: 1 <= i < e as nat + 1 ==> 
    //         store.blocks[xb[computeAllEBBsIndices(xb, e, store)[i - 1]]].slot >= store.blocks[xb[computeAllEBBsIndices(xb, e, store)[i]]].slot
    //     /** The epoch e - i boundary block has a slot less than (e - i) * SLOTS_PER_EPOCH. */
    //     ensures forall i :: 0 <= i < e as nat + 1 
    //         ==> store.blocks[xb[computeAllEBBsIndices(xb, e, store)[i]]].slot as nat <= (e as nat - i) * SLOTS_PER_EPOCH as nat 
    //     /** The  blocks at index j less than the epoch e - i boundary block have a slot 
    //         larger than  (e - i) * SLOTS_PER_EPOCH. */
    //     ensures forall i :: 0 <= i < e as nat + 1 ==> 
    //         forall j :: 0 <= j < computeAllEBBsIndices(xb, e, store)[i] ==>
    //         store.blocks[xb[j]].slot as nat > (e as nat - i) * SLOTS_PER_EPOCH as nat
    //     ensures computeAllEBBsIndices(xb, e, store)[|computeAllEBBsIndices(xb, e, store)| - 1] == |xb| - 1
        
    //     decreases e 
    // {
    //     ebbForEpochZeroIsLast(xb, e, store);
    //     //  Get the first boundary block less than or equal to e
    //     [computeEBBAtEpoch(xb, e, store)] +
    //     (
    //         //  if e > 0 recursive call, otherwise, terminate.
    //         if e == 0 then 
    //             []
    //         else 
    //             computeAllEBBsIndices(xb, e - 1, store)
    //     )
    // }

    /**
     *  @param  br      A block root.
     *  @param  e       An epoch.
     *  @param  store   A store.
     *  @returns        The sequence s of e + 1 block roots that are EBB at each epoch
     *                  0 <= e' <= e.
     *                  The EBB at epoch e' is s[e - e'].
     *  @note           We could change the def to have EBB at epoch e' is s[e'] if it simplifies
     *                  things.
     */
    // function computeAllEBBs(br: Root, e:  Epoch, store: Store) : seq<Root>
    //     /** The block root must in the store.  */
    //     requires br in store.blocks.Keys

    //     /** Store is well-formed. */
    //     requires isClosedUnderParent(store)
    //     requires isSlotDecreasing(store)

    //     /** Define this function by its post conditions. */
    //     ensures |computeAllEBBs(br, e, store)| == e as nat + 1
    //     ensures forall k:: 0 <= k <= e ==> 
    //         computeAllEBBs(br, e, store)[k] 
    //         == chainRoots(br, store)[computeAllEBBsIndices(chainRoots(br, store), e, store)[k]]

    /**
     *  The index of the first (left to right) i.e. most recent justified ebb.
     *  
     *  @param  i       An index in the sequence of ebbs.
     *  @param  xb      A sequence of block roots.
     *  @param  ebbs    A sequence of indices. (xb[ebbs(j)],j) is EBB(xb, |ebbs| - 1 - j).
     *                  The last element (xb[ebbs[|ebbs| - 1]], |ebbs| - 1 - (|ebbs| - 1) )
     *                  i.e. (xb[|xb| - 1], 0) is assumed to be justified.
     *  @param  links   All the attestations received so far.
     *  @returns        Whether (xb[ebbs[i]], i) is justified according to the votes in *                  `links`.         
     *  @note           ebbs contains EBB for epochs |ebbs| - 1 down to 0. 
     */
    // function lastJustified(xb : seq<Root>, ebbs: seq<nat>,  links : seq<PendingAttestation>): nat
    //     /** `xb` has at least one block. */
    //     requires |xb| >= 1
    //     requires 1 <= |ebbs| <= 0x10000000000000000
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     requires ebbs[|ebbs| - 1] == |xb| - 1
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] < |xb|

    //     ensures lastJustified(xb, ebbs, links) < |ebbs|
    //     ensures isJustified(lastJustified(xb, ebbs, links), xb, ebbs, links)
    //     /** No index less than lastJustified is justified.  */
    //     ensures forall i :: 0 <= i < lastJustified(xb, ebbs, links) ==> 
    //         !isJustified(i, xb, ebbs, links)
   
    /**
     *  
     *  @param  i       An epoch before the epoch of `br`.
     *  @param  br      A block root.
     *
     *  @param  links   All the attestations received so far.
     *  @returns        Whether (xb[ebbs[i]], i) is justified according to the votes in *                  `links`.         
     *  @note           ebbs contains EBB for epochs |ebbs| - 1 down to 0. 
     */
    // predicate isJustified(i: nat, br: Root, links : seq<PendingAttestation>)
    //     /** i is an index in ebbs, and each index represent an epoch so must be uint64. */
    //     requires i < |ebbs| <= 0x10000000000000000
    //     /** `xb` has at least one block. */
    //     requires |xb| >= 1
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     requires ebbs[|ebbs| - 1] == |xb| - 1
        
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] < |xb|

    //     decreases |ebbs| - i 
    // {
    //     // true
    //     if i == |ebbs| - 1 then 
    //         // Last block in the list is assumed to be justified.
    //         true
    //     else 
    //         //  There should be a justified block at a higher index `j` that is justified
    //         //  and a supermajority link from `j` to `i`.
    //         exists j  :: i < j < |ebbs| - 1 && isJustified(j, xb, ebbs, links) 
    //             && |collectValidatorsAttestatingForLink(
    //                 links, 
    //                 CheckPoint(j as Epoch, xb[ebbs[j]]), 
    //                 CheckPoint(i as Epoch, xb[ebbs[i]]))| 
    //                     >= (2 * MAX_VALIDATORS_PER_COMMITTEE) / 3 + 1
    // }

    /**
     *  
     *  @param  i       An epoch before the epoch of `br`.
     *  @param  links   All the attestations received so far.
     *  @param  store   A store.
     *
     *  @returns        Whether (ebbs[i], i) is justified according to the votes in *                  `links`.         
     *  @note           ebbs contains EBB for epochs |ebbs| - 1 down to 0. 
     */
    // predicate isJustifiedEpoch(i: nat, ebbs: seq<Root>, store: Store, links : seq<PendingAttestation>)
    //     /** i is an index in ebbs, and each index represent an epoch so must be uint64. */
    //     requires i < |ebbs| <= 0x10000000000000000
    //     /** `xb` has at least one block. */
    //     // requires |xb| >= 1
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     // requires ebbs[|ebbs| - 1] == |xb| - 1
        
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     // requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] < |xb|

    //     decreases |ebbs| - i  
    // {
    //     // true
    //     if i == |ebbs| - 1 then 
    //         // Last block in the list is assumed to be justified.
    //         store.blocks[ebbs[0]].slot == 0 
    //     else 
    //         //  There should be a justified block at a higher index `j` that is justified
    //         //  and a supermajority link from `j` to `i`.
    //         exists j  :: i < j < |ebbs| - 1 && isJustifiedEpoch(j, xb, ebbs, links) 
    //             && |collectValidatorsAttestatingForLink(
    //                 links, 
    //                 CheckPoint(j as Epoch, xb[ebbs[j]]), 
    //                 CheckPoint(i as Epoch, xb[ebbs[i]]))| 
    //                     >= (2 * MAX_VALIDATORS_PER_COMMITTEE) / 3 + 1
    // }


    /**
     *  ebbs[k] is the the EBB at epoch |ebbs| - 1 - k    
     */
    // predicate isJustified2(i: nat, ebbs: seq<Root>, store: Store, links : seq<PendingAttestation>)
    //     /** i is an index in ebbs, and each index represent an epoch so must be uint64. */
    //     requires i < |ebbs| <= 0x10000000000000000
    //     /** `xb` has at least one block. */
    //     // requires |xb| >= 1
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     // requires ebbs[|ebbs| - 1] == |xb| - 1
        
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] in store.blocks.Keys

    //     decreases |ebbs| - i 
    // {
    //     // true
    //     if i == |ebbs| - 1 then 
    //         // Last block in the list is justified it has slot 0
    //         store.blocks[ebbs[0]].slot == 0
    //     else 
    //         //  There should be a justified block at a higher index `j` that is justified
    //         //  and a supermajority link from `j` to `i`.
    //         exists j  :: i < j < |ebbs| - 1 && isJustified2(j, ebbs, store, links) 
    //             && |collectValidatorsAttestatingForLink(
    //                 links, 
    //                 CheckPoint(j as Epoch, ebbs[j]), 
    //                 CheckPoint(i as Epoch, ebbs[i]))| 
    //                     >= (2 * MAX_VALIDATORS_PER_COMMITTEE) / 3 + 1
    // }

    /**
     *  
     *  @param  i       An index in the sequence of ebbs. This is not the epoch
     *                  of a checkpoint but rather the epoch is |ebbs| - 1 - i 
     *  @param  xb      A sequence of block roots from most recent to genesis root.
     *  @param  ebbs    A sequence of indices. (xb[ebbs(j)],j) is EBB(xb, |ebbs| - 1 - j).
     *                  The last element (xb[ebbs[|ebbs| - 1]], |ebbs| - 1 - (|ebbs| - 1) )
     *                  i.e. (xb[|xb| - 1], 0) is assumed to be justified.
     *  @param  links   All the attestations received so far.
     *  @returns        Whether (xb[ebbs[i]], i) is 1-finalised according to the votes in *                  `links`.         
     *  @note           ebbs contains EBB for epochs |ebbs| - 1 down to 0. 
     */
    // predicate isOneFinalised(i: nat, xb : seq<Root>, ebbs: seq<nat>,  links : seq<PendingAttestation>)
    //     /** i is an index in ebbs, and each index represents an epoch so must be uint64.
    //      *  i is not the first index as to be 1-finalised it needs to have at least on descendant.
    //      */
    //     requires 0 < i < |ebbs|  <= 0x10000000000000000
    //     // requires 0 < i 
    //     /** `xb` has at least two blocks. */
    //     requires |xb| >= 2
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     requires ebbs[|ebbs| - 1] == |xb| - 1
        
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] < |xb|

    //     decreases |ebbs| - i 
    // {
    //     //  1-finalised: is justified and justifies the next EBB.
    //     isJustified(i, xb, ebbs, links) &&
    //     //  note: the EBBs are in reverse order in `ebbs`
    //     |collectValidatorsAttestatingForLink(
    //         links, 
    //         CheckPoint(i as Epoch, xb[ebbs[i]]),                //  source
    //         CheckPoint((i - 1) as Epoch, xb[ebbs[i - 1]]))|     //  target
    //             >= (2 * MAX_VALIDATORS_PER_COMMITTEE) / 3 + 1
    // }
    
    /**
     *  
     *  @param  i       An index in the sequence of ebbs. This is not the epoch
     *                  of a checkpoint but rather the epoch is |ebbs| - 1 - i 
     *  @param  xb      A sequence of block roots from most recent to genesis root.
     *  @param  ebbs    A sequence of indices. (xb[ebbs(j)],j) is EBB(xb, |ebbs| - 1 - j).
     *                  The last element (xb[ebbs[|ebbs| - 1]], |ebbs| - 1 - (|ebbs| - 1) )
     *                  i.e. (xb[|xb| - 1], 0) is assumed to be justified.
     *  @param  links   All the attestations received so far.
     *  @returns        Whether (xb[ebbs[i]], i) is 2-finalised according to the votes in *                  `links`.         
     *  @note           ebbs contains EBB for epochs |ebbs| - 1 down to 0. 
     */
    // predicate isTwoFinalised(i: nat, xb : seq<Root>, ebbs: seq<nat>,  links : seq<PendingAttestation>)
    //     /** i is an index in ebbs, and each index represents an epoch so must be uint64.
    //      *  i is not the first or second index as to be 1-finalised it needs to have at least on descendant.
    //      */
    //     requires 1 < i < |ebbs|  <= 0x10000000000000000
    //     // requires 0 < i 
    //     /** `xb` has at least two blocks. */
    //     requires |xb| >= 3
    //     /** The last element of ebbs is the EBB at epoch 0 and should be the last block in `xb`. */
    //     requires ebbs[|ebbs| - 1] == |xb| - 1
        
    //     /** (xb[ebbs[j]], j) is the EBB at epoch |ebbs| - j and must be an index in `xb`.  */
    //     requires forall i :: 0 <= i < |ebbs| ==> ebbs[i] < |xb|

    //     decreases |ebbs| - i 
    // {
    //     //  2-finalised
    //     isJustified(i, xb, ebbs, links) &&
    //     //  index i - 1 is justified two 
    //     isJustified(i - 1, xb, ebbs, links) &&
    //     //  index i - 2 is justified by i
    //     //  note: the EBBs are in reverse order in `ebbs`
    //     |collectValidatorsAttestatingForLink(
    //         links, 
    //         CheckPoint(i as Epoch, xb[ebbs[i]]),                //  source
    //         CheckPoint((i - 2) as Epoch, xb[ebbs[i - 2]]))|     //  target
    //              >= (2 * MAX_VALIDATORS_PER_COMMITTEE) / 3 + 1
    // }
                
}
