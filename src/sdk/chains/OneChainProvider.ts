import { ChainProvider, TransactionRequest, Transaction, TransactionReceipt, SDKConfig } from '../core/types';
import { ethers } from 'ethers';

/**
 * OneChain Provider - Primary chain for OmniFlow RWA marketplace
 * Optimized for demo demonstrations with enhanced features
 */
export class OneChainProvider implements ChainProvider {
  public readonly chainId = 'onechain' as const;
  private provider: ethers.JsonRpcProvider;
  private signer?: ethers.Signer;
  private config: SDKConfig;

  // OneChain specific configuration
  private readonly CHAIN_CONFIG = {
    testnet: {
      chainId: 1001,
      name: 'OneChain Testnet',
      rpcUrl: 'https://testnet-rpc.onechain.ai',
      explorerUrl: 'https://testnet-explorer.onechain.ai',
      nativeCurrency: {
        name: 'OneChain Token',
        symbol: 'OCT',
        decimals: 18,
      },
    },
    mainnet: {
      chainId: 1000,
      name: 'OneChain Mainnet',
      rpcUrl: 'https://rpc.onechain.ai',
      explorerUrl: 'https://explorer.onechain.ai',
      nativeCurrency: {
        name: 'OneChain Token',
        symbol: 'OCT',
        decimals: 18,
      },
    },
  };

  constructor(config: SDKConfig) {
    this.config = config;
    const chainConfig = this.CHAIN_CONFIG[config.environment];
    const rpcUrl = config.rpcEndpoints?.onechain || chainConfig.rpcUrl;
    
    this.provider = new ethers.JsonRpcProvider(rpcUrl, {
      chainId: chainConfig.chainId,
      name: chainConfig.name,
    });
  }

  async initialize(): Promise<void> {
    try {
      // Test connection
      await this.provider.getNetwork();
      
      // Initialize signer if private key is provided
      if (this.config.privateKey) {
        this.signer = new ethers.Wallet(this.config.privateKey, this.provider);
      }

      console.log(`OneChain Provider initialized for ${this.config.environment}`);
    } catch (error) {
      throw new Error(`Failed to initialize OneChain provider: ${error}`);
    }
  }

  async disconnect(): Promise<void> {
    // Cleanup connections
    this.signer = undefined;
  }

  async isHealthy(): Promise<boolean> {
    try {
      const blockNumber = await this.provider.getBlockNumber();
      return blockNumber > 0;
    } catch {
      return false;
    }
  }

  async getBalance(address: string): Promise<string> {
    const balance = await this.provider.getBalance(address);
    return ethers.formatEther(balance);
  }

  async sendTransaction(tx: TransactionRequest): Promise<Transaction> {
    if (!this.signer) {
      throw new Error('Signer not initialized');
    }

    const txRequest = {
      to: tx.to,
      value: tx.value ? ethers.parseEther(tx.value) : undefined,
      data: tx.data,
      gasPrice: tx.gasPrice ? ethers.parseUnits(tx.gasPrice, 'gwei') : undefined,
      gasLimit: tx.gasLimit ? BigInt(tx.gasLimit) : undefined,
    };

    const txResponse = await this.signer.sendTransaction(txRequest);

    return {
      hash: txResponse.hash,
      chainId: 'onechain',
      from: txResponse.from,
      to: txResponse.to || '',
      value: ethers.formatEther(txResponse.value || 0),
      gasPrice: ethers.formatUnits(txResponse.gasPrice || 0, 'gwei'),
      gasLimit: (txResponse.gasLimit || BigInt(0)).toString(),
      data: txResponse.data || '0x',
      nonce: txResponse.nonce,
      status: 'pending',
    };
  }

  async call(to: string, data: string): Promise<string> {
    return await this.provider.call({ to, data });
  }

  async estimateGas(tx: TransactionRequest): Promise<string> {
    const gasEstimate = await this.provider.estimateGas({
      to: tx.to,
      value: tx.value ? ethers.parseEther(tx.value) : undefined,
      data: tx.data,
    });
    return gasEstimate.toString();
  }

  async getBlockNumber(): Promise<number> {
    return await this.provider.getBlockNumber();
  }

  async waitForTransaction(hash: string): Promise<TransactionReceipt> {
    const receipt = await this.provider.waitForTransaction(hash);
    if (!receipt) {
      throw new Error('Transaction receipt not found');
    }

    return {
      hash: receipt.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      status: receipt.status === 1,
      logs: receipt.logs.map(log => ({
        address: log.address,
        topics: log.topics,
        data: log.data,
      })),
    };
  }

  /**
   * OneChain specific methods for enhanced functionality
   */

  async getChainInfo() {
    const network = await this.provider.getNetwork();
    const chainConfig = this.CHAIN_CONFIG[this.config.environment];
    
    return {
      chainId: Number(network.chainId),
      name: network.name,
      rpcUrl: chainConfig.rpcUrl,
      explorerUrl: chainConfig.explorerUrl,
      nativeCurrency: chainConfig.nativeCurrency,
    };
  }

