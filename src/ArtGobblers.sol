// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Strings} from "openzeppelin/utils/Strings.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";

import {VRFCoordinatorV2Interface} from "chainlink/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "chainlink/v0.8/VRFConsumerBaseV2.sol";

import {VRGDA} from "./utils/VRGDA.sol";
import {ERC1155B} from "./utils/ERC1155B.sol";
import {LogisticVRGDA} from "./utils/LogisticVRGDA.sol";

import {Goop} from "./Goop.sol";
import {Pages} from "./Pages.sol";

// TODO: can we just have tokenid start with 0 why 1 bro its confusing af

// TODO; all addresses can be constants, predict them

// TODO: events??? do we have events?? indexed??
// TODO: UNCHECKED
// TODO: sync link to avoid extcall
// TODO: Make sure we're ok with people being able to mint one more than the max (cuz we start at 0)
// TODO: check everything is being packed properly with forge inspect
// TODO: ensure it was safe that we removed the max supply checks
// TODO: can we make mint start constant by setting merkle root at deploy uwu would save sload
// TODO: can we save gas by using SSTORE2 for attributes?
// TODO: trigger afterTransfer on reveal
// TODO: this contract needs to be marked an ERC1155 receiver

/// @title Art Gobblers NFT (GBLR)
/// @notice Art Gobblers scan the cosmos in search of art producing life.
contract ArtGobblers is ERC1155B, Auth(msg.sender, Authority(address(0))), VRFConsumerBaseV2, LogisticVRGDA {
    using Strings for uint256;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                ADDRESSES
    //////////////////////////////////////////////////////////////*/

    Goop public immutable goop;

    Pages public immutable pages;

    /*//////////////////////////////////////////////////////////////
                            SUPPLY CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum number of mintable tokens.
    uint256 private constant MAX_SUPPLY = 10000;

    /// @notice Maximum amount of gobblers mintable via whitelist.
    uint256 private constant WHITELIST_SUPPLY = 2000;

    /// @notice Maximum amount of mintable legendary gobblers.
    uint256 private constant LEGENDARY_SUPPLY = 10;

    /*//////////////////////////////////////////////////////////////
                            URI CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Base URI for minted gobblers.
    string public BASE_URI;

    /// @notice URI for gobblers that have yet to be revealed.
    string public UNREVEALED_URI;

    /*//////////////////////////////////////////////////////////////
                              VRF CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal immutable chainlinkKeyHash;

    VRFCoordinatorV2Interface internal immutable vrfCoordinator;

    uint32 internal immutable callbackGasLimit = 100000;

    uint16 internal immutable requestConfirmations = 3;

    /// @notice need two words, one for index and one for multiplier 
    uint32 internal immutable numWords = 2;

    uint64 internal immutable chainlinkSubscriptionId;

    /*//////////////////////////////////////////////////////////////
                             WHITELIST STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Merkle root of mint whitelist.
    bytes32 public immutable merkleRoot;

    /// @notice Mapping to keep track of which addresses have claimed from whitelist.
    mapping(address => bool) public claimedWhitelist;

    /*//////////////////////////////////////////////////////////////
                            VRGDA INPUT STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Timestamp for the start of the whitelist & VRGDA mint.
    uint256 public immutable mintStart;

    /// @notice Number of gobblers minted from goop.
    uint128 public numMintedFromGoop;

    /*//////////////////////////////////////////////////////////////
                         STANDARD GOBBLER STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Id of last minted non legendary token.
    uint128 internal currentNonLegendaryId; // TODO: public?

    /*///////////////////////////////////////////////////////////////
                    LEGENDARY GOBBLER AUCTION STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Last 10 ids are reserved for legendary gobblers.
    uint256 private constant LEGENDARY_GOBBLER_ID_START = MAX_SUPPLY - 10;

    /// @notice Struct holding info required for legendary gobbler auctions.
    struct LegendaryGobblerAuctionData {
        /// @notice Start price of current legendary gobbler auction.
        uint120 currentLegendaryGobblerStartPrice;
        /// @notice Start timestamp of current legendary gobbler auction.
        uint120 currentLegendaryGobblerAuctionStart;
        /// @notice Id of last minted legendary gobbler.
        /// @dev 16 bits has a max value of ~60,000,
        /// which is safely within our limits here.
        uint16 currentLegendaryId;
    }

    /// @notice Data about the current legendary gobbler auction.
    LegendaryGobblerAuctionData public legendaryGobblerAuctionData;

    /*//////////////////////////////////////////////////////////////
                             ATTRIBUTE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct holding gobbler attributes.
    // TODO: idx does not need to be this big? split it?
    struct GobblerAttributes {
        /// @notice Index of token after shuffle.
        uint128 idx;
        /// @notice Multiple on goop issuance.
        uint64 stakingMultiple;
    }

    /// @notice Maps gobbler ids to their attributes.
    mapping(uint256 => GobblerAttributes) public getAttributesForGobbler;

    /*//////////////////////////////////////////////////////////////
                         ATTRIBUTES REVEAL STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Index of last token that has been revealed.
    uint128 public lastRevealedIndex;

    /*//////////////////////////////////////////////////////////////
                              STAKING STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct holding info required for goop staking reward calculations.
    struct StakingData {
        /// @notice The sum of the multiples of all gobblers the user holds.
        uint64 multiple;
        /// @notice Balance at time of last deposit or withdrawal.
        uint128 lastBalance;
        /// @notice Timestamp of last deposit or withdrawal.
        uint64 lastTimestamp;
    }

    /// @notice Maps user addresses to their staking data.
    mapping(address => StakingData) public getStakingDataForUser;

    /*//////////////////////////////////////////////////////////////
                            ART FEEDING STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from page ids to gobbler ids they were fed to.
    mapping(uint256 => uint256) public pageIdToGobblerId;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Merkle root was set.
    event MerkleRootSet(bytes32 merkleRoot);

    /// @notice Legendary gobbler was minted.
    event LegendaryGobblerMint(uint256 tokenId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();

    error CannotBurnLegendary();

    error InsufficientGobblerBalance();

    error NoRemainingLegendaryGobblers();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        bytes32 _merkleRoot,
        uint256 _mintStart,
        address _vrfCoordinator,
        bytes32 _chainlinkKeyHash,
        uint64 _chainlinkSubscriptionId,
        string memory _baseUri
    )
        VRFConsumerBaseV2(_vrfCoordinator)
        VRGDA(
            6.9e18, // Initial price.
            0.31e18 // Per period price decrease.
        )
        LogisticVRGDA(
            // Logistic scale. We multiply by 2x (as a wad)
            // to account for the subtracted initial value,
            // and add 1 to ensure all the tokens can be sold:
            int256(MAX_SUPPLY - WHITELIST_SUPPLY - LEGENDARY_SUPPLY + 1) * 2e18,
            0.014e18 // Time scale.
        )
    {
        chainlinkKeyHash = _chainlinkKeyHash;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        chainlinkSubscriptionId = _chainlinkSubscriptionId;

        mintStart = _mintStart;
        merkleRoot = _merkleRoot;

        goop = new Goop(address(this));
        pages = new Pages(address(goop), msg.sender, _mintStart);

        goop.setPages(address(pages));

        BASE_URI = _baseUri;

        // Start price for legendary gobblers is 100 gobblers.
        legendaryGobblerAuctionData.currentLegendaryGobblerStartPrice = 100;

        // First legendary gobbler auction starts 30 days after the mint starts.
        legendaryGobblerAuctionData.currentLegendaryGobblerAuctionStart = uint120(_mintStart + 30 days);

        // Current legendary id starts at beginning of legendary id space.
        legendaryGobblerAuctionData.currentLegendaryId = uint16(LEGENDARY_GOBBLER_ID_START);
    }

    /*//////////////////////////////////////////////////////////////
                             WHITELIST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint from whitelist, using a merkle proof.
    function mintFromWhitelist(bytes32[] calldata _merkleProof) public {
        bytes32 root = merkleRoot;

        if (mintStart > block.timestamp || claimedWhitelist[msg.sender]) revert Unauthorized();

        if (!MerkleProof.verify(_merkleProof, root, keccak256(abi.encodePacked(msg.sender)))) revert Unauthorized();

        claimedWhitelist[msg.sender] = true;

        mintGobbler(msg.sender);

        pages.mintByAuth(msg.sender); // Whitelisted users also get a free page.
    }

    /*//////////////////////////////////////////////////////////////
                           GOOP MINTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint from goop, burning the cost.
    function mintFromGoop() public {
        // No need to check supply cap, gobblerPrice()
        // will revert due to overflow if we reach it.
        // It will also revert prior to the mint start.
        goop.burnForGobblers(msg.sender, gobblerPrice());

        mintGobbler(msg.sender);

        unchecked {
            numMintedFromGoop++;
        }
    }

    /// @notice Gobbler pricing in terms of goop.
    /// @dev Will revert if called before minting starts
    /// or after all gobblers have been minted via VRGDA.
    function gobblerPrice() public view returns (uint256) {
        // We need checked math here to cause overflow
        // before minting has begun, preventing mints.
        uint256 timeSinceStart = block.timestamp - mintStart;

        // TODO: is it ok that numMintedFromGoop starts at 0? idts at all that means we can do +1 more than the limit? or at least pricing is behind idk

        return getPrice(timeSinceStart, numMintedFromGoop);
    }

    function mintGobbler(address mintAddress) internal {
        // Only arithmetic done is the counter increment.
        unchecked {
            uint256 newId = ++currentNonLegendaryId;

            _mint(mintAddress, newId, ""); // TODO: reentrancy?

            // Start generating goop from mint time.
            // TODO: Update the comment above
            // TODO: Is it safe to do this now that its global per user?
            // TODO: i think this is handled in the transfer hook
            getStakingDataForUser[msg.sender].lastTimestamp = uint64(block.timestamp);

            requestRandomnessForReveal();
        }
    }

    /*//////////////////////////////////////////////////////////////
                     LEGENDARY GOBBLER AUCTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a legendary gobbler by burning multiple standard gobblers.
    function mintLegendaryGobbler(uint256[] calldata gobblerIds) public {
        uint256 legendaryId = legendaryGobblerAuctionData.currentLegendaryId;

        // When legendary id surpasses max supply, we've minted all 10 legendary gobblers:
        if (legendaryId >= MAX_SUPPLY) revert NoRemainingLegendaryGobblers();

        // This will revert if the auction hasn't started yet, no need to check here as well.
        uint256 cost = legendaryGobblerPrice();

        if (gobblerIds.length != cost) revert InsufficientGobblerBalance();

        uint256 multiple; // The legendary's multiple will be 2x the sum of the gobblers burned.

        unchecked {
            // Burn the gobblers provided as tribute.
            for (uint256 i = 0; i < gobblerIds.length; i++) {
                uint256 id = gobblerIds[i]; // Cache the current id.

                // TODO: off by one here? does start include all 10?
                if (id >= LEGENDARY_GOBBLER_ID_START) revert CannotBurnLegendary();

                multiple += getAttributesForGobbler[id].stakingMultiple;

                if (msg.sender != ownerOf[id]) revert Unauthorized();

                // TODO: reentrancy?
                // TODO: batch tranfsfer?
                _burn(id); // TODO: can inline this and skip ownership check?
            }

            // Supply caps are properly checked above, so overflow should be impossible here.
            uint256 newId = (legendaryGobblerAuctionData.currentLegendaryId = uint16(legendaryId + 1));

            // Mint the legendary gobbler.
            _mint(msg.sender, newId, "");

            // It gets a special event.
            emit LegendaryGobblerMint(newId);

            // Start a new auction, 30 days after the previous start.
            legendaryGobblerAuctionData.currentLegendaryGobblerAuctionStart += 30 days;

            // TODO: is it ok there are no overflow checks on the left shift
            // New start price is max of 100 and prev_cost * 2. Shift left by 1 is like multiplication by 2.
            legendaryGobblerAuctionData.currentLegendaryGobblerStartPrice = uint120(cost < 50 ? 100 : cost << 1);
        }

        unchecked {
            // The legendary's multiple is 2x the sum of the multiples of the gobblers burned.
            getAttributesForGobbler[legendaryId].stakingMultiple = uint64(multiple * 2);
            getAttributesForGobbler[legendaryId].idx = uint128(legendaryId); // TODO: wait idt we need to do this lol check uri
        }
    }

    /// @notice Calculate the legendary gobbler price in terms of gobblers, according to linear decay function.
    /// @dev Reverts due to underflow if the auction has not yet begun. This is intended behavior and helps save gas.
    function legendaryGobblerPrice() public view returns (uint256) {
        uint256 daysSinceStart = (block.timestamp - legendaryGobblerAuctionData.currentLegendaryGobblerAuctionStart) /
            1 days;

        // If more than 30 days have passed, legendary gobbler is free, else, decay linearly over 30 days.
        // TODO: can we uncheck?
        return
            daysSinceStart >= 30
                ? 0 // TODO: why divide
                : (legendaryGobblerAuctionData.currentLegendaryGobblerStartPrice * (30 - daysSinceStart)) / 30;
    }

    /*//////////////////////////////////////////////////////////////
                                VRF LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice request random word to assign gobbler
    function requestRandomnessForReveal() internal {
        vrfCoordinator.requestRandomWords(
            chainlinkKeyHash,
            chainlinkSubscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
    }

    function fulfillRandomWords(uint256, uint256[] memory randomWords) internal override {
        //shuffle gobblerId with random word
        knuthShuffle(randomWords);
    }

    /*//////////////////////////////////////////////////////////////
                         ATTRIBUTES REVEAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice knuth shuffle random gobbler and select attributes 
    function knuthShuffle(uint256[] memory randomWords) internal {
        unchecked {

            uint256 remainingSlots = LEGENDARY_GOBBLER_ID_START - lastRevealedIndex;

            // Randomly pick distance for swap.
            uint256 distance = randomWords[0] % remainingSlots;

            // Select swap slot, adding distance to next reveal slot.
            uint256 swapSlot = lastRevealedIndex + 1 + distance;

            // If index in swap slot is 0, that means slot has never been touched, thus, it has the default value, which is the slot index.
            uint128 swapIndex = getAttributesForGobbler[swapSlot].idx == 0
                ? uint128(swapSlot)
                : getAttributesForGobbler[swapSlot].idx;

            // Current slot is consecutive to last reveal.
            uint256 currentSlot = lastRevealedIndex + 1;

            // Again, we derive index based on value:
            uint128 currentIndex = getAttributesForGobbler[currentSlot].idx == 0
                ? uint128(currentSlot)
                : getAttributesForGobbler[currentSlot].idx;

            // Swap indices.
            getAttributesForGobbler[currentSlot].idx = swapIndex;
            getAttributesForGobbler[swapSlot].idx = currentIndex;

            uint64 multiple = uint64(randomWords[1] % 128) + 1;

            getAttributesForGobbler[currentSlot].stakingMultiple = multiple;

            address slotOwner = ownerOf[currentSlot];

            getStakingDataForUser[slotOwner].lastBalance = uint128(goopBalance(slotOwner));
            getStakingDataForUser[slotOwner].lastTimestamp = uint64(block.timestamp);
            getStakingDataForUser[slotOwner].multiple += multiple;
            lastRevealedIndex++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                URI LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a token's URI if it has been minted.
    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        // Between 0 and lastRevealedIndex are revealed normal gobblers.
        if (tokenId <= lastRevealedIndex) {
            // 0 is not a valid id:
            if (tokenId == 0) return "";

            return string(abi.encodePacked(BASE_URI, uint256(getAttributesForGobbler[tokenId].idx).toString()));
        }
        // Between lastRevealedIndex + 1 and currentNonLegendaryId are minted but not revealed.
        if (tokenId <= currentNonLegendaryId) return UNREVEALED_URI;

        // Between currentNonLegendaryId and  LEGENDARY_GOBBLER_ID_START are unminted.
        if (tokenId <= LEGENDARY_GOBBLER_ID_START) return "";

        // Between LEGENDARY_GOBBLER_ID_START and currentLegendaryId are minted legendaries.
        if (tokenId <= legendaryGobblerAuctionData.currentLegendaryId)
            return string(abi.encodePacked(BASE_URI, tokenId.toString()));

        return ""; // Unminted legendaries and invalid token ids.
    }

    /*//////////////////////////////////////////////////////////////
                            ART FEEDING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Feed a gobbler a page.
    function feedArt(uint256 gobblerId, uint256 pageId) public {
        // The page must be drawn on and the caller must own this gobbler:
        if (!pages.isDrawn(pageId) || ownerOf[gobblerId] != msg.sender) revert Unauthorized();

        // This will revert if the caller does not own the page.
        pages.safeTransferFrom(msg.sender, address(this), pageId, 1, "");

        // Map the page to the gobbler that ate it.
        pageIdToGobblerId[pageId] = gobblerId;
    }

    /*//////////////////////////////////////////////////////////////
                              STAKING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the balance of goop that is available to withdraw from a gobbler.
    // TODO: do we have this return uint128
    function goopBalance(address user) public view returns (uint256) {
        // TODO: idt this accounts for wads

        unchecked {
            uint256 multiple = getStakingDataForUser[user].multiple;
            uint256 lastBalance = getStakingDataForUser[user].lastBalance;
            uint256 timePassed = block.timestamp - getStakingDataForUser[user].lastTimestamp;

            // If a user's goop balance is greater than
            // 2**256 - 1 we've got much bigger problems.
            // TODO: check i got the new formula without baserate right
            return
                lastBalance +
                ((multiple * (timePassed * timePassed)) / 4) +
                (timePassed * FixedPointMathLib.sqrt(multiple * lastBalance));
        }
    }

    /// @notice Add goop to gobbler for staking.
    function addGoop(uint256 goopAmount) public {
        // Burn goop being added to gobbler.
        goop.burnForGobblers(msg.sender, goopAmount);

        unchecked {
            // If a user has enough goop to overflow their balance we've got big problems.
            // TODO: do we maybe want to use a safecast tho? idk maybe this is not safe.
            getStakingDataForUser[msg.sender].lastBalance = uint128(goopBalance(msg.sender) + goopAmount);
            getStakingDataForUser[msg.sender].lastTimestamp = uint64(block.timestamp);
        }
    }

    /// @notice Remove goop from a gobbler.
    function removeGoop(uint256 goopAmount) public {
        // Will revert due to underflow if removed amount is larger than the user's current goop balance.
        getStakingDataForUser[msg.sender].lastBalance = uint128(goopBalance(msg.sender) - goopAmount);
        getStakingDataForUser[msg.sender].lastTimestamp = uint64(block.timestamp);

        goop.mint(msg.sender, goopAmount);
    }

    /*//////////////////////////////////////////////////////////////
                       ERC721 TRANSFER HOOK LOGIC
    //////////////////////////////////////////////////////////////*/

    function afterTransfer(
        address from,
        address to,
        uint256 id
    ) internal override {
        // TODO: account for address(0)?

        uint64 idMultiple = getAttributesForGobbler[id].stakingMultiple;

        // TODO: uh what do we do about multiple being 0 right after mint... do we need to reassign after shuffle

        // TODO: this is not necessarily safe cuz sum could exceed 64, lets check dave's spreadsheet ensures not possible
        unchecked {
            getStakingDataForUser[from].lastBalance = uint128(goopBalance(from));
            getStakingDataForUser[from].lastTimestamp = uint64(block.timestamp);
            getStakingDataForUser[from].multiple -= idMultiple;

            getStakingDataForUser[to].lastBalance = uint128(goopBalance(from));
            getStakingDataForUser[to].lastTimestamp = uint64(block.timestamp);
            getStakingDataForUser[to].multiple += idMultiple;
        }
    }
}
