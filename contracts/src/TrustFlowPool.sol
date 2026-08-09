// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAttestationOracle, Attestation} from "./interfaces/IAttestationOracle.sol";
import {CreditCurve} from "./libraries/CreditCurve.sol";

/// @notice A borrower's position. One per address.
struct CreditLine {
    /// @dev Outstanding debt including interest capitalised up to `lastAccrual`.
    uint256 principal;
    /// @dev vUSD escrowed by this borrower. Segregated -- never lent out to others.
    uint256 collateral;
    /// @dev Timestamp interest was last folded into `principal`.
    uint64 lastAccrual;
    /// @dev Rate this borrower currently pays, in bps. Re-snapshotted on every borrow/repay.
    uint16 rateBps;
    /// @dev CVI tier at the time of the most recent draw. Kept for audit trails.
    uint8 cviTierAtLastDraw;
    /// @dev CVI score at the time of the most recent draw.
    uint16 cviScoreAtLastDraw;
    /// @dev When this line was first opened.
    uint64 openedAt;
}

/// @notice Everything the UI needs about one wallet, in a single call.
struct CreditStatus {
    uint8 cviTier;
    uint16 cviScore;
    bool isCompliant;
    bool isVerified;
    uint256 trustScoreBps;
    uint256 reputationLine;
    uint256 collateralLine;
    uint256 maxBorrow;
    uint256 debt;
    uint256 available;
    uint256 collateral;
    uint256 rateBps;
    uint256 unsecuredShareBps;
    uint256 healthBps;
}

/// @notice Aggregate pool state, in a single call.
struct PoolStats {
    uint256 totalAssets;
    uint256 totalBorrows;
    uint256 cash;
    uint256 availableLiquidity;
    uint256 totalCollateral;
    uint256 totalReserves;
    uint256 utilizationBps;
    uint256 totalShares;
    uint256 sharePrice;
}

