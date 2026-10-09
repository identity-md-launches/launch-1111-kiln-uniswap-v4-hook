// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

interface IPepeolithic {
    function balanceOf(address wallet) external view returns (uint256);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @notice Immutable ETH/ZTO fee pass and reserve-funded Pepeolithic market.
/// @dev Only before/after swap callbacks exist; liquidity is unrestricted.
contract Kiln is IUnlockCallback {
    using SafeCast for uint256;

    uint8 public constant ZTO_DECIMALS = 18;
    uint24 public constant lpFee = 2000;
    int24 public constant tickSpacing = 60;
    uint256 public constant spreadBps = 1500;
    uint256 public constant depth = 50;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    IERC20Minimal public immutable zto;
    IPepeolithic public immutable pepeo;
    IPoolManager public immutable poolManager;

    uint256 public claims;
    uint256 public reserve;
    uint256[] private _inventory;
    mapping(uint256 id => uint256 indexPlusOne) private _index;

    error InvalidAddress();
    error OnlyPoolManager();
    error WrongPool();
    error PartialSpecifiedSwap();
    error InvalidSwapAmount();
    error ZeroBid();
    error AlreadyInInventory();
    error NotInInventory();
    error ZTOTransferFailed();

    event Passed(address indexed trader, uint256 pepes, uint24 kilnCut, uint256 ztoTaken);
    event Collected(uint256 amount);
    event Sold(uint256 indexed id, address indexed seller, uint256 price);
    event Bought(uint256 indexed id, address indexed buyer, uint256 price);
    event Seeded(address indexed from, uint256 amount);

    /// @dev No external calls or address-bit validation: Launcher validates after CREATE2.
    constructor(address zto_, address pepeo_, address poolManager_) {
        if (zto_ == address(0) || pepeo_ == address(0) || poolManager_ == address(0)) revert InvalidAddress();
        zto = IERC20Minimal(zto_);
        pepeo = IPepeolithic(pepeo_);
        poolManager = IPoolManager(poolManager_);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function poolKey() public view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(zto)), lpFee, tickSpacing, IHooks(address(this)));
    }

    function tierOf(address wallet) public view returns (uint24 kilnCut) {
        return _tier(pepeo.balanceOf(wallet));
    }

    function _tier(uint256 pepes) private pure returns (uint24) {
        if (pepes >= 21) return 0;
        if (pepes >= 4) return 3000;
        if (pepes >= 1) return 8000;
        return 13000;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(zto)
                || key.fee != lpFee || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert WrongPool();
    }

    /// @dev ZTO is specified for ZTO exact-input and ETH exact-output swaps.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (params.amountSpecified == type(int256).min) revert InvalidSwapAmount();
        bool exactInput = params.amountSpecified < 0;
        uint256 fee;
        if (params.zeroForOne != exactInput) {
            uint24 rate = tierOf(tx.origin);
            uint256 amount = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
            // Exact-output requests specify net ZTO. Gross up so output minus cut remains exact.
            fee = FullMath.mulDiv(amount, rate, exactInput ? FEE_DENOMINATOR : FEE_DENOMINATOR - rate);
            _mintCut(fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        uint256 pepes = pepeo.balanceOf(tx.origin);
        uint24 rate = _tier(pepes);
        bool exactInput = params.amountSpecified < 0;
        uint256 fee;
        int128 returned;
        if (params.zeroForOne != exactInput) {
            uint256 amount = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
            fee = FullMath.mulDiv(amount, rate, exactInput ? FEE_DENOMINATOR : FEE_DENOMINATOR - rate);
            // A beforeSwap specified delta cannot be refunded by afterSwap (which is unspecified).
            // Reject partial fills with a nonzero specified cut instead of charging for unfilled volume.
            if (fee != 0 && int256(delta.amount1()) != params.amountSpecified + int256(fee)) {
                revert PartialSpecifiedSwap();
            }
        } else {
            int256 ztoDelta = int256(delta.amount1());
            uint256 amount = uint256(ztoDelta < 0 ? -ztoDelta : ztoDelta);
            // For ZTO exact-output input, amount excludes the cut: gross up total ZTO paid.
            fee = FullMath.mulDiv(amount, rate, exactInput ? FEE_DENOMINATOR : FEE_DENOMINATOR - rate);
            returned = fee.toInt128();
            _mintCut(fee);
        }
        emit Passed(tx.origin, pepes, rate, fee);
        return (IHooks.afterSwap.selector, returned);
    }

    function _mintCut(uint256 amount) private {
        if (amount == 0) return;
        claims += amount;
        // Mint offsets the positive hook return delta without requiring real tokens before router settlement.
        poolManager.mint(address(this), uint256(uint160(address(zto))), amount);
    }

    /// @notice Redeem every ZTO claim, including claims donated directly to this contract.
    /// @dev With outstanding claims this must be called outside an existing manager unlock.
    function collect() public {
        if (poolManager.balanceOf(address(this), uint256(uint160(address(zto)))) == 0) {
            emit Collected(0);
            return;
        }
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 id = uint256(uint160(address(zto)));
        uint256 amount = poolManager.balanceOf(address(this), id);
        claims = 0;
        reserve += amount;
        emit Collected(amount);
        poolManager.burn(address(this), id, amount);
        poolManager.take(Currency.wrap(address(zto)), address(this), amount);
        return "";
    }

    function bid() public view returns (uint256) {
        return reserve / depth;
    }

    function ask() public view returns (uint256) {
        return FullMath.mulDiv(bid(), 10_000 + spreadBps, 10_000);
    }

    function inventory() external view returns (uint256[] memory) {
        return _inventory;
    }

    function inInventory(uint256 id) public view returns (bool) {
        return _index[id] != 0;
    }

    function sell(uint256 id) external {
        collect();
        uint256 price = bid();
        if (price == 0) revert ZeroBid();
        if (inInventory(id)) revert AlreadyInInventory();
        reserve -= price;
        _inventory.push(id);
        _index[id] = _inventory.length;
        emit Sold(id, msg.sender, price);
        pepeo.transferFrom(msg.sender, address(this), id);
        if (!zto.transfer(msg.sender, price)) revert ZTOTransferFailed();
    }

    function buy(uint256 id) external {
        collect();
        uint256 index = _index[id];
        if (index == 0) revert NotInInventory();
        uint256 price = ask();
        // ask() is zero exactly when bid() is zero (reserve below depth): mirror sell().
        if (price == 0) revert ZeroBid();
        uint256 lastId = _inventory[_inventory.length - 1];
        _inventory[index - 1] = lastId;
        _index[lastId] = index;
        _inventory.pop();
        delete _index[id];
        reserve += price;
        emit Bought(id, msg.sender, price);
        if (!zto.transferFrom(msg.sender, address(this), price)) revert ZTOTransferFailed();
        pepeo.transferFrom(address(this), msg.sender, id);
    }

    function seed(uint256 amount) external {
        reserve += amount;
        emit Seeded(msg.sender, amount);
        if (!zto.transferFrom(msg.sender, address(this), amount)) revert ZTOTransferFailed();
    }
}
