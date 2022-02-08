// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import {ISplitMain} from './interfaces/ISplitMain.sol';
import {SplitWallet} from './SplitWallet.sol';
import {Clones} from './libraries/Clones.sol';
import {ERC20} from '@rari-capital/solmate/src/tokens/ERC20.sol';
import {SafeTransferLib} from '@rari-capital/solmate/src/utils/SafeTransferLib.sol';

/**
                                                    ,s# ## mp
                                                ;# ########### #p
                                           ,s@ ######## B ########  m,
                                       ,s# ####### W2`      l% ######## #p
                                  ,s# ######## K*               |8 ######## #m,
                              ,s# ######## f^                        7  ######## mp
                          ;# ######## b|                                 |8 #######
                     ,s  ######## b|                                   ,s  #########
                 ,m# ####### 8T`                                   ;# ##############
            ,;# ######## B7                                   ,s  ######## K7  @####
        ,s# ######## T"                                   ,s  ######## T^      @####
    ,# ######## W|                                    ;# ######## W2           @####
    #########p                                   ,s  ######## B\               @####
    ########### #p                           ,## ##########"                   @####
    ###### ########  m,                 ,;# ######## B@####                    @####
    #####   ^l ######### Qp         ,s# ######## b^   @####                    @####
    #####        |8 ######## #m,;# ######## 8|        @####                    @####
    #####            |8 ############### T|            @####                    @####
    #####                '3  ######## mp              @####                    @####
    #####                     |8 ######## #m,         @####                    @####
    #####                          j  ######## m,     @####                    @####
    #####                              |8 ######## #p @####                    @####
    #####                                  ^7 #############                    @####
    ##### Qp                                    |Y ########                    @####
    %######## #p,                                   |8@####                    @####
       j  ######## mp                                 @####                    @####
           "Y ######## #p                             @####                    @####
               ^7 ########  m,                        @####                    @####
                    l% ######## #p                    @####                    @####
                        |8 ######## #m,               @####               ,s# ######
                             7  ######## m,           @####           ,s# ######## \
                                 |5 ######## #p       @####       ;# ######## 8\
                                     '7 ########  m,  @####  ,s@ ######## b7
                                          l8 ######## #####  ####### WT`
                                              |8 ############### B|
                                                   7  ###### T"
 */

/**
 * ERRORS
 */

/// @notice Unauthorized sender `sender`
/// @param sender Transaction sender
error Unauthorized(address sender);
/// @notice Invalid number of accounts `accountsLength`, must have at least 2
/// @param accountsLength Length of accounts array
error InvalidSplit__TooFewAccounts(uint256 accountsLength);
/// @notice Array lengths of accounts & percentAllocations don't match (`accountsLength` != `allocationsLength`)
/// @param accountsLength Length of accounts array
/// @param allocationsLength Length of percentAllocations array
error InvalidSplit__AccountsAndAllocationsMismatch(uint256 accountsLength, uint256 allocationsLength);
/// @notice Invalid percentAllocations sum `allocationsSum` must equal `PERCENTAGE_SCALE`
/// @param allocationsSum Sum of percentAllocations array
error InvalidSplit__InvalidAllocationsSum(uint32 allocationsSum);
/// @notice Invalid accounts ordering at `index`
/// @param index Index of out-of-order account
error InvalidSplit__AccountsOutOfOrder(uint256 index);
/// @notice Invalid percentAllocation of zero at `index`
/// @param index Index of zero percentAllocation
error InvalidSplit__AllocationMustBePositive(uint256 index);
/// @notice Invalid distributionFee `distributionFee` cannot be greater than 10% (1e5)
/// @param distributionFee Invalid distributionFee amount
error InvalidSplit__InvalidDistributionFee(uint32 distributionFee);
/// @notice Invalid hash `hash` from split data (accounts, percentAllocations, distributionFee)
/// @param hash Invalid hash
error InvalidSplit__InvalidHash(bytes32 hash);
/// @notice Invalid new controlling address `newController` for mutable split
/// @param newController Invalid new controller
error InvalidNewController(address newController);

