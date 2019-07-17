pragma solidity 0.5.10;

interface ERC20Interface {
    function totalSupply() external view returns (uint);
    function balanceOf(address tokenOwner) external view returns (uint balance);
    function allowance(address tokenOwner, address spender) external view returns (uint remaining);
    function transfer(address to, uint tokens) external returns (bool success);
    function approve(address spender, uint tokens) external returns (bool success);
    function transferFrom(address from, address to, uint tokens) external returns (bool success);
}

interface QueryInterface {
  enum QueryStatus { INVALID, OK, NOT_AVAILABLE, DISAGREEMENT }

  function query(bytes calldata input)
    external payable returns (bytes32 output, uint256 updatedAt, QueryStatus status);

  function queryPrice() external view returns (uint256);
}


contract NBAPrediction {

    bool public hasResolved = false;
    bool public isHomeWin = false;

    uint256 public predictionEndTime;
    uint256 public homeTeamTotalWeight;
    uint256 public awayTeamTotalWeight;
    bytes public eventKey;

    ERC20Interface public token;
    QueryInterface public oracle;

    //           who => betting amount
    mapping (address => uint256) bettingOnHomeTeam;
    mapping (address => uint256) bettingOnAwayTeam;

    constructor(
        bytes memory _eventKey,
        uint256 _predictionEndTime,
        ERC20Interface _token,
        QueryInterface _oracle
    ) public {
        eventKey = _eventKey;
        predictionEndTime = _predictionEndTime;
        token = _token;
        oracle = _oracle;
    }

    function bet(uint256 betAmount, bool isHome) public {
        require(now < predictionEndTime);
        require(betAmount > 0);
        require(bettingOnHomeTeam[msg.sender] == 0);
        require(bettingOnAwayTeam[msg.sender] == 0);

        require(token.transferFrom(msg.sender, address(this), betAmount));

        if (isHome) {
            bettingOnHomeTeam[msg.sender] = betAmount;
            homeTeamTotalWeight += betAmount;
        } else {
            bettingOnAwayTeam[msg.sender] = betAmount;
            awayTeamTotalWeight += betAmount;
        }
    }

    function resolve() public payable {
        require(now >= predictionEndTime);
        require(!hasResolved);

        (bytes32 rawData,, QueryInterface.QueryStatus status) = oracle.query.value(oracle.queryPrice())(eventKey);
        require(status == QueryInterface.QueryStatus.OK);

        uint8 homeScore = uint8(rawData[0]);
        uint8 awayScore = uint8(rawData[1]);

        isHomeWin = homeScore > awayScore;

        hasResolved = true;
    }

    function withdraw() public {
        require(hasResolved);
        require(bettingOnHomeTeam[msg.sender] > 0 || bettingOnAwayTeam[msg.sender] > 0);
        if (bettingOnHomeTeam[msg.sender] > 0 && isHomeWin) {
            uint256 withdrawAmount = (bettingOnHomeTeam[msg.sender]*(homeTeamTotalWeight+awayTeamTotalWeight))/homeTeamTotalWeight;
            require(token.transfer(msg.sender,withdrawAmount));
        } else if (bettingOnAwayTeam[msg.sender] > 0 && !isHomeWin) {
            uint256 withdrawAmount = (bettingOnAwayTeam[msg.sender]*(homeTeamTotalWeight+awayTeamTotalWeight))/awayTeamTotalWeight;
            require(token.transfer(msg.sender,withdrawAmount));
        }
        bettingOnHomeTeam[msg.sender] = 0;
        bettingOnAwayTeam[msg.sender] = 0;
    }
}