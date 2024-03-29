/**
 *                                      FLOW
 * makeDealProposal -> getDealProposal -> handle_filecoin_method Market Actor {MarketAPI} -> 
 * authenticateMessage -> dealNotify
 */

 /** 
 * "makeDealProposal" is the entry point for a client trying to store data on filecoin, she will provide all details
 *  necessary for storing files. "makeDealProposal" function emits a event. This events is listened by Storage Providers. 
 * Give out metadata for SP to index the deal. Once the SP gets the event they can ask for the 'deal proposal details' using
 * "getDealProposal" function. "getDealProposal" function returns a CBOR encoded bytes of the protocol verison of deal 
 * proposal struct.
 * 
 * SP now has your deal request, once they do their validation on it and they want to make a deal. They will send a publish 
 * deal message with the deal proposal to the market actor which will then call back into your contract through the 
 * "handle_filecoin_method" function.
 * 
 * now this "handle_filecoin_method" is a universal entry point for any "EVM based actor" for a call coming from a
 * built-in filecoin actor and it specifies a method in the params. Its primarily acts as a dispatcher to what we would
 * consider the proper apis for each of these different methods.
 * 
 * Public storage deals has two callbacks into the contract 
 * Authenticate Message and market deal notify
 * 
 */

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {MarketAPI} from "@zondax/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import {CommonTypes} from "@zondax/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {MarketTypes} from "@zondax/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import {AccountTypes} from "@zondax/filecoin-solidity/contracts/v0.8/types/AccountTypes.sol";
import {CommonTypes} from "@zondax/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {AccountCBOR} from "@zondax/filecoin-solidity/contracts/v0.8/cbor/AccountCbor.sol";
import {MarketCBOR} from "@zondax/filecoin-solidity/contracts/v0.8/cbor/MarketCbor.sol";
import {BytesCBOR} from "@zondax/filecoin-solidity/contracts/v0.8/cbor/BytesCbor.sol";
import {BigNumbers} from "@zondax/filecoin-solidity/contracts/v0.8/external/BigNumbers.sol";
import {CBOR} from "@zondax/filecoin-solidity/contracts/v0.8/external/CBOR.sol";
import {Misc} from "@zondax/filecoin-solidity/contracts/v0.8/utils/Misc.sol";
import {FilAddresses} from "@zondax/filecoin-solidity/contracts/v0.8/utils/FilAddresses.sol";
import {MarketDealNotifyParams, deserializeMarketDealNotifyParams, serializeDealProposal, deserializeDealProposal} from "./Types.sol";

using CBOR for CBOR.CBORBuffer;

struct ProposalIdSet {
    bytes32 proposalId;
    bool valid;
}

struct ProposalIdx {
    uint256 idx;
    bool valid;
}

struct ProviderSet {
    bytes provider;
    bool valid;
}

// User request for this contract to make a deal. This structure is modelled after Filecoin's Deal
// Proposal, but leaves out the provider, since any provider can pick up a deal broadcast by this
// contract.
struct DealRequest {
    bytes piece_cid;
    uint64 piece_size;
    bool verified_deal;
    string label;
    int64 start_epoch;
    int64 end_epoch;
    uint256 storage_price_per_epoch;
    uint256 provider_collateral;
    uint256 client_collateral;
    uint64 extra_params_version;
    ExtraParamsV1 extra_params;
}

// Extra parameters associated with the deal request. These are off-protocol flags that
// the storage provider will need.
struct ExtraParamsV1 {
    string location_ref;
    uint64 car_size;
    bool skip_ipni_announce;
    bool remove_unsealed_copy;
}

function serializeExtraParamsV1(
    ExtraParamsV1 memory params
) pure returns (bytes memory) {
    CBOR.CBORBuffer memory buf = CBOR.create(64);
    buf.startFixedArray(4);
    buf.writeString(params.location_ref);
    buf.writeUInt64(params.car_size);
    buf.writeBool(params.skip_ipni_announce);
    buf.writeBool(params.remove_unsealed_copy);
    return buf.data();
}

