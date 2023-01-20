// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./MerkleProof.sol";
import "./Ownable.sol";
import "./Address.sol";
import "./YeyeBase.sol";

contract ListedMint is Ownable {
    /* =============================================================
    * STATES
    ============================================================= */

    // Merkle Root for whitelist
    bytes32 public merkleRoot;
    // list of token ID to mint, make sure the ID is exist (Ticket ID)
    uint256[] public tokens;
    // count claimed token per address per batch
    mapping(uint => mapping(address => uint)) private claimed;
    // contract of token to be minted
    address public tokenContract;
    // token price
    uint public tokenPrice;
    // batch => supply
    mapping(uint => uint) private supply;
    // batch => minted
    mapping(uint => uint) private minted;

    // mint sale state
    uint public batch;
    bool public paused;
    uint private closedIn;
    bool public publicMint;

    // withdraw address
    address payable immutable public withdrawAddress;

    /* =============================================================
    * MODIFIER
    ============================================================= */

    modifier noContracts() {
        require(_msgSender() == tx.origin, "tx.origin != msg.sender");
        require(!Address.isContract(_msgSender()), "Contract calls are not allowed");
        _;
    }
    
    modifier isClosed {
        require(block.timestamp > closedIn, "Mint is not over yet");
        _;
    }
    modifier isNotClosed {
        require(block.timestamp <= closedIn, "Mint is over");
        _;
    }
    modifier isClosedOrPaused {
        require((block.timestamp > closedIn) || paused, "Mint is not over yet");
        _;
    }
    modifier isPaused {
        require(paused, "Mint is not paused");
        _;
    }
    modifier isNotPaused {
        require(!paused, "Mint is paused");
        _;
    }

    /* =============================================================
    * CONSTRUCTOR
    ============================================================= */

    constructor(address _tokenAddress, address payable _withdrawAddress) {
        tokenContract = _tokenAddress;
        withdrawAddress = _withdrawAddress;
    }

    /* =============================================================
    * SETTERS
    ============================================================= */

    /*
    * @dev set Merkle Root 
    */
    function setMerkleRoot(bytes32 newRoot) public onlyOwner isClosedOrPaused {
        merkleRoot = newRoot;
    }

    /*
    * @dev set Token Contract 
    */
    function setTokenContract(address newAddress) public onlyOwner isClosedOrPaused {
        tokenContract = newAddress;
    }

    /*
    * @dev set Token to sell 
    */
    function setToken(uint256[] calldata newIds) public onlyOwner isClosedOrPaused {
        YeyeBase baseContract = YeyeBase(tokenContract);
        for (uint i = 0; i < newIds.length; i++) 
        {
            (bool exist, bool redeemable, bool equipable) = baseContract.tokenCheck(newIds[i]);
            require(exist && redeemable && !equipable, "Invalid ticket IDs");
        }
        tokens = newIds;
    }

    /*
    * @dev set NFT price 
    */
    function setPrice(uint newPrice) public onlyOwner isClosedOrPaused {
        tokenPrice = newPrice;
    }

    /*
    * @dev add more tickets supply
    */
    function addSupply(uint _supply) public onlyOwner {
        supply[batch] += _supply;
    }

    /*
    * @dev cut tickets supply
    */
    function cutSupply(uint _supply) public onlyOwner {
        uint[2] memory current = getCurrentSupply();
        require(_supply <= (current[1] - current[0]), "Cannot cut supply below minted");
        supply[batch] -= _supply;
    }

    /* =============================================================
    * GETTERS
    ============================================================= */

    /*
    * @dev get time left of the current sale
    */
    function getTimeLeft() public view returns (uint _timeLeft) {
        _timeLeft = closedIn - block.timestamp;
    }

    /*
    * @dev get remaining supply of current batch
    */
    function getCurrentSupply() public view returns (uint[2] memory _supply) {
        _supply[0] = minted[batch];
        _supply[1] = supply[batch];
    }

    /*
    * @dev get claimed ticket for an account of current batch
    */
    function claimedTicket(address _account) public view returns (uint _claimed) {
        _claimed = claimed[batch][_account];
    }

    /* =============================================================
    * MAIN FUNCTION
    ============================================================= */

    /*
    * @dev pause Mint in case of emergency
    */
    function pause() public onlyOwner isNotClosed isNotPaused {
        paused = true;
    }

    /*
    * @dev unpause Mint in case of emergency
    */
    function unpause() public onlyOwner isNotClosed isPaused {
        paused = false;
    }

    /*
    * @dev add more time to extend sale duration
    */
    function addTime(uint hour) public onlyOwner {
        closedIn = block.timestamp + (hour * 1 hours);
    }

    /*
    * @dev listed mint function
    */
    function mint(bytes32[] calldata merkleProof, uint256 amount) public payable isNotClosed isNotPaused noContracts {
        if (!publicMint) {
            require(MerkleProof.verify(merkleProof, merkleRoot, toBytes32(_msgSender())) == true, "Not whitelisted!");
        }
        require(minted[batch] <= supply[batch], "Out of tickets!");
        require(msg.value >= (tokenPrice * amount), "Not enough ETH!");
        uint maxMint = tokens.length;
        uint _claimed = claimed[batch][_msgSender()];
        require((amount + _claimed) <= maxMint, string(abi.encodePacked("Remaining mint chance ", Strings.toString(maxMint - _claimed), " ticket")));

        minted[batch] += amount;
        claimed[batch][_msgSender()] += amount;

        YeyeBase mintContract = YeyeBase(tokenContract);
        for (uint i = _claimed; i < (_claimed + amount); i++) 
        {
            mintContract.mint(_msgSender(), tokens[i], 1, "0x00");
        }
    }

    /*
    * @dev Start new Mint Sale for next batch
    * Param :
    * - newRoot     = New Merkle Root
    * - ids         = List of token id (ids.length = max mint, so each address can buy one per NFT)
    * - price       = Token Price
    * - supply      = Token supply
    * - duration    = Duration of the sale (in hours)
    */
    function startNew(bytes32 _newRoot, uint256[] calldata _ids, uint _price, uint _supply, uint _duration) public onlyOwner isClosed {
        batch += 1;

        setMerkleRoot(_newRoot);
        setToken(_ids);
        setPrice(_price);
        supply[batch] = _supply;

        paused = false;
        closedIn = block.timestamp + (_duration * 1 hours);
    }

    /*
    * @dev Allow public to mint
    */
    function openPublicMint() public onlyOwner isNotClosed {
        publicMint = true;
    }

    /*
    * @dev Restrict public to mint
    */
    function closePublicMint() public onlyOwner isNotClosed {
        publicMint = false;
    }

    /*
    * @dev close sale immediately
    */
    function forceClose() public onlyOwner isNotClosed {
        closedIn = 0;
        paused = false;
    }

    /* =============================================================
    * OWNER AREA
    ============================================================= */

    /*
    * @dev Transfer funds to withdraw address
    */
    function withdrawAll() external onlyOwner {
        require(withdrawAddress != address(0), "Cannot withdraw to Address Zero");
        uint256 balance = address(this).balance;
        require(balance > 0, "there is nothing to withdraw");
        Address.sendValue(withdrawAddress, balance);
    }
    
    /* =============================================================
    * MISC
    ============================================================= */

    /*
    * @dev address to Bytes32 helper
    */
    function toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}