/**
 * @title SplitMain
 * @author 0xSplits <will@0xSplits.xyz>
 * @notice A composable and gas-efficient protocol for deploying splitter contracts.
 * @dev Split recipients, ownerships, and keeper fees are stored onchain as calldata & re-passed as args / validated
 * via hashing when needed. Each split gets its own address & proxy for maximum composability with other contracts onchain.
 * For these proxies, we extended EIP-1167 Minimal Proxy Contract to avoid `DELEGATECALL` inside `receive()` to accept
 * hard gas-capped `sends` & `transfers`.
 */
contract SplitMain is ISplitMain {
    using SafeTransferLib for address;
    using SafeTransferLib for ERC20;

    /**
     * STRUCTS
     */

    /// @notice holds Split metadata
    struct Split {
        bytes32 hash;
        address controller;
        address newPotentialController;
    }

    /**
     * STORAGE
     */

    /**
     * STORAGE - CONSTANTS & IMMUTABLES
     */

    /// @notice constant to scale uints into percentages (1e6 == 100%)
    uint256 public constant PERCENTAGE_SCALE = 1e6;
    /// @notice maximum distribution fee; 1e5 = 10% * PERCENTAGE_SCALE
    uint256 internal constant MAX_DISTRIBUTION_FEE = 1e5;
    /// @notice address of wallet implementation for split proxies
    address public immutable override walletImplementation;

    /**
     * STORAGE - VARIABLES - PRIVATE & INTERNAL
     */

    /// @notice mapping to account ETH balances
    mapping(address => uint256) internal ethBalances;
    /// @notice mapping to account ERC20 balances
    mapping(ERC20 => mapping(address => uint256)) internal erc20Balances;
    /// @notice mapping to Split metadata
    mapping(address => Split) internal splits;

    /**
     * MODIFIERS
     */

    /** @notice Reverts if the sender doesn't own the split `split`
     *  @param split Address to check for control
     */
    modifier onlySplitController(address split) {
        if (msg.sender != splits[split].controller) revert Unauthorized(msg.sender);
        _;
    }

    /** @notice Reverts if the sender isn't the new potential controller of split `split`
     *  @param split Address to check for new potential control
     */
    modifier onlySplitNewPotentialController(address split) {
        if (msg.sender != splits[split].newPotentialController) revert Unauthorized(msg.sender);
        _;
    }

    /** @notice Reverts if the split with recipients represented by `accounts` and `percentAllocations` is malformed
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     */
    modifier validSplit(
        address[] memory accounts,
        uint32[] memory percentAllocations,
        uint32 distributionFee
    ) {
        if (accounts.length < 2) revert InvalidSplit__TooFewAccounts(accounts.length);
        if (accounts.length != percentAllocations.length)
            revert InvalidSplit__AccountsAndAllocationsMismatch(accounts.length, percentAllocations.length);
        // _getSum should overflow if any percentAllocation[i] < 0
        if (_getSum(percentAllocations) != PERCENTAGE_SCALE)
            revert InvalidSplit__InvalidAllocationsSum(_getSum(percentAllocations));
        unchecked {
            // overflow should be impossible in for-loop index
            // cache accounts length to save gas
            uint256 loopLength = accounts.length - 1;
            for (uint256 i = 0; i < loopLength; i++) {
                // overflow should be impossible in array access math
                if (accounts[i] >= accounts[i + 1]) revert InvalidSplit__AccountsOutOfOrder(i);
                if (percentAllocations[i] == uint32(0)) revert InvalidSplit__AllocationMustBePositive(i);
            }
            // overflow should be impossible in array access math with validated equal array lengths
            if (percentAllocations[loopLength] == uint32(0)) revert InvalidSplit__AllocationMustBePositive(loopLength);
        }
        if (distributionFee > MAX_DISTRIBUTION_FEE) revert InvalidSplit__InvalidDistributionFee(distributionFee);
        _;
    }

    /** @notice Reverts if `newController` is the zero address
     *  @param newController Proposed new controlling address
     */
    modifier validNewController(address newController) {
        if (newController == address(0)) revert InvalidNewController(newController);
        _;
    }

    /**
     * CONSTRUCTOR
     */

    constructor() {
        walletImplementation = address(new SplitWallet());
    }

    /**
     * FUNCTIONS
     */

    /**
     * FUNCTIONS - PUBLIC & EXTERNAL
     */

    /** @notice Receive ETH
     *  @dev Used by split proxies in `distributeETH` to transfer ETH to `SplitMain`
     *  Funds sent outside of `distributeETH` will be unrecoverable
     */
    receive() external payable {}

    /** @notice Creates a new split with recipients `accounts` with ownerships `percentAllocations`, a keeper fee for splitting of `distributionFee` and the controlling address `controller`
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     *  @param controller Controlling address (0x0 if immutable)
     *  @return split Address of newly created split
     */
    function createSplit(
        address[] calldata accounts,
        uint32[] calldata percentAllocations,
        uint32 distributionFee,
        address controller
    ) external override validSplit(accounts, percentAllocations, distributionFee) returns (address split) {
        bytes32 splitHash = _hashSplit(accounts, percentAllocations, distributionFee);
        if (controller == address(0)) {
            // create immutable split
            split = Clones.cloneDeterministic(walletImplementation, splitHash);
        } else {
            // create mutable split
            split = Clones.clone(walletImplementation);
            splits[split].controller = controller;
        }
        // store split's hash in storage for future verification
        splits[split].hash = splitHash;
        emit CreateSplit(split);
    }

    /** @notice Predicts the address for an immutable split created with recipients `accounts` with ownerships `percentAllocations` and a keeper fee for splitting of `distributionFee`
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     *  @return split Predicted address of such an immutable split
     */
    function predictImmutableSplitAddress(
        address[] calldata accounts,
        uint32[] calldata percentAllocations,
        uint32 distributionFee
    ) external view override validSplit(accounts, percentAllocations, distributionFee) returns (address split) {
        bytes32 splitHash = _hashSplit(accounts, percentAllocations, distributionFee);
        split = Clones.predictDeterministicAddress(walletImplementation, splitHash);
    }

    /** @notice Updates an existing split with recipients `accounts` with ownerships `percentAllocations` and a keeper fee for splitting of `distributionFee`
     *  @param split Address of mutable split to update
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     */
    function updateSplit(
        address split,
        address[] calldata accounts,
        uint32[] calldata percentAllocations,
        uint32 distributionFee
    ) external override onlySplitController(split) validSplit(accounts, percentAllocations, distributionFee) {
        bytes32 splitHash = _hashSplit(accounts, percentAllocations, distributionFee);
        // store new hash in storage for future verification
        splits[split].hash = splitHash;
        emit UpdateSplit(split);
    }

    /** @notice Begins transfer of the controlling address of mutable split `split` to `newController`
     *  @dev Two-step control transfer inspired by [dharma](https://github.com/dharma-eng/dharma-smart-wallet/blob/master/contracts/helpers/TwoStepOwnable.sol)
     *  @param split Address of mutable split to transfer control for
     *  @param newController Address to begin transferring control to
     */
    function transferControl(address split, address newController)
        external
        override
        onlySplitController(split)
        validNewController(newController)
    {
        splits[split].newPotentialController = newController;
        emit InitiateControlTransfer(split, newController);
    }

    /** @notice Cancels transfer of the controlling address of mutable split `split`
     *  @param split Address of mutable split to cancel control transfer for
     */
    function cancelControlTransfer(address split) external override onlySplitController(split) {
        delete splits[split].newPotentialController;
        emit CancelControlTransfer(split);
    }

    /** @notice Accepts transfer of the controlling address of mutable split `split`
     *  @param split Address of mutable split to accept control transfer for
     */
    function acceptControl(address split) external override onlySplitNewPotentialController(split) {
        delete splits[split].newPotentialController;
        emit ControlTransfer(split, splits[split].controller, msg.sender);
        splits[split].controller = msg.sender;
    }

    /** @notice Turns mutable split `split` immutable
     *  @param split Address of mutable split to turn immutable
     */
    function makeSplitImmutable(address split) external override onlySplitController(split) {
        delete splits[split].newPotentialController;
        emit ControlTransfer(split, splits[split].controller, address(0));
        splits[split].controller = address(0);
    }

    /** @notice Distributes the ETH balance for split `split`
     *  @dev `accounts`, `percentAllocations`, and `distributionFee` are verified by hashing
     *  & comparing to the hash in storage associated with split `split`
     *  @param split Address of split to distribute balance for
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     *  @param distributionAddress Address to pay `distributionFee` to
     */
    function distributeETH(
        address split,
        address[] memory accounts,
        uint32[] memory percentAllocations,
        uint32 distributionFee,
        address distributionAddress
    ) external override validSplit(accounts, percentAllocations, distributionFee) {
        // use internal fn instead of modifier to avoid stack depth compiler errors
        _validSplitHash(split, accounts, percentAllocations, distributionFee);
        uint256 mainBalance = ethBalances[split];
        uint256 proxyBalance = split.balance;
        // leave balance of 1 in SplitMain for gas efficiency
        // underflow if mainBalance + proxyBalance = 0 (no funds to split)
        uint256 amountToSplit = mainBalance + proxyBalance - 1;
        if (mainBalance != 1) ethBalances[split] = 1;
        // emit event with gross amountToSplit (before deducting distributionFee)
        emit DistributeETH(split, amountToSplit, distributionAddress);
        if (distributionFee != 0) {
            // given `amountToSplit`, calculate keeper fee
            uint256 distributionFeeAmount = _scaleAmountByPercentage(amountToSplit, distributionFee);
            unchecked {
                // credit keeper with fee
                // overflow should be impossible with validated distributionFee
                ethBalances[
                    distributionAddress != address(0) ? distributionAddress : msg.sender
                ] += distributionFeeAmount;
                // given keeper fee, calculate how much to distribute to split recipients
                // underflow should be impossible with validated distributionFee
                amountToSplit -= distributionFeeAmount;
            }
        }
        unchecked {
            // distribute remaining balance
            // overflow should be impossible in for-loop index
            // cache accounts length to save gas
            uint256 accountsLength = accounts.length;
            for (uint256 i = 0; i < accountsLength; i++) {
                // overflow should be impossible with validated allocations
                ethBalances[accounts[i]] += _scaleAmountByPercentage(amountToSplit, percentAllocations[i]);
            }
        }
        // flush proxy ETH balance to SplitMain
        // split proxy should be guaranteed to exist at this address after validating splitHash
        // (attacker can't deploy own contract to address with high balance & empty sendETHToMain
        // to drain ETH from SplitMain)
        // could technically check if (change in proxy balance == change in SplitMain balance)
        // before/after external call, but seems like extra gas for no practical benefit
        if (proxyBalance > 0) SplitWallet(split).sendETHToMain(proxyBalance);
    }

    /** @notice Distributes the ERC20 `token` balance for split `split`
     *  @dev `accounts`, `percentAllocations`, and `distributionFee` are verified by hashing
     *  & comparing to the hash in storage associated with split `split`
     *  @dev pernicious ERC20s may cause overflow in this function inside
     *  _scaleAmountByPercentage, but results do not affect ETH & other ERC20 balances
     *  @param split Address of split to distribute balance for
     *  @param token Address of ERC20 to distribute balance for
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     *  @param distributionAddress Address to pay `distributionFee` to
     */
    function distributeERC20(
        address split,
        ERC20 token,
        address[] memory accounts,
        uint32[] memory percentAllocations,
        uint32 distributionFee,
        address distributionAddress
    ) external override validSplit(accounts, percentAllocations, distributionFee) {
        // use internal fn instead of modifier to avoid stack depth compiler errors
        _validSplitHash(split, accounts, percentAllocations, distributionFee);
        uint256 amountToSplit;
        uint256 mainBalance = erc20Balances[token][split];
        uint256 proxyBalance = token.balanceOf(split);
        if (proxyBalance > 1) {
            unchecked {
                // leave balance of 1 in ERC20 for gas efficiency
                // leave balances of 1 in SplitMain for gas efficiency
                // overflow impossible with proxyBalance >= 2
                amountToSplit = mainBalance + proxyBalance - 2;
            }
        } else {
            // leave balances of 1 in SplitMain for gas efficiency
            // underflow if erc20Balance is 0 & proxyBalance is 0 or 1 (no funds to split)
            amountToSplit = mainBalance - 1;
        }
        // leave balance of 1 for gas efficiency
        if (mainBalance != 1) erc20Balances[token][split] = 1;
        // emit event with gross amountToSplit (before deducting distributionFee)
        emit DistributeERC20(split, token, amountToSplit, distributionAddress);
        if (distributionFee != 0) {
            // given `amountToSplit`, calculate keeper fee
            uint256 distributionFeeAmount = _scaleAmountByPercentage(amountToSplit, distributionFee);
            // overflow should be impossible with validated distributionFee
            unchecked {
                // credit keeper with fee
                erc20Balances[token][
                    distributionAddress != address(0) ? distributionAddress : msg.sender
                ] += distributionFeeAmount;
                // given keeper fee, calculate how much to distribute to split recipients
                amountToSplit -= distributionFeeAmount;
            }
        }
        // distribute remaining balance
        // overflows should be impossible in for-loop with validated allocations
        unchecked {
            // cache accounts length to save gas
            uint256 accountsLength = accounts.length;
            for (uint256 i = 0; i < accountsLength; i++) {
                erc20Balances[token][accounts[i]] += _scaleAmountByPercentage(amountToSplit, percentAllocations[i]);
            }
        }
        // split proxy should be guaranteed to exist at this address after validating splitHash
        // (attacker can't deploy own contract to address with high ERC20 balance & empty
        // sendERC20ToMain to drain ERC20 from SplitMain)
        // could technically check if (change in proxy ERC20 balance == change in splitmain
        // ERC20 balance) before/after external call, but seems like extra gas for no practical benefit
        unchecked {
            // flush proxy ERC20 balance to SplitMain
            // leave balance of 1 in ERC20 for gas efficiency
            // overflow is impossible in proxyBalance math
            if (proxyBalance > 1) SplitWallet(split).sendERC20ToMain(token, proxyBalance - 1);
        }
    }

    /** @notice Withdraw ETH &/ ERC20 balances for account `account`
     *  @param account Address to withdraw on behalf of
     *  @param eth Bool of whether to withdraw ETH
     *  @param tokens Addresses of ERC20s to withdraw for
     */
    function withdraw(
        address account,
        bool eth,
        ERC20[] calldata tokens
    ) external override {
        uint256 ethUint = eth ? 1 : 0;
        unchecked {
            // overflow should be impossible in array length math
            uint256[] memory withdrawnAmounts = new uint256[](ethUint + tokens.length);
            if (eth) {
                withdrawnAmounts[0] = _withdraw(account);
            }
            // overflow should be impossible in for-loop index
            for (uint256 i = 0; i < tokens.length; i++) {
                // overflow should be impossible in array length math
                withdrawnAmounts[ethUint + i] = _withdrawERC20(account, tokens[i]);
            }
            emit Withdrawal(account, eth, tokens, withdrawnAmounts);
        }
    }

    /**
     * FUNCTIONS - VIEWS
     */

    /** @notice Returns the current hash of split `split`
     *  @param split Split to return hash for
     *  @return Split's hash
     */
    function getHash(address split) external view returns (bytes32) {
        return splits[split].hash;
    }

    /** @notice Returns the current controller of split `split`
     *  @param split Split to return controller for
     *  @return Split's controller
     */
    function getController(address split) external view returns (address) {
        return splits[split].controller;
    }

    /** @notice Returns the current newPotentialController of split `split`
     *  @param split Split to return newPotentialController for
     *  @return Split's newPotentialController
     */
    function getNewPotentialController(address split) external view returns (address) {
        return splits[split].newPotentialController;
    }

    /** @notice Returns the current ETH balance of account `account`
     *  @param account Account to return ETH balance for
     *  @return Account's balance of ETH
     */
    function getETHBalance(address account) external view returns (uint256) {
        return ethBalances[account];
    }

    /** @notice Returns the ERC20 balance of token `token` for account `account`
     *  @param account Account to return ERC20 `token` balance for
     *  @param token Token to return balance for
     *  @return Account's balance of `token`
     */
    function getERC20Balance(address account, ERC20 token) external view returns (uint256) {
        return erc20Balances[token][account];
    }

    /**
     * FUNCTIONS - PRIVATE & INTERNAL
     */

    /** @notice Sums array of uint32s
     *  @param numbers Array of uint32s to sum
     *  @return sum Sum of `numbers`.
     */
    function _getSum(uint32[] memory numbers) internal pure returns (uint32 sum) {
        // overflow should be impossible in for-loop index
        uint256 numbersLength = numbers.length;
        for (uint256 i = 0; i < numbersLength; ) {
            sum += numbers[i];
            unchecked {
                // overflow should be impossible in for-loop index
                i++;
            }
        }
    }

    /** @notice Hashes a split
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     *  @return computedHash Hash of the split.
     */
    function _hashSplit(
        address[] memory accounts,
        uint32[] memory percentAllocations,
        uint32 distributionFee
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(accounts, percentAllocations, distributionFee));
    }

    /** @notice Checks hash from `accounts`, `percentAllocations`, and `distributionFee` against the hash stored for `split`
     *  @param split Address of hash to check
     *  @param accounts Ordered, unique list of addresses with ownership in the split
     *  @param percentAllocations Percent allocations associated with each address
     *  @param distributionFee Keeper fee paid by split to cover gas costs of distribution
     */
    function _validSplitHash(
        address split,
        address[] memory accounts,
        uint32[] memory percentAllocations,
        uint32 distributionFee
    ) internal view {
        bytes32 hash = _hashSplit(accounts, percentAllocations, distributionFee);
        if (splits[split].hash != hash) revert InvalidSplit__InvalidHash(hash);
    }

    /** @notice Multiplies an amount by a scaled percentage
     *  @param amount Amount to get `scaledPercentage` of
     *  @param scaledPercent Percent scaled by PERCENTAGE_SCALE
     *  @return scaledAmount Percent of `amount`.
     */
    function _scaleAmountByPercentage(uint256 amount, uint256 scaledPercent)
        internal
        pure
        returns (uint256 scaledAmount)
    {
        // use assembly to bypass checking for overflow & division by 0
        // scaledPercent has been validated to be < PERCENTAGE_SCALE)
        // & PERCENTAGE_SCALE will never be 0
        // pernicious ERC20s may cause overflow, but results do not affect ETH & other ERC20 balances
        assembly {
            /* eg (100 * 2*1e4) / (1e6) */
            scaledAmount := div(mul(amount, scaledPercent), PERCENTAGE_SCALE)
        }
    }

    /** @notice Withdraw ETH for account `account`
     *  @param account Account to withdrawn ETH for
     *  @return withdrawn Amount of ETH withdrawn
     */
    function _withdraw(address account) internal returns (uint256 withdrawn) {
        // leave balance of 1 for gas efficiency
        // underflow is ethBalance is 0
        withdrawn = ethBalances[account] - 1;
        ethBalances[account] = 1;
        account.safeTransferETH(withdrawn);
    }

    /** @notice Withdraw ERC20 `token` for account `account`
     *  @param account Account to withdrawn ERC20 `token` for
     *  @return withdrawn Amount of ERC20 `token` withdrawn
     */
    function _withdrawERC20(address account, ERC20 token) internal returns (uint256 withdrawn) {
        // leave balance of 1 for gas efficiency
        // underflow is erc20Balance is 0
        withdrawn = erc20Balances[token][account] - 1;
        erc20Balances[token][account] = 1;
        token.safeTransfer(account, withdrawn);
    }
}
