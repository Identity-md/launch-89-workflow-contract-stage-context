// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConduitToken} from "../src/ConduitToken.sol";
import {PaymentChannel} from "../src/PaymentChannel.sol";

/// @dev Token that tries to re-enter the channel contract during transfers.
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;
    PaymentChannel public target;
    bytes public attack;
    bool public attackSucceeded;
    bytes public attackRevertData;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(PaymentChannel target_, bytes calldata attack_) external {
        target = target_;
        attack = attack_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (attack.length != 0) {
            bytes memory data = attack;
            delete attack;
            (bool ok, bytes memory ret) = address(target).call(data);
            attackSucceeded = ok;
            attackRevertData = ret;
        }
    }
}

/// @dev Token that returns false instead of reverting.
contract FalseToken {
    mapping(address => uint256) public balanceOf;
    bool public fail;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFail(bool f) external {
        fail = f;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (fail) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (fail) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Token that takes a 1% fee on transfer.
contract FeeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount / 100;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract PaymentChannelTest is Test {
    ConduitToken token;
    PaymentChannel pc;

    uint256 payerKey = 0xA11CE;
    address payer;
    address payee = makeAddr("payee");
    address stranger = makeAddr("stranger");

    uint256 constant DEPOSIT = 1_000 ether;
    uint64 expiresAt;

    event ChannelOpened(
        uint256 indexed channelId, address indexed payer, address indexed payee, uint256 deposit, uint64 expiresAt
    );
    event ChannelClosed(uint256 indexed channelId, uint256 paidToPayee, uint256 refundedToPayer);
    event ChannelReclaimed(uint256 indexed channelId, uint256 refundedToPayer);

    function setUp() public {
        vm.warp(1_700_000_000);
        payer = vm.addr(payerKey);
        token = new ConduitToken();
        pc = new PaymentChannel(address(token));
        token.transfer(payer, 10_000 ether);
        vm.prank(payer);
        token.approve(address(pc), type(uint256).max);
        expiresAt = uint64(block.timestamp + 1 days);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(payer);
        id = pc.open(payee, DEPOSIT, expiresAt);
    }

    function _sign(uint256 key, uint256 id, uint256 amount) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, pc.voucherDigest(id, amount));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructorStoresToken() public view {
        assertEq(address(pc.token()), address(token));
    }

    function test_constructorRejectsNonContractToken() public {
        vm.expectRevert(PaymentChannel.InvalidToken.selector);
        new PaymentChannel(address(0));
        vm.expectRevert(PaymentChannel.InvalidToken.selector);
        new PaymentChannel(stranger);
    }

    // ---------------------------------------------------------------- open

    function test_open() public {
        vm.expectEmit(true, true, true, true);
        emit ChannelOpened(1, payer, payee, DEPOSIT, expiresAt);
        uint256 id = _open();
        assertEq(id, 1);
        assertEq(pc.channelCount(), 1);
        PaymentChannel.Channel memory c = pc.getChannel(id);
        assertEq(c.payer, payer);
        assertEq(c.payee, payee);
        assertEq(c.deposit, DEPOSIT);
        assertEq(c.expiresAt, expiresAt);
        assertEq(token.balanceOf(address(pc)), DEPOSIT);
        assertEq(token.balanceOf(payer), 10_000 ether - DEPOSIT);
        assertEq(_open(), 2);
    }

    function test_openRejectsZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.InvalidAmount.selector);
        pc.open(payee, 0, expiresAt);
    }

    function test_openRejectsBadPayee() public {
        vm.startPrank(payer);
        vm.expectRevert(PaymentChannel.InvalidPayee.selector);
        pc.open(address(0), DEPOSIT, expiresAt);
        vm.expectRevert(PaymentChannel.InvalidPayee.selector);
        pc.open(payer, DEPOSIT, expiresAt);
        vm.expectRevert(PaymentChannel.InvalidPayee.selector);
        pc.open(address(pc), DEPOSIT, expiresAt);
        vm.stopPrank();
    }

    function test_openRejectsExpirationNotInFuture() public {
        vm.startPrank(payer);
        vm.expectRevert(PaymentChannel.InvalidExpiration.selector);
        pc.open(payee, DEPOSIT, uint64(block.timestamp));
        vm.expectRevert(PaymentChannel.InvalidExpiration.selector);
        pc.open(payee, DEPOSIT, uint64(block.timestamp - 1));
        pc.open(payee, DEPOSIT, uint64(block.timestamp + 1));
        vm.stopPrank();
    }

    function test_openRevertsWithoutAllowanceOrBalance() public {
        vm.prank(stranger);
        vm.expectRevert(PaymentChannel.TokenTransferFailed.selector);
        pc.open(payee, 1, expiresAt);

        vm.prank(payer);
        vm.expectRevert(PaymentChannel.TokenTransferFailed.selector);
        pc.open(payee, 10_000 ether + 1, expiresAt);
    }

    function test_openRejectsFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        PaymentChannel p = new PaymentChannel(address(fee));
        fee.mint(payer, DEPOSIT);
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.UnexpectedTransferAmount.selector);
        p.open(payee, DEPOSIT, expiresAt);
    }

    function test_openRejectsFalseReturningToken() public {
        FalseToken ft = new FalseToken();
        PaymentChannel p = new PaymentChannel(address(ft));
        ft.mint(payer, DEPOSIT);
        ft.setFail(true);
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.TokenTransferFailed.selector);
        p.open(payee, DEPOSIT, expiresAt);
    }

    // ---------------------------------------------------------------- close

    function test_closePartial() public {
        uint256 id = _open();
        uint256 amount = 300 ether;
        bytes memory sig = _sign(payerKey, id, amount);
        vm.expectEmit(true, false, false, true);
        emit ChannelClosed(id, amount, DEPOSIT - amount);
        vm.prank(payee);
        pc.close(id, amount, sig);
        assertEq(token.balanceOf(payee), amount);
        assertEq(token.balanceOf(payer), 10_000 ether - amount);
        assertEq(token.balanceOf(address(pc)), 0);
        assertEq(pc.getChannel(id).payer, address(0));
    }

    function test_closeFullAndZero() public {
        uint256 id = _open();
        bytes memory sigid = _sign(payerKey, id, DEPOSIT);
        vm.prank(payee);
        pc.close(id, DEPOSIT, sigid);
        assertEq(token.balanceOf(payee), DEPOSIT);

        uint256 id2 = _open();
        bytes memory sigid2 = _sign(payerKey, id2, 0);
        vm.prank(payee);
        pc.close(id2, 0, sigid2);
        assertEq(token.balanceOf(payee), DEPOSIT);
        assertEq(token.balanceOf(payer), 10_000 ether - DEPOSIT);
        assertEq(token.balanceOf(address(pc)), 0);
    }

    function test_closeAfterExpirationStillAllowed() public {
        uint256 id = _open();
        vm.warp(expiresAt + 100);
        bytes memory sigid = _sign(payerKey, id, 1 ether);
        vm.prank(payee);
        pc.close(id, 1 ether, sigid);
        assertEq(token.balanceOf(payee), 1 ether);
    }

    function test_closeOnlyPayee() public {
        uint256 id = _open();
        bytes memory sig = _sign(payerKey, id, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(PaymentChannel.NotPayee.selector);
        pc.close(id, 1 ether, sig);
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.NotPayee.selector);
        pc.close(id, 1 ether, sig);
    }

    function test_closeAmountExceedsDeposit() public {
        uint256 id = _open();
        bytes memory sig = _sign(payerKey, id, DEPOSIT + 1);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.AmountExceedsDeposit.selector);
        pc.close(id, DEPOSIT + 1, sig);
    }

    function test_closeWrongSigner() public {
        uint256 id = _open();
        bytes memory sig = _sign(0xBAD, id, 1 ether);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, sig);
    }

    function test_closeAmountMismatchWithSignature() public {
        uint256 id = _open();
        bytes memory sig = _sign(payerKey, id, 1 ether);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 2 ether, sig);
    }

    function test_voucherNotReplayableAcrossChannels() public {
        uint256 id1 = _open();
        uint256 id2 = _open();
        bytes memory sig = _sign(payerKey, id1, 1 ether);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id2, 1 ether, sig);
    }

    function test_voucherNotReplayableAcrossContractsOrChains() public {
        uint256 id = _open();
        PaymentChannel other = new PaymentChannel(address(token));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, other.voucherDigest(id, 1 ether));
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, abi.encodePacked(r, s, v));

        bytes memory sig = _sign(payerKey, id, 1 ether);
        vm.chainId(999);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, sig);
    }

    function test_closeRejectsMalformedSignatures() public {
        uint256 id = _open();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, pc.voucherDigest(id, 1 ether));

        vm.startPrank(payee);
        // wrong length
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, abi.encodePacked(r, s));
        // high-s malleated form
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, abi.encodePacked(r, highS, flippedV));
        // invalid v
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, abi.encodePacked(r, s, uint8(0)));
        // unrecoverable (zero) signature
        vm.expectRevert(PaymentChannel.InvalidSignature.selector);
        pc.close(id, 1 ether, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        vm.stopPrank();
    }

    function test_closeTwiceReverts() public {
        uint256 id = _open();
        bytes memory sig = _sign(payerKey, id, 1 ether);
        vm.startPrank(payee);
        pc.close(id, 1 ether, sig);
        vm.expectRevert(PaymentChannel.ChannelNotFound.selector);
        pc.close(id, 1 ether, sig);
        vm.stopPrank();
    }

    function test_closeUnknownChannel() public {
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.ChannelNotFound.selector);
        pc.close(42, 0, new bytes(65));
    }

    function test_closeFailsWhenTokenReturnsFalse() public {
        FalseToken ft = new FalseToken();
        PaymentChannel p = new PaymentChannel(address(ft));
        ft.mint(payer, DEPOSIT);
        vm.prank(payer);
        uint256 id = p.open(payee, DEPOSIT, expiresAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, p.voucherDigest(id, 1 ether));
        ft.setFail(true);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.TokenTransferFailed.selector);
        p.close(id, 1 ether, abi.encodePacked(r, s, v));
        assertEq(p.getChannel(id).deposit, DEPOSIT, "state rolled back");
    }

    // ---------------------------------------------------------------- reclaim

    function test_reclaimAtExactExpiration() public {
        uint256 id = _open();
        vm.warp(expiresAt);
        vm.expectEmit(true, false, false, true);
        emit ChannelReclaimed(id, DEPOSIT);
        vm.prank(payer);
        pc.reclaim(id);
        assertEq(token.balanceOf(payer), 10_000 ether);
        assertEq(token.balanceOf(address(pc)), 0);
    }

    function test_reclaimOneSecondBeforeExpirationReverts() public {
        uint256 id = _open();
        vm.warp(expiresAt - 1);
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.NotExpired.selector);
        pc.reclaim(id);
    }

    function test_reclaimOnlyPayer() public {
        uint256 id = _open();
        vm.warp(expiresAt);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.NotPayer.selector);
        pc.reclaim(id);
        vm.prank(stranger);
        vm.expectRevert(PaymentChannel.NotPayer.selector);
        pc.reclaim(id);
    }

    function test_reclaimAfterCloseReverts() public {
        uint256 id = _open();
        bytes memory sigid = _sign(payerKey, id, 1 ether);
        vm.prank(payee);
        pc.close(id, 1 ether, sigid);
        vm.warp(expiresAt);
        vm.prank(payer);
        vm.expectRevert(PaymentChannel.ChannelNotFound.selector);
        pc.reclaim(id);
    }

    function test_closeAfterReclaimReverts() public {
        uint256 id = _open();
        bytes memory sig = _sign(payerKey, id, 1 ether);
        vm.warp(expiresAt);
        vm.prank(payer);
        pc.reclaim(id);
        vm.prank(payee);
        vm.expectRevert(PaymentChannel.ChannelNotFound.selector);
        pc.close(id, 1 ether, sig);
    }

    function test_reclaimTwiceReverts() public {
        uint256 id = _open();
        vm.warp(expiresAt);
        vm.startPrank(payer);
        pc.reclaim(id);
        vm.expectRevert(PaymentChannel.ChannelNotFound.selector);
        pc.reclaim(id);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- isolation & conservation

    function test_channelsAreIsolated() public {
        uint256 id1 = _open();
        uint256 id2 = _open();
        bytes memory sigid1 = _sign(payerKey, id1, DEPOSIT);
        vm.prank(payee);
        pc.close(id1, DEPOSIT, sigid1);
        assertEq(token.balanceOf(address(pc)), DEPOSIT);
        assertEq(pc.getChannel(id2).deposit, DEPOSIT);
        vm.warp(expiresAt);
        vm.prank(payer);
        pc.reclaim(id2);
        assertEq(token.balanceOf(address(pc)), 0);
    }

    function testFuzz_closeConservesFunds(uint256 deposit, uint256 amount) public {
        deposit = bound(deposit, 1, 10_000 ether);
        amount = bound(amount, 0, deposit);
        vm.prank(payer);
        uint256 id = pc.open(payee, deposit, expiresAt);
        bytes memory sigid = _sign(payerKey, id, amount);
        vm.prank(payee);
        pc.close(id, amount, sigid);
        assertEq(token.balanceOf(payee), amount);
        assertEq(token.balanceOf(payer), 10_000 ether - amount);
        assertEq(token.balanceOf(address(pc)), 0);
    }

    // ---------------------------------------------------------------- reentrancy

    function _reentrantSetup() internal returns (ReentrantToken rt, PaymentChannel p, uint256 id) {
        rt = new ReentrantToken();
        p = new PaymentChannel(address(rt));
        rt.mint(payer, 2 * DEPOSIT);
        vm.prank(payer);
        id = p.open(payee, DEPOSIT, expiresAt);
        vm.prank(payer);
        p.open(payee, DEPOSIT, expiresAt);
    }

    function test_reentrancyDuringReclaimBlocked() public {
        (ReentrantToken rt, PaymentChannel p, uint256 id) = _reentrantSetup();
        vm.warp(expiresAt);
        rt.arm(p, abi.encodeCall(PaymentChannel.reclaim, (id)));
        vm.prank(payer);
        p.reclaim(id);
        assertFalse(rt.attackSucceeded());
        assertEq(bytes4(rt.attackRevertData()), PaymentChannel.Reentrancy.selector);
        assertEq(rt.balanceOf(payer), DEPOSIT);
        assertEq(rt.balanceOf(address(p)), DEPOSIT);
    }

    function test_reentrancyDuringCloseBlocked() public {
        (ReentrantToken rt, PaymentChannel p, uint256 id) = _reentrantSetup();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, p.voucherDigest(id, 1 ether));
        bytes memory sig = abi.encodePacked(r, s, v);
        rt.arm(p, abi.encodeCall(PaymentChannel.close, (id, 1 ether, sig)));
        vm.prank(payee);
        p.close(id, 1 ether, sig);
        assertFalse(rt.attackSucceeded());
        assertEq(bytes4(rt.attackRevertData()), PaymentChannel.Reentrancy.selector);
        assertEq(rt.balanceOf(payee), 1 ether);
        assertEq(rt.balanceOf(address(p)), DEPOSIT);
    }

    function test_reentrancyDuringOpenBlocked() public {
        ReentrantToken rt = new ReentrantToken();
        PaymentChannel p = new PaymentChannel(address(rt));
        rt.mint(payer, DEPOSIT);
        rt.arm(p, abi.encodeCall(PaymentChannel.open, (payee, 1, expiresAt)));
        vm.prank(payer);
        p.open(payee, DEPOSIT, expiresAt);
        assertFalse(rt.attackSucceeded());
        assertEq(bytes4(rt.attackRevertData()), PaymentChannel.Reentrancy.selector);
        assertEq(p.channelCount(), 1);
    }

    // ---------------------------------------------------------------- EIP-712 layout

    function test_digestMatchesEip712() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PaymentChannel"),
                keccak256("1"),
                block.chainid,
                address(pc)
            )
        );
        assertEq(pc.DOMAIN_SEPARATOR(), domain);
        bytes32 structHash = keccak256(abi.encode(keccak256("Voucher(uint256 channelId,uint256 amount)"), 7, 5));
        assertEq(pc.voucherDigest(7, 5), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
