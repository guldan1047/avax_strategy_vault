// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "./basic/Basic.sol";
import "./interfaces/wavax/IWAVAX.sol";
import "./interfaces/IVault.sol";
import "./interfaces/aave/v3/ILendingPoolV3.sol";
import "./interfaces/aave/v3/IFlashLoanSimpleReceiver.sol";
import "./interfaces/benqi/IBenqiOracle.sol";
import "./interfaces/benqi/IComptroller.sol";
import "./interfaces/benqi/IQiToken.sol";
import "./interfaces/benqi/IQiAVAX.sol";
import "./interfaces/benqi/IMaximillion.sol";
import "./interfaces/platypus/IPlatypussavaxPoolRouter.sol";
import "./interfaces/pangolin/IPangolinRouter.sol";

contract StrategySAVAX is Basic, OwnableUpgradeable, IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWAVAX;

    address public immutable implementationAddress;

    address public constant savaxAddr = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address public constant qiAddr =  0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5;
    address public constant qiavaxAddr = 0x5C0401e81Bc07Ca70fAD469b451682c0d747Ef1c;
    address public constant qisavaxAddr = 0xF362feA9659cf036792c9cb02f8ff8198E21B4cB;

    address public constant oneInchAddr = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address public constant benqiUnitrollerAddr = 0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4;
    address public constant aaveLendingPoolV3Addr = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant pangolinRouterAddr = 0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106;
    address public constant qiMaximillionAddr = 0xd78DEd803b28A5A9C860c2cc7A4d84F611aA4Ef8;
    address public constant platypusSavaxPoolRouterAddr = 0x4658EA7e9960D6158a261104aAA160cC953bb6ba;

    IERC20 public constant SAVAX = IERC20(savaxAddr);
    IWAVAX public constant WAVAX = IWAVAX(wavaxAddr);
    IQiAVAX public constant QIAVAX = IQiAVAX(qiavaxAddr);
    IQiToken public constant QISAVAX = IQiToken(qisavaxAddr);

    // For flashLoan.
    address public executor;
    IComptroller public benqiComptroller;
    IPangolinRouter public pangolinRouter;

    bool public isDeprecated;
    address public vault;
    uint256 public constant PRECISION = 1e18;
    uint256 public marketCapacity;
    uint256 public constant liquidateColFactor = 0.75e18;
    uint256 public riskyColFactor;
    uint256 public targetColFactor;

    mapping(address => bool) public rebalancer;

    event Deposit(uint256 amount);
    event DepositSAVAX(uint256 amount);
    event Withdraw(uint256 shares);
    event WithdrawSAVAX(uint256 shares);
    event AddRebalancer(address rebalancer);
    event RemoveRebalancer(address rebalancer);
    event UpdateTargetColFactor(uint256 newColFactor);
    event UpdateRiskyFactor(uint256 newRiskyColRate);

    constructor() {
        implementationAddress = address(this);
    }

    modifier onlyVault() {
        require(vault == msg.sender, "!vault");
        _;
    }
    modifier onlyProxy() {
        require(address(this) != implementationAddress, "!proxy");
        _;
    }
    modifier whenNotDeprecated() {
        require(!isDeprecated, "Deprecated!");
        _;
    }
    modifier onlyAuth() {
        require(msg.sender == owner() || rebalancer[msg.sender], "!Auth");
        _;
    }
    modifier checkColFacterSafe() {
        _;
        require(currentColFactor() < riskyColFactor, "risky!");
    }

    function initialize(
        uint256 _marketCapacity,
        uint256 _riskyColFactor,    
        uint256 _targetColFactor,
        address[] memory _rebalancers
    ) public initializer onlyProxy {
        __Ownable_init();

        marketCapacity = _marketCapacity;   
        riskyColFactor = _riskyColFactor * 1e14;    //7500e14 = 0.75e18 = 75%
        targetColFactor = _targetColFactor * 1e14;    //6667e14 = 0.6667e18 = 66.67%
        if (_rebalancers.length != 0) {
            for (uint256 i = 0; i < _rebalancers.length; i++) {
                _addRebalancer(_rebalancers[i]);
            }
        }
        benqiComptroller = IComptroller(benqiUnitrollerAddr);
        pangolinRouter = IPangolinRouter(pangolinRouterAddr);

        _giveAllowances();
        _enterMarkets();   
    }

    function updateMarketCapacity(uint256 _newCapacityLimit)
        external
        onlyOwner
    {
        require(_newCapacityLimit > marketCapacity, "Unsupported!");
        marketCapacity = _newCapacityLimit;
    }

    function updateTargetColFactor(uint256 _newColRate) external onlyOwner {
        targetColFactor = _newColRate * 1e14;

        emit UpdateTargetColFactor(_newColRate);
    }

    function updateRebalancer(
        address[] calldata _rebalancers,
        bool[] calldata _isAllowed
    ) external onlyOwner {
        require(
            _rebalancers.length == _isAllowed.length && _isAllowed.length != 0,
            "Length mismatch!"
        );
        for (uint256 i = 0; i < _rebalancers.length; i++) {
            _isAllowed[i]
                ? _addRebalancer(_rebalancers[i])
                : _removeRebalancer(_rebalancers[i]);
        }
    }

    function _addRebalancer(address _newRebalancer) internal {
        require(!rebalancer[_newRebalancer], "Already exists!");
        rebalancer[_newRebalancer] = true;

        emit AddRebalancer(_newRebalancer);
    }

    function _removeRebalancer(address _delRebalancer) internal {
        require(rebalancer[_delRebalancer], "Does not exists!");
        rebalancer[_delRebalancer] = false;

        emit RemoveRebalancer(_delRebalancer);
    }

    function beforeDepositOrWithdraw() external onlyVault whenNotDeprecated{
        claimBenqiRewardsAndSupply(true);
    }

    function depositSAVAX(uint256 _amount)
        external
        onlyVault
        whenNotDeprecated
    {
        require(_amount > 0, "Deposit amount is zero!");
        SAVAX.safeTransferFrom(vault, address(this), _amount);
        uint256 depositValueInBenqiAvax_ = _amount * getBenqiExchangeRate() / PRECISION;
        require(
            depositValueInBenqiAvax_ + balanceOfOnBenqi() <= marketCapacity,
            "Over cap limit"
        );

        QISAVAX.mint(_amount);
        emit DepositSAVAX(_amount);
    }

    /// @dev claim QI and AVAX rewards in Benqi, and swap QI -> AVAX, then swap all AVAX -> SAVAX and supply to Benqi.
    function claimBenqiRewardsAndSupply(bool _isSupply) public {
        uint256 avaxBefore_ = address(this).balance;
        //claim QI, AVAX rewards
        benqiComptroller.claimReward(0, address(this));
        benqiComptroller.claimReward(1, address(this));
        uint256 qiBalance_ = IERC20(qiAddr).balanceOf(address(this));
        if(qiBalance_ > 0){
            address[] memory path_ = new address[](2);
            path_[0] = qiAddr;
            path_[1] = wavaxAddr;
            //swap QI -> AVAX
            pangolinRouter.swapExactTokensForAVAX(qiBalance_, 0, path_, address(this), block.timestamp);
        }

        uint256 totalRewardsInAVAX_ = address(this).balance - avaxBefore_;
        uint256 performanceFee_ = totalRewardsInAVAX_ * IVault(vault).performanceFeeRate() / PRECISION;
        if(performanceFee_ > 0){
            safeTransferAVAX(IVault(vault).feeReceiver(), performanceFee_);
            totalRewardsInAVAX_ -= performanceFee_;
            IVault(vault).accPerformanceFee(performanceFee_);
        }

        if(_isSupply && totalRewardsInAVAX_ > 0){
            //1. no debt yet, swap to savax and supply
            uint256 debt_ = QIAVAX.borrowBalanceCurrent(address(this));
            if(totalRewardsInAVAX_ < debt_) 
                QIAVAX.repayBorrow{value: totalRewardsInAVAX_}();
            else {
                //2. repay all debt, supply left
                IMaximillion(qiMaximillionAddr).repayBehalf{value: debt_}(address(this));
                //supply left
                if(address(this).balance > avaxBefore_){
                    uint256 savaxBefore_ = SAVAX.balanceOf(address(this));
                    //swap AVAX -> SAVAX 
                    _swap(true, address(this).balance - avaxBefore_);
                    //supply savax to Benqi.
                    if(SAVAX.balanceOf(address(this)) - savaxBefore_ > 0)
                        QISAVAX.mint(SAVAX.balanceOf(address(this)) - savaxBefore_);
                }
            }
        }
    }

    function _swap(bool isToSAVAX, uint256 _amount) internal {
        isToSAVAX ? 
            IPlatypussavaxPoolRouter(platypusSavaxPoolRouterAddr).swapFromETH{value: _amount}(
                savaxAddr,
                0,
                address(this),
                block.timestamp
            )
            :
            IPlatypussavaxPoolRouter(platypusSavaxPoolRouterAddr).swapToETH(
                    savaxAddr,
                    _amount,
                    0,
                    address(this),
                    block.timestamp
                );
    }

    /// @dev rebalance for admins to trigger
    function rebalance(bytes calldata _swapData) 
        external 
        onlyAuth 
        whenNotDeprecated
        checkColFacterSafe
    {
        (
            bool needRebalance_,
            bool isLeverage_,
            uint256 loanWavaxAmount_, 
            ,    
            uint256 redeemSavaxAmountToRepayLoan_,  
            ,
        ) = getRebalanceData();

        claimBenqiRewardsAndSupply(true);

        if(needRebalance_) {
            isLeverage_ 
                ? _doLeverage(loanWavaxAmount_, _swapData) 
                : _doDeLeverage(redeemSavaxAmountToRepayLoan_, loanWavaxAmount_, _swapData);
        }
    }

    /// @dev Withdraw AVAX
    function withdraw(uint256 _shareFactor, bytes memory _swapData)
        external
        onlyVault
        whenNotDeprecated
        checkColFacterSafe
        returns (uint256 avaxGet)
    {
        require(_shareFactor > 0, "Invalid shareFactor");

        (avaxGet,) = _withdrawInternal(_shareFactor, true, _swapData);
        safeTransferAVAX(vault, avaxGet);

        emit Withdraw(_shareFactor);
    }

    /// @dev Withdraw SAVAX
    function withdrawSAVAX(uint256 _shareFactor, bytes memory _swapData)
        external
        onlyVault
        whenNotDeprecated
        checkColFacterSafe
        returns (uint256 avaxGet, uint256 savaxGet)
    {
        require(_shareFactor > 0, "Invalid shareFactor");

        (avaxGet, savaxGet) = _withdrawInternal(_shareFactor, false, _swapData);
        safeTransferAVAX(vault, avaxGet);

        emit WithdrawSAVAX(_shareFactor);
    }

    /// @dev avoid stack too deep
    struct WithdrawLocalData {
        uint256 avaxBalanceBefore;
        uint256 savaxBalanceBefore;
        uint256 totalDebt;
        uint256 totalColInBenqiAvax;
        uint256 totalColSavax;
    }

    /// @dev Withdrawing assets.
    function _withdrawInternal(uint256 _shareFactor, bool _isAvax, bytes memory _swapData)
        internal
        returns (uint256 avaxGet, uint256 savaxGet)
    {
        WithdrawLocalData memory localData;
        (
            localData.totalColInBenqiAvax, 
            localData.totalColSavax, 
            ,
        ) = poolAccountData();

        localData.avaxBalanceBefore = address(this).balance;
        localData.savaxBalanceBefore = SAVAX.balanceOf(address(this));
        localData.totalDebt = QIAVAX.borrowBalanceCurrent(address(this));

        //no debt, simply redeem savax
        if(localData.totalDebt == 0 && localData.totalColSavax > 0){
            uint256 redeemSavaxAmount_ = localData.totalColSavax * _shareFactor / PRECISION;
            QISAVAX.redeemUnderlying(redeemSavaxAmount_);
            //swap savax -> avax
            if(_isAvax){
                //most use 1inch
                (bool success_, bytes memory returnData_) = oneInchAddr.call(_swapData);
                require(success_, string(returnData_));
                uint256 savaxLeft_ = SAVAX.balanceOf(address(this)) - localData.savaxBalanceBefore;
                //left use platypus
                if(savaxLeft_ > 0)
                    _swap(false, savaxLeft_);

                avaxGet = address(this).balance - localData.avaxBalanceBefore;
            }
            else
                savaxGet = SAVAX.balanceOf(address(this)) - localData.savaxBalanceBefore;
        }
        else if(localData.totalDebt > 0) {
            //need flashloan and de-leverage
            uint256 needLoan_ = localData.totalDebt * _shareFactor / PRECISION;
            uint256 needRedeemSavax_ = localData.totalColSavax * _shareFactor / PRECISION;

            bytes memory callbackData_ = abi.encode(
                false,   //isLeverage
                needRedeemSavax_,
                _isAvax,   //swap all redeemed SAVAX to AVAX
                _swapData
            );

            //flashloan, repay, redeem, swap all or partial savax -> avax
            executeFlashLoan(wavaxAddr, needLoan_, callbackData_);

            //unwrap left wavax
            if(WAVAX.balanceOf(address(this)) > 0)
                WAVAX.withdraw(WAVAX.balanceOf(address(this)));

            avaxGet = address(this).balance > localData.avaxBalanceBefore ? address(this).balance - localData.avaxBalanceBefore : 0;
            savaxGet = SAVAX.balanceOf(address(this)) > localData.savaxBalanceBefore ? SAVAX.balanceOf(address(this)) - localData.savaxBalanceBefore : 0;
        }
    }

    // Query withdraw swap data
    function getEstimateSwapAmountWhenWithdraw(uint256 _shares, bool _isAvax) external view returns(uint256 swapAmount){
        uint256 _shareFactor = IVault(vault).totalSupply() == 0 ? 0 : _shares * PRECISION / IVault(vault).totalSupply();
        require(_shareFactor > 0 && _shareFactor <= PRECISION, "Invalid share amount");

        (, uint256 totalColSavax_, uint256 totalDebt_, ) = poolAccountData();

        //include qi,avax pending rewards
        uint256 qiRewards_ = benqiComptroller.rewardAccrued(0, address(this));
        uint256 avaxRewards_ = benqiComptroller.rewardAccrued(1, address(this));
        address[] memory path_ = new address[](2);
        path_[0] = qiAddr;
        path_[1] = wavaxAddr;
        if(qiRewards_ > 0)
            avaxRewards_ += pangolinRouter.getAmountsOut(qiRewards_, path_)[1];
        if(avaxRewards_ > 0){
            //exclude performance fee
            uint256 performanceFee_ = avaxRewards_ * IVault(vault).performanceFeeRate() / PRECISION;
            if(performanceFee_ > 0)
                avaxRewards_ -= performanceFee_;

            totalColSavax_ += avaxRewards_ * PRECISION / getBenqiExchangeRate();
        }

        //when withdraw savax, swap partial savax to avax just for repay loan+fee
        if(_isAvax)
            swapAmount = totalColSavax_ * _shareFactor / PRECISION;
        else if (totalDebt_ > 0){
            uint256 loanAndFee_ = totalDebt_ * _shareFactor * 1.0005e18 / 1e36;
            swapAmount = loanAndFee_ * 1.05e18 / getBenqiExchangeRate();
        } 
    }

    /// @dev Use Benqi oracle to get the savax/avax rate in Benqi.
    function getBenqiExchangeRate() public view returns (uint256 rate) {
        uint256 savaxPriceInUsd_ = getPrice(qisavaxAddr);
        uint256 avaxPriceInUsd_ = getPrice(qiavaxAddr);
        require(savaxPriceInUsd_ != 0 && avaxPriceInUsd_ != 0, "Benqi oracle error");
        rate = savaxPriceInUsd_ * PRECISION / avaxPriceInUsd_;
    }

    /// @dev Get the account data of the pool.
    function poolAccountData()
        public
        view
        returns (
            uint256 colInBenqiAvax,
            uint256 colSavax,
            uint256 debtInAvax,
            uint256 colFactor
        )
    {
        //get savax supplied value in usd
        (, uint256 qisavaxBal_, , uint256 qisavaxRate_) = QISAVAX.getAccountSnapshot(
            address(this)
        );
        colSavax = qisavaxBal_ * qisavaxRate_ / PRECISION;
        colInBenqiAvax = colSavax * getBenqiExchangeRate() / PRECISION;
        
        //get avax borrowed value in usd
        (, , debtInAvax,) = QIAVAX.getAccountSnapshot(
            address(this)
        );

        colFactor = debtInAvax == 0 ? 0 : debtInAvax * PRECISION / colInBenqiAvax;   
    }

    /// @dev TVL of this pool, in benqi oracle
    function balanceOfOnBenqi() public view returns (uint256) {
        (uint256 colInBenqiAvax_, ,uint256 debtInAvax_, ) = poolAccountData();
        return colInBenqiAvax_ > debtInAvax_ ? colInBenqiAvax_ - debtInAvax_ : 0;
    }

    /// @dev Get the collateral factor of this pool.
    function currentColFactor() public view returns (uint256 colFactor) {
        (,,,colFactor) = poolAccountData();
    }

    function getPrice(address qiTokenAddr) public view returns(uint256){
        return IBenqiOracle(benqiComptroller.oracle()).getUnderlyingPrice(qiTokenAddr);
    }

    struct LoanData{
        uint256 _a;
        uint256 _b;
    }

    function getRebalanceData() 
        public
        view 
        returns (  
            bool needRebalance,
            bool isLeverage,
            uint256 loanWavaxAmount, 
            uint256 borrowAvaxAmountToRepayLoan,    
            uint256 redeemSavaxAmountToRepayLoan,  
            uint256 swapAmount,
            address swapFromToken
        ) 
    {
        PoolData memory poolData;
        LoanData memory loanData;
        (poolData.colInBenqiAvax,, poolData.debtAvax,) = poolAccountData();

        //include pending rewards
        uint256 qiRewards_ = benqiComptroller.rewardAccrued(0, address(this));
        uint256 avaxRewards_ = benqiComptroller.rewardAccrued(1, address(this));
        address[] memory path_ = new address[](2);
        path_[0] = qiAddr;
        path_[1] = wavaxAddr;
        if(qiRewards_ > 0)
            avaxRewards_ += pangolinRouter.getAmountsOut(qiRewards_, path_)[1];
        if(avaxRewards_ > 0){
            //exclude performance fee
            uint256 performanceFee_ = avaxRewards_ * IVault(vault).performanceFeeRate() / PRECISION;
            if(performanceFee_ > 0)
                avaxRewards_ -= performanceFee_;
            //calculate extimated TVL change
            poolData.colInBenqiAvax += avaxRewards_;
        }
        
        poolData.colFactor = poolData.debtAvax == 0 ? 0 : poolData.debtAvax * PRECISION / poolData.colInBenqiAvax;
        
        //need leverage
        if(poolData.colFactor < targetColFactor){
            needRebalance = true;
            isLeverage = true;
            loanData._a = targetColFactor * poolData.colInBenqiAvax / PRECISION - poolData.debtAvax;
            loanData._b = 1.0005e18 - targetColFactor;
            //ideal loan amount use benqi price
            loanWavaxAmount = loanData._a * PRECISION / loanData._b;  
            borrowAvaxAmountToRepayLoan = loanWavaxAmount * 1.0005e18 / PRECISION;
            swapFromToken = wavaxAddr;
            swapAmount = loanWavaxAmount;
        }
        else if(poolData.colFactor > targetColFactor){
            //need de-leverage
            needRebalance = true;
            loanData._a = poolData.debtAvax - targetColFactor * poolData.colInBenqiAvax / PRECISION;
            loanData._b = PRECISION - 1.0005e18 * targetColFactor / PRECISION;
            //ideal loan amount using benqi price
            loanWavaxAmount = loanData._a * PRECISION / loanData._b;
            redeemSavaxAmountToRepayLoan = 1.0005e18 * loanWavaxAmount * 1.05e18 / getBenqiExchangeRate() / PRECISION;
            swapFromToken = savaxAddr;
            swapAmount = redeemSavaxAmountToRepayLoan;
        }
    }

    struct PoolData {
        uint256 colInBenqiAvax;
        uint256 colSavax;
        uint256 debtAvax;
        uint256 colFactor;
    }

    function _doLeverage(
        uint256 _loanWavaxAmount,
        bytes memory _swapData
    ) internal {
        bytes memory callbackData_ = abi.encode(
            true,   //isLeverage
            0,  //redeem savax amount
            true,   //swap all redeemed SAVAX to AVAX
            _swapData
        );
        executeFlashLoan(wavaxAddr, _loanWavaxAmount, callbackData_);
    }

    function _doDeLeverage(
        uint256 _savaxAmountToRedeem,
        uint256 _loanWavaxAmount,
        bytes memory _swapData
    ) internal {
        uint256 avaxBefore_ = address(this).balance;

        bytes memory callbackData_ = abi.encode(
            false,  //isLeverage
            _savaxAmountToRedeem,
            true,   //swap all redeemed SAVAX to AVAX
            _swapData
        );

        executeFlashLoan(wavaxAddr, _loanWavaxAmount, callbackData_);

        // after reapy flashloan and fee, unwrap left WAVAX -> AVAX 
        if(WAVAX.balanceOf(address(this)) > 0)
            WAVAX.withdraw(WAVAX.balanceOf(address(this)));

        uint256 debtInAvax_ = QIAVAX.borrowBalanceCurrent(address(this));
        uint256 savaxBefore_ = SAVAX.balanceOf(address(this));
        uint256 surplusAvax_ = address(this).balance - avaxBefore_;

        // left avax repay debt or swap to savax and supply back to Benqi
        if(debtInAvax_ > 0 && surplusAvax_ > 0){
            //all avax left repay debt
            if(surplusAvax_ < debtInAvax_)
                QIAVAX.repayBorrow{value: surplusAvax_}();
            else{
                //partial avax repay all debt
                IMaximillion(qiMaximillionAddr).repayBehalf{value: debtInAvax_}(address(this));
                surplusAvax_ -= debtInAvax_;
                //swap left avax to savax and supply back
                if(surplusAvax_ > 0){
                    _swap(true, surplusAvax_);
                    QISAVAX.mint(SAVAX.balanceOf(address(this)) - savaxBefore_);
                }
            }
        }
    }

    function doLiquidate(bytes memory _swapData) external onlyOwner {
        _doFinalLiquidate(_swapData);
    }

    function _doFinalLiquidate(bytes memory _swapData) internal {
        isDeprecated = true;

        //get qisavax snapshot
        (, uint256 savaxAmountToRedeem_, ,) = poolAccountData();
        uint256 avaxDebtAmount_ = QIAVAX.borrowBalanceCurrent(address(this));

        bytes memory callbackData_ = abi.encode(false, savaxAmountToRedeem_, true, _swapData);
        uint256 loanAmount_ = avaxDebtAmount_ * 1.0005e18 / PRECISION;
        executeFlashLoan(wavaxAddr, loanAmount_, callbackData_);

        if(WAVAX.balanceOf(address(this)) > 0)
            WAVAX.withdraw(WAVAX.balanceOf(address(this)));

        claimBenqiRewardsAndSupply(false);
    }

    function executeFlashLoan(
        address _token, //wavax
        uint256 _amount,
        bytes memory _callbackData
    ) internal {
        executor = msg.sender;
        ILendingPoolV3(aaveLendingPoolV3Addr).flashLoanSimple(address(this), _token, _amount, _callbackData, uint16(0));
    }

    //receive flashloan and do leverage/deleverage
    function executeOperation(
        address _loanAsset, //wavax
        uint256 _loanAmount,
        uint256 _loanFee,   //0.05% wavax
        address _initiator, //strategy
        bytes calldata _callbackData
    ) external  override returns (bool){
        require(
            msg.sender == aaveLendingPoolV3Addr && 
            executor != address(0) && 
            _loanAsset == wavaxAddr &&
            _initiator == address(this),
            "Invalid flashloan call!"
        );
        (
            bool isLeverage_,
            uint256 amount_, //when de-leverage : redeemSavax amount_
            bool swapAll_,
            bytes memory swapData_
        ) = abi.decode(_callbackData, (bool, uint256, bool, bytes));
        
        if (isLeverage_) {
            _leverageCallback(_loanAmount, _loanFee, swapData_);
        } else {
            _deleverageCallback(_loanAmount, _loanFee, amount_, swapAll_, swapData_);
        }
        executor = address(0);

        require(WAVAX.balanceOf(address(this)) >= _loanAmount + _loanFee, "Wavax not enough to repay flashloan");

        return true;
    }

    function _leverageCallback(
        uint256 _loanWavaxAmount,
        uint256 _loanFee,   //0.05%
        bytes memory _swapData
    ) internal {
        uint256 wavaxBefore_ = WAVAX.balanceOf(address(this));
        uint256 savaxBefore_ = SAVAX.balanceOf(address(this));

        //most of WAVAX -> SAVAX use 1inch
        (bool success_, bytes memory returnData_) = oneInchAddr.call(_swapData);
        require(success_, string(returnData_));

        //left WAVAX -> AVAX -> SAVAX use platypus
        if(wavaxBefore_ - WAVAX.balanceOf(address(this)) < _loanWavaxAmount){
            uint256 leftWavax_ = _loanWavaxAmount + WAVAX.balanceOf(address(this)) - wavaxBefore_;
            WAVAX.withdraw(leftWavax_);
            _swap(true, leftWavax_);
        }

        QISAVAX.mint(SAVAX.balanceOf(address(this)) - savaxBefore_);
        QIAVAX.borrow(_loanWavaxAmount + _loanFee);
        WAVAX.deposit{value: _loanWavaxAmount + _loanFee}();
    }

    function _deleverageCallback(
        uint256 _loanAmount,
        uint256 _loanFee,   //0.05%
        uint256 _savaxAmountToRedeem,
        bool _swapAll,
        bytes memory _swapData
    ) internal {
        uint256 avaxBefore_ = address(this).balance;
        uint256 savaxBefore_ = SAVAX.balanceOf(address(this));

        WAVAX.withdraw(_loanAmount);
        
        uint256 realDebt = QIAVAX.borrowBalanceCurrent(address(this));

        //repay all AVAX debt and redeem all SAVAX
        if(_loanAmount >= realDebt)
        {   
            IMaximillion(qiMaximillionAddr).repayBehalf{value: realDebt}(address(this));
            (, uint256 qiBal_, ,uint256 rate_) = QISAVAX.getAccountSnapshot(address(this));
            _savaxAmountToRedeem = qiBal_ * rate_ / PRECISION;
        }
        else {
            // repay partial debt
            QIAVAX.repayBorrow{value: _loanAmount}();
        }

        QISAVAX.redeemUnderlying(_savaxAmountToRedeem); 

        //most of SAVAX -> AVAX use 1inch
        (bool success_, bytes memory returnData_) = oneInchAddr.call(_swapData);
        require(success_, string(returnData_));

        //if rebalance or liquidate or withdraw avax, all left SAVAX -> AVAX use platypus
        if(_swapAll && SAVAX.balanceOf(address(this)) - savaxBefore_ > 0)
            _swap(false, SAVAX.balanceOf(address(this)) - savaxBefore_);
        else if(!_swapAll){
            //if withdraw savax, swap partial savax -> avax just for repay loan+fee
            if(address(this).balance - avaxBefore_ < _loanAmount + _loanFee){
                uint256 needAvax_ = _loanAmount + _loanFee + avaxBefore_ - address(this).balance;
                uint256 needSwapSavax_ = needAvax_ * PRECISION / getBenqiExchangeRate();
                //swap 5% more to ensure cover loan and fee
                _swap(false, needSwapSavax_ * 1.05e18 / PRECISION); 
            }
        }

        //wrap
        WAVAX.deposit{value: address(this).balance - avaxBefore_}();
    }

    // for test : change col rate for rebalance
    function goToTargetLTV(uint256 _targetColFactor) public payable {
        if(_targetColFactor == 0) return;

        (uint256 colInBenqiAvax,,uint256 debtInAvax, uint256 colFactor) = poolAccountData();
        //need redeem savax to increase colRate
        if(_targetColFactor > colFactor){
            uint256 needDedeemAvax = (colInBenqiAvax * _targetColFactor - debtInAvax * PRECISION) / _targetColFactor;
            uint256 needRedeemSavax = needDedeemAvax * PRECISION / getBenqiExchangeRate();
            uint256 beforeSavax = SAVAX.balanceOf(address(this));
            QISAVAX.redeemUnderlying(needRedeemSavax);
            uint256 savaxGet = SAVAX.balanceOf(address(this)) - beforeSavax;
            require(savaxGet > 0, "Redeem SAVAX failed.");

            SAVAX.safeTransfer(0x316aE55EC59e0bEb2121C0e41d4BDef8bF66b32B, savaxGet);
        }
        else if(_targetColFactor < colFactor){
            //need supply more to decrease colRate
            uint256 needSupplySavax = (debtInAvax * PRECISION - colInBenqiAvax * _targetColFactor) / _targetColFactor;

            uint256 beforeSavax = SAVAX.balanceOf(address(this));
            SAVAX.safeTransferFrom(0x77905972FBAa90Bf98A8C5cab3ED7703BBb82414, address(this), needSupplySavax);
            uint256 savaxGet = SAVAX.balanceOf(address(this)) - beforeSavax;

            QISAVAX.mint(savaxGet);
        }

    }

    function endWithdraw(uint256 _shareFactor)
        external
        onlyVault
        returns (uint256 avaxAmount)
    {
        require(isDeprecated, "!Deprecated");
        avaxAmount = (_shareFactor * address(this).balance) / PRECISION;
        safeTransferAVAX(vault, avaxAmount);
    }

    function _giveAllowances() internal {
        SAVAX.safeApprove(qisavaxAddr, type(uint256).max);
        SAVAX.safeApprove(oneInchAddr, type(uint256).max);
        SAVAX.safeApprove(platypusSavaxPoolRouterAddr, type(uint256).max);
        QISAVAX.approve(qisavaxAddr, type(uint256).max);

        WAVAX.safeApprove(oneInchAddr, type(uint256).max);
        WAVAX.safeApprove(aaveLendingPoolV3Addr, type(uint256).max);

        IERC20(qiAddr).safeApprove(pangolinRouterAddr, type(uint256).max);
    }

    function _enterMarkets() internal {
        address[] memory qiTokens_ = new address[](1);
        qiTokens_[0] = qisavaxAddr;
        benqiComptroller.enterMarkets(qiTokens_);
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
        SAVAX.safeApprove(_vault, type(uint256).max);
    }

    function updateRiskyFactor(uint256 _newRiskyColRate) public onlyOwner {
        riskyColFactor = _newRiskyColRate * 1e14;

        emit UpdateRiskyFactor(_newRiskyColRate);
    }

    receive() external payable {}
}
