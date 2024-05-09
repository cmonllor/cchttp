//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTCP_Consumer} from "./interfaces/ICCTCP_Consumer.sol";

contract CCTCP_Host is OwnerIsCreator, CCIPReceiver {
    using SafeERC20 for IERC20;


    event NonRevertError(string message);
    
    enum CCTCP_Sement_Status{
        Untracked, // 0
        Sent, // 1
        Received, // 2
        Acknowledged, // 3
        ProcessedinDestination, // 4
        Retryed, // 5
        Failed // 6
    }

    enum CCTCP_Segment_Type{
        Data, // 0
        TkTx, // 1
        Ack, // 2
        Rty // 3
    }

    //PDU
    struct CCTCP_Segment {
        uint24 CCTCP_Seg_Id;
        CCTCP_Segment_Type CCTCP_Seg_Type;
        address CCIP_ops_token; // Linktoken
        uint256 CCIP_ops_amount; // Link_for_ack when send/receive//retry, link refund when ack
        bytes data;
    } //403 bytes + data

    //IDU = PDU + ICI 
    struct CCTCP_Segment_Status {
        CCTCP_Sement_Status CCTCP_Seg_Status;
        CCTCP_Segment CCTCP_Seg;
        address origWallet; //for link refunds after ack
        uint256 total_CCTCP_Token_amount;
        uint256 first_update;
        uint256 last_update;
        uint8 retry_count;
    }

    //CCIP SDU
    //PDU administred by Chainlink wich we don't control
    struct CCIP_Package {
        bytes32 CCIP_Package_Id;
        uint64 origChain;
        address origHost;
        uint64 destChain;
        address destHost;
        CCTCP_Segment data;
    }
    
    //IDU, probably will not be used in this version
    //but let's stick to Mr Tannembaum's principles
    struct CCIP_Package_Status {
        bytes32 CCIP_Pkg_Id;
        uint256 timestamp;
        address feeToken;
        uint256 feeAmount;
        CCIP_Package CCIP_Package;
    }


    //State vars
    uint64 public CCTCP_Host_ChainId;

    mapping (  uint64 chainId => address CCTCP_Host  ) public CCTCP_Hosts;
    
    //for this version we assume 1 Host per chain
    mapping (  uint64 chainId => mapping ( address CCTCP_Host => uint24 id )  ) public CCTCP_LastSegId;

    mapping (  uint64 chainId => mapping ( address CCTCP_Wallet => CCTCP_Segment CCTCP_Segment )  ) public lastSent_CCTCP_Segment;
    // CCTCP Segemnt Status
    mapping (  uint64 chainId => mapping ( address CCTCP_Host => mapping ( uint24 CCTCP_Seg_Id => CCTCP_Segment_Status CCTCP_Seg_Status ) )  ) public CCTCP_Segments;
    //Link token address
    address public default_CCIP_ops_token; 
    address public CCIP_router;


    modifier onlyCCTCP_Host(uint64 chainId, address CCTCP_PairHost) {
        require( (CCTCP_Hosts[chainId] == CCTCP_PairHost), "CCTCP_Host: Host not allowed" );
        _;
    }


    constructor (address _CCIP_router, address _default_CCIP_ops_token) CCIPReceiver(_CCIP_router) {
        CCIP_router = _CCIP_router;
        default_CCIP_ops_token = _default_CCIP_ops_token;
    }


    function add_CCTCP_PairHost(uint64 chainId, address CCTCP_PairHost) public onlyOwner {
        CCTCP_LastSegId[chainId][CCTCP_PairHost] = 1;
    }


    function _ccipReceive
    (
        Client.Any2EVMMessage memory message
    ) 
        internal 
        override 
        onlyRouter  
        onlyCCTCP_Host
        (
            message.sourceChainSelector,
            abi.decode(message.sender, (address))
        ) 
    {
        uint64 origChain = message.sourceChainSelector;
        address origHost = abi.decode(message.sender, (address));
        CCTCP_Segment memory _CCTCP_Segment = abi.decode(message.data, (CCTCP_Segment));

        if ( _CCTCP_Segment.CCTCP_Seg_Type == CCTCP_Segment_Type.Data ) {
            processDataSegment(origChain, origHost, _CCTCP_Segment);
        } else if ( _CCTCP_Segment.CCTCP_Seg_Type == CCTCP_Segment_Type.Ack ) {
            processAckSegment(origChain, origHost, _CCTCP_Segment);
        } else if ( _CCTCP_Segment.CCTCP_Seg_Type == CCTCP_Segment_Type.Rty ) {
            processRetryedMessage(origChain, origHost, _CCTCP_Segment);
        } else {
            emit NonRevertError("CCTCP_Host: Unknown CCTCP_Segment_Type");
        }       
    }


    function getFeesForMessage(
        uint64 destChain,
        address destHost,
        uint256 linkForAck,
        bytes memory data,
        address feeToken
    ) public view returns (uint256) {
        uint24 segId = CCTCP_LastSegId[destChain][destHost]+1;
        CCTCP_Segment memory _CCTCP_Segment = CCTCP_Segment(
            segId,
            CCTCP_Segment_Type.Data,
            default_CCIP_ops_token,
            linkForAck,
            data
        );
        Client.EVMTokenAmount[] memory _CCIP_ops = new Client.EVMTokenAmount[](1);
        
        _CCIP_ops[0] = Client.EVMTokenAmount(default_CCIP_ops_token, linkForAck);
        uint256 fees = IRouterClient(CCIP_router).getFee(
            destChain,
            Client.EVM2AnyMessage({
                receiver: abi.encode(destHost),
                data: abi.encode(_CCTCP_Segment),
                tokenAmounts: _CCIP_ops,
                extraArgs: Client._argsToBytes(  Client.EVMExtraArgsV1({ gasLimit:1_000_000 })  ),
                feeToken: feeToken
            })
        );
        return fees;
    }
    

    function sendMessage(
        uint64 destChain,
        address destHost,
        address origWallet,//where link will be refunded
        uint256 linkForAck,
        bytes memory data,
        address feeToken,
        uint256 feeAmount
    ) 
        onlyCCTCP_Host(destChain, destHost)
        public returns (bool) 
    {
        uint24 segId = CCTCP_LastSegId[destChain][origWallet]+1;
        CCTCP_Segment memory _CCTCP_Segment = CCTCP_Segment(
            segId,
            CCTCP_Segment_Type.Data,
            default_CCIP_ops_token,
            linkForAck,
            data
        );
        Client.EVMTokenAmount[] memory _CCIP_ops = new Client.EVMTokenAmount[](1);

        uint256 linkAmount;
        if( feeToken == default_CCIP_ops_token ) {
            linkAmount = linkForAck + feeAmount;
            IERC20(default_CCIP_ops_token).safeTransferFrom(msg.sender, address(this), linkAmount);
        } else {
            linkAmount = linkForAck;
            IERC20(default_CCIP_ops_token).safeTransferFrom(msg.sender, address(this), linkForAck);
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), feeAmount);
        }    

        _CCIP_ops[0] = Client.EVMTokenAmount(default_CCIP_ops_token, linkForAck);
        bytes32 CCIP_pkg_id;

        try IRouterClient(CCIP_router).ccipSend(
            destChain,
            Client.EVM2AnyMessage({
                receiver: abi.encode(destHost),
                data: abi.encode(_CCTCP_Segment),
                tokenAmounts: _CCIP_ops,
                extraArgs: Client._argsToBytes(  Client.EVMExtraArgsV1({ gasLimit:1_000_000 })  ),
                feeToken: feeToken
            })
        ) returns (bytes32 id ) {
            CCIP_pkg_id = id;
            //TODO: emit event
            lastSent_CCTCP_Segment[destChain][origWallet] = _CCTCP_Segment;
        } catch {
            emit NonRevertError("CCTCP_Host: Message not sent");
            return false;
        }

        CCTCP_LastSegId[destChain][destHost] = segId;
        CCTCP_Segments[destChain][destHost][segId] = CCTCP_Segment_Status(
            CCTCP_Sement_Status.Sent,
            _CCTCP_Segment,
            origWallet,            
            linkAmount,
            block.timestamp,
            block.timestamp,
            0
        );

        return true;
    }

    function retryMessage(
        uint64 destChain,
        address destHost,
        address origWallet,
        uint256 linkForAck,
        address feeToken,
        uint256 feeAmount
    ) public returns (bool) {
        CCTCP_Segment memory _CCTCP_Segment = lastSent_CCTCP_Segment[destChain][origWallet];
        uint24 segId = _CCTCP_Segment.CCTCP_Seg_Id;

        if( (CCTCP_Segments[destChain][destHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.ProcessedinDestination) 
            || (CCTCP_Segments[destChain][destHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Acknowledged)
        ){
            emit NonRevertError("CCTCP_Host: Mesasaage already processed");
            return false;
        }

        _CCTCP_Segment.CCTCP_Seg_Type = CCTCP_Segment_Type.Rty;
        _CCTCP_Segment.CCIP_ops_amount = _CCTCP_Segment.CCIP_ops_amount;
        Client.EVMTokenAmount[] memory _CCIP_ops = new Client.EVMTokenAmount[](1);

        _CCTCP_Segment.CCIP_ops_amount = linkForAck;
        uint256 linkAmount;
        if( feeToken == default_CCIP_ops_token ) {
            linkAmount = linkForAck + feeAmount;
            IERC20(default_CCIP_ops_token).safeTransferFrom(msg.sender, address(this), linkAmount);
            IERC20(default_CCIP_ops_token).approve(CCIP_router, linkAmount);
        } else {
            linkAmount = linkForAck;
            IERC20(default_CCIP_ops_token).safeTransferFrom(msg.sender, address(this), linkForAck);
            IERC20(default_CCIP_ops_token).approve(CCIP_router, linkForAck);
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), feeAmount);
            IERC20(feeToken).approve(CCIP_router, feeAmount);
        }

        _CCIP_ops[0] = Client.EVMTokenAmount(default_CCIP_ops_token, linkForAck);
        bytes32 CCIP_pkg_id;

        try IRouterClient(CCIP_router).ccipSend(
            destChain,
            Client.EVM2AnyMessage({
                receiver: abi.encode(destHost),
                data: abi.encode(_CCTCP_Segment),
                tokenAmounts: _CCIP_ops,
                extraArgs: Client._argsToBytes(  Client.EVMExtraArgsV1({ gasLimit:1_000_000 })  ),
                feeToken: feeToken
            })
        ) returns (bytes32 id ) {
            CCIP_pkg_id = id;
            //TODO: emit event
        } catch {
            emit NonRevertError("CCTCP_Host: Message not sent");
            return false;
        }
        

        return true;
    }

    function processDataSegment
    (
        uint64 origChain, 
        address origHost, 
        CCTCP_Segment memory _CCTCP_Segment
    ) internal  {
        uint24 segId = _CCTCP_Segment.CCTCP_Seg_Id;
        if(CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Untracked) {
            ICCTCP_Consumer(owner()).receiveMessage(
                origChain,
                _CCTCP_Segment.CCIP_ops_token,
                _CCTCP_Segment.CCIP_ops_amount,
                _CCTCP_Segment.data
            );

            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.Received;
            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg = _CCTCP_Segment;
            CCTCP_Segments[origChain][origHost][segId].first_update = block.timestamp;
            CCTCP_Segments[origChain][origHost][segId].last_update = block.timestamp;
            CCTCP_Segments[origChain][origHost][segId].retry_count = 0;
            CCTCP_Segments[origChain][origHost][segId].total_CCTCP_Token_amount = _CCTCP_Segment.CCIP_ops_amount;

            CCTCP_LastSegId[origChain][origHost] = segId + 1;



            //TODO: emit event
            if ( _CCTCP_Segment.CCIP_ops_amount > 0 ) {
                IERC20(_CCTCP_Segment.CCIP_ops_token).safeTransferFrom(msg.sender, address(this), _CCTCP_Segment.CCIP_ops_amount);
                if ( sendAck(origChain, origHost,  _CCTCP_Segment) == false ) {
                    emit NonRevertError("CCTCP_Host: Ack not sent");
                }
                else{
                    CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.Acknowledged;
                    CCTCP_Segments[origChain][origHost][segId].last_update = block.timestamp;
                    //TODO: emit event
                }
            }

        } else {
            emit NonRevertError("CCTCP_Host: Segment already received");
        }
    }

