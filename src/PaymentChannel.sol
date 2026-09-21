// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title PaymentChannel
/// @notice Unidirectional CNDT payment channels.
/// - A payer opens a channel by depositing tokens for a payee with an expiration timestamp.
/// - The payee may close at any time (while the channel exists) with an EIP-712 voucher signed by the
///   payer for a cumulative amount. The payee receives that amount and the rest returns to the payer.
/// - From the expiration timestamp onward (block.timestamp >= expiresAt) the payer may reclaim the
///   whole deposit, unless the payee closed first.
/// @dev No owner, admin, fee or upgradeability. The only external calls are to the immutable token.
/// Vouchers must be signed by an EOA (ecrecover); contract-wallet (ERC-1271) payers are not supported.
contract PaymentChannel {
    struct Channel {
        address payer;
        address payee;
        uint256 deposit;
        uint64 expiresAt;
    }

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant VOUCHER_TYPEHASH = keccak256("Voucher(uint256 channelId,uint256 amount)");
    bytes32 private constant NAME_HASH = keccak256("PaymentChannel");
    bytes32 private constant VERSION_HASH = keccak256("1");
    /// @dev Upper bound of a canonical (low-s) secp256k1 signature, per EIP-2.
    uint256 private constant MAX_S = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    IERC20Minimal public immutable token;

    /// @notice Id of the most recently opened channel. Ids start at 1 and are never reused.
    uint256 public channelCount;
    mapping(uint256 => Channel) private _channels;
    uint256 private _locked = 1;

    event ChannelOpened(
        uint256 indexed channelId, address indexed payer, address indexed payee, uint256 deposit, uint64 expiresAt
    );
    event ChannelClosed(uint256 indexed channelId, uint256 paidToPayee, uint256 refundedToPayer);
    event ChannelReclaimed(uint256 indexed channelId, uint256 refundedToPayer);

    error InvalidToken();
    error InvalidPayee();
    error InvalidAmount();
    error InvalidExpiration();
    error UnexpectedTransferAmount();
    error ChannelNotFound();
    error NotPayee();
    error NotPayer();
    error AmountExceedsDeposit();
    error InvalidSignature();
    error NotExpired();
    error TokenTransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address token_) {
        if (token_.code.length == 0) revert InvalidToken();
        token = IERC20Minimal(token_);
    }

    /// @notice Opens a channel funded with `amount` tokens pulled from the caller (requires approval).
    /// @param payee The only address that may close the channel with a voucher.
    /// @param amount Deposit, must be > 0. The contract must receive exactly this amount.
    /// @param expiresAt Unix timestamp strictly in the future after which the payer may reclaim.
    function open(address payee, uint256 amount, uint64 expiresAt) external nonReentrant returns (uint256 channelId) {
        if (payee == address(0) || payee == msg.sender || payee == address(this)) revert InvalidPayee();
        if (amount == 0) revert InvalidAmount();
        if (expiresAt <= block.timestamp) revert InvalidExpiration();

        channelId = ++channelCount;
        _channels[channelId] = Channel({payer: msg.sender, payee: payee, deposit: amount, expiresAt: expiresAt});
        emit ChannelOpened(channelId, msg.sender, payee, amount, expiresAt);

        uint256 balanceBefore = token.balanceOf(address(this));
        _call(abi.encodeCall(IERC20Minimal.transferFrom, (msg.sender, address(this), amount)));
        if (token.balanceOf(address(this)) - balanceBefore != amount) revert UnexpectedTransferAmount();
    }

    /// @notice Closes a channel as its payee with the payer's signed voucher for a cumulative `amount`.
    /// The payee receives `amount`; the remaining deposit returns to the payer.
    function close(uint256 channelId, uint256 amount, bytes calldata signature) external nonReentrant {
        Channel memory channel = _channels[channelId];
        if (channel.payer == address(0)) revert ChannelNotFound();
        if (msg.sender != channel.payee) revert NotPayee();
        if (amount > channel.deposit) revert AmountExceedsDeposit();
        if (_recover(voucherDigest(channelId, amount), signature) != channel.payer) revert InvalidSignature();

        delete _channels[channelId];
        uint256 refund = channel.deposit - amount;
        emit ChannelClosed(channelId, amount, refund);

        if (amount != 0) _call(abi.encodeCall(IERC20Minimal.transfer, (channel.payee, amount)));
        if (refund != 0) _call(abi.encodeCall(IERC20Minimal.transfer, (channel.payer, refund)));
    }

    /// @notice Returns the whole deposit to the payer once `block.timestamp >= expiresAt`.
    function reclaim(uint256 channelId) external nonReentrant {
        Channel memory channel = _channels[channelId];
        if (channel.payer == address(0)) revert ChannelNotFound();
        if (msg.sender != channel.payer) revert NotPayer();
        if (block.timestamp < channel.expiresAt) revert NotExpired();

        delete _channels[channelId];
        emit ChannelReclaimed(channelId, channel.deposit);

        _call(abi.encodeCall(IERC20Minimal.transfer, (channel.payer, channel.deposit)));
    }

    /// @notice Returns an open channel; all fields are zero once it is closed or reclaimed.
    function getChannel(uint256 channelId) external view returns (Channel memory) {
        return _channels[channelId];
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice EIP-712 digest the payer signs for `Voucher(channelId, amount)`.
    function voucherDigest(uint256 channelId, uint256 amount) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VOUCHER_TYPEHASH, channelId, amount));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > MAX_S || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    /// @dev Calls the token and requires success plus either no return data or a true boolean.
    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = address(token).call(data);
        if (!ok || (ret.length != 0 && (ret.length != 32 || abi.decode(ret, (uint256)) != 1))) {
            revert TokenTransferFailed();
        }
    }
}
