// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConduitToken} from "../src/ConduitToken.sol";

contract ConduitTokenTest is Test {
    ConduitToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new ConduitToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Conduit");
        assertEq(token.symbol(), "CNDT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_constructorMintsToDeployerAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1e27);
        vm.prank(alice);
        ConduitToken t = new ConduitToken();
        assertEq(t.balanceOf(alice), 1e27);
    }

    function test_transfer() public {
        assertTrue(token.transfer(alice, 100));
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(address(this)), 1e27 - 100);
    }

    function test_transferInsufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(ConduitToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(ConduitToken.InvalidReceiver.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        token.approve(alice, 50);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(address(this), alice), 20);

        vm.prank(alice);
        vm.expectRevert(ConduitToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 21);
    }

    function test_infiniteAllowanceNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(ConduitToken.InvalidSpender.selector);
        token.approve(address(0), 1);
    }

    function test_noMintSelector() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), token.totalSupply());
    }
}