  async getFeeData() {
    const feeData = await this.provider.getFeeData();
    return {
      gasPrice: feeData.gasPrice ? ethers.formatUnits(feeData.gasPrice, 'gwei') : null,
      maxFeePerGas: feeData.maxFeePerGas ? ethers.formatUnits(feeData.maxFeePerGas, 'gwei') : null,
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ? ethers.formatUnits(feeData.maxPriorityFeePerGas, 'gwei') : null,
    };
  }

  async getTransactionCount(address: string): Promise<number> {
    return await this.provider.getTransactionCount(address);
  }

  async getTransaction(hash: string) {
    const tx = await this.provider.getTransaction(hash);
    if (!tx) return null;

    return {
      hash: tx.hash,
      from: tx.from,
      to: tx.to,
      value: ethers.formatEther(tx.value),
      gasPrice: tx.gasPrice ? ethers.formatUnits(tx.gasPrice, 'gwei') : null,
      gasLimit: tx.gasLimit.toString(),
      data: tx.data,
      nonce: tx.nonce,
      blockNumber: tx.blockNumber,
    };
  }

  /**
   * Contract interaction helpers
   */
  async deployContract(bytecode: string, abi: any[], constructorArgs: any[] = []): Promise<ethers.Contract> {
    if (!this.signer) {
      throw new Error('Signer required for contract deployment');
    }

    const factory = new ethers.ContractFactory(abi, bytecode, this.signer);
    const contract = await factory.deploy(...constructorArgs);
    await contract.waitForDeployment();
    
    return contract;
  }

  getContract(address: string, abi: any[]): ethers.Contract {
    const signerOrProvider = this.signer || this.provider;
    return new ethers.Contract(address, abi, signerOrProvider);
  }

  /**
   * OneChain-specific RWA contract interactions
   */
  async createRWAToken(
    name: string,
    symbol: string,
    metadataURI: string,
    assetValue: string
  ): Promise<Transaction> {
    const contractAddress = this.config.contractAddresses?.onechain?.rwaToken;
    if (!contractAddress) {
      throw new Error('RWA Token contract address not configured');
    }

    // Simplified ABI for demo
    const abi = [
      'function mint(address to, string memory name, string memory symbol, string memory metadataURI, uint256 assetValue) external returns (uint256)',
    ];

    const contract = this.getContract(contractAddress, abi);
    const tx = await contract.mint(
      this.signer?.address,
      name,
      symbol,
      metadataURI,
      ethers.parseEther(assetValue)
    );

    return {
      hash: tx.hash,
      chainId: 'onechain',
      from: tx.from,
      to: tx.to,
      value: '0',
      gasPrice: ethers.formatUnits(tx.gasPrice || 0, 'gwei'),
      gasLimit: (tx.gasLimit || BigInt(0)).toString(),
      data: tx.data,
      nonce: tx.nonce,
      status: 'pending',
    };
  }

  async listAssetOnMarketplace(
    tokenId: number,
    price: string,
    listingType: 'fixed' | 'auction'
  ): Promise<Transaction> {
    const contractAddress = this.config.contractAddresses?.onechain?.marketplace;
    if (!contractAddress) {
      throw new Error('Marketplace contract address not configured');
    }

    const abi = [
      'function listAsset(uint256 tokenId, uint256 price, uint8 listingType) external',
    ];

    const contract = this.getContract(contractAddress, abi);
    const tx = await contract.listAsset(
      tokenId,
      ethers.parseEther(price),
      listingType === 'fixed' ? 0 : 1
    );

    return {
      hash: tx.hash,
      chainId: 'onechain',
      from: tx.from,
      to: tx.to,
      value: '0',
      gasPrice: ethers.formatUnits(tx.gasPrice || 0, 'gwei'),
      gasLimit: (tx.gasLimit || BigInt(0)).toString(),
      data: tx.data,
      nonce: tx.nonce,
      status: 'pending',
    };
  }

  /**
   * Demo-specific helper methods for demos
   */
  async getDemoAssets(): Promise<any[]> {
    // Return mock demo assets for demo presentation
    return [
      {
        id: 'demo-1',
        name: 'Manhattan Luxury Condo',
        type: 'real-estate',
        value: '2500000',
        location: 'New York, USA',
        tokenId: 1001,
      },
      {
        id: 'demo-2',
        name: 'Solar Farm Texas',
        type: 'renewable-energy',
        value: '5000000',
        location: 'Austin, USA',
        tokenId: 1002,
      },
      {
        id: 'demo-3',
        name: 'Amazon Carbon Credits',
        type: 'carbon-credits',
        value: '750000',
        location: 'Brazil',
        tokenId: 1003,
      },
    ];
  }

  async simulateDemoDemo(): Promise<{
    assetsCreated: number;
    transactionsExecuted: number;
    totalValue: string;
    demoUrl: string;
  }> {
    const demoAssets = await this.getDemoAssets();
    const totalValue = demoAssets.reduce((sum, asset) => sum + parseInt(asset.value), 0);

    return {
      assetsCreated: demoAssets.length,
      transactionsExecuted: 12, // Mock transaction count
      totalValue: ethers.formatEther(totalValue.toString()),
      demoUrl: `${this.CHAIN_CONFIG[this.config.environment].explorerUrl}/demo`,
    };
  }
}
