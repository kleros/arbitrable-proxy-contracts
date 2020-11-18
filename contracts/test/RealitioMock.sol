pragma solidity >=0.7;

contract RealitioMock {

    address public arbitrator;
    bool public is_pending_arbitration;
    bytes32 public answer;
    bool private isRevealed;
    uint32 private reveal_ts;
    bytes32 private revealedAnswer;
    bytes32 private history_hash;

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "msg.sender must be arbitrator");
        _;
    }

    function setArbitrator(address _arbitrator) external {
        arbitrator = _arbitrator;
    }

    function notifyOfArbitrationRequest(bytes32 _question_id, address _requester, uint256 _max_previous) external onlyArbitrator() {
        is_pending_arbitration = true;
    }

    function submitAnswerByArbitrator(bytes32 _question_id, bytes32 _answer, address _answerer) external onlyArbitrator() {
        is_pending_arbitration = false;
        history_hash = keccak256(abi.encodePacked(history_hash, _answer, uint256(0), _answerer, false));
        answer = _answer;
    }

    // To simulate the answer submission.
    function addAnswerToHistory(bytes32 _answer_or_commitment_id, address _answerer, uint256 _bond, bool _is_commitment) external {
        history_hash = keccak256(abi.encodePacked(history_hash, _answer_or_commitment_id, _bond, _answerer, _is_commitment));
    }

    function setCommitment(bool _isRevealed, bytes32 _revealedAnswer) external {
        reveal_ts = uint32(block.timestamp + 10);
        isRevealed = _isRevealed;
        revealedAnswer = _revealedAnswer;
    }

    function commitments(bytes32 _commitmentID) external view returns (uint32, bool, bytes32) {
        return(
            reveal_ts,
            isRevealed,
            revealedAnswer
        );
    }

    function getHistoryHash(bytes32 _question_id) external view returns(bytes32) {
        return history_hash;
    }

    function toBytes(uint _a) external pure returns (bytes32) {
        return bytes32(_a);
    }
}