/// @title TrustFlowPool
/// @notice An identity-gated, undercollateralized lending pool. Borrowing power comes from
///         Cleanverse CVI-CVA attestations rather than from posting excess collateral.
///
/// @dev Design notes worth knowing before reading the code:
///
///      * COMPLIANCE IS A HARD GATE, NOT A DISCOUNT. `borrow` reverts unless the oracle
///        reports a live, unexpired, compliant attestation. Repayment is deliberately left
///        ungated -- freezing a sanctioned user's ability to *repay* would trap funds and
///        serve nobody.
///
///      * COLLATERAL IS SEGREGATED. Posted collateral is escrowed and excluded from the
///        lendable `cash`. This keeps the LP share price independent of borrower collateral
///        and makes the accounting auditable at a glance.
///
///      * INTEREST ACCRUES PER BORROWER. Because each borrower pays a personalised,
///        trust-adjusted rate, there is no single global borrow index. Interest is folded
///        into `principal` whenever an account is touched, and `accrueFor` is permissionless
///        so anyone can bring an account current. Consequence: `totalBorrows` lags real
///        accrued interest between touches, so `totalAssets` -- and therefore the LP share
///        price -- is a slight *underestimate*. That is the safe direction: an exiting LP can
///        never be paid out more than the pool has actually earned.
contract TrustFlowPool is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = CreditCurve.BPS;

    /// @notice Share of a liquidatee's debt a single liquidation may repay.
    uint256 public constant CLOSE_FACTOR_BPS = 5_000; // 50%

    /// @notice Premium a liquidator earns on seized collateral.
    uint256 public constant LIQUIDATION_BONUS_BPS = 800; // 8%

    /// @notice Upper bound on the protocol's cut of interest, enforced on config changes.
    uint256 public constant MAX_RESERVE_FACTOR_BPS = 3_000; // 30%

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice The stablecoin LPs supply and borrowers draw. vUSD in the demo, USDC in prod.
    IERC20 public immutable asset;

    /// @notice The identity feed. Swappable -- this is the Cleanverse integration seam.
    IAttestationOracle public oracle;

    /// @notice Sum of all outstanding debt, as of each borrower's last accrual.
    uint256 public totalBorrows;

    /// @notice Sum of all escrowed borrower collateral. Not lendable, not LP-claimable.
    uint256 public totalCollateral;

    /// @notice Protocol's accumulated cut of interest. Not LP-claimable.
    uint256 public totalReserves;

    /// @notice Protocol's share of interest, in bps.
    uint256 public reserveFactorBps = 1_000; // 10%

    mapping(address => CreditLine) internal _lines;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error NotCompliant(address borrower);
    error ExceedsCreditLimit(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InsufficientCollateral(uint256 requested, uint256 posted);
    error NoDebt(address borrower);
    error PositionHealthy(address borrower);
    error RepayExceedsCloseFactor(uint256 requested, uint256 maxRepay);
    error ReserveFactorTooHigh(uint256 requested);
    error NothingToRedeem();

    // ---------------------------------------------------------------------
    // Events -- the UI's live activity feed is built entirely from these
    // ---------------------------------------------------------------------

    event Deposited(address indexed lp, address indexed receiver, uint256 assets, uint256 shares);
    event Redeemed(address indexed lp, address indexed receiver, uint256 shares, uint256 assets);
    event CollateralPosted(address indexed borrower, uint256 amount, uint256 newCollateral);
    event CollateralWithdrawn(address indexed borrower, uint256 amount, uint256 newCollateral);
    event Borrowed(
        address indexed borrower,
        uint256 amount,
        uint256 newPrincipal,
        uint256 rateBps,
        uint8 cviTier,
        uint16 cviScore,
        uint256 maxBorrow,
        uint256 utilizationBps
    );
    event Repaid(
        address indexed borrower, address indexed payer, uint256 amount, uint256 newPrincipal
    );
    event InterestAccrued(
        address indexed borrower, uint256 interest, uint256 toReserves, uint256 newPrincipal
    );
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 repaid,
        uint256 seized,
        uint256 shortfall
    );
    event DefaultRecorded(address indexed borrower, uint256 unrecoveredDebt, uint8 cviTier);
    event OracleUpdated(address indexed previous, address indexed current, string sourceId);
    event ReserveFactorUpdated(uint256 previous, uint256 current);
    event ReservesWithdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(IERC20 asset_, IAttestationOracle oracle_, address initialOwner)
        ERC20("TrustFlow vUSD", "tfvUSD")
        Ownable(initialOwner)
    {
        if (address(asset_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        asset = asset_;
        oracle = oracle_;
        emit OracleUpdated(address(0), address(oracle_), oracle_.sourceId());
    }

    // ---------------------------------------------------------------------
    // Accounting views
    // ---------------------------------------------------------------------

    /// @notice Idle vUSD held by the pool, excluding escrowed borrower collateral.
    function cash() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > totalCollateral ? bal - totalCollateral : 0;
    }

    /// @notice Cash an LP can actually pull out, after setting aside protocol reserves.
    function availableLiquidity() public view returns (uint256) {
        uint256 c = cash();
        return c > totalReserves ? c - totalReserves : 0;
    }

    /// @notice Total supply-side assets backing LP shares: idle cash plus outstanding debt,
    ///         net of the protocol's reserve claim.
    function totalAssets() public view returns (uint256) {
        uint256 gross = cash() + totalBorrows;
        return gross > totalReserves ? gross - totalReserves : 0;
    }

    /// @notice Fraction of lendable supply currently drawn, in bps.
    function utilizationBps() public view returns (uint256) {
        uint256 gross = cash() + totalBorrows;
        if (gross == 0) return 0;
        return (totalBorrows * BPS) / gross;
    }

    /// @dev Virtual-share offset (+1/+1) blunts the classic first-depositor donation attack.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply() + 1)) / (totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + 1)) / (totalSupply() + 1);
    }

    /// @notice vUSD backing one whole LP share. Purely for display.
    function sharePrice() public view returns (uint256) {
        return convertToAssets(1e18);
    }

    // ---------------------------------------------------------------------
    // Borrower views
    // ---------------------------------------------------------------------

    function creditLineOf(address borrower) external view returns (CreditLine memory) {
        return _lines[borrower];
    }

    /// @notice Interest that has accrued since this account was last touched.
    function pendingInterest(address borrower) public view returns (uint256) {
        CreditLine memory line = _lines[borrower];
        if (line.principal == 0 || line.lastAccrual == 0) return 0;
        return CreditCurve.accruedInterest(
            line.principal, line.rateBps, block.timestamp - line.lastAccrual
        );
    }

    /// @notice Live debt, including interest not yet folded into principal.
    function debtOf(address borrower) public view returns (uint256) {
        return _lines[borrower].principal + pendingInterest(borrower);
    }

    /// @notice Borrowing power for `borrower` under the current attestation and collateral.
    function maxBorrowOf(address borrower) public view returns (uint256) {
        Attestation memory a = oracle.getAttestation(borrower);
        return CreditCurve.maxBorrow(a.cviTier, a.cviScore, _lines[borrower].collateral);
    }

    /// @notice Headroom left on the credit line. Zero once fully drawn.
    function availableCreditOf(address borrower) public view returns (uint256) {
        uint256 max = maxBorrowOf(borrower);
        uint256 debt = debtOf(borrower);
        return max > debt ? max - debt : 0;
    }

    /// @notice Rate `borrower` would pay on a draw right now, in bps.
    function borrowRateOf(address borrower) public view returns (uint256) {
        Attestation memory a = oracle.getAttestation(borrower);
        return CreditCurve.borrowRateBps(a.cviTier, a.cviScore, utilizationBps());
    }

    /// @notice maxBorrow / debt in bps. 10_000 is the liquidation boundary.
    /// @dev Returns type(uint256).max for a debt-free account.
    function healthBps(address borrower) public view returns (uint256) {
        uint256 debt = debtOf(borrower);
        if (debt == 0) return type(uint256).max;
        return (maxBorrowOf(borrower) * BPS) / debt;
    }

    /// @notice True when debt has outgrown the credit line -- e.g. attestation lapsed,
    ///         compliance revoked, or interest pushed the account over its limit.
    function isLiquidatable(address borrower) public view returns (bool) {
        uint256 debt = debtOf(borrower);
        return debt > 0 && debt > maxBorrowOf(borrower);
    }

    /// @notice One-call snapshot for the frontend.
    function creditStatus(address borrower) external view returns (CreditStatus memory s) {
        Attestation memory a = oracle.getAttestation(borrower);
        CreditLine memory line = _lines[borrower];
        uint256 debt = debtOf(borrower);
        uint256 max = CreditCurve.maxBorrow(a.cviTier, a.cviScore, line.collateral);

        s.cviTier = a.cviTier;
        s.cviScore = a.cviScore;
        s.isCompliant = a.isCompliant;
        s.isVerified = oracle.isVerified(borrower);
        s.trustScoreBps = CreditCurve.trustScoreBps(a.cviTier, a.cviScore);
        s.reputationLine = CreditCurve.reputationLine(a.cviTier, a.cviScore);
        s.collateralLine = CreditCurve.collateralLine(a.cviTier, line.collateral);
        s.maxBorrow = max;
        s.debt = debt;
        s.available = max > debt ? max - debt : 0;
        s.collateral = line.collateral;
        s.rateBps = CreditCurve.borrowRateBps(a.cviTier, a.cviScore, utilizationBps());
        s.unsecuredShareBps = CreditCurve.unsecuredShareBps(a.cviTier);
        s.healthBps = debt == 0 ? type(uint256).max : (max * BPS) / debt;
    }

    /// @notice One-call snapshot of pool health for the frontend.
    function poolStats() external view returns (PoolStats memory p) {
        p.totalAssets = totalAssets();
        p.totalBorrows = totalBorrows;
        p.cash = cash();
        p.availableLiquidity = availableLiquidity();
        p.totalCollateral = totalCollateral;
        p.totalReserves = totalReserves;
        p.utilizationBps = utilizationBps();
        p.totalShares = totalSupply();
        p.sharePrice = sharePrice();
    }

    // ---------------------------------------------------------------------
    // LP side
    // ---------------------------------------------------------------------

    /// @notice Supply vUSD to the pool and mint LP shares.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Priced against pool state BEFORE the incoming transfer lands.
        shares = convertToShares(assets);
        if (shares == 0) revert NothingToRedeem();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposited(msg.sender, receiver, assets, shares);
    }

    /// @notice Burn LP shares and withdraw the underlying vUSD.
    function redeem(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        assets = convertToAssets(shares);
        if (assets == 0) revert NothingToRedeem();

        uint256 liquid = availableLiquidity();
        if (assets > liquid) revert InsufficientLiquidity(assets, liquid);

        _burn(msg.sender, shares);
        asset.safeTransfer(receiver, assets);

        emit Redeemed(msg.sender, receiver, shares, assets);
    }

    // ---------------------------------------------------------------------
    // Borrower side
    // ---------------------------------------------------------------------

    /// @notice Escrow vUSD to enlarge the collateral component of your credit line.
    /// @dev Open to any wallet, verified or not. A tier-0 wallet posting collateral is just a
    ///      conventional 80%-LTV overcollateralized loan -- the fallback path.
    function postCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        CreditLine storage line = _lines[msg.sender];
        if (line.openedAt == 0) line.openedAt = uint64(block.timestamp);
        line.collateral += amount;
        totalCollateral += amount;

        asset.safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralPosted(msg.sender, amount, line.collateral);
    }

    /// @notice Reclaim escrowed collateral, provided the remaining line still covers the debt.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue(msg.sender);
        CreditLine storage line = _lines[msg.sender];
        if (amount > line.collateral) revert InsufficientCollateral(amount, line.collateral);

        line.collateral -= amount;
        totalCollateral -= amount;

        // Re-check solvency against the SHRUNKEN collateral base.
        Attestation memory a = oracle.getAttestation(msg.sender);
        uint256 max = CreditCurve.maxBorrow(a.cviTier, a.cviScore, line.collateral);
        if (line.principal > max) revert ExceedsCreditLimit(line.principal, max);

        asset.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount, line.collateral);
    }

    /// @notice Draw vUSD against your identity-derived credit line.
    /// @dev The compliance gate lives here and nowhere else. There is no admin override,
    ///      no allowlist bypass, and no path that reaches the transfer without it.
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // HARD COMPLIANCE GATE -- must hold a live, unexpired, compliant attestation.
        if (!oracle.isVerified(msg.sender)) revert NotCompliant(msg.sender);

        _accrue(msg.sender);

        // Gross supply is invariant across a borrow (cash falls, borrows rise by the same
        // amount), so measuring it here yields the correct POST-borrow utilization below.
        uint256 grossAssets = cash() + totalBorrows;

        CreditLine storage line = _lines[msg.sender];
        Attestation memory a = oracle.getAttestation(msg.sender);

        uint256 max = CreditCurve.maxBorrow(a.cviTier, a.cviScore, line.collateral);
        uint256 headroom = max > line.principal ? max - line.principal : 0;
        if (amount > headroom) revert ExceedsCreditLimit(amount, headroom);

        uint256 liquid = availableLiquidity();
        if (amount > liquid) revert InsufficientLiquidity(amount, liquid);

        if (line.openedAt == 0) line.openedAt = uint64(block.timestamp);
        line.principal += amount;
        totalBorrows += amount;

        uint256 util = grossAssets == 0 ? 0 : (totalBorrows * BPS) / grossAssets;
        uint256 rate = CreditCurve.borrowRateBps(a.cviTier, a.cviScore, util);

        // Safe: borrowRateBps is bounded above by BASE_RATE + SLOPE1 + SLOPE2 = 7_200 bps,
        // well inside uint16. `test_borrowRate_alwaysFitsUint16` fuzzes this bound.
        // forge-lint: disable-next-line(unsafe-typecast)
        line.rateBps = uint16(rate);
        line.lastAccrual = uint64(block.timestamp);
        line.cviTierAtLastDraw = a.cviTier;
        line.cviScoreAtLastDraw = a.cviScore;

        asset.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, line.principal, rate, a.cviTier, a.cviScore, max, util);
    }

    /// @notice Repay debt for `borrower`. Anyone may repay on anyone's behalf.
    /// @dev Intentionally NOT compliance-gated. Blocking repayment would strand funds and
    ///      leave a flagged borrower permanently indebted -- worse for everyone, including
    ///      the regulator.
    /// @param amount Pass type(uint256).max to clear the position exactly.
    function repay(address borrower, uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();

        _accrue(borrower);

        uint256 grossAssets = cash() + totalBorrows;

        CreditLine storage line = _lines[borrower];
        if (line.principal == 0) revert NoDebt(borrower);

        repaid = amount > line.principal ? line.principal : amount;

        line.principal -= repaid;
        totalBorrows -= repaid;

        // Re-price the surviving debt at the new, lower utilization.
        if (line.principal > 0) {
            Attestation memory a = oracle.getAttestation(borrower);
            uint256 util = grossAssets == 0 ? 0 : (totalBorrows * BPS) / grossAssets;
            // Safe: bounded by 7_200 bps -- see the note in `borrow`.
            // forge-lint: disable-next-line(unsafe-typecast)
            line.rateBps = uint16(CreditCurve.borrowRateBps(a.cviTier, a.cviScore, util));
        } else {
            line.rateBps = 0;
        }

        asset.safeTransferFrom(msg.sender, address(this), repaid);

        emit Repaid(borrower, msg.sender, repaid, line.principal);
    }

    /// @notice Fold accrued interest into `borrower`'s principal. Permissionless.
    /// @dev Anyone can poke any account. Keeping accounts current is what keeps the LP share
    ///      price honest, so it is deliberately open to keepers.
    function accrueFor(address borrower) external {
        _accrue(borrower);
    }

    /// @notice Batch version of `accrueFor`, for a keeper sweeping the book.
    function accrueForMany(address[] calldata borrowers) external {
        for (uint256 i = 0; i < borrowers.length; i++) {
            _accrue(borrowers[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Liquidation + default
    // ---------------------------------------------------------------------

    /// @notice Repay part of an underwater borrower's debt and seize their collateral at a
    ///         premium.
    /// @dev An unsecured line can go underwater with little or no collateral behind it -- that
    ///      is the inherent trade-off of undercollateralized credit. `shortfall` in the emitted
    ///      event reports exactly how much of the seize the collateral could not cover, so the
    ///      gap is measurable rather than hidden.
    function liquidate(address borrower, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 seized)
    {
        if (repayAmount == 0) revert ZeroAmount();

        _accrue(borrower);

        CreditLine storage line = _lines[borrower];
        if (line.principal == 0) revert NoDebt(borrower);

        uint256 max = maxBorrowOf(borrower);
        if (line.principal <= max) revert PositionHealthy(borrower);

        uint256 maxRepay = (line.principal * CLOSE_FACTOR_BPS) / BPS;
        if (repayAmount > maxRepay) revert RepayExceedsCloseFactor(repayAmount, maxRepay);

        uint256 target = (repayAmount * (BPS + LIQUIDATION_BONUS_BPS)) / BPS;
        seized = target > line.collateral ? line.collateral : target;
        uint256 shortfall = target - seized;

        line.principal -= repayAmount;
        totalBorrows -= repayAmount;
        line.collateral -= seized;
        totalCollateral -= seized;

        asset.safeTransferFrom(msg.sender, address(this), repayAmount);
        if (seized > 0) asset.safeTransfer(msg.sender, seized);

        emit Liquidated(borrower, msg.sender, repayAmount, seized, shortfall);
    }

    /// @notice Flag an unrecoverable position so the attestation authority can slash the
    ///         borrower's CVI/CVA off-chain.
    /// @dev This is the closing half of the undercollateralized loop: on-chain the pool has no
    ///      collateral left to seize, so the consequence has to land on the borrower's
    ///      *identity*. The emitted event is the signal a Cleanverse issuer consumes to
    ///      downgrade the wallet. Permissionless, but only valid on a genuinely dead position.
    function markDefault(address borrower) external {
        _accrue(borrower);

        CreditLine storage line = _lines[borrower];
        if (line.principal == 0) revert NoDebt(borrower);
        if (line.collateral > 0) revert PositionHealthy(borrower);
        if (line.principal <= maxBorrowOf(borrower)) revert PositionHealthy(borrower);

        Attestation memory a = oracle.getAttestation(borrower);
        emit DefaultRecorded(borrower, line.principal, a.cviTier);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Point the pool at a different attestation feed.
    /// @dev THE CLEANVERSE SWAP. Deploy an adapter implementing IAttestationOracle against the
    ///      live CVI-CVA API, call this, and every credit decision from that block on uses real
    ///      attestation data. No other contract changes, no migration, no redeploy.
    function setOracle(IAttestationOracle newOracle) external onlyOwner {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        address previous = address(oracle);
        oracle = newOracle;
        emit OracleUpdated(previous, address(newOracle), newOracle.sourceId());
    }

    function setReserveFactor(uint256 newFactorBps) external onlyOwner {
        if (newFactorBps > MAX_RESERVE_FACTOR_BPS) revert ReserveFactorTooHigh(newFactorBps);
        emit ReserveFactorUpdated(reserveFactorBps, newFactorBps);
        reserveFactorBps = newFactorBps;
    }

    function withdrawReserves(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount > totalReserves) revert InsufficientLiquidity(amount, totalReserves);
        uint256 c = cash();
        if (amount > c) revert InsufficientLiquidity(amount, c);

        totalReserves -= amount;
        asset.safeTransfer(to, amount);

        emit ReservesWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Capitalise elapsed interest into the borrower's principal and the pool's books.
    ///      Interest raises `totalBorrows` (so LP share price rises) and carves out the
    ///      protocol's reserve cut from the same amount.
    function _accrue(address borrower) internal {
        CreditLine storage line = _lines[borrower];

        if (line.lastAccrual == 0) {
            line.lastAccrual = uint64(block.timestamp);
            return;
        }
        if (line.principal == 0) {
            line.lastAccrual = uint64(block.timestamp);
            return;
        }

        uint256 elapsed = block.timestamp - line.lastAccrual;
        if (elapsed == 0) return;

        uint256 interest = CreditCurve.accruedInterest(line.principal, line.rateBps, elapsed);
        line.lastAccrual = uint64(block.timestamp);
        if (interest == 0) return;

        uint256 toReserves = (interest * reserveFactorBps) / BPS;

        line.principal += interest;
        totalBorrows += interest;
        totalReserves += toReserves;

        emit InterestAccrued(borrower, interest, toReserves, line.principal);
    }
}
