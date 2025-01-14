// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.6.12;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public override feeTo;
    address public override feeToSetter;
    uint256 public override adminFee;
    uint256 public override providerFee;
    uint256 public override daysFee;

    bytes32 public constant INIT_CODE_HASH = keccak256(abi.encodePacked(type(UniswapV2Pair).creationCode));

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    // 0.4% fee = 4  0.17% fee = 17 mutiply the wanted fee by 10
    constructor(address _feeToSetter, uint256 _adminFee, uint256 _providerFee, uint256 _daysFee) public {
        feeToSetter = _feeToSetter;
        adminFee = _adminFee;
        providerFee = _providerFee;
        daysFee = _daysFee;
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(UniswapV2Pair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        UniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function getAdminFee() external view returns (uint256) {
        return adminFee;
    }

    function setAdminFee(uint256 _fee) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        adminFee = _fee;
    }

    function getProviderFee() external view returns (uint256) {
        return providerFee;
    }

    function setProviderFee(uint256 _fee) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        providerFee = _fee;
    }

    function setDaysFee(uint256 _daysFee) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        daysFee = _daysFee;
    }
}
