import { EventEmitter } from 'events';
import { ChainProvider } from '../core/types';
import { 
  Asset, 
  BridgeTransfer, 
  Transaction, 
  ChainId,
  SDKError,
  BridgeStatus
} from '../core/types';

/**
 * Cross-Chain Bridge Manager - Handles RWA asset transfers between chains
 */
export class CrossChainBridge extends EventEmitter {
  private providers: Map<ChainId, ChainProvider>;
  private transfers: Map<string, BridgeTransfer> = new Map();
  private bridgeContracts: Map<ChainId, string> = new Map();

  constructor(providers: Map<ChainId, ChainProvider>) {
    super();
    this.providers = providers;
    this.initializeBridgeContracts();
  }

  /**
   * Transfer RWA asset from one chain to another
   */
  async bridgeAsset(
    asset: Asset,
    targetChainId: ChainId,
    recipient?: string
  ): Promise<BridgeTransfer> {
    const sourceProvider = this.providers.get(asset.chainId);
    const targetProvider = this.providers.get(targetChainId);

    if (!sourceProvider) {
      throw new SDKError(`Source provider not found for chain: ${asset.chainId}`, 'CHAIN_ERROR');
    }

    if (!targetProvider) {
      throw new SDKError(`Target provider not found for chain: ${targetChainId}`, 'CHAIN_ERROR');
    }

    if (asset.chainId === targetChainId) {
      throw new SDKError('Source and target chains cannot be the same', 'BRIDGE_ERROR');
    }

    try {
      const transferId = `bridge-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
      const recipientAddress = recipient || asset.owner;

      // Step 1: Lock asset on source chain
      const lockTx = await this.lockAssetOnSource(asset, targetChainId, recipientAddress);

      const transfer: BridgeTransfer = {
        id: transferId,
        assetId: asset.id,
        sourceChainId: asset.chainId,
        targetChainId,
        sender: asset.owner,
        recipient: recipientAddress,
        status: 'pending',
        lockTransactionHash: lockTx.hash,
        createdAt: new Date(),
        updatedAt: new Date(),
        estimatedTime: this.getEstimatedBridgeTime(asset.chainId, targetChainId),
      };

      this.transfers.set(transferId, transfer);
      this.emit('bridgeInitiated', { transfer, lockTransaction: lockTx });

      // Step 2: Start monitoring for confirmation (async)
      this.monitorBridgeTransfer(transferId);

      return transfer;
    } catch (error) {
      throw new SDKError(`Failed to bridge asset: ${error}`, 'BRIDGE_ERROR');
    }
  }

  /**
   * Get bridge transfer status
   */
  async getBridgeTransfer(transferId: string): Promise<BridgeTransfer | null> {
    return this.transfers.get(transferId) || null;
  }

  /**
   * Get all bridge transfers for a user
   */
  async getBridgeTransfers(userAddress?: string): Promise<BridgeTransfer[]> {
    let transfers = Array.from(this.transfers.values());

    if (userAddress) {
      transfers = transfers.filter(transfer => 
        transfer.sender.toLowerCase() === userAddress.toLowerCase() ||
        transfer.recipient.toLowerCase() === userAddress.toLowerCase()
      );
    }

    return transfers.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  /**
   * Get supported bridge routes
   */
  async getSupportedRoutes(): Promise<Array<{
    sourceChain: ChainId;
    targetChain: ChainId;
    estimatedTime: number;
    fee: string;
    supported: boolean;
  }>> {
    const chains: ChainId[] = ['onechain', 'ethereum', 'polygon', 'bsc'];
    const routes: Array<{
      sourceChain: ChainId;
      targetChain: ChainId;
      estimatedTime: number;
      fee: string;
      supported: boolean;
    }> = [];

    for (const sourceChain of chains) {
      for (const targetChain of chains) {
        if (sourceChain !== targetChain) {
          routes.push({
            sourceChain,
            targetChain,
            estimatedTime: this.getEstimatedBridgeTime(sourceChain, targetChain),
            fee: this.getBridgeFee(sourceChain, targetChain),
            supported: this.isRouteSupported(sourceChain, targetChain),
          });
        }
      }
    }

    return routes;
  }

  /**
   * Estimate bridge cost and time
   */
  async estimateBridge(
    asset: Asset,
    targetChainId: ChainId
  ): Promise<{
    estimatedTime: number;
    bridgeFee: string;
    gasCost: string;
    totalCost: string;
  }> {
    const sourceProvider = this.providers.get(asset.chainId);
    const targetProvider = this.providers.get(targetChainId);

    if (!sourceProvider || !targetProvider) {
      throw new SDKError('Providers not available for bridge estimation', 'CHAIN_ERROR');
    }

    const estimatedTime = this.getEstimatedBridgeTime(asset.chainId, targetChainId);
    const bridgeFee = this.getBridgeFee(asset.chainId, targetChainId);

    // Estimate gas costs
    const sourceGas = await this.estimateSourceGas(asset);
    const targetGas = await this.estimateTargetGas(asset, targetChainId);
    const totalGasCost = parseFloat(sourceGas) + parseFloat(targetGas);

    const totalCost = parseFloat(bridgeFee) + totalGasCost;

    return {
      estimatedTime,
      bridgeFee,
      gasCost: totalGasCost.toString(),
      totalCost: totalCost.toString(),
    };
  }

  /**
   * Cancel pending bridge transfer (if possible)
   */
  async cancelBridgeTransfer(transferId: string): Promise<Transaction> {
    const transfer = this.transfers.get(transferId);
    if (!transfer) {
      throw new SDKError(`Transfer not found: ${transferId}`, 'BRIDGE_ERROR');
    }

    if (transfer.status !== 'pending') {
      throw new SDKError(`Cannot cancel transfer with status: ${transfer.status}`, 'BRIDGE_ERROR');
    }

    const sourceProvider = this.providers.get(transfer.sourceChainId);
    if (!sourceProvider) {
      throw new SDKError(`Source provider not found: ${transfer.sourceChainId}`, 'CHAIN_ERROR');
    }

    try {
      // Create cancellation transaction
      const tx = await sourceProvider.sendTransaction({
        to: this.bridgeContracts.get(transfer.sourceChainId) || '',
        data: this.encodeCancelData(transfer.id),
      });

      // Update transfer status
      transfer.status = 'cancelled';
      transfer.updatedAt = new Date();
      this.transfers.set(transferId, transfer);

      this.emit('bridgeCancelled', { transfer, transaction: tx });
      return tx;
    } catch (error) {
      throw new SDKError(`Failed to cancel bridge transfer: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Get bridge analytics
   */
  async getBridgeAnalytics(): Promise<{
    totalTransfers: number;
    successfulTransfers: number;
    totalVolume: string;
    averageTime: number;
    popularRoutes: Array<{ route: string; count: number }>;
  }> {
    const transfers = Array.from(this.transfers.values());
    const successfulTransfers = transfers.filter(t => t.status === 'completed');

    const totalVolume = transfers.reduce((sum, transfer) => {
      // Would need asset value lookup in real implementation
      return sum + 1000000; // Mock value
    }, 0);

    const completedTransfers = transfers.filter(t => t.status === 'completed' && t.completedAt);
    const averageTime = completedTransfers.length > 0
      ? completedTransfers.reduce((sum, transfer) => {
          const duration = transfer.completedAt!.getTime() - transfer.createdAt.getTime();
          return sum + duration;
        }, 0) / completedTransfers.length / 1000 // Convert to seconds
      : 0;

    // Calculate popular routes
    const routeCounts = new Map<string, number>();
    transfers.forEach(transfer => {
      const route = `${transfer.sourceChainId}->${transfer.targetChainId}`;
      routeCounts.set(route, (routeCounts.get(route) || 0) + 1);
    });

    const popularRoutes = Array.from(routeCounts.entries())
      .map(([route, count]) => ({ route, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);

    return {
      totalTransfers: transfers.length,
      successfulTransfers: successfulTransfers.length,
      totalVolume: totalVolume.toString(),
      averageTime,
      popularRoutes,
    };
  }

  /**
   * Private helper methods
   */
  private async lockAssetOnSource(
    asset: Asset,
    targetChainId: ChainId,
    recipient: string
  ): Promise<Transaction> {
    const sourceProvider = this.providers.get(asset.chainId);
    if (!sourceProvider) {
      throw new SDKError(`Source provider not found: ${asset.chainId}`, 'CHAIN_ERROR');
    }

    const bridgeContract = this.bridgeContracts.get(asset.chainId);
    if (!bridgeContract) {
      throw new SDKError(`Bridge contract not found for chain: ${asset.chainId}`, 'BRIDGE_ERROR');
    }

    return await sourceProvider.sendTransaction({
      to: bridgeContract,
      data: this.encodeLockData(asset.tokenId, targetChainId, recipient),
    });
  }

  private async monitorBridgeTransfer(transferId: string): Promise<void> {
    const transfer = this.transfers.get(transferId);
    if (!transfer) return;

    // Simulate bridge processing time
    setTimeout(async () => {
      try {
        // Step 3: Mint asset on target chain
        const mintTx = await this.mintAssetOnTarget(transfer);
        
        transfer.status = 'completed';
        transfer.mintTransactionHash = mintTx.hash;
        transfer.completedAt = new Date();
        transfer.updatedAt = new Date();
        
        this.transfers.set(transferId, transfer);
        this.emit('bridgeCompleted', { transfer, mintTransaction: mintTx });
      } catch (error) {
        transfer.status = 'failed';
        transfer.error = error instanceof Error ? error.message : 'Unknown error';
        transfer.updatedAt = new Date();
        
        this.transfers.set(transferId, transfer);
        this.emit('bridgeFailed', { transfer, error });
      }
    }, transfer.estimatedTime * 1000);
  }

  private async mintAssetOnTarget(transfer: BridgeTransfer): Promise<Transaction> {
    const targetProvider = this.providers.get(transfer.targetChainId);
    if (!targetProvider) {
      throw new SDKError(`Target provider not found: ${transfer.targetChainId}`, 'CHAIN_ERROR');
    }

    const bridgeContract = this.bridgeContracts.get(transfer.targetChainId);
    if (!bridgeContract) {
      throw new SDKError(`Bridge contract not found for chain: ${transfer.targetChainId}`, 'BRIDGE_ERROR');
    }

    return await targetProvider.sendTransaction({
      to: bridgeContract,
      data: this.encodeMintData(transfer.assetId, transfer.recipient),
    });
  }

  private initializeBridgeContracts(): void {
    // Initialize bridge contract addresses for each chain
    this.bridgeContracts.set('onechain', '0x1111111111111111111111111111111111111111');
    this.bridgeContracts.set('ethereum', '0x2222222222222222222222222222222222222222');
    this.bridgeContracts.set('polygon', '0x3333333333333333333333333333333333333333');
    this.bridgeContracts.set('bsc', '0x4444444444444444444444444444444444444444');
  }

  private getEstimatedBridgeTime(sourceChain: ChainId, targetChain: ChainId): number {
    // Estimated bridge times in seconds
    const baseTimes: Record<ChainId, Record<ChainId, number>> = {
      'onechain': {
        'ethereum': 300, // 5 minutes
        'polygon': 180, // 3 minutes
        'bsc': 240, // 4 minutes
      },
      'ethereum': {
        'onechain': 600, // 10 minutes
        'polygon': 1200, // 20 minutes
        'bsc': 900, // 15 minutes
      },
      'polygon': {
        'onechain': 180, // 3 minutes
        'ethereum': 1200, // 20 minutes
        'bsc': 600, // 10 minutes
      },
      'bsc': {
        'onechain': 240, // 4 minutes
        'ethereum': 900, // 15 minutes
        'polygon': 600, // 10 minutes
      },
    };

    return baseTimes[sourceChain]?.[targetChain] || 600; // Default 10 minutes
  }

  private getBridgeFee(sourceChain: ChainId, targetChain: ChainId): string {
    // Bridge fees in USD
    const fees: Record<ChainId, Record<ChainId, string>> = {
      'onechain': {
        'ethereum': '25.00',
        'polygon': '5.00',
        'bsc': '8.00',
      },
      'ethereum': {
        'onechain': '30.00',
        'polygon': '15.00',
        'bsc': '20.00',
      },
      'polygon': {
        'onechain': '5.00',
        'ethereum': '15.00',
        'bsc': '8.00',
      },
      'bsc': {
        'onechain': '8.00',
        'ethereum': '20.00',
        'polygon': '8.00',
      },
    };

    return fees[sourceChain]?.[targetChain] || '10.00'; // Default fee
  }

  private isRouteSupported(sourceChain: ChainId, targetChain: ChainId): boolean {
    // All routes are supported in this implementation
    return this.providers.has(sourceChain) && this.providers.has(targetChain);
  }

  private async estimateSourceGas(asset: Asset): Promise<string> {
    const provider = this.providers.get(asset.chainId);
    if (!provider) return '0';

    try {
      return await provider.estimateGas({
        to: this.bridgeContracts.get(asset.chainId) || '',
        data: this.encodeLockData(asset.tokenId, 'ethereum', asset.owner),
      });
    } catch {
      return '0.01'; // Default gas estimate
    }
  }

  private async estimateTargetGas(asset: Asset, targetChainId: ChainId): Promise<string> {
    const provider = this.providers.get(targetChainId);
    if (!provider) return '0';

    try {
      return await provider.estimateGas({
        to: this.bridgeContracts.get(targetChainId) || '',
        data: this.encodeMintData(asset.id, asset.owner),
      });
    } catch {
      return '0.01'; // Default gas estimate
    }
  }

  private encodeLockData(tokenId: number, targetChainId: ChainId, recipient: string): string {
    const chainIdMap: Record<ChainId, number> = {
      'onechain': 1000,
      'ethereum': 1,
      'polygon': 137,
      'bsc': 56,
    };

    const targetChainIdNum = chainIdMap[targetChainId] || 1;
    
    return `0x${tokenId.toString(16).padStart(64, '0')}${targetChainIdNum.toString(16).padStart(64, '0')}${recipient.slice(2).padStart(64, '0')}`;
  }

  private encodeMintData(assetId: string, recipient: string): string {
    return `0x${assetId.slice(-32)}${recipient.slice(2).padStart(64, '0')}`;
  }

  private encodeCancelData(transferId: string): string {
    return `0x${transferId.slice(-32)}`;
  }

  /**
   * Load demo bridge transfers for demo presentations
   */
  async loadDemoBridgeTransfers(): Promise<BridgeTransfer[]> {
    const demoTransfers: Partial<BridgeTransfer>[] = [
      {
        assetId: 'onechain-real-estate-demo-1',
        sourceChainId: 'onechain',
        targetChainId: 'ethereum',
        sender: '0x1234567890123456789012345678901234567890',
        recipient: '0x1234567890123456789012345678901234567890',
        status: 'completed',
        lockTransactionHash: '0xabc123...',
        mintTransactionHash: '0xdef456...',
        completedAt: new Date(Date.now() - 3600000), // 1 hour ago
      },
      {
        assetId: 'onechain-renewable-energy-demo-2',
        sourceChainId: 'ethereum',
        targetChainId: 'polygon',
        sender: '0x2345678901234567890123456789012345678901',
        recipient: '0x2345678901234567890123456789012345678901',
        status: 'pending',
        lockTransactionHash: '0x789abc...',
      },
      {
        assetId: 'onechain-carbon-credits-demo-3',
        sourceChainId: 'polygon',
        targetChainId: 'onechain',
        sender: '0x3456789012345678901234567890123456789012',
        recipient: '0x3456789012345678901234567890123456789012',
        status: 'completed',
        lockTransactionHash: '0x456def...',
        mintTransactionHash: '0x123ghi...',
        completedAt: new Date(Date.now() - 7200000), // 2 hours ago
      },
    ];

    const createdTransfers: BridgeTransfer[] = [];
    for (const transferData of demoTransfers) {
      const transferId = `demo-bridge-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
      
      const transfer: BridgeTransfer = {
        id: transferId,
        assetId: transferData.assetId!,
        sourceChainId: transferData.sourceChainId!,
        targetChainId: transferData.targetChainId!,
        sender: transferData.sender!,
        recipient: transferData.recipient!,
        status: transferData.status!,
        lockTransactionHash: transferData.lockTransactionHash,
        mintTransactionHash: transferData.mintTransactionHash,
        createdAt: new Date(Date.now() - Math.random() * 86400000), // Random time in last 24h
        updatedAt: new Date(),
        completedAt: transferData.completedAt,
        estimatedTime: this.getEstimatedBridgeTime(transferData.sourceChainId!, transferData.targetChainId!),
      };

      this.transfers.set(transferId, transfer);
      createdTransfers.push(transfer);
    }

    return createdTransfers;
  }
}
