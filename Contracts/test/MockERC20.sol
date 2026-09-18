// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Cue", "MCUE") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract MockCueNFTReader {
    uint256 public bonusBps;

    function setBonus(uint256 value) external {
        bonusBps = value;
    }

    function walletBonusBps(address) external view returns (uint256) {
        return bonusBps;
    }

    function BADGE_SILVER() external pure returns (uint8) { return 5; }
    function BADGE_GOLD() external pure returns (uint8) { return 6; }
    function BADGE_DIAMOND() external pure returns (uint8) { return 7; }
    function mintBadge(address, uint8, uint256) external pure returns (uint256) {
        return 1;
    }
}

contract MockRewardsPool {
    function payNFTBonus(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

contract MockFactory {
    address public pair = address(0xBEEF);

    function createPair(address, address) external view returns (address) {
        return pair;
    }
}

contract MockRouter {
    address public immutable factory;
    address public constant WETH = address(0xB0B);

    constructor() {
        factory = address(new MockFactory());
    }
}
