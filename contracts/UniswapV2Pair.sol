pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

//Uniswap配对合约
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    //定义了最小流动性，在提供初始流动性时会被燃烧掉 1000
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 是用于计算ERC-20合约中转移资产的transfer对应的函数选择器
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    //是要用于存储factory合约地址，token0，token1分别表示两种代币的地址
    address public factory;
    address public token0;
    address public token1;

    //这个缓存余额是为了解决uniswap v1价格操纵和剧烈波动的问题，详情见《Uniswap 顶流之路：机制、决策与风险分析》
    //https://foresightnews.pro/article/detail/12945
    //reserve0 reserve1为缓存余额，并非实际余额，值取自上一个块的最后一个交易
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    //记录交易时的区块创建时间
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    //price0CumulativeLast，price1CumulativeLast变量用于记录交易对中两种价格的累计值
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    // 用于表示某一时刻恒定乘积中的积的值，主要用于开发团队手续费的计算
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //表示未被锁上的状态，用于下面的修饰器
    uint private unlocked = 1;

    //锁定运行，防止重入
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //获取缓存余额与更新时间戳
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //此时会使用代币的call函数去调用代币合约transfer来发送代币，在这里会检查call调用是否成功以及返回值是否为true：
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
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

    //这是因为用 create2 创建合约的方式限制了构造函数不能有参数。
    constructor() public {
        //设置工厂合约
        factory = msg.sender;
    }

    //初始化pair两个代币的地址
    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        //必须有工厂合约调用
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * 
     * @param balance0 
     * @param balance1 
     * @param _reserve0 
     * @param _reserve1 
     * 用于更新reserves并进行价格累计的计算
     */
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        //用于验证 balance0 和 blanace1 是否 uint112 的上限
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        //blockTimestamp只取后32位
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        //计算当前区块和上一个区块之间的时间差
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //时间差（两个区块的时间差，不是同一个区块）大于0并且两种资产的数量不为0，才可以进行价格累计计算，
        //如果是同一个区块的第二笔交易及以后的交易，timeElapsed则为0，此时不会计算价格累计值。
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新 reserve0 和 reserve1；同时更新block时间为当前 blockTimestampLast 时间，之后通过emit触发同步事件：
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // 用于在添加流动性和移除流动性时，计算开发团队手续费
    // 向feeTo地址发送手续费，但是这个函数从未被调用，因为feeTo地址一直都为空
    /**
     * Uniswap V2 新增了协议收费机制，也称为费用开关。当机制关闭时，LP 获得 0.3% 的收入。而当机制开启时，协议将抽取 0.05% 的费用，
     * LP 的收入则下降为 0.25%。若要开启收费机制，社区必须通过治理投票。协议收费机制在 V2 一直处于关闭状态，却在 Uniswap V3 阶段被提议开启。
     * 社区内支持方观点认为，开启协议收费向代币持有者分红、充实协议金库、
     * 建立协议自身的流动性或资助开发等行为将更有利于 Uniswap 的长期发展。而反对方则认为，协议收费可能会埋下流动性大量外逃的隐患。
     * @param _reserve0 
     * @param _reserve1 
     */
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
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     * @return liquidity 增加流动性的数值
     * @param to  是接收流动性代币的地址
     * 通过同时注入两种代币资产来获取流动性代币
     * 用于用户提供流动性时(提供一定比例的两种ERC-20代币)增加流动性代币给流动性提供者
     * 
     * Question1:参数里为什么没有两个代币投入的数量呢?
     * Answer1:调用该函数之前，路由合约已经完成了将用户的代币数量划转到该配对合约
     * 
     * Question2：这里的lock有什么作用？
     * Answer2：保证了每次添加流动性时不会有多个用户同时往配对合约里转账，不然就没法计算用户的 amount0 和 amount1 了
     */
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        // 获取当前token0和token1的储备量（获取库存交易对的资产数量，也就是上个区块的数量）
        //getReserves()获取两种代币的缓存余额。在白皮书中提到，保存缓存余额是为了防止攻击者操控价格预言机。
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // balance0和balance1是流动性池中当前交易对的资产数量
        // 获取当前合约在token0合约内的余额，本次交易区块的数量
        uint balance0 = IERC20(token0).balanceOf(address(this));
        // 获取当前合约在token2合约内的余额，本次交易区块的数量
        uint balance1 = IERC20(token1).balanceOf(address(this));
        //获得当前balance和上一次缓存的余额的差值(当前区块和上一个区块缓存的数据)
        //因为此前路由合约已经将两个token转到了pair合约，所以这里直接拿余额减去储备量，就得到了这次要投入的token数量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        //计算手续费(目前没开开关)
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //这里的_totalSupply是LP代币也就是总的流动性代币
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        //计算用户能得到多少流动性代币
        if (_totalSupply == 0) {
            //第一次铸币，也就是第一次注入流动性，值为根号k减去MINIMUM_LIQUIDITY
            //如果_totalSupply为0，则说明是初次提供流动性，会根据恒定乘积公式的平方根来计算，同时要减去已经燃烧掉的初始流动性值，
            //具体为MINIMUM_LIQUIDITY；
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            //如果_totalSupply不为0，则会根据已有流动性按比例增发，由于注入了两种代币，所以会有两个计算公式，每种代币按注入比例计算流动性值，
            //取两个中的最小值。
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        //增发新的流动性给接收者,_update()更新流动性池中两种资产的值。
        _mint(to, liquidity);
        //更新实际余额，与缓存余额
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    //燃烧流动性代币来提取相应的两种资产，并减少交易对的流动性
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        //balance0和balance1获取交易对两种代币实际数量
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        //获取当前合约中流动性代币
        //此时用户的LP token已经被转移至合约地址，因此这里取合约地址中的LP Token余额就是等下要burn掉的量

        //解答：理论上合约地址是没有这个liquidity的，liquidity数值应该是提现在to地址也就是用户地址上，所以这里的liquidity值是由路由合约
        //因为路由合约会先把用户的流动性代币划转到该配对合约里。
        uint liquidity = balanceOf[address(this)];
        //计算手续费给开发团队
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //是存储当前已发行的LP流动性代币的总量（之所以写在feeOn后面，是因为在_mintFee()中会更新一次totalSupply值）
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        //分别计算用户发送的LP价值多少token0与token1
        //liquidity:用户持有的流动性  _totalSupply：池子所有的流动性
        //提取数量 = 用户流动性 / 总流动性 * 代币总余额
        //用户流动性除以总流动性就得出了用户在整个流动性池子里的占比是多少，再乘以代币总余额就得出用户应该分得多少代币了
        //amount0会大于balance0，因为balance0会因为提供流动性获取到交易费奖励
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        //将用户转入的流动性代币燃烧（通过燃烧代币得到方式来提取两种资产）
        _burn(address(this), liquidity);
        //将两种资产token转到对应的地址
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        //更新实际余额，与缓存余额
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 用于交易对中资产交易
    //amount0Out 和 amount1Out 表示兑换结果要转出的 token0 和 token1 的数量，这两个值通常情况下是一个为 0，一个不为 0，
    //但使用闪电交易时可能两个都不为 0。to 参数则是接收者地址，最后的 data 参数是执行回调时的传递数据，通过路由合约兑换的话，该值为 0。
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        //第一步先校验兑换结果的数量是否有一个大于 0，然后读取出两个代币的 reserve，之后再校验兑换数量是否小于 reserve。
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        //为了限制 _token{0,1} 这两个临时变量的作用域，防止堆栈太深导致错误。
        { // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            //安全发送_token0到to地址
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            //安全发送_token1到to地址
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            //闪电贷的功能~这里的msg.sender一般是路由合约
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            // 获取两个代币当前的余额 balance{0,1} ，这个余额是在上面扣减了转出代币后的余额。
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        //一般情况下用一个资产去swap另一个资产,amount0和amount1正常有一个不是0一个是0
        //通过当前余额和库存余额比较可得出汇入流动性池的资产数量
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // 强制储备量和余额平衡
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 将合约的储备金设置为当前余额
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