contract DealClient {
    using AccountCBOR for *;
    using MarketCBOR for *;

    uint64 public constant AUTHENTICATE_MESSAGE_METHOD_NUM = 2643134072;
    uint64 public constant DATACAP_RECEIVER_HOOK_METHOD_NUM = 3726118371;
    uint64 public constant MARKET_NOTIFY_DEAL_METHOD_NUM = 4186741094;
    address public constant MARKET_ACTOR_ETH_ADDRESS =
        address(0xff00000000000000000000000000000000000005);
    address public constant VERIFREG_ACTOR_ETH_ADDRESS =
        address(0xFF00000000000000000000000000000000000006);

    mapping(bytes32 => ProposalIdx) public dealProposals; // contract deal id -> deal index
    mapping(bytes => ProposalIdSet) public pieceToProposal; // commP -> dealProposalID
    mapping(bytes => ProviderSet) public pieceProviders; // commP -> provider
    mapping(bytes => uint64) public pieceDeals; // commP -> deal ID
    DealRequest[] public deals;

    event ReceivedDataCap(string received);
    event DealProposalCreate(
        bytes32 indexed id,
        uint64 size,
        bool indexed verified,
        uint256 price
    );

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function getProviderSet(
        bytes calldata cid
    ) public view returns (ProviderSet memory) {
        return pieceProviders[cid];
    }

    function getProposalIdSet(
        bytes calldata cid
    ) public view returns (ProposalIdSet memory) {
        return pieceToProposal[cid];
    }

    function dealsLength() public view returns (uint256) {
        return deals.length;
    }

    function getDealByIndex(
        uint256 index
    ) public view returns (DealRequest memory) {
        return deals[index];
    }

    /**
     * @notice This is the entry point for a client trying to store data on filecoin
     * @dev this function should be called by owner 
     */
    function makeDealProposal(
        DealRequest calldata deal
    ) public returns (bytes32) {
        // TODO: length check on byte fields
        require(msg.sender == owner);

        uint256 index = deals.length;
        deals.push(deal);

        // creates a unique ID for the deal proposal -- there are many ways to do this
        bytes32 id = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, index)
        );
        dealProposals[id] = ProposalIdx(index, true);

        pieceToProposal[deal.piece_cid] = ProposalIdSet(id, true);

        // writes the proposal metadata to the event log
        // This events is listened by Storage Providers. Give out metadata for SP to index the deal
        emit DealProposalCreate(
            id,
            deal.piece_size,
            deal.verified_deal,
            deal.storage_price_per_epoch
        );

        return id;
    }

    // helper function to get deal request based from id
    function getDealRequest(
        bytes32 proposalId
    ) internal view returns (DealRequest memory) {
        ProposalIdx memory pi = dealProposals[proposalId];
        require(pi.valid, "proposalId not available");

        return deals[pi.idx];
    }

    // Returns a CBOR-encoded DealProposal.
    function getDealProposal(
        bytes32 proposalId
    ) public view returns (bytes memory) {
        DealRequest memory deal = getDealRequest(proposalId);

        MarketTypes.DealProposal memory ret;
        ret.piece_cid = CommonTypes.Cid(deal.piece_cid);
        ret.piece_size = deal.piece_size;
        ret.verified_deal = deal.verified_deal;
        ret.client = getDelegatedAddress(address(this));
        // Set a dummy provider. The provider that picks up this deal will need to set its own address.
        ret.provider = FilAddresses.fromActorID(0);
        ret.label = deal.label;
        ret.start_epoch = deal.start_epoch;
        ret.end_epoch = deal.end_epoch;
        ret.storage_price_per_epoch = uintToBigInt(
            deal.storage_price_per_epoch
        );
        ret.provider_collateral = uintToBigInt(deal.provider_collateral);
        ret.client_collateral = uintToBigInt(deal.client_collateral);

        return serializeDealProposal(ret);
    }

    // TODO fix in filecoin-solidity. They're using the wrong hex value.
    function getDelegatedAddress(
        address addr
    ) internal pure returns (CommonTypes.FilAddress memory) {
        return CommonTypes.FilAddress(abi.encodePacked(hex"040a", addr));
    }

    function getExtraParams(
        bytes32 proposalId
    ) public view returns (bytes memory extra_params) {
        DealRequest memory deal = getDealRequest(proposalId);
        return serializeExtraParamsV1(deal.extra_params);
    }

    /**
     * @notice how you would vet the deal proposal coming from the SP and gives you the chance to either accept this deal or reject it.
     */
    function authenticateMessage(bytes memory params) internal view {
        require(
            msg.sender == MARKET_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be market actor f05"
        );

        AccountTypes.AuthenticateMessageParams memory amp = params
            .deserializeAuthenticateMessageParams();
        MarketTypes.DealProposal memory proposal = deserializeDealProposal(
            amp.message
        );

        bytes memory pieceCid = proposal.piece_cid.data;
        require(pieceToProposal[pieceCid].valid, "piece cid must be added before authorizing");
        require(!pieceProviders[pieceCid].valid, "deal failed policy check: provider already claimed this cid");

        DealRequest memory req = getDealRequest(pieceToProposal[pieceCid].proposalId);
        require(proposal.verified_deal == req.verified_deal, "verified_deal param mismatch");
        require(bigIntToUint(proposal.storage_price_per_epoch) <= req.storage_price_per_epoch, "storage price greater than request amount");
        require(bigIntToUint(proposal.client_collateral) < req.client_collateral, "client collateral greater than request amount");
    }


    /**
     * @notice this function basically means the deal proposal has passed all the validation in the storage market actor
     * and is ready to fully published
     * you can add more logic for final rejection of the deal
     * @dev this function also gives you dealID for the final deal which is then stored on chain and can be used to query
     * deal state. 
     */
    function dealNotify(bytes memory params) internal {
        require(
            msg.sender == MARKET_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be market actor f05"
        );

        MarketDealNotifyParams memory mdnp = deserializeMarketDealNotifyParams(
            params
        );
        MarketTypes.DealProposal memory proposal = deserializeDealProposal(
            mdnp.dealProposal
        );

        require(
            pieceToProposal[proposal.piece_cid.data].valid,
            "piece cid must be added before authorizing"
        );
        require(
            !pieceProviders[proposal.piece_cid.data].valid,
            "deal failed policy check: provider already claimed this cid"
        );

        pieceProviders[proposal.piece_cid.data] = ProviderSet(
            proposal.provider.data,
            true
        );
        pieceDeals[proposal.piece_cid.data] = mdnp.dealId;
    }


    /**
     * @notice addBalance funds the builtin storage market actor's escrow
     * with funds from the contract's own balance
     * @param value - amount to be added in escrow in attoFIL
     */
    function addBalance(uint256 value) public {
        require(msg.sender == owner);
        MarketAPI.addBalance(getDelegatedAddress(address(this)), value);
    }

    // TODO: Below 2 funcs need to go to filecoin.sol
    function uintToBigInt(
        uint256 value
    ) internal view returns (CommonTypes.BigInt memory) {
        BigNumbers.BigNumber memory bigNumVal = BigNumbers.init(value, false);
        CommonTypes.BigInt memory bigIntVal = CommonTypes.BigInt(
            bigNumVal.val,
            bigNumVal.neg
        );
        return bigIntVal;
    }

    function bigIntToUint(
        CommonTypes.BigInt memory bigInt
    ) internal view returns (uint256) {
        BigNumbers.BigNumber memory bigNumUint = BigNumbers.init(
            bigInt.val,
            bigInt.neg
        );
        uint256 bigNumExtractedUint = uint256(bytes32(bigNumUint.val));
        return bigNumExtractedUint;
    }

    // This function attempts to withdraw the specified amount from the contract addr's escrow balance
    // If less than the given amount is available, the full escrow balance is withdrawn
    // @client - Eth address where the balance is withdrawn to. This can be the contract address or an external address
    // @value - amount to be withdrawn in escrow in attoFIL
    /** */
    function withdrawBalance(
        address client,
        uint256 value
    ) public returns (uint) {
        require(msg.sender == owner);

        MarketTypes.WithdrawBalanceParams memory params = MarketTypes
            .WithdrawBalanceParams(
                getDelegatedAddress(client),
                uintToBigInt(value)
            );
        CommonTypes.BigInt memory ret = MarketAPI.withdrawBalance(params);

        return bigIntToUint(ret);
    }

    function receiveDataCap(bytes memory params) internal {
        require(
            msg.sender == VERIFREG_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be verifreg actor f06"
        );
        emit ReceivedDataCap("DataCap Received!");
        // Add get datacap balance api and store datacap amount
    }

    function handle_filecoin_method(
        uint64 method,
        uint64,
        bytes memory params
    ) public returns (uint32, uint64, bytes memory) {
        bytes memory ret;
        uint64 codec;
        // dispatch methods
        if (method == AUTHENTICATE_MESSAGE_METHOD_NUM) {
            authenticateMessage(params);
            // If we haven't reverted, we should return a CBOR true to indicate that verification passed.
            CBOR.CBORBuffer memory buf = CBOR.create(1);
            buf.writeBool(true);
            ret = buf.data();
            codec = Misc.CBOR_CODEC;
        } else if (method == MARKET_NOTIFY_DEAL_METHOD_NUM) {
            dealNotify(params);
        } else if (method == DATACAP_RECEIVER_HOOK_METHOD_NUM) {
            receiveDataCap(params);
        } else {
            revert("the filecoin method that was called is not handled");
        }
        return (0, codec, ret);
    }
}