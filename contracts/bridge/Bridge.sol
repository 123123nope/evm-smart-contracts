// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Actions} from "../libs/Actions.sol";
import {FeeUtils} from "../libs/FeeUtils.sol";
import {IAdapter} from "./adapters/IAdapter.sol";
import {IBridge, ILBTC, INotaryConsortium} from "./IBridge.sol";
import {RateLimits} from "../libs/RateLimits.sol";
contract Bridge is
    IBridge,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable
{
    struct DestinationConfig {
        bytes32 bridgeContract;
        uint16 relativeCommission; // relative to amount commission to charge on bridge deposit
        uint64 absoluteCommission; // absolute commission to charge on bridge deposit
        IAdapter adapter; // adapter which should provide bridging logic (nullable)
        bool requireConsortium; // require notarization from consortium
    }

    struct Deposit {
        bytes payload; // content of Deposit
        bool adapterReceived; // true if payload received from adapter
        bool notarized; // true if payload notarized from consortium
        bool withdrawn; // true if payload already withdrawn
    }

    /// @custom:storage-location erc7201:lombardfinance.storage.Bridge
    struct BridgeStorage {
        address treasury;
        ILBTC lbtc;
        // Increments with each cross chain operation and should be part of the payload
        // Makes each payload unique
        uint256 crossChainOperationsNonce;
        mapping(bytes32 => DestinationConfig) destinations;
        mapping(bytes32 => Deposit) deposits;
        INotaryConsortium consortium;
        // Rate limits
        mapping(bytes32 => RateLimits.Data) depositRateLimits;
        mapping(bytes32 => RateLimits.Data) withdrawRateLimits;
    }

    // keccak256(abi.encode(uint256(keccak256("lombardfinance.storage.Bridge")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BRIDGE_STORAGE_LOCATION =
        0x577a31cbb7f7b010ebd1a083e4c4899bcd53b83ce9c44e72ce3223baedbbb600;
    uint16 private constant MAX_COMMISSION = 100_00; // 100.00%

    /// PUBLIC FUNCTIONS ///

    /// @dev https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#initializing_the_implementation_contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        ILBTC lbtc_,
        address treasury_,
        address owner_
    ) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();

        __Bridge_init(lbtc_, treasury_);
    }

    /// GETTERS ///

    function getTreasury() external view returns (address) {
        return _getBridgeStorage().treasury;
    }

    /**
     * @dev Get config of destination chain
     * @param toChain Chain id of the destination chain
     */
    function getDestination(
        bytes32 toChain
    ) public view returns (DestinationConfig memory) {
        return _getBridgeStorage().destinations[toChain];
    }

    function getDepositAbsoluteCommission(
        bytes32 toChain
    ) public view returns (uint64) {
        return _getBridgeStorage().destinations[toChain].absoluteCommission;
    }

    function getDepositRelativeCommission(
        bytes32 toChain
    ) public view returns (uint16) {
        return _getBridgeStorage().destinations[toChain].relativeCommission;
    }

    /**
     * @notice Returns the address of the configured adapter
     */
    function getAdapter(bytes32 toChain) external view returns (IAdapter) {
        return _getBridgeStorage().destinations[toChain].adapter;
    }

    function consortium() external view override returns (INotaryConsortium) {
        return _getBridgeStorage().consortium;
    }

    function lbtc() public view override returns (ILBTC) {
        return _getBridgeStorage().lbtc;
    }

    function getAdapterFee(
        bytes32 toChain,
        bytes32 toAddress,
        uint64 amount
    ) external view returns (uint256) {
        DestinationConfig memory destConfig = getDestination(toChain);
        if (destConfig.bridgeContract == bytes32(0)) {
            return 0;
        }

        // payload data doesn't matter for fee calculation, only length
        return
            destConfig.adapter.getFee(
                toChain,
                destConfig.bridgeContract,
                toAddress,
                amount,
                new bytes(228)
            );
    }

    /// ACTIONS ///

    /**
     * @notice Deposit LBTC to another chain.
     * @dev LBTC on source and destination chains are linked with independent supplies.
     * Burns tokens on source chain (to later mint on destination chain).
     * @param toChain One of many destination chain ID.
     * @param toAddress The address that will receive `amount` LBTC.
     * @param amount Amount of LBTC to be sent.
     */
    function deposit(
        bytes32 toChain,
        bytes32 toAddress,
        uint64 amount
    ) external payable override nonReentrant returns (uint256, bytes memory) {
        // validate inputs
        // amount should be validated, because absolute commission can be not set
        if (amount == 0) {
            revert Bridge_ZeroAmount();
        }

        if (toAddress == bytes32(0)) {
            revert Bridge_ZeroAddress();
        }

        // it's not necessary to validate `toChain` because destination
        // for zero chain can't be set
        DestinationConfig memory destConfig = getDestination(toChain);
        if (destConfig.bridgeContract == bytes32(0)) {
            revert UnknownDestination();
        }

        return _deposit(destConfig, toChain, toAddress, amount);
    }

    /**
     * @notice Notify the bridge about received payload from adapter.
     * @dev only adapter can call
     * @param fromChain The source where payload produced.
     * @param payload The payload received from bridge adapter.
     */
    function receivePayload(
        bytes32 fromChain,
        bytes calldata payload
    ) external override {
        // validate inputs
        DestinationConfig memory destConf = getDestination(fromChain);
        if (destConf.bridgeContract == bytes32(0)) {
            revert UnknownDestination();
        }

        // it also prevent to use method if adapter not set
        if (_msgSender() != address(destConf.adapter)) {
            revert UnknownAdapter(_msgSender());
        }

        // payload validation
        if (bytes4(payload) != Actions.DEPOSIT_BRIDGE_ACTION) {
            revert UnexpectedAction(bytes4(payload));
        }
        Actions.DepositBridgeAction memory action = Actions.depositBridge(
            payload[4:]
        );

        // extra checks
        if (
            destConf.bridgeContract !=
            bytes32(uint256(uint160(action.fromContract)))
        ) {
            revert UnknownOriginContract(
                bytes32(action.fromChain),
                bytes32(uint256(uint160(action.fromContract)))
            );
        }

        BridgeStorage storage $ = _getBridgeStorage();
        bytes32 payloadHash = sha256(payload);

        if ($.deposits[payloadHash].withdrawn) {
            revert PayloadAlreadyUsed(payloadHash);
        }

        $.deposits[payloadHash].adapterReceived = true;

        emit PayloadReceived(action.recipient, payloadHash, _msgSender());
    }

    function authNotary(
        bytes calldata payload,
        bytes calldata proof
    ) external nonReentrant {
        // payload validation
        if (bytes4(payload) != Actions.DEPOSIT_BRIDGE_ACTION) {
            revert UnexpectedAction(bytes4(payload));
        }
        Actions.DepositBridgeAction memory action = Actions.depositBridge(
            payload[4:]
        );

        // TODO: verify action

        bytes32 payloadHash = sha256(payload);
        BridgeStorage storage $ = _getBridgeStorage();

        Deposit storage depositData = $.deposits[payloadHash];
        // proof validation
        if (depositData.withdrawn) {
            revert PayloadAlreadyUsed(payloadHash);
        }

        depositData.notarized = true;

        $.consortium.checkProof(payloadHash, proof);

        emit PayloadNotarized(action.recipient, payloadHash);
    }

    /**
     * @notice Withdraw bridged LBTC
     */
    function withdraw(bytes calldata payload) external nonReentrant {
        BridgeStorage storage $ = _getBridgeStorage();

        // payload validation
        if (bytes4(payload) != Actions.DEPOSIT_BRIDGE_ACTION) {
            revert UnexpectedAction(bytes4(payload));
        }
        Actions.DepositBridgeAction memory action = Actions.depositBridge(
            payload[4:]
        );

        // check rate limits
        RateLimits.updateLimit(
            $.withdrawRateLimits[bytes32(action.fromChain)],
            action.amount
        );

        DestinationConfig memory destConf = $.destinations[
            bytes32(action.fromChain)
        ];

        bytes32 payloadHash = sha256(payload);
        Deposit storage depositData = $.deposits[payloadHash];

        // validate required auth received
        if (
            address(destConf.adapter) != address(0) &&
            !depositData.adapterReceived
        ) {
            revert AdapterNotConfirmed();
        }

        if (destConf.requireConsortium && !depositData.notarized) {
            revert ConsortiumNotConfirmed();
        }

        // proof validation
        if (depositData.withdrawn) {
            revert PayloadAlreadyUsed(payloadHash);
        }

        depositData.withdrawn = true;

        lbtc().mint(action.recipient, action.amount);

        emit WithdrawFromBridge(
            action.recipient,
            payloadHash,
            payload,
            action.amount
        );
    }

    /// ONLY OWNER ///

    /**
     * @param adapter Address of adapter if required (nullable)
     * @param requireConsortium Flag to require consortium for bridging
     */
    function addDestination(
        bytes32 toChain,
        bytes32 toContract,
        uint16 relCommission,
        uint64 absCommission,
        IAdapter adapter,
        bool requireConsortium
    ) external onlyOwner {
        if (toContract == bytes32(0)) {
            revert ZeroContractHash();
        }
        if (toChain == bytes32(0)) {
            revert ZeroChainId();
        }

        if (!requireConsortium && address(adapter) == address(0)) {
            revert BadConfiguration();
        }

        if (getDestination(toChain).bridgeContract != bytes32(0)) {
            revert KnownDestination();
        }
        // do not allow 100% commission or higher values
        FeeUtils.validateCommission(relCommission);

        _getBridgeStorage().destinations[toChain] = DestinationConfig(
            toContract,
            relCommission,
            absCommission,
            adapter,
            requireConsortium
        );

        emit DepositAbsoluteCommissionChanged(absCommission, toChain);
        emit DepositRelativeCommissionChanged(relCommission, toChain);
        // TODO: add more information to event
        emit BridgeDestinationAdded(toChain, toContract);
    }

    function removeDestination(bytes32 toChain) external onlyOwner {
        _validDestination(toChain);

        BridgeStorage storage $ = _getBridgeStorage();
        delete $.destinations[toChain];

        emit DepositAbsoluteCommissionChanged(0, toChain);
        emit DepositRelativeCommissionChanged(0, toChain);
        emit BridgeDestinationRemoved(toChain);
    }

    function changeDepositAbsoluteCommission(
        uint64 newValue,
        bytes32 chain
    ) external onlyOwner {
        _validDestination(chain);

        BridgeStorage storage $ = _getBridgeStorage();
        $.destinations[chain].absoluteCommission = newValue;
        emit DepositAbsoluteCommissionChanged(newValue, chain);
    }

    function changeDepositRelativeCommission(
        uint16 newValue,
        bytes32 chain
    ) external onlyOwner {
        _validDestination(chain);

        FeeUtils.validateCommission(newValue);

        BridgeStorage storage $ = _getBridgeStorage();
        $.destinations[chain].relativeCommission = newValue;
        emit DepositRelativeCommissionChanged(newValue, chain);
    }

    function changeAdapter(
        bytes32 chain,
        IAdapter newAdapter
    ) external onlyOwner {
        _changeAdapter(chain, newAdapter);
    }

    function changeConsortium(INotaryConsortium newVal) external onlyOwner {
        BridgeStorage storage $ = _getBridgeStorage();
        emit ConsortiumChanged($.consortium, newVal);
        $.consortium = newVal;
    }

    function setRateLimits(
        RateLimits.Config[] memory depositRateLimits,
        RateLimits.Config[] memory withdrawRateLimits
    ) external onlyOwner {
        BridgeStorage storage $ = _getBridgeStorage();
        for (uint256 i; i < depositRateLimits.length; i++) {
            RateLimits.setRateLimit(
                $.depositRateLimits[depositRateLimits[i].chainId],
                depositRateLimits[i]
            );
        }
        for (uint256 i; i < withdrawRateLimits.length; i++) {
            RateLimits.setRateLimit(
                $.withdrawRateLimits[withdrawRateLimits[i].chainId],
                withdrawRateLimits[i]
            );
        }
    }

    /// PRIVATE FUNCTIONS ///

    function __Bridge_init(
        ILBTC lbtc_,
        address treasury_
    ) internal onlyInitializing {
        _changeTreasury(treasury_);

        BridgeStorage storage $ = _getBridgeStorage();
        $.lbtc = lbtc_;
    }

    function _deposit(
        DestinationConfig memory config,
        bytes32 toChain,
        bytes32 toAddress,
        uint64 amount
    ) internal returns (uint256, bytes memory) {
        BridgeStorage storage $ = _getBridgeStorage();

        // check rate limits
        RateLimits.updateLimit($.depositRateLimits[toChain], amount);

        // relative fee
        uint256 fee = FeeUtils.getRelativeFee(
            amount,
            getDepositRelativeCommission(toChain)
        );
        // absolute fee
        fee += config.absoluteCommission;

        if (fee >= amount) {
            revert AmountLessThanCommission(fee);
        }
        uint64 amountWithoutFee = amount - uint64(fee);

        address fromAddress = _msgSender();

        // charge Lombard fees
        SafeERC20.safeTransferFrom(
            IERC20(address(lbtc())),
            fromAddress,
            $.treasury,
            fee
        );

        // prepare bridge deposit payload
        bytes memory payload = abi.encodeWithSelector(
            Actions.DEPOSIT_BRIDGE_ACTION,
            bytes32(block.chainid),
            bytes32(uint256(uint160(address(this)))),
            toChain,
            config.bridgeContract,
            toAddress,
            amountWithoutFee,
            $.crossChainOperationsNonce++
        );

        if (address(config.adapter) != address(0)) {
            // transfer assets to adapter
            SafeERC20.safeTransferFrom(
                IERC20(address(lbtc())),
                fromAddress,
                address(config.adapter),
                amountWithoutFee
            );
            // let adapter handle the deposit
            config.adapter.deposit{value: msg.value}(
                fromAddress,
                toChain,
                config.bridgeContract,
                toAddress,
                amountWithoutFee,
                payload
            );
        } else {
            // burn assets if no adapter
            lbtc().burn(fromAddress, amountWithoutFee);
        }

        emit DepositToBridge(fromAddress, toAddress, sha256(payload), payload);
        return (amountWithoutFee, payload);
    }

    function _changeTreasury(address treasury_) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        address previousTreasury = $.treasury;
        $.treasury = treasury_;
        emit TreasuryChanged(previousTreasury, treasury_);
    }

    function _changeAdapter(bytes32 toChain, IAdapter newAdapter) internal {
        if (address(newAdapter) == address(0)) {
            revert Bridge_ZeroAddress();
        }
        DestinationConfig storage conf = _getBridgeStorage().destinations[
            toChain
        ];
        address previousAdapter = address(conf.adapter);
        conf.adapter = IAdapter(newAdapter);
        emit AdapterChanged(previousAdapter, newAdapter);
    }

    function _calcRelativeFee(
        uint64 amount,
        uint16 commission
    ) internal pure returns (uint256 fee) {
        return
            Math.mulDiv(amount, commission, MAX_COMMISSION, Math.Rounding.Ceil);
    }

    function _getBridgeStorage()
        private
        pure
        returns (BridgeStorage storage $)
    {
        assembly {
            $.slot := BRIDGE_STORAGE_LOCATION
        }
    }

    function _validDestination(bytes32 chain) internal view {
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.destinations[chain].bridgeContract == bytes32(0)) {
            revert NotValidDestination();
        }
    }
}