/*
    function processTokenTxSegment(uint64 origChain, address origHost, CCTCP_Segment memory _CCTCP_Segment) pure internal{
        //TODO
        revert("CCTCP_Host: processTokenTxSegment not implemented");
    }
*/

    function processAckSegment(uint64 origChain, address origHost, CCTCP_Segment memory _CCTCP_Segment) internal {
        uint24 segId = _CCTCP_Segment.CCTCP_Seg_Id;
        if( (CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Sent) 
            || (CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Retryed)
        ){
            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.ProcessedinDestination;
            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg = _CCTCP_Segment;
            CCTCP_Segments[origChain][origHost][segId].last_update = block.timestamp;

            address refundWallet = CCTCP_Segments[origChain][origHost][segId].origWallet;

            IERC20(_CCTCP_Segment.CCIP_ops_token).safeTransfer(refundWallet, _CCTCP_Segment.CCIP_ops_amount);

            ICCTCP_Consumer( owner() ).receiveMessage(
                origChain, 
                _CCTCP_Segment.CCIP_ops_token,
                _CCTCP_Segment.CCIP_ops_amount,
                _CCTCP_Segment.data
            );
        } else {
            emit NonRevertError("CCTCP_Host: Ack for non-sent segment");
        }
    }

    function processRetryedMessage(uint64 origChain, address origHost, CCTCP_Segment memory _CCTCP_Segment) internal {
        uint24 segId = _CCTCP_Segment.CCTCP_Seg_Id;
        if(
            (CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Untracked)
            || (CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status == CCTCP_Sement_Status.Received)        
        ){
            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.Received;
            CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg = _CCTCP_Segment;
            CCTCP_Segments[origChain][origHost][segId].first_update = block.timestamp;
            CCTCP_Segments[origChain][origHost][segId].last_update = block.timestamp;
            CCTCP_Segments[origChain][origHost][segId].retry_count++;
            CCTCP_Segments[origChain][origHost][segId].total_CCTCP_Token_amount += _CCTCP_Segment.CCIP_ops_amount;

            CCTCP_LastSegId[origChain][origHost] = segId + 1;

            //TODO: emit event
            if ( _CCTCP_Segment.CCIP_ops_amount > 0 ) {
                IERC20(_CCTCP_Segment.CCIP_ops_token).safeTransferFrom(msg.sender, address(this), _CCTCP_Segment.CCIP_ops_amount);
                if( sendAck(origChain, origHost,  _CCTCP_Segment) == false ) {
                    emit NonRevertError("CCTCP_Host: Retry Ack not sent");
                }
                else{
                    CCTCP_Segments[origChain][origHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.Acknowledged;
                    CCTCP_Segments[origChain][origHost][segId].last_update = block.timestamp;
                }
            }
        }
    }

    function sendAck
    (
        uint64 destChain, 
        address destHost, 
        CCTCP_Segment memory mssg
    ) public returns (bool) {
        uint24 segId = mssg.CCTCP_Seg_Id;
        uint256 linkForAck = mssg.CCIP_ops_amount;

        Client.EVMTokenAmount[] memory _CCIP_ops = new Client.EVMTokenAmount[](1);

        IERC20(default_CCIP_ops_token).safeTransferFrom(msg.sender, address(this), linkForAck);

        _CCIP_ops[0] = Client.EVMTokenAmount(default_CCIP_ops_token, linkForAck);
        bytes32 CCIP_pkg_id;

        IERC20(default_CCIP_ops_token).approve(CCIP_router, linkForAck);
        try IRouterClient(CCIP_router).ccipSend(
            destChain,
            Client.EVM2AnyMessage({
                receiver: abi.encode(destHost),
                data: abi.encode(mssg),
                tokenAmounts: _CCIP_ops,
                extraArgs: Client._argsToBytes(  Client.EVMExtraArgsV1({ gasLimit:1_000_000 })  ),
                feeToken: default_CCIP_ops_token
            })
        ) returns (bytes32 id ) {
            CCIP_pkg_id = id;
        }
        catch {
            emit NonRevertError("CCTCP_Host: Ack not sent");
            return false;
        }

        CCTCP_LastSegId[destChain][destHost] = segId;
        CCTCP_Segments[destChain][destHost][segId].CCTCP_Seg_Status = CCTCP_Sement_Status.Acknowledged;
        CCTCP_Segments[destChain][destHost][segId].last_update = block.timestamp;

        return true;
    }
}