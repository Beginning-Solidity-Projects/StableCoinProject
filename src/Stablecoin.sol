// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Stablecoin is ERC20Burnable, Ownable {

    error Stablecoin_MustBeMoreThanZero();
    error Stablecoin_BurnMoreThanBalance();
    error Stablecoin_NoMintingZeroAddress();
    error Stablecoin_AmountMustBeMoreThanZero();

    constructor() ERC20("Stablecoin", "SBT") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if(_amount == 0) {
            revert Stablecoin_MustBeMoreThanZero();
        }
        if(balance < _amount) {
            revert Stablecoin_BurnMoreThanBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if(_to == address[0]) {
            revert Stablecoin_NoMintingZeroAddress;
        }
        if(_amount == 0) {
            revert Stablecoin_MustBeMoreThanZero();
        }
        _mint(_to,_amount);
        return true;
    }
}