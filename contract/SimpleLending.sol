
pragma solidity 0.5.10;

interface ERC20Interface {
    function totalSupply() external view returns (uint);
    function balanceOf(address tokenOwner) external view returns (uint balance);
    function allowance(address tokenOwner, address spender) external view returns (uint remaining);
    function transfer(address to, uint tokens) external returns (bool success);
    function approve(address spender, uint tokens) external returns (bool success);
    function transferFrom(address from, address to, uint tokens) external returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

interface QueryInterface {
  enum QueryStatus { INVALID, OK, NOT_AVAILABLE, DISAGREEMENT }

  function query(bytes calldata input)
    external payable returns (bytes32 output, uint256 updatedAt, QueryStatus status);
  function queryPrice(bytes calldata input)
    external view returns (uint256);
}

contract SimpleLending {

    uint256 public denominator = 1e18; // 1 scaled by 1e18
    uint256 public interestRate = 1e18 + 1e16; // 1.01 scaled by 1e18
    uint256 public liquidationRatio = 1e18 + 5e17;  // 1.5 scaled by 1e18
    uint256 public collateralRatio = 2;

    address public admin;
    address public oracle;

    struct LendingNote {
        address lender;
        address borrower;
        ERC20Interface asset;
        ERC20Interface assetBacked;
        uint256 assetAmount;
        uint256 assetBackedAmount;
        uint256 payOffAmount;
        uint256 startBorrowingDate;
        uint256 pastDays;
    }

    mapping(address => bytes) public supportedAssets; // token's address => token's symbol

    mapping(address => mapping(address => LendingNote) ) public Lending; // lender => asset => LendingNote

    constructor(address _oracle) public {
        admin = msg.sender;
        oracle = _oracle;
    }

    function concatBytes(bytes memory a, bytes memory b) internal pure returns(bytes memory c) {
        uint256 alen = a.length;
        uint256 totallen = alen + b.length;
        uint256 la = (a.length + 31) / 32;
        uint256 lb = (b.length + 31) / 32;
        assembly {
            let m := mload(0x40)
            mstore(m, totallen)
            for {  let i := 0 } lt(i, la) { i := add(1, i) } {
                mstore(add(m, mul(32, add(1, i))), mload(add(a, mul(32, add(1, i)))))
            }
            for {  let i := 0 } lt(i, lb) { i := add(1, i) } {
                mstore(add(m, add(mul(32, add(1, i)), alen)), mload(add(b, mul(32, add(1, i)))))
            }
            mstore(0x40, add(m, add(32, totallen)))
            c := m
        }
    }

    function isSupported(ERC20Interface asset) public view returns(bool) {
        return supportedAssets[address(asset)].length > 0;
    }

    function addSupportedAssets(ERC20Interface asset, bytes memory symbol) public {
        require(msg.sender == admin);
        require(symbol.length > 0);
        require(!isSupported(asset));

        supportedAssets[address(asset)] = symbol;
    }

    function getRate(ERC20Interface asset1, ERC20Interface asset2) internal returns (uint256) {
        require(isSupported(asset1));
        require(isSupported(asset2));
        bytes memory key =
        concatBytes(
            concatBytes(
                supportedAssets[address(asset1)],
                "/"
            ),
            supportedAssets[address(asset2)]
        );

        QueryInterface q = QueryInterface(oracle);
        (bytes32 rawRate,, QueryInterface.QueryStatus status) = q.query.value(q.queryPrice(key))(key);
        require(status == QueryInterface.QueryStatus.OK);
        return uint256(rawRate);
    }

    function deposit(uint256 amount, ERC20Interface asset) public {
        require(isSupported(asset));

        LendingNote storage ln = Lending[msg.sender][address(asset)];
        require(ln.lender == address(0));

        require(asset.transferFrom(msg.sender,address(this),amount));

        ln.lender = msg.sender;
        ln.asset = asset;
        ln.assetAmount = amount;
    }

    function withdraw(ERC20Interface asset) public {
        LendingNote memory ln = Lending[msg.sender][address(asset)];
        require(ln.borrower == address(0));

        require(ln.asset.transfer(msg.sender, ln.assetAmount));

        delete Lending[msg.sender][address(asset)];
    }

    function updatePayOff(address lender, ERC20Interface asset) public {
        LendingNote storage ln = Lending[lender][address(asset)];
        require(ln.lender == lender);
        require(ln.borrower != address(0));

        uint256 currentPastDays = (now - ln.startBorrowingDate) / 1 days;

        if (currentPastDays > ln.pastDays) {
            uint256 currentPayOff = ln.payOffAmount;
            for (uint256 i = ln.pastDays; i < currentPastDays; i++) {
                currentPayOff = (currentPayOff * interestRate) / denominator;
            }
            ln.payOffAmount = currentPayOff;
            ln.pastDays = currentPastDays;
        }
    }

    function borrow(
        address lender,
        ERC20Interface asset,
        ERC20Interface assetBacked,
        uint256 assetBackedAmount
    ) public {
        require(isSupported(asset));
        require(isSupported(assetBacked));

        LendingNote storage ln = Lending[lender][address(asset)];
        require(ln.lender == lender);
        require(ln.borrower == address(0));

        uint256 exchangeRate = getRate(asset,assetBacked);
        uint256 assetBackedAtRateAmount = ln.assetAmount * exchangeRate / denominator;

        require(assetBackedAmount >= assetBackedAtRateAmount * collateralRatio);
        require(assetBacked.transferFrom(msg.sender,address(this),assetBackedAmount));

        ln.borrower = msg.sender;
        ln.assetBacked = assetBacked;
        ln.assetBackedAmount = assetBackedAmount;
        ln.startBorrowingDate = now;
        ln.payOffAmount = ln.assetAmount * interestRate / denominator;
        ln.pastDays = 0;
    }

    function payOff(address lender, ERC20Interface asset) public {
        require(isSupported(asset));

        LendingNote storage ln = Lending[lender][address(asset)];

        require(ln.borrower == msg.sender);

        updatePayOff(lender,asset);

        require(asset.transferFrom(msg.sender,address(this),ln.payOffAmount));
        require(ln.assetBacked.transfer(msg.sender,ln.assetBackedAmount));

        ln.assetAmount = ln.payOffAmount;
        ln.borrower = address(0);
        ln.assetBacked = ERC20Interface(address(0));
        ln.assetBackedAmount = 0;
        ln.startBorrowingDate = 0;
        ln.payOffAmount = 0;
        ln.pastDays = 0;
    }

    function liquidate(ERC20Interface asset) public {
        require(isSupported(asset));

        LendingNote storage ln = Lending[msg.sender][address(asset)];

        updatePayOff(msg.sender,asset);

        uint256 exchangeRate = getRate(asset,ln.assetBacked);
        uint256 payOffassetBackedAmount = ln.payOffAmount * exchangeRate / denominator;

        require(ln.assetBackedAmount < payOffassetBackedAmount * liquidationRatio / denominator);

        require(ln.assetBacked.transfer(msg.sender,ln.assetBackedAmount));

        delete Lending[msg.sender][address(asset)];
    }

}
