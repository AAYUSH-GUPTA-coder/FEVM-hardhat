/**
 * @title 
 * @author 
 * @notice 
 */

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { MarketAPI } from "@zondax/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import { CommonTypes } from "@zondax/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import { MarketTypes } from "@zondax/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import { Actor } from "@zondax/filecoin-solidity/contracts/v0.8/utils/Actor.sol";
import { Misc } from "@zondax/filecoin-solidity/contracts/v0.8/utils/Misc.sol";

/* 
Contract Usage
    Step   |   Who   |    What is happening  |   Why 
    ------------------------------------------------
    Deploy | contract owner   | contract owner deploys address is owner who can call addCID  | create contract setting up rules to follow
    AddCID | data pinners     | set up cids that the contract will incentivize in deals      | add request for a deal in the filecoin network, "store data" function
    Fund   | contract funders |  add FIL to the contract to later by paid out by deal        | ensure the deal actually gets stored by providing funds for bounty hunter and (indirect) storage provider
    Claim  | bounty hunter    | claim the incentive to complete the cycle                    | pay back the bounty hunter for doing work for the contract
*/
contract DealRewarder {
    // mapping to store the CID, for example cid 12di3d => true
    mapping(bytes => bool) public cidSet;
    // mapping to store the size of the CID, for example cid 1234d3 => has size 1 MB
    mapping(bytes => uint) public cidSizes;
    // mapping to check whether the CID of size(CID Size) is stored or not
    // Cid => (size of CID => true/false) 
    mapping(bytes => mapping(uint64 => bool)) public cidProviders;

    address public owner;
    //?? Actor Constants
    address constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    uint64 constant DEFAULT_FLAG = 0x00000000;
    uint64 constant METHOD_SEND = 0;
    

    constructor() {
        owner = msg.sender;
    }

    function fund(uint64 unused) public payable {}

    /**
     * @notice function to add CID and its size to mapping
     * @param cidraw contract identification
     * @param size size of the file
     */
    function addCID(bytes calldata cidraw, uint size) public {
       require(msg.sender == owner,"not owner");
       cidSet[cidraw] = true;
       cidSizes[cidraw] = size;
    }

    /**
     * @notice function to check whether the CID of size(CID Size) is already stored or not
     * @param cidraw contract identification
     * @param provider size of the file
     * @return _ if already stored then return False else true 
     */
    function policyOK(bytes memory cidraw, uint64 provider) internal view returns (bool) {
        bool alreadyStoring = cidProviders[cidraw][provider];
        return !alreadyStoring;
    }

    /**
     * @notice function to authorize the data
     * @param cidraw contract identification
     * @param provider size of the file
     * @param size size of the file
     */
    function authorizeData(bytes memory cidraw, uint64 provider, uint size) public {
        require(cidSet[cidraw], "cid must be added before authorizing");
        require(cidSizes[cidraw] == size, "data size must match expected");
        require(policyOK(cidraw, provider), "deal failed policy check: has provider already claimed this cid?");

        cidProviders[cidraw][provider] = true;
    }

    /**
     * @notice function to send fil to Bounty Hunter
     * @param deal_id deal ID
     * @dev function can be called by anyone but the money/fil will be send to bounty hunter
     */
    function claim_bounty(uint64 deal_id) public {
        // get CID of the dealID
        MarketTypes.GetDealDataCommitmentReturn memory commitmentRet = MarketAPI.getDealDataCommitment(deal_id);

        // get the storage provider details
        MarketTypes.GetDealProviderReturn memory providerRet = MarketAPI.getDealProvider(deal_id);

        authorizeData(commitmentRet.data, providerRet.provider, commitmentRet.size);

        // get dealer (bounty hunter client)
        MarketTypes.GetDealClientReturn memory clientRet = MarketAPI.getDealClient(deal_id);

        // send reward to client 
        send(clientRet.client);
    }


    function call_actor_id(uint64 method, uint256 value, uint64 flags, uint64 codec, bytes memory params, uint64 id) public returns (bool, int256, uint64, bytes memory) {
        (bool success, bytes memory data) = address(CALL_ACTOR_ID).delegatecall(abi.encode(method, value, flags, codec, params, id));
        (int256 exit, uint64 return_codec, bytes memory return_value) = abi.decode(data, (int256, uint64, bytes));
        return (success, exit, return_codec, return_value);
    }

    // send 1 FIL to the filecoin actor at actor_id
    function send(uint64 actorID) internal {
        bytes memory emptyParams = "";
        delete emptyParams;

        uint oneFIL = 1000000000000000000;
        Actor.callByID(actorID, METHOD_SEND, Misc.NONE_CODEC, emptyParams, oneFIL, false);

    }

}