// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title IIdentityPassportNFT
 * @dev Interface for cross-chain identity passport NFT with DID integration
 */
interface IIdentityPassportNFT is IERC721 {
    // Enums
    enum KYCLevel { None, Basic, Enhanced, Institutional }
    enum InvestorTier { None, Retail, Accredited, Institutional, Qualified }

    // Structs
    struct CrossChainAddress {
        string chain;
        string address;
        bool verified;
        uint256 timestamp;
    }

    struct IdentityPassport {
        string did;
        KYCLevel kycLevel;
        InvestorTier investorTier;
        uint256 reputationScore;
        uint256 issuanceDate;
        uint256 expirationDate;
        bool isActive;
        string metadataURI;
        address issuer;
        CrossChainAddress[] crossChainAddresses;
        string[] credentials;
    }

    // Events
    event PassportIssued(
        uint256 indexed tokenId,
        address indexed holder,
        string did,
        KYCLevel kycLevel,
        InvestorTier investorTier
    );
    
    event PassportUpdated(
        uint256 indexed tokenId,
        KYCLevel kycLevel,
        InvestorTier investorTier,
        uint256 reputationScore
    );
    
    event CrossChainAddressLinked(
        uint256 indexed tokenId,
        string chain,
        string chainAddress
    );
    
    event CrossChainSync(
        uint256 indexed tokenId,
        string targetChain,
        string remoteTokenId,
        bytes32 messageHash
    );
    
    event CredentialAdded(
        uint256 indexed tokenId,
        string credentialId,
        string credentialType
    );

    // Core functions
    function issuePassport(
        address to,
        string memory did,
        KYCLevel kycLevel,
        InvestorTier investorTier,
        string memory metadataURI,
        uint256 validityPeriod
    ) external returns (uint256);

    function updatePassport(
        uint256 tokenId,
        KYCLevel newKycLevel,
        InvestorTier newInvestorTier,
        uint256 newReputationScore,
        string memory newMetadataURI
    ) external;

    function linkCrossChainAddress(
        uint256 tokenId,
        string memory chain,
        string memory chainAddress,
        bytes memory signature
    ) external;

    function addCredential(
        uint256 tokenId,
        string memory credentialId,
        string memory credentialType,
        bytes memory credentialProof
    ) external;

    function syncToChain(
        uint256 tokenId,
        string memory targetChain,
        string memory targetContract
    ) external payable;

    // View functions
    function getPassport(uint256 tokenId) external view returns (IdentityPassport memory);
    function getPassportByAddress(address holder) external view returns (IdentityPassport memory);
    function getPassportByDID(string memory did) external view returns (IdentityPassport memory);
    function hasValidPassport(address holder) external view returns (bool);
    function getCrossChainAddresses(uint256 tokenId) external view returns (CrossChainAddress[] memory);
    function getCredentials(uint256 tokenId) external view returns (string[] memory);

    // ERC-725 functions
    function getData(uint256 tokenId, bytes32 dataKey) external view returns (bytes memory);

    // Mappings access
    function addressToTokenId(address holder) external view returns (uint256);
    function didToTokenId(string memory did) external view returns (uint256);
}
