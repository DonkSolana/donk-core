// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.6.12;

import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is UniswapV2ERC20 {
    using SafeMathUniswap for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast = 0;
    uint public price1CumulativeLast = 0;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    mapping(address => uint) public accumulatedFeeToken0;
    mapping(address => uint) public accumulatedFeeToken1;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            string(abi.encodePacked('UniswapV2: TRANSFER_FAILED'))
        );
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(2).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        uint balance0 = IERC20Uniswap(token0).balanceOf(address(this));
        uint balance1 = IERC20Uniswap(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint liquidity, uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) = getBurnInputs();
        (uint feeAmount0, uint feeAmount1, uint providerFee0, uint providerFee1, uint pairFee) = calculateFeeAmounts();

        bool feeOn = _mintFee(_reserve0, _reserve1);

        (amount0, amount1) = getAmounts(liquidity, balance0, balance1);

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);

        payUserAmounts(to, amount0, amount1, feeAmount0, feeAmount1, providerFee0, providerFee1, pairFee);

        balance0 = IERC20Uniswap(token0).balanceOf(address(this));
        balance1 = IERC20Uniswap(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(_reserve0).mul(_reserve1); // _reserve0 and _reserve1 are up-to-date

        emit Burn(msg.sender, amount0, amount1, to);
    }

    function getAmounts(uint liquidity, uint balance0, uint balance1) public view returns (uint amount0, uint amount1) {
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
    }

    function payUserAmounts(
        address to,
        uint amount0,
        uint amount1,
        uint feeAmount0,
        uint feeAmount1,
        uint providerFee0,
        uint providerFee1,
        uint pairFee
    ) private {
        address _feeToSetter = IUniswapV2Factory(factory).feeToSetter();
        //transfering provider fee to the provider and the admin fee to the admin wallet
        if (feeAmount1 > 0) {
            _safeTransfer(token0, _feeToSetter, feeAmount0);
            _safeTransfer(token0, to, amount0.subSafeMath(pairFee).addSafeMath(providerFee0));
            accumulatedFeeToken0[address(this)] = 0;
        } else {
            _safeTransfer(token0, to, amount0);
        }

        if (feeAmount0 > 0) {
            _safeTransfer(token1, _feeToSetter, feeAmount1);
            _safeTransfer(token1, to, amount1.subSafeMath(pairFee).addSafeMath(providerFee1));
            accumulatedFeeToken0[address(this)] = 0;
        } else {
            _safeTransfer(token1, to, amount1);
        }
    }

    function getBurnInputs()
        public
        view
        returns (uint liquidity, uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1)
    {
        (_reserve0, _reserve1, ) = getReserves(); // gas savings
        balance0 = IERC20Uniswap(token0).balanceOf(address(this));
        balance1 = IERC20Uniswap(token1).balanceOf(address(this));
        liquidity = balanceOf[address(this)];
    }

    function calculateFeeAmounts()
        public
        view
        returns (uint feeAmount0, uint feeAmount1, uint providerFee0, uint providerFee1, uint pairFee)
    {
        uint fees = IUniswapV2Factory(factory).adminFee();
        uint providerFees = IUniswapV2Factory(factory).providerFee();
        uint total = 100;

        //pair fee it will let the rest for the pair

        uint calcPairFee = total.subSafeMath(fees).subSafeMath(providerFees).div(10000); // 0.60%
        pairFee = accumulatedFeeToken0[address(this)].mulSafeMath(calcPairFee).div(10000); // 0.60%
        //admin fee
        feeAmount0 = accumulatedFeeToken0[address(this)].mulSafeMath(fees).div(10000); // 0.17%
        feeAmount1 = accumulatedFeeToken1[address(this)].mulSafeMath(fees).div(10000); // 0.17%

        //provider fee
        providerFee0 = accumulatedFeeToken0[address(this)].mulSafeMath(providerFees).div(10000); // 0.23%
        providerFee1 = accumulatedFeeToken1[address(this)].mulSafeMath(providerFees).div(10000); // 023%
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20Uniswap(_token0).balanceOf(address(this));
            balance1 = IERC20Uniswap(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            calculateLiquidityFee(amount0Out, amount1Out);
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function calculateLiquidityFee(uint amount0Out, uint amount1Out) public {
        uint swapFees = IUniswapV2Factory(factory).swapFee();

        if (amount0Out > 0) {
            uint feeToken0 = amount0Out.mulSafeMath(swapFees).div(1000);
            accumulatedFeeToken0[address(this)] = accumulatedFeeToken0[address(this)].addSafeMath(feeToken0);
        } else if (amount1Out > 0) {
            uint feeToken1 = amount1Out.mulSafeMath(swapFees).div(1000);
            accumulatedFeeToken1[address(this)] = accumulatedFeeToken1[address(this)].addSafeMath(feeToken1);
        }
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20Uniswap(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20Uniswap(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(
            IERC20Uniswap(token0).balanceOf(address(this)),
            IERC20Uniswap(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}
