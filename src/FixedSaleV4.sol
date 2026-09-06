// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ---- v4-core (verificato e testato su commit 59d3ecf, pinnato da Uniswap/liquidity-launcher) ----
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ---- v4-periphery (commit ad04c9f): percorso POSM ufficiale ----
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice ERC-20 standard + burn. Nessuna tax, nessun mint post-deploy.
contract LaunchToken is ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_) {
        _mint(msg.sender, supply_);
    }
}

/// @title FixedSaleV4 (REV 7)
///
/// @dev TRUST BOUNDARIES — tesi per l'audit:
///  [CUSTOM] FixedSale -> PoolManager: SOLO la normalizzazione condizionale
///           del prezzo (unlockCallback, ~30 righe). Nessun'altra contabilita'
///           delta manuale esiste nel contratto.
///  [POSM]   FixedSale -> PositionManager: creazione posizione e raccolta fee
///           seguono il percorso ufficiale (modifyLiquidities con actions
///           standard), che gestisce internamente settle/take.
///  Il codice upstream (v4-core 59d3ecf, v4-periphery ad04c9f) e' una
///  DIPENDENZA, non un merito: il glue code qui presente e' custom e va
///  auditato come tale. Nessuna proprieta' di sicurezza e' rivendicata per
///  derivazione.
///
/// @dev VERIFICA (passata 2): compilato con solc 0.8.26 via-ir contro i
///  commit sopra; 7 test d'integrazione + fuzz 600 run PASS contro
///  PoolManager e PositionManager reali deployati in-test (lifecycle,
///  H-1 free-move e liquidita' ostile, I13 regression, refund, collect,
///  I11 grace, rounding del mint).
///
/// @dev INVARIANTI:
///  I1  !finalized: balance >= feesAccrued + ethForLiquidity
///      finalized:  balance >= feesAccrued (+ dust fino allo sweep)
///  I2  token.balanceOf(this) >= somma(purchased outstanding) == totalSold
///  I3  totalSold <= saleSupply
///  I4  finalized => totalSold al finalize >= softCapTokens
///  I5  feesAccrued + ethForLiquidity == somma(contributed) outstanding
///  I6  token immessi in LP <= liquidityReserve
///  I7  sqrtPriceX96 == target immediatamente prima del mint POSM
///  I8  tick == targetTick immediatamente prima del mint POSM
///  I9  bootstrapLiquidity mai ridotta: unica DECREASE_LIQUIDITY nel
///      bytecode con liquidity = 0; nessun transfer/approve dell'NFT
///  I10 controparti: POOL_MANAGER (normalizzazione) e POSITION_MANAGER
///      (posizione), entrambi immutabili; PoolKey immutabile
///  I11 liveness: dopo saleDeadline + FINALIZE_GRACE almeno uno tra
///      finalize() e refund() e' sempre eseguibile
///  I12 post-finalize: totalSupply == escrow claimabile + LP (burn reale)
///  I13 (statico) TICK_LOWER/TICK_UPPER insaturabili — verificato on-chain
///      con SqrtPriceMath: upper > 1e25 wei ETH; lower > 10x MAX_TOTAL_SUPPLY
///      in token; il vecchio full-range era attaccabile con < 1e13 wei
///
/// @dev Nessun owner, nessun admin, nessuna pause, nessun upgrade.
contract FixedSaleV4 is ReentrancyGuard, IUnlockCallback, IERC721Receiver {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------- errori ----------
    error BadParams();
    error ZeroAddress();
    error SupplyTooLarge();
    error TargetOutOfRange();
    error ManagerMismatch();
    error SaleClosed();
    error SaleExpired();
    error SaleStillActive();
    error ZeroEth();
    error SoldOutError();
    error CapNotReached();
    error AmountTooSmall();
    error NothingToClaim();
    error NothingToRefund();
    error AwaitMigration();
    error EthTransferFailed();
    error NotPoolManager();
    error NotPositionManager();
    error PriceNotAtTarget(); // I7
    error TickNotAtTarget(); // I8
    error FinalizeWindowOpen();
    error DirectEthNotAccepted();
    error NoDust();

    // ---------- costanti ----------
    uint256 public constant FEE_BPS = 1000; // 10% sulla vendita
    uint256 public constant BPS = 10_000;
    uint24 public constant POOL_FEE = 3000; // 0,30% sul pool
    int24 public constant TICK_SPACING = 60;
    uint256 public constant FINALIZE_GRACE = 3 days; // I11

    /// @dev I13: range largo ma bounded, allineato a spacing 60
    ///      (-160140 = -2669*60; 251340 = 4189*60). Copertura prezzo
    ///      ~1.1e-7x .. ~8e10x dal target: full-range economico.
    int24 public constant TICK_LOWER = -160_140;
    int24 public constant TICK_UPPER = 251_340;

    /// @dev I13: il bound inferiore e' sicuro solo sotto questo cap.
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000_000e18;

    // ---------- immutabili ----------
    LaunchToken public immutable token;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    address public immutable feeRecipient;
    uint256 public immutable pricePerToken; // wei per 1e18 unita' di token
    uint256 public immutable saleSupply;
    uint256 public immutable softCapTokens;
    uint256 public immutable liquidityReserve;
    uint256 public immutable saleDeadline;
    uint160 public immutable targetSqrtPriceX96;
    int24 public immutable targetTick;
    Currency internal immutable currency0; // ETH nativo (address(0))
    Currency internal immutable currency1; // token
    PoolId public immutable poolId;

    // ---------- stato ----------
    uint256 public totalSold;
    uint256 public ethForLiquidity;
    uint256 public feesAccrued;
    bool public finalized;
    uint256 public bootstrapTokenId; // NFT POSM della posizione (I9)
    uint128 public bootstrapLiquidity; // I9
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public contributed; // ETH lordo (fee inclusa)
    mapping(address => uint256) public feePaid; // fee esatta per-utente

    event Bought(address indexed buyer, uint256 tokensOut, uint256 ethSpent, uint256 fee);
    event Normalized(uint160 fromSqrtPriceX96, int256 ethDelta, int256 tokenDelta);
    event Finalized(PoolId indexed poolId, uint256 indexed tokenId, uint128 liquidity, uint256 burned);
    event PoolFeesCollected(uint256 ethAmount, uint256 tokenAmount);
    event DustSwept(uint256 ethDust);
    event Claimed(address indexed buyer, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event FeesWithdrawn(uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 saleSupply_,
        uint256 pricePerToken_,
        uint256 saleDuration_,
        uint256 softCapBps_,
        address feeRecipient_,
        address poolManager_,
        address positionManager_
    ) {
        if (saleSupply_ == 0 || pricePerToken_ == 0 || saleDuration_ == 0) revert BadParams();
        if (softCapBps_ == 0 || softCapBps_ > BPS) revert BadParams();
        if (feeRecipient_ == address(0) || poolManager_ == address(0) || positionManager_ == address(0)) {
            revert ZeroAddress();
        }
        // Un PositionManager legato a un PoolManager diverso renderebbe
        // migrazione e fee irrecuperabili (pattern InstantLaunchStrategy).
        if (address(IPositionManager(positionManager_).poolManager()) != poolManager_) {
            revert ManagerMismatch();
        }

        saleSupply = saleSupply_;
        pricePerToken = pricePerToken_;
        saleDeadline = block.timestamp + saleDuration_;
        softCapTokens = (saleSupply_ * softCapBps_) / BPS;
        feeRecipient = feeRecipient_;
        poolManager = IPoolManager(poolManager_);
        positionManager = IPositionManager(positionManager_);

        liquidityReserve = (saleSupply_ * (BPS - FEE_BPS)) / BPS;
        if (saleSupply_ + liquidityReserve > MAX_TOTAL_SUPPLY) revert SupplyTooLarge(); // I13
        token = new LaunchToken(name_, symbol_, saleSupply_ + liquidityReserve);

        // sqrtPriceX96 = sqrt(price(token/ETH) * 2^192); 1e18<<192 ~ 2^252
        uint256 sp = Math.sqrt((1e18 << 192) / pricePerToken_);
        if (sp < TickMath.MIN_SQRT_PRICE || sp >= TickMath.MAX_SQRT_PRICE) revert BadParams();
        targetSqrtPriceX96 = uint160(sp);
        targetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
        // Strettamente interno: sul bordo la posizione sarebbe single-sided.
        if (targetTick <= TICK_LOWER || targetTick >= TICK_UPPER) revert TargetOutOfRange();

        currency0 = Currency.wrap(address(0)); // sempre < token: ordine fisso
        currency1 = Currency.wrap(address(token));
        PoolKey memory key = _poolKey();
        poolId = key.toId();

        // Inizializzazione atomica col deploy: zero front-running.
        poolManager.initialize(key, targetSqrtPriceX96);
    }

    /// @dev ETH in ingresso post-vendita: take della normalizzazione (dal
    ///      PoolManager) e TAKE_PAIR del surplus mint (eseguito da POSM).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(positionManager)) {
            revert DirectEthNotAccepted();
        }
    }

    /// @dev La posizione viene mintata a questo contratto; accetta solo NFT
    ///      dal PositionManager.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ---------------- fase A: vendita ----------------

    function buy() external payable nonReentrant {
        // checks
        if (finalized) revert SaleClosed();
        if (block.timestamp >= saleDeadline) revert SaleExpired();
        if (msg.value == 0) revert ZeroEth();
        uint256 remaining = saleSupply - totalSold;
        if (remaining == 0) revert SoldOutError();

        uint256 tokensOut = (msg.value * 1e18) / pricePerToken;
        uint256 spend = msg.value;
        if (tokensOut > remaining) {
            tokensOut = remaining;
            spend = (tokensOut * pricePerToken) / 1e18;
        }
        if (tokensOut == 0) revert AmountTooSmall();

        // effects
        uint256 fee = (spend * FEE_BPS) / BPS;
        feesAccrued += fee;
        ethForLiquidity += spend - fee;
        totalSold += tokensOut;
        purchased[msg.sender] += tokensOut;
        contributed[msg.sender] += spend;
        feePaid[msg.sender] += fee;

        // interactions
        if (msg.value > spend) {
            (bool ok,) = msg.sender.call{value: msg.value - spend}("");
            if (!ok) revert EthTransferFailed();
        }
        emit Bought(msg.sender, tokensOut, spend, fee);
    }

    // ---------------- fase C: migrazione ----------------

    /// @notice Permissionless. Sold out: sempre. Soft cap: solo a deadline.
    /// @dev [CUSTOM unlock #1 solo se necessario] -> assert I7/I8 -> [POSM].
    ///      I due unlock vivono nella stessa tx: nessun attaccante puo'
    ///      inserirsi tra normalizzazione e mint.
    function finalize() external nonReentrant {
        if (finalized) revert SaleClosed();
        bool soldOut = totalSold == saleSupply;
        bool softOk = block.timestamp >= saleDeadline && totalSold >= softCapTokens;
        if (!soldOut && !softOk) revert CapNotReached();
        finalized = true;

        uint256 ethAvail = ethForLiquidity;
        uint256 tokenAvail = liquidityReserve;

        // ---- [CUSTOM] unlock #1: normalizzazione, solo se serve ----
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        if (sqrtP != targetSqrtPriceX96) {
            bytes memory result = poolManager.unlock(abi.encode(ethAvail, tokenAvail));
            (ethAvail, tokenAvail) = abi.decode(result, (uint256, uint256));
        }

        // ---- ASSERT I7 + I8 (whale-grief: revert; refund post-grace, I11) ----
        (uint160 sqrtNow, int24 tickNow,,) = poolManager.getSlot0(poolId);
        if (sqrtNow != targetSqrtPriceX96) revert PriceNotAtTarget();
        if (tickNow != targetTick) revert TickNotAtTarget();

        // ---- [POSM] mint della posizione bounded (I6, I13) ----
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            targetSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            ethAvail,
            tokenAvail
        );

        // Fondi al PositionManager con pattern CONTRACT_BALANCE (identico a
        // InstantLaunchStrategy): niente permit2, niente approve.
        // token e' LaunchToken (OZ ERC20): reverte su fallimento, non ritorna false.
        // slither-disable-next-line unchecked-transfer
        token.transfer(address(positionManager), tokenAvail);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            _poolKey(),
            TICK_LOWER,
            TICK_UPPER,
            liq,
            // ethAvail <= ETH raccolto e tokenAvail <= MAX_TOTAL_SUPPLY (1e27): entrambi << 2^128.
            // aderyn-fp-next-line(unsafe-casting)
            uint128(ethAvail),
            // aderyn-fp-next-line(unsafe-casting)
            uint128(tokenAvail),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(currency1, ActionConstants.CONTRACT_BALANCE, false);
        // Surplus di entrambe le currency torna alla sale per burn/sweep.
        params[3] = abi.encode(currency0, currency1, address(this));

        uint256 tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities{value: ethAvail}(abi.encode(actions, params), block.timestamp);

        bootstrapTokenId = tokenId;
        bootstrapLiquidity = liq; // I9

        // ---- BURN (I12): balance - escrow outstanding, post-settlement ----
        uint256 burnAmount = token.balanceOf(address(this)) - totalSold;
        if (burnAmount > 0) token.burn(burnAmount);

        // ---- SWEEP ETH best-effort (retry: sweepDust) ----
        uint256 ethDust = address(this).balance - feesAccrued;
        if (ethDust > 0) {
            (bool ok,) = feeRecipient.call{value: ethDust}("");
            if (ok) emit DustSwept(ethDust);
        }

        emit Finalized(poolId, tokenId, liq, burnAmount);
    }

    /// @dev [CUSTOM] L'UNICA logica delta manuale del contratto: swap di
    ///      normalizzazione a budget pieno + settlement dei suoi delta.
    ///      Su path vuoto costa ~0; liquidita' ostile viene attraversata
    ///      (l'attaccante compra token sopra listing — verificato in T3).
    ///      Senza nonReentrant, di proposito: il guard e' gia' "entered" da
    ///      finalize(). Solo il PoolManager puo' chiamare, e in V4 la
    ///      callback riceve solo i dati passati da QUESTO contratto a unlock().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 ethAvail, uint256 tokenAvail) = abi.decode(data, (uint256, uint256));

        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        bool zeroForOne = sqrtP > targetSqrtPriceX96;
        BalanceDelta sd = poolManager.swap(
            _poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(ethAvail) : -int256(tokenAvail),
                sqrtPriceLimitX96: targetSqrtPriceX96
            }),
            ""
        );

        int128 d0 = sd.amount0();
        int128 d1 = sd.amount1();
        // Settlement dei soli delta dello swap (pattern 59d3ecf:
        // ETH nativo -> settle{value}; ERC-20 -> sync, transfer, settle).
        if (d0 < 0) poolManager.settle{value: uint256(uint128(-d0))}();
        else if (d0 > 0) poolManager.take(currency0, address(this), uint256(uint128(d0)));
        if (d1 < 0) {
            poolManager.sync(currency1);
            // token e' LaunchToken (OZ ERC20): reverte su fallimento, non ritorna false.
            // slither-disable-next-line unchecked-transfer
            token.transfer(address(poolManager), uint256(uint128(-d1)));
            poolManager.settle();
        } else if (d1 > 0) {
            poolManager.take(currency1, address(this), uint256(uint128(d1)));
        }

        emit Normalized(sqrtP, d0, d1);
        // Budget netti per il mint POSM.
        return abi.encode(uint256(int256(ethAvail) + d0), uint256(int256(tokenAvail) + d1));
    }

    // ---------------- fase E: fee del pool ----------------

    /// @notice [POSM] Raccolta perpetua delle swap fee. Permissionless:
    ///         destinatario hardcoded. DECREASE_LIQUIDITY(0) realizza le
    ///         sole fee maturate senza toccare il principal (I9 — T6
    ///         verifica principal invariato).
    function collectPoolFees() external nonReentrant {
        if (!finalized) revert AwaitMigration();
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(bootstrapTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, feeRecipient);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit PoolFeesCollected(0, 0); // importi esatti dagli eventi POSM/pool
    }

    // ---------------- fase D: claim / refund / fee vendita / dust ----------------

    function claim() external nonReentrant {
        if (!finalized) revert AwaitMigration();
        uint256 amt = purchased[msg.sender];
        if (amt == 0) revert NothingToClaim();
        purchased[msg.sender] = 0;
        // token e' LaunchToken (OZ ERC20): reverte su fallimento, non ritorna false.
        // slither-disable-next-line unchecked-transfer
        token.transfer(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    /// @notice Rimborso integrale (fee inclusa): sotto soft cap a deadline,
    ///         oppure post-grace se finalize non e' avvenuta (I11).
    function refund() external nonReentrant {
        if (finalized) revert SaleClosed();
        if (block.timestamp < saleDeadline) revert SaleStillActive();
        if (totalSold >= softCapTokens && block.timestamp < saleDeadline + FINALIZE_GRACE) {
            revert FinalizeWindowOpen();
        }
        uint256 amtEth = contributed[msg.sender];
        if (amtEth == 0) revert NothingToRefund();
        uint256 fee = feePaid[msg.sender];
        uint256 tok = purchased[msg.sender];

        // effects: ripristino esatto dello stato globale
        contributed[msg.sender] = 0;
        feePaid[msg.sender] = 0;
        purchased[msg.sender] = 0;
        totalSold -= tok;
        feesAccrued -= fee;
        ethForLiquidity -= amtEth - fee;

        // interactions
        (bool ok,) = msg.sender.call{value: amtEth}("");
        if (!ok) revert EthTransferFailed();
        emit Refunded(msg.sender, amtEth);
    }

    /// @notice Fee di vendita (10% in ETH). Pull; bloccata fino a finalized
    ///         a garanzia dei refund.
    function withdrawFees() external nonReentrant {
        if (!finalized) revert AwaitMigration();
        uint256 amt = feesAccrued;
        if (amt == 0) revert NothingToClaim();
        feesAccrued = 0;
        (bool ok,) = feeRecipient.call{value: amt}("");
        if (!ok) revert EthTransferFailed();
        emit FeesWithdrawn(amt);
    }

    /// @notice Retry permissionless dello sweep del dust ETH post-migrazione.
    function sweepDust() external nonReentrant {
        if (!finalized) revert AwaitMigration();
        uint256 dust = address(this).balance - feesAccrued;
        // Uguaglianza stretta su un saldo, usata solo per revertire: nessun branch di valore.
        // slither-disable-next-line incorrect-equality
        if (dust == 0) revert NoDust();
        (bool ok,) = feeRecipient.call{value: dust}("");
        if (!ok) revert EthTransferFailed();
        emit DustSwept(dust);
    }
}
