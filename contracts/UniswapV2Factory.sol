pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {

    //开发者团队的地址。用于切换开发团队手续费开关，在uniswapV2中，会收取0.3%的手续费给LP，如果这里的feeTo地址是0，
    //则表明不给开发者团队手续费，如果不为0，则开发者会收取0.05%手续费。
    address public feeTo;
    //用于改变开发者团队地址,有权限更改feeToSetter本身和feeTo的address
    address public feeToSetter;

    //前两个地址分别对应交易对中的两种代币地址，最后一个地址是交易对合约本身地址
    mapping(address => mapping(address => address)) public getPair;
    //是用于存放所有交易对（代币对）合约地址信息
    address[] public allPairs;

    //事件在createPair方法中触发，保存交易对的信息（两种代币地址，交易对本身地址，创建交易对的数量）
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    //返回到目前为止通过工厂创建的交易对的总数。
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        //确保tokenA和tokenB不相等
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //tokenA和tokenB按照地址大小排序
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        //确保token0地址不等于0
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        //确保token0和token1这个pair目前不存在，就是确保这个pair还没被创建过
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        //取到UniswapV2Pair这个合约的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        //以token0和token1的地址的哈希作为salt
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        //内联汇编代码
        assembly {
            //通过create2的方法部署合约，加上salt变量，返回部署的合约地址到pair
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //调用IUniswapV2Pair的initialize方法，单纯的传入token0和token1地址
        IUniswapV2Pair(pair).initialize(token0, token1);
        //映射存放token0和token1的地址对，方便获取
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        //存放所有的
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    //更改开发者团队权限地址
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
