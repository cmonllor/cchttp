//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICCTCP_Consumer} from "./interfaces/ICCTCP_Consumer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract CCHTTP_Peer is ICCTCP_Consumer, Ownable{
    using SafeERC20 for IERC20;

    enum CCHTTP_Primitive{
        REQUEST,
        INDICATION,
        CONFIRMATION
    }

    enum CCHTTP_Operation{
        GET,
        DEPLOY_AND_MINT,
        MINT,
        BURN,
        UPDATE_SUPPLY
    }

    enum CCHTTP_Message_Status{
        PENDING,
        SENT,
        RECEIVED,
        CONFIRMED,
        FAILED
    }

    struct deploy_and_mint_mssg{
        address user;
        string tokenName;
        string tokenSymbol;
        address expectedTokenAddress;
        uint24 decimals;
        uint256 amount;
        uint256 totalSupply;
    }

    struct mint_mssg{
        address token;
        address receiver;
        uint256 amount;
    }

    struct burn_mssg{
        address token;
        address sender;
        uint256 amount;
    }

    struct upd_total_supply_mssg{
        address token;
        uint256 amount;
    }
    
    struct CCHTTP_Message{
        CCHTTP_Operation operation;
        CCHTTP_Primitive primitive;
        address originUser;
        address destinationUser;
        bytes data;
    }

    struct CCHTTP_Message_Info{
        uint64 origChainId;
        address origHost;
        uint64 destChainId;
        address destHost;
        address linkToken;
        uint256 linkAmount;
        address feeToken;
        uint256 feesAmount;
        CCHTTP_Message_Status status;
        CCHTTP_Message message;
    }

    enum connectionState{
        READY,
        WAITING,
        BUSY
    } 

    struct connectionStateInfo{
        uint64 chain;
        address host;
        connectionState state;
        CCHTTP_Message_Info lastMessage;
    }

    event NonRevertiveError(string message);
    event Debug(string message);


    uint64 public thisChainId;
    address public CCTCP_Host;

    //just temporary
    address public Link_Token;
    
    mapping (uint64 chain =>address host) public CCTCP_Chains_Hosts;
    mapping (address host => connectionStateInfo) public CCTCP_Hosts_Connections;

    //TODO constructor 


    //To be called from CCTCP Host
    function receiveMessage(
        uint64 origChainId,
        bytes memory origData
    )  external  {
        CCHTTP_Message memory mssg = abi.decode(origData, (CCHTTP_Message));

        if(mssg.primitive == CCHTTP_Primitive.REQUEST){
            if( processRequest(origChainId, mssg.operation, mssg.data) ){
                emit Debug("Request processed");
            }
            else{
                emit NonRevertiveError("Request processing failed");
            }
        }
        else if(mssg.primitive == CCHTTP_Primitive.CONFIRMATION){
            if( processConfirmation(origChainId, mssg.operation, mssg.data) ){
                emit Debug("Confirmation processed");
            }
            else{
                emit NonRevertiveError("Confirmation processing failed");
            }
        }
    }

    function processRequest
    (
        uint64 origChain,
        CCHTTP_Operation op, 
        bytes memory data
    ) internal returns (bool) {
        if (op == CCHTTP_Operation.DEPLOY_AND_MINT){
            deploy_and_mint_mssg memory mssg = abi.decode(data, (deploy_and_mint_mssg));
            return deployAndMintIndication(
                origChain, 
                mssg.user,
                mssg.tokenName,
                mssg.tokenSymbol,
                mssg.expectedTokenAddress,
                mssg.decimals,
                mssg.amount
            );
        }
        else if (op == CCHTTP_Operation.MINT){
            mint_mssg memory mssg = abi.decode(data, (mint_mssg));
            return mintIndication(
                origChain,
                mssg.receiver,
                mssg.token,
                mssg.amount
            );
        }
        else if (op == CCHTTP_Operation.BURN){
            burn_mssg memory mssg = abi.decode(data, (burn_mssg));
            return burnIndication(
                origChain, 
                mssg.sender, 
                mssg.token, 
                mssg.amount
            );
        }
        else if (op == CCHTTP_Operation.UPDATE_SUPPLY){
            upd_total_supply_mssg memory mssg = abi.decode(data, (upd_total_supply_mssg));
            return updateSupplyIndication(
                origChain, 
                mssg.token, 
                mssg.amount
            );
        }
        else{
            emit NonRevertiveError("Unknown operation");
            return false;
        }
    }


    function processConfirmation(
        uint64 origChain,
        CCHTTP_Operation op,
        bytes memory data
    ) internal returns (bool){
        if(op==CCHTTP_Operation.DEPLOY_AND_MINT){
            deploy_and_mint_mssg memory mssg = abi.decode(data, (deploy_and_mint_mssg));
            return deployAndMintConfirmation(
                origChain,
                mssg.user,
                mssg.expectedTokenAddress,
                mssg.amount
            );
        }
        else if(op==CCHTTP_Operation.MINT){
            mint_mssg memory mssg = abi.decode(data, (mint_mssg));
            return mintConfirmation(
                origChain,
                mssg.token,
                mssg.receiver,
                mssg.amount
            );
        }
        else if(op==CCHTTP_Operation.BURN){
            burn_mssg memory mssg = abi.decode(data, (burn_mssg));
            return burnConfirmation(
                origChain,
                mssg.sender,
                mssg.token,
                mssg.amount
            );
        }
        else if(op==CCHTTP_Operation.UPDATE_SUPPLY){
            upd_total_supply_mssg memory mssg = abi.decode(data, (upd_total_supply_mssg));
            return updateSupplyConfirmation(
                origChain,
                mssg.token,
                mssg.amount
            );
        }
        else{
            return false;
        }
    }



    //To make call to CCTCP Host
    function _send(
        uint64 destChainId,
        address destination,
        bytes memory data,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount
    ) internal returns (bool){

        if(linkToken != Link_Token){
            emit NonRevertiveError("Other token for CCIP than LINK not supported");
            return false;
        }
        
        ICCTCP_Consumer(CCTCP_Host).sendMessage(
            destChainId,
            destination,
            address(this),
            linkAmount,
            data,
            feeToken,
            feesAmount
        );

        return true;
    }


    //to call before send
    function estimateFees(
        uint64 destChainId,
        address destination,
        bytes memory data,
        address linkToken,
        uint256 linkAmount,
        address feeToken
    ) external returns (uint256 feeAmount){

        if(linkToken != Link_Token){
            emit NonRevertiveError("Other token for CCIP than LINK not supported");
            return 0;
        }
        
        feeAmount = ICCTCP_Consumer(CCTCP_Host).getFeesForMessage(
            destChainId,
            destination,
            linkAmount,
            data,
            feeToken
        );
    }


    function retryLastMessage(uint64 chain, uint256 muchMoreLink) external returns (bool){
        if(CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[chain]].state != connectionState.BUSY){
            emit NonRevertiveError("Connection not busy");
            return false;
        }
        CCHTTP_Message_Info memory message_info = CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[chain]].lastMessage;
        bytes memory data = abi.encode(message_info.message);
        if(_retry(chain, message_info.destHost, data, message_info.linkToken, muchMoreLink, message_info.feeToken, message_info.feesAmount)){
            emit Debug("Last message resent to Transport Layer");
            return true;
        }
        else{
            emit NonRevertiveError("Last message resend failed");
            return false;
        }
    }


    function _retry(
        uint64 destChainId,
        address destination,
        bytes memory data,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount
    ) internal returns (bool){
        if(linkToken != Link_Token){
            emit NonRevertiveError("Other token for CCIP than LINK not supported");
            return false;
        }
        
        ICCTCP_Consumer(CCTCP_Host).retryMessage(
            destChainId,
            destination,
            address(this),
            linkAmount,
            data,
            feeToken,
            feesAmount
        );

        return true;
    }

    //
    //   Protocol  Primitives
    //

    function mintRequest(
        uint64 destChainId,
        address token,
        address destUser,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount,
        uint256 amount
    ) external returns (bool){
        mint_mssg memory mssg = mint_mssg({
            token: token,
            receiver: destUser,
            amount: amount
        });

        CCHTTP_Message memory message = CCHTTP_Message({
            operation: CCHTTP_Operation.MINT,
            primitive: CCHTTP_Primitive.REQUEST,
            originUser: msg.sender,
            destinationUser: destUser,
            data: abi.encode(mssg)
        });

        CCHTTP_Message_Info memory message_info = CCHTTP_Message_Info({
            origChainId: thisChainId,
            origHost: address(this),
            destChainId: destChainId,
            destHost: CCTCP_Chains_Hosts[destChainId],
            linkToken: linkToken,
            linkAmount: linkAmount,
            feeToken: feeToken,
            feesAmount: feesAmount,
            status: CCHTTP_Message_Status.PENDING,
            message: message
        });

        bytes memory data = abi.encode(message);

        if(_send(destChainId, message_info.destHost, data, linkToken, linkAmount, feeToken, feesAmount)){
            emit Debug("Mint request sent to Transport Layer");
            return true;
        }
        else{
            return false;
        }
    }


    function mintIndication(
        uint64 origChainId,
        address token,
        address destUser,
        uint256 amount
    ) 
        internal returns (bool)
    {
        emit Debug("Mint Indication Received");
        //firs release connection
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[origChainId]].state = connectionState.READY;
        string memory log = string(abi.encodePacked("Mint order received: ", amount));
        emit Debug(log);
        //nothing more to do here

        emit Debug(string(abi.encode(destUser)));
        emit Debug(string(abi.encode(token)));
        return true;
    }

    function mintConfirmation(
        uint64 origChainId,
        address destUser,
        address token,
        uint256 amount
    ) internal returns (bool){
        emit Debug("Mint at pair chain Confirmation");
        //firs release connection
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[origChainId]].state = connectionState.READY;
        string memory log = string(abi.encodePacked("Mint at pair chain confirmed: ", amount));
        emit Debug(log);
        //nothing more to do here
        //TODO: proper event 
        emit Debug(string(abi.encode(destUser)));
        emit Debug(string(abi.encode(token)));
        return true;
    }


    function updateSupplyRequest(
        uint64 destChainId,
        address token,
        address user,
        uint256 amount,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount
    ) external onlyOwner returns (bool){
        assert (linkToken == Link_Token);
        if (CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].state != connectionState.READY){
            emit NonRevertiveError("Connection not ready");
            return false;
        }
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].state = connectionState.BUSY;

        CCHTTP_Message memory message = CCHTTP_Message({
            operation: CCHTTP_Operation.UPDATE_SUPPLY,
            primitive: CCHTTP_Primitive.REQUEST,
            originUser: msg.sender,
            destinationUser: user,
            data: abi.encode(token, amount)
        });

        CCHTTP_Message_Info memory message_info = CCHTTP_Message_Info({
            origChainId: thisChainId,
            origHost: address(this),
            destChainId: destChainId,
            destHost: CCTCP_Chains_Hosts[destChainId],
            linkToken: Link_Token,
            linkAmount: linkAmount,
            feeToken: feeToken,
            feesAmount: feesAmount,
            status: CCHTTP_Message_Status.PENDING,
            message: message
        });
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].lastMessage = message_info;

        bytes memory data = abi.encode(message);
        if(_send(destChainId, message_info.destHost, data, Link_Token, 0, Link_Token, 0)){
            emit Debug("UpdateSupply request sent to Transport Layer");
            return true;
        }
        else{
            emit NonRevertiveError("UpdateSupply request failed");
            return false;
        }
    }


    function updateSupplyIndication(
        uint64 destChainId,
        address token,
        uint256 amount
    ) internal returns (bool){
        // Here we would update the token contract....
        emit Debug("UpdateSupply  Indication Received at pair chain");
        emit Debug(string(abi.encode(destChainId)));
        emit Debug(string(abi.encode(token)));
        emit Debug(string(abi.encode(amount)));
        return true;
    }

    function updateSupplyConfirmation(
        uint64 origChainId,
        address token,
        uint256 amount
    ) internal returns (bool){
        emit Debug("UpdateSupply at pair chain Confirmation");
        //first release connection
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[origChainId]].state = connectionState.READY;

        emit Debug(string(abi.encode(token)));
        emit Debug(string(abi.encode(amount)));
        return true;
    }

    function burnRequest(
        uint64 destChainId,
        address token,
        address user,
        uint256 amount,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount
    ) external returns (bool){
        assert (linkToken == Link_Token);
        if (CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].state != connectionState.READY){
            emit NonRevertiveError("Connection not ready");
            return false;
        }

        CCHTTP_Message memory message = CCHTTP_Message({
            operation: CCHTTP_Operation.BURN,
            primitive: CCHTTP_Primitive.REQUEST,
            originUser: msg.sender,
            destinationUser: user,
            data: abi.encode(token, amount)
        });

        CCHTTP_Message_Info memory message_info = CCHTTP_Message_Info({
            origChainId: thisChainId,
            origHost: address(this),
            destChainId: destChainId,
            destHost: CCTCP_Chains_Hosts[destChainId],
            linkToken: linkToken,
            linkAmount: linkAmount,
            feeToken: feeToken,
            feesAmount: feesAmount,
            status: CCHTTP_Message_Status.PENDING,
            message: message
        });
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].lastMessage = message_info;

        bytes memory data = abi.encode(message);

        if(_send(destChainId, message_info.destHost, data, linkToken, linkAmount, feeToken, feesAmount)){
            emit Debug("Burn request sent to Transport Layer");
            return true;
        }
        else{
            emit NonRevertiveError("Burn request failed");
            return false;
        }
    }

    function burnIndication(
        uint64 destChainId,
        address token,
        address user,
        uint256 amount
    ) internal returns (bool){
        // Here we would burn the token....
        emit Debug("Burn Indication Received");
        emit Debug(string(abi.encode(destChainId)));
        emit Debug(string(abi.encode(user)));
        emit Debug(string(abi.encode(token)));
        emit Debug(string(abi.encode(amount)));
        return true;
    }

    function burnConfirmation(
        uint64 origChainId,
        address sender,
        address token,
        uint256 amount
    ) internal returns (bool){
        emit Debug("Burn at pair chain Confirmation");
        //first release connection
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[origChainId]].state = connectionState.READY;
        emit Debug(string(abi.encode(sender)));
        emit Debug(string(abi.encode(token)));
        emit Debug(string(abi.encode(amount)));
        return true;
    }

    function deployAndMintRequest(
        uint64 destChainId,
        address origUser,
        address destUser,
        address linkToken,
        uint256 linkAmount,
        address feeToken,
        uint256 feesAmount,
        string calldata tokenName,
        string calldata tokenSymbol,
        address expectedTokenAddress,
        uint24 decimals,
        uint256 amount,
        uint256 totalSupply
    ) external returns (bool){
        assert (linkToken == Link_Token);
        if (CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].state != connectionState.READY){
            emit NonRevertiveError("Connection not ready");
            return false;
        }

        CCHTTP_Message memory message = CCHTTP_Message({
            operation: CCHTTP_Operation.DEPLOY_AND_MINT,
            primitive: CCHTTP_Primitive.REQUEST,
            originUser: origUser,
            destinationUser: destUser,
            data: abi.encode(tokenName, tokenSymbol, expectedTokenAddress, decimals, amount, totalSupply)
        });
        CCHTTP_Message_Info memory message_info = CCHTTP_Message_Info({
            origChainId: thisChainId,
            origHost: address(this),
            destChainId: destChainId,
            destHost: CCTCP_Chains_Hosts[destChainId],
            linkToken: linkToken,
            linkAmount: linkAmount,
            feeToken: feeToken,
            feesAmount: feesAmount,
            status: CCHTTP_Message_Status.PENDING,
            message: message
        });
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[destChainId]].lastMessage = message_info;

        return true;
    }



    function deployAndMintIndication(
        uint64 origChainId,
        address origin,
        string memory tokenName,
        string memory tokenSymbol,
        address expectedTokenAddress,
        uint24 decimals,
        uint256 amount
    ) internal returns (bool){
        // Here we would deploy the token and mint the amount....
        emit Debug("DeployAndMintIndication");
        emit Debug(string(abi.encode(origChainId)));
        emit Debug(string(abi.encode(origin)));
        emit Debug(tokenName);
        emit Debug(tokenSymbol);
        emit Debug(string(abi.encode(expectedTokenAddress)));
        emit Debug(string(abi.encode(decimals)));
        emit Debug(string(abi.encode(amount)));
        return true;
    }


    function deployAndMintConfirmation(
        uint64 origChainId,
        address token,
        address destUser,
        uint256 amount
    ) internal returns (bool){
        emit Debug("DeployAndMint at pair chain Confirmation");
        //first release connection
        CCTCP_Hosts_Connections[CCTCP_Chains_Hosts[origChainId]].state = connectionState.READY;
        emit Debug(string(abi.encode(token)));
        emit Debug(string(abi.encode(destUser)));
        emit Debug(string(abi.encode(amount)));
        //TODO
        return true;
    }
}
