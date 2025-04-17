// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

// Импорты OpenZeppelin ниже используют ссылки на GitHub для совместимости с Remix IDE.
// При использовании локальной среды (например, Truffle) их можно заменить на локальные пути.
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.8.2/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.8.2/contracts/access/Ownable.sol";

contract AlphaChadToken is ERC20, Ownable {
    // Адрес для сжигания токенов (невосстанавливаемый)
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Налоговые кошельки
    address public taxWallet;
    address public liquidityWallet;

    // Карты для пар DEX и исключений
    mapping(address => bool) public isPair;
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) public isExcludedFromFees;
    mapping(address => address) public dexRouterByPair;

    // Налоговые ставки (в базисных пунктах, 100 = 1%)
    uint256 public buyTax = 200;               // 2.00%
    uint256 public sellTaxMarketing = 200;     // 2.00%
    uint256 public sellTaxLiquidity = 200;     // 2.00%
    uint256 public constant MAX_TAX = 1000;    // 10.00% максимум

    // Новые пределы динамических налогов
    uint256 public constant BUY_TAX_MIN = 200;    // 2%
    uint256 public constant BUY_TAX_MAX = 500;    // 5%
    uint256 public constant SELL_TAX_MIN_TOTAL = 400;   // 4% (суммарно)
    uint256 public constant SELL_TAX_MAX_TOTAL = 1000;  // 10% (суммарно)

    // Лимиты на транзакцию и кошелек
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;

    // Порог для свопа и добавления ликвидности
    uint256 public swapThreshold = 100_000 * 10**18;
    bool private swapping;

    // Анти-бот механизмы
    mapping(address => uint256) public lastTxTime;
    uint256 public txCooldown = 20;  // секунд
    bool public cooldownEnabled = true;

    // Черный список адресов
    mapping(address => bool) public isBlacklisted;

    // Новый механизм учета числа держателей
    mapping(address => bool) private isHolder;
    uint256 public holderCount;

    // Переменные для паузы и метаданных
    bool public paused = false;
    string public telegram = "https://t.me/AlphaChadToken";
    string public twitter = "https://twitter.com/AlphaChadToken";

    // Флаги/состояния
    bool public ownershipRenounced = false;

    // ===== Новые переменные для динамического налога =====
    uint256 public lastVolatilityUpdate;
    uint256 public tradeVolume10min;

    // ===== Новые переменные для вестинга команды =====
    address public teamWallet;
    uint256 public teamVestingAmount;
    uint256 public teamCliffEnd;
    uint256 public teamVestingEnd;
    uint256 public teamReleased;

    // ===== Новые переменные для вестинга эйрдропа =====
    uint256 public airdropReserve;
    struct AirdropVesting {
        uint256 totalAllocated;
        uint256 claimed;
        uint256 startTime;
    }
    mapping(address => AirdropVesting) public airdropVesting;

    // События (добавим новые для вестинга)
    event Paused(bool status);
    event MetadataUpdated(string telegram, string twitter);
    event BuyTaxUpdated(uint256 newBuyTax);
    event SellTaxMarketingUpdated(uint256 newSellTaxMarketing);
    event SellTaxLiquidityUpdated(uint256 newSellTaxLiquidity);
    event ExcludedFromFees(address indexed account, bool isExcluded);
    event ExcludedFromLimits(address indexed account, bool isExcluded);
    event MaxTxAmountUpdated(uint256 newMaxTxAmount);
    event MaxWalletAmountUpdated(uint256 newMaxWalletAmount);
    event TaxWalletUpdated(address newTaxWallet);
    event LiquidityWalletUpdated(address newLiquidityWallet);
    event BlacklistStatusChanged(address indexed account, bool isBlacklisted);
    event OwnershipRenounced(address previousOwner);
    // Новые события для вестинга:
    event TeamTokensClaimed(uint256 amount);
    event AirdropAllocated(address indexed recipient, uint256 amount);
    event AirdropTokensClaimed(address indexed recipient, uint256 amount);

    constructor() ERC20("AlphaChad Token", "ACT") {
        taxWallet = msg.sender;
        liquidityWallet = msg.sender;

        uint256 totalSupplyTokens = 69_000_000_000 * 10**decimals();
        // Момент выпуска: все токены временно на контракте
        _mint(address(this), totalSupplyTokens);

        // Установка лимитов транзакций/кошельков (1% и 2% от общего выпуска)
        maxTxAmount = totalSupplyTokens / 100;         // 1%
        maxWalletAmount = totalSupplyTokens * 2 / 100; // 2%

        // Исключаем владельца и контракт из ограничений и комиссий
        isExcludedFromLimits[msg.sender] = true;
        isExcludedFromFees[msg.sender] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromFees[address(this)] = true;

        // Вестинг команды:
        teamWallet = msg.sender;
        uint256 teamTotal = totalSupplyTokens * 10 / 100;    // 10% от выпуска
        uint256 teamImmediate = totalSupplyTokens * 1 / 100; // 1% сразу
        teamVestingAmount = teamTotal - teamImmediate;       // 9% на вестинге

        // Резервируем токены для эйрдропа:
        airdropReserve = totalSupplyTokens * 15 / 100;       // 15% от выпуска

        // Переводим мгновенную часть команды на teamWallet
        if (teamImmediate > 0) {
            super._transfer(address(this), teamWallet, teamImmediate);
        }
        // Настраиваем таймеры для командного вестинга
        teamCliffEnd = block.timestamp + 180 days;
        teamVestingEnd = teamCliffEnd + 180 days;
        teamReleased = 0;

        // (Оставшиеся 9% команды и 15% для эйрдропа остаются на контракте)
    }

    modifier notPaused() {
        require(!paused, "Transfers are paused");
        _;
    }

    // === Внешние функции токена ===

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function setSwapThreshold(uint256 amount) external onlyOwner {
        swapThreshold = amount;
    }

    function setMaxTxAmount(uint256 newAmount) external onlyOwner {
        maxTxAmount = newAmount;
        emit MaxTxAmountUpdated(newAmount);
    }

    function setMaxWalletAmount(uint256 newAmount) external onlyOwner {
        maxWalletAmount = newAmount;
        emit MaxWalletAmountUpdated(newAmount);
    }

    function setTxCooldown(uint256 seconds_) external onlyOwner {
        require(seconds_ <= 3600, "Cooldown cannot exceed 1 hour");
        txCooldown = seconds_;
    }

    function setCooldownEnabled(bool enabled) external onlyOwner {
        cooldownEnabled = enabled;
    }

    function blacklistAddress(address account, bool value) external onlyOwner {
        isBlacklisted[account] = value;
        emit BlacklistStatusChanged(account, value);
    }

    function setTaxWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address not allowed");
        taxWallet = newWallet;
        emit TaxWalletUpdated(newWallet);
    }

    function setLiquidityWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address not allowed");
        liquidityWallet = newWallet;
        emit LiquidityWalletUpdated(newWallet);
    }

    function setPair(address pair, bool value) external onlyOwner {
        require(pair != address(0), "Zero address not allowed");
        isPair[pair] = value;
    }

    function setPairRouter(address pair, address router) external onlyOwner {
        require(pair != address(0) && router != address(0), "Invalid address");
        dexRouterByPair[pair] = router;
    }

    function excludeFromLimits(address account, bool value) external onlyOwner {
        isExcludedFromLimits[account] = value;
        emit ExcludedFromLimits(account, value);
    }

    function excludeFromFees(address account, bool value) external onlyOwner {
        isExcludedFromFees[account] = value;
        emit ExcludedFromFees(account, value);
    }

    function setBuyTax(uint256 newBuyTax) external onlyOwner {
        require(newBuyTax <= MAX_TAX, "Buy tax too high");
        require(newBuyTax >= 10, "Buy tax too low");  // минимум 0.1%
        buyTax = newBuyTax;
        emit BuyTaxUpdated(newBuyTax);
    }

    function setSellTaxMarketing(uint256 newTax) external onlyOwner {
        require(newTax <= MAX_TAX, "Sell marketing tax too high");
        require(newTax >= 10, "Sell marketing tax too low");  // минимум 0.1%
        sellTaxMarketing = newTax;
        emit SellTaxMarketingUpdated(newTax);
    }

    function setSellTaxLiquidity(uint256 newTax) external onlyOwner {
        require(newTax <= MAX_TAX, "Sell liquidity tax too high");
        require(newTax >= 10, "Sell liquidity tax too low");  // минимум 0.1%
        sellTaxLiquidity = newTax;
        emit SellTaxLiquidityUpdated(newTax);
    }

    function setPause(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function updateSocialLinks(string calldata tg, string calldata tw) external onlyOwner {
        telegram = tg;
        twitter = tw;
        emit MetadataUpdated(tg, tw);
    }

    function renounceWhenReady() external onlyOwner {
        require(holderCount >= 10000, "Holder threshold not met");
        address prevOwner = owner();
        renounceOwnership();  // вызывает Ownable.OwnershipTransferred (owner -> 0x0)
        ownershipRenounced = true;
        emit OwnershipRenounced(prevOwner);
    }

    // Разрешаем контракту принимать ETH (например, от router при swap)
    receive() external payable {}

    // === Функции вестинга (команда и эйрдроп) ===

    function claimTeamTokens() external {
        require(msg.sender == teamWallet, "Not team wallet");
        require(block.timestamp >= teamCliffEnd, "Cliff not finished yet");
        uint256 amount;
        if (block.timestamp >= teamVestingEnd) {
            // После окончания вестинга отдаём всё, что осталось
            amount = teamVestingAmount - teamReleased;
        } else {
            // Линейный вестинг: пропорционально времени после клиффа
            uint256 vestingDuration = teamVestingEnd - teamCliffEnd;
            uint256 timeSinceCliff = block.timestamp - teamCliffEnd;
            uint256 unlocked = teamVestingAmount * timeSinceCliff / vestingDuration;
            amount = unlocked - teamReleased;
        }
        require(amount > 0, "No tokens to claim yet");
        teamReleased += amount;
        super._transfer(address(this), teamWallet, amount);
        emit TeamTokensClaimed(amount);
    }

    function allocateAirdrop(address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "Invalid address");
        require(airdropReserve >= amount, "Not enough airdrop tokens remaining");
        require(airdropVesting[recipient].totalAllocated == 0, "Airdrop already allocated");

        uint256 immediatePortion = amount * 20 / 100;
        uint256 vestingPortion = amount - immediatePortion;
        airdropReserve -= amount;
        // Сохраняем информацию о распределении
        airdropVesting[recipient] = AirdropVesting({
            totalAllocated: amount,
            claimed: immediatePortion,
            startTime: block.timestamp
        });
        // Отправляем 20% сразу
        super._transfer(address(this), recipient, immediatePortion);
        emit AirdropAllocated(recipient, amount);
    }

    function claimAirdropTokens() external {
        AirdropVesting storage vesting = airdropVesting[msg.sender];
        require(vesting.totalAllocated > 0, "No airdrop allocated");
        // Вычисляем долю разблокированных токенов по времени (20% + 10% * месяц)
        uint256 total = vesting.totalAllocated;
        uint256 immediate = total * 20 / 100;
        uint256 monthsPassed = (block.timestamp - vesting.startTime) / 30 days;
        if (monthsPassed > 8) {
            monthsPassed = 8;
        }
        uint256 unlockedPortion = total * (20 + 10 * monthsPassed) / 100;
        if (unlockedPortion > total) {
            unlockedPortion = total;
        }
        uint256 claimable = unlockedPortion - vesting.claimed;
        require(claimable > 0, "No new tokens to claim yet");
        vesting.claimed += claimable;
        super._transfer(address(this), msg.sender, claimable);
        emit AirdropTokensClaimed(msg.sender, claimable);
    }

    // === Внутренние функции ===

    function _transfer(address sender, address recipient, uint256 amount)
        internal
        override
        notPaused
    {
        require(!isBlacklisted[sender] && !isBlacklisted[recipient], "Blacklisted address");

        // Анти-бот задержка между транзакциями
        if (cooldownEnabled && sender != owner() && sender != address(this)) {
            require(block.timestamp > lastTxTime[sender] + txCooldown, "Cooldown active");
            lastTxTime[sender] = block.timestamp;
        }

        // Проверка лимитов на размер транзакции и баланс кошелька
        if (!isExcludedFromLimits[sender] && !isExcludedFromLimits[recipient]) {
            require(amount <= maxTxAmount, "Transfer exceeds max tx limit");
            require(balanceOf(recipient) + amount <= maxWalletAmount, "Recipient balance exceeds wallet limit");
        }

        // Дополнительный лимит: не больше 0.2% totalSupply за раз при продаже
        if (isPair[recipient] && !isExcludedFromLimits[sender]) {
            uint256 maxSale = totalSupply() * 2 / 1000;  // 0.2% от общего выпуска
            require(amount <= maxSale, "Sell amount exceeds 0.2% of total supply");
        }

        uint256 taxAmount = 0;
        uint256 marketingAmount = 0;
        uint256 liquidityAmount = 0;

        // === Динамический налог: обновление волатильности и налоговых ставок ===
        if (isPair[sender] || isPair[recipient]) {
            // Учитываем объём текущей сделки в статистике
            tradeVolume10min += amount;
            // Проверяем, пора ли пересчитывать налог (прошло >=10 минут)
            if (block.timestamp >= lastVolatilityUpdate + 10 minutes) {
                uint256 totalSupplyTokens = totalSupply();
                uint256 lowVolThreshold = totalSupplyTokens / 1000;  // 0.1% от supply
                uint256 highVolThreshold = totalSupplyTokens / 200;   // 0.5% от supply

                uint256 newBuyTaxBP;
                uint256 newSellTaxTotalBP;
                if (tradeVolume10min <= lowVolThreshold) {
                    newBuyTaxBP = BUY_TAX_MIN;
                    newSellTaxTotalBP = SELL_TAX_MIN_TOTAL;
                } else if (tradeVolume10min >= highVolThreshold) {
                    newBuyTaxBP = BUY_TAX_MAX;
                    newSellTaxTotalBP = SELL_TAX_MAX_TOTAL;
                } else {
                    uint256 volRange = highVolThreshold - lowVolThreshold;
                    uint256 volPercent = (tradeVolume10min - lowVolThreshold) * 10000 / volRange;
                    newBuyTaxBP = BUY_TAX_MIN + (volPercent * (BUY_TAX_MAX - BUY_TAX_MIN) / 10000);
                    newSellTaxTotalBP = SELL_TAX_MIN_TOTAL + (volPercent * (SELL_TAX_MAX_TOTAL - SELL_TAX_MIN_TOTAL) / 10000);
                }
                // Устанавливаем новые ставки налогов
                buyTax = newBuyTaxBP;
                sellTaxMarketing = newSellTaxTotalBP / 2;
                sellTaxLiquidity = newSellTaxTotalBP - sellTaxMarketing;
                lastVolatilityUpdate = block.timestamp;
                tradeVolume10min = 0;
            }
        }

        // Расчет налога на покупку/продажу, если адреса не освобождены от комиссии
        if (!isExcludedFromFees[sender] && !isExcludedFromFees[recipient]) {
            if (isPair[recipient]) {
                // Продажа: комиссия на маркетинг и ликвидность
                unchecked {
                    marketingAmount = amount * sellTaxMarketing / 10000;
                    liquidityAmount = amount * sellTaxLiquidity / 10000;
                    taxAmount = marketingAmount + liquidityAmount;
                }
            } else if (isPair[sender]) {
                // Покупка: комиссия на маркетинг
                unchecked {
                    taxAmount = amount * buyTax / 10000;
                }
                marketingAmount = taxAmount;
            }
        }

        // Если есть начисленный налог, распределяем его
        if (taxAmount > 0) {
            if (marketingAmount > 0) {
                super._transfer(sender, taxWallet, marketingAmount);
            }
            if (liquidityAmount > 0) {
                super._transfer(sender, address(this), liquidityAmount);
            }
            amount -= taxAmount;
        }

        // Авто-ликвидность: если контракт накопил достаточно токенов, добавляем ликвидность
        if (!swapping && isPair[recipient]) {
            uint256 contractTokenBalance = balanceOf(address(this));
            if (contractTokenBalance >= swapThreshold) {
                swapping = true;
                _swapAndLiquify(recipient, swapThreshold);
                swapping = false;
            }
        }

        // Сжигание 1% с каждой передачи (дефляция), кроме операций вестинга
        bool vestingTransfer = (sender == address(this) || recipient == address(this));
        if (vestingTransfer) {
            // Пропускаем дефляционное сжигание для выдачи из вестинга
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 burnAmount = amount / 100;
        uint256 sendAmount = amount - burnAmount;
        super._transfer(sender, DEAD, burnAmount);
        super._transfer(sender, recipient, sendAmount);
    }

    function _swapAndLiquify(address pair, uint256 tokenAmount) internal {
        address routerAddr = dexRouterByPair[pair];
        require(routerAddr != address(0), "Router not set for this pair");
        IRouter router = IRouter(routerAddr);

        // Разбиваем половину токенов для свопа в ETH, другая половина пойдет в ликвидность
        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;
        uint256 initialBalance = address(this).balance;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        // Одобряем токены для роутера и проводим своп токенов на ETH
        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half,
            0,
            path,
            address(this),
            block.timestamp
        );

        // Вычисляем полученный ETH и добавляем ликвидность (токены + ETH)
        uint256 newBalance = address(this).balance - initialBalance;
        router.addLiquidityETH{value: newBalance}(
            address(this),
            otherHalf,
            0,
            0,
            liquidityWallet,
            block.timestamp
        );
    }

    // Хук, вызываемый после каждой передачи (включая mint/burn), для обновления счетчика держателей
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        if (to != address(0) && to != DEAD && amount > 0 && !isHolder[to] && balanceOf(to) > 0) {
            isHolder[to] = true;
            holderCount += 1;
        }
        if (from != address(0) && from != DEAD && amount > 0 && isHolder[from] && balanceOf(from) == 0) {
            isHolder[from] = false;
            holderCount -= 1;
        }
    }
}

// Интерфейс роутера DEX для свопа и добавления ликвидности
interface IRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function WETH() external pure returns (address);
}

